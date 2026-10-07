-- Provjera migracija 20261007120000 (sponzorski trenuci) i …120100 (seed).
--
-- Pokretanje nad lokalnim stackom (idempotentno — briše svoj trag na početku):
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20261007_sponzorski_trenuci.sql
--
-- Očekivano: NOTICE redci "OK — …" i na kraju "SVE PROVJERE PROŠLE".
-- Svaki drugi ishod je pad. Paralelna rezervacija (409) je u zasebnoj skripti
-- supabase/tests/20261007_sponzorski_trenuci_utrka.sh (treba stvarne procese).
\set ON_ERROR_STOP on
\timing off

-- ── priprema: referentna donacijska kampanja (lokalno je nema) ──────────────
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-4000-8000-0000000051a1', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'test-sponzor-vlasnik@example.com', crypt('demo1234', gen_salt('bf')),
        now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into pinka_finance.campaigns (account_id, slug, type, title, subject_type, subject_ref,
                                     min_contribution_cents, currency, destination_address, chain,
                                     state, visibility)
select a.id, 'podrzi-domovina-podcast', 'donation', 'Podrži DOMOVINA podcast (lokalni fixture)',
       'podcast_channel', 'domovina_tv', 100, 'EUR',
       '0x6693a7D19486Dc45e9F90Fd2D515d972bBA2d65e', 'gnosis', 'active', 'public'
  from public.accounts a
 where a.primary_owner_user_id = '00000000-0000-4000-8000-0000000051a1' and a.is_personal_account
   and not exists (select 1 from pinka_finance.campaigns where slug = 'podrzi-domovina-podcast');

\ir ../migrations/20261007120100_sponzorski_trenuci_seed.sql

-- ── čišćenje prethodnog prolaza ─────────────────────────────────────────────
update pinka_finance.slots s
   set state = 'free', contribution_id = null, holder_account_id = null,
       hold_session_key = null, hold_expires_at = null
  from pinka_finance.slot_maps m
 where m.id = s.map_id and m.campaign_id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';
delete from pinka_finance.contribution_events
 where campaign_id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';
delete from pinka_finance.contributions
 where campaign_id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';
-- storage.protect_delete brani direktan delete; testni objekti smiju van.
set storage.allow_delete_query = 'true';
delete from storage.objects where bucket_id = 'sponsor-logos'
   and name like '00000000-0000-4000-8000-0000000051b%';
reset storage.allow_delete_query;

insert into storage.objects (bucket_id, name, metadata)
values ('sponsor-logos', '00000000-0000-4000-8000-0000000051b1/logo.png',
        '{"size": 1200, "mimetype": "image/png"}'::jsonb),
       ('sponsor-logos', '00000000-0000-4000-8000-0000000051b1/velik.png',
        '{"size": 300000, "mimetype": "image/png"}'::jsonb);

-- Pomoćnik: checkout kao zadani korisnik (authenticated, anonimna sesija).
create or replace function pg_temp.kupi(p_user uuid, p_keys text[], p_overrides jsonb default '{}')
returns uuid language plpgsql as $$
declare v_id uuid; b jsonb;
begin
  b := jsonb_build_object(
    'brand', 'Primjer d.o.o.', 'tagline', 'Jedna rečenica.', 'link_url', 'https://primjer.hr',
    'logo_path', null, 'terms', true,
    'buyer', jsonb_build_object('company', 'Primjer d.o.o.', 'oib', '12345678903',
                                'email', 'racuni@primjer.hr',
                                'address', jsonb_build_object('street', 'Ilica 1', 'city', 'Zagreb',
                                                              'postal_code', '10000'))) || p_overrides;
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  select contribution_id into v_id from pinka_finance.create_sponsor_contribution(
    '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101', p_keys, b->>'brand', b->>'tagline', b->>'link_url',
    b->>'logo_path', b->'buyer', (b->>'terms')::boolean);
  perform set_config('role', 'postgres', true);
  return v_id;
