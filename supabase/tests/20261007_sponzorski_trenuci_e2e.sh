#!/usr/bin/env bash
# E2E sponzorskih trenutaka nad LOKALNIM stackom, kroz prave edge funkcije:
#   checkout (pinka-contribute) → potpisan intent.paid (pinka-webhook) → slot
#   sold → public_live_moments → račun na (mock) fiskalu → e-pošta vlasniku;
#   plus: 409 na utrku, dupli webhook ne izdaje drugi račun, manjak + alarm,
#   povlačenje kreative, cron.
#
# Preduvjeti (vidi docs/sponzorski-trenuci-zakljucak.md, "Lokalni test"):
#   1. migracije primijenjene, supabase/tests/20261007_sponzorski_trenuci.sql prošao
#   2. mock MPT/fiskal/Resend na :54999 (supabase/tests/mock-mpt-fiskal.ts)
#   3. supabase functions serve --env-file <e2e.env> (vrijednosti ispod)
#
# Očekivano: redci "OK — …" i na kraju "E2E PROŠAO".
set -euo pipefail

DB="${DB:-postgresql://postgres:postgres@127.0.0.1:55322/postgres}"
API="${API:-http://127.0.0.1:55321}"
MOCK="${MOCK:-http://127.0.0.1:54999}"
WEBHOOK_KEY="${WEBHOOK_KEY:-e2e-local-webhook-secret-123456}"   # = base64-dekodiran INTENT_WEBHOOK_SECRET
CRON_SECRET="${CRON_SECRET:-e2e-cron-secret-0123456789abcdef}"
CAMPAIGN=7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101
K_OK='KvIhy5SESYs@45'      # otvaranje, 8000
K_UNDER='KvIhy5SESYs@390'  # tijelo, 5000
K_RACE='KvIhy5SESYs@1005'

eval "$(supabase status -o env 2>/dev/null | grep -E '^(ANON_KEY|SERVICE_ROLE_KEY)=')"
q() { psql "$DB" -tAc "$1"; }
fail() { echo "PAO TEST: $*" >&2; exit 1; }

# ── priprema ────────────────────────────────────────────────────────────────
q "update pinka_finance.slots set state='free', contribution_id=null, holder_account_id=null,
     hold_session_key=null, hold_expires_at=null
   where slot_key in ('$K_OK','$K_UNDER','$K_RACE')" >/dev/null
# Plaćeni doprinosi iz SQL testa bi inače ušli u cron (račun, e-pošta) i
# pomiješali brojanje poziva — označi ih kao već obrađene.
q "update pinka_finance.contributions set invoice_state='skipped', owner_notified_at=coalesce(owner_notified_at, now())
   where campaign_id='$CAMPAIGN' and is_sponsor" >/dev/null
curl -s -XPOST "$MOCK/_reset" >/dev/null

