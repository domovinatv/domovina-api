# Događaji (E2+E3+E4+U1) — curl test scenarij

> Reference: safe-wallet-monorepo `docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md` +
> `handoffs/dogadjaji-2-backend.md` + `handoffs/dogadjaji-3-qr-checkin.md` +
> `handoffs/dogadjaji-4-organizator.md`.
> Migracije: `20260716120000/120100/120200_events_ticketing_*`, `20260717120000_events_checkin`,
> `20260717130000_events_organizer`, `20260803120000_events_stripe_rail` (U1).
> Funkcije: `events-order`, `events-confirm`, `events-tickets`, `events-feed`,
> `events-checkin`, `events-organizer`, `events-stripe-intent`, `events-stripe-confirm`.
>
> Scenarij pokriva kriterije prihvaćanja E2: create_event → order (rezervacija) →
> onchain confirm → paid + N ulaznica; idempotencija; oversell odbijen; TTL istek
> oslobađa rezervaciju; imenska bez imena odbijena. E3 (§7): check-in — prvi sken
> ✅, drugi sken istog QR-a ⛔ s vremenom prvog ulaska; ne-admin odbijen. E4 (§9):
> organizator self-service — draft bez Safe-a, publish gating (allowlist + Safe,
> server-side), update/tier lock, DAC7 zapis (RLS), feed filtriranje/paginacija.
> U1 (§11): Stripe rail — HMAC gate, direct-charge intent, confirm + izdavanje,
> idempotencija u bazi, poslovni ne-uspjesi kao status, onchain put nepromijenjen.

## 0. Okruženje

Lokalni stack (`supabase start`; API na `:55321`) ili prod (`https://api.domovina.ai`).

```bash
export API=http://127.0.0.1:55321
export SERVICE_ROLE=<service_role key>       # supabase status | grep service_role
export FN=$API/functions/v1
# psql u lokalni stack:
alias lpsql='psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres"'
```

Za `events-confirm` protiv lokalnog stacka treba EURe tx na Gnosisu — koristi se
stvarni tx hash uplate na organizatorov Safe (funkcija čita `GNOSIS_RPC_URL`,
public RPC je default). Bez stvarne uplate: korak 4 se simulira direktnim
pozivom `confirm_ticket_order` RPC-a kroz psql (označeno ispod).

## 1. Priprema: org account + aktivan event

`create_event` je security INVOKER — RLS traži `has_role_on_account(account, 'admin')`
+ KYC za insert kampanje. Za smoke test najjednostavnije kroz psql (service put):

```sql
-- lpsql
-- org account postoji iz core seeda ili se koristi postojeći personal account id:
select id, name from public.accounts limit 5;

set role service_role;  -- ili ostani postgres; create_event je invoker, insert prolazi bez RLS-a za superusera
select pinka_finance.create_event(
  p_id                  => '00000000-0000-4000-8000-000000000e01',
  p_account_id          => '<ACCOUNT_ID>',
  p_title               => 'Money Motion 2027 (test)',
  p_destination_address => '0x1111111111111111111111111111111111111111',
  p_venue_name          => 'Zagrebački velesajam',
  p_venue_city          => 'Zagreb',
  p_event_type          => 'konferencija',
  p_starts_at           => '2027-03-10T08:00:00+01',
  p_ends_at             => '2027-03-11T20:00:00+01',
  p_description_hr      => 'Testni event',
  p_organizer_name      => 'Money Motion',
  p_organizer_email     => 'tickets@money-motion.eu',
  p_visibility          => 'public',
  p_tiers               => '[
    {"title":"Super Early Bird","price_cents":14900,"inventory_total":3,"imenska":true},
    {"title":"Studentska","price_cents":4900,"inventory_total":100,"imenska":true,
     "sale_end":"2026-01-01T00:00:00Z"}
  ]'::jsonb
);
reset role;

-- idempotencija: isti poziv drugi put vraća {"existing": true, "event_created": false}

-- aktivacija (kampanja se rađa kao draft; write guard traži pravi Safe):
update pinka_finance.campaigns
   set state = 'active'
 where id = '00000000-0000-4000-8000-000000000e01';

-- tier id-evi za nastavak:
select id, title, imenska, inventory_total, inventory_claimed, sale_end
  from pinka_finance.campaign_tiers
 where campaign_id = '00000000-0000-4000-8000-000000000e01';
```

