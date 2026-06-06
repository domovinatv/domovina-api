# Pinka — Aave yield: HANDOFF (nastavak rada)

Zadnje ažurirano: 2026-06-06. Ovaj dokument je "nastavi ovdje" za sve vezano uz
**oplodnju prikupljenih sredstava kampanje na Aaveu** (i povezani payout flow).
Cross-repo: `domovina-api` (backend, ovdje), `domovina.ai` (Flutter UI),
`pay.domovina.ai` (on-chain izvršitelj — TODO). Povezani docovi:
`pinka-yield-execution.md`, `pinka-payout-execution.md`, `pinka-donation-rails.md`,
`pinka-finance-platform-plan.md`.

## 1. Cilj / model (odlučeno)

- Prikupljena EURe sredstva sjede na **per-campaign Safeu** (Gnosis, counterfactual,
  **1-of-1 ekosustavni signer** — kreira pinka.io, deploya pay.domovina.ai relay).
- Dok čekaju **ad-hoc isplatu**, parkiraju se na **Aave v3 (Gnosis)** i nose prinos
  (supply EURe → `aGnoEURe`, ~3,5% APY, withdraw on-demand → likvidno).
- **Custody = payout-request, BEZ multisiga.** Owner wallet je **odredište isplate**,
  NIKAD Safe co-signer. (`domovina_ai.episode_safes` + `safe-owner-add` su legacy,
  NISU dio ovog puta.)
- **Yield = per-campaign opt-in** (vlasnik toggla; `campaigns.metadata.yield.enabled`,
  default OFF). **Prinos pripada kampanji** → povećava raspoloživo za isplatu.
- Glavnica supplyana u Aave je i dalje dio `total_raised_cents` (ne dvostruko
  brojimo); jedini dodatak na "raspoloživo" je `accrued_yield_cents`.
- Venue = Aave **v3** Gnosis. Aave **v4** je live (Ethereum, 30.3.2026.) ALI
  Ethereum-only + bez EURe → neprimjenjiv; `yield_positions.protocol` predviđa
  buduću migraciju ako v4 dođe na Gnosis s EURe.

## 2. Što je GOTOVO (committano + live)

### Backend (domovina-api, na main, primijenjeno na Supabase — smoke-tested)
- `20260603140000_pinka_payouts.sql`: `payouts_select` RLS (vlasnik kanala) +
  `request_payout(campaign,dest,amount)` (gate: ownership ∧ KYC iz
  `auth.users.raw_app_meta_data.kyc_verified` ∧ available; dest = 0x ili IBAN).
- `20260603150000_pinka_yield.sql`:
  - tablica `pinka_finance.yield_positions` (campaign_id PK, protocol,
    principal_cents, last_balance_cents, accrued_yield_cents, atoken_address,
    status idle|active|paused, last_synced_at) + RLS select (vlasnik/javno).
  - `set_campaign_yield(campaign, enabled)` (authenticated, ownership-gated) →
    postavlja `metadata.yield.enabled` + upsert poziciju.
  - **service_role** keeper RPC-evi: `record_yield_deposit(campaign,cents,atoken?)`,
    `record_yield_withdraw(campaign,cents)`, `sync_yield_balance(campaign,balance_cents,atoken?)`.
  - `request_payout` create-or-replace → `available += accrued_yield_cents`.
- Smoke test (anon): `request_payout`/`set_campaign_yield` → 401 perm denied
  (postoje, anon blokiran); `yield_positions` → 200 []; keeper RPC-evi → 401
  (service_role only). ✓

### Frontend (domovina.ai, na main, deployano v2.0.46)
- `lib/pinka_sdk/`: `PinkaPayout`/`PinkaPayoutSummary` (available uključuje prinos),
  `PinkaYieldPosition` (+ `PinkaClient.yieldPosition`), `PinkaOwnerCampaign` yield
  polja, `PinkaAdminClient.setCampaignYield` + `listPayouts`/`requestPayout`.
