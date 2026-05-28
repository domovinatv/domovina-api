# DOMOVINA.AI FRONTEND — backend M2–M4 + deep links su sad LIVE

**Datum:** 2026-05-28
**Backend commit:** `19eb6a2`
**Stanje:** sve 4 stavke verificirane na živom sustavu (containeri healthy, curl/psql provjereni)

Backend (`domovina-api`, self-hosted Supabase na https://api.domovina.ai) je upravo
dovršio i deployao 4 stvari koje su frontend dosad lomile. Tvoj zadatak je wire-ati
frontend (Flutter `domovina.ai`) na njih.

Već radi i NE treba dirati: anonymous login, Google OAuth (redirect
`https://api.domovina.ai/auth/v1/callback`), manual identity linking.

---

## 1) `domovina_ai` schema je sad exposed kroz PostgREST (M2)

`client.schema('domovina_ai').from('watch_progress')` više NE vraća PGRST106.
Dostupne tablice (RLS-gated): `watch_progress`, `watch_sessions`, `favorites`,
`handoff_tokens`, `onboarding_events`.

Vlasništvo (bitno):
- `watch_progress`  — PK `(user_id, episode_id)`, `user_id` = profil (per-user).
- `watch_sessions`  — append-only, `user_id`.
- `favorites`       — PK `(owner_id, episode_id)`, `owner_id` = account (ne user!).

Pravila: anon role ima samo SELECT; pisanje treba authenticated sesiju (anon
Supabase user JE authenticated, samo bez emaila). Uvijek fully-qualify preko
`.schema('domovina_ai')`.

Akcija: makni sve privremene workaround-e/try-catch oko PGRST106 na ovim tablicama.

---

## 2) `migrate_anon_data(p_anon_id)` RPC postoji (M3)

Nakon anon→permanent promocije (link email/Google na anon usera), pozovi:

```dart
final res = await client
    .schema('domovina_ai')
    .rpc('migrate_anon_data', params: {'p_anon_id': oldAnonUserId});
// res => { moved_watch_progress, moved_watch_sessions, new_user_id }
```

Ponašanje: prebaci `watch_progress` + `watch_sessions` sa starog anon usera na
trenutnog (promoviranog) usera. Kod konflikta (isti episode_id već postoji kod
permanent usera) — permanent verzija pobjeđuje, anon duplikat se briše.

Mora se zvati NAKON promocije, iz sesije koja VIŠE NIJE anonimna. Greške:
- `not_authenticated` (nema sesije)
- `caller_still_anonymous` (sesija je još anon — promocija nije gotova)

Spremi `oldAnonUserId` PRIJE promocije jer se nakon nje mijenja `auth.uid()`.

---

## 3) `handoff-consume` Edge Function za cross-device sign-in (M4)

Endpoint: `POST https://api.domovina.ai/functions/v1/handoff-consume`
(`supabase_flutter`: `client.functions.invoke('handoff-consume', body: {...})`).

Flow (M5 cross-device):
1. Uređaj A (prijavljen, permanent user): pozove RPC
   `client.schema('domovina_ai').rpc('create_handoff_token')`
   → vraća `{ code: "123456", expires_at: <ISO ts> }`. Prikaži 6-znamenkasti kod
   + countdown do `expires_at` (TTL 5 min).
2. Uređaj B (mora imati BAR neku sesiju — npr. anon — jer fn verificira pozivatelja):
   ukuca kod, ti pozoveš `handoff-consume` s body:
   ```json
   { "code": "123456", "device": "ios" }   // device ∈ web|ios|android|macos (opcionalno)
   ```
   Šalji `Authorization: Bearer <trenutni access token uređaja B>`.
3. Odgovor `200`: `{ action_link, user_id }`. Otvori `action_link` (magic link s
   `redirectTo=ai.domovina://auth/callback`) da uređaj B dobije sesiju usera s
   uređaja A.

Greške: `401 not_authenticated` (uređaj B nema sesiju), `400 invalid_code_format`
(kod nije 6 znamenki), `400 invalid_or_expired_code`, `405 method_not_allowed`.

---

## 4) Deep link `ai.domovina://auth/callback` je u allow-listi

Mobile/TV OAuth + magic-link callback sad rade na taj scheme. Frontend mora:
- registrirati `ai.domovina://auth/callback` kao deep link (iOS URL scheme /
  Android intent-filter),
- proslijediti `redirectTo: 'ai.domovina://auth/callback'` u OAuth/magiclink
  pozivima na mobileu/TV-u,
- imati `/auth/callback` handler koji: parsira `?type=` (`invite` | `recovery` |
  `magiclink`), provjeri `getSession()`, pa rutira (welcome / set-password /
  silent-sign-in).

---

## Acceptance za frontend
- watch_progress/favorites read+write preko `.schema('domovina_ai')` rade bez PGRST106.
- anon→permanent zadrži watch state (migrate_anon_data pozvan, moved_* > 0).
- 6-znamenkasti handoff kod s uređaja A → uređaj B dobije sesiju preko action_link.
- mobile OAuth/magiclink callback sleti na `ai.domovina://auth/callback` i odradi sign-in.
