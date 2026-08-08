# Izborni dan (glasanje o sljedećem kanalu) — curl + SQL test scenarij

> Dizajn: `domovina.ai/docs/plans/2026-08-08-glasanje-o-kanalima.md`
> (§4 integritet, §5 model, §5.1 RLS, §5.2 ugovor RPC-eva, §6.3 streak,
> §6.4 rubni slučajevi, §7 rangiranje i zatvaranje kola).
> Migracije: `20260808120000_channel_voting.sql`,
> `20260808120100_channel_voting_rls.sql`,
> `20260808120200_channel_voting_rpcs.sql`.
>
> Scenarij dokazuje: (a) javna ljestvica radi bez prijave, (b) verificiran
> korisnik glasa jednom dnevno i drugi glas istog dana pada na
> `already_voted_today` uz tally koji se inkrementira **točno jednom**,
> (c) `voters`/`votes` su nedostupni klijentu, (d) svih **10 rubnih slučajeva
> iz §6.4**, (e) lijeno zatvaranje kola s kvorumom i carry-overom.

## 0. Okruženje

```bash
export API=http://127.0.0.1:55321
export PUB=$(./scripts/dev-local.sh status -o env | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
export SEC=$(./scripts/dev-local.sh status -o env | sed -n 's/^SERVICE_ROLE_KEY="\(.*\)"$/\1/p')
alias lpsql='psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres"'
```

(Novi `sb_publishable_…` / `sb_secret_…` ključevi iz `supabase status` rade
jednako — legacy JWT ključevi su gore samo zato što ih `-o env` ispisuje.)

Sve RPC-eve zove se s **`Content-Profile: domovina_ai`** (i `Accept-Profile`
za tablične `GET`-ove) jer feature živi u `domovina_ai` shemi, ne u `public`.
Flutter to radi kroz `client.schema('domovina_ai').rpc(...)`.

**Semantika grešaka**: `raise exception '<kod>'` izlazi kroz PostgREST kao
**HTTP 400** s tijelom `{"code":"P0001","message":"<kod>"}`. Klijent parsira
`message`. Nedostatak `execute` prava daje **401/403** s `code: 42501`.

```bash
./scripts/dev-local.sh db reset     # migracije se primjenjuju od nule
```

## 1. Priprema — kandidati, kolo, verificiran korisnik

Registar u produkciju puni `fetch.domovina.tv/sync_voting_candidates.mjs`;
za test je dovoljno četiri reda.

```sql
-- lpsql
insert into domovina_ai.vote_candidates
  (slug, display_name, youtube_url, tags, quality_score, tier, source_type)
values
  ('podcast-inkubator','Podcast Inkubator','https://youtube.com/@inkubator','{talk-show,society}',100,1,'channel'),
  ('projekt-velebit',  'Projekt Velebit',  'https://youtube.com/@velebit',  '{political,history}', 96,1,'channel'),
  ('rebootcast',       'Rebootcast',       'https://youtube.com/@rebootcast','{gaming}',            91,1,'channel'),
  ('mjesto-zlocina',   'Mjesto zločina',   'https://youtube.com/@mzlocina', '{true-crime}',        84,1,'channel');
```

Kolo se otvara **lijeno** — prvi poziv `current_round()` ga stvori. Za scenarij
ga fiksiramo da pokriva današnji dan:

```sql
insert into domovina_ai.vote_rounds (starts_on, ends_on)
values (domovina_ai.vote_today(), domovina_ai.vote_today() + 13);
```

Verificiran korisnik (u produkciji red u `public.identity_verifications` piše
`certilia` edge funkcija; `oib_hash` je HMAC i za RPC-eve je neproziran ključ):

```bash
U=$(curl -s -X POST "$API/auth/v1/admin/users" \
  -H "apikey: $SEC" -H "authorization: Bearer $SEC" -H 'content-type: application/json' \
  -d '{"email":"glasac@izbor.test","password":"IzborniDan2026!","email_confirm":true}')
export UID_=$(echo "$U" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
```

