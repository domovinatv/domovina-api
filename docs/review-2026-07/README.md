# Codebase review & roadmap — srpanj 2026

Puni pregled `domovina-api` repozitorija (self-hosted Supabase na Coolify: SSO jezgra,
Pinka donacijska platforma, RevenueCat pretplate). Review je rađen 2026-07-10 kroz
četiri paralelne analize: edge funkcije, SQL migracije + RLS, ops skripte + config,
te dokumentacija + roadmap.

Cilj dokumenta: **akcijski plan** — svaki nalaz i svaka predložena funkcionalnost ima
gotov *autonomni prompt* koji možeš zalijepiti u novu Claude Code sesiju da odradi posao.

## Sažetak stanja

Backend je **production-ready za MVP** i solidno izveden: RLS pokriva sve tablice, novac
se drži u cijelim centima (nema float), PII je minimiziran (OIB enkriptiran, IBAN samo
hash), idempotentnost webhookova je stvarna, SECURITY DEFINER funkcije uglavnom pinaju
`search_path = ''`. Ops tooling je iznad prosjeka za solo-dev. Ali review je našao
**2 potvrđena kritična/visoka sigurnosna propusta u bazi**, **1 visoki u edge sloju**,
**1 kritični ops rizik (backup)** i niz srednjih nekonzistentnosti + zastarjelu dokumentaciju.

## Dokumenti

| # | Dokument | Sadržaj |
|---|----------|---------|
| 01 | [`01-fixes-security-correctness.md`](01-fixes-security-correctness.md) | Sigurnosni i correctness nalazi (baza + edge) s promptovima |
| 02 | [`02-ops-hardening.md`](02-ops-hardening.md) | Backup/offsite, secrets u `ps`, CI, missing tooling |
| 03 | [`03-consistency-refactor.md`](03-consistency-refactor.md) | Duplikacija koda, `_shared` ekstrakcije, testovi |
| 04 | [`04-docs-hygiene.md`](04-docs-hygiene.md) | Zastarjela dokumentacija, TODO.md sinkronizacija |
| 05 | [`05-roadmap-features.md`](05-roadmap-features.md) | Nove funkcionalnosti logične uz postojeći sustav |

## Prioritetni redoslijed (ako radiš odozgo prema dolje)

1. 🔴 **SEC-1** — `v_continue_watching` cross-user leak (jednoretčani fix) → dok. 01
2. 🔴 **SEC-2** — `migrate_anon_data` krađa/brisanje tuđih podataka → dok. 01
3. 🔴 **OPS-1** — offsite enkriptirani backup (trenutno backup živi na istom serveru kao baza) → dok. 02
4. 🟠 **SEC-3** — handoff kod bez rate-limitinga (brute-force → account takeover) → dok. 01
5. 🟠 **SEC-4** — svix HMAC verifikatori divergirali (`pinka-webhook` ne strip-a `v1,`) → dok. 01 / 03
6. 🟠 **OPS-2** — rotacija procurenih secreta iz 2026-05-29 još otvorena → dok. 02
7. 🟡 Ostalo (M/L nalazi, refaktori, dokumentacija) → dok. 01–04
8. 🟢 Roadmap funkcionalnosti → dok. 05

## Kako koristiti autonomne promptove

Svaki nalaz ima blok `> **Autonomni prompt**`. Otvori novu Claude Code sesiju u repou i
zalijepi ga. Promptovi su pisani da budu samodostatni (referenciraju konkretne fajlove i
linije), ali **provjeri diff prije commita** — posebno za migracije i sve što dira secrets
ili živu bazu. Za promjene baze koristi `scripts/db-migrate.sh` (ne `deploy.sh`), za edge
funkcije `scripts/deploy-functions.sh`.