# korisnik = brand s anonimnom-ekvivalentnom sesijom (lokalno: email/lozinka)
token_for() {
  local email="$1"
  curl -s -XPOST "$API/auth/v1/admin/users" -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" -H 'content-type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"e2e-lozinka-123\",\"email_confirm\":true}" >/dev/null
  curl -s -XPOST "$API/auth/v1/token?grant_type=password" -H "apikey: $ANON_KEY" \
    -H 'content-type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"e2e-lozinka-123\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}
T1=$(token_for e2e-brand-1@example.com)
T2=$(token_for e2e-brand-2@example.com)
T3=$(token_for e2e-brand-3@example.com)
UID1=$(q "select id from auth.users where email='e2e-brand-1@example.com'")

# Logo: storage API lokalno ne radi pa objekt upisujemo izravno (bucket limit
# i RLS uploada pokriva SQL test; ovdje je bitna provjera u checkoutu).
q "insert into storage.objects (bucket_id, name, owner, metadata)
   values ('sponsor-logos', '$UID1/logo.png', '$UID1', '{\"size\":1500,\"mimetype\":\"image/png\"}')
   on conflict do nothing" >/dev/null

checkout() {  # $1 token, $2 slot_key, $3 oib
  curl -s -w '\n%{http_code}\n' -XPOST "$API/functions/v1/pinka-contribute" \
    -H "Authorization: Bearer $1" -H 'content-type: application/json' -d @- <<JSON
{"campaign_id":"$CAMPAIGN","slot_keys":["$2"],
 "sponsor":{"brand":"E2E Brand","tagline":"Rečenica <b>bez</b> HTML-a.","link_url":"https://e2e.example.com",
   "logo_path":${4:-null},"terms_accepted":true,
   "buyer":{"company":"E2E d.o.o.","oib":${3:-null},"email":"racuni@e2e.example.com",
            "address":{"street":"Ilica 1","city":"Zagreb","postal_code":"10000"},"reference":"PO-1"}}}
JSON
}

webhook() {  # $1 type, $2 sid, $3 amount_cents
  local id="msg_$(date +%s%N)" ts body sig
  ts=$(date +%s)
  body="{\"type\":\"$1\",\"sid\":\"$2\",\"amount_received_cents\":$3,\"forward_tx_hash\":\"0xe2e$RANDOM\"}"
  sig=$(printf '%s' "$id.$ts.$body" | openssl dgst -sha256 -hmac "$WEBHOOK_KEY" -binary | base64)
  curl -s -w ' %{http_code}' -XPOST "$API/functions/v1/pinka-webhook" -H 'content-type: application/json' \
    -H "webhook-id: $id" -H "webhook-timestamp: $ts" -H "webhook-signature: v1,$sig" -d "$body"
}
# Webhook radi račun/e-poštu IZA odgovora (EdgeRuntime.waitUntil) → čekaj stanje.
wait_for() {  # $1 sql koji vraća 't' kad je gotovo
  for _ in $(seq 1 30); do [ "$(q "$1")" = t ] && return 0; sleep 0.5; done
  fail "timeout: $1"
}
calls() { curl -s "$MOCK/_calls" | python3 -c "import json,sys; c=json.load(sys.stdin); print(sum(1 for x in c if $1))"; }

# ── 1. checkout ─────────────────────────────────────────────────────────────
out=$(checkout "$T1" "$K_OK" '"12345678903"' "\"$UID1/logo.png\"")
code=$(tail -1 <<<"$out"); json=$(head -1 <<<"$out")
[ "$code" = 200 ] || fail "checkout $code $json"
SID=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["amount_cents"]==8000, d; print(d["sid"])' "$json")
CID=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["contribution_id"])' "$json")
echo "OK — checkout 200, 80 € određuje server, sid=$SID"

# ── 2. utrka kroz HTTP: dva kupca, isti trenutak → 200 + 409 ────────────────
checkout "$T2" "$K_RACE" > /tmp/e2e_r2.$$ & checkout "$T3" "$K_RACE" > /tmp/e2e_r3.$$ & wait
codes=$(tail -qn1 /tmp/e2e_r2.$$ /tmp/e2e_r3.$$ | sort | tr '\n' ' ')
SID_RACE=$(cat /tmp/e2e_r2.$$ /tmp/e2e_r3.$$ | grep -m1 '"sid"' | python3 -c 'import json,sys; print(json.load(sys.stdin)["sid"])' || true)
[ "$codes" = "200 409 " ] || fail "utrka: $codes $(cat /tmp/e2e_r2.$$ /tmp/e2e_r3.$$)"
grep -h slot_taken /tmp/e2e_r2.$$ /tmp/e2e_r3.$$ >/dev/null || fail "409 bez slot_taken"
rm -f /tmp/e2e_r2.$$ /tmp/e2e_r3.$$
echo "OK — paralelni checkout: 200 + 409 slot_taken"

# ── 3. validacija → 400 ─────────────────────────────────────────────────────
out=$(checkout "$T2" "$K_UNDER" '"12345678901"'); [ "$(tail -1 <<<"$out")" = 400 ] || fail "neispravan OIB nije 400"
grep -q 'invalid_sponsor:buyer_oib' <<<"$out" || fail "$out"
echo "OK — neispravan OIB → 400 invalid_sponsor:buyer_oib"