## 2. Feed (javni katalog za wallet)

```bash
curl -s $FN/events-feed | jq
# očekivano: events[0].slug = money-motion-2027-test, tiers s price_cents/imenska/sale_*
```

## 3. Narudžba (rezervacija s TTL-om)

```bash
export TIER=<SUPER_EARLY_BIRD_TIER_UUID>
export ORDER=$(uuidgen | tr 'A-Z' 'a-z')

curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id": "'$ORDER'",
  "campaign_id": "00000000-0000-4000-8000-000000000e01",
  "tier_id": "'$TIER'",
  "quantity": 2,
  "holders": [{"full_name":"Ana Anić","email":"ana@example.com"},
              {"full_name":"Ivo Ivić"}],
  "payer_address": "0x2222222222222222222222222222222222222222"
}' | jq
# očekivano: {"order_id":..., "state":"pending", "amount_cents":29800,
#             "destination_address":"0x1111…", "expires_at":..., "existing":false}
```

Provjere:

```bash
# rezervacija vidljiva ODMAH (prije plaćanja):
# lpsql: select inventory_claimed from pinka_finance.campaign_tiers where id = '<TIER>';
# → 2

# idempotencija: ISTI payload ponovno → existing:true, inventory NE raste
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '…isti…' | jq .existing

# oversell odbijen (inventory_total=3, claimed=2 → qty 2 ne stane):
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id": "'$(uuidgen | tr 'A-Z' 'a-z')'",
  "campaign_id": "00000000-0000-4000-8000-000000000e01",
  "tier_id": "'$TIER'", "quantity": 2,
  "holders": [{"full_name":"X"},{"full_name":"Y"}]
}' | jq
# → {"error":"tier_sold_out"} (HTTP 400)

# imenska bez potpunih imena odbijena:
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id": "'$(uuidgen | tr 'A-Z' 'a-z')'",
  "campaign_id": "00000000-0000-4000-8000-000000000e01",
  "tier_id": "'$TIER'", "quantity": 1, "holders": []
}' | jq
# → {"error":"holders_incomplete"}

# tier izvan prodajnog prozora (Studentska, sale_end u prošlosti):
# → {"error":"sale_ended"}
```

## 4. Uplata + confirm

Stvarni put: kupac plati EURe (Gnosis) na `destination_address`, app pošalje:

```bash
curl -s -X POST $FN/events-confirm -H 'content-type: application/json' -d '{
  "order_id": "'$ORDER'",
  "tx_hash": "0x<STVARNI_TX>"
}' | jq
# not mined → {"ok":true,"mined":false,"status":"not_mined"} (retry)
# krivi primatelj / premali iznos → {"ok":true,"mined":true,"status":"no_matching_transfer"}
# uspjeh → {"ok":true,"mined":true,"status":"paid","serials":["MON-000001","MON-000002"]}
# PONOVLJENI confirm istog tx-a → {"status":"already_paid"} — ništa se ne duplicira
#
# Poslovni ne-uspjesi RPC-a se vraćaju kao status (NE exception — exception bi
# rollbackao audit event za ručno sparivanje):
#   {"status":"tx_already_credited"}  — (tx,log) već kreditiran drugoj contribution
#   {"status":"amount_insufficient","expected_cents":…,"received_cents":…}
#   {"status":"expired_sold_out"}     — istekla rezervacija, inventory u međuvremenu pun
```

Simulacija bez stvarnog tx-a (lokalni smoke; preskače Gnosis verifikaciju,
testira RPC idempotenciju + izdavanje):