```sql
-- lpsql
insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash, first_name, last_name)
values ('<UID_>'::uuid, '\x00'::bytea, 'oibhash-glasac', 'Ana', 'Anić');
```

```bash
export TOK=$(curl -s -X POST "$API/auth/v1/token?grant_type=password" \
  -H "apikey: $PUB" -H 'content-type: application/json' \
  -d '{"email":"glasac@izbor.test","password":"IzborniDan2026!"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

auth() { curl -s -X POST "$API/rest/v1/rpc/$1" \
  -H "apikey: $PUB" -H "authorization: Bearer $TOK" \
  -H 'Content-Profile: domovina_ai' -H 'content-type: application/json' -d "${2:-{\}}"; }
anon() { curl -s -X POST "$API/rest/v1/rpc/$1" \
  -H "apikey: $PUB" -H 'Content-Profile: domovina_ai' \
  -H 'Accept-Profile: domovina_ai' -H 'content-type: application/json' -d "${2:-{\}}"; }
```

## 2. Javna ljestvica — bez ijedne prijave (§11.2)

```bash
anon current_round
# {"id":8,"today":"2026-08-08","status":"open","voters":0,"ends_on":"2026-08-21",
#  "days_left":13,"starts_on":"2026-08-08","quorum_net":10,"total_votes":0,"quorum_total":25}

anon round_leaderboard '{"p_sort":"leaderboard","p_limit":3}'
# [{"slug":"podcast-inkubator",…,"up":0,"down":0,"net":0,"rank":1}, …]
```

Sort chipovi i tag filter iz §3.1 (rep liste dobiva izlaganje):

```bash
anon round_leaderboard '{"p_sort":"random","p_limit":5}'        # determinističko sjeme = kolo + dan
anon round_leaderboard '{"p_sort":"least_votes","p_limit":5}'
anon round_leaderboard '{"p_tag":"true-crime"}'
anon round_leaderboard '{"p_query":"velebit"}'
anon round_leaderboard '{"p_sort":"foo"}'   # → {"code":"P0001","message":"invalid_sort"}
```

`rank` je **uvijek** globalni poredak ljestvice (§7.1 tie-break:
`net desc → up desc → quality_score desc → slug asc`), neovisan o `p_sort` —
chip mijenja redoslijed prikaza, ne broj pored imena. `random` je sjemenovan
parom (kolo, dan) da paginacija ne ponavlja ni ne preskače kandidate.

## 3. Glasanje — sretan put i „drugi glas isti dan"

```bash
auth my_voting_state
# {"verified":true,"consented":false,"voted_today":false,…,"streak":0,"flags":0}

auth cast_vote '{"p_slug":"podcast-inkubator","p_direction":1}'
# → {"code":"P0001","message":"terms_not_accepted"}      (§4.3 privola pri prvom glasu)

auth accept_voting_terms                                  # HTTP 204

auth cast_vote '{"p_slug":"podcast-inkubator","p_direction":1}'
# {"flags":1,"streak":1,"longest_streak":1,"voted_today":true,
#  "today_vote":{"slug":"podcast-inkubator","direction":1},
#  "flags_burned":0,"streak_saved":false,"round":{"id":8,"ends_on":…,"days_left":13}}

auth cast_vote '{"p_slug":"projekt-velebit","p_direction":-1}'
# → HTTP 400 {"code":"P0001","message":"already_voted_today"}

curl -s "$API/rest/v1/vote_tallies?select=slug,up,down,net" \
  -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'
# [{"slug":"podcast-inkubator","up":1,"down":0,"net":1}]   ← inkrementiran TOČNO jednom

auth cast_vote '{"p_slug":"ne-postoji","p_direction":1}'
# → {"code":"P0001","message":"candidate_not_available"}
```

**Kriterij prihvaćanja iz T1 je time zadovoljen**: verificiran korisnik glasa →
drugi glas isti dan pada na `already_voted_today` → tally se inkrementira točno
jednom.