- "Isplata" tab (`lib/screens/ownership/campaigns/campaign_manage_screen.dart`):
  sažetak (prikupljeno/prinos/u obradi/isplaćeno/raspoloživo), "Zatraži isplatu",
  **"Oplođuj sredstva (Aave v3 · Gnosis)"** toggle + disclosure + prikaz pozicije.
- **aGnoEURe transparentnost**: javni "Provjeri na lancu" (`pinka_campaign_screen.dart`)
  pokazuje "Sredstva rade na Aaveu" + iznos + prinos + Gnosisscan aGnoEURe link
  kad je pozicija deployana; isto i u vlasnikovom Isplata tabu.

## 3. Što OSTAJE (TODO — nastavak)

### A) On-chain keeper (pay.domovina.ai / ops) — NIJE implementiran (spec u `pinka-yield-execution.md`)
Najveći komad. Ugovor:
- **Zodiac Roles Modifier** na svakom campaign Safeu (yield ON), scope preko
  **DeFi Kit** (karpatkey) za **Aave v3 Gnosis**: dozvoljeno ISKLJUČIVO
  `Pool.supply`/`Pool.withdraw` EURe + `EURe.approve(Pool)` — ništa drugo.
  Potpisuje postojeći ekosustavni signer/relay (`execTransactionWithRole`).
- **Loop** (cron/ops): za `metadata.yield.enabled=true` → deploy Safe ako
  counterfactual → `supply(balance − buffer)` → `record_yield_deposit`. Periodični
  `sync_yield_balance` (čita aGnoEURe saldo, upiše i `atoken_address` → otključa
  Gnosisscan link u UI-u). Na disable → withdraw cijele pozicije.
- **Buffer policy** (param): npr. drži €X ili Y% likvidno za brze isplate.
- **APY prikaz** (opc.): fetch Aave reserve APY → cache (UI sad ima statično "~3,5%").

### B) Payout izvršitelj (pay.domovina.ai / ops) — spec u `pinka-payout-execution.md`
- Čita `payouts.state='requested'` → **withdraw-before-payout** (ako su sredstva u
  Aaveu, prvo `withdraw` + `record_yield_withdraw`) → Monerium redeem (IBAN) ili
  Safe transfer (0x) → `mark_payout_submitted/confirmed/failed` (service_role RPC-evi
  koje TREBA dodati u domovina-api kad izvršitelj kreće).

### C) Manji
- `mark_payout_*` service_role RPC-evi (još ne postoje — dodati uz izvršitelj).
- Realtime/refresh UI-a nakon synca (Supabase Realtime na yield_positions/payouts).
- Pravni pregled (MiCA/e-money: prinos na skrbljenim donaciranim sredstvima;
  transparentnost "100% creatoru").

## 4. Ključne datoteke
- Backend: `supabase/migrations/20260603{140000_pinka_payouts,150000_pinka_yield}.sql`;
  docs `pinka-yield-execution.md`, `pinka-payout-execution.md`.
- Frontend: `lib/pinka_sdk/src/{models/pinka_yield_position,models/pinka_payout,
  pinka_admin_client,pinka_client,pinka_config}.dart`;
  `lib/screens/ownership/campaigns/campaign_manage_screen.dart`;
  `lib/pinka_sdk/src/screens/pinka_campaign_screen.dart` (verify card).

## 5. Kako nastaviti (predloženi redoslijed)
1. Implementiraj keeper supply/sync u pay.domovina.ai (Roles + DeFi Kit, Aave v3 Gnosis).
2. Dodaj `mark_payout_*` RPC-eve + payout izvršitelj (withdraw-before-payout).
3. Testiraj E2E na jednoj test-kampanji (enable yield → supply → sync prikaže prinos
   → raspoloživo poraste → isplata povuče iz Aavea).
4. Buffer policy + APY live fetch + pravni pregled prije šire produkcije.
