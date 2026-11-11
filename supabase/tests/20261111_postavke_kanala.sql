-- Provjera migracije 20261111120000_postavke_kanala (postavke kanala za vlasnika).
--
-- Pokretanje nad lokalnim stackom (idempotentno):
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20261111_postavke_kanala.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju NOTICE "SVE PROVJERE PROŠLE".
-- Svaki drugi ishod je pad (ON_ERROR_STOP).
--
-- Testovi su pisani iz UGOVORA (S2), ne iz implementacije: cilj je uhvatiti
-- odstupanje migracije od ugovora.
--
-- ── IDEMPOTENTNOST: svježi sintetički UC-ovi u svakom prolazu ───────────────
-- channel_settings_events je append-only, a channel_tombstones trajan: ni
-- postgres ne smije obrisati njihove retke. Zato svaki prolaz radi na NOVIM
-- UC-ovima: 'UCtestpk' + 14 hex znakova iz md5(clock_timestamp, random) + 2
-- znaka oznake kanala = 24 znaka (UC + 22). Alternativa, `alter table … disable
-- trigger` u čišćenju, je odbijena: test bi tada privremeno gasio upravo
-- zaštitu koju provjerava, a prekinut prolaz (ili paralelna sesija) vidio bi
-- tablicu bez nje. Cijena: svaki prolaz ostavi nekoliko događaja i dva
-- tombstonea pod prefiksom 'UCtestpk' u LOKALNOJ bazi. Stvarni redovi
-- (domovina_tv, UCXXhnehl2pss0uYdfLRDtyw) se ne diraju.
--
-- Fiksni (ponovljivi) fixturei se čiste/upsertaju na početku: testni
-- korisnici (…0c50xx), njihovi channel_claims, slugovi 'test_postavke_*',
-- episode_safes 'tpkEpizoda*', kampanje 'test-postavke-*' i njihovi doprinosi
-- i mjesta.
\set ON_ERROR_STOP on
\timing off
\pset pager off

-- ── run id (svježi UC-ovi) ──────────────────────────────────────────────────
do $$ begin
  perform set_config('test.run', left(md5(clock_timestamp()::text || random()::text), 14), false);
end $$;

-- ── pomoćnici ───────────────────────────────────────────────────────────────
create or replace function pg_temp.uc(p_n text) returns text language sql as $$
  select 'UCtestpk' || current_setting('test.run') || p_n
$$;

create or replace function pg_temp.u(p_n text) returns uuid language sql as $$
  select ('00000000-0000-4000-8000-0000000c50' || p_n)::uuid
$$;

-- Ugovor: 20 ključeva, ovim redoslijedom.
create or replace function pg_temp.kljucevi() returns text[] language sql as $$
  select array['channel_enabled','processing','home_featured','in_app_search','search_engines',
               'push_notifications','cdn_playback','share_clips','ebook',
               'article_summary','transcript_subtitles','english_translation','magisterium',
               'highlights_reels','persons_mentions','news_portal','ai_assistants',
               'donations','paid_sponsor_moments','sponsors_in_video']
$$;

create or replace function pg_temp.ai_kljucevi() returns text[] language sql as $$
  select array['article_summary','transcript_subtitles','english_translation','magisterium',
               'highlights_reels','persons_mentions','news_portal','ai_assistants']
$$;

create or replace function pg_temp.ocekivano(p_false text[]) returns jsonb language sql as $$
  select jsonb_object_agg(k, not (k = any (p_false))) from unnest(pg_temp.kljucevi()) k
$$;

