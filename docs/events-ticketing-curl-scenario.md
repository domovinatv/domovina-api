# Događaji (E2) — curl test scenarij

> Reference: safe-wallet-monorepo `docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md` +
> `handoffs/dogadjaji-2-backend.md`. Migracije: `20260716120000/120100/120200_events_ticketing_*`.
> Funkcije: `events-order`, `events-confirm`, `events-tickets`, `events-feed`.
>
> Scenarij pokriva kriterije prihvaćanja E2: create_event → order (rezervacija) →
> onchain confirm → paid + N ulaznica; idempotencija; oversell odbijen; TTL istek
> oslobađa rezervaciju; imenska bez imena odbijena.

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

## 7. Nesparena uplata (§8 reconciliation rub)

Ako je cron indexer (`pinka-onchain-ingest`) već kreditirao isti `(tx_hash,
log_index)` kao generičku donaciju, `events-confirm` vraća
`{"status":"tx_already_credited"}` i upiše `ticket_order.match_conflict` event u
`contribution_events` → red za ručno sparivanje:

```sql
select * from pinka_finance.contribution_events
 where event_type in ('ticket_order.match_conflict','ticket_order.underpaid','ticket_order.expired_sold_out')
 order by created_at desc;
```

## Deploy (prod — ručni korak)

```bash
./scripts/db-migrate.sh --dry-run     # 3 pending events_ticketing migracije
./scripts/db-migrate.sh               # idempotentne; drugi run = no-op
./scripts/deploy-functions.sh --only=events-order
./scripts/deploy-functions.sh --only=events-confirm
./scripts/deploy-functions.sh --only=events-tickets
./scripts/deploy-functions.sh --only=events-feed --restart -y
```
