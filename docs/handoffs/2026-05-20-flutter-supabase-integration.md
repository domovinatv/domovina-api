# Handoff prompt — Flutter Supabase integration (M3 onwards)

**Created:** 2026-05-20
**Backend state at handoff time:** see `Backend ready state` section below.
**Target repo:** `/Users/ms/git/domovinatv/domovina.ai` (Flutter Netflix-style app)

---

## YOU (the receiving Claude Code session)

You are working on `/Users/ms/git/domovinatv/domovina.ai` — a Flutter app for Netflix-style episode viewing. The backend (`domovina-api`) is fully deployed and ready. Your job is to swap the mock services in `lib/services/*` for real Supabase calls.

**Confirm working dir before doing anything:**
```bash
pwd  # should be /Users/ms/git/domovinatv/domovina.ai
ls   # should see lib/, pubspec.yaml, docs/
```

If you are in `/Users/ms/git/domovinatv/domovina-api`, **stop**. That's the backend. `cd` to the Flutter repo:
```bash
cd /Users/ms/git/domovinatv/domovina.ai
```

**Do NOT modify the backend** (`domovina-api` repo). Schema, RLS, triggers are all already deployed. Your changes belong only in `domovina.ai`.

---

## Backend ready state (what's live on `api.domovina.ai`)

| Component | Status | Detail |
|---|---|---|
| Supabase stack | ✅ live | 13 containers healthy on Coolify (Oracle Cloud) |
| API endpoint | ✅ | `https://api.domovina.ai` (Kong gateway) |
| Studio UI | ✅ | `https://studio.domovina.ai` (CF Access protected) |
| `PGRST_DB_SCHEMAS` | ✅ | includes `domovina_ai` |
| Migrations | ✅ all 6 applied | core_identity → domovina_ai_schema → triggers_functions → rls_policies → handoff_rpc → grants_and_search_path |
| Tables: `public.*` | ✅ | profiles, accounts, accounts_memberships, activity_events |
| Tables: `domovina_ai.*` | ✅ | watch_progress, watch_sessions, favorites, handoff_tokens, onboarding_events |
| View `domovina_ai.v_continue_watching` | ✅ | filters `not completed AND position_seconds > 30` |
| Triggers | ✅ | `on_auth_user_created` + `on_auth_user_promoted` create profile + personal account + activity event |
| RLS | ✅ | all 9 tables `to authenticated`, `(select auth.uid())` pattern |
| RPC functions | ✅ | `domovina_ai.create_handoff_token()`, `domovina_ai.consume_handoff_token(text, text)` |

**Smoke test (anyone can run):**
```bash
curl -s "https://api.domovina.ai/auth/v1/health"  -H "apikey: <ANON>"
curl -s "https://api.domovina.ai/rest/v1/profiles" -H "apikey: <ANON>"
curl -s "https://api.domovina.ai/rest/v1/watch_progress" -H "apikey: <ANON>" -H "Accept-Profile: domovina_ai"
# All should return HTTP 200.
```

---

## Spec to read (in this order, before writing code)

These docs live in **this repo** (`/Users/ms/git/domovinatv/domovina.ai/docs/`):

1. **`docs/auth-and-database-plan-v3.md`** — read §Architectural principles + §Updated MVP scope (skim rest). Critical: **PII lives only in `auth.users`**, slug is immutable, soft-delete only on accounts.
2. **`docs/schema-v3.dbml`** — formal schema. Note `watch_progress` has `episode_title` + `episode_thumbnail_url` (denorm cache, v3 add).
3. **`docs/backend-prompts/07-flutter-swap-mocks.md`** — **YOUR PRIMARY SPEC**. Detailed step-by-step for what to implement.

You may also scan `docs/backend-prompts/00-README.md` for the big picture mapping.

---

## Environment variables (Supabase URL + anon key)

Flutter app needs:
- `SUPABASE_URL=https://api.domovina.ai`
- `SUPABASE_ANON_KEY=<JWT>` — the anon JWT key signed by GoTrue

### How to get the anon key

The anon key is **not secret** (designed to be embedded in clients), but it's specific to our Supabase instance. Two ways:

**Option A — Ask the user.** They have it in `domovina-api/.local-secrets.env` or in Coolify env. Just ask: *"Please paste the SUPABASE_ANON_KEY from Coolify (Environment Variables tab, search for `ANON_KEY` or `SERVICE_SUPABASEANON_KEY`)."*

