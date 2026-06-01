# domovina-api

Centralizirani API i identity provider za sve **domovina.\*** proizvode — `domovina.ai`, `domovina.energy`, `domovina.tv` i sve buduće aplikacije pod brendom.

Pod haubom: **self-hosted Supabase** (Postgres + GoTrue + PostgREST + Realtime + Storage + Edge Functions + Studio + Logflare + MinIO), deployan preko **Coolify**, eksponiran kroz **Cloudflare Tunnel**.

> Public endpoint: **https://api.domovina.ai** (jedini Kong gateway za sve servise)

## Što je ovdje

Ovaj repo NIJE Supabase source code — to je **infrastruktura kao kod + dokumentacija** za naš self-hosted deployment:

- `docs/` — arhitektura, SSO model, deployment runbook, troubleshooting
- `scripts/` — pomoćne skripte (generiranje secreta, smoke testovi, migracije)
- `cloudflared/` — Cloudflare Tunnel ingress konfiguracija
- `supabase/` — DB migracije, Edge Functions, RLS policies, seed podaci
- `.env.example` — template za Coolify env vars (BEZ secreta)

## Brzi pregled SSO arhitekture

```
┌─────────────────┐  ┌──────────────────┐  ┌──────────────┐
│  domovina.ai    │  │ domovina.energy  │  │ domovina.tv  │
│  (Next/Vite)    │  │ (Next/Vite)      │  │ (Next/Vite)  │
└────────┬────────┘  └────────┬─────────┘  └──────┬───────┘
         │                    │                   │
         └────────────────────┼───────────────────┘
                              ▼
                  https://api.domovina.ai
                  (Supabase Kong gateway)
                              │
         ┌────────────────────┼─────────────────────┐
         ▼                    ▼                     ▼
     GoTrue Auth         PostgREST              Storage
   (zajednički user)   (RLS po user_id)       (MinIO S3)
```

Detaljnije: [`docs/sso-architecture.md`](docs/sso-architecture.md)

## Hosting topologija

```
Internet
   │
   ▼  (HTTPS, SSL na Cloudflare edge)
Cloudflare Edge
   │
   ▼  (Cloudflare Tunnel, encrypted)
cloudflared container (na Coolify hostu)
   │
   ▼  (HTTP)
Traefik :80  ── Coolify-managed labels po Host headeru
   │
   ├──> supabase-kong:8000        (api.domovina.ai)
   ├──> supabase-studio:3000      (studio.domovina.ai, iza CF Access)
   └──> supabase-minio:9000       (s3.domovina.ai, opcionalno)
```

## Secrets workflow (zero leakage)

Niti jedan secret ne završi u repo-u niti u chat transkriptu. Workflow:

1. **U Coolifyju kreiraj svjež Supabase service** (Coolify auto-generira sve env vars sa svojim placeholder vrijednostima).
2. **Otvori Environment Variables → Developer view → kopiraj sve** → spremi lokalno kao `.coolify-defaults.env` (gitignored — Coolify defaults samo služe kao struktura/baseline).
3. **Kopiraj `cp .local-secrets.env.example .local-secrets.env`** i u njemu popuni:
   - `SMTP_PASS` = Resend API key
   - `OPENAI_API_KEY` (opcionalno)
4. **Pokreni:**
   ```bash
   ./scripts/build-coolify-env.sh
   ```
   Skripta:
   - generira sve secrets fresh (`SERVICE_PASSWORD_*`, `SERVICE_USER_*`, HS256 JWT-ovi za `anon` i `service_role`, `SECRET_KEY_BASE`)
   - override-uje config (`api.domovina.ai`, SSO redirect URL-ovi, Studio brand, phone signup OFF, ...)
   - merge-a Coolify defaults + naše override-e + local secrets
   - **kopira finalni env u clipboard** (pbcopy/xclip/wl-copy)
   - na stdout pokazuje **samo maskirani preview** (`Jb6L****k9Mz`)
5. **U Coolifyju → Environment Variables → Developer view → Cmd+A → Paste → Save → Deploy**.

