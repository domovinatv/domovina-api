# On-chain Donation Receipts & Tokenization — Design Plan

> Status: **DRAFT for iteration** (2026-06-05). No implementation yet — this is the systematic plan to review before we build.
> Scope: how a contributor to a Pinka campaign gets a verifiable **on-chain proof of contribution**, for both **SEPA** (off-chain payment) and **direct on-chain EURe** donations; whether that proof can become a **tradeable security token**; and how a **secondary market with royalties** could work.
>
> Related SSOT: [`pinka-finance-platform-plan.md`](./pinka-finance-platform-plan.md) · rails: [`pinka-donation-rails.md`](./pinka-donation-rails.md) · payouts: [`pinka-payout-execution.md`](./pinka-payout-execution.md) · contracts: `pinka-finance-mvp/` (Foundry).

---

## 1. TL;DR — the one decision that drives everything

A "proof of donation" can be **anything from a signed receipt to a financial instrument**. The single most important choice is *what rights the artifact conveys to the holder*, because that — not the file format — decides the legal regime, whether it can be traded, and whether royalties are even allowed.

```mermaid
flowchart TD
    Q{"Does the artifact give the holder<br/>an expectation of profit, revenue<br/>share, redemption value, equity or<br/>governance over money?"}
    Q -- "NO (it only *proves* you paid)" --> R["RECEIPT / COLLECTIBLE<br/>attestation · SBT · NFT badge<br/>→ outside MiCA/MiFID<br/>→ freely tradeable (if transferable)<br/>→ royalties = pure marketplace construct"]
    Q -- "YES (it represents value/return)" --> S["SECURITY / FINANCIAL INSTRUMENT<br/>equity token · revenue-share · RWA<br/>→ MiFID II + Prospectus / ECSPR<br/>→ transfer-restricted (KYC/allowlist)<br/>→ 'royalty' = controlled transfer fee"]
    R --> Rok["✅ Ship incrementally, low legal load"]
    S --> Sok["⚠️ Needs authorised CSP / venue,<br/>KYC gating, legal structuring"]
```

**Recommendation up front:** treat these as a **spectrum (Tiers 0→4)** and ship left-to-right. The donation product wants Tiers 1–3 (receipts/collectibles). The *equity* product (`pinka-finance-mvp` / ITALK) is Tier 4 and is a **separate regulated track** that should not be conflated with "donation receipts".

---

## 2. Where we are today (anchored to the code)

```mermaid
flowchart LR
    subgraph Client["pinka.io (Next.js SPA)"]
      CP["ContributePanel<br/>SEPA EPC QR · on-chain EIP-681 QR · wallet SDK"]
    end
    subgraph Pay["pay.domovina.ai (rail + ecosystem signer KEYS)"]
      RAIL["Monerium intent → EURe mint<br/>forward to campaign Safe<br/>on-chain indexer"]
    end
    subgraph API["domovina-api (Supabase · KEYLESS · ledger+authz)"]
      FC["pinka-contribute"]
      WH["pinka-webhook"]
      OI["pinka-onchain-ingest / -confirm"]
      DB[("pinka_finance.*<br/>contributions · token_positions<br/>campaign_stats")]
    end
    Safe["Per-campaign Gnosis Safe<br/>(counterfactual, 1/1 ecosystem passkey)"]

    CP -->|create| FC --> DB
    CP -->|SEPA| RAIL -->|EURe| Safe
    RAIL -->|intent.paid HMAC| WH --> DB
    CP -->|on-chain EURe| Safe
    RAIL -. indexer .-> OI --> DB
    DB -. "trigger: state→paid & type=tokenization" .-> TP["token_positions row<br/>status=pending<br/>onchain_token_address=NULL"]
```

**Facts that constrain the design:**