exception when others then
  perform set_config('role', 'postgres', true);
  raise;
end $$;

create or replace function pg_temp.ocekuj_gresku(p_user uuid, p_keys text[], p_overrides jsonb, p_err text)
returns void language plpgsql as $$
begin
  begin
    perform pg_temp.kupi(p_user, p_keys, p_overrides);
  exception when others then
    if sqlerrm not like p_err || '%' then raise exception 'PAO TEST: očekivano %, dobiveno %', p_err, sqlerrm; end if;
    raise notice 'OK — odbijeno: %', sqlerrm;
    return;
  end;
  raise exception 'PAO TEST: prošlo bez greške, očekivano %', p_err;
end $$;

\echo '--- 1. seed: 79 trenutaka u 7 epizoda, svi slobodni u izlogu'
do $$
declare n integer; e integer; f integer;
begin
  select count(*), count(distinct youtube_id), count(*) filter (where state = 'free')
    into n, e, f from pinka_finance.public_sponsor_moments
   where campaign_id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';
  if n <> 79 or e <> 7 or f <> 79 then raise exception 'PAO TEST: n=% e=% free=%', n, e, f; end if;
  raise notice 'OK — % trenutaka, % epizoda', n, e;
  if exists (select 1 from pinka_finance.slots where youtube_id is not null and end_sec <= start_sec) then
    raise exception 'PAO TEST: trenutak s end <= start';
  end if;
end $$;

\echo '--- 2. OIB kontrolna znamenka'
do $$
begin
  if not pinka_finance.oib_valid('12345678903') then raise exception 'PAO TEST: valjan OIB odbijen'; end if;
  if pinka_finance.oib_valid('12345678901') then raise exception 'PAO TEST: neispravan OIB prihvaćen'; end if;
  if pinka_finance.oib_valid('1234567890') then raise exception 'PAO TEST: 10 znamenki prihvaćeno'; end if;
  raise notice 'OK — oib_valid';
end $$;

\echo '--- 3. validacija checkouta'
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"buyer":{"company":"X","oib":"12345678901","email":"a@b.hr"}}', 'invalid_sponsor:buyer_oib');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"link_url":"http://primjer.hr"}', 'invalid_sponsor:link_url');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"link_url":"javascript:alert(1)"}', 'invalid_sponsor:link_url');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"terms":false}', 'invalid_sponsor:terms');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"brand":"  "}', 'invalid_sponsor:brand');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
       '{"logo_path":"00000000-0000-4000-8000-0000000051b1/velik.png"}', 'invalid_sponsor:logo_path');
-- tuđa mapa: put drugog korisnika
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b2', array['WRE248YCIeI@33'],
       '{"logo_path":"00000000-0000-4000-8000-0000000051b1/logo.png"}', 'invalid_sponsor:logo_path');
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@34'],
       '{}', 'invalid_slot_keys');
-- anon (bez sesije) ne smije uopće zvati RPC
do $$
begin
  perform set_config('role', 'anon', true);
  begin
    perform pinka_finance.create_sponsor_contribution('7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101',
      array['WRE248YCIeI@33'], 'X', null, null, null, '{}'::jsonb, true);
    raise exception 'PAO TEST: anon je prošao';
  exception when insufficient_privilege then
    raise notice 'OK — anon nema execute';
  end;
  perform set_config('role', 'postgres', true);
end $$;

