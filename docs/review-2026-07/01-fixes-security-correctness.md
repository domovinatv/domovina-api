# 01 — Sigurnosni i correctness nalazi

Redoslijed po prioritetu. Svaki nalaz: severity, lokacija, opis, fix, autonomni prompt.

---

## 🔴 SEC-1 — `v_continue_watching` curi tuđu povijest gledanja (POTVRĐENO)

**Severity:** Kritično · **Datoteke:** `supabase/migrations/20260520120200_domovina_ai_schema.sql:133`, `20260520120600_grants_and_search_path.sql:22`

View je definiran bez `security_invoker`, pa se izvršava kao vlasnik (migration role koji
bypassa RLS), a nema `where user_id = auth.uid()` filtera. Migracija 07 radi
`grant select on all tables in schema domovina_ai to anon` — što uključuje i view.
Rezultat: bilo koji autenticirani (pa i anonimni-JWT) pozivatelj može preko PostgREST-a
dohvatiti `domovina_ai.v_continue_watching` i pročitati **povijest gledanja svih korisnika**.
Inline komentar "Postgres 15+ nasljeđuje RLS" je netočan.

**Fix:** nova migracija koja re-kreira view s `security_invoker = on` i dodaje eksplicitni
`user_id = (select auth.uid())` filter (belt-and-suspenders).

> **Autonomni prompt**
> U repou `domovina-api` postoji sigurnosni propust: view `domovina_ai.v_continue_watching`
> (definiran u `supabase/migrations/20260520120200_domovina_ai_schema.sql:133`) nema
> `security_invoker`, pa bypassa RLS i preko PostgREST-a curi povijest gledanja svih
> korisnika (migracija 07 grant-a `select` na sve tablice u schemi `anon`/`authenticated`).
> Napravi novu migraciju `supabase/migrations/20260710120000_fix_continue_watching_rls.sql`
> koja radi `create or replace view domovina_ai.v_continue_watching with (security_invoker = on) as`
> s identičnim SELECT-om ali dodanim uvjetom `and user_id = (select auth.uid())`. Poštuj
> postojeći stil migracija (bez inline begin/commit, završi sa `select 'OK ...' as status;`).
> Ne primjenjuj je na živu bazu — samo napiši migraciju i objasni kako je testirati lokalno
> te `scripts/db-migrate.sh` komandom.

---

## 🔴 SEC-2 — `migrate_anon_data()` omogućuje krađu i brisanje tuđih podataka (POTVRĐENO)

**Severity:** Kritično · **Datoteka:** `supabase/migrations/20260528120000_anon_data_migration_rpc.sql`

Funkcija je `security definer`, grant-ana `authenticated`, a jedina provjera je "pozivatelj
je autenticiran i nije anoniman". Parametar `p_anon_id uuid` je potpuno pod kontrolom
napadača. Permanentni korisnik može proslijediti UUID bilo koje žrtve i (a) prebaciti
žrtvine `watch_progress`/`watch_sessions` na sebe te (b) **obrisati** žrtvine preostale
(konfliktne) `watch_progress` redove (`delete from ... where user_id = p_anon_id`). Nema
provjere da je `p_anon_id` stvarno anoniman user niti da je povezan s pozivateljevom sesijom.

**Fix (preporučeno):** prebaci logiku na service-role poziv iz edge funkcije koja dokazuje
anon→permanent linkanje (edge sloj ima taj kontekst iz Supabase anon→permanent flowa).
**Minimalni fix:** u RPC-u provjeri da je izvor stvarno anoniman user:
```sql
if not exists (select 1 from auth.users
               where id = p_anon_id and coalesce(is_anonymous, false)) then
  raise exception 'source_not_anonymous' using errcode = '42501';
end if;
```
Napomena: minimalni fix i dalje dopušta leak između dva anonimna usera — service-role
linkanje je ispravno rješenje.

