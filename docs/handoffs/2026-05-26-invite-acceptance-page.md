## UX gap: invite link → raw landing page

**Datum:** 2026-05-26
**Verificirano s:** `ms@domovina.link` invite preko Studio
**Stanje backend-a:** auth flow radi 100%, confirmed_at + last_sign_in_at se popunjavaju ispravno

## Problem

GoTrue invite mail šalje link tipa:
```
https://api.domovina.ai/auth/v1/verify?token=<...>&type=invite&redirect_to=https://domovina.ai
```

Klik na link → GoTrue verificira token → redirect na `https://domovina.ai` (root landing). Korisnik završi na običnom marketing landing-u **bez ikakve vizualne potvrde** da je:
- invite prihvaćen
- session aktivna
- možda treba kompletirati profil (set password, full_name, locale, ...)

## Što frontend treba napraviti (domovina.ai Flutter / Next)

1. **Dedicated route `/auth/callback`** koji handla 3 entry case-ova:
   - `?type=invite` — "Dobrodošli, <email>! Sad si član Domovina." + CTA "Set password" / "Continue"
   - `?type=recovery` — password reset form
   - `?type=magiclink` — silent sign-in pa redirect na zadnji intended path

2. **Update invite redirect_to** — backend treba slati `redirect_to=https://domovina.ai/auth/callback?type=invite` umjesto root URL-a.

3. **PostgREST/GoTrue session check** odmah nakon callback-a — `supabase.auth.getSession()`. Ako session valid, prikaži welcome state. Ako ne (token expired), prikaži "Link je istekao, zatraži novi invite".

4. **Profile completion gate** — invited useri nemaju ime/avatar. Welcome page bi trebao gurnuti user-a u onboarding (set `profiles.full_name`, opcionalno avatar).

## Backend strana — minor change

Treba ažurirati gdje se invite šalje da `redirectTo` ide na `/auth/callback` umjesto root URL-a. To je client-side parametar (`inviteUserByEmail({ redirectTo })`), ne backend env. Studio "Invite user" trenutno koristi default redirect koji je `SITE_URL` (vidi GOTRUE_SITE_URL u env-u).

**Opcija A — global**: postaviti `GOTRUE_SITE_URL=https://domovina.ai/auth/callback`. Loše jer to mijenja default redirect za **sve** auth flow-ove, ne samo invite.

**Opcija B — per-call** (preporučeno): kad Flutter app ili admin tool zove `auth.admin.inviteUserByEmail()`, prosljedi `{ redirectTo: 'https://domovina.ai/auth/callback?type=invite' }`. Studio UI to također radi ako se klikne "Send magic link" s naprednim opcijama.

**Opcija C — email template override**: u `GOTRUE_MAILER_TEMPLATES_INVITE` postaviti custom HTML template gdje `{{ .ConfirmationURL }}` apenda `?next=/auth/callback?type=invite`. Najsofisticiranije, ali template hosting treba (objaviti html negdje pa GoTrue ga fetcha).

## Akcija

- **Frontend (domovina.ai sesija)**: implementirati `/auth/callback` route per Spec gore. Ovo je M2 onboarding momentum koji već postoji u Flutter mock-ovima — sad ide live.
- **Backend (ova sesija)**: ne dirati ništa dok frontend ne potvrdi koju Opciju (A/B/C) hoće. Najvjerojatnije B.