**Option B — Pull from running container** (if SSH access is set up locally):
```bash
ssh -i ~/.ssh/dom-001-oracle-ssh-key-2026-04-20.key ubuntu@89.168.100.120 \
  "docker inspect \$(docker ps --format '{{.Names}}' | grep '^supabase-rest-' | head -1) \
   --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ^ANON_KEY= | sed 's/^ANON_KEY=//'"
```

### Where to put the key

**Local dev:** `.env` in repo root (gitignored — verify `.gitignore` contains `.env` before writing). Loaded via `flutter_dotenv` OR via `--dart-define=SUPABASE_ANON_KEY=...` flag.

**Production (Cloudflare Pages):** build-time env vars set in Pages dashboard. `scripts/deploy.sh` should pass through with `flutter build web --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY --dart-define=SUPABASE_URL=$SUPABASE_URL`.

Prefer `--dart-define` over `dotenv` because the key gets baked into the build, which is fine since it's a public anon key.

---

## Implementation order

Follow `docs/backend-prompts/07-flutter-swap-mocks.md` step by step. Below is a checklist version — after each step run the verification:

### Step 1 — Dependencies
```yaml
# pubspec.yaml dependencies:
supabase_flutter: ^2.5.0
flutter_dotenv: ^5.1.0   # only if you choose .env loading
# passkeys: ^2.0.0       # SKIP for now — passkey integration is Faza later
```
```bash
flutter pub get
```
**Verify:** `flutter pub deps | grep supabase_flutter` shows the version.

### Step 2 — `lib/main.dart` initialize + anonymous signin
Implement exactly as in prompt 07 §Korak 3. Use `String.fromEnvironment('SUPABASE_URL')` etc.

**Verify:** App boots in `flutter run -d chrome --dart-define=SUPABASE_URL=https://api.domovina.ai --dart-define=SUPABASE_ANON_KEY=<key>`. DevTools → Application → Local Storage shows `sb-<...>-auth-token` entry. No errors in console.

In Studio (`https://studio.domovina.ai` → Authentication → Users): a row with `is_anonymous=true` appears for your new browser session.

### Step 3 — Swap `lib/services/auth_service.dart`
Per prompt 07 §Korak 4 `auth_service.dart`. Replace mock with real Supabase calls.

**Verify:** AuthService.currentUser returns the anonymous user (non-null). `isAnonymous` returns true.

### Step 4 — Swap `lib/services/watch_progress_service.dart`
Per prompt 07. **Critical v3 detail:** upsert must include `episode_title` + `episode_thumbnail_url` (denorm cache from CDN).

```dart
await _client.schema('domovina_ai').from('watch_progress').upsert({
  'user_id': user.id,
  'episode_id': episodeId,
  // ... all fields ...
  'episode_title': episodeTitle,
  'episode_thumbnail_url': episodeThumbnailUrl,
}, onConflict: 'user_id,episode_id');
```

**Verify (after playing an episode 10s and triggering an upsert):**

In Supabase SQL Editor (Studio):
```sql
select user_id, episode_id, position_seconds, episode_title, percent_complete
from domovina_ai.watch_progress
order by last_watched_at desc limit 5;
```
Should show your row with title populated and `percent_complete` auto-computed.

**Anonymous-user caveat:** the spec says writes happen only for non-anonymous users. For initial bring-up, **temporarily allow anonymous writes too** (remove the `if (!user.isAnonymous)` check) so you can verify the upsert pipeline works. Then restore the gating later in onboarding flow work.

### Step 5 — Swap `lib/services/favorites_service.dart`
Per prompt 07. Note `owner_id` references `public.accounts.id`, **not** `user_id`. For anonymous users there's no personal account yet → favorites should be local-only.

### Step 6 — Swap `lib/services/handoff_service.dart`
`createCode` calls `rpc('create_handoff_token')`. `consumeCode` calls `https://api.domovina.ai/handoff/consume` (edge function endpoint — **may not exist yet on backend**). If consume fails 404, document it and skip that test for now.

### Step 7 — Continue Watching uses the view, not the table
```dart
.from('v_continue_watching')   // ✅ — already filters not-completed and >30s
```

### Step 8 — Realtime sync (deferred — optional in this round)
Realtime cross-device sync per §Korak 5. Only implement if there's bandwidth; otherwise this can be Phase 2.