```sql
-- lpsql
select pinka_finance.confirm_ticket_order(
  '<ORDER>'::uuid,
  '0x' || repeat('ab', 32),  -- 64 hex chara
  0, '0x2222222222222222222222222222222222222222', 29800
);
-- → {"status":"paid","serials":["MON-000001","MON-000002"]}
-- drugi poziv istog: {"status":"already_paid"} ; drugi (tx,log) na istoj narudžbi: exception order_already_paid

select state, forward_tx_hash, onchain_log_index from pinka_finance.contributions where id = '<ORDER>';
select serial, holder_name, state, qr_token_hash is not null as has_hash, qr_token_once is not null as undelivered
  from pinka_finance.tickets where contribution_id = '<ORDER>';
```

## 5. Dostava ulaznica (QR tokeni jednokratno)

```bash
curl -s -X POST $FN/events-tickets -H 'content-type: application/json' \
  -d '{"order_ids":["'$ORDER'"]}' | jq
# 1. poziv: tickets[].qr_token = 64-hex string (jednokratna dostava)
# 2. poziv: tickets[].qr_token = null — u bazi je ostao samo sha256 hash
```

## 6. TTL istek oslobađa rezervaciju

```bash
export ORDER2=$(uuidgen | tr 'A-Z' 'a-z')
# kreiraj narudžbu qty=1 (korak 3), zatim:
# lpsql:
#   update pinka_finance.contributions
#      set reserve_expires_at = now() - interval '1 minute'
#    where id = '<ORDER2>';
# bilo koji sljedeći events-order/events-tickets poziv pokreće expire:
curl -s -X POST $FN/events-tickets -H 'content-type: application/json' -d '{"order_ids":["'$ORDER2'"]}' | jq '.orders[0].state'
# → "expired"; inventory_claimed se smanjio za quantity (provjeri u psql)
```

## 7. Check-in (E3) — skener ulaza

`events-checkin` traži GoTrue JWT org **admina** organizatorovog accounta
(Authorization header); autorizacija je isključivo server-side u `redeem_ticket`
RPC-u (`has_role_on_account(campaign.account_id, 'admin')`). App šalje goli
64-hex token; funkcija tolerira i cijeli QR payload s `dgdj1:` prefiksom.

```bash
# JWT org admina (lokalni stack; korisnik mora biti admin member org accounta
# koji je vlasnik kampanje — v. public.accounts_memberships):
export ADMIN_JWT=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H 'content-type: application/json' \
  -d '{"email":"admin@momo.test","password":"…"}' | jq -r .access_token)

export QR_TOKEN=<64-hex token iz koraka 5>

# prvi sken → ✅ checked_in s imenom holdera, tierom i brojačem ulazaka:
curl -s -X POST $FN/events-checkin -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{"qr_token":"'$QR_TOKEN'"}' | jq
# → {"status":"checked_in","serial":"MON-000001","holder_name":"Ana Anić",
#    "tier_title":"Super Early Bird","event_title":…,"checked_in_at":…,
#    "checked_in_count":1}

# drugi sken ISTOG tokena → ⛔ already_checked_in s vremenom i skenerom PRVOG
# ulaska (anti-double-entry; idempotentno — ništa se ne mijenja u bazi):
curl -s -X POST $FN/events-checkin -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{"qr_token":"'$QR_TOKEN'"}' | jq
# → {"status":"already_checked_in","checked_in_at":<prvi ulaz>,
#    "checked_in_by_email":"admin@momo.test","checked_in_count":1,…}

# bez JWT-a → 401 not_authenticated; s JWT-om korisnika koji NIJE org admin
# → 403 not_authorized (RLS/grant test); nepostojeći token → {"status":"not_found"}
curl -s -X POST $FN/events-checkin -H 'content-type: application/json' \
  -d '{"qr_token":"'$QR_TOKEN'"}' | jq          # → 401
```

Simulacija kroz psql (bez GoTrue; testira RPC autorizaciju + idempotenciju):

