# Deployment runbook

Stanje deploya: **LIVE** na `https://api.domovina.ai` i `https://studio.domovina.ai`.

Ovaj dokument je redoslijed koraka za **re-deploy from scratch** (npr. nakon brisanja Coolify resource-a) ili za novi environment.

## Status checklist

- [x] Coolify host (89.168.100.120) postavljen
- [x] `cloudflared` container exposa Traefik :80 preko Cloudflare Tunnela
- [x] Cloudflare DNS CNAME `api.domovina.ai`, `studio.domovina.ai` → tunnel
- [x] Tunnel Public Hostnames: `api.domovina.ai` i `studio.domovina.ai` → `http://traefik:80`
- [x] Cloudflare Access — `studio.domovina.ai` (cijela domena) + `api.domovina.ai` admin paths
- [x] Cloudflare WAF — Block `api.domovina.ai/` bare root
- [x] Coolify Supabase resource kreiran, env builded preko `scripts/build-coolify-env.sh`
- [x] Per-service Domain postavljen kroz Coolify UI (Settings dialog)
- [x] Deploy uspješan, svi servisi `Running (healthy)`
- [ ] Resend domena `domovina.ai` verified
- [ ] SMTP test (signup s pravim email-om → mail stiže)
- [ ] DB migracija `0001_profiles.sql` aplicirana
- [ ] Prvi frontend (domovina.ai) integriran sa Supabase auth

## Korak 1 — Coolify env (preko skripte, NE ručno)

```bash
# Prvi setup ili nakon Coolify upgrade-a:
#   1. Kreiraj svjež Supabase service u Coolifyju.
#   2. U Environment Variables → Developer view → kopiraj sve →
#      spremi u .coolify-defaults.env (gitignored).
#   3. cp .local-secrets.env.example .local-secrets.env  →  popuni SMTP_PASS
./scripts/build-coolify-env.sh
# Paste output u Coolify → Bulk edit → Save (NE Deploy još)
```