> **Autonomni prompt**
> U repou `domovina-api`, RPC `domovina_ai.migrate_anon_data(p_anon_id uuid)` u
> `supabase/migrations/20260528120000_anon_data_migration_rpc.sql` je `security definer`
> grant-an `authenticated` i vjeruje proizvoljnom `p_anon_id`, čime dopušta preuzimanje i
> brisanje tuđih `watch_progress`/`watch_sessions` redova. Istraži kako Flutter frontend
> (`auth_service.dart`, referenciran u komentaru migracije) i eventualna edge funkcija zovu
> ovaj RPC te predloži dva rješenja: (1) minimalni fix — nova migracija koja dodaje provjeru
> da je `p_anon_id` stvarno `auth.users.is_anonymous = true` prije bilo kakvog update/delete;
> (2) robustan fix — prebacivanje na service-role edge funkciju koja dokazuje anon→permanent
> vezu. Implementiraj (1) kao migraciju `20260710120100_fix_migrate_anon_data_guard.sql`
> (poštuj stil postojećih migracija), a (2) opiši kao follow-up plan. Ne diraj živu bazu.

---

## 🟠 SEC-3 — Handoff 6-znamenkasti kod: brute-force do account takeover-a

**Severity:** Visoko · **Datoteke:** `supabase/functions/handoff-consume/index.ts:19-44`, `supabase/migrations/20260520120500_handoff_rpc.sql`

Za konzumaciju koda dovoljan je bilo koji (i anonimni) JWT + 6 znamenki; na pogodak
funkcija vraća magic `action_link` koji pozivatelja prijavljuje **kao ciljni korisnik**.
Prostor je 10^6 unutar 5-min TTL-a, bez brojača pokušaja i bez per-IP throttlea u funkciji
ili RPC-u. Dodatno, kod se generira nekriptografskim `random()` (SEC-3b).

**Fix:**
1. Rate-limit / lockout: tablica `handoff_attempts` (ili edge/WAF pravilo) — nakon N
   neuspjelih pokušaja invalidiraj ciljni kod i throttle-aj pozivatelja/IP.
2. Povećaj entropiju: 8+ znamenki ili alfanumerički kod.
3. Zamijeni `random()` s `extensions.gen_random_bytes()` u generatoru.
4. Minimalno: dokumentiraj da je CF rate-limit pravilo ispred rute **obavezno**
   (već je na TODO listi kao `cf-rate-limiting.md`, ali za `/auth/v1/*`, ne za ovu rutu).

> **Autonomni prompt**
> U `domovina-api`, edge funkcija `handoff-consume` (`supabase/functions/handoff-consume/index.ts`)
> i RPC `consume_handoff_token` (`supabase/migrations/20260520120500_handoff_rpc.sql`) dopuštaju
> brute-force 6-znamenkastog handoff koda (10^6 prostor, 5-min TTL, bez rate-limita) što vodi
> do preuzimanja tuđeg računa. Implementiraj obranu u tri sloja: (1) nova migracija koja dodaje
> `domovina_ai.handoff_attempts` tablicu + logiku u `consume_handoff_token` da broji neuspjele
> pokušaje po ciljnom useru i invalidira kod nakon 5 promašaja; (2) izmijeni generator koda da
> koristi `extensions.gen_random_bytes(3)` umjesto `random()`; (3) dodaj per-IP throttle u edge
> funkciju (npr. brojanje u istoj tablici po `x-forwarded-for`). Napiši migracije po postojećem
> stilu i ažuriraj funkciju. Objasni koji dio i dalje traži CF WAF pravilo. Ne diraj živu bazu/deploy.

---

## 🟠 SEC-4 — svix HMAC verifikatori divergirali (`pinka-webhook` ne strip-a `v1,`)

**Severity:** Visoko (potencijalni tihi auth outage) · **Datoteke:** `supabase/functions/pinka-webhook/index.ts:145`, usporedi `auth-send-email/index.ts:164`, `pinka-onchain-ingest/index.ts:151`

