# Sponzorski trenuci — ugovor backend ↔ frontend

*Status: **ugovor v2, 7.10.2026.** (v2: anonimne prijave se gase — sponzor traži pravi račun, donacija ide kao gost, §9) Backend (`domovina-api`) i frontend
(`domovina.ai`) rade isključivo po ovom dokumentu. Promjena ugovora = promjena
ovog fajla u istom commitu kao i kod.*

Plan: `domovina.ai/docs/plans/2026-10-06-mvp-sponzorski-trenuci-domovina-tv.md`.
Migracije: `20261007120000_sponzorski_trenuci.sql` (shema, RPC-ovi, viewovi),
`20261007120100_sponzorski_trenuci_seed.sql` (kampanja + karta `domovina_tv`).

---

## 0. Odluke koje ovaj ugovor fiksira

| # | Odluka | Zašto |
|---|---|---|
| O1 | **Jedna kampanja, jedna `timeline` karta za SVE epizode kanala.** Epizoda je kolona `slots.youtube_id`, ne zasebna karta. `unique(campaign_id)` na `slot_maps` **ostaje**. | `reserve_slots`, `claim_slots_for_contribution` i `mark_contribution_paid` (put novca) traže kartu po `campaign_id`. Kampanja po epizodi = 7 kampanja × (Safe, stats, KYC gate) i nova kampanja za svaku novu epizodu. Ukidanje uniquea = izmjena funkcija kroz koje prolazi svaki novac. Ovako je nova epizoda samo `insert` u `slots`, a „karta epizode" je filtar `youtube_id = …`. |
| O2 | Kampanja `domovina-tv-sponzorski-trenuci` je **zasebna** od donacijske `podrzi-domovina-podcast`, `visibility = 'unlisted'`, isti vlasnik i isti Safe. | Kupnja oglasa nije donacija: ne smije ući u zid podrške ni u statistiku donacija. `unlisted` je drži izvan popisa kampanja. |
| O3 | **Cijena je bruto** (PDV 25 % uključen) i određuje je server. Klijent ne šalje iznos. | Brand plaća točno ono što vidi. Račun računa neto = bruto / 1,25. |
| O4 | **Manjak uplate**: `state = 'failed'` + `underpaid = true`. Novi enum nije uveden. | `failed` već postoji i klijent ga tretira kao završno stanje. Novi enum bi srušio svaki klijent koji parsira stanje. Flag nosi razlog. |
| O5 | `conflict_policy = 'flag_for_refund'`. Trenutak se nikad ne seli tiho na drugi trenutak. | Brand je kupio *taj* trenutak *te* epizode. |
| O6 | Ispravnost isteka ne ovisi o cronu: view gleda `live_until > now()`, a checkout prije rezervacije poziva `expire_live_slots()`. Cron je higijena. | Isti princip kao istekli hold (H3 u `pinka-slots.md`). |

---

## 1. Identifikatori

| Što | Vrijednost |
|---|---|
| `campaign_id` | `7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101` |
| slug | `domovina-tv-sponzorski-trenuci` |
| `slot_key` | `<youtube_id>@<start_sec>`, npr. `WRE248YCIeI@33` |
| Storage bucket | `sponsor-logos` (javan za čitanje) |

`slot_key` se ne parsira na klijentu. `youtube_id` i `start_sec` dolaze kao zasebne kolone.

---

## 2. Izlog — `pinka_finance.public_sponsor_moments`

Svi trenuci svih epizoda, za kartu u izlogu (`/c/domovina-tv/oglasi`, `/v/:id/sponzoriraj`).
Čitljivo za `anon` i `authenticated`.

```
GET /rest/v1/public_sponsor_moments?youtube_id=eq.WRE248YCIeI&order=start_sec
Accept-Profile: pinka_finance
```

| kolona | tip | značenje |
|---|---|---|
| `campaign_id` | uuid | |
| `slot_key` | text | šalje se u checkout |
| `youtube_id` | text | epizoda |
| `start_sec` | int | početak trenutka, `[start_sec, end_sec)` |
| `end_sec` | int | kraj (isključivo) |
| `title` | text | naslov sekcije članka koja počinje u trenutku |
| `zone_index` | smallint | 0 = najjeftinije |
| `zone_label_key` | text | ARB ključ zone: `sponsorZoneZatvaranje`, `sponsorZoneTijelo`, `sponsorZoneOtvaranje` |
| `price_cents` | int | **bruto** cijena, EUR centi |
| `run_days` | int | koliko dana trenutak traje nakon uplate |
| `state` | text | `free` \| `held` \| `sold` \| `blocked` |
| `live_until` | timestamptz | samo kad je `sold` (do kada je zauzeto), inače `null` |

