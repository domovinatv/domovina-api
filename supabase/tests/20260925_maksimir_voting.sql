-- Provjera migracije 20260925120000 (Stadion Maksimir — 100 bodova po osobi).
--
-- Pokretanje nad lokalnim stackom (idempotentno — briše svoj trag na početku i kraju):
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20260925_maksimir_voting.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju "SVE PROVJERE PROŠLE".
-- Pretpostavka: lokalna baza nema drugih maksimir listića (rezultati se
-- provjeravaju apsolutno). Cleanup BRIŠE CIJELI maksimir_log (append-only
-- trigger se privremeno gasi s disable trigger) — samo lokalno!
\set ON_ERROR_STOP on
\timing off

create or replace function pg_temp.cleanup() returns void language sql as $$
  alter table domovina_ai.maksimir_log disable trigger user;
  delete from domovina_ai.maksimir_log;
  alter table domovina_ai.maksimir_log enable trigger user;
  delete from domovina_ai.maksimir_voters where oib_hash like 'test-maksimir-%';
  delete from auth.users where email like 'test-maksimir-%@example.com';
  update domovina_ai.maksimir_settings set opens_at = null, closes_at = '2027-12-31 23:59:59 Europe/Zagreb';
$$;
select pg_temp.cleanup();

-- korisnik + KYC red (oib_hash je sve što RPC-evi gledaju)
create or replace function pg_temp.mk_user(p_id uuid, p_email text, p_hash text) returns void
language sql as $$
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data)
  values (p_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          p_email, '', now(), now(), now(), '{"provider":"certilia"}'::jsonb, '{}'::jsonb);
  insert into public.identity_verifications (user_id, oib_ciphertext, oib_hash)
  values (p_id, '\x00'::bytea, p_hash);
$$;

-- poziv javnog RPC-a kao prijavljeni korisnik (auth.uid() iz JWT claimsa)
create or replace function pg_temp.as_user(p_id uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_id, 'role', 'authenticated')::text, true);
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

select pg_temp.mk_user('00000000-0000-4000-8000-00000000d001', 'test-maksimir-a@example.com', 'test-maksimir-A');
select pg_temp.mk_user('00000000-0000-4000-8000-00000000d002', 'test-maksimir-b@example.com', 'test-maksimir-B');
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-4000-8000-00000000d003', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'test-maksimir-anon@example.com', '',
        now(), now(), now(), '{}'::jsonb, '{}'::jsonb);   -- BEZ KYC-a

do $$
declare
  a constant uuid := '00000000-0000-4000-8000-00000000d001';
  b constant uuid := '00000000-0000-4000-8000-00000000d002';
  x constant uuid := '00000000-0000-4000-8000-00000000d003';
  r jsonb;
  c1 text; c2 text; c3 text;
begin
  select code into c1 from domovina_ai.maksimir_entries where n = 1;
  select code into c2 from domovina_ai.maksimir_entries where n = 2;
  select code into c3 from domovina_ai.maksimir_entries where n = 3;

  if (select count(*) from domovina_ai.maksimir_entries) <> 88 then
    raise exception 'PAD — očekivao 88 radova';
  end if;
  raise notice 'OK — 88 radova u maksimir_entries';

  -- 1. bez KYC-a
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', x, jsonb_build_object(c1, 100)), 'not_verified');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(null, %L)', jsonb_build_object(c1, 100)), 'not_verified');
  raise notice 'OK — bez Certilia verifikacije nema glasa (not_verified)';

  -- 2. bez privole
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 100)), 'terms_not_accepted');
  raise notice 'OK — bez privole nema glasa (terms_not_accepted)';
  perform domovina_ai._maksimir_accept_terms_for(a);
  perform domovina_ai._maksimir_accept_terms_for(b);

  -- 3. validacija listića
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 60, c2, 30)), 'points_sum_not_100');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 60, c2, 50)), 'points_sum_not_100');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object('XXXXXXXXX', 100)), 'unknown_entry');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 0, c2, 100)), 'invalid_ballot');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 50.5, c2, 49.5)), 'invalid_ballot');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, '100')), 'invalid_ballot');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, '[1,2]'), 'invalid_ballot');
  raise notice 'OK — listić mora biti {code: cijeli broj 1..100} sa zbrojem 100';

  -- 4. prvi listić
  r := domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c1, 60, c2, 40));
  if r->'items' <> jsonb_build_object(c1, 60, c2, 40) then raise exception 'PAD — items %', r; end if;
  r := domovina_ai.maksimir_results();
  if (r->>'voters')::int <> 1 or (r->'results'->0->>'code') <> c1 or (r->'results'->0->>'points')::int <> 60
     or (r->'results'->0->>'share')::numeric <> 60 then
    raise exception 'PAD — rezultati nakon prvog listića %', r->'results'->0;
  end if;
  if jsonb_array_length(r->'results') <> 88 then raise exception 'PAD — results mora imati svih 88'; end if;
  raise notice 'OK — listić 60/40 → 1 glasač, % ima 60 bodova (60 %%)', c1;

  -- 5. izmjena: atomska zamjena, i dalje 1 glasač
  r := domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c3, 100));
  r := domovina_ai.maksimir_results();
  if (r->>'voters')::int <> 1
     or (select (e->>'points')::int from jsonb_array_elements(r->'results') e where e->>'code' = c1) <> 0
     or (select (e->>'points')::int from jsonb_array_elements(r->'results') e where e->>'code' = c3) <> 100 then
    raise exception 'PAD — izmjena nije zamijenila listić %', r;
  end if;
  if (select revisions from domovina_ai.maksimir_ballots bl join domovina_ai.maksimir_voters v on v.id = bl.voter_id
       where v.oib_hash = 'test-maksimir-A') <> 2 then
    raise exception 'PAD — revisions';
  end if;
  raise notice 'OK — izmjena listića zamjenjuje stari (revisions = 2), i dalje 1 glasač';

  -- 6. druga osoba
  perform domovina_ai._maksimir_cast_ballot_for(b, jsonb_build_object(c3, 50, c1, 50));
  r := domovina_ai.maksimir_results();
  if (r->>'voters')::int <> 2 or (r->'results'->0->>'code') <> c3 or (r->'results'->0->>'points')::int <> 150
     or (r->'results'->0->>'share')::numeric <> 75 or (r->'results'->0->>'backers')::int <> 2 then
    raise exception 'PAD — dva glasača %', r->'results'->0;
  end if;
  raise notice 'OK — 2 glasača: % = 150 bodova = 75 %% svih glasova, 2 podupiratelja', c3;

  -- 7. zatvoren prozor
  update domovina_ai.maksimir_settings set closes_at = now() - interval '1 minute';
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 100)), 'voting_closed');
  if (domovina_ai.maksimir_results()->>'open')::boolean then raise exception 'PAD — open'; end if;
  update domovina_ai.maksimir_settings set closes_at = '2027-12-31 23:59:59 Europe/Zagreb', opens_at = now() + interval '1 day';
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 100)), 'voting_closed');
  update domovina_ai.maksimir_settings set opens_at = null;
  raise notice 'OK — izvan prozora glasanja: voting_closed';

  -- 8. povlačenje
  perform domovina_ai._maksimir_cast_ballot_for(b, '{}'::jsonb);
  if (domovina_ai.maksimir_results()->>'voters')::int <> 1 then raise exception 'PAD — povlačenje'; end if;
  raise notice 'OK — prazan listić {} povlači glas';
