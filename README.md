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

## Licenca

MIT — vidi [`LICENSE`](LICENSE).