- Istekli hold i istekli zakup prikazuju se kao `free`, bez ikakvog joba.
- `held` znači da netko upravo plaća. Ne otkriva ništa drugo.
- Ime branda **nije** u ovom viewu. Prikaz plaćenog trenutka ide kroz §3.

---

## 3. Prikaz plaćenog trenutka — `pinka_finance.public_live_moments`

Samo trenuci koji su **sada** uživo: `sold` ∧ `now() ∈ [live_from, live_until)` ∧
`not message_hidden`. Izvor za `SponsoredMoment` (traka u playeru, oznaka u
članku, pojas na seek baru).

```
GET /rest/v1/public_live_moments?youtube_id=eq.WRE248YCIeI&order=start_sec
Accept-Profile: pinka_finance
```

| kolona | tip | značenje |
|---|---|---|
| `slot_key` | text | |
| `youtube_id` | text | |
| `start_sec` | int | |
| `end_sec` | int | |
| `brand` | text | ime branda (≤ 60) — tekst „Sponzorirano · {brand}" |
| `tagline` | text \| null | jedna rečenica (≤ 120) |
| `link_url` | text \| null | uvijek `https://`, ide s `rel="sponsored"` |
| `logo_url` | text \| null | puni javni URL loga |
| `logo_path` | text \| null | put u bucketu (za `storage.from('sponsor-logos').getPublicUrl`) |
| `live_from` | timestamptz | |
| `live_until` | timestamptz | |

View **nikad** ne sadrži `buyer_*`, iznos, e-poštu ni trenutke u stanju `held`.
Povučen trenutak (`message_hidden`) nestaje iz viewa isti tren.

---

## 4. Upload loga (prije plaćanja)

1. Klijent ima Supabase sesiju **s pravim računom** (Google, Apple ili e-pošta).
   Anonimna sesija ne smije uploadati (RLS), a anonimne prijave se gase.
2. Upload u bucket `sponsor-logos` na put **`<auth.uid()>/<bilo_koji_id>.<png|jpg|jpeg|webp>`**,
   `id` = `[A-Za-z0-9_-]{1,64}`.
3. Ograničenja (bucket ih nameće, server ih ponovno provjerava u checkoutu):
   - ≤ **200 kB** (204 800 B);
   - MIME `image/png`, `image/jpeg`, `image/webp`;
   - pisati smiješ samo u svoju mapu; nema `update` ni `delete` (logo je nepromjenjiv).
4. U checkout se šalje taj put kao `logo_path`. Logo je **opcionalan**.

---

## 5. Checkout — `POST /functions/v1/pinka-contribute`

Postojeća funkcija, nova grana kad body ima `sponsor`. Header `Authorization: Bearer <access_token>`
**pravog računa**. Bez sesije ili s anonimnom sesijom → `401 login_required`; klijent tada
nudi „Prijavi se s Googleom" i nastavlja checkout nakon prijave.

```json
{
  "campaign_id": "7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101",
  "slot_keys": ["WRE248YCIeI@33"],
  "sponsor": {
    "brand": "Primjer d.o.o.",
    "tagline": "Jedna rečenica o brandu.",
    "link_url": "https://primjer.hr",
    "logo_path": "3f1c…/logo.png",
    "terms_accepted": true,
    "buyer": {
      "company": "Primjer d.o.o.",
      "oib": "12345678903",
      "vat_id": "HR12345678903",
      "email": "racuni@primjer.hr",
      "address": { "street": "Ilica 1", "city": "Zagreb", "postal_code": "10000", "country": "HR" },
      "reference": "PO-2026-118"
    }
  }
}
```

