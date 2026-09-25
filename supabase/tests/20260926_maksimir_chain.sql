-- Provjera migracije 20260926120000 (Maksimir — spajanje faze 1 s glasanjem na lancu).
--
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" -f supabase/tests/20260926_maksimir_chain.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju "SVE PROVJERE PROŠLE".
-- Cleanup BRIŠE CIJELI maksimir_log i maksimir_zk_log — samo lokalno!
\set ON_ERROR_STOP on
\timing off

create or replace function pg_temp.cleanup() returns void language sql as $$
  update domovina_ai.maksimir_settings set opens_at = null, closes_at = '2027-12-31 23:59:59 Europe/Zagreb',
         chain_from = null, active_chain_id = null, active_contract = null;
  delete from domovina_ai.maksimir_shares;
  delete from domovina_ai.maksimir_chain_public;
  delete from domovina_ai.maksimir_chain_registrations where oib_hash like 'test-mch-%';
  delete from domovina_ai.maksimir_keystore where credential_id_hash like 'feed%';
  delete from domovina_ai.maksimir_voters where oib_hash like 'test-mch-%';
  delete from auth.users where email like 'test-mch-%@example.com';
  delete from domovina_ai.maksimir_chains where label like 'test-%';
  alter table domovina_ai.maksimir_log disable trigger user;
  delete from domovina_ai.maksimir_log;
  alter table domovina_ai.maksimir_log enable trigger user;
  alter table domovina_ai.maksimir_zk_log disable trigger user;
  delete from domovina_ai.maksimir_zk_log;
  alter table domovina_ai.maksimir_zk_log enable trigger user;
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

select pg_temp.mk_user('00000000-0000-4000-8000-0000000cc001', 'test-mch-a@example.com', 'test-mch-A', 'IVANA', 'HORVAT');
select pg_temp.mk_user('00000000-0000-4000-8000-0000000cc002', 'test-mch-b@example.com', 'test-mch-B', 'MARKO', 'KOVAČEVIĆ');
select pg_temp.mk_user('00000000-0000-4000-8000-0000000cc003', 'test-mch-c@example.com', 'test-mch-C', 'ANA', 'PERIĆ');

-- ugovor koji se broji (kao Gnosis) i testni (kao Chiado)
insert into domovina_ai.maksimir_chains (chain_id, contract, label, counts, rpc_url, relayer_url, semaphore, group_id, deploy_block)
values (100,   '0x00000000000000000000000000000000000000aa', 'test-gnosis', true,  'http://rpc.test', 'http://relayer.test', '0x8a1fd199516489b0fb7153eb5f075cdac83c693d', '7', 1000),
       (10200, '0x00000000000000000000000000000000000000bb', 'test-chiado', false, 'http://rpc.test', null,                  '0x8a1fd199516489b0fb7153eb5f075cdac83c693d', '2', 2000);

create temp table fx (proof jsonb);
-- oblik Semaphore dokaza sa scope listića (SNARK se ovdje ne provjerava)
insert into fx values ('{
 "merkleTreeDepth": 1,
 "merkleTreeRoot": "8421255540297742528422511282815627295641002497237025746317624583567460878734",
 "nullifier": "4258905585796011515188041119451567587823596460950646881156023647667681007508",
 "message": "123456789",
 "scope": "49474226259215312994888701590182260559525090119511958701658821262471327645696",
 "points": ["1","2","3","4","5","6","7","8"]
}');

do $$
declare
  a constant uuid := '00000000-0000-4000-8000-0000000cc001';
  b constant uuid := '00000000-0000-4000-8000-0000000cc002';
  c constant uuid := '00000000-0000-4000-8000-0000000cc003';
  g constant text := '0x00000000000000000000000000000000000000AA';   -- namjerno velika slova
  t constant text := '0x00000000000000000000000000000000000000bb';
  c1 text; c2 text;
  r jsonb; p jsonb; cnt int; seq_before bigint;