# ── 4. uplata → sold → živi view → račun → e-pošta ──────────────────────────
r=$(webhook intent.paid "$SID" 8000); [[ "$r" == *' 200' ]] || fail "webhook $r"
[ "$(q "select state from pinka_finance.slots where slot_key='$K_OK'")" = sold ] || fail "slot nije sold"
wait_for "select invoice_state = 'sent' from pinka_finance.contributions where payment_intent_sid='$SID'"
live=$(curl -s "$API/rest/v1/public_live_moments?slot_key=eq.$K_OK" -H "apikey: $ANON_KEY" -H 'Accept-Profile: pinka_finance')
python3 - "$live" <<'PY' || fail "živi view: $live"
import json, sys
rows = json.loads(sys.argv[1]); assert len(rows) == 1, rows; r = rows[0]
assert r["brand"] == "E2E Brand" and r["link_url"] == "https://e2e.example.com" and r["start_sec"] == 45, r
assert r["logo_url"].endswith("/sponsor-logos/" + r["logo_path"]), r
assert not any(k.startswith("buyer") or k.startswith("amount") for k in r), r
PY
echo "OK — anon REST: public_live_moments vraća trenutak, bez buyer_*"

[ "$(calls "x['path']=='/api/v1/racun' and x['status']==201 and x['idempotencyKey']=='$CID' and x['body']['tip']=='ERACUN_B2B'")" = 1 ] \
  || fail "nema točno jednog ERACUN_B2B poziva: $(curl -s $MOCK/_calls)"
[ "$(calls "x['path'].endswith('/posalji-eracun')")" = 1 ] || fail "posalji-eracun"
[ "$(calls "x['path']=='/emails' and 'Prodan' in x['body']['subject']")" = 1 ] || fail "nema e-pošte vlasniku"
calls "x['path']=='/emails' and '&lt;b&gt;' in x['body']['html'] and '/sponsor-moderate?c=$CID' in x['body']['html']" | grep -qx 1 \
  || fail "e-pošta ne escapea kreativu ili nema link za povlačenje"
[ "$(q "select invoice_state||':'||invoice_racun_id from pinka_finance.contributions where id='$CID'")" = "sent:100" ] \
  || fail "invoice_state: $(q "select invoice_state, invoice_last_error from pinka_finance.contributions where id='$CID'")"
echo "OK — fiskal: 1 × POST /api/v1/racun (ERACUN_B2B, Idempotency-Key=$CID, prošao pravu shemu), poslan, vlasnik obaviješten"

# ── 5. DUPLI intent.paid + payment.late → nema drugog računa ni e-pošte ─────
webhook intent.paid "$SID" 8000 >/dev/null
webhook payment.late "$SID" 8000 >/dev/null
sleep 2   # pozadinski rad dupliciranih isporuka
[ "$(calls "x['path']=='/api/v1/racun'")" = 1 ] || fail "dupli webhook je ponovno zvao fiskal"
[ "$(calls "x['path']=='/emails'")" = 1 ] || fail "dupli webhook je ponovno slao e-poštu"
echo "OK — dupli intent.paid / payment.late: i dalje 1 račun, 1 e-pošta"

# ── 5b. kupac BEZ OIB-a → RACUN (ne eRačun) + PDF e-poštom ─────────────────
webhook intent.paid "$SID_RACE" 5000 >/dev/null
wait_for "select invoice_state = 'sent' from pinka_finance.contributions where payment_intent_sid='$SID_RACE'"
[ "$(calls "x['path']=='/api/v1/racun' and x['status']==201 and x['body']['tip']=='RACUN' and 'oib' not in x['body']['kupac']")" = 1 ] \
  || fail "kupac bez OIB-a nije dobio RACUN: $(curl -s $MOCK/_calls)"
[ "$(calls "x['path'].endswith('/posalji') and x['body']['na']=='racuni@e2e.example.com'")" = 1 ] || fail "RACUN nije poslan e-poštom"
echo "OK — kupac bez OIB-a: RACUN (prošao pravu shemu), PDF e-poštom na adresu kupca"

