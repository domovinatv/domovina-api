-- Provjera migracija 20260903120000 (rail gate) i 20260903120100 (rotacija QR).
--
-- Pokretanje nad lokalnim stackom (idempotentno — briše svoj trag na početku):
--   psql "postgresql://postgres:postgres@127.0.0.1:55322/postgres" \
--        -f supabase/tests/20260903_rail_gate_i_rotacija.sql
--
-- Očekivano: osam NOTICE redaka koji počinju s "OK —" i na kraju
-- "SVE PROVJERE PROŠLE". Svaki drugi ishod je pad.
\set ON_ERROR_STOP on
\timing off

-- Skripta mora biti ponovljiva: obriši trag prethodnog prolaza prije svega,
-- inače drugi run kreće s railom koji je zadnji korak ostavio uključenim.
delete from pinka_finance.tickets where contribution_id = '00000000-0000-4000-8000-00000000ac01';
delete from pinka_finance.contribution_events where contribution_id = '00000000-0000-4000-8000-00000000ac01';
delete from pinka_finance.contributions where id = '00000000-0000-4000-8000-00000000ac01';
delete from pinka_finance.organizer_payment_rails where account_id = '00000000-0000-4000-8000-00000000aa02';
delete from pinka_finance.campaign_tiers where campaign_id in ('00000000-0000-4000-8000-00000000af01','00000000-0000-4000-8000-00000000af02');
delete from pinka_finance.events where campaign_id in ('00000000-0000-4000-8000-00000000af01','00000000-0000-4000-8000-00000000af02');
delete from pinka_finance.campaigns where id in ('00000000-0000-4000-8000-00000000af01','00000000-0000-4000-8000-00000000af02');

-- ── priprema: organizator BEZ Safea, s radnim Stripeom ──────────────────────
insert into auth.users (id, instance_id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values ('00000000-0000-4000-8000-00000000aa01', '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'test-rail@example.com', crypt('demo1234', gen_salt('bf')),
        now(), now(), now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb)
on conflict (id) do nothing;

insert into public.accounts (id, primary_owner_user_id, is_personal_account, slug, name)
values ('00000000-0000-4000-8000-00000000aa02', '00000000-0000-4000-8000-00000000aa01',
        false, 'test-udruga-rail', 'Test udruga (rail gate)')
on conflict (id) do nothing;

insert into public.accounts_memberships (account_id, user_id, account_role)
values ('00000000-0000-4000-8000-00000000aa02', '00000000-0000-4000-8000-00000000aa01', 'admin')
on conflict do nothing;

insert into pinka_finance.organizer_allowlist (account_id, note)
values ('00000000-0000-4000-8000-00000000aa02', 'test rail gate')
on conflict (account_id) do nothing;

-- događaj s NULTOM adresom (organizator nema i neće imati Safe)
select pinka_finance.create_event(
  p_id                  => '00000000-0000-4000-8000-00000000af01',
  p_account_id          => '00000000-0000-4000-8000-00000000aa02',
  p_title               => 'Test događaj bez Safea',
  p_destination_address => '0x0000000000000000000000000000000000000000',
  p_venue_name          => 'Dvorana',
  p_venue_city          => 'Varaždin',
  p_event_type          => 'susret',
  p_tiers               => '[{"title":"Redovna","price_cents":14900,"inventory_total":10}]'::jsonb
);

\echo '--- 1. BEZ Stripe raila: objava mora pasti s event_no_working_rail'
do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000aa01","role":"authenticated"}', true);
  begin
    perform pinka_finance.publish_event('00000000-0000-4000-8000-00000000af01', 'active');
    raise exception 'PAO TEST: objava je prošla bez ijednog raila';
  exception when others then
    if sqlerrm not like '%event_no_working_rail%' then
      raise exception 'PAO TEST: kriva greška: %', sqlerrm;
    end if;
    raise notice 'OK — odbijeno: %', sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
end $$;

\echo '--- 2. SA Stripe railom (charges_enabled): objava mora proći'
insert into pinka_finance.organizer_payment_rails
  (account_id, stripe_account_id, stripe_charges_enabled, stripe_payouts_enabled, invoice_provider)
values ('00000000-0000-4000-8000-00000000aa02', 'acct_1TestRailGate', true, true, 'fira')
on conflict (account_id) do update set stripe_charges_enabled = true;

do $$
declare v jsonb;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000aa01","role":"authenticated"}', true);
  v := pinka_finance.publish_event('00000000-0000-4000-8000-00000000af01', 'active');
  if v->>'state' <> 'active' then raise exception 'PAO TEST: %', v; end if;
  raise notice 'OK — objavljeno bez Safea: %', v;
  perform set_config('role', 'postgres', true);
end $$;

\echo '--- 3. charges_enabled = false → događaj se NE smije moći objaviti'
update pinka_finance.campaigns set state = 'draft', visibility = 'private'
 where id = '00000000-0000-4000-8000-00000000af01';
update pinka_finance.organizer_payment_rails set stripe_charges_enabled = false
 where account_id = '00000000-0000-4000-8000-00000000aa02';

do $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    '{"sub":"00000000-0000-4000-8000-00000000aa01","role":"authenticated"}', true);
  begin
    perform pinka_finance.publish_event('00000000-0000-4000-8000-00000000af01', 'active');
    raise exception 'PAO TEST: objava prošla s charges_enabled=false';
  exception when others then
    if sqlerrm not like '%event_no_working_rail%' then
      raise exception 'PAO TEST: kriva greška: %', sqlerrm;
    end if;
    raise notice 'OK — odbijeno kad Stripe ne prima uplate: %', sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
