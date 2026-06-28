# Backend architecture — where does a backend function go?

Two places run backend code for the DOMOVINA products. They are **not**
interchangeable. Pick by **purpose**, using the one test below.

## The rule

> **Does the function read or write our Postgres DB (`api.domovina.ai`,
> self-hosted Supabase on Coolify) for a (logged-in) user — or otherwise need
> the service role / GoTrue admin / RLS context?**
>
> - **Yes → Supabase Edge Function** (`domovina-api/supabase/functions/`).
> - **No (pure proxy / presentation / third-party SaaS) → Cloudflare Pages
>   Worker** (`domovina.ai/web/_worker.js`).

## Cloudflare Pages Worker — `domovina.ai/web/_worker.js`

The edge surface that fronts the Flutter **web** app. Use it for things tied to
the web frontend and for **third-party SaaS** integrations that hide a vendor key
but **do not touch our database**:

- SPA routing, pretty-URL `.html` lookup, COOP/COEP headers, `.well-known`.
- OG / JSON-LD injection for social crawlers.
- **Proxying a third-party SaaS API while keeping its key server-side** — e.g.
  the Cal.com booking proxy (`/api/cal/*`, holds `CAL_API_KEY`). The worker calls
  `api.cal.com`; nothing is written to our Postgres.

Secrets here are **only** third-party/presentation keys (Cal.com, CDN purge).
**Never** put `SUPABASE_SERVICE_ROLE_KEY` or DB-writing logic here — that would
duplicate the crown-jewel secret into a second system and split the backend.

## Supabase Edge Functions — `domovina-api/supabase/functions/`

Run on Coolify next to Postgres + GoTrue, with `SUPABASE_URL`,
`SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` auto-injected. Use them whenever
state for a user is involved:

- **Webhooks that persist state** — `revenuecat-webhook` (entitlement mirror),
  `pinka-webhook` (contribution paid). Server-to-server, `verify_jwt = false`,
  authenticated by a shared secret / HMAC, then a service-role write.
- **Auth bridges / admin** — `certilia`, `passkey`, `auth-send-email`,
  `account-delete`, `handoff-consume`.
- Anything needing RLS context, the service role, or GoTrue admin APIs.

Deploy with `scripts/deploy-functions.sh`; per-function JWT policy in
`supabase/config.toml`; function secrets live in the edge runtime env (Coolify),
not in the repo.

## Worked example — RevenueCat subscriptions

The RevenueCat webhook **writes** `domovina_ai.subscriptions` for a logged-in
user → it is a **Supabase Edge Function** (`revenuecat-webhook`), not a
Cloudflare route, even though the Cloudflare worker already had a `/api/*`
pattern (Cal.com). The mobile SDK keys stay client-side (`--dart-define`); the
service-role key stays on Coolify. The Flutter app (all platforms) only **reads**
its own row via RLS. See `domovina.ai/docs/payments/`.