### 3.1 Race / dupli tap — dvije istovremene transakcije

`cast_vote` zaključa red glasača (`select … for update`) prije provjere dana, a
`unique (voter_id, vote_day)` je zadnji čuvar. Deterministična reprodukcija:

```bash
P="postgresql://postgres:postgres@127.0.0.1:55322/postgres"
DAY=$(psql "$P" -At -c "select domovina_ai.vote_today()")

# A drži lock 3 s, pa commita
( psql "$P" -At -c "begin;
    select domovina_ai._cast_vote_on('$UID_'::uuid,'rebootcast',1,'$DAY'::date) is not null;
    select pg_sleep(3); commit;" | sed 's/^/A: /' ) &
sleep 1
# B blokira na FOR UPDATE, pa vidi već upisan glas
( psql "$P" -At -c "select domovina_ai._cast_vote_on('$UID_'::uuid,'rebootcast',1,'$DAY'::date)" \
    2>&1 | sed 's/^/B: /' ) &
wait
```

Očekivano: `A: t`, `B: ERROR: already_voted_today`, a `votes` i `vote_tallies`
imaju točno **jedan** zapis. B-jeva transakcija se cijela rollbacka — zato
inkrement tallyja ide **nakon** inserta u `votes`, nikad prije.

## 4. RLS — što klijent smije, a što ne (§5.1)

```bash
# javno čitljivo (rezultati su javni, §4.3)
curl -s "$API/rest/v1/vote_candidates?select=slug" -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'
curl -s "$API/rest/v1/vote_rounds?select=id,status" -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'
curl -s "$API/rest/v1/vote_tallies?select=slug,net"  -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'

# NIKAD dostupno klijentu — pojedinačni glas može otkriti uvjerenje (GDPR čl. 9, §4.3)
curl -s "$API/rest/v1/votes?select=*"  -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'
# {"code":"42501","message":"permission denied for table votes"}
curl -s "$API/rest/v1/voters?select=*" -H "apikey: $PUB" -H 'Accept-Profile: domovina_ai'
# {"code":"42501","message":"permission denied for table voters"}
```

Isto kroz `psql` za obje klijentske role (uključujući interne wrappere s
dan-parametrom, koji su service_role-only):

```sql
-- lpsql
set role anon;
select count(*) from domovina_ai.votes;                          -- permission denied
select count(*) from domovina_ai.voters;                         -- permission denied
select count(*) from domovina_ai.candidate_follows;              -- permission denied
select domovina_ai.my_voting_state();                            -- permission denied for function
select domovina_ai.cast_vote('projekt-velebit', 1);              -- permission denied for function
select domovina_ai._cast_vote_on(gen_random_uuid(),'x',1,current_date);  -- permission denied
select domovina_ai._ensure_round(current_date);                  -- permission denied
select domovina_ai.current_round();                              -- ✅ prolazi
select * from domovina_ai.round_leaderboard();                   -- ✅ prolazi
reset role;

set role authenticated;
select count(*) from domovina_ai.votes;                          -- permission denied
select domovina_ai._voting_state_of(gen_random_uuid(), current_date);    -- permission denied
select domovina_ai.my_voting_state() -> 'verified';              -- ✅ false (bez JWT-a auth.uid() je null)
reset role;
```

`candidate_follows` (⚑ Prati; UI dolazi u kasnijem krugu) ima klasične
own-row policyje:

```bash
FOL=(-H "apikey: $PUB" -H "authorization: Bearer $TOK" -H 'Content-Profile: domovina_ai'
     -H 'Accept-Profile: domovina_ai' -H 'content-type: application/json')
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/rest/v1/candidate_follows" "${FOL[@]}" \
  -d "{\"user_id\":\"$UID_\",\"slug\":\"rebootcast\"}"                       # 201
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/rest/v1/candidate_follows" "${FOL[@]}" \
  -d '{"user_id":"00000000-0000-4000-8000-000000000001","slug":"rebootcast"}' # 403
curl -s -X PATCH "$API/rest/v1/candidate_follows?slug=eq.rebootcast" "${FOL[@]}" -d '{"slug":"x"}'
# {"code":"42501","message":"permission denied for table candidate_follows"}  ← update namjerno nema grant
```

