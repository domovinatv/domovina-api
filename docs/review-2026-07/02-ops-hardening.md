# 02 — Ops hardening & backup

Ops tooling je iznad prosjeka (svi scriptovi `set -euo pipefail`, destruktivne operacije
imaju `-y` potvrdu, secrets uglavnom maskirani). Ovo su preostali rizici i praznine.

---

## 🔴 OPS-1 — Nema offsite backupa: gubitak servera = gubitak baze

**Severity:** Kritično · **Datoteka:** `scripts/server/pg-backup.sh:15-17`

Backup dumpovi žive **samo na istom Oracle hostu** (89.168.100.120) koji vrti bazu,
`RETENTION_DAYS=14`, bez enkripcije, bez restore testa, bez success alerta (failure ide
samo u log koji nitko ne gleda). Kvar diska / gubitak instance / ransomware uništi bazu
**i** sve backupe zajedno. Ovo je auth + payments (RevenueCat/Pinka) baza — RPO trenutno
do 24h, a katastrofalni scenarij je totalni gubitak.

**Fix:**
1. Nakon dumpa: `age`-enkripcija pa `rclone`/`aws s3 cp` na Cloudflare R2 (račun već postoji,
   vidi `scripts/storage-r2-switch.sh:26`).
2. Alert preko postojećeg Telegram `notify` obrasca (`scripts/server/healthcheck.sh`) na failure.
3. Mjesečni skriptirani restore-test u scratch kontejner.
4. Backup-freshness check (najnoviji `.gz < 26h) u healthcheck cron.

> **Autonomni prompt**
> U `domovina-api`, `scripts/server/pg-backup.sh` sprema backupe samo lokalno na isti server
> koji vrti bazu (nema offsite, nema enkripcije, nema alerta). Nadogradi backup strategiju:
> (1) izmijeni `pg-backup.sh` da dumpa u `$OUT.tmp`, verificira `gzip -t`, `mv` na uspjeh,
> `rm -f` u trap-u; (2) enkriptiraj `.gz` s `age` (recipient iz `.local-secrets.env`) i uploadaj
> na Cloudflare R2 preko `rclone` (creds iz env, nikad iz argv); (3) na failure pošalji Telegram
> alert koristeći isti obrazac kao `scripts/server/healthcheck.sh`; (4) dodaj u `healthcheck.sh`
> provjeru da je najnoviji backup mlađi od 26h; (5) napiši novi `scripts/server/pg-restore.sh`
> koji restore-a enkriptirani R2 backup u lokalni ili scratch kontejner (za restore-test).
> Ažuriraj `scripts/server/install-*.sh` da deployaju izmjene. Sve secrets drži izvan argv
> (stdin/env/keyfile). Ne izvršavaj protiv živog servera — samo napiši i objasni deployment.

---

## 🟠 OPS-2 — Rotacija procurenih secreta (incident 2026-05-29) još otvorena

**Severity:** Visoko · **Izvor:** `docs/secret-rotation.md §2`

Bug u `coolify-env-merge.sh` je 2026-05-29 iznio živi env u chat. Rotacijski red je i dalje
"⏳ OTVORENO — odgođeno na maintenance window" (~6 tjedana). JWT rotacija lomi frontende dok
ne dobiju novi anon key, pa je odgođeno — ali ostali secreti (DB pass, service keys, API
tokeni) se mogu rotirati neovisno.

> **Autonomni prompt**
> U `domovina-api`, `docs/secret-rotation.md §2` navodi otvoreni rotacijski red iz incidenta
> 2026-05-29 (procureli živi env). Pročitaj taj dokument i `docs/security-hardening.md`, pa
> napravi plan rotacije razdvojen na (a) secrete koji se mogu rotirati odmah bez lomljenja
> frontenda (DB password preko `scripts/db-rotate-postgres-password.sh`, API tokeni, Resend key,
> R2 keys) i (b) JWT/anon key koji traži najavljeni maintenance window i koordinaciju s frontendima.
> Za (a) pripremi točan redoslijed komandi (bez izvršavanja). Za svaki secret navedi gdje se
> mijenja (Coolify env, host `.env`, koji servisi se recreate-aju) i kako se verificira. NE
> izvršavaj rotaciju — samo pripremi runbook i označi što traži moju potvrdu.

---

## 🟠 OPS-3 — Secrets u `ps` / stdout tijekom rotacije lozinke

**Severity:** Visoko · **Datoteke:** `scripts/db-rotate-postgres-password.sh:87,104,119`, `scripts/storage-r2-switch.sh:36,101`

- Nova PG lozinka se ispisuje u cleartextu na stdout (`:119`) — proturječi mask-everything
  konvenciji i lekciji iz 2026-05-29.
- Stara i nova lozinka idu u remote argv (`docker exec -e PGPASSWORD=...`, `sed`) → vidljivo u
  server `ps`/audit logu. Repo već ima ispravan obrazac: `coolify-env-set.sh:127` šalje vrijednost
  preko ssh **stdin**.
- `storage-r2-switch.sh` prima R2 kredencijale kao pozicijske argumente i šalje cijeli compose
  sa secretima kao base64 blob u ssh command line-u.

> **Autonomni prompt**
> U `domovina-api` popravi curenje secreta u process-list/stdout: (1) u
> `scripts/db-rotate-postgres-password.sh` novu lozinku ne ispisuj u cleartextu (`:119`) nego
> stavi na clipboard/maskiraj, i proslijedi stare/nove lozinke preko ssh **stdin** umjesto argv
> (`:87,:104`) — koristi isti obrazac kao `scripts/coolify-env-set.sh:127`; (2) u
> `scripts/storage-r2-switch.sh` čitaj R2 kredencijale iz `.local-secrets.env`/env umjesto
> pozicijskih argumenata (`:36`), i pošalji patchani compose preko ssh stdin umjesto base64 u
> command line-u (`:101`), te čisti `/tmp` temp fajlove s `mktemp -d` pod trap-om. Ne izvršavaj
> protiv živog servera; testiraj `bash -n` i objasni ručnu verifikaciju.

---

## 🟡 Srednji ops nalazi

### OPS-M1 — Pre-migration "backup" je schema-only, poruka zavarava
`db-migrate.sh:87` dumpa `--schema-only`, a `:115` na grešci kaže "Restore from backup". Migracija
koja briše/prepisuje podatke se **ne može** vratiti iz tog fajla. Ili pokreni server `pg-backup.sh`
prije migracije, ili preimenuj poruku u "schema reference, NIJE data backup".

### OPS-M2 — Unbound-variable crash u `db-migrate.sh --no-backup`
`:113-116` interpolira `${TS}` koji je postavljen samo unutar `if $DO_BACKUP`. Uz `set -u`,
failajuća migracija pod `--no-backup` umre s `TS: unbound variable`. Fix: `TS=${TS:-}`.

### OPS-M3 — `pg-backup.sh` ostavlja korumpiran parcijalni fajl na failure
`:44-47` ako `pg_dump` padne, truncani `.gz` ostaje i broji se kao backup; 14 dana takvih
failova istisne zadnji dobar dump. Dump u `.tmp` + `gzip -t` + `mv` na uspjeh (dio OPS-1 prompta).

### OPS-M4 — Healthcheck gleda krivi filesystem
`healthcheck.sh:71` radi `df /`, a backupi rastu pod `/data/coolify/backups`. Ako je `/data`
zaseban mount, može se napuniti neopaženo (baza stane). Provjeri i `/` i `/data`.

### OPS-M5 — Argument quoting se gubi kroz dvostruki shell (`db-env.sh:73`)
`$*` flatta argumente pa `db-psql.sh -c "select count(*) from x"` puca remotely. Koristi
`printf '%q '` po argumentu ili dokumentiraj `--stdin` kao jedini multi-word put.

> **Autonomni prompt (srednji ops)**
> U `domovina-api` riješi: (1) `db-migrate.sh` — preimenuj zavaravajuću "Restore from backup"
> poruku (`:115`) jer je pre-dump schema-only, i popravi `TS: unbound variable` crash pod
> `--no-backup` (`TS=${TS:-}`); (2) `scripts/lib/db-env.sh:73` — očuvaj quoting kroz ssh sloj
> koristeći `printf '%q '` po argumentu; (3) provjeri jesu li OPS-M3 (parcijalni backup) i
> OPS-M4 (`df /` vs `/data`) već pokriveni OPS-1 promptom, ako ne — popravi ih. Testiraj `bash -n`,
> ne diraj živi server.

---

## Missing tooling (dodati kad stigne)

| # | Alat | Zašto |
|---|------|-------|
| T1 | `pg-restore.sh` | Backup priča je jednosmjerna i netestirana (dio OPS-1) |
| T2 | Offsite/enkriptirani shipper | rclone→R2 + age (dio OPS-1) |
| T3 | Migration rollback / down-migracije | Forward-only, nema brzog undo |
| T4 | **CI** (`.github/workflows/`) | Nema shellcheck, migration-lint, `deno check`, ni **gitleaks** na PR-ovima — a repo je **javan** |
| T5 | Backup/health dashboard ili dnevni Telegram digest | Backup age, disk trend, cert/Apple-secret expiry na jednom mjestu |
| T6 | `deploy-functions.sh --prune` + checksum diff | Obrisane funkcije zauvijek ostaju u edge volumenu |
| T7 | Coolify DB (`coolify-db`) backup | Definicije servisa/env store nemaju dump job |
| T8 | WAL archiving / PITR (`wal-g`/`pgbackrest` → R2) | Dnevni dump = RPO do 24h za auth+payments bazu |
| T9 | `secrets-audit.sh` | Expiry reminderi za Coolify token, R2 keys, Resend key (poput `rotate-apple-secret.sh --check`) |
| T10 | logrotate za `/var/log/domovina-*.log` | 5-min cron log raste neograničeno |

> **Autonomni prompt (CI — najviši ROI od missing toolinga)**
> `domovina-api` je javan repo bez ikakvog CI-ja. Dodaj `.github/workflows/ci.yml` koji na PR
> pokreće: (1) `gitleaks` secret-scan (kritično jer je repo javan i već je bilo curenje secreta),
> (2) `shellcheck` na svim `scripts/**/*.sh`, (3) `deno check`/`deno lint` na `supabase/functions/**`,
> (4) migration-lint koji provjerava da migracije ne sadrže bare `COMMIT;` i da imaju timestamp
> prefix. Neka job-ovi budu neovisni i ne trebaju secrets (read-only na kodu). Objasni kako lokalno
> reproducirati svaki korak. Ne mijenjaj postojeće skripte osim ako lint nađe stvarni problem.

> **Autonomni prompt (down-migracije / rollback)**
> `domovina-api` migracije su forward-only bez rollbacka. Predloži lagani rollback mehanizam
> kompatibilan s `scripts/db-migrate.sh` (koji ima vlastitu tracking tablicu): npr. opcionalni
> `-- rollback:` blok u svakoj migraciji ili paralelni `migrations/down/` direktorij, plus
> `db-migrate.sh --rollback <version>`. Implementiraj minimalnu verziju + dokumentiraj u
> `docs/deployment-runbook.md`. Ne diraj živu bazu.