end;
$$;

\echo '--- 9. brisanje računa ne daje drugi listić'
delete from auth.users where id = '00000000-0000-4000-8000-00000000d001';   -- cascade briše KYC red
select pg_temp.mk_user('00000000-0000-4000-8000-00000000d004', 'test-maksimir-a2@example.com', 'test-maksimir-A');
do $$
declare r jsonb; c1 text;
begin
  select code into c1 from domovina_ai.maksimir_entries where n = 1;
  r := domovina_ai._maksimir_ballot_of('00000000-0000-4000-8000-00000000d004');
  if not (r->>'consented')::boolean or r->'items' = '{}'::jsonb then
    raise exception 'PAD — novi račun iste osobe ne vidi stari listić %', r;
  end if;
  perform domovina_ai._maksimir_cast_ballot_for('00000000-0000-4000-8000-00000000d004', jsonb_build_object(c1, 100));
  if (domovina_ai.maksimir_results()->>'voters')::int <> 1 then
    raise exception 'PAD — ponovna registracija je dala DRUGI listić';
  end if;
  raise notice 'OK — obriši račun → ponovno verificiraj: isti listić, i dalje 1 glasač';
end;
$$;


\echo '--- 11. lanac hasheva'
do $$
declare
  r jsonb; prev text := repeat('0', 64); l record; k int := 0; c1 text;