## 5. Rubni slučajevi §6.4 — SQL scenarij

Dan se **NE** simulira mijenjanjem `now()`. Interni wrapperi primaju izborni dan
kao parametar i dostupni su samo `service_role`-u:

| wrapper | javni pandan |
|---|---|
| `_cast_vote_on(user_id, slug, direction, day)` | `cast_vote(p_slug, p_direction)` |
| `_voting_state_of(user_id, day)` | `my_voting_state()` |
| `_ensure_round(day)` | `current_round()` |
| `_accept_voting_terms_for(user_id)` | `accept_voting_terms()` |

Javni RPC-evi dan računaju sami preko `domovina_ai.vote_today()`
(`(now() at time zone 'Europe/Zagreb')::date`) — **klijent datum nikad ne šalje**.

### Priprema

```sql
-- lpsql
delete from domovina_ai.votes;
delete from domovina_ai.vote_tallies;
update domovina_ai.vote_rounds set winner_slug = null;
delete from domovina_ai.voters;
delete from domovina_ai.vote_rounds;
delete from auth.users where email like '%@izbor.test';
update domovina_ai.vote_candidates set status = 'candidate';

insert into domovina_ai.vote_rounds (starts_on, ends_on) values ('2026-08-01', '2026-08-14');

create or replace function pg_temp.mk_voter(p_tag text) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
          p_tag || '@izbor.test', 'x', now(), now(), now());
  insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash, first_name, last_name)
  values (v_id, '\x00'::bytea, 'oibhash-' || p_tag, 'Test', p_tag);
  perform domovina_ai._accept_voting_terms_for(v_id);
  return v_id;
end $$;

create or replace function pg_temp.stanje(p_user uuid) returns text
language sql as $$
  select format('streak=%s longest=%s flags=%s last=%s total=%s',
                v.current_streak, v.longest_streak, v.flags, v.last_vote_day, v.total_votes)
    from domovina_ai.voters v
    join public.identity_verifications iv on iv.oib_hash = v.oib_hash
   where iv.user_id = p_user;
$$;
```

### 1 — Prvi glas ikad → niz 1, zastavice 1

```sql
select set_config('t.u1', pg_temp.mk_voter('c1')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u1')::uuid, 'podcast-inkubator', 1, '2026-08-01');
select pg_temp.stanje(current_setting('t.u1')::uuid);
-- streak=1 longest=1 flags=1 last=2026-08-01 total=1
```

### 2 — Glas u 23:59:59 pa u 00:00:01 → dva izborna dana, niz +2

```sql
select set_config('t.u2', pg_temp.mk_voter('c2')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u2')::uuid,'projekt-velebit',1,'2026-08-01') -> 'streak';  -- 1
select domovina_ai._cast_vote_on(current_setting('t.u2')::uuid,'projekt-velebit',1,'2026-08-02') -> 'streak';  -- 2
-- streak=2 longest=2 flags=2 last=2026-08-02 total=2
```

### 3 — Dupli tap → `already_voted_today`, tally se ne duplira

```sql
select set_config('t.u3', pg_temp.mk_voter('c3')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u3')::uuid,'rebootcast',1,'2026-08-01') -> 'streak';
do $$ begin
  perform domovina_ai._cast_vote_on(current_setting('t.u3')::uuid,'rebootcast',1,'2026-08-01');
  raise exception 'FAIL: drugi glas je prošao';
exception when others then
  if sqlerrm <> 'already_voted_today' then raise; end if;
  raise notice 'OK: %', sqlerrm;
end $$;
select up, down, net from domovina_ai.vote_tallies where slug = 'rebootcast';   -- 1 | 0 | 1
```

Za pravi paralelni race vidi §3.1.