\echo '--- 4. ispravan checkout: hold, iznos određuje server, held ne curi'
do $$
declare v_id uuid; c pinka_finance.contributions; n integer;
begin
  v_id := pg_temp.kupi('00000000-0000-4000-8000-0000000051b1', array['WRE248YCIeI@33'],
                       '{"logo_path":"00000000-0000-4000-8000-0000000051b1/logo.png"}');
  select * into c from pinka_finance.contributions where id = v_id;
  -- WRE248YCIeI@33 je 'otvaranje' = zona 2 = 8000 (placeholder)
  if c.amount_cents <> 8000 or not c.is_sponsor or c.display_name <> 'Primjer d.o.o.'
     or c.buyer_oib <> '12345678903' or c.buyer_address->>'country' <> 'HR' or c.anonymous then
    raise exception 'PAO TEST: doprinos %', row_to_json(c);
  end if;
  if (select state from pinka_finance.public_sponsor_moments where slot_key = 'WRE248YCIeI@33') <> 'held' then
    raise exception 'PAO TEST: izlog ne pokazuje held';
  end if;
  select count(*) into n from pinka_finance.public_live_moments;
  if n <> 0 then raise exception 'PAO TEST: held curi u public_live_moments (%)', n; end if;
  perform pinka_finance.attach_intent(v_id, 'sid_test_puno', null, now() + interval '24 hours');
  raise notice 'OK — hold, 80 €, nije u živom viewu';
end $$;

\echo '--- 5. drugi kupac na isti trenutak → slot_taken (409)'
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b2', array['WRE248YCIeI@33'],
       '{}', 'slot_taken');

\echo '--- 6. MANJAK: uplata < cijena ne dodjeljuje trenutak'
do $$
declare v_id uuid; c pinka_finance.contributions; r boolean;
begin
  v_id := pg_temp.kupi('00000000-0000-4000-8000-0000000051b2', array['WRE248YCIeI@220'], '{}');
  perform pinka_finance.attach_intent(v_id, 'sid_test_manjak', null, now() + interval '24 hours');
  r := pinka_finance.mark_contribution_paid('sid_test_manjak', '0xabc', 100, null, null, null);
  select * into c from pinka_finance.contributions where id = v_id;
  if not r or c.state <> 'failed' or not c.underpaid or c.amount_received_cents <> 100 then
    raise exception 'PAO TEST: manjak r=% state=% underpaid=%', r, c.state, c.underpaid;
  end if;
  if exists (select 1 from pinka_finance.slots where slot_key = 'WRE248YCIeI@220' and state <> 'free') then
    raise exception 'PAO TEST: trenutak nije otpušten nakon manjka';
  end if;
  if not exists (select 1 from pinka_finance.contribution_events
                  where contribution_id = v_id and event_type = 'contribution.underpaid') then
    raise exception 'PAO TEST: nema eventa za alarm';
  end if;
  -- retry istog webhooka: ništa novo
  r := pinka_finance.mark_contribution_paid('sid_test_manjak', '0xabc', 100, null, null, null);
  if r then raise exception 'PAO TEST: retry manjka vratio true'; end if;
  if (select count(*) from pinka_finance.contribution_events
       where contribution_id = v_id and event_type = 'contribution.underpaid') <> 1 then
    raise exception 'PAO TEST: retry je dupao event manjka';
  end if;
  -- nepoznat iznos (null) se također ne smatra plaćenim
  v_id := pg_temp.kupi('00000000-0000-4000-8000-0000000051b2', array['WRE248YCIeI@220'], '{}');
  perform pinka_finance.attach_intent(v_id, 'sid_test_null', null, now() + interval '24 hours');
  r := pinka_finance.mark_contribution_paid('sid_test_null', '0xabd', null, null, null, null);
  if (select state::text || underpaid::text from pinka_finance.contributions where id = v_id) <> 'failedtrue' then
    raise exception 'PAO TEST: null iznos je dodijelio trenutak';
  end if;
  raise notice 'OK — manjak: failed + underpaid, trenutak slobodan, jedan event';
end $$;