# ── 6. izgubljen odgovor fiskala: retry s istim ključem = isti dokument ─────
q "update pinka_finance.contributions set invoice_state='failed', invoice_racun_id=null, invoice_next_at=null
   where id='$CID'" >/dev/null
r=$(curl -s -XPOST "$API/functions/v1/sponsor-cron" -H "x-cron-secret: $CRON_SECRET")
[ "$(calls "x['path']=='/api/v1/racun' and x['status']==200")" = 1 ] || fail "retry nije dobio Idempotent-Replay: $r"
[ "$(q "select invoice_racun_id from pinka_finance.contributions where id='$CID'")" = 100 ] || fail "retry je stvorio novi račun"
echo "OK — retry (cron) s istim Idempotency-Key: replay istog računa #100"

# ── 7. MANJAK → trenutak se ne dodjeljuje + alarm ───────────────────────────
out=$(checkout "$T2" "$K_UNDER"); [ "$(tail -1 <<<"$out")" = 200 ] || fail "checkout 2: $out"
SID2=$(head -1 <<<"$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sid"])')
webhook intent.paid "$SID2" 100 >/dev/null
sleep 2   # alarm ide u pozadini
[ "$(q "select state||':'||underpaid from pinka_finance.contributions where payment_intent_sid='$SID2'")" = "failed:true" ] \
  || fail "manjak nije failed:true"
[ "$(q "select state from pinka_finance.slots where slot_key='$K_UNDER'")" = free ] || fail "manjak je zadržao trenutak"
[ "$(calls "x['path']=='/emails' and 'ALARM' in x['body']['subject']")" = 1 ] || fail "nema alarma"
CID2=$(q "select id from pinka_finance.contributions where payment_intent_sid='$SID2'")
[ "$(calls "x['path']=='/api/v1/racun' and x['idempotencyKey']=='$CID2'")" = 0 ] || fail "manjak je dobio račun"
echo "OK — manjak (1,00 € od 50 €): failed+underpaid, trenutak slobodan, alarm, bez računa"

# ── 8. povlačenje kreative iz e-pošte ───────────────────────────────────────
LINK=$(curl -s "$MOCK/_calls" | python3 -c "
import json,sys,re
c=[x for x in json.load(sys.stdin) if x['path']=='/emails' and 'Prodan' in x['body']['subject']][0]
print(re.search(r'href=\"([^\"]+)\"', c['body']['html']).group(1).replace('&amp;','&'))")
T=$(sed -E 's/.*[?&]t=([0-9a-f]+).*/\1/' <<<"$LINK")
[ "$(curl -s -o /dev/null -w '%{http_code}' "$LINK")" = 200 ] || fail "GET moderate"
[ "$(q "select message_hidden from pinka_finance.contributions where id='$CID'")" = f ] || fail "GET je promijenio stanje"
[ "$(curl -s -o /dev/null -w '%{http_code}' -XPOST "$API/functions/v1/sponsor-moderate" -d "c=$CID&t=bad&hidden=1")" = 403 ] \
  || fail "loš token prošao"
curl -s -o /dev/null -XPOST "$API/functions/v1/sponsor-moderate" -d "c=$CID&t=$T&hidden=1"
[ "$(q "select message_hidden from pinka_finance.contributions where id='$CID'")" = t ] || fail "POST nije povukao"
[ "$(curl -s "$API/rest/v1/public_live_moments?slot_key=eq.$K_OK" -H "apikey: $ANON_KEY" -H 'Accept-Profile: pinka_finance')" = "[]" ] \
  || fail "povučen trenutak i dalje u viewu"
echo "OK — povlačenje: GET ne mijenja ništa, loš token 403, POST skida trenutak"

# ── 9. cron bez tajne ───────────────────────────────────────────────────────
[ "$(curl -s -o /dev/null -w '%{http_code}' -XPOST "$API/functions/v1/sponsor-cron")" = 401 ] || fail "cron bez tajne"
echo "OK — sponsor-cron bez x-cron-secret → 401"

echo "E2E PROŠAO"
