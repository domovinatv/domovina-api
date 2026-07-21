# 04 — Dokumentacija: sinkronizacija i praznine

Kod je ispred dokumentacije ~6 tjedana. `docs/TODO.md` kaže "Last updated 2026-05-26", a
cijeli lipanjski Pinka build (~20 migracija, 4 edge fn, yield/payout ledger), RevenueCat rad
i fiskal redirect-URL commit nisu u njemu.

## Konkretne nekonzistentnosti

| Dok | Problem |
|-----|---------|
| `docs/TODO.md` | Stale header; dupli "## Done (recent)" heading; **nijedan Pinka item**; ne spominje RevenueCat ni fiskal-app redirect (`f0130a3`), koji već djelomično rješava hot-path "Verify ADDITIONAL_REDIRECT_URLS" |
| `docs/deployment-runbook.md` | Checklist proturječi TODO.md (Resend/migracija/prvi frontend prikazani kao nedovršeni iako su gotovi); referencira nepostojeći `0001_profiles.sql` (migracije počinju od `20260520120100_core_identity.sql`) |
| `docs/sso-architecture.md` | Prikazuje zastarjeli `0001_profiles.sql` email/profiles model (zamijenjen v3 accounts/memberships shemom); redirect lista bez fiskal domena i `ai.domovina://` deep linka |
| `docs/setup-guides/README.md` | Resend "⏳ DNS needed" iako je verified; Google OAuth "awaiting setup" dok handoff 2026-05-28 kaže "već radi i NE treba dirati" — direktna kontradikcija |
| `docs/secret-rotation.md §3d` vs `deployment-runbook.md` | Jedan kaže `db-rotate-postgres-password.sh` postoji (postoji), drugi ga vodi kao TODO |

## Praznine
- Nema doc za edge fn `youtube-claim`, `account-delete`, `auth-send-email`, `safe-owner-add`.
- `revenuecat-webhook` nema doc osim primjera u `backend-architecture.md` (upućuje na cross-repo).
- Pinka subscriptions/schedule (20260606) i campaign KYC/location/hardening (20260610–11)
  migracije bez doc updatea.
- Deploy journal (`deploys/INDEX.md`) nema unosa nakon 2026-06-05 unatoč kasnijim commitovima.
- 🔴 Rotacijski red iz 2026-05-29 još označen OPEN (vidi dok. 02 OPS-2).

> **Autonomni prompt**
> Sinkroniziraj dokumentaciju `domovina-api` sa stvarnim stanjem koda (danas je 2026-07-10;
> zadnji rad: `20260628120000_revenuecat_subscriptions.sql`, `revenuecat-webhook` fn, commit
> `f0130a3`). Konkretno: (1) prepiši `docs/TODO.md` — makni dupli "Done (recent)" heading,
> označi dovršene hot-path iteme (ADDITIONAL_REDIRECT_URLS je djelomično riješen commitom
> `f0130a3`), i dodaj Pinka + RevenueCat sekciju stanja (pull iz `docs/pinka-aave-yield-handoff.md §3`);
> (2) u `docs/deployment-runbook.md` i `docs/sso-architecture.md` ukloni reference na nepostojeći
> `0001_profiles.sql` i ažuriraj checkliste/shemu na stvarno stanje; (3) uskladi
> `docs/setup-guides/README.md` status kolonu (Resend verified, Google OAuth radi); (4) razriješi
> kontradikciju oko `db-rotate-postgres-password.sh` (postoji). Provjeri svaku tvrdnju protiv
> koda/git historije prije nego je zapišeš — ne prepisuj napamet. Ne diraj sigurnosni sadržaj
> `secret-rotation.md §2` osim da ažuriraš status ako je rotacija u međuvremenu napravljena.

> **Autonomni prompt (nedostajući edge-fn docs)**
> Napiši kratke doc stranice (`docs/edge-functions/<name>.md`) za edge funkcije koje ih nemaju:
> `youtube-claim`, `account-delete`, `auth-send-email`, `safe-owner-add`, `revenuecat-webhook`.
> Svaka: svrha, auth model (verify_jwt, tko smije zvati), ulaz/izlaz, vanjski servisi, env varijable,
> idempotentnost. Izvuci istinu iz koda u `supabase/functions/<name>/index.ts`, ne izmišljaj.