begin
  select code into c1 from domovina_ai.maksimir_entries where n = 1;
  -- povijest iz koraka 4–9: A 60/40, A 100, B 50/50, B povlačenje, A(novi račun) 100
  if (select count(*) from domovina_ai.maksimir_log) <> 5 then
    raise exception 'PAD — očekivao 5 redova u lancu, ima %', (select count(*) from domovina_ai.maksimir_log);
  end if;
  for l in select * from domovina_ai.maksimir_log order by seq loop
    k := k + 1;
    if l.seq <> k or l.prev_hash <> prev or l.hash <> encode(sha256(convert_to(
         l.prev_hash || '|' || l.seq || '|' || l.pseudonym || '|' || l.revision || '|' || l.ts_ms || '|' || l.items_canon,
         'UTF8')), 'hex') then
      raise exception 'PAD — lanac puca na seq %', l.seq;
    end if;
    prev := l.hash;
  end loop;
  raise notice 'OK — 5 redova, svaki hash i prev_hash se ponovno izračunaju';

  if (select count(distinct pseudonym) from domovina_ai.maksimir_log) <> 2 then
    raise exception 'PAD — ista osoba mora imati isti pseudonim i nakon novog računa';
  end if;
  if (select revision from domovina_ai.maksimir_log where seq = 4) <> 0
     or (select items_canon from domovina_ai.maksimir_log where seq = 4) <> '' then
    raise exception 'PAD — povlačenje mora biti revision 0 i prazan items_canon';
  end if;
  raise notice 'OK — 2 pseudonima (novi račun iste osobe = isti pseudonim), povlačenje = revision 0';

  r := domovina_ai._maksimir_ballot_of('00000000-0000-4000-8000-00000000d004');
  if (r->'receipt'->>'seq')::int <> 5 or r->'receipt'->>'hash' <> prev
     or r->'receipt'->>'items_canon' <> c1 || ':100' then
    raise exception 'PAD — potvrda %', r->'receipt';
  end if;
  raise notice 'OK — potvrda glasača = njegov zadnji red lanca';

  r := domovina_ai.maksimir_snapshot();
  if (r->'head'->>'seq')::int <> 5 or r->'head'->>'hash' <> prev or (r->>'voters')::int <> 1 then
    raise exception 'PAD — snapshot %', r - 'results';
  end if;
  raise notice 'OK — snapshot: vrh lanca i rezultati zajedno';

  -- povlačenje bez listića ne piše u lanac
  perform domovina_ai._maksimir_cast_ballot_for('00000000-0000-4000-8000-00000000d002', '{}'::jsonb);
  if (select count(*) from domovina_ai.maksimir_log) <> 5 then raise exception 'PAD — prazno povlačenje je pisalo'; end if;

  begin
    update domovina_ai.maksimir_log set items_canon = '' where seq = 1;
    raise exception 'PAD — update prošao';
  exception when others then
    if sqlerrm <> 'maksimir_log is append-only' then raise; end if;
  end;
  begin
    delete from domovina_ai.maksimir_log where seq = 5;
    raise exception 'PAD — delete prošao';
  exception when others then
    if sqlerrm <> 'maksimir_log is append-only' then raise; end if;
  end;
  begin
    truncate domovina_ai.maksimir_log;
    raise exception 'PAD — truncate prošao';
  exception when others then
    if sqlerrm <> 'maksimir_log is append-only' then raise; end if;
  end;
  raise notice 'OK — lanac je append-only (update/delete/truncate odbijeni)';

  perform pg_temp.expect_error('select domovina_ai.maksimir_log()', 'log_not_public_yet');
  update domovina_ai.maksimir_settings set closes_at = now() - interval '1 second';
  if jsonb_array_length(domovina_ai.maksimir_log()) <> 5
     or jsonb_array_length(domovina_ai.maksimir_log(3, 10)) <> 2 then
    raise exception 'PAD — javni lanac po zatvaranju';
  end if;
  update domovina_ai.maksimir_settings set closes_at = '2027-12-31 23:59:59 Europe/Zagreb';
  raise notice 'OK — cijeli lanac javan tek po zatvaranju';
end;
$$;

\echo '--- 12. vanjski provjeravač (Python) nad istim lancem'
update domovina_ai.maksimir_settings set closes_at = now() - interval '1 second';
\pset tuples_only on
\pset format unaligned
\o /tmp/maksimir-test-log.json
select domovina_ai.maksimir_log();
\o /tmp/maksimir-test-snapshot.json
select domovina_ai.maksimir_snapshot();
\o
\pset tuples_only off
\pset format aligned
\echo 'lanac i snapshot izvezeni u /tmp/maksimir-test-{log,snapshot}.json — provjera:'
\echo '  python3 <stadion-repo>/scripts/maksimir_verify.py /tmp/maksimir-test-log.json /tmp/maksimir-test-snapshot.json'
update domovina_ai.maksimir_settings set closes_at = '2027-12-31 23:59:59 Europe/Zagreb';

\echo '--- 10. javni RPC-evi kroz uloge'
begin;
select pg_temp.as_user('00000000-0000-4000-8000-00000000d004');
set local role authenticated;
do $$
declare r jsonb;
begin
  r := domovina_ai.maksimir_my_ballot();
  if not (r->>'verified')::boolean then raise exception 'PAD — my_ballot kao authenticated %', r; end if;
  begin
    perform 1 from domovina_ai.maksimir_ballot_items;
    raise exception 'PAD — authenticated čita ballot_items';
  exception when insufficient_privilege then null;
  end;
  begin
    perform domovina_ai._maksimir_cast_ballot_for(auth.uid(), '{}'::jsonb);
    raise exception 'PAD — authenticated zove interni wrapper';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK — authenticated: my_ballot radi, tablice i interni wrapperi zabranjeni';
end;
$$;
reset role;
commit;
begin;
set local role anon;
do $$
begin
  perform domovina_ai.maksimir_results();
  begin
    perform domovina_ai.maksimir_cast_ballot('{}'::jsonb);
    raise exception 'PAD — anon glasa';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from domovina_ai.maksimir_voters;
    raise exception 'PAD — anon čita voters';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from domovina_ai.maksimir_log;
    raise exception 'PAD — anon čita maksimir_log izravno';
  exception when insufficient_privilege then null;
  end;
  perform domovina_ai.maksimir_snapshot();
  raise notice 'OK — anon: rezultati da, glasanje i oib_hash ne';
end;
$$;
commit;

select pg_temp.cleanup();
\echo 'SVE PROVJERE PROŠLE'