-- Uloga + JWT za ostatak transakcije. 'postgres' | 'anon' | 'service' |
-- 'bez_sesije' (authenticated bez sub) | uuid korisnika.
create or replace function pg_temp.kao(p text) returns void language plpgsql as $$
begin
  if p = 'postgres' then
    perform set_config('request.jwt.claims', '', true);
    perform set_config('role', 'postgres', true);
  elsif p = 'anon' then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('role', 'anon', true);
  elsif p = 'service' then
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
  elsif p = 'bez_sesije' then
    perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
    perform set_config('role', 'authenticated', true);
  else
    perform set_config('request.jwt.claims',
      jsonb_build_object('sub', p::uuid, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $$;

-- Izvrši SQL kao zadana uloga i vrati prvi stupac prvog retka kao text.
create or replace function pg_temp.izvrsi(p_kao text, p_sql text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.kao(p_kao);
  execute p_sql into v;
  perform pg_temp.kao('postgres');
  return v;
exception when others then
  perform pg_temp.kao('postgres');
  raise exception 'PAO TEST: [%] neočekivana greška: % (SQL: %)', p_kao, sqlerrm, p_sql;
end $$;

-- Očekivan pad. p_err: prefiks poruke ili '#SQLSTATE'; više alternativa s '|'.
-- Ako naredba NE padne, sentinel-greška poništi i njezin učinak (subtransakcija).
create or replace function pg_temp.pada(p_kao text, p_sql text, p_err text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text; v_alt text; v_ok boolean := false;
begin
  begin
    perform pg_temp.kao(p_kao);
    execute p_sql;
    raise exception using errcode = 'XX999', message = 'NIJE_PALO';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  perform pg_temp.kao('postgres');
  if v_state = 'XX999' and v_msg = 'NIJE_PALO' then
    raise exception 'PAO TEST: % — prošlo bez greške (očekivano %)', p_opis, p_err;
  end if;
  foreach v_alt in array string_to_array(p_err, '|') loop
    if (v_alt like '#%' and v_state = substr(v_alt, 2))
       or (v_alt not like '#%' and v_msg like v_alt || '%') then
      v_ok := true;
    end if;
  end loop;
  if not v_ok then
    raise exception 'PAO TEST: % — očekivano %, dobiveno [%] %', p_opis, p_err, v_state, v_msg;
  end if;
  raise notice 'OK — %: [%] %', p_opis, v_state, v_msg;
end $$;

-- DML bez učinka: ili pada, ili dira 0 redaka (RLS bez policyja). Ako dirne
-- išta, sentinel ga poništi i test pada.
create or replace function pg_temp.bez_ucinka(p_kao text, p_sql text, p_opis text)
returns void language plpgsql as $$
declare v_state text; v_msg text; n integer;
begin
  begin
    perform pg_temp.kao(p_kao);
    execute p_sql;
    get diagnostics n = row_count;
    if n > 0 then
      raise exception using errcode = 'XX998', message = 'DIRNUO ' || n;
    end if;
    v_msg := '0 redaka';
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
  end;
  perform pg_temp.kao('postgres');
  if v_state = 'XX998' then
    raise exception 'PAO TEST: % — % redaka promijenjeno', p_opis, v_msg;
  end if;
  raise notice 'OK — %: [%] %', p_opis, coalesce(v_state, '-'), v_msg;
end $$;

create or replace function pg_temp.postavi(p_user text, p_uc text, p_key text, p_val boolean)
returns jsonb language sql as $$
  select pg_temp.izvrsi(p_user,
    format('select domovina_ai.set_channel_setting(%L, %L, %L)', p_uc, p_key, p_val))::jsonb
$$;

create or replace function pg_temp.br_dogadaja(p_uc text) returns integer language sql as $$
  select count(*)::integer from domovina_ai.channel_settings_events where youtube_channel_id = p_uc
$$;

-- Efektivno stanje (i po ključu kroz channel_setting_enabled) = očekivano.
create or replace function pg_temp.efektivno(p_uc text, p_false text[], p_opis text)
returns void language plpgsql as $$
declare v jsonb; e jsonb := pg_temp.ocekivano(p_false); k text; razlika text;
begin
  v := domovina_ai.channel_effective_settings(p_uc);
  if v is distinct from e then
    select string_agg(k2 || '=' || coalesce(v->>k2, 'NEMA') || ' (očekivano ' || (e->>k2) || ')', ', ')
      into razlika
      from unnest(pg_temp.kljucevi()) k2 where (v->k2) is distinct from (e->k2);
    raise exception 'PAO TEST: % — efektivno odstupa: % ; višak ključeva: %', p_opis, razlika,
      (select string_agg(x, ',') from jsonb_object_keys(v) x where x <> all (pg_temp.kljucevi()));
  end if;
  foreach k in array pg_temp.kljucevi() loop
    if domovina_ai.channel_setting_enabled(p_uc, k) is distinct from (e->>k)::boolean then
      raise exception 'PAO TEST: % — channel_setting_enabled(%) = %, očekivano %', p_opis, k,
        domovina_ai.channel_setting_enabled(p_uc, k), e->>k;
    end if;
  end loop;
  raise notice 'OK — %: efektivno točno (% false)', p_opis, coalesce(array_length(p_false, 1), 0);
end $$;

\echo '--- 0. migracija postoji: objekti, RLS, ključevi, sintetički UC-ovi'
do $$
declare o text; n integer;
begin
  foreach o in array array[
    'domovina_ai.channel_setting_keys()',
    'domovina_ai.channel_effective_settings(text)',
    'domovina_ai.channel_setting_enabled(text,text)',
    'domovina_ai.channel_setting_enabled_by_slug(text,text)',
    'domovina_ai.is_channel_settings_writer(text,uuid)',
    'domovina_ai.is_channel_settings_reader(text,uuid)',
    'domovina_ai.set_channel_setting(text,text,boolean)',
    'domovina_ai.request_channel_deletion(text,text)',
    'domovina_ai.cancel_channel_deletion(text)',
    'domovina_ai.confirm_channel_deletion_by_phone(uuid,text)',
    'domovina_ai.mark_channel_deletion_executed(uuid,text[])',
    'domovina_ai.get_channel_settings_log(text,integer,bigint)'] loop
    if to_regprocedure(o) is null then raise exception 'PAO TEST: nema funkcije %', o; end if;
  end loop;
  foreach o in array array['domovina_ai.channel_slugs','domovina_ai.channel_settings',
    'domovina_ai.channel_settings_events','domovina_ai.channel_deletion_requests',
    'domovina_ai.channel_tombstones'] loop
    if to_regclass(o) is null then raise exception 'PAO TEST: nema tablice %', o; end if;
    if not (select relrowsecurity from pg_class where oid = to_regclass(o)) then
      raise exception 'PAO TEST: RLS nije uključen na %', o;
    end if;
  end loop;
  foreach o in array array['domovina_ai.public_channel_settings','domovina_ai.public_channel_tombstones'] loop
    if to_regclass(o) is null then raise exception 'PAO TEST: nema pogleda %', o; end if;
  end loop;
  raise notice 'OK — 12 funkcija, 5 tablica s RLS-om, 2 javna pogleda';

  if domovina_ai.channel_setting_keys() is distinct from pg_temp.kljucevi() then
    raise exception 'PAO TEST: channel_setting_keys() = %', domovina_ai.channel_setting_keys();
  end if;
  raise notice 'OK — channel_setting_keys(): 20 ključeva, redoslijed iz ugovora';

  if pg_temp.uc('A1') !~ '^UC[0-9A-Za-z_-]{22}$' or length(pg_temp.uc('A1')) <> 24 then
    raise exception 'PAO TEST (fixture): sintetički UC % ne prolazi regex', pg_temp.uc('A1');
  end if;
  -- seed
  if not exists (select 1 from domovina_ai.channel_slugs
                  where slug = 'domovina_tv' and youtube_channel_id = 'UCXXhnehl2pss0uYdfLRDtyw') then
    raise exception 'PAO TEST: nema seeda domovina_tv → UCXXhnehl2pss0uYdfLRDtyw';
  end if;
  begin
    insert into domovina_ai.channel_settings (youtube_channel_id) values ('UCkratak');
    raise exception using errcode = 'XX999', message = 'PAO TEST: channel_settings prima UC koji ne prolazi regex';
  exception when check_violation then null;
  end;
  begin
    insert into domovina_ai.channel_slugs (slug, youtube_channel_id) values ('test_postavke_los', 'UCkratak');
    raise exception using errcode = 'XX999', message = 'PAO TEST: channel_slugs prima UC koji ne prolazi regex';
  exception when check_violation then null;
  end;
  raise notice 'OK — UC % (24 zn.), seed domovina_tv, check UC-a na channel_settings i channel_slugs', pg_temp.uc('A1');
end $$;

-- ── fixturei: korisnici, claimovi, slugovi ─────────────────────────────────
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select pg_temp.u(n), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'test-postavke-' || n || '@example.com', crypt('demo1234', gen_salt('bf')),
       now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
  from unnest(array['01','02','03','04','05','06','07','08','09','0a','0b','0c']) n
on conflict (id) do nothing;

delete from domovina_ai.channel_claims
 where account_id in (select pg_temp.u(n) from unnest(array['01','02','03','04','05','06','07','08','09','0a','0b','0c']) n);

-- 01 primarni A1 | 02 suradnik A1 (10 d) | 03 suradnik 91 d | 04 suradnik 89 d
-- 05 revoked | 06 pending | 07 disputed | 08 bez claima (donator/kupac)
-- 09 primarni D1 (brisanje) | 0a suradnik D1 bez naslova | 0b primarni M1 (novac)
-- 0c verified bez verified_at
insert into domovina_ai.channel_claims
  (account_id, youtube_channel_id, channel_title, google_sub, role, status, verified_at)
values
  (pg_temp.u('01'), pg_temp.uc('A1'), 'Testni kanal A', 'g-tpk-01', 'primary',      'verified', now() - interval '1 day'),
  (pg_temp.u('02'), pg_temp.uc('A1'), null,             'g-tpk-02', 'collaborator', 'verified', now() - interval '10 days'),
  (pg_temp.u('03'), pg_temp.uc('A1'), null,             'g-tpk-03', 'collaborator', 'verified', now() - interval '91 days'),
  (pg_temp.u('04'), pg_temp.uc('A1'), null,             'g-tpk-04', 'collaborator', 'verified', now() - interval '89 days'),
  (pg_temp.u('05'), pg_temp.uc('A1'), null,             'g-tpk-05', 'collaborator', 'revoked',  now() - interval '1 day'),
  (pg_temp.u('06'), pg_temp.uc('A1'), null,             'g-tpk-06', 'collaborator', 'pending',  null),
  (pg_temp.u('07'), pg_temp.uc('A1'), null,             'g-tpk-07', 'collaborator', 'disputed', now() - interval '1 day'),
  (pg_temp.u('0c'), pg_temp.uc('A1'), null,             'g-tpk-0c', 'collaborator', 'verified', null),
  (pg_temp.u('09'), pg_temp.uc('D1'), 'Testni kanal brisanja', 'g-tpk-09', 'primary',      'verified', now() - interval '1 day'),
  (pg_temp.u('0a'), pg_temp.uc('D1'), null,             'g-tpk-0a', 'collaborator', 'verified', now() - interval '5 days'),
  (pg_temp.u('0b'), pg_temp.uc('M1'), 'Testni kanal novca', 'g-tpk-0b', 'primary',  'verified', now() - interval '1 day');

insert into domovina_ai.channel_slugs (slug, youtube_channel_id)
values ('test_postavke_kanala', pg_temp.uc('M1')), ('test_postavke_brisanje', pg_temp.uc('D1'))
on conflict (slug) do update set youtube_channel_id = excluded.youtube_channel_id, updated_at = now();

\echo '--- 1. suradnik (verified, 10 dana) piše ključ; događaj s old/new i role=collaborator'
do $$
declare v jsonb; e domovina_ai.channel_settings_events; s jsonb;
begin
  if not domovina_ai.is_channel_settings_writer(pg_temp.uc('A1'), pg_temp.u('02')) then
    raise exception 'PAO TEST: suradnik nije pisac';
  end if;
  v := pg_temp.postavi(pg_temp.u('02')::text, pg_temp.uc('A1'), 'ebook', false);
  if (select count(*) from jsonb_object_keys(v)) is distinct from 20 or v->'ebook' is distinct from 'false'::jsonb
     or v->'donations' is distinct from 'true'::jsonb then
    raise exception 'PAO TEST: povrat set_channel_setting %', v;
  end if;
  if pg_temp.br_dogadaja(pg_temp.uc('A1')) <> 1 then
    raise exception 'PAO TEST: događaja %', pg_temp.br_dogadaja(pg_temp.uc('A1'));
  end if;
  select * into e from domovina_ai.channel_settings_events where youtube_channel_id = pg_temp.uc('A1');
  if e.kind is distinct from 'setting' or e.key is distinct from 'ebook' or e.old_value is distinct from true
     or e.new_value is distinct from false or e.account_id is distinct from pg_temp.u('02')
     or e.role is distinct from 'collaborator' or e.source is distinct from 'app' then
    raise exception 'PAO TEST: događaj %', row_to_json(e);
  end if;
  select settings into s from domovina_ai.channel_settings where youtube_channel_id = pg_temp.uc('A1');
  if s is distinct from '{"ebook": false}'::jsonb then
    raise exception 'PAO TEST: settings nije rijedak: %', s;
  end if;
  raise notice 'OK — suradnik: ebook=false, događaj true→false role=collaborator, settings %', s;
end $$;

\echo '--- 2. primarni piše; ista vrijednost drugi put ne stvara događaj'
do $$
declare n integer; e domovina_ai.channel_settings_events; s jsonb; s2 jsonb; v jsonb;
begin
  perform pg_temp.postavi(pg_temp.u('01')::text, pg_temp.uc('A1'), 'highlights_reels', false);
  select * into e from domovina_ai.channel_settings_events
   where youtube_channel_id = pg_temp.uc('A1') order by id desc limit 1;
  if e.key is distinct from 'highlights_reels' or e.old_value is distinct from true or e.new_value is distinct from false
     or e.role is distinct from 'primary' or e.account_id is distinct from pg_temp.u('01') then
    raise exception 'PAO TEST: događaj primarnog %', row_to_json(e);
  end if;
  raise notice 'OK — primarni: highlights_reels=false, role=primary';

  n := pg_temp.br_dogadaja(pg_temp.uc('A1'));
  select settings into s from domovina_ai.channel_settings where youtube_channel_id = pg_temp.uc('A1');
  v := pg_temp.postavi(pg_temp.u('01')::text, pg_temp.uc('A1'), 'highlights_reels', false);
  if pg_temp.br_dogadaja(pg_temp.uc('A1')) <> n then raise exception 'PAO TEST: ista vrijednost stvorila događaj'; end if;
  if v->'highlights_reels' is distinct from 'false'::jsonb then raise exception 'PAO TEST: povrat bez promjene %', v; end if;
  raise notice 'OK — ista vrijednost (false→false): bez događaja, vraća stanje';

  -- nedostaje = true → postavljanje true nije promjena
  v := pg_temp.postavi(pg_temp.u('01')::text, pg_temp.uc('A1'), 'donations', true);
  select settings into s2 from domovina_ai.channel_settings where youtube_channel_id = pg_temp.uc('A1');
  if pg_temp.br_dogadaja(pg_temp.uc('A1')) <> n then raise exception 'PAO TEST: nedostajući=true + true stvorio događaj'; end if;
  if s2 is distinct from s then raise exception 'PAO TEST: settings se promijenio bez promjene: % → %', s, s2; end if;
  raise notice 'OK — nedostaje=true, postavi true: bez događaja, settings netaknut';

  -- vraćanje na true je promjena
  v := pg_temp.postavi(pg_temp.u('01')::text, pg_temp.uc('A1'), 'ebook', true);
  select * into e from domovina_ai.channel_settings_events
   where youtube_channel_id = pg_temp.uc('A1') order by id desc limit 1;
  if pg_temp.br_dogadaja(pg_temp.uc('A1')) is distinct from n + 1 or e.key is distinct from 'ebook'
     or e.old_value is distinct from false or e.new_value is distinct from true or v->'ebook' is distinct from 'true'::jsonb then
    raise exception 'PAO TEST: vraćanje ebook %', row_to_json(e);
  end if;
  raise notice 'OK — ebook false→true: jedan događaj';
end $$;

\echo '--- 3. verified_at stariji od 90 dana → not_owner; 89 dana prolazi; verified bez verified_at → not_owner'
select pg_temp.pada(pg_temp.u('03')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')),
  'not_owner', 'suradnik s claimom starim 91 dan');
select pg_temp.pada(pg_temp.u('0c')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')),
  'not_owner', 'verified bez verified_at');
do $$
begin
  perform pg_temp.postavi(pg_temp.u('04')::text, pg_temp.uc('A1'), 'push_notifications', false);
  if domovina_ai.is_channel_settings_writer(pg_temp.uc('A1'), pg_temp.u('03')) then
    raise exception 'PAO TEST: is_channel_settings_writer true za 91 dan';
  end if;
  if not domovina_ai.is_channel_settings_reader(pg_temp.uc('A1'), pg_temp.u('03')) then
    raise exception 'PAO TEST: is_channel_settings_reader false za 91 dan (čitač = bilo koje starosti)';
  end if;
  raise notice 'OK — 89 dana piše; 91 dan nije pisac ali jest čitač';
end $$;

\echo '--- 4. revoked / pending / disputed / bez claima / tuđi kanal → not_owner; anon bez EXECUTE; bez sesije → login_required'
select pg_temp.pada(pg_temp.u('05')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), 'not_owner', 'status revoked');
select pg_temp.pada(pg_temp.u('06')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), 'not_owner', 'status pending');
select pg_temp.pada(pg_temp.u('07')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), 'not_owner', 'status disputed');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), 'not_owner', 'korisnik bez claima');
select pg_temp.pada(pg_temp.u('01')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('D1')), 'not_owner', 'primarni A1 na tuđem kanalu D1');
select pg_temp.pada('anon',
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), '#42501', 'anon zove set_channel_setting');
select pg_temp.pada('bez_sesije',
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', false)', pg_temp.uc('A1')), 'login_required', 'authenticated bez sub');
select pg_temp.pada('bez_sesije',
  format('select domovina_ai.set_channel_setting(%L, ''nepostojeci'', false)', pg_temp.uc('A1')), 'login_required',
  'redoslijed: login_required prije unknown_key');
