# Pinka payout execution (ops / pay.domovina.ai)

Status: **SPEC** (request strana implementirana u domovina-api + domovina.ai;
on-chain izvršitelj NIJE implementiran — ovo je ugovor za pay.domovina.ai/ops).

## Model

Platform-custody + **payout-request, bez multisiga**. Donacije sjede na
counterfactual **campaign Safe** (`pinka_finance.campaigns.destination_address`,
1-of-1 ekosustavni signer). Vlasnik kanala NIJE Safe co-signer — registrira
**odredište** (0x ili IBAN) i zatraži isplatu. Autorizacija je na request strani
(verified channel ownership ∧ KYC, vidi `request_payout` RPC); izvršenje radi
platforma ekosustavnim signerom. Zato je 1-of-1 Safe dovoljan.

## Što je već implementirano (domovina-api)

- Tablica `pinka_finance.payouts` (id, campaign_id, amount_cents, destination,
  state `payout_state`, tx_hash, monerium_redeem_order_id, requested_by, …).
- RLS `payouts_select`: čita vlasnik kampanje (`has_role_on_account`) ILI
  verificirani vlasnik kanala (`is_verified_channel_owner(campaigns.youtube_channel_id)`).
- RPC `request_payout(p_campaign_id, p_destination, p_amount_cents)` (authenticated,
  SECURITY DEFINER): gate ownership + KYC + destination format + `amount ≤ available`
  (`available = total_raised_cents − Σ payouts[requested|approved|submitted|confirmed]`),
  insert `state='requested'`. Greške: `kyc_required`, `invalid_destination`,
  `invalid_amount`, `amount_exceeds_available`, `not_authorized`.
- Flutter UI: "Isplata" tab u CampaignManageScreen (zatraži + povijest + sažetak).

## Što treba implementirati (pay.domovina.ai / ops) — TODO

### 1. Izvršitelj (cron ili ops-trigger)
Čita `payouts where state='requested'` (preko `service_role`), za svaki:

1. **Re-validacija on-chain**: provjeri da campaign Safe (`destination_address`)
   ima ≥ `amount_cents` EURe salda (V2 `0x420CA0f9…`, Gnosis). Ako ne →
   `mark_payout_failed(id, 'insufficient_onchain_balance')`.
2. **Deploy ako counterfactual**: ako Safe nije deployan, relay cold-path
   (postojeći `pay.domovina.ai/wallet … relay.ts` `buildSafeInitializer`, 1-of-1).
3. **Izvrši prema tipu odredišta**:
   - **0x (EVM)** → Safe `execTransaction` EURe `transfer(destination, amount)`
     potpisan ekosustavnim signerom; spremi `tx_hash`.
   - **IBAN** → Monerium **redeem** (EURe → SEPA na IBAN); spremi
     `monerium_redeem_order_id` (+ `tx_hash` burn transakcije ako postoji).
4. Pomakni stanje: `requested → submitted` (poslano) → `confirmed` (potvrđeno)
   ili `failed`. (Opcionalno `approved` korak za ručnu ops aprovu velikih iznosa,
   npr. > €1000, per `pay.domovina.ai/backend/safe-tx/PHASE-2-SAFE-API.md` policy ladder.)

### 2. service_role mark RPC-evi (dodati u domovina-api kad izvršitelj kreće)
```sql
-- svi SECURITY DEFINER, grant samo service_role
pinka_finance.mark_payout_submitted(p_id uuid, p_tx_hash text, p_monerium_redeem_order_id text default null)
pinka_finance.mark_payout_confirmed(p_id uuid, p_tx_hash text default null)
pinka_finance.mark_payout_failed(p_id uuid, p_reason text)
```
Svaki: `update payouts set state=…, tx_hash=coalesce(...), updated_at=now() where id=p_id`.
(Idempotentno; samo naprijed po state-machine.)

### 3. Sigurnosna granica
- Ekosustavni signer ključ **ostaje u pay.domovina.ai** (Roles/relay). domovina-api
  nikad ne drži ključ niti potpisuje.
- domovina-api je autorizacijska + knjigovodstvena strana (RLS + request gate +
  payouts ledger). pay-worker je izvršna strana.

## State machine

```
requested ──(ops/izvršitelj)──► submitted ──► confirmed
    │                              │
    └──────────────► failed ◄──────┘
(approved: opcionalni ručni ops korak prije submitted za velike iznose)
```

## Otvorena pitanja
- Policy ladder po iznosu (auto vs ručna ops aprova) — vidi PHASE-2-SAFE-API.md.
- Realtime obavijest klijentu o promjeni stanja (Supabase Realtime na payouts?).
- Webhook od Moneriuma za redeem confirmation → `mark_payout_confirmed`.