end $$;

\echo '--- 4. event_rail_ready: donacije i dalje traže Safe, ulaznice ne'
-- (test 3 je rail ugasio; ovdje ga vraćamo jer se provjerava razlika po TIPU
-- kampanje, ne po stanju Stripea)
update pinka_finance.organizer_payment_rails set stripe_charges_enabled = true
 where account_id = '00000000-0000-4000-8000-00000000aa02';
do $$
declare
  v_acc uuid := '00000000-0000-4000-8000-00000000aa02';
  v_nula text := '0x0000000000000000000000000000000000000000';
  v_safe text := '0x1111111111111111111111111111111111111111';
begin
  -- ticketing + radan Stripe, bez Safea → prolazi
  if not pinka_finance.event_rail_ready(v_acc, 'tickets', v_nula) then
    raise exception 'PAO TEST: ticketing sa Stripeom mora proći';
  end if;
  -- DONACIJA + isti Stripe rail, bez Safea → NE prolazi (Stripe rail ne vrijedi
  -- za donacije; novac tamo ide onchain na Safe)
  if pinka_finance.event_rail_ready(v_acc, 'donation', v_nula) then
    raise exception 'PAO TEST: donacija bez Safea NE SMIJE proći';
  end if;
  -- donacija s pravim Safeom → prolazi (staro pravilo netaknuto)
  if not pinka_finance.event_rail_ready(v_acc, 'donation', v_safe) then
    raise exception 'PAO TEST: donacija sa Safeom mora proći';
  end if;
  -- ticketing bez ijednog raila (drugi account) → ne prolazi
  if pinka_finance.event_rail_ready('00000000-0000-4000-8000-0000000000ff', 'tickets', v_nula) then
    raise exception 'PAO TEST: bez ijednog raila ne smije proći';
  end if;
  raise notice 'OK — Stripe rail vrijedi SAMO za tickets; donacije i dalje traže Safe';
end $$;

-- ── rotacija tokena ─────────────────────────────────────────────────────────
\echo '--- 5. rotate_ticket_tokens: novi token, stari hash prestaje vrijediti'
update pinka_finance.organizer_payment_rails set stripe_charges_enabled = true
 where account_id = '00000000-0000-4000-8000-00000000aa02';

insert into pinka_finance.contributions
  (id, campaign_id, tier_id, state, quantity, amount_cents, currency, reserved,
   destination_address, payment_rail, external_payment_ref, buyer_email, paid_at)
select '00000000-0000-4000-8000-00000000ac01',
       '00000000-0000-4000-8000-00000000af01', t.id, 'paid', 2, 29800, 'eur', true,
       '0x0000000000000000000000000000000000000000',
       'stripe', 'pi_test_rotacija', 'kupac@example.com', now()
  from pinka_finance.campaign_tiers t
 where t.campaign_id = '00000000-0000-4000-8000-00000000af01'
 limit 1
on conflict (id) do nothing;