\echo '--- 7. puna uplata: sold, live_until = +run_days, vidljivo u živom viewu'
do $$
declare v_id uuid; s pinka_finance.slots; r boolean; m record;
begin
  select id into v_id from pinka_finance.contributions where payment_intent_sid = 'sid_test_puno';
  r := pinka_finance.mark_contribution_paid('sid_test_puno', '0xdef', 8000, null, null, null);
  if not r then raise exception 'PAO TEST: puna uplata nije označena'; end if;
  select * into s from pinka_finance.slots where slot_key = 'WRE248YCIeI@33';
  if s.state <> 'sold' or s.contribution_id <> v_id
     or s.live_from is null or abs(extract(epoch from (s.live_until - s.live_from)) - 30*86400) > 1 then
    raise exception 'PAO TEST: slot %', row_to_json(s);
  end if;
  select * into m from pinka_finance.public_live_moments where slot_key = 'WRE248YCIeI@33';
  if m.brand <> 'Primjer d.o.o.' or m.link_url <> 'https://primjer.hr' or m.start_sec <> 33
     or m.logo_url not like '%/sponsor-logos/00000000-0000-4000-8000-0000000051b1/logo.png' then
    raise exception 'PAO TEST: živi view %', row_to_json(m);
  end if;
  if (select live_until from pinka_finance.public_sponsor_moments where slot_key = 'WRE248YCIeI@33') is null then
    raise exception 'PAO TEST: izlog ne pokazuje do kada je zauzeto';
  end if;
  -- dupli intent.paid
  r := pinka_finance.mark_contribution_paid('sid_test_puno', '0xdef', 8000, null, null, null);
  if r then raise exception 'PAO TEST: dupli intent.paid vratio true'; end if;
  raise notice 'OK — sold do %, živi view: %', s.live_until, m.brand;
end $$;

\echo '--- 8. javni viewovi nemaju kolone kupca ni iznosa'
do $$
declare v text;
begin
  select string_agg(table_name || '.' || column_name, ', ') into v
    from information_schema.columns
   where table_schema = 'pinka_finance'
     and table_name in ('public_live_moments', 'public_sponsor_moments')
     and (column_name like 'buyer%' or column_name like '%email%' or column_name like '%oib%'
          or column_name like 'amount%' or column_name like 'invoice%' or column_name = 'hold_session_key');
  if v is not null then raise exception 'PAO TEST: curi %', v; end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'pinka_finance' and table_name = 'public_live_moments') <> 11 then
    raise exception 'PAO TEST: public_live_moments ima kolone izvan ugovora';
  end if;
  -- anon čita oba viewa, a contributions ne
  perform set_config('role', 'anon', true);
  perform count(*) from pinka_finance.public_live_moments;
  perform count(*) from pinka_finance.public_sponsor_moments;
  begin
    perform buyer_oib from pinka_finance.contributions limit 1;
    raise exception 'PAO TEST: anon čita contributions';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  raise notice 'OK — bez buyer_*/iznosa; anon vidi viewove, ne vidi contributions';
end $$;

\echo '--- 9. račun: lease ima JEDNOG pobjednika; nakon sent nema ponovnog izdavanja'
do $$
declare v_id uuid; n1 integer; n2 integer;
begin
  select id into v_id from pinka_finance.contributions where payment_intent_sid = 'sid_test_puno';
  select count(*) into n1 from pinka_finance.sponsor_invoice_lease(v_id, 120);
  select count(*) into n2 from pinka_finance.sponsor_invoice_lease(v_id, 120);
  if n1 <> 1 or n2 <> 0 then raise exception 'PAO TEST: lease n1=% n2=%', n1, n2; end if;
  perform pinka_finance.sponsor_invoice_record(v_id, 'issued', 41, 'R-1/1/1', null);
  -- issued još nije sent → smije se nastaviti (slanje)
  select count(*) into n1 from pinka_finance.sponsor_invoice_lease(v_id, 120);
  if n1 <> 1 then raise exception 'PAO TEST: issued se ne može nastaviti'; end if;
  perform pinka_finance.sponsor_invoice_record(v_id, 'sent', null, null, null);
  select count(*) into n1 from pinka_finance.sponsor_invoice_lease(v_id, 120);
  if n1 <> 0 then raise exception 'PAO TEST: sent je ponovno uzet'; end if;
  if v_id in (select pinka_finance.sponsor_invoices_due(100)) then
    raise exception 'PAO TEST: sent je u redu za retry';
  end if;
  if (select invoice_racun_id from pinka_finance.contributions where id = v_id) <> 41 then
    raise exception 'PAO TEST: racun id izgubljen';
  end if;
  -- underpaid i pending doprinosi nikad ne dobivaju račun
  if exists (select 1 from pinka_finance.contributions c
              where c.campaign_id = '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101' and c.underpaid
                and c.id in (select pinka_finance.sponsor_invoices_due(100))) then
    raise exception 'PAO TEST: underpaid u redu za račun';
  end if;
  raise notice 'OK — lease 1/0, issued→sent, nema ponovnog izdavanja';