```sql
-- lpsql
select set_config('request.jwt.claims',
  '{"sub":"<ADMIN_USER_UUID>","role":"authenticated"}', false);
set role authenticated;
select pinka_finance.redeem_ticket('<QR_TOKEN>');   -- {"status":"checked_in",…,"checked_in_count":1}
select pinka_finance.redeem_ticket('<QR_TOKEN>');   -- {"status":"already_checked_in",…} — drugi sken
-- ne-admin sub → ERROR not_authorized; bez claims → ERROR not_authenticated
-- krivi format → ERROR invalid_token; nepoznat token → {"status":"not_found"}

-- void (organizatorsko poništenje; samo issued → void):
select pinka_finance.void_ticket('<TICKET_UUID>');  -- {"status":"voided"}
-- redeem poništene → {"status":"void"}; ponovni void → {"status":"already_void"}
-- void iskorištene → {"status":"already_checked_in"} (ulaz se već dogodio)
reset role;

-- audit trag (uklj. pokušaje dvostrukog ulaska — INSERT preživi jer se poslovni
-- ishodi vraćaju kao status, ne exception):
select event_type, payload from pinka_finance.contribution_events
 where event_type in ('ticket.checked_in','ticket.checkin_duplicate','ticket.voided')
 order by created_at desc;
```

## 8. Nesparena uplata (§8 reconciliation rub)

Ako je cron indexer (`pinka-onchain-ingest`) već kreditirao isti `(tx_hash,
log_index)` kao generičku donaciju, `events-confirm` vraća
`{"status":"tx_already_credited"}` i upiše `ticket_order.match_conflict` event u
`contribution_events` → red za ručno sparivanje:

```sql
select * from pinka_finance.contribution_events
 where event_type in ('ticket_order.match_conflict','ticket_order.underpaid','ticket_order.expired_sold_out')
 order by created_at desc;
```

## 9. Organizator self-service (E4)

`events-organizer` traži GoTrue JWT (isti "pristupni token" obrazac kao
events-checkin); autorizacija je server-side u RPC-ima: `create_event`/
`update_event` su INVOKER (RLS: org admin + KYC), `publish_event` je DEFINER
(org admin + **allowlist** + pravi Safe). Jedna funkcija, POST s `action` poljem.

