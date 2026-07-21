# Pinka slots — rezervacija pojedinačno birljivih mjesta

Status: **implementirano, nije deployano** (migracija `20260722120000_pinka_slots.sql`).

## Zašto generički sloj

Donacijski grid 120×120 (kvadratić = doprinos, skuplje prema središtu) i prodaja
**numeriranih ulaznica** (konferencija, utakmica, koncert) su isti tehnički problem:

> fiksan skup jedinstveno identificiranih mjesta, pojedinačno birljivih,
> s atomarnim holdom preko **asinkrone** uplate.

Postojeći ticketing (`20260716120000` / `…200`) zna samo za **količine**
(`campaign_tiers.inventory_total/inventory_claimed`); `serial` se dodjeljuje tek pri
izdavanju, a `unit='seat'` (`20260716120200:151`) je puki natpis. Numerirano sjedalo
prije ovoga nije postojalo. Zato je sloj napisan generički, a grid mu je prvi potrošač.

## Model

| tablica | uloga |
|---|---|
| `slot_maps` | jedna po kampanji: `kind` (`grid`\|`seatmap`), dimenzije, `conflict_policy`, TTL, anti-grief limit |
| `slot_zones` | cjenovni razredi — grid: koncentrični prstenovi, seatmap: sektori. `zone_index` 0 = najjeftinije |
| `slots` | mjesto: `slot_key`, `zone_id`, `state`, `contribution_id`, `token_id`, hold polja |

**Mjesta se seedaju unaprijed**, sva u `state='free'`. 14.400 redova po kampanji je
za Postgres trivijalno (~2 MB), a nosi tri stvari:

1. Rezervacija je **jedan `UPDATE … WHERE`** — row lock i provjera dostupnosti u istoj
   naredbi (prior art: `20260716120200:408-416`). Nema `INSERT … ON CONFLICT` krađe,
   nema TOCTOU prozora, nema advisory lockova.
2. „Slobodno" je red u bazi, a ne *odsutnost* reda → render i brojanje su obični upiti.
3. Seat mapa ionako mora biti pre-seedana (sjedala fizički postoje, s rupama za
   prolaze) → pre-seed je zajednički imenitelj, ne kompromis za grid.

`token_positions` se **ne** koristi — tamo „position" znači financijski udio
(`units numeric`), ne koordinatu.

### Stanja

`free → held → sold → minted`, plus `blocked` (prolaz u dvorani, ćelija koju je
organizator izuzeo).

**Istekli hold nije zasebno stanje.** Red ostaje `held` s prošlim `hold_expires_at` i
tretira se kao slobodan na dva mjesta: u `WHERE` klauzuli rezervacije i u javnom viewu.
Partial unique index s `now()` nije opcija — `now()` nije `IMMUTABLE`.

## Tri hazarda

### H1 — TTL naspram SEPA

Hold i rail intent **umiru istovremeno po konstrukciji**:

| kanal | TTL |
|---|---|
| provizorni (u `create_contribution`, prije nego rail odgovori) | 10 min |
| SEPA rail intent | `intent.expires_at`, clamp `[·, 24 h]` |
| in-app wallet (EURe) | isto, ali uplata sjedne u sekundama |

`attach_intent` produžuje hold **samo naprijed** (`greatest(…)`), pa webhook retry s
kraćom vrijednošću ne može skratiti postojeći hold.

> ⚠ **Zatečeni bug, popravljen usput.** `pinka-contribute` nije slao
> `expires_in_seconds`, pa je rail primjenjivao `DEFAULT_TTL_SECONDS = 900`
> (`pay.domovina.ai/backend/src/intents/api.ts:36`) — **svi SEPA intenti su istjecali
> za 15 minuta**. Kasna uplata na istekli intent nikad ne postane plaćena
> (`markIntentPaid` traži `state='pending'`; `confirm.ts:228` to izrijekom kaže) i
> merchant webhook se ne emitira → doprinos zauvijek `pending`. Sweep se vrti svakih
> 6 h (`wrangler.toml:35`) pa je praktični prozor bio 15 min–6 h. Sada tražimo
> `INTENT_TTL_SECONDS = 86400` (rail hard cap). Iznad 24 h ne možemo bez podizanja
> `MAX_TTL_SECONDS` na railu — taj slučaj pada u H2.

