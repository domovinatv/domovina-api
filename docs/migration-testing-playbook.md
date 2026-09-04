# Playbook: testiranje migracije prije produkcije

Kako smo testirali `20260722120000_pinka_slots.sql` (migracija koja dira
`mark_contribution_paid` i `tg_contribution_state` — funkcije kroz koje prolazi svaki
novac na platformi) **prije** nego je otišla na živu bazu. Postupak je generički;
ponovi ga za svaku migraciju koja dira novac, RLS ili postojeće funkcije.

## Zašto ne testirati na lokalnom Supabaseu

`supabase start` daje praznu bazu bez naše sheme. Migracija koja `create or replace`-a
postojeću funkciju mora se testirati **protiv stvarne strukture** — inače ne vidiš da si
naslijedio krivu (stariju) verziju funkcije ili razbio postojeći constraint.

## Postupak

### 1. Schema-only dump s produkcije (read-only, siguran)

```bash
./scripts/db-dump.sh --schemas public,pinka_finance,auth,extensions
```

### 2. Scratch Postgres

```bash
docker run -d --name mig-test -e POSTGRES_PASSWORD=test postgres:16-alpine
```

> Koristi **lokalno dostupan** image (`docker images postgres`). Povlačenje `postgres:15`
> s mreže je trajalo dulje od timeouta; `16-alpine` je bio već tu i posve dovoljan.

### 3. Pripremi bazu PRIJE restorea — inače restore tiho zakaže

`pg_dump --schema-only` **ne uključuje `CREATE EXTENSION`**. Bez toga tablice s
`citext` stupcima (npr. `campaigns.slug`) ne nastanu, a restore nastavi dalje — dobiješ
bazu koja *izgleda* popunjeno (13 tablica) ali fali baš ona koja ti treba.

```sql
create database t2;
\c t2
create schema if not exists extensions;
create extension citext;
create extension pg_trgm;
-- ★ pgcrypto MORA biti u schemi `extensions` — kod zove extensions.hmac(...)
--   (mark_contribution_paid hashira IBAN). Ako sleti u public, funkcija puca s
--   "function extensions.hmac(text, text, unknown) does not exist".
create extension pgcrypto with schema extensions;
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
do $$ begin create role service_role; exception when duplicate_object then null; end $$;
```

### 4. Restore i PROVJERI greške ispravno

```bash
docker exec mig-test psql -U postgres -d t2 -v ON_ERROR_STOP=0 -q -f /dump.sql 2>&1 \
  | grep -oE "ERROR:.*" | sed 's/"[^"]*"/"X"/g' | sort | uniq -c | sort -rn
```

> ⚠ **Zamka koja me koštala jednog kruga.** psql prefiksira poruke
> (`psql:/dump.sql:412: ERROR: …`), pa `grep "^ERROR"` **ne uhvati ništa** i restore
> izgleda čisto dok zapravo nije. Koristi `grep -oE "ERROR:.*"`.

Nakon pripreme iz koraka 3 ostaju samo `role "X" does not exist` (GRANT-ovi na role koje
lokalno ne trebaju) — to je prihvatljivo.

### 5. Primijeni migraciju točno kako to radi produkcija

```bash
docker exec mig-test psql -U postgres -d t2 -v ON_ERROR_STOP=1 -q --single-transaction -f /m.sql
```

`--single-transaction` + `ON_ERROR_STOP=1` zrcali `scripts/db-migrate.sh:105-117`.
Pokreni je **dvaput** — migracija mora biti idempotentna.

### 6. Fixture podaci: pazi na trigere

`insert into auth.users (...)` **automatski stvara `public.accounts` red** (trigger).
Ručni insert accounta pukne na `ix_one_personal_per_user`. Dohvati postojeći:

```sql
select id from public.accounts limit 1;
```

### 7. Funkcionalni testovi

Piši ih kao `select '<ime>' as test, <uvjet> as pass, <vrijednost> as got;` i pokreni
kroz `-f`. Za varijable koristi `\gset` — **`\gset` ne radi s `psql -c`**, mora ići
kroz datoteku.

Zbroji rezultat:

```bash
grep -cE '\| t +\|' out.txt   # prolazi
grep -cE '\| f +\|' out.txt   # pada
```

### 8. Test utrke — jedini pravi dokaz atomičnosti

Jednodretveni test **ne dokazuje ništa** o zaključavanju. Pokreni N stvarnih procesa:

```bash
for i in $(seq 1 12); do
  (docker exec mig-test psql -U postgres -d t2 -tAc "select … reserve …" \
     > q_$i.out 2> q_$i.err) &
done; wait
cat q_*.err | grep -oE "ERROR:.*" | sort | uniq -c
```

Očekuj **točno 1 uspjeh**, ostalo kontrolirana poslovna greška, i **nula
`deadlock detected`**.

> ⚠ Ne koristi `| tail -1` na izlazu — psql ERROR ima više redaka i `tail` ti ostavi
> `CONTEXT:` liniju, pa izgleda kao da greška nije ona koju očekuješ. Preusmjeri
> stdout i stderr u zasebne datoteke.

## Provjera nakon deploya bez pisanja podataka

Da dokažeš da je PostgREST pokupio novu signaturu, **ne moraš kreirati red**. Pozovi RPC
s anon ključem i gledaj kod greške:

| kod | značenje |
|---|---|
| `42501 permission denied` | ✅ funkcija **postoji i resolvira se**, anon ispravno odbijen |
| `PGRST202` | ❌ nema takve funkcije — schema cache nije reloadan ili signatura ne odgovara |
| `PGRST203` | ❌ **dvosmisleno** — stari overload nije dropan |