```bash
# JWT org admina (v. §7); org account mora imati admin membership + KYC zapis.
export ADMIN_JWT=…
export ORG=aaaaaaaa-….   # org account id
export EV=$(uuidgen | tr 'A-Z' 'a-z')

# 9.1 pregled (org accounti + allowlist/DAC7 status + moji eventi uklj. draftove):
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{"action":"overview"}' | jq
# → {"accounts":[{"id":…,"allowlisted":false,"has_record":false,…}],"events":[…]}

# 9.2 kreiranje eventa BEZ Safe adrese (draft; placeholder nulta adresa):
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{
  "action":"create", "event_id":"'$EV'", "account_id":"'$ORG'",
  "title":"BlockSplit 2027", "venue_name":"MEDILS", "venue_city":"Split",
  "event_type":"kamp", "description_hr":"Unconference summer camp.",
  "tiers":[{"title":"Stay paket","price_cents":39900,"inventory_total":40,"imenska":true}]
}' | jq
# → {"id":…, "slug":"blocksplit-2027", "existing":false, "event_created":true}
# kampanja je draft + private — javni feed je NE prikazuje

# 9.3 publish gating — allowlist odbijanje (kriterij 3; server-side test):
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' \
  -d '{"action":"publish","campaign_id":"'$EV'"}' | jq
# → {"error":"organizer_not_allowlisted"} (HTTP 400) — org NIJE na allowlistu

# operater dodaje org na allowlist (ručni flag za pilot; SAMO service/psql):
# lpsql: insert into pinka_finance.organizer_allowlist (account_id, note)
#        values ('<ORG>', 'pilot: Luka Sucic');

# 9.4 publish gating — bez pravog Safe-a i dalje nema objave:
curl -s … -d '{"action":"publish","campaign_id":"'$EV'"}' | jq
# → {"error":"campaign_destination_missing"} — nulta/nevaljana adresa

# 9.5 organizator upiše svoj Safe (kreiran kroz app onboarding) + publish:
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{
  "action":"update", "campaign_id":"'$EV'",
  "destination_address":"0x1111111111111111111111111111111111111111"
}' | jq
curl -s … -d '{"action":"publish","campaign_id":"'$EV'"}' | jq
# → {"campaign_id":…, "state":"active", "visibility":"public"}
# event se ODMAH pojavi u javnom feedu (korak 2) bez izmjene koda/configa

# 9.6 tier lock nakon objave (kupci su kupovali pod tim uvjetima):
#   update s promijenjenim price_cents postojećeg tiera → {"error":"tier_locked"}
#   inventory_total < inventory_claimed → {"error":"inventory_below_claimed"}
#   novi tier (bez "id") se SMIJE dodati (npr. Early Bird → Regular faza)

# 9.7 zatvaranje prodaje: {"action":"publish","campaign_id":…,"target_state":"closed"}
#   closed → closed/active → {"error":"invalid_state_transition"}

# 9.8 DAC7 zapis organizatora (SENSITIVE; nikad u feedu):
curl -s -X POST $FN/events-organizer -H "Authorization: Bearer $ADMIN_JWT" \
  -H 'content-type: application/json' -d '{
  "action":"record_upsert", "account_id":"'$ORG'",
  "legal_name":"UBIK udruga", "oib":"12345678901",
  "address_line":"Ulica 1", "city":"Split", "postal_code":"21000",
  "financial_identifier_type":"safe_address",
  "financial_identifier":"0x1111111111111111111111111111111111111111"
}' | jq
# → {"account_id":…, "saved":true}
# RLS test (kriterij 4): drugi authenticated user vidi 0 redaka; anon nema ni
# select grant (permission denied); ne-admin record_upsert → 403 not_authorized

# 9.9 ne-admin JWT na publish/update → {"error":"not_authorized"} (HTTP 403)
```

Simulacija kroz psql (bez GoTrue; sve gore + guardovi):

```sql
-- lpsql
select set_config('request.jwt.claims',
  '{"sub":"<ADMIN_USER_UUID>","role":"authenticated"}', false);
set role authenticated;
select pinka_finance.publish_event('<EV>');          -- organizer_not_allowlisted / campaign_destination_missing / OK
select pinka_finance.update_event(p_campaign_id => '<EV>', p_title => 'Novi naslov');
select pinka_finance.organizer_overview();
select pinka_finance.upsert_organizer_record(…);
reset role;

-- destination lock (anti-rug): nakon prve PLAĆENE uplate update_event s novom
-- adresom → exception campaign_destination_locked (campaigns_write_guard)
```

## 10. Feed filtriranje/paginacija (E4)

```bash
curl -s "$FN/events-feed?grad=split" | jq '.events[].slug'      # case-insensitive substring
curl -s "$FN/events-feed?from=2027-01-01&to=2027-12-31" | jq    # events.starts_at prozor
curl -s "$FN/events-feed?limit=1&offset=1" | jq '.limit, .offset, (.events|length)'
# default limit 50, max 100; bez parametara = ponašanje kao E2 (prvih 50)
```

## 11. Stripe rail (U1) — offchain naplata narudžbe

> Migracija: `20260803120000_events_stripe_rail.sql`.
> Funkcije: `events-stripe-intent`, `events-stripe-confirm` (obje `verify_jwt=false` + **HMAC**).
> Plan: `domovina-ulaznice/docs/handoffs/u1-stripe-rail-backend.md`.

Isti tok kao onchain (§3–§5), ali uplatu potvrđuje Stripe umjesto blockchaina.
**Backend nikad ne razgovara sa Stripeom** — Stripe zove isključivo Cloudflare
Worker (`domovina-ulaznice`), koji verificira webhook potpis i tek onda poziva
`events-stripe-confirm`. Naplata je Connect **direct charge** na račun
organizatora, 0 % provizije: novac ne prolazi kroz platformu.

