# Deploy journal

Regresijski dnevnik deployeva. **Svaki deploy = jedan neovisan, immutable milestone**
(`<UTC-ts>-<shortsha>.md`) s **punim snapshotom** stanja backenda u tom trenutku —
ne delta. Ako nešto pukne, ovdje je uvijek zapis kako je izgledao deployment u
zadnjoj poznato-dobroj točki.

## Što milestone sadrži

- **git** — short/full SHA (link na GitHub commit), grana, subject, pushan?, dirty count
- **migracije** — live `supabase_migrations.schema_migrations`: count, head i **puna lista**
- **edge funkcije** — deployani set iz `supabase/functions/`
- **containeri** — live `docker ps` supabase-* (`name|image|status`) → točne verzije image-a
- **ops-verify** — PASS/FAIL health rezultata
- **operator** + slobodna bilješka

## Kako se piše

Automatski na kraju `./scripts/deploy.sh` (zadnji korak, `--commit`). Ručno:

```bash
./scripts/deploy-journal.sh --verify --commit            # snimi + ops-verify + commit
./scripts/deploy-journal.sh --note "migration-only" --commit
./scripts/deploy-journal.sh --dry-run                    # pregled, ništa ne piše
```

## Regresija

Puni snapshot po deployu znači da je delta = obični `git diff`:

```bash
# što se promijenilo (migracije / image-i / funkcije) između dva deploya
git diff deploys/<stariji>.md deploys/<noviji>.md

# kronologija
cat deploys/INDEX.md
```

Milestone fajlovi se **ne uređuju nakon zapisa** — to je njihova vrijednost kao
fiksne regresijske točke. [INDEX.md](INDEX.md) je kronološki indeks (najnoviji gore).
