# Review: sponzorski trenuci + gostujuća donacija (8.10.2026.)

Pregled commitova `a07d384`, `6d6947e`, `a4e8ff1`, `d977638`, koji su na
produkciji od 8.10.2026. (deploy journal `deploys/20261008T061422Z-6d6947e.md`).
Ispod je backendni dio. Frontendni dio je u `domovina.ai`:
`docs/2026-10-08-review-sponzorski-trenuci-frontend.md`.

Nalazi označeni s **provjereno** potvrđeni su čitanjem koda. Ponovna provjera
8.10.2026. pokazala je da nijedan još nije popravljen. Do tada se ništa nije
prodalo, pa nalazi oko novca zasad nisu napravili štetu.

> **Repo je javan.** Tri nalaza tiču se zaobilaženja autorizacije i limita.
> Ovdje su opisani samo kao zadatak popravka, bez načina iskorištavanja. Puni
> opis je u privatnoj bilješci
> `~/.claude/handoffs/domovina-api/2026-10-08-review-sigurnosni-nalazi.md`.

## 1. KRITIČNO: `handoff-consume` traži sesiju koju klijent više nema (provjereno)

- `supabase/functions/handoff-consume/index.ts:16-17` vraća
  `401 not_authenticated` kad poziv nema sesije.
- Frontend v2.0.172 (`domovina.ai` `b372c69`) više ne zove `signInAnonymously`.
- Posljedica: prijava novog uređaja kodom ne radi nikome tko nema staru
  anonimnu sesiju. To su svježa instalacija, novi preglednik, TV i svatko nakon
  odjave. Kvar je **živ na produkciji**.

Popravak:
- pustiti poziv bez sesije, uz limit po IP-u (`guestAllowed` iz
  `_shared/guest.ts`), jer šesteroznamenkasti kod ima samo 10⁶ kombinacija;
- `activity_events.actor_user_id` mora podnijeti `null` (danas se upisuje
  `user.id`);
- ispraviti zaključak §7 (`sponzorski-trenuci-zakljucak.md:269`), koji tvrdi
  da „sve ostalo već traži pravi račun ili radi bez sesije".

## 2. VISOKO: gubitak jednog trenutka obilježi cijelu narudžbu (provjereno)

- Ako narudžba ima više trenutaka, a jedan od njih je u međuvremenu prodan
  drugome, `claim_slots_for_contribution` postavi `slot_unassigned = true` za
  cijeli contribution (`20260722120000_pinka_slots.sql:737`, isto `:783`).
- `_shared/sponsor.ts:106` zbog toga preskoči račun za **sve** trenutke, iako
  su ostali uživo.
- `_shared/sponsor.ts:265` pošalje alarm „kreativa nije nigdje prikazana,
  povrat je ručan", što nije istina.

Popravak: stanje dodjele voditi po slotu, a račun i alarm računati nad stvarno
dodijeljenim trenucima (djelomičan račun ili djelomičan povrat, odluka vlasnika).

## 3. SREDNJE: sigurnosni nalazi (detalji u privatnoj bilješci)

- **3a (provjereno):** grana `pinka-contribute` za rezervaciju mjesta mora
  zahtijevati pravi račun i za anonimnu sesiju, kao što to već radi sponzorska
  grana (`index.ts:119` naspram `:122`). Ovo je hitno dok GoTrue na produkciji
  dopušta anonimne prijave (zaključak §7, koraci 3–6 nisu odrađeni).
- **3b (vjerojatno):** `create_contribution` mora odbiti kartu vrste
  `timeline`, tako da sponzorski trenutak ide isključivo kroz
  `create_sponsor_contribution` (podaci kupca, uvjeti, račun).
- **3c:** limit za gosta (`_shared/guest.ts`) treba atomarnu provjeru i
  fail-closed ponašanje pri grešci baze.

## 4. SREDNJE: premala uplata za kvadratić na zidu tiho pada

Do `a07d384` je kvadratić bio dodijeljen i uz manjak (H2 ponašanje). Sada
contribution postane `failed` i novac ostane na Safeu, a alarm ne ide nikome
jer se šalje samo za sponzorske narudžbe. Treba ili alarm i za grid/sjedala,
ili vratiti H2 ponašanje za te vrste karte (commit kaže da ga zadržavaju, pa
provjeriti što je namjera).

## 5. NISKO (lako se zaboravi)

- **Fiskal nije podešen.** Dok na produkciji nema `FISKAL_API_KEY`,
  `FISKAL_POSLOVNI_PROSTOR` i `FISKAL_NAPLATNI_UREDAJ` (a `FISKAL_*` URL je
  fiskal-test), svaki račun pada na `fiskal_not_configured`. Svaka plaćena
  narudžba tako u ~1,5 dan potroši 12 pokušaja i ispadne iz retryja.
  Konfiguracijska greška ne bi smjela trošiti pokušaje.
- **Slanje eRačuna nije idempotentno.** Izdavanje ima `Idempotency-Key`, ali
  ponovni pokušaj nakon izdanog računa može dvaput pozvati `/posalji-eracun`.
- **EU kupac s VAT ID-om** plaća 25 % PDV-a umjesto prijenosa porezne obveze
  (pitanje za računovođu, plan P1/P2).
- **`logo_path` u javnom viewu** nosi kupčev user ID u putanji. Treba
  neprozirna putanja ili samo javni URL.

## Provjereno i ispravno

- Nijedan javni view ne otkriva `buyer_*` ni stanje `held`.
- Isti contribution ne može dobiti dva računa (Idempotency-Key + lease).
- PDV se ispravno zbraja.
- SECURITY DEFINER funkcije imaju zaključan `search_path`.

## Predloženi redoslijed

1. **Odmah:** 1 (handoff, živ kvar), 3a i 3b. Svi su mali i lokalizirani.
2. **Prije prve prodaje:** 2, 4, 3c, 5 (fiskal i idempotentnost slanja).
3. **Odluka vlasnika:** djelomičan račun ili povrat (2), EU reverse charge (5).