### 4 — Propušten 1 dan, 1 zastavica → potrošena, niz teče

```sql
select set_config('t.u4', pg_temp.mk_voter('c4')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u4')::uuid,'rebootcast',1,'2026-08-01') -> 'flags';  -- 1
select domovina_ai._cast_vote_on(current_setting('t.u4')::uuid,'rebootcast',1,'2026-08-03');
-- "flags_burned":1, "streak_saved":true, "streak":2
select pg_temp.stanje(current_setting('t.u4')::uuid);
-- streak=2 longest=2 flags=1 last=2026-08-03 total=2      ← zastavica potrošena pa +1 za dolazak
```

### 5 — Propuštena 2 dana, 2 zastavice → obje potrošene, niz nastavljen

```sql
select set_config('t.u5', pg_temp.mk_voter('c5')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u5')::uuid,'mjesto-zlocina',1,'2026-08-01') -> 'flags';  -- 1
select domovina_ai._cast_vote_on(current_setting('t.u5')::uuid,'mjesto-zlocina',1,'2026-08-02') -> 'flags';  -- 2
select domovina_ai._cast_vote_on(current_setting('t.u5')::uuid,'mjesto-zlocina',1,'2026-08-05');
-- "flags_burned":2, "streak_saved":true, "streak":3, "flags":1
select pg_temp.stanje(current_setting('t.u5')::uuid);
-- streak=3 longest=3 flags=1 last=2026-08-05 total=3
```

### 6 — Propuštena 3 dana, 2 zastavice → niz = 1, zastavice OSTAJU (strop 2)

Namjerno odstupanje od Brilliant-a (§2.1 / §6.3): zastavice se troše
**sve-ili-ništa**, pa propust ne bude dvostruko kažnjen.

```sql
select set_config('t.u6', pg_temp.mk_voter('c6')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u6')::uuid,'mjesto-zlocina',1,'2026-08-01') -> 'flags';  -- 1
select domovina_ai._cast_vote_on(current_setting('t.u6')::uuid,'mjesto-zlocina',1,'2026-08-02') -> 'flags';  -- 2
select domovina_ai._cast_vote_on(current_setting('t.u6')::uuid,'mjesto-zlocina',1,'2026-08-06');
-- "flags_burned":0, "streak_saved":false, "streak":1, "flags":2
select pg_temp.stanje(current_setting('t.u6')::uuid);
-- streak=1 longest=2 flags=2 last=2026-08-06 total=3      ← longest ostaje zauvijek
```

### 7 — Zastavice na stropu, glasa se → ostaje 2, ne 3

```sql
select set_config('t.u7', pg_temp.mk_voter('c7')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u7')::uuid,'podcast-inkubator',1,'2026-08-01') -> 'flags';  -- 1
select domovina_ai._cast_vote_on(current_setting('t.u7')::uuid,'podcast-inkubator',1,'2026-08-02') -> 'flags';  -- 2
select domovina_ai._cast_vote_on(current_setting('t.u7')::uuid,'podcast-inkubator',1,'2026-08-03') -> 'flags';  -- 2
-- streak=3 longest=3 flags=2 last=2026-08-03 total=3
```

### 8 — Brisanje računa → nova verifikacija istog OIB-a → isti `voter_id`

**Ovo je rupa iz §4.1 i razlog postojanja tablice `voters`.**

```sql
select id, current_streak, flags from domovina_ai.voters where oib_hash = 'oibhash-c7';
--  a43e… | 3 | 2

delete from auth.users where id = current_setting('t.u7')::uuid;   -- cascade briše identity_verifications
select id, user_id, current_streak, flags from domovina_ai.voters where oib_hash = 'oibhash-c7';
--  a43e… | NULL | 3 | 2      ← red preživio, user_id je SET NULL (ne cascade)

-- ista osoba, novi račun, isti OIB:
select set_config('t.u8', gen_random_uuid()::text, false);
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', current_setting('t.u8')::uuid,
        'authenticated','authenticated','c7-novi@izbor.test','x', now(), now(), now());
insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash, first_name, last_name)
values (current_setting('t.u8')::uuid, '\x00'::bytea, 'oibhash-c7', 'Test', 'c7');

select domovina_ai._cast_vote_on(current_setting('t.u8')::uuid,'podcast-inkubator',1,'2026-08-04');
select id, user_id, current_streak, flags from domovina_ai.voters where oib_hash = 'oibhash-c7';
--  a43e… (ISTI voter_id) | 25df… (novi user) | 4 | 2
```