### H2 — kasna uplata

`mark_contribution_paid` sada prihvaća `state in ('pending','expired','failed')`.
Novac je na Safeu; odbiti ga zato što je istekao *naš interni timer* je najgori mogući
ishod. `'paid'` i `'refunded'` ostaju isključeni pa idempotencija preživi.

`claim_slots_for_contribution` (iz trigera, na prijelaz u `paid`) ima četiri ishoda:

| ishod | kada |
|---|---|
| `kept` | naš hold još stoji → promocija u `sold` |
| `reclaimed` | hold istekao ali mjesto još slobodno → vraćamo ga |
| `relocated` | mjesto preoteto, `conflict_policy='relocate_same_or_better'` → najbliže slobodno u **istoj ili skupljoj** zoni (nikad jeftinijoj — ta je cijena plaćena) |
| `lost` / `unassigned` | `conflict_policy='flag_for_refund'` (sjedalo je obećanje, ne seli se tiho) ili je mapa puna → `contributions.slot_unassigned = true` + audit event |

Funkcija **nikad ne raise-a**; trigger je dodatno omotan u `begin … exception` jer bi
iznimka rollbackala cijelu uplatu. Poslovni neuspjeh je podatak (event), ne iznimka.

> **Regresija koju otvara proširenje `mark_contribution_paid`:** sad je moguć prijelaz
> `expired → paid`. Za rezerviranu ticket narudžbu inventar je već vraćen na expire, a
> postojeća grana ga ne bi ponovno uzela (traži `not new.reserved`) → tihi oversell.
> Trigger zato ima eksplicitnu granu za taj prijelaz.

### H3 — istekli holdovi bez crona

Tri sloja, redom po važnosti:

1. **View** mapira istekli `held` u `'free'` — nestaje s ekrana isti trenutak.
2. **`WHERE (state='free' or hold_expires_at <= now())`** u rezervaciji — istekli hold
   se preuzima in-place. **Za ispravnost cron uopće ne treba.**
3. `expire_stale_slot_holds()` — higijena, uz 24 h grace (dok red postoji, `claim` ga
   može jeftino vratiti kasnoj uplati). Zove se oportunistički iz `pinka-contribute`;
   `cron.schedule` blok je zakomentiran u migraciji.

## Utrke i deadlock

`reserve_slots` prima **niz** ključeva (obitelj kupuje 4 sjedala, sponzor blok 3×3) i
radi all-or-nothing. Ključevi se prije zaključavanja **sortiraju**:

```sql
select array_agg(k order by k) into v_keys from unnest(p_slot_keys) k;
```

Bez toga dvije istovremene rezervacije s preklapajućim skupovima (`{A,B}` i `{B,A}`)
zaključavaju redove obrnutim redoslijedom i **deadlockaju** — bug koji se pojavi tek
pod opterećenjem, u produkciji.

Cijenu određuje **server** (zbroj `slot_zones.price_cents`); klijent ne smije tvrditi
da je jezgra 1 €.

## On-chain put

`record_onchain_contribution` (`20260602140000:24-58`) uvijek **INSERTA NOVI** doprinos.
Za mjesta bi to značilo: korisnik izabere kvadratić (hold uz pending doprinos), plati
in-app novčanikom, confirm napravi *drugi* doprinos bez mjesta → hold istekne, korisnik
je platio i nije dobio ništa.