end $$;

\echo '--- 10. povlačenje: message_hidden skida trenutak iz živog viewa'
do $$
declare v_id uuid;
begin
  select id into v_id from pinka_finance.contributions where payment_intent_sid = 'sid_test_puno';
  perform pinka_finance.sponsor_set_hidden(v_id, true);
  if exists (select 1 from pinka_finance.public_live_moments where slot_key = 'WRE248YCIeI@33') then
    raise exception 'PAO TEST: povučen trenutak je i dalje živ';
  end if;
  if not (select hidden from pinka_finance.sponsor_order_status(v_id)) then
    raise exception 'PAO TEST: status ne pokazuje hidden';
  end if;
  perform pinka_finance.sponsor_set_hidden(v_id, false);
  raise notice 'OK — povučen i vraćen';
end $$;

\echo '--- 11. ISTEK: istekli zakup je odmah free u izlogu, žetva ga vraća, opet se prodaje'
do $$
declare v_id uuid; n integer; v_new uuid;
begin
  select id into v_id from pinka_finance.contributions where payment_intent_sid = 'sid_test_puno';
  update pinka_finance.slots
     set live_from = now() - interval '31 days', live_until = now() - interval '1 day'
   where slot_key = 'WRE248YCIeI@33';
  if (select state from pinka_finance.public_sponsor_moments where slot_key = 'WRE248YCIeI@33') <> 'free' then
    raise exception 'PAO TEST: istekli zakup nije free u izlogu';
  end if;
  if exists (select 1 from pinka_finance.public_live_moments where slot_key = 'WRE248YCIeI@33') then
    raise exception 'PAO TEST: istekli zakup je u živom viewu';
  end if;
  n := pinka_finance.expire_live_slots();
  if n <> 1 then raise exception 'PAO TEST: expire_live_slots vratio %', n; end if;
  if exists (select 1 from pinka_finance.slots where slot_key = 'WRE248YCIeI@33'
              and (state <> 'free' or contribution_id is not null or live_until is not null)) then
    raise exception 'PAO TEST: slot nije čisto vraćen u free';
  end if;
  if not exists (select 1 from pinka_finance.contribution_events
                  where contribution_id = v_id and event_type = 'slot.expired') then
    raise exception 'PAO TEST: nema slot.expired eventa';
  end if;
  -- doprinos ostaje plaćen (povijest), trenutak je opet prodajan
  v_new := pg_temp.kupi('00000000-0000-4000-8000-0000000051b2', array['WRE248YCIeI@33'], '{}');
  raise notice 'OK — istek: free, event, ponovno prodano (%)', v_new;
end $$;

\echo '--- 12. istekli zakup koji cron NIJE počistio ne blokira prodaju'
do $$
declare v_id uuid;
begin
  update pinka_finance.slots
     set state = 'sold', contribution_id = (select id from pinka_finance.contributions
                                             where payment_intent_sid = 'sid_test_puno')
   where slot_key = 'WRE248YCIeI@890';
  update pinka_finance.slots
     set live_from = now() - interval '31 days', live_until = now() - interval '1 second'
   where slot_key = 'WRE248YCIeI@890';
  v_id := pg_temp.kupi('00000000-0000-4000-8000-0000000051b3', array['WRE248YCIeI@890'], '{}');
  raise notice 'OK — checkout sam počisti istekli zakup';
end $$;