Da je `voters.user_id` bio `on delete cascade`, ista bi osoba ovime dobila
**drugi glas isti dan**. Ne mijenjati u cascade.

### 9 — Glas na dan kad kolo završava → ulazi u kolo koje se zatvara

```sql
select set_config('t.u9', pg_temp.mk_voter('c9')::text, false);
select domovina_ai._cast_vote_on(current_setting('t.u9')::uuid,'projekt-velebit',1,'2026-08-14') -> 'round';
-- {"id":…, "ends_on":"2026-08-14", "days_left":0, "starts_on":"2026-08-01"}
select v.vote_day, v.round_id, r.ends_on, r.status
  from domovina_ai.votes v join domovina_ai.vote_rounds r on r.id = v.round_id
 where v.vote_day = '2026-08-14';
-- 2026-08-14 | <kolo 1> | 2026-08-14 | open      ← `ends_on` je UKLJUČIV
```

### 10 — Kandidat proglašen pobjednikom usred kola → `candidate_not_available`

```sql
select set_config('t.u10', pg_temp.mk_voter('c10')::text, false);
update domovina_ai.vote_candidates set status = 'winner' where slug = 'rebootcast';
do $$ begin
  perform domovina_ai._cast_vote_on(current_setting('t.u10')::uuid,'rebootcast',1,'2026-08-05');
  raise exception 'FAIL: glas za pobjednika je prošao';
exception when others then
  if sqlerrm <> 'candidate_not_available' then raise; end if;
  raise notice 'OK: %', sqlerrm;
end $$;
update domovina_ai.vote_candidates set status = 'candidate' where slug = 'rebootcast';
```

Isto vrijedi za `withdrawn` / `onboarding` / `onboarded` — glasa se samo za
`status = 'candidate'`.

### Ostale greške iz ugovora §5.2

```sql
-- not_verified (nema reda u identity_verifications)
do $$ begin
  perform domovina_ai._cast_vote_on(gen_random_uuid(),'podcast-inkubator',1,'2026-08-05');
  raise exception 'FAIL';
exception when others then
  if sqlerrm <> 'not_verified' then raise; end if; raise notice 'OK: %', sqlerrm;
end $$;

-- terms_not_accepted → nakon accept_voting_terms glas prolazi (vidi §3)
-- invalid_direction (jedini dopušteni su -1 i 1)
do $$ begin
  perform domovina_ai._cast_vote_on(current_setting('t.u1')::uuid,'podcast-inkubator',0,'2026-08-07');
  raise exception 'FAIL';
exception when others then
  if sqlerrm <> 'invalid_direction' then raise; end if; raise notice 'OK: %', sqlerrm;
end $$;
```

### Projekcija bez upisa (`my_voting_state`, §6.3)

`u1` je zadnji put glasao 2026-08-01 i ima 1 zastavicu:

```sql
select domovina_ai._voting_state_of(current_setting('t.u1')::uuid, '2026-08-01');
--  voted_today=true,  streak=1, streak_at_risk=false, flags_that_will_burn=0
select domovina_ai._voting_state_of(current_setting('t.u1')::uuid, '2026-08-02');
--  voted_today=false, streak=1, streak_at_risk=false, flags_that_will_burn=0
select domovina_ai._voting_state_of(current_setting('t.u1')::uuid, '2026-08-03');
--  voted_today=false, streak=1, streak_at_risk=TRUE,  flags_that_will_burn=1   ← zadnji dan obrane
select domovina_ai._voting_state_of(current_setting('t.u1')::uuid, '2026-08-05');
--  voted_today=false, streak=0 (već pukao), streak_at_risk=false, flags_that_will_burn=0
select domovina_ai._voting_state_of(null, '2026-08-05');
--  verified=false, sve nule — gost vidi samo `round`
```

