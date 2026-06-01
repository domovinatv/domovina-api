# Supabase verzije — prod (Coolify) vs lokal (CLI)

> Auto-generirano: `scripts/supabase-versions.sh --write` · snapshot 2026-06-01 09:57Z
>
> **Coolify NE auto-update-a Supabase.** Pri deployu snapshotira docker-compose;
> redeploy povlači iste pinane tagove. Update = ručno u Coolifyju (bumpaj template /
> image tagove → redeploy). Lokalni CLI verzije fiksira `supabase` binary; sync
> preko `brew upgrade supabase` + `scripts/dev-local.sh restart`. Cilj: lokal NE
> smije biti viša verzija od prod-a (testiraj na ≤ prod, idealno ≈ prod).

## PROD — api.domovina.ai (Coolify service `cv887vonujh1swebndh4x4iu`)

| servis | image:tag |
|---|---|
| analytics | `supabase/logflare:1.31.2` |
| auth | `supabase/gotrue:v2.186.0` |
| db | `supabase/postgres:15.8.1.085` |
| edge-functions | `supabase/edge-runtime:v1.71.2` |
| imgproxy | `darthsim/imgproxy:v3.30.1` |
| kong | `kong/kong:3.9.1` |
| meta | `supabase/postgres-meta:v0.95.2` |
| minio | `ghcr.io/coollabsio/minio:RELEASE.2025-10-15T17-29-55Z` |
| realtime-dev | `supabase/realtime:v2.76.5` |
| rest | `postgrest/postgrest:v14.6` |
| storage | `supabase/storage-api:v1.44.2` |
| studio | `supabase/studio:2026.03.16-sha-5528817` |
| supavisor | `supabase/supavisor:2.7.4` |
| vector | `timberio/vector:0.53.0-alpine` |

## LOKAL — Supabase CLI `2.103.0`

| servis | image:tag |
|---|---|
| analytics | `public.ecr.aws/supabase/logflare:1.42.0` |
| auth | `public.ecr.aws/supabase/gotrue:v2.189.0` |
| db | `public.ecr.aws/supabase/postgres:15.8.1.085` |
| edge_runtime | `public.ecr.aws/supabase/edge-runtime:v1.74.0` |
| inbucket | `public.ecr.aws/supabase/mailpit:v1.22.3` |
| kong | `public.ecr.aws/supabase/kong:2.8.1` |
| pg_meta | `public.ecr.aws/supabase/postgres-meta:v0.96.6` |
| realtime | `public.ecr.aws/supabase/realtime:v2.102.1` |
| rest | `public.ecr.aws/supabase/postgrest:v14.12` |
| storage | `public.ecr.aws/supabase/storage-api:v1.60.2` |
| studio | `public.ecr.aws/supabase/studio:2026.05.25-sha-65c570e` |
| vector | `public.ecr.aws/supabase/vector:0.53.0-alpine` |

## Refresh

```bash
scripts/supabase-versions.sh --write   # re-fetch prod + lokal, prepiši ovaj doc
git add docs/supabase-versions.md && git commit -m "chore: snapshot supabase verzija"
```