| Fact | Implication for this plan |
|---|---|
| `token_positions` row is auto-created on `paid` **only when `campaign.type='tokenization'`**; `onchain_token_address` / `attestation_uid` stay **NULL** (dormant). | The ledger hook already exists — we extend it, we don't invent it. |
| **domovina-api holds no signing keys.** Minting/attesting must be triggered through **pay.domovina.ai** (ecosystem signer) or **client passkey** — same trust boundary as payouts. | Issuance is an *executive* action on the pay side; the API stays authz/ledger. |
| Per-campaign Safe is **counterfactual** (not deployed until first payout), 1/1 ecosystem signer; creator only *requests*. | The Safe can be the **issuer/owner** of receipt contracts, but only via the ecosystem signer; "Safe auto-issues" = ecosystem signer executes a Safe tx (or a Safe module). |
| `contributions` has idempotency keys (`payment_intent_sid`; `(forward_tx_hash, onchain_log_index)`) and `contributor_verified` (Certilia KYC snapshot) + `contributor_account_id`. | We get **dedup, KYC status, and identity linkage for free** — critical for both claims and security-token allowlisting. |
| Separate `pinka-finance-mvp` contracts already implement a **compliant ERC-20 equity** (allowlist bitmask, mint allowance, SEPA `investOnBehalf`, Safe `investFor`). **No NFT / no EAS / no EIP-2981.** | Tier 4 already has a code base; Tiers 1–3 (NFT/attestation/royalty) are net-new but small. |
| EURe is a **MiCA e-money token (EMT)** → **no interest/yield to holders** allowed. | Receipts must not promise yield; revenue-share belongs to Tier 4 structuring, not to a "receipt". |

---

## 3. The Receipt→Security spectrum (Tiers 0–4)

```mermaid
flowchart LR
    T0["Tier 0<br/>Off-chain receipt<br/>(DB row + wall)"]
    T1["Tier 1<br/>On-chain ATTESTATION<br/>EAS / signed claim<br/>(non-transferable)"]
    T2["Tier 2<br/>SBT badge<br/>ERC-721 soulbound<br/>(non-transferable)"]
    T3["Tier 3<br/>Collectible NFT<br/>ERC-721 + EIP-2981<br/>(transferable, royalties)"]
    T4["Tier 4<br/>Security token / RWA<br/>ERC-3643 or ERC-20 equity<br/>(permissioned transfer)"]
    T0 --> T1 --> T2 --> T3 -. "legal line: conveys financial rights" .-> T4
    style T0 fill:#eef
    style T1 fill:#e8f7ee
    style T2 fill:#e8f7ee
    style T3 fill:#fff6e6
    style T4 fill:#fde8e8
```

| Tier | Artifact | Transferable? | Conveys value? | Regime | Effort | Good for |
|---|---|---|---|---|---|---|
| **0** | DB receipt + support wall (✅ exists) | n/a | no | none | — | every donation |
| **1** | **EAS attestation** "address X contributed €Y to campaign Z @ t" | no (attestation) | no | none (proof) | **S** | verifiable donor proof, tax/audit trail, SEPA *and* on-chain |
| **2** | **Soulbound NFT** (ERC-721, transfer-locked) — supporter badge | no | no | none (collectible) | **M** | gamified supporter identity, POAP-style |
| **3** | **Collectible NFT** (ERC-721 + ERC-2981 royalty) — campaign art/edition | yes | no (utility/collectible) | outside MiCA/MiFID* | **M** | tradeable memorabilia, creator upside via royalties |
| **4** | **Security/RWA token** (equity, revenue-share, redeemable) | restricted | **yes** | MiFID II + Prospectus / **ECSPR** + KYC | **XL** | real fractional investment (the ITALK model) |

\* NFTs that are genuinely unique/collectible are outside MiCA; but a *large fungible series sold for expected profit* can be re-characterised as a security regardless of the ERC-721 wrapper (substance over form). See §4.

**Design stance:** the **"on-chain proof of donation"** the user is asking for is **Tier 1 (attestation)** as the universal default, optionally upgraded to **Tier 2/3** per campaign. **Tier 4 stays a separate, opt-in "investment campaign" product**, reusing `pinka-finance-mvp`.

---

## 4. Legal compass (EU / Croatia) — what makes it a security

This is a design input, **not legal advice**; every Tier-3/4 decision needs counsel sign-off.