do $$
declare f text; r text;
begin
  foreach f in array array['domovina_ai.set_channel_setting(text,text,boolean)',
    'domovina_ai.request_channel_deletion(text,text)', 'domovina_ai.cancel_channel_deletion(text)',
    'domovina_ai.confirm_channel_deletion_by_phone(uuid,text)',
    'domovina_ai.mark_channel_deletion_executed(uuid,text[])'] loop
    if has_function_privilege('anon', f, 'execute') then raise exception 'PAO TEST: anon ima EXECUTE na %', f; end if;
  end loop;
  foreach f in array array['domovina_ai.set_channel_setting(text,text,boolean)',
    'domovina_ai.request_channel_deletion(text,text)', 'domovina_ai.cancel_channel_deletion(text)'] loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'PAO TEST: authenticated nema EXECUTE na %', f;
    end if;
  end loop;
  foreach f in array array['domovina_ai.confirm_channel_deletion_by_phone(uuid,text)',
    'domovina_ai.mark_channel_deletion_executed(uuid,text[])'] loop
    if has_function_privilege('authenticated', f, 'execute') then
      raise exception 'PAO TEST: authenticated ima EXECUTE na %', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'PAO TEST: service_role nema EXECUTE na %', f;
    end if;
  end loop;
  foreach f in array array['domovina_ai.channel_effective_settings(text)'] loop
    foreach r in array array['anon','authenticated','service_role'] loop
      if not has_function_privilege(r, f, 'execute') then raise exception 'PAO TEST: % nema EXECUTE na %', r, f; end if;
    end loop;
  end loop;
  raise notice 'OK — EXECUTE: anon nijedan RPC, authenticated set/request/cancel, telefon/izvršenje samo service_role';
end $$;

\echo '--- 5. channel_settings_events je append-only (postgres, service_role, authenticated)'
select pg_temp.pada('postgres',
  format('update domovina_ai.channel_settings_events set note = ''x'' where youtube_channel_id = %L', pg_temp.uc('A1')),
  'append_only', 'UPDATE događaja kao postgres');
select pg_temp.pada('postgres',
  format('delete from domovina_ai.channel_settings_events where youtube_channel_id = %L', pg_temp.uc('A1')),
  'append_only', 'DELETE događaja kao postgres');