### 11.0 Autentikacija: HMAC (jedina razlika prema onchain putu)

Kod `events-confirm` autorizacija je sam blockchain. Ovdje takvog dokaza nema —
jedini dokaz uplate je Stripe potpis koji je verificirao Worker. Zato obje
funkcije traže dijeljenu tajnu:

```
header:  x-ulaznice-signature: sha256=<hex(hmac_sha256(EVENTS_STRIPE_CONFIRM_SECRET, RAW_BODY))>
potpis:  nad SIROVIM tijelom zahtjeva (byte-for-byte), usporedba konstantnog vremena
bez tajne na serveru → 503 (nikad "prolazi jer tajne nema")
krivi/nedostajući potpis → 401, baza se NE dira
```

Replay se namjerno ne brani timestampom: ponovljeni identičan zahtjev je no-op
jer je idempotencija u bazi (unique `(payment_rail, external_payment_ref)`).

```bash
export SECRET=<EVENTS_STRIPE_CONFIRM_SECRET>
sign() { printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.*= /sha256=/'; }
post() { curl -s -X POST "$1" -H 'content-type: application/json' \
              -H "x-ulaznice-signature: $(sign "$2")" -d "$2" | jq; }
```

### 11.1 Priprema: Stripe stanje organizatora

`organizer_payment_rails` piše **isključivo service_role** (Worker iz
`account.updated` webhooka). Za smoke test kroz psql:

```sql
-- lpsql
insert into pinka_finance.organizer_payment_rails
  (account_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled, invoice_provider)
values ('<ORG_ACCOUNT_ID>', 'acct_1TestOrganizator', true, true, 'fira')
on conflict (account_id) do update
  set stripe_account_id = excluded.stripe_account_id,
      stripe_charges_enabled = excluded.stripe_charges_enabled;

-- RLS: anon → permission denied; authenticated ne-član → 0 redaka;
--      org admin → vidi svoj redak, ali UPDATE → permission denied
```

### 11.2 Narudžba (nepromijenjeni `events-order` iz §3)

```bash
export ORDER=$(uuidgen | tr 'A-Z' 'a-z')
curl -s -X POST $FN/events-order -H 'content-type: application/json' -d '{
  "order_id": "'$ORDER'", "campaign_id": "'$EV'", "tier_id": "'$TIER'", "quantity": 2,
  "holders": [{"full_name":"Web Kupac","email":"web@example.com"},{"full_name":"Drugi Gost"}]
}' | jq
# → pending, amount_cents 29800; inventory_claimed +2 ODMAH (rezervacija, TTL 20 min)
```

### 11.3 `events-stripe-intent` — podaci za Checkout

```bash
post $FN/events-stripe-intent "{\"order_id\":\"$ORDER\"}"
# → {"order_id":…, "amount_cents":29800, "currency":"eur", "quantity":2,
#    "expires_at":…, "buyer_email":null,
#    "tier":{"id":…,"title":"Redovna","price_cents":14900,"imenska":true},
#    "event":{"campaign_id":…,"title":…,"slug":…,"starts_at":…,"ends_at":…,
#             "timezone":"Europe/Zagreb","venue_name":…,"venue_city":…},
#    "stripe_account_id":"acct_1TestOrganizator",   ← JEDINI odgovor koji ga vraća
#    "charges_enabled":true, "invoice_provider":"fira"}

# krivi HMAC → {"error":"bad_signature"} (HTTP 401)
# narudžba već plaćena → {"error":"order_not_pending","state":"paid"} (400)
# istekla rezervacija  → {"error":"order_expired"} (400)
# organizator bez charges_enabled → {"error":"organizer_charges_disabled"} (400)
# organizator bez acct_…          → {"error":"organizer_not_connected"} (400)
```

Invariant (`rodjendaonice/worker/bookable.ts`): bez povezanog računa i bez
`charges_enabled` Checkout session se **nikad** ne kreira. `acct_…` ne izlazi
nigdje drugdje — javni feed dobiva izvedeni boolean.