```mermaid
flowchart TD
    A["Artifact issued to contributor"] --> B{"Financial return expected?<br/>(profit, revenue share,<br/>redemption, dividend, equity)"}
    B -- No --> C{"Transferable to others?"}
    C -- No --> T12["Tier 1/2: attestation / SBT<br/>→ no securities/MiCA issue"]
    C -- Yes --> D{"Unique collectible, or<br/>large fungible series sold<br/>for expected appreciation?"}
    D -- "Unique / collectible" --> T3["Tier 3: NFT collectible<br/>→ outside MiCA (NFT carve-out)<br/>→ royalties OK"]
    D -- "Fungible-for-profit" --> RE["⚠️ Re-characterisation risk<br/>treat as Tier 4"]
    B -- Yes --> E{"Is it a MiFID<br/>'transferable security'?<br/>(equity/bond-like)"}
    E -- Yes --> F["Tier 4: security token<br/>→ Prospectus Reg OR<br/>ECSPR (≤€5M, KIIS, authorised CSP)<br/>→ KYC + transfer restriction"]
    E -- "No, but money-like" --> G["MiCA token (ART/EMT/other)<br/>EURe=EMT → NO yield to holders<br/>→ usually NOT what a receipt should be"]
    RE --> F
```

Key anchors:
- **MiCA (EU 2023/1114):** governs crypto-assets that are *not* financial instruments. EURe = **EMT → no interest/yield to holders** (don't promise donors yield). Genuinely unique **NFTs are carved out**; fractionalised/large series are not.
- **MiFID II + Prospectus Regulation:** equity/debt-like tokens are **transferable securities**. Public offer ⇒ prospectus unless exempt.
- **ECSPR (EU 2020/1503):** the realistic path for **equity/loan crowdfunding ≤ €5M / 12 mo** via an **authorised Crowdfunding Service Provider**, using a **Key Investment Information Sheet** instead of a full prospectus. ECSPR allows only a **bulletin board** (expressions of interest), **not** a real exchange.
- **DLT Pilot Regime (EU 2022/858):** the only sanctioned route to a *real* secondary **market** (MTF/settlement) for security tokens — heavyweight, licensed venues.
- **HANFA (HR regulator):** national competent authority for prospectus/ECSPR/MiFID in Croatia.

**Consequence for "secondary market with royalties":**
- Tier 3 (collectible) → trade anywhere, royalties are a contract/marketplace feature. ✅ feasible now.
- Tier 4 (security) → secondary trading is **permissioned and venue-restricted**; a "royalty" can only be a **protocol transfer fee** enforced by the compliant transfer hook, and resale needs an ECSPR bulletin board or a licensed venue. ⚠️ heavy.

---

## 5. Issuance architecture

### 5.1 Who is allowed to mint/attest? (the keyless-backend problem)

domovina-api cannot sign. Options, in order of preference:

```mermaid
flowchart TD
    subgraph Options
      O1["A) EAS attestation<br/>attester key in pay.domovina.ai<br/>cheap, no token, Tier 1"]
      O2["B) ReceiptIssuer contract<br/>MINTER_ROLE → ecosystem signer (pay)<br/>mints ERC-721 SBT/NFT, Tier 2/3"]
      O3["C) Safe module on campaign Safe<br/>'on EURe-in → mint receipt'<br/>most 'automatic', most audit"]
      O4["D) Lazy voucher (EIP-712)<br/>signed by attester, donor redeems<br/>(donor pays gas), gasless for platform"]
    end
    DB[("domovina-api ledger<br/>contribution = paid")] --> PAY["pay.domovina.ai<br/>(executive: holds keys)"]
    PAY --> O1 & O2 & O3 & O4
```

| Option | Mechanism | Pros | Cons | Fits tier |
|---|---|---|---|---|
| **A. EAS attester** | pay-side key signs an EAS attestation referencing `contribution_id`/donor address | cheapest, no NFT infra, revocable, great audit | not a "token" in wallets/markets | 1 |
| **B. ReceiptIssuer (mint on confirm)** | indexer/webhook → pay executes `mint(to, campaignId, …)` | real NFT in wallet, simple | platform pays gas; needs `to` address | 2,3 |
| **C. Safe module** | per-campaign Safe auto-mints on EURe-in | maximally "the Safe issues it", on-chain provenance | per-Safe module deploy, more complex, still needs `to` | 2,3 |
| **D. Lazy voucher** | pay signs EIP-712 voucher; donor calls `claim()` & pays gas | gasless for platform, donor opts in, perfect for SEPA | needs a claim UX; unclaimed vouchers expire | 1,2,3 |

**Recommendation:** **A + D**. Use **EAS attestations** as the universal Tier-1 proof (works even if donor has no wallet — attest to a derived/placeholder subject and re-point on claim), and **lazy EIP-712 vouchers** for Tier-2/3 tokens so the platform never custodies gas or guesses addresses. Reserve **C (Safe module)** for campaigns that want fully autonomous on-chain issuance.

> Note: confirm **EAS is deployed on Gnosis** (schema registry + attester); if not, fall back to a minimal `AttestationRegistry` contract or off-chain EIP-712 attestations verified on demand.

### 5.2 SEPA path — off-chain payment, on-chain *claim*

The donor pays by bank; they may have **no wallet**. So issuance is a **two-step claim**: the platform records an entitlement when EURe is confirmed, the donor later **claims** the on-chain artifact to their address.

```mermaid
sequenceDiagram
    actor D as Donor (bank)
    participant UI as pinka.io
    participant RAIL as pay.domovina.ai
    participant API as domovina-api
    participant ATT as Attester/Issuer (pay key)
    participant CH as Gnosis

    D->>UI: choose amount, (optional) "I want an on-chain receipt"
    UI->>API: create_contribution (pending)
    UI-->>D: EPC QR
    D->>RAIL: SEPA Instant
    RAIL->>CH: Monerium mint EURe → campaign Safe
    RAIL->>API: intent.paid (HMAC) → mark paid
    API->>API: token_positions row (status=pending) + receipt_claim (claimable)
    Note over API: off-chain entitlement exists now
    UI-->>D: "Receipt ready — connect wallet to claim"
    D->>UI: connect wallet (or Certilia→derived address)
    UI->>API: request claim (contribution_id)
    API->>ATT: authorize voucher (donor addr, campaign, amount, nonce)
    ATT-->>UI: EIP-712 voucher (signed)
    D->>CH: claim(voucher) → EAS attest / mint NFT to donor
    CH-->>API: (indexer) status=minted, attestation_uid set
    UI-->>D: ✅ on-chain receipt in wallet
```

Design notes:
- The **entitlement** (`receipt_claim`) is created at `paid`; the **on-chain artifact** is created at `claim`. Unclaimed entitlements are still provable off-chain (Tier 0) and can carry an **EAS attestation to a placeholder/Certilia-derived subject** so a proof exists even pre-claim.
- If the donor is **Certilia-verified**, we can bind the receipt to their verified identity (KYC) — needed if the campaign is Tier-4.

### 5.3 Direct on-chain path — auto-issue to the sender

Here the donor's address **is known** (the `from` of the EURe `Transfer`). We can **auto-issue** without a claim step.

```mermaid
sequenceDiagram
    actor D as Donor (wallet)
    participant CH as Gnosis
    participant IDX as Indexer (pay)
    participant API as domovina-api
    participant ISS as ReceiptIssuer / Safe module

    D->>CH: EURe transfer → campaign Safe (EIP-681)
    CH-->>IDX: Transfer log
    IDX->>API: record_onchain_contribution (paid, onchain_from=D)
    API->>API: token_positions (pending) + mark issue-eligible
    API->>ISS: authorize mint(to=D, campaign, amount, txref)
    ISS->>CH: mint receipt (SBT/NFT) to D  (or Safe module mints atomically)
    CH-->>API: status=minted, token_id/attestation_uid set
    Note over API: idempotent on (tx_hash, log_index) — no double issue
```

Design notes:
- This is the **"Safe multisig automatically issues a substitute token"** the user described. Two flavours: (B) pay-triggered `ReceiptIssuer.mint`, or (C) a **Zodiac-style Safe module** that mints atomically on EURe-in. Start with B; graduate to C for campaigns that want trustless autonomy.
- **One receipt per Transfer log** (reuse the existing `(forward_tx_hash, onchain_log_index)` idempotency key).

---

## 6. Token-standard mapping & contracts

```mermaid
classDiagram
    class ReceiptAttestation_EAS {
      +schema: contributionId, campaignId, donor, amountCents, paidAt, rail
      +revocable: true
      +nonTransferable: by-nature
    }
    class SupporterSBT_ERC721 {
      +soulbound (transfer reverts)
      +tokenURI: campaign art + tier
      +mint(to, campaignId)
    }
    class CollectibleNFT_ERC721 {
      +transferable
      +ERC2981 royaltyInfo(salePrice)
      +optional ERC721C transferValidator
    }
    class SecurityToken {
      <<Tier 4 - separate track>>
      +PinkaToken ERC20 equity (exists)
      +or ERC3643 (T-REX) permissioned
      +allowlist/identity gating
      +transfer fee hook = 'royalty'
    }
    ReceiptAttestation_EAS <|.. SupporterSBT_ERC721 : upgrade
    SupporterSBT_ERC721 <|.. CollectibleNFT_ERC721 : unlock transfer
    CollectibleNFT_ERC721 ..> SecurityToken : legal line crossed
```

- **Tier 1:** EAS schema (no new token contract).
- **Tier 2:** one **`PinkaReceipt721`** with a soulbound switch (transfers revert unless `TRANSFERER_ROLE`) — mirrors the allowlist/role pattern already used in `PinkaToken`.
- **Tier 3:** same contract with transfers enabled + **ERC-2981**; add **ERC-721C** validator only if royalty enforcement matters (see §7).
- **Tier 4:** reuse **`pinka-finance-mvp` (`PinkaToken`/`PinkaFactory`)** or migrate to **ERC-3643 (T-REX)** for standardised identity/transfer compliance. This is where ITALK lives.

---

## 7. Secondary market & royalties

```mermaid
flowchart TD
    subgraph Collectible["Tier 3 — collectible NFT"]
      M1["List on any NFT marketplace<br/>(OpenSea/Gnosis markets) or own UI"]
      R1["ERC-2981 royaltyInfo()<br/>recipient = campaign Safe / creator / platform split"]
      E1["Enforcement reality:<br/>ERC-2981 is ADVISORY.<br/>For hard enforcement → ERC-721C<br/>transfer validator + allowlisted markets"]
      M1 --> R1 --> E1
    end
    subgraph Security["Tier 4 — security token"]
      M2["Resale is PERMISSIONED:<br/>ECSPR bulletin board (interest only)<br/>or licensed MTF / DLT-TSS"]
      R2["'Royalty' = protocol TRANSFER FEE<br/>enforced inside compliant transfer hook<br/>(you already control transfers)"]
      E2["KYC/allowlist both sides;<br/>HANFA/ECSPR obligations;<br/>no open AMM/DEX"]
      M2 --> R2 --> E2
    end
```

**Answering the user's question directly:**

- *"Does the on-chain proof become a security the user can trade?"* — **Only if you make it one.** A receipt/attestation/SBT (Tiers 1–2) is **not** tradeable by design. A collectible NFT (Tier 3) is freely tradeable but is **not a security** as long as it conveys **no financial return** — it's memorabilia. It becomes a **security (Tier 4)** the moment it carries revenue-share/equity/redemption; then trading is **restricted** to permissioned/licensed venues.

- *"How to set up a secondary market with royalties?"*
  - **Collectible route (recommended first):** mint Tier-3 NFTs, set **ERC-2981** royalty (e.g., split: creator X% / campaign Safe Y% / platform Z%), optionally **ERC-721C** for enforcement, and either list on existing markets or run a thin in-app order book. Royalties flow on-chain in EURe/xDAI on each sale. **No securities licence needed.**
  - **Security route:** royalties become a **transfer fee** inside the compliant transfer function; resale happens on an **ECSPR bulletin board** (matching, not executing) or a **licensed MTF**. Requires authorised CSP/venue, KYC on both sides, and counsel. **Do not** expose Tier-4 tokens to open DEX/AMM liquidity.

---

## 8. Data-model changes

Extend the existing schema rather than replace it.

```mermaid
erDiagram
    contributions ||--o| token_positions : "1:1 (exists)"
    contributions ||--o| receipt_claims : "entitlement (NEW)"
    token_positions ||--o{ onchain_artifacts : "attest/mint events (NEW)"
    campaigns ||--o| receipt_policy : "per-campaign config (NEW)"

    receipt_policy {
      uuid campaign_id PK
      enum tier "none|attestation|sbt|collectible|security"
      text contract_address "issuer/collection"
      jsonb royalty "bps + recipients split"
      bool requires_kyc "force Certilia for claim"
      jsonb art "tokenURI template / metadata"
    }
    receipt_claims {
      uuid id PK
      uuid contribution_id FK
      text subject_address "donor wallet (null until claim)"
      enum state "claimable|voucher_issued|minted|expired"
      text voucher_sig "EIP-712 (pay-signed)"
      timestamptz expires_at
    }
    onchain_artifacts {
      uuid id PK
      uuid token_position_id FK
      enum kind "eas|erc721|erc20"
      text tx_hash
      text attestation_uid
      text token_id
      timestamptz minted_at
    }
```

Reuse: `token_positions` (status `pending→minted→transferred→burned`), `contributions.contributor_verified` (KYC gate for Tier-4 claims), existing idempotency keys.

---

## 9. Receipt lifecycle (state machine)

```mermaid
stateDiagram-v2
    [*] --> Paid: contribution confirmed (SEPA/on-chain)
    Paid --> EntitlementCreated: token_positions(pending) + receipt_claim(claimable)
    EntitlementCreated --> Attested: Tier1 EAS attestation (auto)
    EntitlementCreated --> VoucherIssued: donor requests claim (Tier2/3)
    Attested --> VoucherIssued: upgrade to token
    VoucherIssued --> Minted: donor redeems voucher / auto-mint (on-chain path)
    Minted --> Transferred: Tier3 secondary sale (royalty paid)
    Minted --> Burned: refund / redemption
    VoucherIssued --> Expired: not claimed in TTL
    Expired --> [*]
    Transferred --> [*]
    Burned --> [*]
```

---

## 10. Phased roadmap

```mermaid
gantt
    dateFormat YYYY-MM-DD
    axisFormat %b
    title On-chain receipts → tokenization
    section R1 Attestations (Tier1)
    EAS on Gnosis spike + schema        :r1a, 2026-06-08, 5d
    receipt_policy + receipt_claims DB  :r1b, after r1a, 4d
    pay-side attester + claim UI        :r1c, after r1b, 7d
    section R2 SBT badges (Tier2)
    PinkaReceipt721 (soulbound)         :r2a, after r1c, 6d
    lazy voucher claim + on-chain auto-issue :r2b, after r2a, 6d
    section R3 Collectibles + royalties (Tier3)
    enable transfer + ERC-2981/721C     :r3a, after r2b, 6d
    royalty split + in-app market/listing :r3b, after r3a, 8d
    section R4 Security track (separate)
    legal: ECSPR/CSP + KIIS + HANFA     :r4a, 2026-07-01, 30d
    wire pinka-finance-mvp to platform  :r4b, after r4a, 14d
    permissioned secondary (bulletin/MTF) :r4c, after r4b, 21d
```

**R1** delivers the user's core ask (on-chain proof for SEPA *and* on-chain donations) with the least legal load. **R2–R3** add wallet-visible tokens and a royalty-bearing collectible market. **R4** is the regulated investment product, gated behind legal work, reusing the existing equity contracts.

---

## 11. Open decisions (to iterate before building)

1. **Default receipt tier** — should *every* paid donation get a Tier-1 EAS attestation automatically, or only when the donor opts in / the campaign enables it?
2. **Claim model** — lazy voucher (donor pays gas, opt-in) vs platform-paid auto-mint vs Certilia-derived custodial address for wallet-less donors? (Recommendation: lazy voucher + EAS-to-Certilia-subject fallback.)
3. **EAS vs custom registry** — is EAS live on Gnosis with an attester we can run, or do we ship a minimal `AttestationRegistry`?
4. **Issuer identity** — receipts minted by a **platform-wide** collection or a **per-campaign** Safe/collection? (Per-campaign = cleaner provenance, more deploys.)
5. **Royalty policy (Tier 3)** — split between creator / campaign Safe / platform, and do we need **hard enforcement** (ERC-721C) or is ERC-2981 advisory enough?
6. **Tier-4 appetite** — do we actually want to run regulated equity crowdfunding now (ECSPR/CSP partner), or keep `pinka-finance-mvp` as a separate pilot (ITALK) and *not* expose donation receipts as securities?
7. **KYC binding** — bind every receipt to Certilia identity, or only Tier-4? (Privacy vs compliance trade-off.)

---

## 12. Risks & non-goals

- **Re-characterisation risk:** marketing a Tier-3 collectible with "it'll be worth more / you get a cut" turns it into a Tier-4 security. Keep receipt messaging strictly *proof-of-support*.
- **EMT yield ban:** never present held-EURe yield as a donor benefit.
- **Royalty enforceability:** ERC-2981 is honoured only by cooperating markets; set expectations or use ERC-721C.
- **Key surface:** any new attester/minter key expands the pay-side trust boundary — scope it tightly (mint-only role, per-campaign caps), mirroring the existing payout signer model.
- **Non-goals (for now):** open DEX/AMM liquidity for any Pinka token; promising returns on donations; cross-chain receipts (Gnosis-only to match EURe).
```
