# 05 — Roadmap: nove funkcionalnosti

Prijedlozi izvedeni iz **postojećih** shema, edge funkcija i već zapisanih namjera u
`docs/pinka-*.md`. Poredani po zrelosti (koliko sustav već ima podloge). Poštuju arhitekturne
principe: domovina-api je **keyless** (ledger + authz), sve potpisničke ključeve drži
pay.domovina.ai; SSO je jedan dijeljeni Supabase Auth; backend-placement pravilo (service-role
→ edge fn ovdje, proxy/prezentacija → CF Worker).

---

## Tier A — Dovršava ono što je već napola tu (najviši ROI)

### R-A1 — Payout executor RPC-ovi (`mark_payout_*`)
`docs/pinka-payout-execution.md` eksplicitno traži `mark_payout_submitted/confirmed/failed`
service_role RPC-ove "kad izvršitelj krene" — **ne postoje**. Request-strana (`request_payout`,
uključuje accrued yield) je gotova. Ovo je zadnja karika ledger-side state machine-a
`requested → submitted → confirmed/failed`.

> **Autonomni prompt**
> U `domovina-api` implementiraj payout state-machine RPC-ove opisane u
> `docs/pinka-payout-execution.md`: `pinka_finance.mark_payout_submitted(payout_id, tx_hash)`,
> `mark_payout_confirmed(payout_id)`, `mark_payout_failed(payout_id, reason)` — svi `security definer`,
> `search_path=''`, grant SAMO `service_role` (poziva ih keyless executor s pay.domovina.ai).
> Enforce-aj legalne prijelaze stanja i idempotentnost (ponovljeni poziv vraća postojeće stanje).
> Napiši migraciju po postojećem stilu, dodaj indexe ako trebaju, i ažuriraj
> `docs/pinka-payout-execution.md` da označi ledger-stranu gotovom. Ne diraj živu bazu.

### R-A2 — Realtime notifikacije na `payouts` / `yield_positions` promjene stanja
Zapisano kao otvoreno pitanje u payout/yield docsima. Supabase Realtime publikacija se već
koristi (RevenueCat migracija je dodaje). Vlasnik kampanje bi u appu vidio "isplata potvrđena"
bez pollanja.

> **Autonomni prompt**
> U `domovina-api` omogući Supabase Realtime za `pinka_finance.payouts` i `yield_positions` tako
> da vlasnik kampanje dobije push na promjenu stanja (npr. `requested→confirmed`). Provjeri kako
> je Realtime publikacija dodana u `20260628120000_revenuecat_subscriptions.sql` i slijedi isti
> obrazac (dodaj tablice u `supabase_realtime` publikaciju uz RLS koji osigurava da korisnik vidi
> samo svoje redove). Napiši migraciju + kratku doc bilješku o tome što frontend treba pretplatiti.

### R-A3 — `pinka-onchain-confirm` verifikacija Google/JWKS + prošireni indexer coverage
Onchain confirm/ingest rade, ali `pinka-onchain-confirm` je jedini put bez HMAC/JWT (oslanja se
na on-chain verifikaciju). Vrijedi ojačati: rate-limit po IP-u i eksplicitni `config.toml` unos
(vidi SEC-M6). Prirodni sljedeći korak: webhook od indexera koji retroaktivno pokriva propuštene
transfere (reorg safety).

> **Autonomni prompt**
> U `domovina-api` ojačaj on-chain donacijski put: (1) dodaj `[functions.pinka-onchain-confirm]`
> i `[functions.pinka-onchain-ingest]` u `config.toml` s `verify_jwt=false`; (2) dodaj per-IP
> rate-limit u `pinka-onchain-confirm` (jedini put bez potpisa); (3) predloži reorg-safety: periodični
> reconciliation job koji preko `pinka-onchain-ingest` re-provjeri zadnjih N blokova protiv
> `record_onchain_contribution` idempotency ključa `(forward_tx_hash, onchain_log_index)`. Implementiraj
> (1) i (2), (3) opiši kao plan. Ne diraj živu bazu/deploy.

---

## Tier B — Nova vrijednost na postojećim shemama

### R-B1 — Recurring donacije / subscription naplata kroz Pinka
Postoji `pinka_finance.subscriptions` (IBAN-hash keyed, recognition) i schedule migracija
(20260606130000), ali naplatni ciklus nije aktivan. Uz RevenueCat već integriran za app pretplate,
Pinka mjesečne donacije su logično proširenje.

