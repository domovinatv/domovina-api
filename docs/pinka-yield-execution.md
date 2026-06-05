# Pinka yield execution (keeper / pay.domovina.ai)

Status: **SPEC** (request/ledger strana implementirana u domovina-api + domovina.ai;
on-chain keeper NIJE implementiran — ovo je ugovor za pay.domovina.ai/ops).

## Model

Per-campaign opt-in (`campaigns.metadata.yield.enabled`, vlasnik toggla, default
OFF). Dok prikupljena EURe sredstva čekaju ad-hoc isplatu, parkiraju se na **Aave
v3 (Gnosis)** i nose prinos. **Prinos pripada kampanji** → povećava raspoloživo za
isplatu (`request_payout` already uračunava `yield_positions.accrued_yield_cents`).
Glavnica je i dalje dio `total_raised_cents` (ne dvostruko brojimo); jedini dodatak
je akumulirani prinos.

Venue = **Aave v3 na Gnosisu** (Aave v4 je Ethereum-only, bez EURe/Gnosisa; kad
v4 dođe na Gnosis s EURe, `yield_positions.protocol` predviđa migraciju).

## Već implementirano (domovina-api)

- `pinka_finance.yield_positions` (campaign_id, principal_cents, last_balance_cents,
  accrued_yield_cents, atoken_address, status, last_synced_at). RLS select = vlasnik
  /javno (kao kampanja).
- `set_campaign_yield(campaign, enabled)` (authenticated, ownership-gated) — postavi
  `metadata.yield.enabled` + upsert poziciju (active/paused).
- service_role RPC-evi: `record_yield_deposit`, `record_yield_withdraw`,
  `sync_yield_balance`.
- `request_payout.available += accrued_yield_cents`.
- Flutter: "Oplodnja" toggle + prikaz u "Isplata" tabu (`campaign_manage_screen.dart`).

## TODO (pay.domovina.ai / ops keeper)

### 1. Permisije — Zodiac Roles + DeFi Kit
- Na svakom campaign Safeu (gdje je yield ON) postaviti **Zodiac Roles Modifier**,
  scope preko **DeFi Kit** (karpatkey) za **Aave v3 Gnosis**: dozvoljeno ISKLJUČIVO
  `Pool.supply(EURe,…)`, `Pool.withdraw(EURe,…)` i `EURe.approve(Pool,…)` — ništa
  drugo (keeper ne može slati sredstva izvan Aavea/Safea).
- Keeper potpisuje preko postojećeg ekosustavnog signera/relaya (`pay.domovina.ai`),
  `execTransactionWithRole`.

### 2. Keeper loop (cron/ops)
Za kampanje s `metadata.yield.enabled = true`:
- **Supply:** ako Safe ima slobodne EURe iznad **buffera**, `deploy` Safe ako je
  counterfactual → `supply(EURe, balance − buffer)` → `record_yield_deposit(campaign, cents, aToken)`.
- **Sync:** periodično čitaj `aGnoEURe` saldo → `sync_yield_balance(campaign, balance_cents, aToken)`
  (osvježi accrued_yield = balance − principal).
- **Withdraw-before-payout:** kod `payouts.state='requested'`, ako likvidni EURe na
  Safeu < iznos isplate → `withdraw(EURe, manjak)` iz Aavea → `record_yield_withdraw`
  → tek onda payout redeem (vidi `pinka-payout-execution.md`).
- **Disable:** kad vlasnik isključi (status='paused'), keeper povuče cijelu poziciju
  natrag u EURe na Safe.

### 3. Buffer policy (param)
Drži npr. fiksno €X ili Y% prikupljenog likvidno na Safeu za brze male isplate;
ostatak supplyaj. Konfigurabilno globalno ili per-campaign (`metadata.yield.buffer`).

### 4. APY prikaz (opcionalno)
Periodični fetch Aave v3 Gnosis EURe reserve supply APY (Aave data provider /
DefiLlama) → cache; klijent prikaže uz toggle. Trenutno UI ima statičnu oznaku "~3,5%".

## Sigurnosna granica
- Ekosustavni signer ključ ostaje u pay.domovina.ai. domovina-api je knjigovodstvo
  + autorizacija (toggle/ownership), nikad ključ.
- Roles permisije su tvrda granica: i ako keeper bot bude kompromitiran, može samo
  supply/withdraw EURe na Aave — ne exfiltrirati.

## Rizici
- **On-chain saldo Safea ~0 kad yield ON** (drži se kao `aGnoEURe`) → "Provjeri na
  lancu" treba pokazati Aave poziciju (TODO UI).
- **Regulativa**: prinos na skrbljenim/donaciranim sredstvima → MiCA/e-money pregled.
- **Eventual consistency**: accrued_yield iz periodičnog synca; re-validiraj on-chain
  prije withdraw/redeem.