Ista Standard-Webhooks HMAC provjera je copy-paste-ana u tri funkcije, ali `pinka-webhook`
strip-a samo `whsec_` prefiks, dok druge dvije prvo strip-aju `v1,` pa `whsec_`. Ako je
`INTENT_WEBHOOK_SECRET` ikad pohranjen u `v1,whsec_…` formi, `pinka-webhook` će krivo
base64-dekodirati i odbijati **svaki** potpis (tihi ispad naplate). Rješenje se poklapa s
refaktorom X1 (dok. 03): ekstrahiraj `_shared/svix.ts`.

> **Autonomni prompt**
> U `domovina-api` postoje tri kopije svix/Standard-Webhooks HMAC verifikatora
> (`supabase/functions/auth-send-email/index.ts`, `pinka-onchain-ingest/index.ts`,
> `pinka-webhook/index.ts`) i one su divergirale: `pinka-webhook` NE strip-a `v1,` prefiks
> secreta pa bi tiho odbijao potpise da je secret u `v1,whsec_` formi. Kreiraj
> `supabase/functions/_shared/svix.ts` s jednom `verifySvix(secret, id, ts, rawBody, sigHeader, toleranceSec)`
> funkcijom koja ispravno strip-a `v1,` pa `whsec_`, radi timing-safe usporedbu i podržava
> više potpisa u headeru. Zamijeni sve tri inline implementacije pozivom na nju. Zadrži
> `revenuecat-webhook` obrazac (čista logika + test) — dodaj `_shared/svix_test.ts` s
> testovima za `v1,`/`whsec_` matricu, tolerance prozor i multi-signature header. Ne mijenjaj
> ponašanje osim ujednačavanja; pokreni `deno check` na izmijenjenim fajlovima.

---

## 🟡 Srednji nalazi (baza)

### SEC-M1 — `request_payout` KYC čita drugi izvor od kreiranja kampanje
`20260603140000_pinka_payouts.sql` čita `raw_app_meta_data->>'kyc_verified'`, dok
`create_campaign` (`20260610120000`) koristi `public.is_identity_verified()` (gleda
`identity_verifications`). Ako Certilia piše samo `identity_verifications`, `request_payout`
uvijek diže `kyc_required` → isplate mrtve. Ujednači na `public.is_identity_verified()`.

### SEC-M2 — Tier inventory oversell (TOCTOU) u `create_contribution`
Provjera `inventory_claimed + v_qty > inventory_total` čita bez row locka, a `inventory_claimed`
se povećava tek kad contribution postane `paid`. Konkurentni pendinzi svi prođu → oversell.
Dodaj `for update` na tier red i/ili `check (inventory_claimed <= inventory_total)` constraint.

### SEC-M3 — `log_event` bez membership gate-a na `target_account_id`
`20260520120300_triggers_functions.sql`: bilo koji authenticated user može ubaciti proizvoljan
`event_type`/`payload` u feed **bilo kojeg** accounta. Dodaj
`if not public.is_account_member(p_target_account_id) then raise exception 'not_member'; end if;`.

### SEC-M4 — `oauth_states` bez eksplicitnog REVOKE
`20260530130000_channel_ownership.sql`: drži PKCE `code_verifier`, ima RLS+zero policies,
ali za razliku od `user_passkeys`/`identity_verifications` nema `revoke ... from anon, authenticated`.
Nije trenutno iskoristivo (RLS default-deny) ali lomi defense-in-depth obrazac. Dodaj revoke.

### SEC-M5 — `revenuecat-webhook` uspoređuje bearer secret ne-konstantno (`!==`)
`revenuecat-webhook/index.ts:36`: jedini secret compare koji ne koristi `timingSafeEqual`.
Zamijeni konstantno-vremenskom usporedbom.

### SEC-M6 — `pinka-onchain-*` nemaju `[functions.*]` unos u `config.toml`
`config.toml` navodi `verify_jwt=false` za 11 funkcija ali izostavlja obje onchain funkcije.
Lokalni `functions serve` default-a na `verify_jwt=true` → 401 prije koda. Dodaj eksplicitne
blokove za `pinka-onchain-confirm` i `pinka-onchain-ingest`.