begin
  select code into c1 from domovina_ai.maksimir_entries order by n limit 1;
  select code into c2 from domovina_ai.maksimir_entries order by n offset 1 limit 1;

  -- 1. konfiguracija
  r := domovina_ai.maksimir_chain_config();
  if r->'active' <> 'null'::jsonb or jsonb_array_length(r->'chains') < 2 then raise exception 'PAD — config %', r; end if;
  update domovina_ai.maksimir_settings set active_chain_id = 100, active_contract = lower(g);
  r := domovina_ai.maksimir_chain_config();
  if r->'active'->>'label' <> 'test-gnosis' or (r->'active'->>'counts')::boolean is not true
     or r->'active'->>'relayerUrl' <> 'http://relayer.test' or (r->'active'->>'deployBlock')::int <> 1000 then
    raise exception 'PAD — aktivni ugovor %', r->'active';
  end if;
  raise notice 'OK — maksimir_chain_config: popis ugovora i aktivni ugovor';

  -- 2. faza 1 radi kao dosad; A i B predaju listiće
  perform domovina_ai._maksimir_accept_terms_for(a);
  perform domovina_ai._maksimir_accept_terms_for(b);
  perform domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c1, 60, c2, 40));
  perform domovina_ai._maksimir_cast_ballot_for(b, jsonb_build_object(c1, 100));
  if (domovina_ai.maksimir_results()->>'voters')::int <> 2 then raise exception 'PAD — 2 glasača'; end if;
  r := domovina_ai._maksimir_ballot_of(a);
  if r->>'pseudonym' !~ '^[0-9a-f]{64}$' or r->>'pseudonym' <> r->'receipt'->>'pseudonym'
     or (r->>'chain_consented')::boolean or r->'chain_registrations' <> '[]'::jsonb then
    raise exception 'PAD — my_ballot nova polja %', r;
  end if;
  raise notice 'OK — faza 1 nepromijenjena; my_ballot vraća pseudonim i prazne registracije';

  -- 3. registracija: uvjeti v2 i provjere oblika
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', a, g, '11'), 'chain_terms_not_accepted');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', null, g, '11'), 'not_verified');
  r := domovina_ai._maksimir_accept_chain_terms_for(a);
  if not (r->>'chain_consented')::boolean then raise exception 'PAD — uvjeti v2'; end if;
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', a, '0x00000000000000000000000000000000000000cc', '11'), 'unknown_chain');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 1, %L, %L)', a, g, '11'), 'unknown_chain');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', a, g, '0'), 'invalid_commitment');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', a, g, 'abc'), 'invalid_commitment');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_chain_register_for(%L, 100, %L, %L)', a, g,
    '21888242871839275222246405745257275088548364400416034343698204186575808495617'), 'invalid_commitment');
  raise notice 'OK — registracija traži eOsobnu, uvjete v2, poznat ugovor i ispravan commitment';

  -- 4. testni ugovor (counts = false): nema prijenosa, faza 1 i dalje radi za A
  select max(seq) into seq_before from domovina_ai.maksimir_log;
  r := domovina_ai._maksimir_chain_register_for(a, 10200, t, '111');
  if r->>'status' <> 'ok' or r->'transfer_seq' <> 'null'::jsonb then raise exception 'PAD — test registracija %', r; end if;
  if (select max(seq) from domovina_ai.maksimir_log) <> seq_before then raise exception 'PAD — testni ugovor je dirao lanac'; end if;
  perform domovina_ai._maksimir_cast_ballot_for(a, jsonb_build_object(c1, 50, c2, 50));
  raise notice 'OK — registracija na testni ugovor ne dira fazu 1';

  -- 5. ugovor koji se broji: prijenos u istoj transakciji
  r := domovina_ai._maksimir_chain_register_for(a, 100, g, '222');
  if r->>'status' <> 'ok' or (r->>'existing')::boolean or r->'transfer_seq' = 'null'::jsonb
     or r->'transferred' <> jsonb_build_object(c1, 50, c2, 50) or r->'chain'->>'contract' <> lower(g) then
    raise exception 'PAD — registracija s prijenosom %', r;
  end if;
  select to_jsonb(l) into p from domovina_ai.maksimir_log l where seq = (r->>'transfer_seq')::bigint;
  if (p->>'revision')::int <> 0 or p->>'items_canon' <> '' or p->>'pseudonym' <> domovina_ai._maksimir_ballot_of(a)->>'pseudonym' then
    raise exception 'PAD — red prijenosa %', p;
  end if;
  if (domovina_ai.maksimir_results()->>'voters')::int <> 1 then raise exception 'PAD — ostatak faze 1 nije 1'; end if;
  if domovina_ai._maksimir_ballot_of(a)->'items' <> '{}'::jsonb then raise exception 'PAD — listić A nije povučen'; end if;
  raise notice 'OK — prijenos: listić faze 1 povučen (revision 0 u lancu), ostatak = 1 glasač';

  -- 6. isti commitment = isti odgovor; drugi commitment = already_registered; tuđi = commitment_taken
  r := domovina_ai._maksimir_chain_register_for(a, 100, g, '222');
  if r->>'status' <> 'ok' or not (r->>'existing')::boolean then raise exception 'PAD — ponovljena registracija %', r; end if;
  r := domovina_ai._maksimir_chain_register_for(a, 100, g, '333');
  if r->>'status' <> 'already_registered' or r->>'commitment' <> '222' then raise exception 'PAD — already_registered %', r; end if;
  perform domovina_ai._maksimir_accept_chain_terms_for(c);
  r := domovina_ai._maksimir_chain_register_for(c, 100, g, '222');
  if r->>'status' <> 'commitment_taken' then raise exception 'PAD — commitment_taken %', r; end if;
  r := domovina_ai._maksimir_chain_register_for(c, 100, g, '444');   -- C nema listić faze 1
  if r->>'status' <> 'ok' or r->'transfer_seq' <> 'null'::jsonb then raise exception 'PAD — C bez listića %', r; end if;
  select count(*) into cnt from domovina_ai.maksimir_chain_registrations where oib_hash like 'test-mch-%';
  if cnt <> 3 then raise exception 'PAD — broj registracija %', cnt; end if;
  raise notice 'OK — jedna osoba = jedan commitment po ugovoru; commitment ne može imati dvije osobe';

  -- 7. registriran na ugovor koji se broji ne može glasati u fazi 1
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, jsonb_build_object(c1, 100)), 'chain_registered');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', a, '{}'), 'chain_registered');
  r := domovina_ai._maksimir_ballot_of(a);
  if jsonb_array_length(r->'chain_registrations') <> 2 then raise exception 'PAD — my_ballot registracije %', r; end if;
  raise notice 'OK — nakon prijenosa faza 1 odbija listić te osobe (chain_registered)';

  -- 8. zastavica: najava pa prijelaz
  update domovina_ai.maksimir_settings set chain_from = now() + interval '1 day';
  r := domovina_ai.maksimir_results();
  if not (r->>'phase1_open')::boolean or not (r->>'chain_open')::boolean or r->>'chain_from' is null then raise exception 'PAD — najava %', r - 'results'; end if;
  perform pg_temp.expect_error('select domovina_ai.maksimir_log()', 'log_not_public_yet');
  perform domovina_ai._maksimir_cast_ballot_for(b, jsonb_build_object(c2, 100));   -- B i dalje smije

  update domovina_ai.maksimir_settings set chain_from = now() - interval '1 second';
  r := domovina_ai.maksimir_results();
  if (r->>'phase1_open')::boolean or (r->>'open')::boolean or not (r->>'chain_open')::boolean then raise exception 'PAD — prijelaz %', r - 'results'; end if;
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', b, jsonb_build_object(c1, 100)), 'voting_closed');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_zk_register_for(%L, %L)', b, '555'), 'voting_closed');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_zk_share(%L, 1)', (select proof from fx)), 'voting_closed');
  if jsonb_array_length(domovina_ai.maksimir_log()) < 5 then raise exception 'PAD — lanac nije javan nakon prijelaza'; end if;
  r := domovina_ai.maksimir_snapshot();
  if r->>'schema' <> 'maksimir-snapshot/3' or not (r->>'phase1_final')::boolean or (r->>'voters')::int <> 1 then
    raise exception 'PAD — snapshot v3 %', r - 'results';
  end if;
  raise notice 'OK — chain_from: faza 1 zatvorena za listiće i ZK, lanac javan, snapshot v3 phase1_final';

  -- 9. nakon prijelaza B prenosi listić faze 1
  perform domovina_ai._maksimir_accept_chain_terms_for(b);
  r := domovina_ai._maksimir_chain_register_for(b, 100, g, '666');
  if r->'transferred' <> jsonb_build_object(c2, 100) then raise exception 'PAD — prijenos B %', r; end if;
  if (domovina_ai.maksimir_results()->>'voters')::int <> 0 then raise exception 'PAD — ostatak nije 0'; end if;
  raise notice 'OK — prijenos radi i nakon prijelaza; ostatak faze 1 samo pada';

  -- 10. povratak (razina 4): faza 1 ponovno otvorena, ali ne za registrirane
  update domovina_ai.maksimir_settings set chain_from = null;
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', b, jsonb_build_object(c1, 100)), 'chain_registered');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_cast_ballot_for(%L, %L)', c, jsonb_build_object(c1, 100)), 'chain_registered');
  update domovina_ai.maksimir_settings set chain_from = now() - interval '1 second';
  raise notice 'OK — povratak: faza 1 ne prima listiće osoba upisanih na lanac';

  -- 11. keystore: samo dodaje
  perform pg_temp.expect_error('select domovina_ai.maksimir_keystore_put(''nije-hash'', ''{}'')', 'invalid_blob');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_keystore_put(%L, %L)', 'feed' || repeat('0', 60), '[1]'), 'invalid_blob');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_keystore_put(%L, %L)', 'feed' || repeat('0', 60),
    jsonb_build_object('x', repeat('a', 3000))), 'invalid_blob');
  perform domovina_ai.maksimir_keystore_put('feed' || repeat('0', 60), '{"v":1,"iv":"a","ct":"b"}');
  perform domovina_ai.maksimir_keystore_put('feed' || repeat('0', 60), '{"v":1,"iv":"a","ct":"b"}');   -- isti: ok
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_keystore_put(%L, %L)', 'feed' || repeat('0', 60), '{"v":1,"iv":"x","ct":"y"}'), 'keystore_exists');
  if domovina_ai.maksimir_keystore_get('feed' || repeat('0', 60))->>'ct' <> 'b' then raise exception 'PAD — keystore get'; end if;
  if domovina_ai.maksimir_keystore_get('feed' || repeat('1', 60)) is not null then raise exception 'PAD — keystore nepostojeći'; end if;
  raise notice 'OK — keystore: prvi upis pobjeđuje, isti upis ok, drugačiji odbijen, veličina ograničena';

  -- 12. javna objava listića s lanca
  p := (select proof from fx);
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_chain_for(%L, %L, 10200, %L, %L, %L)', b, 'full', t, p->>'nullifier', p), 'not_registered');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_chain_for(%L, %L, 100, %L, %L, %L)', a, 'svima', g, p->>'nullifier', p), 'invalid_mode');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_chain_for(%L, %L, 100, %L, %L, %L)', a, 'full', g, '1', p), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_chain_for(%L, %L, 100, %L, %L, %L)', a, 'full', g, p->>'nullifier',
    jsonb_set(p, '{scope}', '"49474226259215312994888701590181247581981161421217961257574660746611720716288"')), 'invalid_proof');
  perform pg_temp.expect_error(format('select domovina_ai._maksimir_set_public_chain_for(%L, %L, 100, %L, %L, %L)', a, 'full', g, p->>'nullifier',
    p - 'points'), 'invalid_proof');
  r := domovina_ai._maksimir_set_public_chain_for(a, 'initial', 100, g, p->>'nullifier', p);
  if r->>'share_id' is null or r->'chain_public'->>'nullifier' <> p->>'nullifier' then raise exception 'PAD — set_public_chain %', r; end if;
  r := domovina_ai.maksimir_share(r->>'share_id');
  if r->>'kind' <> 'public' or r->'card'->>'name' <> 'Ivana H.' or r->'card'->'items' <> '[]'::jsonb
     or r->'card'->'chain'->>'nullifier' <> p->>'nullifier' or r->'card'->'chain'->'proof'->>'message' <> '123456789'
     or (r->'card'->'chain'->>'chainId')::int <> 100 then
    raise exception 'PAD — kartica s lanca %', r;
  end if;
  if (domovina_ai.maksimir_public_ballots()->>'count')::int <> 1 then raise exception 'PAD — public_ballots s lanca'; end if;
  if (domovina_ai.maksimir_snapshot()->>'public_voters')::int <> 1 then raise exception 'PAD — public_voters'; end if;
  perform domovina_ai._maksimir_set_public_for(a, null);
  if domovina_ai.maksimir_share(domovina_ai._maksimir_ballot_of(a)->>'share_id')->'card' <> 'null'::jsonb then
    raise exception 'PAD — isključena kartica s lanca';
  end if;
  raise notice 'OK — javni listić s lanca: ime iz baze, nullifier + dokaz vlasništva, isključivanje radi';

  -- 13. anonimna objava na lancu: kratka poveznica
  perform pg_temp.expect_error('select domovina_ai.maksimir_chain_share(100, ''0x00000000000000000000000000000000000000aa'', ''0x12'')', 'invalid_tx');
  perform pg_temp.expect_error(format('select domovina_ai.maksimir_chain_share(1, %L, %L)', g, '0x' || repeat('ab', 32)), 'unknown_chain');
  r := domovina_ai.maksimir_chain_share(100, g, '0x' || repeat('AB', 32));
  p := domovina_ai.maksimir_chain_share(100, g, '0x' || repeat('ab', 32));
  if r->>'id' <> p->>'id' then raise exception 'PAD — ista transakcija, druga poveznica'; end if;
  r := domovina_ai.maksimir_share(r->>'id');
  if r->>'kind' <> 'chain' or r->>'txHash' <> '0x' || repeat('ab', 32) or r->>'contract' <> lower(g) then raise exception 'PAD — chain objava %', r; end if;
  if (domovina_ai.maksimir_public_ballots()->>'zk_shares')::int <> 1 then raise exception 'PAD — zk_shares broji chain'; end if;
  raise notice 'OK — anonimna objava na lancu: id → transakcija, ista transakcija = ista poveznica';
