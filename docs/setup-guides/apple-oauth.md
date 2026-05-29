# Apple "Sign in with Apple" setup za GoTrue (web + native)

**Cilj:** "Login with Apple" radi na webu/PWA (Services ID OAuth flow preko
GoTrue) i na native iOS-u (id_token → `signInWithIdToken`).

**Status:** Apple Developer account postoji; treba Services ID + Key (.p8).

**Zašto kompliciranije od Googlea:** Apple client secret nije statičan — to je
ES256 JWT koji **istječe ≤ 6 mjeseci** (treba rotacija). Web i native koriste
**različite** client_id-eve (Services ID vs App bundle ID), pa GoTrue mora
prihvatiti oba.

---

## Korak 1 — Apple Developer portal

<https://developer.apple.com/account/resources>

### 1a. App ID (za native iOS Sign in with Apple)
- **Identifiers → +  → App IDs → App**
- Bundle ID: `ai.domovina` (mora odgovarati Flutter `applicationId`)
- Capabilities: ✅ **Sign in with Apple** → Save

### 1b. Services ID (= web `client_id`)
- **Identifiers → + → Services IDs**
- Description: `DOMOVINA.ai Web Sign-In`
- Identifier: **`ai.domovina.signin`** (MORA biti različit od App ID-a) → Continue → Register
- Otvori taj Services ID → ✅ **Sign in with Apple** → **Configure**:
  - Primary App ID: `ai.domovina`
  - **Domains and Subdomains**: `api.domovina.ai`
  - **Return URLs**: `https://api.domovina.ai/auth/v1/callback`
  - Save
- ⚠️ Apple traži **verifikaciju domene**: preuzmi
  `apple-developer-domain-association.txt` i posluži ga na
  `https://api.domovina.ai/.well-known/apple-developer-domain-association.txt`
  (vidi Korak 1d).

### 1c. Sign in with Apple Key (.p8)
- **Keys → + → Key Name**: `DOMOVINA SIWA` → ✅ **Sign in with Apple** →
  Configure → Primary App ID `ai.domovina` → Save → Continue → Register
- **Download** `AuthKey_XXXXXXXXXX.p8` (možeš SAMO jednom — spremi sigurno)
- Zapiši **Key ID** (10 znakova, u nazivu) i **Team ID** (gore desno u accountu)

### 1d. Domain association file (verifikacija)
Apple poslužuje verifikaciju s domene return URL-a. `apple-developer-domain-association.txt`
mora biti dostupan na `https://api.domovina.ai/.well-known/...`. Kako api.domovina.ai
ide kroz Kong/Coolify, najlakše ga je staviti kao statički route ili kroz CDN
proxy. (Ako Apple ne uspije verificirati, web flow vraća `invalid_client`.)

## Korak 2 — Paste lokalno

U `.local-secrets.env` (gitignored):
```
GOTRUE_EXTERNAL_APPLE_CLIENT_ID=ai.domovina.signin,ai.domovina
GOTRUE_EXTERNAL_APPLE_SECRET=<generiran u Koraku 3>
```
**Napomena:** CLIENT_ID je **comma-separated** — `ai.domovina.signin` (web, `aud`
Services ID) + `ai.domovina` (native, `aud` = App bundle). Tako GoTrue validira
i web i native id_tokene. Secret JWT-a koristi prvi (Services ID) kao `sub`.

## Korak 3 — Generiraj client secret (JWT)

```bash
node scripts/gen-apple-secret.mjs \
  --p8 ~/secrets/AuthKey_XXXXXXXXXX.p8 \
  --team TEAM123456 \
  --kid  XXXXXXXXXX \
  --client ai.domovina.signin | pbcopy
```
Zalijepi rezultat u `GOTRUE_EXTERNAL_APPLE_SECRET`. **Istječe za 180 dana** →
zapiši u [secret-rotation.md](../secret-rotation.md) i regeneriraj prije isteka.

## Korak 4 — Backend env + deploy

`scripts/build-coolify-env.sh` već emitira (config-as-code):
```
GOTRUE_EXTERNAL_APPLE_ENABLED=true
GOTRUE_EXTERNAL_APPLE_REDIRECT_URI=https://api.domovina.ai/auth/v1/callback
```
CLIENT_ID + SECRET dolaze iz `.local-secrets.env` (mergeani po ključu). Pokreni:
```bash
./scripts/build-coolify-env.sh        # → clipboard
```
Coolify → Supabase service → Env → Bulk paste → Save → **recreate `supabase-auth`**.

## Korak 5 — Smoke test (web)

```bash
# Treba 302 redirect na appleid.apple.com
curl -s -o /dev/null -w "HTTP %{http_code}  Location: %header{location}\n" \
  "https://api.domovina.ai/auth/v1/authorize?provider=apple"
```
HTTP 400 `provider is not enabled` → env nije primijenjen / auth nije recreated.

## Korak 6 — Frontend

**Web/PWA** (već radi kroz isti put kao Google):
```dart
await supabase.auth.signInWithOAuth(
  OAuthProvider.apple,
  redirectTo: '<callback>',
);
```

**Native iOS** (App Store build) — `sign_in_with_apple` paket daje Apple
id_token, pa:
```dart
final cred = await SignInWithApple.getAppleIDCredential(
  scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
  nonce: hashedNonce,
);
await supabase.auth.signInWithIdToken(
  provider: OAuthProvider.apple,
  idToken: cred.identityToken!,
  nonce: rawNonce,
);
```
Native id_token ima `aud = ai.domovina` (App bundle) → zato je App bundle u
`GOTRUE_EXTERNAL_APPLE_CLIENT_ID` listi. Treba i Xcode **Sign in with Apple**
capability + associated entitlement.

## Troubleshooting
- **`provider is not enabled`** (400): `GOTRUE_EXTERNAL_APPLE_ENABLED` nije `true`
  ili `supabase-auth` nije recreated nakon env update-a.
- **`invalid_client`**: secret JWT istekao/krivi (Team ID, Key ID, sub), ili
  domena nije verificirana (Korak 1d), ili return URL ne odgovara točno.
- **Native `bad_id_token` / aud mismatch**: App bundle ID nije u
  `GOTRUE_EXTERNAL_APPLE_CLIENT_ID` listi.
- **Secret prestao raditi nakon nekoliko mjeseci**: JWT istekao → regeneriraj
  (Korak 3) i recreate auth.