### SEC-M7 — `passkey` `requireUserVerification: false` proturječi `userVerification: "required"`
`passkey/index.ts:211,296` prihvaćaju UV=0 iako start (`:182,263`) traži obavezni Face ID/otisak.
Garancija "hardware UV je obavezan" nije stvarno enforcana. Postavi `requireUserVerification: true`
u oba finish poziva (ili ispravi komentare ako je UV-optional namjeran).

> **Autonomni prompt (svi SEC-M nalazi zajedno)**
> U `domovina-api` riješi sljedeće srednje-prioritetne nalaze, svaki kao zasebnu migraciju ili
> edge izmjenu s jasnim commitom:
> 1. `request_payout` (`20260603140000_pinka_payouts.sql`) i `20260603150000_pinka_yield.sql`
>    čitaju KYC iz `raw_app_meta_data->>'kyc_verified'`, a `create_campaign` iz
>    `public.is_identity_verified()` — ujednači sve na `is_identity_verified()`.
> 2. `create_contribution` ima TOCTOU oversell tier inventara — dodaj `for update` na tier red
>    i `check (inventory_claimed <= inventory_total)` constraint.
> 3. `public.log_event` (`20260520120300`) dopušta pisanje u tuđi account feed — dodaj
>    `is_account_member` gate.
> 4. `domovina_ai.oauth_states` (`20260530130000`) — dodaj eksplicitni
>    `revoke all ... from anon, authenticated`.
> 5. `revenuecat-webhook/index.ts:36` — zamijeni `!==` bearer usporedbu s `timingSafeEqual`.
> 6. `config.toml` — dodaj `[functions.pinka-onchain-confirm]` i `[functions.pinka-onchain-ingest]`
>    s `verify_jwt = false`.
> 7. `passkey/index.ts:211,296` — postavi `requireUserVerification: true` da odgovara
>    `userVerification: "required"` iz start poziva.
> Radi migracije po postojećem stilu, ne diraj živu bazu, i za svaku promjenu objasni kako je verificirati.

---

## 🟢 Niski nalazi (kratko)

- **L-DB1** Info leak: RPC-ovi i edge funkcije vraćaju `error.message`/`String(e)` klijentu
  (`certilia`, `handoff-consume`, `passkey`, `safe-owner-add`, `youtube-claim`, `pinka-contribute`).
  Vrati stabilan error kod, `detail` samo u `console.error`.
- **L-DB2** `contribution_status` ne pina `search_path=''` (body je fully-qualified, benigno).
- **L-DB3** `domovina_ai.subscriptions` policy koristi bare `auth.uid()` bez `to authenticated`
  (gubi InitPlan caching).
- **L-DB4** Missing index na FK `contributions.tier_id`.
- **L-DB5** `passkey` novi-signup dopušta squatting na neregistriranim emailovima (nema dokaza
  vlasništva emaila prije mintanja sesije).
- **L-DB6** `youtube-claim` callback dekodira Google `id_token` bez provjere potpisa (nizak rizik
  jer je server-side TLS exchange, ali fragilan obrazac — verificiraj protiv Google JWKS kao
  `certilia`).
- **L-DB7** `pinka-webhook:41` `JSON.parse(raw)` bez try/catch (kozmetički, body je potpisan).

> **Autonomni prompt (niski nalazi)**
> U `domovina-api` počisti niske nalaze iz `docs/review-2026-07/01-fixes-security-correctness.md`
> (sekcija "Niski nalazi"): standardiziraj error odgovore edge funkcija na stabilne kodove
> (detalj samo u logu), dodaj index na `contributions.tier_id`, poravnaj `domovina_ai.subscriptions`
> policy na `(select auth.uid()) ... to authenticated`, dodaj `search_path=''` na `contribution_status`,
> wrap-aj `JSON.parse` u `pinka-webhook`, i verificiraj Google `id_token` u `youtube-claim` protiv
> JWKS (koristi `jose` kao u `certilia`). Grupiraj u smislene commitove. Ne diraj živu bazu/deploy.