end;
$$;

\echo '--- 14. anon ne smije zvati registrar ni interne funkcije'
begin;
set local role anon;
do $$
begin
  begin
    perform domovina_ai._maksimir_chain_register_for('00000000-0000-4000-8000-0000000cc003', 100, '0x00000000000000000000000000000000000000aa', '777');
    raise exception 'PAD — anon je zvao registrar';
  exception when insufficient_privilege then null;
  end;
  begin
    perform domovina_ai.maksimir_accept_chain_terms();
    raise exception 'PAD — anon je prihvatio uvjete';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from domovina_ai.maksimir_chain_registrations;
    raise exception 'PAD — anon čita registracije';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from domovina_ai.maksimir_keystore;
    raise exception 'PAD — anon čita keystore izravno';
  exception when insufficient_privilege then null;
  end;
  perform domovina_ai.maksimir_chain_config();
  perform domovina_ai.maksimir_keystore_get(repeat('0', 64));
  raise notice 'OK — anon: samo javni RPC-evi (config, keystore, objave)';
end;
$$;
commit;

\echo '--- 15. authenticated: uvjeti v2 kroz auth.uid()'
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000cc003","role":"authenticated"}', true);
do $$
declare r jsonb;
begin
  r := domovina_ai.maksimir_accept_chain_terms();
  if not (r->>'chain_consented')::boolean then raise exception 'PAD — authenticated uvjeti'; end if;
  begin
    perform domovina_ai._maksimir_chain_register_for('00000000-0000-4000-8000-0000000cc003', 100, '0x00000000000000000000000000000000000000aa', '777');
    raise exception 'PAD — authenticated je zvao registrar izravno';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK — authenticated: uvjeti v2 da, registrar samo preko edge funkcije';
end;
$$;
commit;

select pg_temp.cleanup();
\echo 'SVE PROVJERE PROŠLE'
