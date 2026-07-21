# 03 — Konzistentnost, refaktori, testovi

Nije hitno, ali smanjuje drift-rizik i olakšava daljnji razvoj. Prioritet: X1 (svix) jer
se poklapa sa sigurnosnim nalazom SEC-4.

---

## X1 — Ekstrahiraj svix/Standard-Webhooks verifikator u `_shared/svix.ts`

`verify` + `decodeSecret` + `hmacBase64` + `timingSafeEqual` su copy-paste u tri fajla
(`auth-send-email:147-196`, `pinka-onchain-ingest:139-183`, `pinka-webhook:134-181`) i **već
su divergirali** (SEC-4: `v1,` stripping). Najvredniji refaktor — jedna `verifySvix()` uklanja
i bug i budući rizik. Prompt je u dok. 01 (SEC-4).

## X2 — `_shared/http.ts` + `_shared/supabase.ts` + `requireUser()`

Svaka od 13 funkcija re-deklarira `json()` responder i re-čita `SUPABASE_URL`/`SERVICE`/`ANON`.
Dva stila odgovora koegzistiraju (s `corsHeaders` za browser, bez za webhookove). `maybeUser`/
`getUser` anon-aware auth je neovisno reimplementiran u 6 funkcija.

> **Autonomni prompt**
> U `domovina-api/supabase/functions` ekstrahiraj zajednički boilerplate: (1) `_shared/http.ts`
> s `json()` i `jsonCors()` responderima; (2) `_shared/supabase.ts` s `adminClient()` i
> `userClient(authHeader)` factory-jima koji čitaju env; (3) `_shared/auth.ts` s
> `requireUser(req, { allowAnon })` koji centralizira pravilo "anonimni ≠ prijavljen" (trenutno
> reimplementiran u `account-delete`, `passkey`, `safe-owner-add`, `youtube-claim`,
> `pinka-contribute`, `handoff-consume`). Refaktoriraj sve funkcije da ih koriste, bez promjene
> ponašanja. Pokreni `deno check` na svemu. Radi u malim commitovima po funkciji.

## X3 — Standardiziraj HTTP status konvencije

`safe-owner-add` i `youtube-claim` vraćaju business failure kao `200 {ok:false, error:...}`,
dok `account-delete`/`passkey`/`pinka-contribute` koriste prave 4xx. Nije bug ali klijenti
moraju special-case-ati svaku funkciju. Dogovori jedan obrazac i primijeni.

## X4 — Testovi (samo `revenuecat-webhook` ima)

Model je `revenuecat-webhook` (čista `decide()` logika + `logic_test.ts`, 12 slučajeva).
Najvredniji dodaci po redu:
1. `verifySvix` modul (nakon X1) — testovi za `v1,`/`whsec_` matricu, tolerance, multi-signature.
2. Ekstrahiraj `pinka-onchain-confirm` receipt-log→cents parsing (topic match, address
   `0x+slice(26)`, RAIL_SAFE exclusion, wei→cents) u čistu funkciju i testiraj — to je
   najrizičniji neparsirani untrusted input u cijelom kodu.
3. Čisti testovi za `certilia` claim extraction / canonical-email derivaciju.

> **Autonomni prompt**
> U `domovina-api`, po uzoru na `revenuecat-webhook` (čista logika + `logic_test.ts`), izdvoji
> testabilnu logiku i napiši Deno testove za: (1) `pinka-onchain-confirm` — parsiranje EURe
> Transfer log-a u cente (topic match, adresa `0x + slice(26)`, isključivanje RAIL_SAFE forwarda,
> wei→cents konverzija) u `_shared` ili `logic.ts` + `logic_test.ts`; (2) `certilia` — derivaciju
> kanonskog `HMAC(oib)` emaila i claim extraction. Ne mijenjaj runtime ponašanje, samo izdvoji
> čiste funkcije i pokrij ih testovima. Pokreni `deno test`.

## X5 — Ops skripte: zajednička `scripts/lib/`

Duplicirano: `mask()` 5× (dvije divergirane varijante `****` vs `…`), `gen_alnum()` 2×,
ANON-key ekstrakcija iz kontejnera 3×, PATCH→POST upsert fallback 3×, container-grep patterni
razbacani. Fixed `/tmp` imena (`/tmp/_code`, `/tmp/_c` …) uzrokuju race kod paralelnih sesija.

> **Autonomni prompt**
> U `domovina-api/scripts`, konsolidiraj dupliciranu logiku u `scripts/lib/`: jedinstveni
> `mask()` (trenutno 5 kopija, 2 divergirane), `gen_alnum()`, ANON-key ekstrakcija iz kontejnera,
> i PATCH→POST Coolify upsert helper. Zamijeni sve fixed `/tmp/_*` privremene fajlove s `mktemp`
> (race kod paralelnih CC sesija). Popravi i `coolify_curl` protokol (HTTP kod na stderr je
> fragilan) da postavlja globale `COOLIFY_HTTP_CODE`/`COOLIFY_BODY`. Testiraj `bash -n` na svemu,
> ne mijenjaj vanjsko ponašanje skripti.

## X6 — SQL sitnice
- `create_contribution` / `mark_contribution_paid` / `record_sepa_contribution` su
  `create or replace`-ani kroz 4–5 migracija svaki, s copy-paste cijelog tijela → divergence
  rizik. Nije problem sada, ali razmisli o generatoru ili barem komentaru koji upućuje na
  "authoritative" verziju.
- `account_id` znači *user id* u `domovina_ai` channel-ownership tablicama, ali *accounts.id*
  u `pinka_finance` — zbunjujuće. Dokumentiraj ili preimenuj u budućoj migraciji.