select pg_temp.pada('postgres', 'truncate domovina_ai.channel_settings_events',
  'append_only', 'TRUNCATE događaja kao postgres');
select pg_temp.pada('service',
  format('update domovina_ai.channel_settings_events set note = ''x'' where youtube_channel_id = %L', pg_temp.uc('A1')),
  'append_only|#42501', 'UPDATE događaja kao service_role');
select pg_temp.pada('service',
  format('delete from domovina_ai.channel_settings_events where youtube_channel_id = %L', pg_temp.uc('A1')),
  'append_only|#42501', 'DELETE događaja kao service_role');
select pg_temp.pada('service', 'truncate domovina_ai.channel_settings_events',
  'append_only|#42501', 'TRUNCATE događaja kao service_role');
select pg_temp.bez_ucinka(pg_temp.u('01')::text,
  format('update domovina_ai.channel_settings_events set note = ''x'' where youtube_channel_id = %L', pg_temp.uc('A1')),
  'UPDATE događaja kao vlasnik (authenticated)');
select pg_temp.bez_ucinka(pg_temp.u('01')::text,
  format('delete from domovina_ai.channel_settings_events where youtube_channel_id = %L', pg_temp.uc('A1')),
  'DELETE događaja kao vlasnik (authenticated)');
-- izravan INSERT ni na jednu novu tablicu
select pg_temp.pada(pg_temp.u('01')::text,
  format('insert into domovina_ai.channel_settings_events (youtube_channel_id, kind, key, source) values (%L, ''setting'', ''ebook'', ''app'')', pg_temp.uc('A1')),
  '#42501', 'INSERT događaja kao vlasnik');
select pg_temp.pada(pg_temp.u('01')::text,
  format('insert into domovina_ai.channel_settings (youtube_channel_id, settings) values (%L, ''{}'')', pg_temp.uc('A2')),
  '#42501', 'INSERT channel_settings kao authenticated');
select pg_temp.pada('anon',
  format('insert into domovina_ai.channel_settings (youtube_channel_id, settings) values (%L, ''{}'')', pg_temp.uc('A2')),
  '#42501', 'INSERT channel_settings kao anon');
select pg_temp.bez_ucinka(pg_temp.u('01')::text,
  format('update domovina_ai.channel_settings set settings = ''{"donations": false}'' where youtube_channel_id = %L', pg_temp.uc('A1')),
  'UPDATE channel_settings kao vlasnik (mimo RPC-a)');
select pg_temp.pada(pg_temp.u('01')::text,
  format('insert into domovina_ai.channel_tombstones (youtube_channel_id) values (%L)', pg_temp.uc('A2')),
  '#42501', 'INSERT tombstonea kao authenticated');
select pg_temp.pada(pg_temp.u('01')::text,
  format('insert into domovina_ai.channel_deletion_requests (youtube_channel_id, channel_title, requested_by, state) values (%L, ''x'', %L, ''requested'')', pg_temp.uc('A1'), pg_temp.u('01')),
  '#42501', 'INSERT zahtjeva za brisanje kao authenticated');
select pg_temp.pada(pg_temp.u('01')::text,
  format('insert into domovina_ai.channel_slugs (slug, youtube_channel_id) values (''test_postavke_otmica'', %L)', pg_temp.uc('A1')),
  '#42501', 'INSERT channel_slugs kao authenticated');
select pg_temp.bez_ucinka(pg_temp.u('01')::text,
  'update domovina_ai.channel_slugs set youtube_channel_id = youtube_channel_id where slug = ''domovina_tv''',
  'UPDATE channel_slugs (domovina_tv) kao authenticated');

\echo '--- 6. nepoznat ključ → unknown_key (i prije not_owner)'
select pg_temp.pada(pg_temp.u('01')::text,
  format('select domovina_ai.set_channel_setting(%L, ''nepostojeci'', false)', pg_temp.uc('A1')), 'unknown_key', 'pisac, nepoznat ključ');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.set_channel_setting(%L, ''nepostojeci'', false)', pg_temp.uc('A1')), 'unknown_key',
  'redoslijed: unknown_key prije not_owner');
select pg_temp.pada(pg_temp.u('01')::text,
  format('select domovina_ai.set_channel_setting(%L, ''Ebook'', false)', pg_temp.uc('A1')), 'unknown_key', 'ključ je osjetljiv na velika slova');
select pg_temp.pada('postgres',
  format('select domovina_ai.channel_setting_enabled(%L, ''nepostojeci'')', pg_temp.uc('A1')), 'unknown_key',
  'channel_setting_enabled s nepoznatim ključem');

\echo '--- 7. brisanje kanala: zahtjev, otkaz, telefon, izvršenje, tombstone'
-- D1 dobije jednu postavku prije brisanja (provjera unije u javnom pogledu, test 9)
do $$ begin
  perform pg_temp.postavi(pg_temp.u('09')::text, pg_temp.uc('D1'), 'ebook', false);
  raise notice 'OK — D1: postavka prije brisanja';
end $$;
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Krivi naziv'')', pg_temp.uc('D1')),
  'confirm_name_mismatch', 'zahtjev s krivim imenom');
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''testni kanal brisanja'')', pg_temp.uc('D1')),
  'confirm_name_mismatch', 'zahtjev s imenom drugih velikih slova');
