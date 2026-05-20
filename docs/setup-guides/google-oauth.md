# Google OAuth setup za GoTrue (M2 onboarding moment)

**Cilj:** korisnik klikne "Sign in with Google" u Flutter app-u → linkIdentity → trigger `handle_user_promoted` kreira personal account → user dobiva slug + cross-device sync.

**Status:** awaiting Google Cloud Console setup.

---

## Korak 1 — Google Cloud Console

1. Otvori: <https://console.cloud.google.com/apis/credentials>
2. Projekt: ako nema `Domovina` → dropdown gore lijevo → **New Project** → Name: `Domovina` → Create
3. **OAuth consent screen** (lijevi sidebar) → ako prazno, **Get started**:
   - User Type: **External**
   - App name: `Domovina`
   - User support email: `ms@domovina.tv`
   - App logo: skip
   - **App domain → Authorized domains**:
     - `domovina.ai`
     - `domovina.energy`
     - `domovina.tv`
   - Developer contact: `ms@domovina.tv`
   - Scopes: ostavi default (`email`, `profile`, `openid`)
   - Test users: skip ili dodaj svoj email
   - **Save and continue**
4. **Credentials** → **Create Credentials** → **OAuth client ID**:
   - Application type: **Web application**
   - Name: `Domovina API — GoTrue`
   - **Authorized JavaScript origins** (klik Add URI za svaki):
     ```
     https://domovina.ai
     https://www.domovina.ai
     https://domovina.energy
     https://www.domovina.energy
     https://domovina.tv
     https://www.domovina.tv
     http://localhost:3000
     http://localhost:5173
     ```
   - **Authorized redirect URIs**:
     ```
     https://api.domovina.ai/auth/v1/callback
     ```
   - **Create**
5. Google prikazuje modal s **Client ID** + **Client Secret** — kopiraj oba.

## Korak 2 — Paste credentials lokalno

U `.local-secrets.env` (gitignored):
```
GOOGLE_OAUTH_CLIENT_ID="<client-id>.apps.googleusercontent.com"
GOOGLE_OAUTH_CLIENT_SECRET="GOCSPX-<secret>"
```

Pošalji mi vrijednosti, ja radim ostalo.

## Korak 3 — Backend updates (ja radim)

Set Coolify env vars:
```
ENABLE_GOOGLE_PROVIDER=true
GOOGLE_CLIENT_ID=<from step 1>
GOOGLE_SECRET=<from step 1>
```

Coolify compose mapira na:
```
GOTRUE_EXTERNAL_GOOGLE_ENABLED=${ENABLE_GOOGLE_PROVIDER:-false}
GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOTRUE_EXTERNAL_GOOGLE_SECRET=${GOOGLE_SECRET}
GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI=https://api.domovina.ai/auth/v1/callback
```

(Ako compose nema ove env varove već, treba ih ručno dodati u Coolify Custom Compose ili template override.)

Recreate samo `supabase-auth` container.

## Korak 4 — Smoke test (oboje)

```bash
# Treba 302 redirect to accounts.google.com
curl -s -o /dev/null -w "HTTP %{http_code}  Location: %header{location}\n" \
  "https://api.domovina.ai/auth/v1/authorize?provider=google"
```

Otvori u browseru — trebao bi prikazati Google login → odaberi račun → redirect na `https://api.domovina.ai/auth/v1/callback?code=...` → GoTrue izmijeni code za session → redirect na `GOTRUE_SITE_URL` (https://domovina.ai).

## Korak 5 — Frontend test (Flutter session)

Flutter već ima `auth_service.dart linkWithGoogle()` (per prompt 07). Test:

1. Otvori app, anonymous session
2. Klikni "Sign in with Google" gumb (M2 moment)
3. Google login → odobri → vraća u app
4. `auth.users.is_anonymous` flip-a `true → false`
5. Trigger `handle_user_promoted` okida:
   - Kreira `public.accounts` red (is_personal_account=true, slug iz emaila)
   - Update `public.profiles.active_account_id`
   - Insert `public.activity_events` (event_type='user.promoted')
6. UI vidi user slug

```sql
-- Verify u Studio SQL editoru:
select a.slug, a.name, a.created_at, p.active_account_id, e.event_type
from public.accounts a
join public.profiles p on p.active_account_id = a.id
left join public.activity_events e on e.target_account_id = a.id
where a.is_personal_account = true
order by a.created_at desc limit 5;
```

## Troubleshooting

- **`redirect_uri_mismatch`**: Authorized redirect URI u Google Console mora biti **točno** `https://api.domovina.ai/auth/v1/callback`. Bez trailing slash, bez query params.
- **`oauth_provider_not_supported`**: GoTrue env `GOTRUE_EXTERNAL_GOOGLE_ENABLED` nije `true` ili container nije recreated nakon env update-a.
- **App stuck na Google login redirect**: provjeri `GOTRUE_SITE_URL=https://domovina.ai` u Coolify env. Inače GoTrue ne zna gdje vratiti korisnika.

## Apple OAuth (kasnije)

Apple OAuth treba Apple Developer account ($99/god), Sign in with Apple capability, certificate JWT auth. Ostavljamo dok ne kreneš prema iOS App Store releasu.