\echo '--- 13. kasna uplata na istekli intent (H2) dodjeljuje trenutak'
do $$
declare v_id uuid;
begin
  v_id := pg_temp.kupi('00000000-0000-4000-8000-0000000051b4', array['fO7iltytw0I@44'], '{}');
  perform pinka_finance.attach_intent(v_id, 'sid_test_kasno', null, now() + interval '24 hours');
  update pinka_finance.contributions set state = 'expired' where id = v_id;
  update pinka_finance.slots set hold_expires_at = now() - interval '1 hour' where contribution_id = v_id;
  if not pinka_finance.mark_contribution_paid('sid_test_kasno', '0x111', 8000, null, null, null) then
    raise exception 'PAO TEST: kasna uplata odbijena';
  end if;
  if (select state from pinka_finance.slots where slot_key = 'fO7iltytw0I@44') <> 'sold' then
    raise exception 'PAO TEST: kasna uplata nije dobila trenutak';
  end if;
  raise notice 'OK — kasna uplata: sold';
end $$;

\echo '--- 14. donacija bez mjesta s manjkom ostaje plaćena (stari put netaknut)'
do $$
declare v_id uuid;
begin
  insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address,
                                           payment_intent_sid)
  select id, 1000, 'EUR', 'pending', destination_address, 'sid_test_donacija'
    from pinka_finance.campaigns where slug = 'podrzi-domovina-podcast'
  returning id into v_id;
  if not pinka_finance.mark_contribution_paid('sid_test_donacija', '0x222', 900, null, null, null) then
    raise exception 'PAO TEST: donacija nije označena';
  end if;
  if (select state from pinka_finance.contributions where id = v_id) <> 'paid' then
    raise exception 'PAO TEST: donacija s manjkom nije paid';
  end if;
  delete from pinka_finance.contribution_events where contribution_id = v_id;
  delete from pinka_finance.contributions where id = v_id;
  raise notice 'OK — donacija netaknuta';
end $$;

\echo '--- 15. upload loga: samo u vlastitu mapu, samo slikovne ekstenzije'
do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-0000000051b5","role":"authenticated"}', true);
  insert into storage.objects (bucket_id, name, owner_id)
  values ('sponsor-logos', '00000000-0000-4000-8000-0000000051b5/moj.webp', '00000000-0000-4000-8000-0000000051b5');
  begin
    insert into storage.objects (bucket_id, name, owner_id)
    values ('sponsor-logos', '00000000-0000-4000-8000-0000000051b1/tudi.png', '00000000-0000-4000-8000-0000000051b5');
    raise exception 'PAO TEST: upload u tuđu mapu';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into storage.objects (bucket_id, name, owner_id)
    values ('sponsor-logos', '00000000-0000-4000-8000-0000000051b5/skripta.svg', '00000000-0000-4000-8000-0000000051b5');
    raise exception 'PAO TEST: svg prošao';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  raise notice 'OK — RLS uploada: vlastita mapa da, tuđa ne, svg ne';
end $$;

\echo '--- 16. snapshot prodanih trenutaka preživi istek (račun/status nakon isteka)'
do $$
declare v_id uuid; v jsonb;
begin
  select id into v_id from pinka_finance.contributions where payment_intent_sid = 'sid_test_puno';
  -- zakup @33 je istekao u testu 11 → slots.contribution_id je obrisan
  if exists (select 1 from pinka_finance.slots where contribution_id = v_id and slot_key = 'WRE248YCIeI@33') then
    raise exception 'PAO TEST: priprema — slot još veže doprinos';
  end if;
  -- (test 12 je ručno vezao i @890 uz isti doprinos — zato filtar po ključu)
  select e into v from pinka_finance.contributions c, jsonb_array_elements(c.sold_slots) e
   where c.id = v_id and e->>'slot_key' = 'WRE248YCIeI@33';
  if v is null or (v->>'price_cents')::int <> 8000 or v->>'live_until' is null or (v->>'start_sec')::int <> 33 then
    raise exception 'PAO TEST: sold_slots %', v;
  end if;
  if (select count(*) from pinka_finance.contributions c, jsonb_array_elements(c.sold_slots) e
       where c.id = v_id and e->>'slot_key' = 'WRE248YCIeI@33') <> 1 then
    raise exception 'PAO TEST: snapshot dupliran';
  end if;
  raise notice 'OK — sold_slots snapshot preživio istek: %', v->>'slot_key';