select pg_temp.pada(pg_temp.u('0a')::text,
  format('select domovina_ai.request_channel_deletion(%L, '''')', pg_temp.uc('D1')),
  'confirm_name_mismatch', 'suradnik s praznim naslovom u claimu, prazno ime');
select pg_temp.pada(pg_temp.u('0a')::text,
  format('select domovina_ai.request_channel_deletion(%L, null)', pg_temp.uc('D1')),
  'confirm_name_mismatch', 'suradnik s praznim naslovom u claimu, null');
select pg_temp.pada(pg_temp.u('0a')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'confirm_name_mismatch', 'ime se uspoređuje s naslovom POZIVATELJEVOG claima');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'not_owner', 'zahtjev bez claima');
select pg_temp.pada(pg_temp.u('03')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal A'')', pg_temp.uc('A1')),
  'not_owner', 'zahtjev čitača (91 dan) koji nije pisac');
select pg_temp.pada('bez_sesije',
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'login_required', 'zahtjev bez sesije');
select pg_temp.pada('anon',
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  '#42501', 'anon zove request_channel_deletion');
do $$
declare r1 uuid; q domovina_ai.channel_deletion_requests;
begin
  r1 := pg_temp.izvrsi(pg_temp.u('09')::text,
    format('select domovina_ai.request_channel_deletion(%L, %L)', pg_temp.uc('D1'), '  Testni kanal brisanja  '))::uuid;
  select * into q from domovina_ai.channel_deletion_requests where id = r1;
  if q.id is null or q.state is distinct from 'requested' or q.youtube_channel_id is distinct from pg_temp.uc('D1')
     or q.channel_title is distinct from 'Testni kanal brisanja' or q.requested_by is distinct from pg_temp.u('09')
     or q.requested_role is distinct from 'primary' or q.requested_at is null then
    raise exception 'PAO TEST: zahtjev %', row_to_json(q);
  end if;
  raise notice 'OK — zahtjev (ime uz btrim) → % state=requested, naslov snimljen', r1;
end $$;
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'deletion_already_requested', 'drugi zahtjev dok je prvi otvoren');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.cancel_channel_deletion(%L)', pg_temp.uc('D1')),
  'not_owner', 'otkaz bez claima');
do $$
declare r1 uuid; rc uuid; q domovina_ai.channel_deletion_requests; r2 uuid;
begin
  select id into r1 from domovina_ai.channel_deletion_requests
   where youtube_channel_id = pg_temp.uc('D1') and state = 'requested';
  -- otkazuje DRUGI pisac (suradnik), ne onaj koji je tražio
  rc := pg_temp.izvrsi(pg_temp.u('0a')::text,
    format('select domovina_ai.cancel_channel_deletion(%L)', pg_temp.uc('D1')))::uuid;
  select * into q from domovina_ai.channel_deletion_requests where id = r1;
  if rc is distinct from r1 or q.state is distinct from 'cancelled' or q.cancelled_by is distinct from pg_temp.u('0a')
     or q.cancelled_at is null then
    raise exception 'PAO TEST: otkaz povrat=% red=%', rc, row_to_json(q);
  end if;
  raise notice 'OK — suradnik otkazao tuđi zahtjev, vraća id zahtjeva';
end $$;
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.cancel_channel_deletion(%L)', pg_temp.uc('D1')),
  'no_open_request', 'otkaz kad nema otvorenog zahtjeva');
do $$
declare r2 uuid;
begin
  r2 := pg_temp.izvrsi(pg_temp.u('09')::text,
    format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')))::uuid;
  if (select state from domovina_ai.channel_deletion_requests where id = r2) is distinct from 'requested' then
    raise exception 'PAO TEST: ponovni zahtjev';
  end if;
  raise notice 'OK — ponovni zahtjev nakon otkaza: %', r2;
end $$;
-- telefonska potvrda: samo service_role
do $$
declare r2 uuid;
begin
  select id into r2 from domovina_ai.channel_deletion_requests
   where youtube_channel_id = pg_temp.uc('D1') and state = 'requested';
  perform pg_temp.pada(pg_temp.u('09')::text,
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''x'')', r2), '#42501',
    'authenticated (vlasnik) zove confirm_channel_deletion_by_phone');
  perform pg_temp.pada('anon',
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''x'')', r2), '#42501',
    'anon zove confirm_channel_deletion_by_phone');
  perform pg_temp.pada(pg_temp.u('09')::text,
    format('select domovina_ai.mark_channel_deletion_executed(%L, ''{}'')', r2), '#42501',
    'authenticated zove mark_channel_deletion_executed');
  perform pg_temp.pada('service',
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''x'')', gen_random_uuid()), 'not_found',
    'telefonska potvrda nepostojećeg zahtjeva');
  perform pg_temp.pada('service',
    format('select domovina_ai.mark_channel_deletion_executed(%L, ''{}'')', r2), 'invalid_state',
    'izvršenje prije telefonske potvrde');
  perform pg_temp.izvrsi('service',
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, %L)', r2, 'Poziv 11.11. 12:00, potvrđeno'));
  if (select state || '|' || coalesce(phone_note, '') || '|' || (phone_confirmed_at is not null)::text
        from domovina_ai.channel_deletion_requests where id = r2)
     is distinct from 'phone_confirmed|Poziv 11.11. 12:00, potvrđeno|true' then
    raise exception 'PAO TEST: telefonska potvrda %',
      (select row_to_json(q) from domovina_ai.channel_deletion_requests q where id = r2);
  end if;
  raise notice 'OK — service_role: requested → phone_confirmed, bilješka i vrijeme zapisani';
  perform pg_temp.pada('service',
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''x'')', r2), 'invalid_state',
    'druga telefonska potvrda');
  -- otkazani r1 se ne može potvrditi
  perform pg_temp.pada('service',
    format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''x'')',
      (select id from domovina_ai.channel_deletion_requests where youtube_channel_id = pg_temp.uc('D1') and state = 'cancelled')),
    'invalid_state', 'telefonska potvrda otkazanog zahtjeva');
end $$;
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.cancel_channel_deletion(%L)', pg_temp.uc('D1')),
  'no_open_request', 'otkaz nakon telefonske potvrde');
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'deletion_already_requested', 'novi zahtjev dok je phone_confirmed otvoren');
do $$
declare r2 uuid; t domovina_ai.channel_tombstones; q domovina_ai.channel_deletion_requests;
begin
  select id into r2 from domovina_ai.channel_deletion_requests
   where youtube_channel_id = pg_temp.uc('D1') and state = 'phone_confirmed';
  perform pg_temp.izvrsi('service',
    format('select domovina_ai.mark_channel_deletion_executed(%L, %L::text[])', r2, '{test_postavke_brisanje}'));
  select * into q from domovina_ai.channel_deletion_requests where id = r2;
  select * into t from domovina_ai.channel_tombstones where youtube_channel_id = pg_temp.uc('D1');
  if q.state is distinct from 'executed' or q.executed_at is null then raise exception 'PAO TEST: zahtjev nakon izvršenja %', row_to_json(q); end if;
  if t.youtube_channel_id is null or t.channel_title is distinct from 'Testni kanal brisanja'
     or t.slugs is distinct from array['test_postavke_brisanje'] or t.request_id is distinct from r2
     or t.requested_at is distinct from q.requested_at or t.phone_confirmed_at is distinct from q.phone_confirmed_at
     or t.deleted_at is null then
    raise exception 'PAO TEST: tombstone %', row_to_json(t);
  end if;
  raise notice 'OK — izvršeno: tombstone (naslov, slugovi, request_id, vremena)';
  perform pg_temp.pada('service',
    format('select domovina_ai.mark_channel_deletion_executed(%L, ''{}'')', r2), 'invalid_state',
    'drugo izvršenje istog zahtjeva');
end $$;
-- događaji brisanja, redom
do $$
declare k text[]; s text[]; a uuid[];
begin
  select array_agg(kind order by id), array_agg(source order by id), array_agg(account_id order by id)
    into k, s, a from domovina_ai.channel_settings_events where youtube_channel_id = pg_temp.uc('D1');
  if k is distinct from array['setting','deletion_requested','deletion_cancelled','deletion_requested',
                              'deletion_phone_confirmed','deletion_executed'] then
    raise exception 'PAO TEST: vrste događaja %', k;
  end if;
  if s is distinct from array['app','app','app','app','phone','system'] then
    raise exception 'PAO TEST: izvori događaja %', s;
  end if;
  if a[2] is distinct from pg_temp.u('09') or a[3] is distinct from pg_temp.u('0a') then
    raise exception 'PAO TEST: account_id na događajima brisanja %', a;
  end if;
  raise notice 'OK — log brisanja: % / %', k, s;
end $$;
select pg_temp.pada('postgres',
  format('update domovina_ai.channel_tombstones set channel_title = ''x'' where youtube_channel_id = %L', pg_temp.uc('D1')),
  'tombstone_permanent', 'UPDATE tombstonea kao postgres');
select pg_temp.pada('postgres',
  format('delete from domovina_ai.channel_tombstones where youtube_channel_id = %L', pg_temp.uc('D1')),
  'tombstone_permanent', 'DELETE tombstonea kao postgres');
select pg_temp.pada('service',
  format('update domovina_ai.channel_tombstones set channel_title = ''x'' where youtube_channel_id = %L', pg_temp.uc('D1')),
  'tombstone_permanent|#42501', 'UPDATE tombstonea kao service_role');
select pg_temp.pada('service',
  format('delete from domovina_ai.channel_tombstones where youtube_channel_id = %L', pg_temp.uc('D1')),
  'tombstone_permanent|#42501', 'DELETE tombstonea kao service_role');
select pg_temp.pada(pg_temp.u('09')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', true)', pg_temp.uc('D1')),
  'channel_deleted', 'set_channel_setting nakon tombstonea');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.set_channel_setting(%L, ''ebook'', true)', pg_temp.uc('D1')),
  'channel_deleted', 'redoslijed: channel_deleted prije not_owner');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.set_channel_setting(%L, ''nepostojeci'', true)', pg_temp.uc('D1')),
  'unknown_key', 'redoslijed: unknown_key prije channel_deleted');
select pg_temp.pada(pg_temp.u('08')::text,
  format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal brisanja'')', pg_temp.uc('D1')),
  'channel_deleted', 'zahtjev za brisanje nakon tombstonea (prije not_owner)');
do $$
begin
  perform pg_temp.efektivno(pg_temp.uc('D1'), pg_temp.kljucevi(), 'tombstone D1 → svih 20 false');
  -- tombstone bez ijednog retka u channel_settings (D2) također gasi sve
  insert into domovina_ai.channel_tombstones (youtube_channel_id, channel_title) values (pg_temp.uc('D2'), 'Ručni tombstone');
  perform pg_temp.efektivno(pg_temp.uc('D2'), pg_temp.kljucevi(), 'tombstone bez postavki → svih 20 false');
  if domovina_ai.channel_setting_enabled_by_slug('test_postavke_brisanje', 'donations') is distinct from false then
    raise exception 'PAO TEST: by_slug za slug tombstoniranog kanala nije false';
  end if;
  raise notice 'OK — channel_setting_enabled_by_slug(slug tombstoniranog kanala) = false';
end $$;

\echo '--- 8. efektivno stanje: channel_enabled, transcript_subtitles, article_summary'
insert into domovina_ai.channel_settings (youtube_channel_id, settings) values
  (pg_temp.uc('E1'), '{"channel_enabled": false}'),
  (pg_temp.uc('E2'), '{"transcript_subtitles": false}'),
  (pg_temp.uc('E3'), '{"article_summary": false}'),
  (pg_temp.uc('E4'), '{"ebook": false, "donations": false}'),
  (pg_temp.uc('E5'), '{"channel_enabled": true, "transcript_subtitles": true}'),
  (pg_temp.uc('E6'), '{"article_summary": false, "transcript_subtitles": true, "ebook": true}');
do $$
begin
  perform pg_temp.efektivno(pg_temp.uc('E0'), '{}', 'nepoznat UC bez retka → sve true');
  perform pg_temp.efektivno(pg_temp.uc('E1'), pg_temp.kljucevi(), 'channel_enabled=false → svih 20 false');
  perform pg_temp.efektivno(pg_temp.uc('E2'), pg_temp.ai_kljucevi() || array['ebook','share_clips'],
    'transcript_subtitles=false → AI + ebook + share_clips false, ostalih 10 true');
  perform pg_temp.efektivno(pg_temp.uc('E3'),
    array['article_summary','ebook','magisterium','english_translation','share_clips','news_portal'],
    'article_summary=false → točno ebook, magisterium, english_translation, share_clips, news_portal');
  perform pg_temp.efektivno(pg_temp.uc('E4'), array['ebook','donations'], 'list (ebook, donations) ne povlači ništa');
  perform pg_temp.efektivno(pg_temp.uc('E5'), '{}', 'eksplicitni true');
  perform pg_temp.efektivno(pg_temp.uc('E6'),
    array['article_summary','ebook','magisterium','english_translation','share_clips','news_portal'],
    'article_summary=false nadjačava eksplicitni ebook=true');
  if domovina_ai.channel_setting_enabled_by_slug('test_postavke_nepostojeci_slug', 'donations') is distinct from true then
    raise exception 'PAO TEST: nepoznat slug nije true';
  end if;
  raise notice 'OK — channel_setting_enabled_by_slug(nepoznat slug) = true';
end $$;
do $$
declare v jsonb;
begin
  v := pg_temp.izvrsi('anon', format('select domovina_ai.channel_effective_settings(%L)', pg_temp.uc('E2')))::jsonb;
  if v is distinct from domovina_ai.channel_effective_settings(pg_temp.uc('E2')) then
    raise exception 'PAO TEST: anon dobiva drukčije efektivno stanje %', v;
  end if;
  v := pg_temp.izvrsi(pg_temp.u('08')::text, format('select domovina_ai.channel_effective_settings(%L)', pg_temp.uc('E1')))::jsonb;
  if v is distinct from pg_temp.ocekivano(pg_temp.kljucevi()) then
    raise exception 'PAO TEST: authenticated efektivno %', v;
  end if;
  raise notice 'OK — anon i authenticated čitaju channel_effective_settings';
end $$;

\echo '--- 9. javni pogledi (anon), log samo za čitače, RLS na događajima i zahtjevima'
do $$
declare c text[]; r record; n integer; t domovina_ai.channel_tombstones;
begin
  select array_agg(column_name::text order by column_name) into c from information_schema.columns
   where table_schema = 'domovina_ai' and table_name = 'public_channel_settings';
  if c is distinct from array['effective','settings','tombstoned','updated_at','youtube_channel_id'] then
    raise exception 'PAO TEST: kolone public_channel_settings %', c;
  end if;
  select array_agg(column_name::text order by column_name) into c from information_schema.columns
   where table_schema = 'domovina_ai' and table_name = 'public_channel_tombstones';
  if c is distinct from array['channel_title','deleted_at','phone_confirmed_at','requested_at','slugs','youtube_channel_id'] then
    raise exception 'PAO TEST: kolone public_channel_tombstones %', c;
  end if;
  raise notice 'OK — kolone javnih pogleda po ugovoru';

  -- A1: živ kanal s postavkama
  n := pg_temp.izvrsi('anon', format(
    'select count(*) from domovina_ai.public_channel_settings where youtube_channel_id = %L', pg_temp.uc('A1')))::int;
  if n <> 1 then raise exception 'PAO TEST: anon vidi % redaka za A1', n; end if;
  perform pg_temp.kao('anon');
  select * into r from domovina_ai.public_channel_settings where youtube_channel_id = pg_temp.uc('A1');
  perform pg_temp.kao('postgres');
  if r.tombstoned is distinct from false
     or r.settings is distinct from (select settings from domovina_ai.channel_settings where youtube_channel_id = pg_temp.uc('A1'))
     or r.effective is distinct from domovina_ai.channel_effective_settings(pg_temp.uc('A1'))
     or r.updated_at is distinct from (select updated_at from domovina_ai.channel_settings where youtube_channel_id = pg_temp.uc('A1')) then
    raise exception 'PAO TEST: public_channel_settings A1 %', row_to_json(r);
  end if;
  raise notice 'OK — anon: public_channel_settings A1 (settings rijedak, effective, tombstoned=false)';

  -- D1: i u channel_settings i u tombstoneima → JEDAN redak
  perform pg_temp.kao('anon');
  select count(*) into n from domovina_ai.public_channel_settings where youtube_channel_id = pg_temp.uc('D1');
  select * into r from domovina_ai.public_channel_settings where youtube_channel_id = pg_temp.uc('D1');
  perform pg_temp.kao('postgres');
  select * into t from domovina_ai.channel_tombstones where youtube_channel_id = pg_temp.uc('D1');
  if n <> 1 or r.tombstoned is distinct from true or r.updated_at is distinct from t.deleted_at
     or r.effective is distinct from pg_temp.ocekivano(pg_temp.kljucevi()) then
    raise exception 'PAO TEST: public_channel_settings D1 (n=%) %', n, row_to_json(r);
  end if;
  -- D2: samo tombstone
  perform pg_temp.kao('anon');
  select * into r from domovina_ai.public_channel_settings where youtube_channel_id = pg_temp.uc('D2');
  perform pg_temp.kao('postgres');
  if r.youtube_channel_id is null or r.tombstoned is distinct from true
     or r.updated_at is distinct from (select deleted_at from domovina_ai.channel_tombstones where youtube_channel_id = pg_temp.uc('D2')) then
    raise exception 'PAO TEST: public_channel_settings D2 %', row_to_json(r);
  end if;
  raise notice 'OK — anon: tombstone u public_channel_settings (jedan redak, tombstoned, updated_at=deleted_at, sve false)';

  perform pg_temp.kao('anon');
  select * into r from domovina_ai.public_channel_tombstones where youtube_channel_id = pg_temp.uc('D1');
  perform pg_temp.kao('postgres');
  if r.channel_title is distinct from 'Testni kanal brisanja' or r.slugs is distinct from array['test_postavke_brisanje']
     or r.deleted_at is distinct from t.deleted_at then
    raise exception 'PAO TEST: public_channel_tombstones %', row_to_json(r);
  end if;
  raise notice 'OK — anon: public_channel_tombstones D1';
end $$;
-- anon ne čita događaje
do $$
declare n integer; v_ok boolean := false;
begin
  begin
    perform pg_temp.kao('anon');
    select count(*) into n from domovina_ai.channel_settings_events;
    perform pg_temp.kao('postgres');
    if n = 0 then v_ok := true; end if;
  exception when insufficient_privilege then
    perform pg_temp.kao('postgres');
    v_ok := true; n := -1;
  end;
  if not v_ok then raise exception 'PAO TEST: anon čita % događaja', n; end if;
  raise notice 'OK — anon ne čita channel_settings_events (%)', case when n = -1 then 'permission denied' else '0 redaka' end;
end $$;
-- log kroz RPC, od najnovijeg
do $$
declare ids bigint[]; svi bigint[]; prva bigint[]; ispod bigint[]; n integer; n2 integer;
begin
  select array_agg(id order by id desc) into svi from domovina_ai.channel_settings_events
   where youtube_channel_id = pg_temp.uc('A1');
  ids := pg_temp.izvrsi(pg_temp.u('02')::text, format(
    'select array_agg(e.id order by e.ordinality) from rows from (domovina_ai.get_channel_settings_log(%L)) with ordinality e',
    pg_temp.uc('A1')))::bigint[];
  if ids is distinct from svi then raise exception 'PAO TEST: log % ≠ očekivano %', ids, svi; end if;
  raise notice 'OK — suradnik čita log A1 od najnovijeg (% događaja)', array_length(ids, 1);

  prva := pg_temp.izvrsi(pg_temp.u('02')::text, format(
    'select array_agg(e.id order by e.ordinality) from rows from (domovina_ai.get_channel_settings_log(%L, 2)) with ordinality e',
    pg_temp.uc('A1')))::bigint[];
  if prva is distinct from svi[1:2] then raise exception 'PAO TEST: p_limit=2 → %', prva; end if;
  ispod := pg_temp.izvrsi(pg_temp.u('02')::text, format(
    'select array_agg(e.id order by e.ordinality) from rows from (domovina_ai.get_channel_settings_log(%L, 100, %s)) with ordinality e',
    pg_temp.uc('A1'), svi[1]))::bigint[];
  if ispod is distinct from svi[2:] then raise exception 'PAO TEST: p_before → % (očekivano %)', ispod, svi[2:]; end if;
  raise notice 'OK — log: p_limit i p_before (kursor) rade';

  ids := pg_temp.izvrsi(pg_temp.u('03')::text, format(
    'select array_agg(e.id order by e.ordinality) from rows from (domovina_ai.get_channel_settings_log(%L)) with ordinality e',
    pg_temp.uc('A1')))::bigint[];
  if ids is distinct from svi then raise exception 'PAO TEST: čitač 91 dan ne vidi log'; end if;
  raise notice 'OK — čitač s claimom starim 91 dan čita log';

  -- RLS select na događajima: čitač vidi svoje, ne-čitač ništa
  n := pg_temp.izvrsi(pg_temp.u('02')::text, format(
    'select count(*) from domovina_ai.channel_settings_events where youtube_channel_id = %L', pg_temp.uc('A1')))::int;
  n2 := pg_temp.izvrsi(pg_temp.u('02')::text, format(
    'select count(*) from domovina_ai.channel_settings_events where youtube_channel_id = %L', pg_temp.uc('D1')))::int;
  if n <> array_length(svi, 1) or n2 <> 0 then
    raise exception 'PAO TEST: RLS događaja: A1=% (očekivano %), D1=%', n, array_length(svi, 1), n2;
  end if;
  n := pg_temp.izvrsi(pg_temp.u('08')::text, 'select count(*) from domovina_ai.channel_settings_events')::int;
  if n <> 0 then raise exception 'PAO TEST: korisnik bez claima vidi % događaja', n; end if;
  raise notice 'OK — RLS događaja: čitač vidi svoj kanal, ne tuđi; bez claima 0';

  -- zahtjevi za brisanje: čitač kanala vidi, drugi ne
  n := pg_temp.izvrsi(pg_temp.u('0a')::text, format(
    'select count(*) from domovina_ai.channel_deletion_requests where youtube_channel_id = %L', pg_temp.uc('D1')))::int;
  n2 := pg_temp.izvrsi(pg_temp.u('08')::text, 'select count(*) from domovina_ai.channel_deletion_requests')::int;
  if n <> 2 or n2 <> 0 then raise exception 'PAO TEST: RLS zahtjeva: čitač %, bez claima %', n, n2; end if;
  raise notice 'OK — RLS zahtjeva za brisanje: čitač D1 vidi 2, bez claima 0';
end $$;
select pg_temp.pada(pg_temp.u('08')::text,
  format('select * from domovina_ai.get_channel_settings_log(%L)', pg_temp.uc('A1')), 'not_owner', 'log za ne-vlasnika');
select pg_temp.pada(pg_temp.u('05')::text,
  format('select * from domovina_ai.get_channel_settings_log(%L)', pg_temp.uc('A1')), 'not_owner', 'log za revoked');
select pg_temp.pada(pg_temp.u('06')::text,
  format('select * from domovina_ai.get_channel_settings_log(%L)', pg_temp.uc('A1')), 'not_owner', 'log za pending');
select pg_temp.pada('anon',
  format('select * from domovina_ai.get_channel_settings_log(%L)', pg_temp.uc('A1')), '#42501|not_owner|login_required', 'log za anon');

\echo '--- 10. novac: donations, paid_sponsor_moments, izlog, živi trenuci, tombstone'
-- fixturei: kampanje vezane na slug test_postavke_kanala (→ M1) i epizode
insert into domovina_ai.episode_safes (episode_id, youtube_channel_id, safe_address, chain_id)
values ('tpkEpizoda1', pg_temp.uc('M1'), '0x000000000000000000000000000000000000c5e1', 100)
on conflict (episode_id) do update set youtube_channel_id = excluded.youtube_channel_id;
delete from domovina_ai.episode_safes where episode_id = 'tpkEpizoda2';

insert into pinka_finance.campaigns (id, account_id, slug, type, title, subject_type, subject_ref,
                                     min_contribution_cents, currency, destination_address, chain,
                                     state, visibility)
select v.id::uuid, a.id, v.slug, v.type::pinka_finance.campaign_type, v.title, v.st, v.sr, 100, 'EUR',
       '0x000000000000000000000000000000000000c5c5', 'gnosis', 'active', v.vis::pinka_finance.campaign_visibility
  from public.accounts a,
       (values ('00000000-0000-4000-8000-0000000c5d01', 'test-postavke-donacija', 'donation', 'Test postavke: donacija kanala',
                'podcast_channel', 'test_postavke_kanala', 'public'),
               ('00000000-0000-4000-8000-0000000c5d02', 'test-postavke-epizoda', 'donation', 'Test postavke: donacija epizode',
                'podcast_episode', 'tpkEpizoda1', 'public'),
               ('00000000-0000-4000-8000-0000000c5d03', 'test-postavke-epizoda-bez', 'donation', 'Test postavke: epizoda bez mapiranja',
                'podcast_episode', 'tpkEpizoda2', 'public'),
               ('00000000-0000-4000-8000-0000000c5d04', 'test-postavke-sponzor', 'crowdfund', 'Test postavke: sponzorski trenuci',
                'podcast_channel', 'test_postavke_kanala', 'unlisted')) v(id, slug, type, title, st, sr, vis)
 where a.primary_owner_user_id = pg_temp.u('0b') and a.is_personal_account
on conflict (id) do update set state = 'active', deleted_at = null,
  subject_type = excluded.subject_type, subject_ref = excluded.subject_ref;

update pinka_finance.slots s
   set state = 'free', contribution_id = null, holder_account_id = null,
       hold_session_key = null, hold_expires_at = null, live_from = null, live_until = null
  from pinka_finance.slot_maps m
 where m.id = s.map_id and m.campaign_id = '00000000-0000-4000-8000-0000000c5d04';
delete from pinka_finance.contribution_events where campaign_id in
  ('00000000-0000-4000-8000-0000000c5d01','00000000-0000-4000-8000-0000000c5d02',
   '00000000-0000-4000-8000-0000000c5d03','00000000-0000-4000-8000-0000000c5d04');
delete from pinka_finance.contributions where campaign_id in
  ('00000000-0000-4000-8000-0000000c5d01','00000000-0000-4000-8000-0000000c5d02',
   '00000000-0000-4000-8000-0000000c5d03','00000000-0000-4000-8000-0000000c5d04');
select pinka_finance.seed_timeline_map('00000000-0000-4000-8000-0000000c5d04',
  '[{"index":0,"price_cents":1000,"run_days":30,"label_key":"sponsorZoneTijelo"}]'::jsonb) is not null as karta;
select pinka_finance.seed_timeline_episode('00000000-0000-4000-8000-0000000c5d04', 'tpkVideo001', 0::smallint,
  '[{"start":10,"end":100,"zone":0,"title":"Test trenutak 1"},
    {"start":100,"end":200,"zone":0,"title":"Test trenutak 2"},
    {"start":200,"end":300,"zone":0,"title":"Test trenutak 3"}]'::jsonb) as trenutaka;

-- donacija kao zadana uloga; vraća contribution_id
create or replace function pg_temp.doniraj_sql(p_campaign text, p_amount integer) returns text language sql as $$
  select format('select contribution_id from pinka_finance.create_contribution(p_campaign_id => %L::uuid, p_amount_cents => %s)',
                p_campaign, p_amount)
$$;
create or replace function pg_temp.sponzor_sql(p_keys text[]) returns text language sql as $$
  select format('select contribution_id from pinka_finance.create_sponsor_contribution(%L::uuid, %L::text[], %L, null, null, null, %L::jsonb, true)',
                '00000000-0000-4000-8000-0000000c5d04', p_keys, 'Test brand d.o.o.',
                '{"company":"Test brand d.o.o.","email":"racuni@example.com"}')
$$;

do $$
declare n integer;
begin
  select count(*) into n from pinka_finance.public_sponsor_moments
   where campaign_id = '00000000-0000-4000-8000-0000000c5d04';
  if n <> 3 then raise exception 'PAO TEST (fixture): izlog testne kampanje ima % trenutaka', n; end if;
  perform pg_temp.postavi(pg_temp.u('0b')::text, pg_temp.uc('M1'), 'donations', false);
  if domovina_ai.channel_setting_enabled_by_slug('test_postavke_kanala', 'donations') is distinct from false then
    raise exception 'PAO TEST: by_slug(test_postavke_kanala, donations) nije false';
  end if;
  raise notice 'OK — M1 donations=false; by_slug kroz channel_slugs = false';
end $$;
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 500),
  'donations_disabled', 'donacija kanalu s donations=false');
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 1),
  'donations_disabled', 'provjera je na početku (prije amount_below_minimum)');
select pg_temp.pada('service', pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 500),
  'donations_disabled', 'gostujuća grana (service_role, bez sub)');
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d02', 500),
  'donations_disabled', 'donacija epizodi kanala (episode_safes → M1)');
do $$
declare v uuid;
begin
  v := pg_temp.izvrsi(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d03', 500))::uuid;
  if v is null then raise exception 'PAO TEST: donacija epizodi bez mapiranja nije stvorena'; end if;
  raise notice 'OK — epizoda bez mapiranja u episode_safes: donacija dopuštena';
  -- sponzorski checkout ide kroz paid_sponsor_moments, ne donations
  v := pg_temp.izvrsi(pg_temp.u('08')::text, pg_temp.sponzor_sql(array['tpkVideo001@10']))::uuid;
  perform pinka_finance.attach_intent(v, 'sid_tpk_' || current_setting('test.run'), null, now() + interval '24 hours');
  if not pinka_finance.mark_contribution_paid('sid_tpk_' || current_setting('test.run'), '0xc5', 1000, null, null, null) then
    raise exception 'PAO TEST (fixture): sponzorska uplata nije označena';
  end if;
  if not exists (select 1 from pinka_finance.public_live_moments
                  where youtube_id = 'tpkVideo001' and slot_key = 'tpkVideo001@10') then
    raise exception 'PAO TEST (fixture): prodan trenutak nije živ';
  end if;
  raise notice 'OK — donations=false ne blokira sponzorski checkout; trenutak @10 prodan i živ';
end $$;
do $$
declare v uuid;
begin
  perform pg_temp.postavi(pg_temp.u('0b')::text, pg_temp.uc('M1'), 'donations', true);
  v := pg_temp.izvrsi(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 500))::uuid;
  if v is null then raise exception 'PAO TEST: donacija nakon donations=true'; end if;
  v := pg_temp.izvrsi('service', pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d02', 500))::uuid;
  if v is null then raise exception 'PAO TEST: gostujuća donacija epizodi nakon donations=true'; end if;
  raise notice 'OK — donations=true: donacija kanalu i gostujuća donacija epizodi prolaze';
end $$;
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 1),
  'amount_below_minimum', 'donations=true prolazi do sljedeće provjere');
do $$ begin
  perform pg_temp.postavi(pg_temp.u('0b')::text, pg_temp.uc('M1'), 'paid_sponsor_moments', false);
  raise notice 'OK — M1 paid_sponsor_moments=false';
end $$;
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.sponzor_sql(array['tpkVideo001@100']),
  'sponsor_moments_disabled', 'sponzorski checkout s paid_sponsor_moments=false');
do $$
declare n integer; v uuid;
begin
  n := pg_temp.izvrsi('anon', $q$select count(*) from pinka_finance.public_sponsor_moments
                                 where campaign_id = '00000000-0000-4000-8000-0000000c5d04'$q$)::int;
  if n <> 0 then raise exception 'PAO TEST: izlog pokazuje % trenutaka kanala s isključenom ponudom', n; end if;
  raise notice 'OK — izlog ne pokazuje kanal s paid_sponsor_moments=false';
  n := pg_temp.izvrsi('anon', $q$select count(*) from pinka_finance.public_live_moments
                                 where youtube_id = 'tpkVideo001' and slot_key = 'tpkVideo001@10'$q$)::int;
  if n <> 1 then raise exception 'PAO TEST: već prodan trenutak nestao iz public_live_moments (%)', n; end if;
  raise notice 'OK — već prodan trenutak ostaje živ do live_until unatoč isključenom ključu';
  -- reverzibilno
  perform pg_temp.postavi(pg_temp.u('0b')::text, pg_temp.uc('M1'), 'paid_sponsor_moments', true);
  n := pg_temp.izvrsi('anon', $q$select count(*) from pinka_finance.public_sponsor_moments
                                 where campaign_id = '00000000-0000-4000-8000-0000000c5d04'$q$)::int;
  if n <> 3 then raise exception 'PAO TEST: izlog nakon ponovnog uključenja ima %', n; end if;
  v := pg_temp.izvrsi(pg_temp.u('08')::text, pg_temp.sponzor_sql(array['tpkVideo001@100']))::uuid;
  raise notice 'OK — ponovno uključeno: izlog 3 trenutka, checkout prolazi';
end $$;
-- tombstone kanala skida i već prodan trenutak i gasi donacije
do $$
declare r uuid; n integer;
begin
  r := pg_temp.izvrsi(pg_temp.u('0b')::text,
    format('select domovina_ai.request_channel_deletion(%L, ''Testni kanal novca'')', pg_temp.uc('M1')))::uuid;
  perform pg_temp.izvrsi('service', format('select domovina_ai.confirm_channel_deletion_by_phone(%L, ''test'')', r));
  perform pg_temp.izvrsi('service',
    format('select domovina_ai.mark_channel_deletion_executed(%L, %L::text[])', r, '{test_postavke_kanala}'));
  n := pg_temp.izvrsi('anon', $q$select count(*) from pinka_finance.public_live_moments
                                 where youtube_id = 'tpkVideo001'$q$)::int;
  if n <> 0 then raise exception 'PAO TEST: tombstonirani kanal i dalje pokazuje % živih trenutaka', n; end if;
  n := pg_temp.izvrsi('anon', $q$select count(*) from pinka_finance.public_sponsor_moments
                                 where campaign_id = '00000000-0000-4000-8000-0000000c5d04'$q$)::int;
  if n <> 0 then raise exception 'PAO TEST: tombstonirani kanal u izlogu (%)', n; end if;
  raise notice 'OK — tombstone M1: nema živih trenutaka ni izloga';
end $$;
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.doniraj_sql('00000000-0000-4000-8000-0000000c5d01', 500),
  'donations_disabled', 'donacija tombstoniranom kanalu');
select pg_temp.pada(pg_temp.u('08')::text, pg_temp.sponzor_sql(array['tpkVideo001@200']),
  'sponsor_moments_disabled', 'sponzorski checkout tombstoniranom kanalu');

do $$ begin raise notice 'SVE PROVJERE PROŠLE'; end $$;