### 11.4 `events-stripe-confirm` — kreditiranje + izdavanje ulaznica

```bash
CB="{\"order_id\":\"$ORDER\",\"external_ref\":\"pi_HTTP_1\",\"amount_cents\":29800,\"payer_email\":\"web@example.com\"}"

# 5. KRIVI HMAC PRVO — baza mora ostati netaknuta:
curl -s -X POST $FN/events-stripe-confirm -H 'content-type: application/json' \
  -H "x-ulaznice-signature: sha256=$(printf 'a%.0s' {1..64})" -d "$CB" | jq
# → {"error":"bad_signature"} (401)
# bez headera → {"error":"missing_signature"} (401)
# lpsql: select state, payment_rail, external_payment_ref from pinka_finance.contributions where id='<ORDER>';
#        → pending | onchain | null   ← ništa se nije dogodilo, 0 ulaznica

# 3. valjan HMAC → paid + N ulaznica + JEDNOKRATNI QR tokeni:
post $FN/events-stripe-confirm "$CB"
# → {"ok":true,"status":"paid","serials":["SUS-000004","SUS-000005"],"order_id":…,
#    "tickets":[{"serial":"SUS-000004","holder_name":"Web Kupac",
#                "holder_email":"web@example.com","state":"issued",
#                "qr_token":"<64-hex>"}, …]}

# 4. isti confirm ponovno → already_paid, BEZ novih ulaznica:
post $FN/events-stripe-confirm "$CB"
# → {"ok":true,"status":"already_paid","serials":[…isti…],
#    "tickets":[{…,"qr_token":null}, …]}   ← tokeni su već isporučeni
# lpsql: select count(*), count(qr_token_once) from pinka_finance.tickets
#        where contribution_id = '<ORDER>';   → 2 | 0
```

⚠️ **QR tokeni su jednokratni.** `events-stripe-confirm` ih povlači kroz
postojeći `deliver_ticket_orders` (isti invariant kao `events-tickets`): u bazi
trajno ostaje samo sha256 hash. Namjerno se poziva i na `already_paid` — ako je
prvi confirm prošao, a odgovor nije stigao do Workera, retry webhooka i dalje
isporuči tokene (crash recovery). Nakon prve **uspješne** dostave `qr_token` je
zauvijek `null`.

### 11.5 Poslovni ne-uspjesi: HTTP 200 + `status` (nikad exception)

Exception bi rollbackao audit zapis u `contribution_events` — v.
`13-lekcije-sesije-dogadjaji.md` §3. Worker na svaki od ovih statusa reagira
(refund / alarm / red za ručno sparivanje):

```bash
# 6. premali iznos:
post $FN/events-stripe-confirm "{\"order_id\":\"$ORDER2\",\"external_ref\":\"pi_HTTP_2\",\"amount_cents\":100}"
# → {"ok":true,"status":"amount_insufficient","expected_cents":14900,"received_cents":100}
#   audit: ticket_order.underpaid

# 7. isti external_ref na DRUGOJ narudžbi:
post $FN/events-stripe-confirm "{\"order_id\":\"$ORDER2\",\"external_ref\":\"pi_HTTP_1\",\"amount_cents\":14900}"
# → {"ok":true,"status":"tx_already_credited"}
#   audit: ticket_order.match_conflict (other_contribution_id) → ručno sparivanje

# 8. istekla rezervacija + tier u međuvremenu rasprodan:
# → {"ok":true,"status":"expired_sold_out"}
#   audit: ticket_order.expired_sold_out → Worker radi PUN REFUND (doc 03 §5)

# 8b. druga uplata na VEĆ plaćenu narudžbu (dvije checkout sesije, kupac naplaćen dvaput):
# → {"ok":true,"status":"duplicate_payment","credited_ref":"pi_HTTP_1"}
#   audit: ticket_order.duplicate_payment → Worker refunda drugu uplatu
#   ⚠️ odstupanje od onchain blizanca: confirm_ticket_order tu raisa
#      order_already_paid; kod Stripea je to stvarni novac pa mora ostati trag.
```