| polje | obavezno | pravilo |
|---|---|---|
| `slot_keys` | da | 1–3 ključa, svi iz iste kampanje |
| `brand` | da | 1–60 znakova |
| `tagline` | ne | ≤ 120 |
| `link_url` | ne | samo `https://`, ≤ 500, bez razmaka |
| `logo_path` | ne | §4 |
| `terms_accepted` | da | mora biti `true` |
| `buyer.company` | da | 1–200 |
| `buyer.oib` | ne | 11 znamenki + ispravna kontrolna znamenka (ISO 7064 MOD 11,10) |
| `buyer.vat_id` | ne | `[A-Z]{2}[A-Z0-9]{2,13}` |
| `buyer.email` | da | ≤ 200, oblik e-pošte |
| `buyer.address.*` | ne | `street` ≤ 200, `city` ≤ 100, `postal_code` ≤ 16, `country` ISO alpha-2 (zadano `HR`) |
| `buyer.reference` | ne | ≤ 100 (PO broj, ide na račun) |

Tekstovi prolaze kroz `sanitize_ugc` (uklanja kontrolne znakove, trim). `amount_cents`,
`display_name`, `message` i `anonymous` se za sponzorsku granu **ignoriraju**:
iznos je zbroj cijena trenutaka, `brand` postaje `display_name`, a `tagline` postaje `message`.
Kupnja nikad nije anonimna (DSA čl. 26).

**Odgovor 200** je isti kao za postojeći SEPA panel (`PinkaClient.contribute`):

```json
{
  "contribution_id": "…", "sid": "…", "state": "pending",
  "amount_cents": 5000, "amount_eur": 50, "currency": "EUR",
  "memo": "mpt:0x…?sid=…", "iban": "…", "beneficiary_name": "…", "bic": "…",
  "epc_qr_data": "…", "checkout_url": "…", "status_url": "…",
  "expires_at": "…", "slot_keys": ["WRE248YCIeI@33"], "hold_expires_at": "…"
}
```

`hold_expires_at` = do kada je trenutak zaključan (isto kao vijek intenta, max 24 h).

### Kodovi grešaka

| HTTP | `error` | značenje / što klijent radi |
|---|---|---|
| 401 | `login_required` | nema sesije ili je anonimna — prijava (Google/Apple/e-pošta) pa ponovi |
| 400 | `invalid_sponsor:<polje>` | validacija, npr. `invalid_sponsor:buyer_oib`, `invalid_sponsor:link_url`, `invalid_sponsor:logo_path`, `invalid_sponsor:terms` |
| 400 | `not_sponsor_campaign` | kampanja nema `timeline` kartu |
| 400 | `campaign_not_found` / `campaign_not_active` | |
| 400 | `invalid_slot_keys` / `too_many_slots` | |
| **409** | `slot_taken:<slot_key>` | netko te pretekao — osvježi kartu, ponudi drugi trenutak |
| **409** | `too_many_holds` | ova sesija već drži 3 neplaćena trenutka |
| 502 | `intent_create_failed` | rail nije odgovorio; hold je već otpušten, smije se ponoviti |

Stvarni tekst greške iz baze može imati dodatni sufiks (`slot_taken:WRE248YCIeI@33`).
Klijent uspoređuje **prefiks** do prve dvotočke.

---

## 6. Stanja

### Contribution (`pinka_finance.contributions.state`)

```
pending ──(uplata ≥ cijena)──▶ paid
   │ └──(uplata < cijena)───▶ failed  + underpaid = true   (trenutak NIJE dodijeljen, alarm)
   └──(intent istekao)──────▶ expired  ──(kasna uplata ≥ cijena)──▶ paid
```

### Slot (`public_sponsor_moments.state`)

```
free ──reserve──▶ held ──uplata──▶ sold (live_from = uplata, live_until = + run_days)
  ▲                │                 │
  └──hold istekao──┘                 └──live_until prošao──▶ free
```

`blocked` = ručno isključen trenutak (ne prodaje se).

### Status narudžbe — `rpc/sponsor_order_status`

```
POST /rest/v1/rpc/sponsor_order_status   { "p_contribution_id": "…" }
Content-Profile: pinka_finance
```

Vraća jedan red:

