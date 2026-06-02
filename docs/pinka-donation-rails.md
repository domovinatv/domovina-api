# pinka.finance — donation rails

> How money reaches a campaign and how a `pinka_finance.contributions` row gets
> marked `paid`. Three independent rails, one idempotent credit path, one live wall.
> See also: `pinka-finance-platform-plan.md` (data model), and in pay.domovina.ai:
> `docs/reference/monerium-contracts.md` (EURe V1/V2), `docs/research/related-origin-requests.md`.

## The three rails

| Rail | How the donor pays | Detection → credit | Latency |
|---|---|---|---|
| **SEPA (fiat)** | scan EPC QR in their bank app → Monerium mints EURe → rail forwards to the campaign Safe | Monerium webhook → pay-worker `intent.paid` outbound webhook → edge `pinka-webhook` → `mark_contribution_paid(sid)` | ~instant (SEPA Instant) |
| **On-chain QR** | scan an **EIP-681** QR with any wallet (MetaMask/Monerium/DOMOVINA) → send EURe V2 directly to the campaign Safe | pay-worker cron indexer (`*/2`) scans EURe V2 Transfer logs → edge `pinka-onchain-ingest` → `record_onchain_contribution` | ~1–2 min |
| **In-app wallet (SDK)** | "Plati iz DOMOVINA novčanika" → wallet SDK `Domovina.send` → txHash | poll edge `pinka-onchain-confirm` (verifies the Gnosis receipt) → `record_onchain_contribution` | instant (~5–10s) |

All EURe is **Monerium EURe V2** `0x420CA0f9…` on Gnosis (chain 100). The campaign's
`destination_address` is its own counterfactual Safe (deploys lazily on first withdrawal).

## Credit path (shared, idempotent)

Two RPCs flip a contribution to `paid`; both rely on triggers (`tg_contribution_state`,
AFTER UPDATE OF state) to re-sum `campaign_stats`, bump tier inventory, and flip the
campaign to `funded`. Because that trigger fires only on UPDATE, every path **inserts
pending then updates to paid**.

- **`mark_contribution_paid(sid, tx_hash, amount_received_cents)`** — fiat. Matches the
  pending row by `payment_intent_sid`. Idempotent (only flips `state='pending'`).
- **`record_onchain_contribution(campaign_id, tx_hash, log_index, from, cents)`** — on-chain
  (both QR and SDK rails). **Idempotent on `(forward_tx_hash, onchain_log_index)`** via a
  unique index, so the cron indexer and the instant confirm never double-credit the same
  transfer. Snapshots `destination_address` (NOT NULL). service_role only.

### Anti-double-count: rail vs direct

The SEPA rail ALSO lands EURe on the campaign Safe (a forward **from the MPT rail Safe**
`0x449aBCEf…`). That transfer is already credited via the fiat webhook, so both the cron
indexer and `pinka-onchain-confirm` **skip transfers whose `from` == the rail Safe**.
Direct donations come from the donor's own wallet → credited.

## Components

### pay.domovina.ai (Cloudflare)
- `backend/src/intents/outbound.ts` — `intent.paid` outbound webhook (svix HMAC, `INTENT_WEBHOOK_SECRET`).
- `backend/src/intents/onchainIndexer.ts` — cron indexer (KV cursor, chunked `getLogs`, rail-exclude, HMAC POST).
- `POST /api/onchain/scan` (`x-indexer-key`) — manual indexer trigger.
- Crons: `*/2 * * * *` (indexer) + `0 */6 * * *` (account refresh + expired-intent sweep).

### domovina-api (Supabase edge + Postgres)
- `pinka-contribute` — create pending contribution (display_name/message/anonymous) + create rail intent.
- `pinka-webhook` — verify `intent.paid` HMAC → `mark_contribution_paid`.
- `pinka-onchain-ingest` — `GET` watchlist (active campaign Safe addresses); `POST` (HMAC) batch of transfers → `record_onchain_contribution`.
- `pinka-onchain-confirm` — `{campaign_id, tx_hash}` → verify Gnosis receipt (EURe V2 Transfer to Safe, exclude rail) → `record_onchain_contribution`. On-chain verification is the auth (no HMAC/JWT).
- `contribution_status(uuid)` (SECURITY DEFINER) — guest-pollable `{state, paid_at}` by contribution id; the checkout panel polls this (RLS blocks a guest from reading its own row).

### pinka-app (Next.js static)
- `ContributePanel` — SEPA / On-chain tabs; SEPA EPC QR + status poll; on-chain EIP-681 QR + "Plati iz DOMOVINA novčanika" (SDK send → confirm poll).
- Support wall — 12s poll + instant refresh on own paid + `pinka-arrive` animation for new entries.
- On-chain transparency links → Gnosisscan (EURe V2 token + address `#tokentxns`).

## Secrets

- `INTENT_WEBHOOK_SECRET` (shared `whsec_…`): set on pay-worker (`wrangler secret put`) AND
  the Supabase edge container. Signs/verifies the `intent.paid` outbound webhook + the
  on-chain indexer ingest. (`pinka-onchain-confirm` needs no secret.)

## Live status UX

- Fiat: panel polls `contribution_status` every 3s → "Hvala 🙏" ~3s after the webhook.
- On-chain SDK: polls `pinka-onchain-confirm` → instant flip.
- On-chain QR: wall poll picks it up after the indexer credits (~1–2 min).
- Wall animates every new entry regardless of rail.