Simulacija bez HTTP-a (samo RPC — testira state machine i idempotenciju):

```sql
-- lpsql
select pinka_finance.confirm_ticket_order_offchain(
  '<ORDER>'::uuid, 'stripe', 'pi_TEST_1', 29800, 'kupac@example.com');
-- → {"status":"paid","serials":["SUS-000001","SUS-000002"]}
-- drugi poziv istog: {"status":"already_paid"}

-- idempotencija je u BAZI, ne u kodu — direktan pokušaj dupliranja pukne:
update pinka_finance.contributions
   set payment_rail = 'stripe', external_payment_ref = 'pi_TEST_1'
 where id = '<DRUGA_NARUDZBA>';
-- → ERROR: duplicate key value violates unique constraint "ux_contributions_external_payment"

-- validacija ulaza (programske greške = exception, kao i drugdje):
select pinka_finance.confirm_ticket_order_offchain('<ORDER>'::uuid,'onchain','pi_X_1',1,null);
-- → ERROR: invalid_rail          (rail mora biti 'stripe')
select pinka_finance.confirm_ticket_order_offchain('<ORDER>'::uuid,'stripe','x',1,null);
-- → ERROR: invalid_external_ref

-- grantovi: authenticated/anon NE smiju izvršiti RPC
set role authenticated;
select pinka_finance.confirm_ticket_order_offchain('<ORDER>'::uuid,'stripe','pi_Y_1',1,null);
-- → ERROR: permission denied for function confirm_ticket_order_offchain
reset role;
```

### 11.6 Onchain put ostaje nepromijenjen

```sql
-- lpsql — §4 scenarij i dalje prolazi identično:
select pinka_finance.confirm_ticket_order(
  '<ONCHAIN_ORDER>'::uuid, '0x' || repeat('ab', 32), 0,
  '0x2222222222222222222222222222222222222222', 14900);
-- → {"status":"paid","serials":[…]} ; drugi poziv → {"status":"already_paid"}

select id, state, payment_rail, external_payment_ref, forward_tx_hash is not null
  from pinka_finance.contributions where id = '<ONCHAIN_ORDER>';
-- → paid | onchain | null | t   ← default 'onchain' čuva postojeće ponašanje
```

## Deploy (prod — ručni korak)

```bash
./scripts/db-migrate.sh --dry-run     # pending events_ticketing + events_checkin + events_organizer
./scripts/db-migrate.sh               # idempotentne; drugi run = no-op
./scripts/deploy-functions.sh --only=events-order
./scripts/deploy-functions.sh --only=events-confirm
./scripts/deploy-functions.sh --only=events-tickets
./scripts/deploy-functions.sh --only=events-checkin
./scripts/deploy-functions.sh --only=events-organizer
./scripts/deploy-functions.sh --only=events-feed --restart -y

# E4 post-deploy (pilot): allowlist org accounta organizatora (psql, v. §9.3)
```

### Deploy Stripe raila (U1)

```bash
# 1. TAJNA PRIJE FUNKCIJA — bez nje funkcije vraćaju 503:
openssl rand -hex 32                          # → EVENTS_STRIPE_CONFIRM_SECRET
#    upisati u Coolify env edge-runtime servisa (ista vrijednost ide u
#    `wrangler secret put EVENTS_STRIPE_CONFIRM_SECRET` u domovina-ulaznice)

./scripts/db-migrate.sh --dry-run             # → 20260803120000_events_stripe_rail.sql
./scripts/db-migrate.sh
./scripts/deploy-functions.sh --only=events-stripe-intent
./scripts/deploy-functions.sh --only=events-stripe-confirm --restart -y

# 2. smoke na produkciji: intent bez potpisa MORA vratiti 401 (ne 200, ne 503)
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  https://api.domovina.ai/functions/v1/events-stripe-confirm -d '{}'   # → 401
```
