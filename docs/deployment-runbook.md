# Deployment runbook

Aktivni runbook za Coolify Supabase deployment na `api.domovina.ai`.

## Trenutni stage

- [x] Coolify host postavljen (89.168.100.120)
- [x] Cloudflared container exposa Traefik :80 preko Cloudflare Tunnela
- [x] Supabase resource kreiran u Coolifyju (još nije deployan)
- [ ] Env vars konfigurirani za `api.domovina.ai` i SSO redirect URL-ove
- [ ] Cloudflare DNS CNAME zapisi za `api.domovina.ai`
- [ ] Cloudflare Tunnel ingress za `api.domovina.ai` → `traefik:80`
- [ ] Prvi deploy
- [ ] Smoke testovi (`/auth/v1/health`, `/rest/v1/`, Studio login)
- [ ] DB migracija: `public.profiles` + trigger `on_auth_user_created`
- [ ] (opcionalno) `studio.domovina.ai` + Cloudflare Access policy
- [ ] SMTP provider izabran i konfiguriran

## Korak 1 — Env vars u Coolifyju

Vidi [`../.env.example`](../.env.example). Ključne vrijednosti za promijeniti od defaulta:

| Var | Vrijednost |
|---|---|
| `SERVICE_FQDN_SUPABASEKONG_8000` | `api.domovina.ai` (ukloni sslip placeholder) |
| `SUPABASE_PUBLIC_URL` | `https://api.domovina.ai` |
| `API_EXTERNAL_URL` | `https://api.domovina.ai` |
| `STORAGE_PUBLIC_URL` | `https://api.domovina.ai` |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://api.domovina.ai` |
| `GOTRUE_SITE_URL` | `https://domovina.ai` |
| `ADDITIONAL_REDIRECT_URLS` | sve domovina.* + localhost (vidi `.env.example`) |
| `ENABLE_PHONE_SIGNUP` | `false` (default `true` je rizik bez SMS providera) |
| `ENABLE_PHONE_AUTOCONFIRM` | `false` |

Sve `SERVICE_PASSWORD_*` generiraj preko `scripts/generate-coolify-secrets.sh`.

## Korak 2 — Cloudflare DNS

U Cloudflare dashboardu za `domovina.ai`:

```
Type   Name     Target                                  Proxy
CNAME  api      <TUNNEL_UUID>.cfargotunnel.com         Proxied
CNAME  studio   <TUNNEL_UUID>.cfargotunnel.com         Proxied   (opcionalno)
```

`<TUNNEL_UUID>` nađeš na Cloudflare Zero Trust → Networks → Tunnels → tvoj tunel.

## Korak 3 — Cloudflare Tunnel ingress

Vidi [`../cloudflared/config.yml`](../cloudflared/config.yml).

## Korak 4 — Deploy

U Coolifyju → Resource → **Deploy**. Prati logove dok svi healthchecks ne budu zeleni (~ 2-3 min za prvi deploy).

## Korak 5 — Smoke testovi

```bash
# Auth health
curl https://api.domovina.ai/auth/v1/health

# PostgREST root (treba 401 bez API key-a)
curl https://api.domovina.ai/rest/v1/

# Sa anon ključem
curl https://api.domovina.ai/rest/v1/ \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY"

# Studio (samo ako si dodao studio FQDN)
curl -I https://studio.domovina.ai
```

## Korak 6 — Studio access

`https://studio.domovina.ai` (ili port-forward ako nisi exposao):
- Basic auth: `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD`
- **Obavezno** dodaj Cloudflare Access policy: samo `ms@domovina.tv` može pristupiti

## Korak 7 — Migracija profiles tablice

Vidi [`../supabase/migrations/0001_profiles.sql`](../supabase/migrations/0001_profiles.sql) (TODO).

## Rotacija secreta

Nakon završetka inicijalnog deploya **rotiraj sve secrets** (jer su bili u chat transkriptu):

1. U Coolifyju klikni **Regenerate** pored svakog `SERVICE_PASSWORD_*`
2. Pokreni `scripts/generate-coolify-secrets.sh` za nove JWT-ove iz novog `JWT_SECRET`
3. Redeploy
4. Update klijente s novim `ANON_KEY`
