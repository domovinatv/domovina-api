-- Provjera migracija 20260925160000 i 20260925170000 (Maksimir — javni glas i anonimni ZK dokaz).
--
-- Pokretanje nad lokalnim stackom (idempotentno — briše svoj trag na početku i kraju):
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20260925_maksimir_share_zk.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju "SVE PROVJERE PROŠLE".
-- SNARK se ovdje ne provjerava (to radi preglednik); dokaz ispod je pravi
-- Semaphore v4 dokaz, pa oblik, poruka i scope odgovaraju produkciji.
-- Cleanup BRIŠE CIJELI maksimir_log i maksimir_zk_log — samo lokalno!
\set ON_ERROR_STOP on
\timing off

-- Redoslijed je bitan: brisanje glasača briše člana ZK grupe, a okidač tada
-- zapisuje 'remove' u zapisnik — zato se zapisnici brišu tek na kraju.
-- Briše i trag web/scripts/zk-e2e.mjs (e2e-zk-*), jer se brojevi provjeravaju apsolutno.
create or replace function pg_temp.cleanup() returns void language sql as $$
  delete from domovina_ai.maksimir_shares;
  delete from domovina_ai.maksimir_voters where oib_hash like 'test-mzk-%' or oib_hash like 'e2e-zk-%';
  delete from auth.users where email like 'test-mzk-%@example.com' or email like 'e2e-zk-%@example.com';
  alter table domovina_ai.maksimir_log disable trigger user;
  delete from domovina_ai.maksimir_log;
  alter table domovina_ai.maksimir_log enable trigger user;
  alter table domovina_ai.maksimir_zk_log disable trigger user;
  delete from domovina_ai.maksimir_zk_log;
  alter table domovina_ai.maksimir_zk_log enable trigger user;
  update domovina_ai.maksimir_settings set opens_at = null, closes_at = '2027-12-31 23:59:59 Europe/Zagreb';
$$;
select pg_temp.cleanup();

create or replace function pg_temp.mk_user(p_id uuid, p_email text, p_hash text, p_first text, p_last text) returns void
language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          p_email, '', now(), now(), now(), '{"provider":"certilia"}'::jsonb, '{}'::jsonb);
  insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash, first_name, last_name)
  values (p_id, '\x00'::bytea, p_hash, p_first, p_last);
$$;

create or replace function pg_temp.expect_error(p_sql text, p_code text) returns void
language plpgsql as $$
begin
  execute p_sql;
  raise exception 'PAD — očekivao % za: %', p_code, p_sql;
exception when others then
  if sqlerrm <> p_code then
    raise exception 'PAD — očekivao %, dobio % za: %', p_code, sqlerrm, p_sql;
  end if;
end;
$$;

select pg_temp.mk_user('00000000-0000-4000-8000-0000000ee001', 'test-mzk-a@example.com', 'test-mzk-A', 'IVANA', 'HORVAT');
select pg_temp.mk_user('00000000-0000-4000-8000-0000000ee002', 'test-mzk-b@example.com', 'test-mzk-B', 'MARKO', 'KOVAČEVIĆ');
select pg_temp.mk_user('00000000-0000-4000-8000-0000000ee003', 'test-mzk-c@example.com', 'test-mzk-C', null, null);

-- pravi Semaphore v4 dokaz (poruka "glasao-sam", scope "maksimir-2026")
create temp table fx (proof jsonb);
insert into fx values ('{
 "merkleTreeDepth": 1,
 "merkleTreeRoot": "8421255540297742528422511282815627295641002497237025746317624583567460878734",
 "nullifier": "4258905585796011515188041119451567587823596460950646881156023647667681007508",
 "message": "46779715467123036996841617194389431189336537137425384514209209627004761014272",
 "scope": "49474226259215312994888701590181247581981161421217961257574660746611720716288",
 "points": ["5341041206134596016732912663209907231754333240789351155348848659275350588398",
  "19197484264856776292806891785048843229808393080146832590211784098991007173550",
  "19436494260971580893982120210599894854933373297491448337322832812485606566980",
  "442517318015159390408104231209119747902397756027778464498983521281308795528",
  "14383045438037031016806979259920978967800885351064096281228172638550053179965",
  "20755398007354274922503494963120767149444364534557650065172274159305137497584",
  "7849509420853552044811534055605369268653077536752412838788368120742068511192",
  "11974344171944789966328697266169487615276980920757939387010416978242676805278"]
}');