insert into pinka_finance.tickets
  (contribution_id, campaign_id, tier_id, serial, holder_name, qr_token_hash, qr_token_once, state)
select '00000000-0000-4000-8000-00000000ac01', '00000000-0000-4000-8000-00000000af01', t.id,
       'TST-00000' || g, 'Holder ' || g,
       encode(extensions.digest('stari-token-' || g, 'sha256'), 'hex'), null, 'issued'
  from pinka_finance.campaign_tiers t, generate_series(1, 2) g
 where t.campaign_id = '00000000-0000-4000-8000-00000000af01'
on conflict do nothing;

do $$
declare
  v jsonb;
  v_stari text[];
  v_novi text[];
  v_plaintext integer;
begin
  select array_agg(qr_token_hash order by serial) into v_stari
    from pinka_finance.tickets where contribution_id = '00000000-0000-4000-8000-00000000ac01';

  v := pinka_finance.rotate_ticket_tokens('00000000-0000-4000-8000-00000000ac01');
  if v->>'status' <> 'rotated' then raise exception 'PAO TEST: %', v; end if;
  if (v->>'rotated')::int <> 2 then raise exception 'PAO TEST: rotirano %', v->>'rotated'; end if;
  if jsonb_array_length(v->'tickets') <> 2 then raise exception 'PAO TEST: nema tokena u odgovoru'; end if;
  if (v->'tickets'->0->>'qr_token') is null then raise exception 'PAO TEST: token je null'; end if;

  select array_agg(qr_token_hash order by serial) into v_novi
    from pinka_finance.tickets where contribution_id = '00000000-0000-4000-8000-00000000ac01';
  if v_stari = v_novi then raise exception 'PAO TEST: hash se nije promijenio — stari QR bi i dalje radio'; end if;

  select count(*) into v_plaintext from pinka_finance.tickets
   where contribution_id = '00000000-0000-4000-8000-00000000ac01' and qr_token_once is not null;
  if v_plaintext <> 0 then raise exception 'PAO TEST: plaintext ostao u bazi'; end if;

  raise notice 'OK — rotirano 2, stari hashevi mrtvi, plaintext obrisan';
end $$;

\echo '--- 6. iskorištena ulaznica se NE rotira'
update pinka_finance.tickets set state = 'checked_in', checked_in_at = now()
 where contribution_id = '00000000-0000-4000-8000-00000000ac01';
do $$
declare v jsonb;
begin
  v := pinka_finance.rotate_ticket_tokens('00000000-0000-4000-8000-00000000ac01');
  if v->>'status' <> 'nothing_to_rotate' then raise exception 'PAO TEST: %', v; end if;
  raise notice 'OK — %', v->>'status';
end $$;

\echo '--- 7. tvrdi limit 5/24 h'
update pinka_finance.tickets set state = 'issued', checked_in_at = null
 where contribution_id = '00000000-0000-4000-8000-00000000ac01';
do $$
declare v jsonb; i int;
begin
  for i in 1..4 loop
    v := pinka_finance.rotate_ticket_tokens('00000000-0000-4000-8000-00000000ac01');
    if v->>'status' <> 'rotated' then raise exception 'PAO TEST na rotaciji %: %', i, v; end if;
  end loop;
  v := pinka_finance.rotate_ticket_tokens('00000000-0000-4000-8000-00000000ac01');
  if v->>'status' <> 'rate_limited' then raise exception 'PAO TEST: limit nije proradio: %', v; end if;
  raise notice 'OK — šesta rotacija odbijena: %', v;
end $$;

\echo '--- 8. neplaćena narudžba se ne rotira'
do $$
declare v jsonb;
begin
  update pinka_finance.contributions set state = 'pending'
   where id = '00000000-0000-4000-8000-00000000ac01';
  v := pinka_finance.rotate_ticket_tokens('00000000-0000-4000-8000-00000000ac01');
  if v->>'status' <> 'order_not_paid' then raise exception 'PAO TEST: %', v; end if;
  raise notice 'OK — %', v->>'status';
  v := pinka_finance.rotate_ticket_tokens('99999999-9999-4999-8999-999999999999');
  if v->>'status' <> 'order_not_found' then raise exception 'PAO TEST: %', v; end if;
  raise notice 'OK — nepostojeća narudžba: %', v->>'status';
end $$;

\echo 'SVE PROVJERE PROŠLE'