Vidi [README — Secrets workflow](../README.md#secrets-workflow-zero-leakage).

## Korak 2 — Per-service Domain (Coolify UI, NE env)

> **VAŽNO**: Coolify resetira `SERVICE_FQDN_*` env varove na sslip default. Domain se MORA postaviti kroz UI Settings dialog za svaku subuslugu.

Coolify → Service → **General** tab → scroll do **Services** lista. Pored svake subusluge klikni **Settings**:

| Subusluga | Domain field | Razlog |
|---|---|---|
| **Supabase Kong** | `http://api.domovina.ai:8000` | Public API gateway |
| **Supabase Studio** | `http://studio.domovina.ai:3000` | Admin UI (iza CF Access) |

**Dva neintuitivna detalja:**

1. **`http://` ne `https://`** — cloudflared se spaja na Traefik kroz HTTP (port 80). Ako staviš `https://`, Coolify dodaje `redirect-to-https` middleware → beskonačan redirect loop. HTTPS i dalje radi prema korisniku jer Cloudflare terminira SSL na edge-u.

2. **Port suffix `:8000` / `:3000`** je Coolify-interna meta za backend port mapping. Korisnik ga nikad ne vidi (Traefik translatira). Coolify note "Required Port: 8000" znači ovo.

## Korak 3 — Cloudflare Tunnel Public Hostnames

Zero Trust → **Networks → Tunnels** → tvoj tunel → **Public Hostnames**:

| Subdomain | Domain | Service Type | URL |
|---|---|---|---|
| `api` | `domovina.ai` | HTTP | `traefik:80` |
| `studio` | `domovina.ai` | HTTP | `traefik:80` |

HTTP Settings na oba: **No TLS Verify ON**, Keep-Alive timeout 90s (Realtime WS).

## Korak 4 — Cloudflare DNS

Cloudflare → `domovina.ai` zone → DNS:

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | `api` | `<TUNNEL_UUID>.cfargotunnel.com` | Proxied |
| CNAME | `studio` | `<TUNNEL_UUID>.cfargotunnel.com` | Proxied |

*(Cloudflare obično auto-stvori CNAME kad dodaš Public Hostname u Tunnel — provjeri DNS tab i ručno dodaj samo ako fali.)*

## Korak 5 — Cloudflare Access aplikacije

Zero Trust → **Access → Applications → Add an application → Self-hosted**.

### App 1: `Supabase Studio`
- Destination: subdomain `studio`, domain `domovina.ai`, path: *(prazno = sve)*
- Session Duration: 24h
- Policy: `Allow` → Emails: `ms@domovina.tv`, `stepanic.matija@gmail.com`, `domovinasync@gmail.com`
- Identity provider: One-time PIN (dodatno: Google OAuth za bolji UX)

### App 2: `Supabase Kong — Admin paths`
- Destinations (svaka kao zaseban Public Hostname unutar iste app-e):
  - `api.domovina.ai/dashboard*`
  - `api.domovina.ai/project*`
  - `api.domovina.ai/api/platform*`
- Session Duration: 24h
- Policy: ista email lista

## Korak 6 — Cloudflare WAF Custom Rule

Cloudflare → `domovina.ai` zone → **Security → WAF → Custom rules** → Create rule:

- **Rule name**: `Block bare root on api.domovina.ai`
- **Expression**:
  ```
  (http.host eq "api.domovina.ai" and http.request.uri.path eq "/")
  ```
- **Action**: Block

Blokira točno `api.domovina.ai/` (bare root). Sve API path-ovi (`/auth/v1/*`, `/rest/v1/*`, ...) i admin (`/dashboard*`) prolaze.

Free plan: 5 custom rules max — dovoljno za baseline.

## Korak 7 — Deploy

Coolify → Service → **Deploy** (žuti gumb gore desno). Ne Restart — Restart ne regenerira Traefik labele.

Prati **Logs** tab dok svi servisi ne pređu u `Running (healthy)` (~2-3 min).

## Korak 8 — Smoke test

```bash
# WAF block na bare root
curl -s -o /dev/null -w "/ → %{http_code}\n" https://api.domovina.ai/
# Očekivano: 403 (Cloudflare)

# Public API path-ovi (vrate 401 bez apikey-a — to znači Kong radi)
curl -s -o /dev/null -w "/auth/v1/health → %{http_code}\n" https://api.domovina.ai/auth/v1/health
curl -s -o /dev/null -w "/rest/v1/ → %{http_code}\n" https://api.domovina.ai/rest/v1/
# Očekivano: 401 ili 200 (s apikey header-om)

# S anon ključem
ANON=<paste-iz-Coolify-SUPABASE_ANON_KEY>
curl -s "https://api.domovina.ai/auth/v1/health" -H "apikey: $ANON"
# Očekivano: {"name":"GoTrue","version":"...","description":"..."}

# Admin path → CF Access challenge
curl -s -o /dev/null -w "/dashboard → %{http_code}\n" https://api.domovina.ai/dashboard
# Očekivano: 302 → cloudflareaccess.com login

# Studio → CF Access challenge
curl -s -o /dev/null -w "studio.domovina.ai → %{http_code}\n" https://studio.domovina.ai/
# Očekivano: 302 → cloudflareaccess.com login
```

## Korak 9 — DB migracije

```sql
-- U Studio → SQL Editor → New query → paste sadržaj iz:
--   supabase/migrations/0001_profiles.sql
-- Klik Run.
```

Provjera:
```sql
select * from public.profiles;       -- prazno na startu
select * from auth.users;            -- prazno
-- Nakon prvog signup-a profili.id == auth.users.id mora postojati (auto-trigger).
```

## Rotacija secreta

```bash
./scripts/build-coolify-env.sh     # generira sve fresh, copy u clipboard
# Coolify → Bulk edit → Cmd+A → Paste → Save → Deploy
```

**Caveat — Postgres password rotation**:
- Na **prvom deployu** (prazna baza) rotacija je sigurna.
- Na **postojećoj bazi** mora se ručno `ALTER USER postgres PASSWORD '...'` u SQL Editoru **prije** promjene env-a, inače Postgres odbija auth s novom lozinkom i container ulazi u crash loop.

Plan za buduće rotacije: napraviti pre-rotation script koji izvrši `ALTER USER` preko `psql` sa starom lozinkom, pa onda generira novi env. TODO.