```bash
curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/<fn>" \
  -H "apikey: $SUPABASE_ANON_KEY" -H "Content-Profile: pinka_finance" \
  -d '{"p_...":"..."}'
```

Testiraj **oba** skupa parametara: novi (s novim argumentom) i stari (kakav živi
frontend trenutno šalje) — drugi dokazuje unatražnu kompatibilnost.

## Alat: `scripts/db-psql.sh` ima dvije zamke

1. **`-c "..."` se re-parsira na udaljenom shellu.** `remote_psql_exec` prosljeđuje
   `$*` **nequotirano** (`scripts/lib/db-env.sh:73-77`), pa zagrade, `*` i `%` puknu
   (`zsh: no matches found: count(*)`).
2. **`--stdin` ne proslijedi stdin** kroz ssh wrapper — tiho vrati prazno.

Za išta složenije od trivijalnog `select` idi direktno:

```bash
set -a; . ./.local-secrets.env; set +a
C=$(ssh -i "$COOLIFY_SSH_KEY" "$COOLIFY_SSH_HOST" \
     "docker ps --format '{{.Names}}' | grep '^supabase-db-' | head -1")
ssh -i "$COOLIFY_SSH_KEY" "$COOLIFY_SSH_HOST" \
  "docker exec -i $C psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -q" < verify.sql
```

## Postgres zamke naučene usput

- **`::integer` ZAOKRUŽUJE, ne krati.** `(3 / 6.0)::integer` = `1`, ne `0`. Za
  raspoređivanje u pojaseve/prstenove koristi `floor(x::numeric / band)::integer`.
- **Partial unique index ne prima `now()`** (nije `IMMUTABLE`). Vremenski uvjetovanu
  jedinstvenost rješavaj u `WHERE` klauzulama upita i u viewu, ne u indeksu.
- **Defaultirani parametar stvara NOVI overload.** `create or replace` ne zamjenjuje
  funkciju s drugim brojem argumenata — moraš `drop function if exists <točna stara
  signatura>` u istoj migraciji, inače PostgREST baca `PGRST203`.
- **Sortiraj ključeve prije zaključavanja više redaka.** Dvije transakcije koje
  zaključavaju `{A,B}` i `{B,A}` deadlockaju. `array_agg(k order by k)` to isključuje;
  bug se inače pojavi tek pod opterećenjem, u produkciji.

## Backup prije migracije

`scripts/db-migrate.sh:87-91` backupira **samo `public` i `domovina_ai`**.
`pinka_finance` (novac!) **nije u automatskom backupu**:

```bash
./scripts/db-dump.sh --schemas pinka_finance --data
```

Provjeri da backup stvarno ima podatke, ne samo strukturu:

```bash
grep -c "^COPY pinka_finance" backups/<file>.sql
```

---

## Provjera ponašanja, ne samo primjene (2026-09-03)

`supabase db reset` dokazuje da migracija **prolazi**. Ne dokazuje da radi ono
zbog čega je napisana. Za migracije `20260903120000` (rail gate) i
`20260903120100` (rotacija QR tokena) uveden je obrazac koji vrijedi ponoviti:
uz migraciju ide skripta u `supabase/tests/` koja tvrdnje provjerava nad pravom
shemom i **pada glasno**.

```bash
supabase db reset --no-seed        # sve migracije od nule
psql "$LOCAL" -f supabase/tests/20260903_rail_gate_i_rotacija.sql
# očekivano: NOTICE redci "OK — …" i na kraju "SVE PROVJERE PROŠLE"
```

Četiri stvari koje su se pokazale nužnima da skripta bude korisna:

1. **Skripta briše svoj trag na početku, ne na kraju.** Prvi run je prošao, drugi
   pao: zadnji korak je ostavio `stripe_charges_enabled = true`, pa je test „bez
   raila" krenuo s uključenim railom. Čišćenje na kraju ne pomaže ako skripta
   pukne u sredini.
2. **Negativni testovi moraju provjeravati KOJU grešku dobivaju.** `exception when
   others` koji samo kaže „nešto je puklo" prolazi i kad je puklo iz krivog
   razloga — u ovom slučaju je RLS odbio insert prije nego je trigger uopće
   došao na red, pa test nije dokazivao ništa. Lijek: `if sqlerrm not like
   '%očekivani_kod%' then raise exception 'PAO TEST: kriva greška: %', sqlerrm`.
3. **Kad RLS stoji na putu, testiraj funkciju izravno.** Pravilo „donacije i
   dalje traže Safe" nije bilo moguće dokazati kroz `insert into campaigns`
   (RLS insert policy traži KYC). Provjera je zato nad `event_rail_ready(...)`
   za sve četiri kombinacije tipa i raila — to je funkcija koja pravilo i
   sadrži, trigger je samo zove.
4. **Idempotentnost se provjerava ponovnim `psql -f` nad samom migracijom**, ne
   samo drugim `db reset`-om: `create or replace` + `if not exists` moraju dati
   nula grešaka na već migriranoj bazi.

Zamka iz iste sesije: `pinka_finance.contributions.destination_address` je
`not null`, a `campaign_type` enum nema `'standard'` (`donation`, `crowdfund`,
`tokenization`, `tickets`, `realestate`). Oboje se otkriva tek pri pisanju
testnih redaka, ne pri čitanju sheme.

Vezano: [`docs/events-ticketing-curl-scenario.md`](events-ticketing-curl-scenario.md),
`../domovina-ulaznice/docs/2026-09-03-implementacija-p0-p1.md`.