### Step 9 — Migration localStorage → Supabase
Per §Korak 6. Happens after `linkIdentity` (Google/Apple) succeeds. Don't implement yet if linkIdentity UI isn't ready — gate this behind a feature flag.

---

## Smoke test of full integration

When done, run this end-to-end:

1. **Chrome incognito → load app.** DevTools Application tab shows new `sb-...-auth-token`. Console no errors.
2. **Studio → Auth → Users.** New row with `is_anonymous=true`, created within last minute.
3. **Studio → SQL Editor:**
   ```sql
   select count(*) from public.profiles;  -- should be 1+
   select id, locale, active_account_id from public.profiles;
   -- active_account_id should be NULL for anonymous (no personal account yet).
   ```
4. **Play an episode 30s.** With anonymous-write temp-allowed (Step 4), check:
   ```sql
   select episode_id, position_seconds, percent_complete, episode_title
   from domovina_ai.watch_progress order by last_watched_at desc limit 5;
   ```
   One row, populated.
5. **Refresh page.** Session persists (same `sb-...-auth-token`, same user_id). `watch_progress` row not duplicated (upsert worked).

---

## Verification SQL queries (run in Studio for sanity)

```sql
-- 1. Profiles count
select count(*) from public.profiles;

-- 2. Anonymous vs permanent users
select
  count(*) filter (where (auth.users.is_anonymous) = true) as anon,
  count(*) filter (where (auth.users.is_anonymous) = false) as permanent
from auth.users;

-- 3. Recent watch_progress (your test data)
select * from domovina_ai.watch_progress order by last_watched_at desc limit 10;

-- 4. Activity events from triggers
select event_type, payload, created_at from public.activity_events order by created_at desc limit 20;
```

---

## What NOT to do

- ❌ **Don't modify the backend** (`domovina-api` repo). Schema, RLS, triggers, env are all locked in. If you think backend needs changing, **stop and tell the user**.
- ❌ **Don't add `profiles.email` or `profiles.is_anonymous` queries** — those are PII and live only in `auth.users` (Princip 1). Use `Supabase.instance.client.auth.currentUser?.email`.
- ❌ **Don't commit `.env`** — must be gitignored.
- ❌ **Don't commit the anon key value to git** — it's not secret-secret but lives in env / dart-define, not source.
- ❌ **Don't run any DB migrations** — those are managed in `domovina-api/supabase/migrations/`. Read-only access from this app.
- ❌ **Don't try to rotate or fetch Coolify env** — that's backend automation, not frontend concern.

---

## Where to commit

- All changes go to `domovina.ai` repo. No cross-repo commits.
- Suggested commit pattern (per service swap):
  - `feat(auth): swap AuthService mock for supabase_flutter (M2 ready)`
  - `feat(watch): wire WatchProgressService to domovina_ai schema with denorm cache`
  - `feat(favorites): wire FavoritesService to domovina_ai.favorites`
  - `feat(handoff): wire HandoffService to RPC create_handoff_token`
  - `chore(deps): add supabase_flutter ^2.5.0`

---

## Edge cases / known issues

- **Anonymous users + RLS:** anonymous Supabase users DO have `auth.uid()` (they have a JWT). So RLS policies `using (user_id = (select auth.uid()))` will work for them. The "skip writes for anonymous" pattern in the spec is a UX choice (don't pollute DB until user commits), not a security limitation. If you want anonymous writes to work for testing, just remove that check.
- **CORS:** Cloudflare Pages domain serves the Flutter web build. `api.domovina.ai` Kong already has CORS plugin (verified during deployment). If CORS fails in browser, check `ADDITIONAL_REDIRECT_URLS` in Coolify env includes your dev origin (`http://localhost:3000` etc.).
- **WebSocket Realtime:** `api.domovina.ai/realtime/v1/websocket` is exposed via Kong, and Cloudflare Tunnel passes through WS (verified during routing setup). No special config needed.
- **Schema header:** `Accept-Profile: domovina_ai` HTTP header tells PostgREST which schema. supabase_flutter SDK auto-sets this when you use `.schema('domovina_ai')`.

---

## When you finish

1. Commit changes.
2. Run smoke test (above section) and report results — which steps worked, which didn't.
3. Note any backend assumptions that turned out wrong.
4. If you needed to ask the user for the anon key, mention that they should add `SUPABASE_ANON_KEY` to Cloudflare Pages env vars when ready to deploy.

Then this handoff is complete. Cheers.