do $$
declare
  a constant uuid := '00000000-0000-4000-8000-0000000ee001';
  b constant uuid := '00000000-0000-4000-8000-0000000ee002';
  c constant uuid := '00000000-0000-4000-8000-0000000ee003';
  r jsonb; s jsonb; p jsonb;
  c1 text; c2 text;
  sid text; sid2 text; sidc text;
  l record; prev text := repeat('0', 64);
begin
  select code into c1 from domovina_ai.maksimir_entries where n = 1;
  select code into c2 from domovina_ai.maksimir_entries where n = 2;
  select proof into p from fx;

  -- 1. javno: traži listić
  perform domovina_ai._maksimir_accept_terms_for(a);
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_for(%L, %L)', a, 'full'), 'no_ballot');
  perform domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c1, 70, c2, 30));
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_for(%L, %L)', a, 'svi'), 'invalid_mode');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_for(%L, %L)', b, 'full'), 'terms_not_accepted');
  raise notice 'OK — javni prikaz traži privolu i predan listić; mode samo full|initial|anon';

  -- 2. javno: ime iz eOsobne u izabranom obliku
  r := domovina_ai._maksimir_set_public_for(a, 'full');
  sid := r->>'share_id';
  if r->>'public_mode' <> 'full' or sid !~ '^[a-z0-9]{12}$' then raise exception 'PAD — set_public %', r; end if;
  s := domovina_ai.maksimir_share(sid);
  if s->>'kind' <> 'public' or s->'card'->>'name' <> 'Ivana Horvat'
     or jsonb_array_length(s->'card'->'items') <> 2 or s->'card'->'items'->0->>'code' <> c1
     or (s->'card'->'items'->0->>'points')::int <> 70 or s->'card'->'receipt'->>'hash' is null then
    raise exception 'PAD — javna objava %', s;
  end if;
  r := domovina_ai._maksimir_set_public_for(a, 'initial');
  if r->>'share_id' <> sid then raise exception 'PAD — share_id se promijenio'; end if;
  if domovina_ai.maksimir_share(sid)->'card'->>'name' <> 'Ivana H.' then raise exception 'PAD — initial'; end if;
  perform domovina_ai._maksimir_set_public_for(a, 'anon');
  if domovina_ai.maksimir_share(sid)->'card'->>'name' is not null then raise exception 'PAD — anon ima ime'; end if;
  raise notice 'OK — javna objava: Ivana Horvat → Ivana H. → bez imena, ista poveznica, bodovi i potvrda iz lanca';

  -- 3. osoba bez imena u eOsobni
  perform domovina_ai._maksimir_accept_terms_for(c);
  perform domovina_ai._maksimir_cast_ballot_for(c, jsonb_build_object(c2, 100));
  r := domovina_ai._maksimir_set_public_for(c, 'full');
  sidc := r->>'share_id';
  if domovina_ai.maksimir_share(sidc)->'card'->>'name' is not null then raise exception 'PAD — ime bez imena'; end if;
  raise notice 'OK — bez imena u eOsobni javna objava je bez imena';

  -- 4. popis javnih listića + isključivanje
  r := domovina_ai.maksimir_public_ballots(10);
  if (r->>'count')::int <> 2 or jsonb_array_length(r->'ballots') <> 2 then raise exception 'PAD — public_ballots %', r; end if;
  perform domovina_ai._maksimir_set_public_for(c, null);
  if domovina_ai.maksimir_share(sidc)->'card' <> 'null'::jsonb or domovina_ai.maksimir_share(sidc)->>'kind' <> 'public' then
    raise exception 'PAD — isključena objava i dalje prikazuje listić';
  end if;
  if (domovina_ai.maksimir_public_ballots(10)->>'count')::int <> 1 then raise exception 'PAD — count nakon isključivanja'; end if;
  raise notice 'OK — popis javnih listića; isključivanje sakriva listić, poveznica ostaje';

  -- 5. povlačenje glasa sakriva javni listić
  perform domovina_ai._maksimir_cast_ballot_for(a, '{}'::jsonb);
  if domovina_ai.maksimir_share(sid)->'card' <> 'null'::jsonb then raise exception 'PAD — povučen glas je javan'; end if;
  perform domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c1, 100));
  if (domovina_ai.maksimir_share(sid)->'card'->'items'->0->>'points')::int <> 100 then raise exception 'PAD — ponovni glas'; end if;
  raise notice 'OK — povučen glas se ne prikazuje; novi glas se na istoj poveznici prikazuje odmah';

  -- 6. ZK: upis commitmenta
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', a, 'abc'), 'invalid_commitment');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', a,
    '21888242871839275222246405745257275088548364400416034343698204186575808495617'), 'invalid_commitment');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', b, '111'), 'terms_not_accepted');
  r := domovina_ai._maksimir_zk_register_for(a, '111');
  if (r->>'seq')::int <> 1 or (r->'head'->>'members')::int <> 1 then raise exception 'PAD — zk register %', r; end if;
  r := domovina_ai._maksimir_zk_register_for(a, '111');                        -- idempotentno
  if (r->'head'->>'seq')::int <> 1 then raise exception 'PAD — isti commitment je pisao'; end if;
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', c, '111'), 'commitment_taken');
  perform domovina_ai._maksimir_zk_register_for(c, '333');
  r := domovina_ai._maksimir_zk_register_for(a, '222');                        -- novi ključ: remove + add
  if (r->'head'->>'seq')::int <> 4 or (r->'head'->>'members')::int <> 2 then raise exception 'PAD — zamjena ključa %', r; end if;
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', c, '111'), 'commitment_taken');
  if domovina_ai._maksimir_ballot_of(a)->>'zk_commitment' <> '222' then raise exception 'PAD — my_ballot zk'; end if;
  raise notice 'OK — ZK upis: provjera polja BN254, idempotentno, jedinstveno, zamjena ključa = remove + add';

  -- 7. ZK: javni zapisnik grupe je lanac hasheva i nema vremena upisa
  r := domovina_ai.maksimir_zk_group();
  if jsonb_array_length(r->'log') <> 4 or r->'log'->0 ? 'created_at' then raise exception 'PAD — zk_group %', r; end if;
  for l in select * from domovina_ai.maksimir_zk_log order by seq loop
    if l.prev_hash <> prev or l.hash <> encode(sha256(convert_to(l.prev_hash || '|' || l.seq || '|' || l.op || '|' || l.commitment, 'UTF8')), 'hex') then
      raise exception 'PAD — zk lanac puca na seq %', l.seq;
    end if;
    prev := l.hash;
  end loop;
  if r->'head'->>'hash' <> prev then raise exception 'PAD — zk head'; end if;
  if (select string_agg(op || ':' || commitment, ',' order by seq) from domovina_ai.maksimir_zk_log) <> 'add:111,add:333,remove:111,add:222' then
    raise exception 'PAD — redoslijed zk zapisnika';
  end if;
  begin
    update domovina_ai.maksimir_zk_log set commitment = '999' where seq = 1;
    raise exception 'PAD — zk update prošao';
  exception when others then
    if sqlerrm <> 'maksimir_log is append-only' then raise; end if;
  end;
  raise notice 'OK — zapisnik grupe: lanac hasheva se ponovno izračuna, append-only, bez vremena upisa';

  -- 8. ZK: spremanje dokaza (anon)
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 1)', p - 'points'), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 1)', jsonb_set(p, '{message}', '"1"')), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 1)', jsonb_set(p, '{scope}', '"1"')), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 1)', jsonb_set(p, '{merkleTreeDepth}', '33')), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 99)', p), 'unknown_zk_seq');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 0)', p), 'unknown_zk_seq');
  sid2 := domovina_ai.maksimir_zk_share(p || '{"extra":"x"}'::jsonb, 4)->>'id';
  if domovina_ai.maksimir_zk_share(p, 4)->>'id' <> sid2 then raise exception 'PAD — isti nullifier, druga objava'; end if;
  s := domovina_ai.maksimir_share(sid2);
  if s->>'kind' <> 'zk' or (s->>'zk_seq')::int <> 4 or s->'proof' ? 'extra' or s->'proof'->>'nullifier' <> p->>'nullifier' then
    raise exception 'PAD — zk objava %', s;
  end if;
  if (select voter_id from domovina_ai.maksimir_shares where id = sid2) is not null then raise exception 'PAD — zk objava vezana uz glasača'; end if;
  if (domovina_ai.maksimir_public_ballots(10)->>'zk_shares')::int <> 1 then raise exception 'PAD — zk_shares'; end if;
  raise notice 'OK — ZK dokaz: oblik, fiksna poruka/scope, postojeći zk_seq, jedan po nullifieru, bez veze na glasača';

  -- 9. snapshot v2
  r := domovina_ai.maksimir_snapshot();
  if r->>'schema' <> 'maksimir-snapshot/2' or (r->'zk'->>'seq')::int <> 4 or r->'zk'->>'hash' <> prev
     or (r->>'public_voters')::int <> 1 or r->'head' is null then
    raise exception 'PAD — snapshot v2 %', r - 'results';
  end if;
  raise notice 'OK — snapshot v2: vrh lanca listića + vrh ZK grupe + broj javnih glasača';
