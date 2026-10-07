# Sponzorski trenuci — zaključak backend kruga (MVP `domovina_tv`)

*7.10.2026. Ugovor prema frontendu: [`sponzorski-trenuci-ugovor.md`](sponzorski-trenuci-ugovor.md).
Plan: `domovina.ai/docs/plans/2026-10-06-mvp-sponzorski-trenuci-domovina-tv.md`.*

**Ništa od ovoga nije na produkciji.** Sve je testirano lokalno. Puštanje je
§3 i čeka izričito „da".

---

## 1. Što je gotovo, a što je stubano

| Komad | Stanje | Gdje |
|---|---|---|
| `timeline` karta, `slots.youtube_id/start_sec/end_sec` | ✅ | migracija `20261007120000` §1 |
| Jedna karta po epizodi → **jedna kampanja + filtar po `youtube_id`**, `unique(campaign_id)` ostaje | ✅ odluka O1 u ugovoru | |
| `run_days` po zoni, `live_from/live_until` (trigger na prijelaz u `sold`), `expire_live_slots()` | ✅ | §2 |
| **Provjera iznosa**: manjak → `failed` + `underpaid`, trenutak otpušten, event + alarm e-poštom | ✅ | §6, `_shared/sponsor.ts` |
| Kreativa + kupac na `contributions`, OIB MOD 11,10, `sanitize_ugc`, https-only link, logo ≤ 200 kB | ✅ | §3–§5 |
| Checkout `pinka-contribute` + `sponsor`, iznos određuje server | ✅ | `pinka-contribute/index.ts` |
| `public_sponsor_moments` (izlog), `public_live_moments` (prikaz), `sponsor_order_status` | ✅ | §7–§8 |
| Račun: `ERACUN_B2B` + `/posalji-eracun` (s OIB-om), inače `RACUN` + `/posalji`; Idempotency-Key = contribution id; lease; retry s backoffom | ✅ protiv **mocka** | `_shared/sponsor.ts`, `sponsor-cron` |
| E-pošta vlasniku pri prodaji + link za povlačenje (GET = stranica, POST = povlačenje) | ✅ protiv mocka Resenda | `sponsor-moderate` |
| Seed: 7 epizoda, 79 trenutaka | ✅ cijene i `run_days` su **PLACEHOLDER** (P5) | migracija `20261007120100` |
| `payment.late` webhook se sada knjiži (prije se tiho ignorirao) | ✅ | `pinka-webhook` |
| **Pravi poziv na `fiskal-test`** | ⚠️ **stub** | nema `dfk_` ključa za test tenant, a tenant nisam otvarao (pravilo „ne dirati fiskal"). Mock validira tijelo **pravom zod shemom fiskala** (`racunModelShema`), pa je ugovor provjeren. Preostaje samo mreža i autentikacija. |
| Upload loga kroz Storage API | ⚠️ djelomično | lokalni storage container ne radi. RLS uploada (vlastita mapa, samo png/jpg/webp) testiran je u SQL-u; limit 200 kB nameće bucket. |
| pg_cron raspored | ⚠️ ručno | pg_cron je na produkciji dostupan, ali nije instaliran. Ispravnost ne ovisi o cronu (§4). |
| Frontend (izlog, checkout, `SponsoredMoment`, mjerenje) | ✗ | `domovina.ai`, radi po ugovoru |

### Testovi (svi zeleni lokalno)

| Test | Pokriva |
|---|---|
| `supabase/tests/20261007_sponzorski_trenuci.sql` (18 blokova) | seed; OIB; validacija; **manjak ne dodjeljuje trenutak**; puna uplata → `sold` + 30 dana; **dupli `intent.paid` = false**; **javni viewovi bez `buyer_*`/iznosa/`held`**; lease računa 1/0; povlačenje; **istek → `free`** (i bez crona); kasna uplata; donacije netaknute; RLS uploada; snapshot prodanih trenutaka preživi istek; limit 3 holda; grid: uplata iznad cijene i nepoznat iznos ostaju `paid` |
| `supabase/tests/20261007_sponzorski_trenuci_utrka.sh` | **12 i 20 paralelnih procesa na isti trenutak → 1 uspjeh, ostalo `slot_taken`, 0 deadlockova** |
| `supabase/tests/20261007_sponzorski_trenuci_e2e.sh` | pravi edge runtime: checkout 200 → **paralelni checkout 200 + 409** → potpisan `intent.paid` → `sold` → anon REST vidi trenutak → **1 × `POST /api/v1/racun`** (ERACUN_B2B) → **dupli `intent.paid` i `payment.late`: i dalje 1 račun, 1 e-pošta** → kupac bez OIB-a dobiva `RACUN` → izgubljen odgovor: retry daje replay istog računa → manjak + alarm, bez računa → povlačenje (GET ne mijenja, loš token 403) |

Postojeći `rail_gate`, `maksimir_*` testovi prolaze. Dva maksimir testa ovise o
redoslijedu pokretanja (stanje glasanja koje ostavi prethodni test); pojedinačno prolaze.

### `/code-review` (high) prije commita — 10 nalaza, svi ispravljeni

| Nalaz | Ispravak |
|---|---|
| Retry računa nakon isteka zakupa nalazi 0 trenutaka (istek briše `slots.contribution_id`) → račun tiho `skipped` | snapshot `contributions.sold_slots` (piše ga trigger na `sold`); račun, e-pošta i status čitaju njega |
| Kasna uplata za već prodan trenutak (`slot_unassigned`) → vlasnik dobije „uživo" | umjesto toga `[ALARM] Plaćeno, trenutak nije dodijeljen` → ručni povrat |
| Nepoznat iznos = manjak i za grid (kršilo H2) | samo za sponzorski trenutak |
| Grid donator koji obeća više od cijene kvadratića gubi ga kad pošalje manje od obećanja | usporedba s `least(amount_cents, cijena zona)` |
| Manjak vraća `marked=true` → OG preview za neplaćenu poruku | `enrichLinkPreview` radi samo za `paid` |
| Obavijest vlasniku: beskonačni retry, 20 trajno pokvarenih blokira nove | max 5 pokušaja, redoslijed po `paid_at` |
| Fiskal inline u webhooku (do 60 s) → rail ponavlja; cron 20 × spor fiskal > wall-clock | posao nakon uplate u `EdgeRuntime.waitUntil`, timeout 10 s, cron 5 računa po pozivu |
| Anonimna sesija = nova kvota holdova → blokiranje inventara | 3 holda po sesiji; ostatak je **P9** |
| Datum na računu po UTC-u | `Europe/Zagreb` |
| Kopije HMAC/compare koda | `hmacHex`/`timingSafeEqual` iz `_shared/ulaznice-hmac.ts` |

### Lokalni test

```bash
supabase migration up --local
psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" -f supabase/tests/20261007_sponzorski_trenuci.sql
supabase/tests/20261007_sponzorski_trenuci_utrka.sh

# E2E: mock (MPT + fiskal + Resend) iz fiskal repoa jer treba njegov zod
(cd ../domovina-fiskal/backend && FISKAL_REPO=.. deno run -A --unstable-sloppy-imports \
   --node-modules-dir=manual ../../domovina-api/supabase/tests/mock-mpt-fiskal.ts 54999 &)
cat > /tmp/e2e.env <<EOF
INTENT_WEBHOOK_SECRET=whsec_$(printf 'e2e-local-webhook-secret-123456' | base64)
PINKA_INTENTS_URL=http://host.docker.internal:54999/api/intents
FISKAL_URL=http://host.docker.internal:54999
FISKAL_API_KEY=dfk_mock_e2e
FISKAL_POSLOVNI_PROSTOR=OGL
FISKAL_NAPLATNI_UREDAJ=1
RESEND_API_KEY=re_mock
RESEND_API_URL=http://host.docker.internal:54999/emails
SPONSOR_OWNER_EMAIL=vlasnik@example.com
SPONSOR_MODERATION_SECRET=e2e-moderation-secret-0123456789
SPONSOR_CRON_SECRET=e2e-cron-secret-0123456789abcdef
PUBLIC_FUNCTIONS_URL=http://127.0.0.1:55321/functions/v1
EOF
supabase functions serve --env-file /tmp/e2e.env &
supabase/tests/20261007_sponzorski_trenuci_e2e.sh
```

---

## 2. Promjene ponašanja postojećih tokova

Ovo nije samo novi kod. Tri postojeća puta rade drukčije:

1. **`mark_contribution_paid`**: kupnja *bilo kojeg* mjesta (`desired_slot_keys`
   nije null, dakle i grid kvadratić) s manjkom ili nepoznatim iznosom više nije
   `paid`, nego `failed` + `underpaid`. Donacije bez mjesta rade kao i prije
   (test 14). Na produkciji postoji 1 grid karta. Intent traži točan iznos, pa
   manjak nastaje samo ako kupac ručno prepiše iznos.
2. **`pinka-webhook` sada knjiži `payment.late`** (prije: `ignored`). To vrijedi
   za sve doprinose, uključujući donacije. Takvo je bilo deklarirano ponašanje
   (H2 u `pinka-slots.md`), ali kod ga nije provodio: kasna SEPA uplata nikad
   nije postala plaćena.
3. **Javni viewovi** `public_sponsor_moments` / `public_live_moments` prikazuju
   kampanje s `visibility in ('public','unlisted')`. `public_slots` i dalje traži `public`.

---

## 3. Puštanje na produkciju — točne naredbe

> Tek nakon izričitog „da". Redoslijed je bitan: migracije → env → funkcije →
> cron → provjera. Frontend smije ići tek nakon koraka 6.

```bash
cd ~/git/domovinatv/domovina-api

# 0. backup — db-migrate.sh backupira samo public + domovina_ai (pinka-slots.md)
./scripts/db-dump.sh --schemas pinka_finance --data

# 1. migracije (dry-run pa stvarno). Seed kopira vlasnika i Safe s
#    podrzi-domovina-podcast i otvara kampanju 'active' — to je trenutak uključenja.
./scripts/db-migrate.sh --dry-run
./scripts/db-migrate.sh
#    provjera: 79 trenutaka, 7 epizoda
#    select count(*), count(distinct youtube_id) from pinka_finance.public_sponsor_moments;

# 2. env za edge container (svaki KEY=VALUE posebno; vrijednosti NE u repo/chat)
./scripts/coolify-env-set.sh FISKAL_URL=https://fiskal-test.domovina.ai -y
./scripts/coolify-env-set.sh FISKAL_API_KEY=dfk_… -y
./scripts/coolify-env-set.sh FISKAL_POSLOVNI_PROSTOR=… -y
./scripts/coolify-env-set.sh FISKAL_NAPLATNI_UREDAJ=… -y
./scripts/coolify-env-set.sh SPONSOR_MODERATION_SECRET="$(openssl rand -hex 32)" -y
./scripts/coolify-env-set.sh SPONSOR_CRON_SECRET="$(openssl rand -hex 32)" -y
./scripts/coolify-env-set.sh SPONSOR_OWNER_EMAIL=… -y          # opcionalno
./scripts/coolify-env-set.sh PUBLIC_FUNCTIONS_URL=https://api.domovina.ai/functions/v1 -y \
  --recreate-service=supabase-edge-functions

# 3. funkcije (_shared ide automatski uz --only)
./scripts/deploy-functions.sh --only=pinka-contribute
./scripts/deploy-functions.sh --only=pinka-webhook
./scripts/deploy-functions.sh --only=sponsor-moderate
./scripts/deploy-functions.sh --only=sponsor-cron --restart -y

# 4. cron — pg_cron + pg_net, tajna u Vaultu (nikad u migraciji)
#    kroz SSH psql obrazac iz project_deploy_workflow (SQL u temp file → cat | ssh)
```

```sql
create extension if not exists pg_cron;
select vault.create_secret('<SPONSOR_CRON_SECRET>', 'sponsor_cron_secret');
select cron.schedule('sponsor-expire-live', '*/10 * * * *',
                     'select pinka_finance.expire_live_slots()');
select cron.schedule('sponsor-cron', '*/10 * * * *', $$
  select net.http_post(
    url     := 'http://supabase-kong:8000/functions/v1/sponsor-cron',
    headers := jsonb_build_object('x-cron-secret',
                 (select decrypted_secret from vault.decrypted_secrets where name = 'sponsor_cron_secret')),
    body    := '{}'::jsonb)
$$);
```

Ako se pg_cron ne instalira, ispravnost i dalje stoji (istek gleda view, a
checkout žanje sam). Bez crona otpadaju samo retry računa i ponovljena obavijest.
Webhook i dalje sam pokuša račun pri svakoj isporuci.

```bash
# 5. provjera bez pisanja
curl -s "https://api.domovina.ai/rest/v1/public_sponsor_moments?youtube_id=eq.WRE248YCIeI&select=slot_key,state,price_cents" \
  -H "apikey: $ANON" -H 'Accept-Profile: pinka_finance' | head
curl -s -o /dev/null -w '%{http_code}\n' -XPOST https://api.domovina.ai/functions/v1/sponsor-cron   # 401

# 6. deploy journal
./scripts/deploy-journal.sh --verify --note "sponzorski trenuci backend"
```

**Povrat:** `update pinka_finance.campaigns set state = 'paused' where id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';`
Checkout tada vraća `campaign_not_active`, a izlog je prazan. Migracija je
aditivna. Jedina izmjena postojeće funkcije je `mark_contribution_paid`. Njena
prethodna verzija je u `20260722120000_pinka_slots.sql` §15.

---

## 4. Env varijable

| Varijabla | Obavezno | Funkcija | Napomena |
|---|---|---|---|
| `FISKAL_URL` | ne | webhook, cron | zadano `https://fiskal-test.domovina.ai`. Sve osim fiskal-testa i localhosta odbija se bez `FISKAL_ALLOW_PROD=1`. |
| `FISKAL_API_KEY` | da (za račun) | webhook, cron | `dfk_…` ključ tenanta prodajne pravne osobe. Bez njega `invoice_state = failed`, `fiskal_not_configured`. |
| `FISKAL_POSLOVNI_PROSTOR` | da | | oznaka PP-a za „oglase" (plan §2.4) |
| `FISKAL_NAPLATNI_UREDAJ` | da | | oznaka NU-a |
| `FISKAL_ALLOW_PROD` | ne | | `1` tek kad se prelazi na produkcijski fiskal (izvan ovog kruga) |
| `RESEND_API_KEY` | već postoji | webhook, cron | bez njega nema obavijesti ni alarma (samo log) |
| `DOMOVINA_MAIL_FROM` | već postoji | | pošiljatelj |
| `SPONSOR_OWNER_EMAIL` | ne | | inače e-pošta vlasnika accounta kampanje |
| `SPONSOR_MODERATION_SECRET` | da | webhook, `sponsor-moderate` | ≥ 16 znakova; bez njega e-pošta nema link za povlačenje |
| `SPONSOR_CRON_SECRET` | da | `sponsor-cron` | ≥ 16 znakova |
| `PUBLIC_FUNCTIONS_URL` | ne | webhook | zadano `https://api.domovina.ai/functions/v1` (link u e-pošti) |
| `INTENT_WEBHOOK_SECRET`, `PINKA_INTENTS_URL` | već postoje | | nepromijenjeno |

---

## 5. Poznata ograničenja

- **Ponovno slanje eRačuna u rubnom slučaju.** Ako `/posalji-eracun` uspije, a
  odmah zatim padne zapis `sent` u bazu, retry će poslati ponovno. Izdavanje je
  zaštićeno Idempotency-Keyjem, slanje nije. Vjerojatnost je mala (pad baze
  između dva poziva). Lijek je provjeriti `eracun-status` prije slanja.
- **Povrat je ručan** (MPT nema refund API). Odnosi se na manjak, `slot_unassigned`
  (kasna uplata za već prodan trenutak) i odbijenu kreativu. Kandidate za povrat daje:
  `select … from pinka_finance.contributions where is_sponsor and (underpaid or slot_unassigned);`
- **Logo je nepromjenjiv**, a neplaćeni uploadi se ne čiste (bucket je javan,
  putevi su nepogodljivi). Čišćenje je kasnije.
- Cijena je bruto i djeljiva s 5 centi (`seed_timeline_map` odbija ostalo), da
  neto i PDV zbroje točno na plaćeno.
- `sponsor_order_status` i `contribution_status` uzimaju contribution id kao
  capability (isti model). Ne vraćaju PII.

---

## 6. Otvorena pitanja

Iz plana (§5):

| # | Pitanje | Što blokira u ovom kodu |
|---|---|---|
| P1 | Pravna osoba koja prodaje i izdaje račun; PDV status | `FISKAL_API_KEY`/PP/NU. PDV 25 % je hardkodiran (`_shared/sponsor.ts` `PDV_STOPA`). Ako prodavatelj nije u sustavu PDV-a, mijenja se stopa/kategorija. |
| P2 | Knjigovođa: prihod naplaćen kao EURe u Safe | go-live |
| P3 | Vrsta računa kad kupac nema OIB | kod izdaje `RACUN` (nefiskalni, transakcijski). Ako treba `FISKAL_B2C`, to je promjena jedne grane + `operaterOib`. |
| P4 | Pravnik: AVM usluga po ZEM-u, tekst oznake, uvjeti | go-live; `terms_accepted_at` se bilježi |
| P5 | Cijena i `run_days` po zoni | seed je PLACEHOLDER: 30 / 50 / 80 €, 30 dana |
| P6 | Ekskluzivnost (dva konkurentska branda u epizodi) | trenutak je ekskluzivan po konstrukciji; epizoda nije |

Nova pitanja iz ovog kruga:

| # | Pitanje |
|---|---|
| P7 | EU kupac s VAT ID-om bez OIB-a: prijenos porezne obveze (AE, 0 %) umjesto 25 %? Kod sada naplaćuje 25 % (konzervativno). |
| P8 | DSA čl. 26 traži da se vidi **tko je platio**. View pokazuje `brand`. Ako agencija kupuje za brand, treba li javno pokazati `buyer_company`? Ugovor ga sada drži privatnim. |
| P9 | **Blokiranje inventara besplatnim holdovima.** Produkcija ima `ENABLE_ANONYMOUS_USERS`. Svaka nova anonimna sesija smije držati 3 trenutka do 24 h (vijek intenta), pa skripta može zaključati sve trenutke bez plaćanja. Limit po sesiji to ne sprječava. Prijedlog: Turnstile u checkoutu + limit po IP-u u `pinka-contribute`, ili kraći hold dok uplata nije viđena. Treba odluku prije javnog linka. |