> **Autonomni prompt**
> U `domovina-api` istraži postojeće `pinka_finance.subscriptions` i subscription_schedule migracije
> (20260606120000, 20260606130000) te predloži kako aktivirati recurring donacijski ciklus:
> pg_cron job koji generira sljedeći `contribution` pending po rasporedu, integracija s postojećim
> SEPA/on-chain rail-ovima, i idempotentnost po (subscription_id, period). Napiši design doc
> `docs/pinka-recurring-donations.md` + migracijski skeleton. Ne implementiraj naplatu na živo.

### R-B2 — On-chain receipts Tier 1 (EAS attestacije)
`docs/pinka-onchain-receipts-tokenization-plan.md` je DRAFT s gantt-om (R1 od 2026-06-08).
`token_positions` hook već postoji (`onchain_token_address`/`attestation_uid` NULL = dormant).
Tier 1 (proof-of-support EAS attestacija, bez tradeable tokena) je legalno najsigurniji.

> **Autonomni prompt**
> U `domovina-api` pripremi ledger-stranu za on-chain receipts Tier 1 (EAS attestacije) prema
> `docs/pinka-onchain-receipts-tokenization-plan.md`. Keyless princip: domovina-api samo bilježi
> `attestation_uid`/`receipt_policy`, potpisivanje radi pay.domovina.ai. Napravi migraciju s
> `pinka_finance.receipt_policy` i `receipt_claims` tablicama (RLS: donor vidi svoje), te
> service_role RPC `record_receipt_attestation(contribution_id, attestation_uid)`. NE dodaji
> tradeable tokene (legalni Tier-4 track je zaseban). Ažuriraj plan doc statusom. Ne diraj živu bazu.

### R-B3 — "Donor wall" / javne statistike kampanje kao read API
Postoje `public_contributions` view i `campaign_stats` cache. Prirodno je izložiti lagani
javni read endpoint (CF Worker prema backend-placement pravilu) za embed na pinka.finance.

> **Autonomni prompt**
> Dizajniraj javni read-only API za Pinka donor wall / campaign statistiku koristeći postojeće
> `pinka_finance.public_contributions` view i `campaign_stats` cache. Prema
> `docs/backend-architecture.md` placement pravilu, ovo je prezentacijski proxy → pripada CF
> Pages Worker-u u domovina.ai repou, NE ovom repou. Napiši `docs/pinka-public-read-api.md` koji
> specificira endpoint (kešing, rate-limit, koja polja, RLS/anon grant provjera) i jasno označi
> da implementacija ide u drugi repo. Ne dodaji service-role u worker.

---

## Tier C — Platforma / dugoročno (zapisano u planovima)

- **R-C1 — pinka.finance creator dashboard (Phase 2)** — Next.js app za kreatore kampanja
  (platform-plan §6). Frontend repo; ovaj repo samo dodaje eventualne RPC-ove.
- **R-C2 — Payout policy ladder** (auto ≤€100 / multisig-propose €100–1000 / out-of-band >€1000)
  iz platform-plan §6 Phase 4 — ledger-side pravila u `request_payout`.
- **R-C3 — Monerium redeem-confirmation webhook → `mark_payout_confirmed`** (payout open pitanje).
- **R-C4 — Live APY fetch** koji zamjenjuje statični "~3,5%" u yield prikazu.
- **R-C5 — SSO Opcija B**: centralni `auth.domovina.ai` bridge — eksplicitno odgođeno "dok
  poslovno ne opravdamo".
- **R-C6 — Tier 4 regulated token track (ECSPR/HANFA)** — gated iza pravnog strukturiranja.

> **Autonomni prompt (payout policy ladder — R-C2)**
> U `domovina-api` implementiraj payout policy ladder iz `docs/pinka-finance-platform-plan.md` Phase 4:
> u `request_payout` (ili novi guard) dodaj pravila po iznosu — auto-approve ≤ €100 (10000 centi),
> flag za multisig-propose €100–1000, i out-of-band review > €1000. Pravila su ledger-side (keyless);
> izvršenje ide na pay.domovina.ai. Napiši migraciju + doc bilješku, s konfigurabilnim pragovima
> po kampanji ako je izvedivo. Ne diraj živu bazu.

---

## Operativni "roadmap" (nije feature ali diže kvalitetu)

Ovi su detaljno razrađeni u dok. 02 (OPS-1 offsite backup, CI/gitleaks, PITR, restore-test,
secrets-audit). Preporuka: **OPS-1 i CI prije bilo kojeg Tier B/C feature-a** — payments baza
bez offsite backupa i javni repo bez secret-scana su veći rizik od bilo koje nove funkcionalnosti.