end $$;

\echo '--- 17. limit holdova: 3 po sesiji'
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b6',
       array['AoXN-3Mkmew@190','AoXN-3Mkmew@1010','AoXN-3Mkmew@1620','AoXN-3Mkmew@10'], '{}', 'invalid_slot_keys');
do $$
begin
  perform pg_temp.kupi('00000000-0000-4000-8000-0000000051b6', array['AoXN-3Mkmew@190','AoXN-3Mkmew@1010'], '{}');
  perform pg_temp.kupi('00000000-0000-4000-8000-0000000051b6', array['AoXN-3Mkmew@1620'], '{}');
end $$;
select pg_temp.ocekuj_gresku('00000000-0000-4000-8000-0000000051b6', array['oxq1U0xypu8@15'], '{}', 'too_many_holds');

\echo '--- 18. GRID: nepoznat iznos i uplata iznad cijene kvadratića ostaju plaćeni (H2 netaknut)'
do $$
declare v_camp uuid; v_id uuid;
begin
  select id into v_camp from pinka_finance.campaigns where slug = 'test-grid-sponzor';
  if v_camp is null then
    insert into pinka_finance.campaigns (account_id, slug, type, title, subject_type, min_contribution_cents,
                                         currency, destination_address, chain, state, visibility)
    select account_id, 'test-grid-sponzor', 'donation', 'Test grid', 'none', 100, 'EUR',
           destination_address, chain, 'active', 'public'
      from pinka_finance.campaigns where slug = 'podrzi-domovina-podcast'
    returning id into v_camp;
    perform pinka_finance.seed_grid_map(v_camp, 4, array[100, 200]);
  end if;
  update pinka_finance.slots s set state = 'free', contribution_id = null, hold_session_key = null,
         hold_expires_at = null, holder_account_id = null
    from pinka_finance.slot_maps m where m.id = s.map_id and m.campaign_id = v_camp;
  delete from pinka_finance.contributions where campaign_id = v_camp;

  -- (a) obećano 5000 za kvadratić od 100, stiglo 300 → kvadratić ostaje
  insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address)
  select v_camp, 5000, 'EUR', 'pending', destination_address from pinka_finance.campaigns where id = v_camp
  returning id into v_id;
  perform pinka_finance.reserve_slots(v_id, array['0:0'], 600);
  update pinka_finance.contributions set payment_intent_sid = 'sid_test_grid_a' where id = v_id;
  perform pinka_finance.mark_contribution_paid('sid_test_grid_a', '0x1', 300, null, null, null);
  if (select state from pinka_finance.contributions where id = v_id) <> 'paid'
     or (select state from pinka_finance.slots s join pinka_finance.slot_maps m on m.id = s.map_id
          where m.campaign_id = v_camp and s.slot_key = '0:0') <> 'sold' then
    raise exception 'PAO TEST: grid uplata iznad cijene kvadratića odbijena';
  end if;

  -- (b) nepoznat iznos (null) → staro ponašanje: paid
  insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address)
  select v_camp, 100, 'EUR', 'pending', destination_address from pinka_finance.campaigns where id = v_camp
  returning id into v_id;
  perform pinka_finance.reserve_slots(v_id, array['1:0'], 600);
  update pinka_finance.contributions set payment_intent_sid = 'sid_test_grid_b' where id = v_id;
  perform pinka_finance.mark_contribution_paid('sid_test_grid_b', '0x2', null, null, null, null);
  if (select state from pinka_finance.contributions where id = v_id) <> 'paid' then
    raise exception 'PAO TEST: grid s nepoznatim iznosom nije paid';
  end if;

  -- (c) stvarni manjak ispod cijene kvadratića → underpaid
  insert into pinka_finance.contributions (campaign_id, amount_cents, currency, state, destination_address)
  select v_camp, 100, 'EUR', 'pending', destination_address from pinka_finance.campaigns where id = v_camp
  returning id into v_id;
  perform pinka_finance.reserve_slots(v_id, array['2:0'], 600);
  update pinka_finance.contributions set payment_intent_sid = 'sid_test_grid_c' where id = v_id;
  perform pinka_finance.mark_contribution_paid('sid_test_grid_c', '0x3', 50, null, null, null);
  if (select state::text || underpaid::text from pinka_finance.contributions where id = v_id) <> 'failedtrue' then
    raise exception 'PAO TEST: grid manjak ispod cijene nije underpaid';
  end if;
  raise notice 'OK — grid: iznad cijene paid, null paid, ispod cijene underpaid';
