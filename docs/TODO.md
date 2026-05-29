# domovina-api — global TODO

Last updated: 2026-05-26

Status: backend production-ready za MVP. Sve niže su poboljšanja / sljedeće faze.

## Hot path (blokira ili usporava Flutter integraciju)

- [ ] **Coolify API token re-issue** (read+write+deploy perms) — currently 403. Token ide u `.local-secrets.env` → `COOLIFY_API_TOKEN` (pod navodnicima). **Unlock za full API-driven ops:** `coolify-env-apply.sh` (bulk env preko API + post-verify) i ostatak `coolify-*.sh`. Vidi [[feedback-coolify-api]]. (`ops-verify.sh` radi i bez tokena — preko SSH.)
- [ ] **Verify `ADDITIONAL_REDIRECT_URLS` u GoTrue env** — nakon što token bude funkcionalan. Mora uključivati `https://domovina.ai/**`, `https://domovina.energy/**`, `https://domovina.tv/**`, `http://localhost:3000/**`, `http://localhost:5173/**` + `/auth/callback` paths kad se uvede.
- [ ] **Deep link u allow list (Coolify UI)** — dodati `ai.domovina://auth/callback` u `GOTRUE_URI_ALLOW_LIST` **i** `ADDITIONAL_REDIRECT_URLS`, pa restart auth. Repo (`config.toml`, `.env.example`) već ima; live čeka jer je Coolify token 403. Bez ovoga mobile/TV OAuth callback ne radi.
- [ ] **DMARC update** — `_dmarc.domovina.ai` trenutno pokazuje na stari Brevo (`rua@dmarc.brevo.com`). Treba: `v=DMARC1; p=quarantine; rua=mailto:ms@domovina.tv` (preporuka Resenda). DNS only zapis.

## Onboarding & auth

- [ ] **Google OAuth Cloud Console setup** — vidi `docs/setup-guides/google-oauth.md`. Blocker za M2 onboarding moment (linkIdentity Google). User action: Google Console kliktanje.
- [ ] **Invite acceptance flow** — frontend treba `/auth/callback` route + backend per-call `redirectTo`. Vidi `docs/handoffs/2026-05-26-invite-acceptance-page.md`.

## Security & ops

- [ ] **CF Rate Limiting na `/auth/v1/*`** — vidi `docs/setup-guides/cf-rate-limiting.md`. 5 min za CF Custom Rule. Sprječava credential stuffing / spam signups.
- [ ] **Uptime Kuma + Telegram alerts** — vidi `docs/setup-guides/uptime-monitoring.md`. Alerting kad auth padne.
- [ ] **pg_cron schedule za `cleanup_expired_handoffs`** — komentar u migraciji `06_handoff_rpc.sql`. Manual za sad, dodati kad bude prvi cross-device flow.
- [ ] **Pre-rotation script za pg password** — TODO u `docs/deployment-runbook.md`. Skripta koja preko `ALTER USER` zarotira pg password sa starom prije generiranja novog env-a.
- [ ] **🔴 Rotacija leaknutih secreta (2026-05-29)** — `coolify-env-merge.sh` bug ispisao live env u chat (fix `8211733`). Rotation queue + postupci u `docs/secret-rotation.md`. Odgođeno na maintenance window (JWT rotacija ruši frontende dok ne dobiju novi anon key).

## Faza 2 (cross-device / M5)

- [ ] **❗ certilia env fali** — `certilia` edge fn treba `CERTILIA_CLIENT_ID` + `KYC_ENCRYPTION_KEY` (i opcionalno `CERTILIA_ISSUER`, default `https://idp.certilia.com`). Trenutno MISSING u Coolify env-u i u edge containeru → certilia ne radi (JWT audience + KYC enkripcija pucaju). User action: dodati u Coolify env (preko `coolify-env-merge.sh` workflow) + redeploy. `KYC_ENCRYPTION_KEY` je secret (pgcrypto ključ za OIB) — ide u `.local-secrets.env`/override layer, ne u repo.
- [ ] **handoff-consume end-to-end test** — deployment + auth gate verificiran (401 not_authenticated bez user sesije). Pravi e2e (valjan 6-digit kod → `action_link`) treba user-session JWT; testira Flutter na M5.

## Done (recent)

- [x] **Edge function deploy-as-code** — `scripts/deploy-functions.sh` deploya repo `supabase/functions/` → host volume preko `docker exec` (čuva hello/main, opc. restart). Reproducibilno iz gita; rješava redeploy-wipe rizik za certilia/passkey/handoff-consume.

## Done (recent)

- [x] **M2 — `domovina_ai` u PostgREST** — `PGRST_DB_SCHEMAS` već live (verificirano: `Accept-Profile: domovina_ai` → 200 `[]`, ne PGRST106). `.env.example` synced.
- [x] **M3 — `domovina_ai.migrate_anon_data(uuid)`** — migracija `20260528120000`, applied + tracked. Re-owner watch_progress/watch_sessions na anon→permanent promociju, gate-ano na `auth.uid()` + ne-anon caller.
- [x] **M4 — `handoff-consume` edge function** — deployan na `supabase-edge-functions` container, ruta `/functions/v1/handoff-consume` živa (401 bez user sesije, ne 404).
- [x] `create_handoff_token()` returns jsonb `{code, expires_at}` (commit `8bbe160`, migracija `20260526120000`)
- [x] Resend domena `domovina.ai` verified
- [x] Resend API key rotated (leak iz chat-a poništen)
- [x] End-to-end invite test (ms@domovina.link → confirmed_at popunjen, sve tablice + activity_events okidaju ispravno)

## Reference

- Ops automation: `coolify-env-merge.sh` (build bundle) → `coolify-env-apply.sh` (API apply+verify) → `coolify-restart.sh` → `ops-verify.sh` (health). `deploy-functions.sh` za edge fn.
- Security hardening / defense layers: `docs/security-hardening.md` (Coolify API IP allowlist, CF WAF/Access, Kong, RLS, JWT)
- Secret rotation runbook + rotation queue: `docs/secret-rotation.md`
- Status checklist u `docs/deployment-runbook.md` (one-shot deploy)
- Setup guides u `docs/setup-guides/`
- Handoffs u `docs/handoffs/`