end;
$$;

\echo '--- 9b. brisanje glasača zapisuje remove (migracija 20260925170000)'
do $$
declare r jsonb; n int;
begin
  delete from domovina_ai.maksimir_voters where oib_hash = 'test-mzk-C';        -- član '333'
  r := domovina_ai.maksimir_zk_head();
  select count(*) filter (where op = 'add') - count(*) filter (where op = 'remove') into n from domovina_ai.maksimir_zk_log;
  if (r->>'seq')::int <> 5 or (r->>'members')::int <> 1 or n <> 1
     or (select op || ':' || commitment from domovina_ai.maksimir_zk_log where seq = 5) <> 'remove:333' then
    raise exception 'PAD — brisanje glasača nije zapisalo remove %', r;
  end if;
  raise notice 'OK — brisanje glasača: remove u zapisniku, zapisnik i broj članova usklađeni';
end;
$$;

\echo '--- 10. javni RPC-evi kroz uloge'
begin;
set local role anon;
select 'anon share' as t, (domovina_ai.maksimir_zk_group()->'head'->>'seq') = '4' as ok;
do $$ begin
  perform domovina_ai.maksimir_set_public('full');
  raise exception 'PAD — anon smije set_public';
exception when insufficient_privilege then raise notice 'OK — anon ne smije set_public ni zk_register';
end $$;
do $$ begin
  perform * from domovina_ai.maksimir_zk_members;
  raise exception 'PAD — anon čita zk_members';
exception when insufficient_privilege then raise notice 'OK — anon ne čita zk_members, shares ni zk_log izravno';
end $$;
rollback;

begin;
select set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-0000000ee001', 'role', 'authenticated')::text, true);
set local role authenticated;
do $$ declare r jsonb; begin
  r := domovina_ai.maksimir_set_public('initial');
  if r->>'public_mode' <> 'initial' then raise exception 'PAD — authenticated set_public %', r; end if;
  r := domovina_ai.maksimir_zk_register('222');
  if (r->>'seq')::int <> 4 then raise exception 'PAD — authenticated zk_register %', r; end if;
  raise notice 'OK — authenticated: set_public i zk_register kroz javne RPC-eve';
end $$;
rollback;

select pg_temp.cleanup();
\echo 'SVE PROVJERE PROŠLE'