| kolona | tip | |
|---|---|---|
| `state` | text | `pending` \| `paid` \| `failed` \| `expired` \| `refunded` |
| `underpaid` | bool | `true` → uplata manja od cijene, trenutak nije dodijeljen |
| `amount_cents` | bigint | cijena |
| `amount_received_cents` | bigint \| null | primljeno |
| `paid_at` | timestamptz \| null | |
| `slot_unassigned` | bool | plaćeno, ali trenutak je u međuvremenu prodan drugome (kasna uplata) → ručni povrat |
| `slots` | jsonb | `[{slot_key, youtube_id, start_sec, end_sec, state, live_from, live_until}]`; nakon isteka zakupa snapshot prodanih trenutaka (bez `state`) |
| `invoice_state` | text \| null | `pending` \| `issued` \| `sent` \| `failed` \| `skipped` |
| `invoice_number` | text \| null | broj računa kad je izdan |
| `hidden` | bool | vlasnik je povukao kreativu |

`contribution_id` je capability, kao kod postojećeg `contribution_status`. Nema PII u odgovoru.
Postojeći `contribution_status` i MPT SSE rade kao i dosad. `paid` znači da je trenutak živ
ili da je `slot_unassigned`.

---

## 7. Što frontend NE radi

- Ne računa cijenu i ne šalje iznos.
- Ne piše u `slots` ni `contributions` mimo `pinka-contribute`.
- Ne prikazuje `held` kao „prodano s brandom". Brand postoji tek u `public_live_moments`.
- Ne spaja „Sponzorirano" s `SponsorsInVideo` (autorovi sponzori). Odvojen izvor, odvojen widget.

## 8. Povlačenje kreative (vlasnik kanala)

Vlasnik pri svakoj prodaji dobije e-poštu s linkom
`<SUPABASE_PUBLIC_URL>/functions/v1/sponsor-moderate?c=<contribution_id>&t=<token>`.
`GET` prikazuje stranicu s gumbom, a tek `POST` (klik na gumb) postavlja
`message_hidden = true`. Skeneri linkova u e-pošti zato ne mogu slučajno povući oglas.
Frontend za ovo ne treba ništa.

---

## 9. Bez anonimnih prijava: gostujuća donacija

Anonimne prijave se gase (`docs/sponzorski-trenuci-zakljucak.md` §7). Klijent
**ne zove `signInAnonymously` nigdje** (ni pri pokretanju, ni nakon odjave,
ni u `ensureSession`). Bez prijave korisnik nema Supabase sesiju i čita sve
javno s anon ključem.

**Donacija (SEPA panel) bez prijave** = isti `POST /functions/v1/pinka-contribute`,
bez sesije (`Authorization: Bearer <anon key>`, što supabase klijent šalje sam):

```json
{ "campaign_id": "…", "amount_cents": 1000, "display_name": "…", "message": "…",
  "anonymous": false, "slot_keys": null, "turnstile_token": "<Cloudflare Turnstile token>" }
```

| HTTP | `error` | |
|---|---|---|
| 401 | `login_required` | gost je poslao `slot_keys` (grid kvadratić, sjedalo, trenutak): mjesta traže pravi račun |
| 401 | `not_authenticated` | poslan je bearer koji NIJE anon ključ, a sesija ne vrijedi (istekla) — osvježi sesiju; klijent ne smije tiho prijeći u gosta |
| 403 | `captcha_failed` | Turnstile token nedostaje ili nije valjan. Provodi se tek kad je na backendu postavljen `TURNSTILE_SECRET_KEY`; klijent ga uvijek šalje. |
| 429 | `rate_limited` | 30 uspješnih gostujućih doprinosa s iste IP adrese u satu (neuspjeli pokušaji se ne broje) |

**Turnstile token je jednokratan**: troši se pri svakom zahtjevu. Nakon BILO
KOJEG odgovora (i 400/409) widget se resetira prije ponovnog pokušaja.

Ostali odgovori i greške su isti kao za prijavljenog korisnika. Gostujući
doprinos nema account (kao dosadašnja anonimna sesija). Status se polla
postojećim `rpc/contribution_status` s anon ključem.

`pinka-link-preview` također radi bez sesije (limit po IP-u).

Što i dalje traži **pravi račun** (nepromijenjeno): favoriti u oblaku,
novčanik, pretplata, claim kanala, passkey, maksimir, brisanje računa,
sponzorski checkout (§5) i **svaka rezervacija mjesta** (grid kvadratić,
numerirano sjedalo) — `slot_keys` od gosta → `401 login_required`.
