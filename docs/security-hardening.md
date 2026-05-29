# Security hardening — defense layers

Živi popis obrambenih slojeva za DOMOVINA backend (`api.domovina.ai`,
`studio.domovina.ai`, Coolify control-plane). Proširuj kako dodajemo slojeve.
Vezano: [secret-rotation.md](secret-rotation.md) (rotacija ključeva).

## Control plane (Coolify)

### Coolify API — IP allowlist
- **`app.domovina.link/settings/advanced`** → API dostupan **samo s IP `89.201.137.96`**
  (statička IPv4 dev lokacije). Bilo koji drugi izvor je blokiran na network razini.
- Posljedica za automaciju: `scripts/coolify-*.sh` (status, env-get/set/apply, restart)
  rade **samo s te lokacije**. `scripts/ops-verify.sh` ne ovisi o tome (ide preko SSH).
- Token: `COOLIFY_API_TOKEN` u `.local-secrets.env` (gitignored), scope read+write+deploy.
- Proširenje: dodatni IP-evi (npr. CI runner) po potrebi na istom mjestu.

## Edge (Cloudflare) — `api.domovina.ai` / `studio.domovina.ai`

1. **WAF Custom Rule** — `host=api.domovina.ai AND path="/"` → Block (bare root je samo
   Kong dashboard entry; nijedan public API path nije točno `/`).
2. **Cloudflare Access — admin paths** na `api.domovina.ai`: `/dashboard*`, `/project*`,
   `/api/platform*` → Allow samo dopuštene email adrese.
3. **Cloudflare Access — cijeli `studio.domovina.ai`** → ista email lista.

## App / data

4. **Kong basic auth** (Supabase template) — štiti Kong `/dashboard` route
   (`SERVICE_USER_ADMIN`/`SERVICE_PASSWORD_ADMIN`); failsafe ispod CF Access.
5. **PostgreSQL RLS** — sve user tablice imaju `auth.uid()` policy; `service_role`
   bypassa RLS (samo backend / edge funkcije).
6. **JWT (HS256, secret ≥ 32 znakova)** — GoTrue izdaje; PostgREST/Storage/Realtime
   verificiraju. `anon` key public/bezopasan; `service_role` NIKAD na klijent.

## Public paths (namjerno otvoreni, idu ravno u Kong)
`/auth/v1/*`, `/rest/v1/*`, `/realtime/v1/*`, `/storage/v1/*`, `/functions/v1/*`.
Kad dodaješ novi `api.domovina.ai/<path>`: ako je **admin-only**, dodaj ga u CF Access
destinations; public path-ovi rade kroz Kong bez dodatnih koraka.

## Edge function auth model
- `handoff-consume`, `passkey`, `certilia`: `verify_jwt=false` (config.toml) — GoTrue ne
  gate-a; funkcija **interno** verificira (getUser za handoff/passkey-add, Certilia JWKS
  za certilia idToken). Tako anon/no-session pozivi dođu do funkcije koja sama odlučuje.

## Tajne
Vidi [secret-rotation.md](secret-rotation.md). Ukratko: secreti samo u Coolify env +
gitignored `.local-secrets.env`/`.coolify-extra.env`; nikad u repo/chat/memory; rotacija
obavezna nakon svakog leaka.