Merge layers (kasnije prepisuje ranije):
```
.coolify-defaults.env  →  hardcoded overrides + fresh secrets  →  .local-secrets.env
```

**Rotation** = pokreni skriptu ponovno, paste novi env, redeploy. Rotacija u 30 sekundi.

## Status deploymenta

Vidi [`docs/deployment-runbook.md`](docs/deployment-runbook.md) za trenutni stage i sljedeće korake.

## Verzije Supabasea (lokal ↔ prod)

Coolify NE auto-update-a Supabase; verzije su pinane i bumpaju se ručno. Model,
siguran upgrade postupak i staging preporuka: [`docs/supabase-version-management.md`](docs/supabase-version-management.md).
Živi snapshot tagova: [`docs/supabase-versions.md`](docs/supabase-versions.md) (`scripts/supabase-versions.sh --write`).

## DB migrations workflow

Sav schema-as-code za `public.*` i `domovina_ai.*` živi u [`supabase/migrations/`](supabase/migrations/). App repos (`domovina.ai`, `domovina.energy`, ...) **samo konzumiraju** kroz `supabase_flutter` / `supabase-js` SDK — nikad ne definiraju schemu.

### One-time setup

```bash
# 1) Popuni SSH access u .local-secrets.env (kopiraj iz .example)
cp .local-secrets.env.example .local-secrets.env
# Edit i postavi:
#   COOLIFY_SSH_HOST=ubuntu@89.168.100.120
#   COOLIFY_SSH_KEY=~/.ssh/dom-001-oracle-ssh-key-2026-04-20.key

# 2) Verify SSH access
./scripts/db-psql.sh -c '\dn'
# Treba pokazati listu schemas (public, auth, storage, ...)
```

### Apply pending migracije

```bash
./scripts/db-status.sh           # pokaži applied vs pending
./scripts/db-migrate.sh          # pg_dump backup + apply pending u transakciji
./scripts/db-migrate.sh --dry-run        # samo pokaži plan
./scripts/db-migrate.sh --no-backup      # preskoči pg_dump (brže za dev)
```

Tracking ide u `supabase_migrations.schema_migrations` (kompatibilno s Supabase CLI-em ako kasnije instaliraš).

### Nova migracija

```bash
# Filename: YYYYMMDDHHMMSS_<area>_<what>.sql (sortable po prefiksu)
NEW="supabase/migrations/$(date -u +'%Y%m%d%H%M%S')_my_change.sql"
$EDITOR "$NEW"
# Napiši IDEMPOTENTAN SQL (create if not exists, create or replace function,
# drop trigger if exists pa create).

./scripts/db-migrate.sh --dry-run
./scripts/db-migrate.sh
git add supabase/migrations/
git commit -m "feat(db): <what>"
git push
```

### Pomoćne komande

```bash
./scripts/db-psql.sh                                    # interaktivni psql na live DB
./scripts/db-psql.sh -c "select * from public.profiles" # one-shot query
./scripts/db-dump.sh                                    # schema-only dump public + domovina_ai
./scripts/db-dump.sh --data                             # full dump (schema + data)
./scripts/db-dump.sh --schemas auth                     # specific schemas
```

Sve scripte koriste **SSH + docker exec psql** — bez tunela, bez izlaganja DB porta javnosti. Auto-detect-aju `supabase-db-*` container preko `docker ps`.

### Schema referenca

Detaljan spec, ERD i argumentacija žive u [`domovina.ai` repo-u](https://github.com/domovinatv/domovina.ai):
- [`docs/auth-and-database-plan-v3.md`](https://github.com/domovinatv/domovina.ai/blob/main/docs/auth-and-database-plan-v3.md) — principi (PII u `auth.users`, slug immutable, soft-delete only `accounts`)
- [`docs/schema-v3.dbml`](https://github.com/domovinatv/domovina.ai/blob/main/docs/schema-v3.dbml) — formal DBML
- [`docs/backend-prompts/01-07`](https://github.com/domovinatv/domovina.ai/tree/main/docs/backend-prompts) — implementacijske recepture iz kojih su generirane migracije ovdje

## Licenca

MIT — vidi [`LICENSE`](LICENSE).