`confirm_slot_contribution(campaign_id, contribution_id, tx_hash, log_index, from, cents)`
umjesto toga kreditira **konkretan** pending doprinos. Dijeli isti idempotency ključ
`(forward_tx_hash, onchain_log_index)` pa se s postojećim putem nikad ne duplira,
provjerava da doprinos pripada kampanji čiju je `destination_address` edge funkcija
verificirala u Transfer logu, i odbija manjak.

`pinka-onchain-confirm` grana na `contribution_id` u body-ju; bez njega ide stari put.

## Seed

```sql
-- grid: 120×120, 10 prstenova 1 €…1000 € (donjih pet se poklapa s preset
-- čipovima u pinka_contribute_panel.dart)
select pinka_finance.seed_grid_map('<campaign_id>');

-- seatmap: sektor/red/sjedalo iz JSON layouta
select pinka_finance.seed_seatmap('<campaign_id>', '{"zones":[…],"seats":[…]}'::jsonb);
```

## Klijent (domovina.ai)

- `PinkaSlot` / `PinkaSlotZone` / `PinkaSlotMap` / `PinkaSlotTaken` —
  `lib/pinka_sdk/src/models/pinka_slot.dart`
- `PinkaClient.slotMap(campaignId)` → `null` ako kampanja nema mapu
- `PinkaClient.slots(campaignId)` → dohvaća samo `state <> 'free'` (slobodna mjesta su
  većina i nose nula informacije)
- `PinkaClient.contribute(…, slotKeys: [...])` → baca `PinkaSlotTaken` na 409

**Grid mod se pali podacima, ne feature flagom**: nema mape → legacy prikaz, ima mape →
server je izvor istine. Nema flaga koji bi trebalo držati usklađenim s backendom.

## Redoslijed deploya

1. `./scripts/db-migrate.sh` — aditivno; stari frontend zove `create_contribution` bez
   `p_slot_keys` → `null` → stara putanja netaknuta.
   Poslije: `notify pgrst, 'reload schema'` (signatura funkcije se promijenila).
2. `./scripts/deploy-functions.sh --only=pinka-contribute` i `--only=pinka-onchain-confirm`.
3. Seed test kampanje (`unlisted`) → render, kupnja, istek holda, utrka.
4. Frontend.
5. **Seed produkcijske mape = trenutak uključenja.** Reverzibilno:
   `delete from slot_maps where campaign_id = …` vraća legacy prikaz.

> ⚠ `scripts/db-migrate.sh:87-91` backupira samo `public` i `domovina_ai` —
> **`pinka_finance` nije u backupu.** Prije migracije ručni
> `./scripts/db-dump.sh --schemas pinka_finance --data`.

## Testirano

Protiv kopije produkcijske sheme (schema-only dump → scratch Postgres 16):

- seed: 14.400 mjesta, 10 zona, kut = zona 0 @ 1 €, središte = zona 9 @ 1000 €,
  `token_id` = 7260 za (60,60)
- rezervacija → hold; ponovljena → `slot_taken`; 1 € za jezgru → `amount_below_slot_price`
- istekli hold: u viewu `free`, preuzimljiv, namjera prvog korisnika preživi
- **kasna uplata na `expired`**: `mark_contribution_paid` → `true`, doprinos `paid`,
  mjesto relocirano u istu zonu, event zapisan, statistika uvećana točno jednom
- TTL: provizornih 10 min → produženje na vijek intenta → retry ne skraćuje → clamp 24 h
- on-chain: kreditira postojeći doprinos, idempotentno, odbija manjak i tuđu kampanju
- refund oslobađa mjesto; `anon` vidi `public_slots`, ne vidi `contributions`
- **utrka: 12 paralelnih procesa na istu ćeliju → 1 uspjeh, 11 × `slot_taken`,
  nula deadlockova**
- unatražna kompatibilnost: stari poziv s 5 imenovanih parametara radi;
  `create_contribution` ima točno 1 overload (nema PGRST203 dvosmislenosti)