end $$;

\echo '--- 19. anonimna sesija ne smije kupiti sponzorski trenutak ni uploadati logo'
do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-0000000051b7","role":"authenticated","is_anonymous":true}', true);
  begin
    perform pinka_finance.create_sponsor_contribution('7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101',
      array['oxq1U0xypu8@255'], 'X', null, null, null,
      '{"company":"X","email":"x@example.com"}'::jsonb, true);
    raise exception 'PAO TEST: anonimna sesija je kupila trenutak';
  exception when others then
    if sqlerrm <> 'login_required' then raise exception 'PAO TEST: kriva greška %', sqlerrm; end if;
  end;
  begin
    insert into storage.objects (bucket_id, name, owner_id)
    values ('sponsor-logos', '00000000-0000-4000-8000-0000000051b7/logo.png', '00000000-0000-4000-8000-0000000051b7');
    raise exception 'PAO TEST: anonimna sesija je uploadala logo';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  raise notice 'OK — anonimna sesija: login_required, upload odbijen';
end $$;

\echo '--- 20. limit gostiju po ključu i prozoru'
do $$
declare a boolean; b boolean; c boolean; d boolean;
begin
  delete from pinka_finance.guest_rate_hits where key like 'test:%';
  a := pinka_finance.guest_rate_hit('test:ip1', 2, 3600);
  b := pinka_finance.guest_rate_hit('test:ip1', 2, 3600);
  c := pinka_finance.guest_rate_hit('test:ip1', 2, 3600);
  d := pinka_finance.guest_rate_hit('test:ip2', 2, 3600);
  if not (a and b and not c and d) then raise exception 'PAO TEST: limit % % % %', a, b, c, d; end if;
  -- provjera bez brojanja ne troši kvotu
  if pinka_finance.guest_rate_hit('test:ip3', 1, 3600, false) is not true
     or pinka_finance.guest_rate_hit('test:ip3', 1, 3600, false) is not true
     or exists (select 1 from pinka_finance.guest_rate_hits where key = 'test:ip3') then
    raise exception 'PAO TEST: p_count=false je potrošio kvotu';
  end if;
  perform pinka_finance.guest_rate_hit('test:ip3', 1, 3600, true);
  if pinka_finance.guest_rate_hit('test:ip3', 1, 3600, false) then
    raise exception 'PAO TEST: provjera ne vidi potrošenu kvotu';
  end if;
  perform set_config('role', 'anon', true);
  begin
    perform pinka_finance.guest_rate_hit('test:x', 1, 60);
    raise exception 'PAO TEST: anon smije zvati guest_rate_hit';
  exception when insufficient_privilege then null;
  end;
  perform set_config('role', 'postgres', true);
  delete from pinka_finance.guest_rate_hits where key like 'test:%';
  raise notice 'OK — limit gostiju: 2/2 prolaze, treći ne, drugi ključ neovisan';
end $$;

\echo 'SVE PROVJERE PROŠLE'
