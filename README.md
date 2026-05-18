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

## Secrets

Sve tajne (JWT secret, DB password, service/anon JWT, MinIO, Logflare, Supavisor, Vault enc key, dashboard admin) **generiraju se offline** skriptom:

```bash
./scripts/generate-coolify-secrets.sh   # kopira sve KEY=VALUE u clipboard
```

Zatim **paste u Coolify** → Service → Environment Variables. **Nikad ne commit-aj `.env`.**

## Status deploymenta

Vidi [`docs/deployment-runbook.md`](docs/deployment-runbook.md) za trenutni stage i sljedeće korake.

## Licenca

MIT — vidi [`LICENSE`](LICENSE).