Funkcija je `stable` i ne dira ni jedan red — provjerivo s
`select count(*) from domovina_ai.voters` prije i poslije.

## 6. Zatvaranje kola — lijeno, s kvorumom i carry-overom (§7)

Bez crona: prvi poziv `current_round()` nakon isteka kola sve odradi u jednoj
transakciji pod `pg_advisory_xact_lock`.

```sql
-- kvorum default: net >= 10 i up+down >= 25 → s malo glasova NITKO ne prolazi
select domovina_ai._ensure_round('2026-08-15');
select id, starts_on, ends_on, status, winner_slug, no_winner_reason
  from domovina_ai.vote_rounds order by id;
-- 1 | 2026-08-01 | 2026-08-14 | closed |      | quorum_not_met
-- 2 | 2026-08-15 | 2026-08-28 | open   |      |

select round_id, slug, up, down, net from domovina_ai.vote_tallies order by round_id, slug;
-- tally je PRENESEN u kolo 2 (carry-over) — trud glasača se ne baca
```

Sad s dostižnim kvorumom:

```sql
update domovina_ai.vote_rounds set quorum_net = 1, quorum_total = 1 where status = 'open';
select domovina_ai._ensure_round('2026-09-01');
select id, starts_on, ends_on, status, winner_slug, no_winner_reason
  from domovina_ai.vote_rounds order by id;
-- 2 | 2026-08-15 | 2026-08-28 | closed | podcast-inkubator |
-- 3 | 2026-08-29 | 2026-09-11 | open   |                   |

select slug, status from domovina_ai.vote_candidates order by slug;
-- podcast-inkubator | winner        ← ispada iz bazena, cast_vote ga odbija

select round_id, count(*) from domovina_ai.vote_tallies group by round_id;
-- kolo 3 nema redova → ljestvica je resetirana (carry-over ide SAMO bez pobjednika)
```

Zadnji `_ensure_round('2026-09-01')` je preskočio i kolo koje bi završilo prije
tog datuma — petlja rollovera vrti dok otvoreno kolo ne pokrije traženi dan, pa
povratak nakon višetjednog izbivanja ne ostavlja „rupu" među kolima.

`quorum_net` / `quorum_total` su kolone na `vote_rounds` — podižu se `update`-om
kad volumen naraste, **bez migracije** (§7.2).

## 7. Sažetak očekivanih rezultata

| Provjera | Očekivano |
|---|---|
| `supabase db reset` | prolazi bez greške |
| anon `current_round` / `round_leaderboard` | 200, ljestvica vidljiva bez prijave |
| anon/authenticated `select * from votes` / `voters` | `42501 permission denied` |
| anon `my_voting_state` / `cast_vote` | `42501 permission denied for function` |
| bilo tko `_cast_vote_on` / `_ensure_round` / `_voting_state_of` | `42501` (service_role only) |
| prvi `cast_vote` bez privole | `terms_not_accepted` |
| `cast_vote` × 2 isti dan | drugi → `already_voted_today`, tally +1 ukupno |
| paralelni `cast_vote` (§3.1) | jedan uspije, drugi `already_voted_today`, tally +1 |
| §6.4 slučajevi 1–10 | svi kako je gore ispisano |
| kolo bez kvoruma | `closed` + `quorum_not_met` + carry-over tallyja |
| kolo s kvorumom | `winner_slug` postavljen, kandidat `status='winner'`, tally resetiran |

**Ne pokretati `supabase db push` ni deploy na Coolify iz ovog scenarija** —
migracije se u produkciju vode zasebno (`docs/deployment-runbook.md`).
