-- =============================================================================
-- Sponzorski trenuci — samoposlužna prodaja trenutka u epizodi (MVP domovina_tv)
--
-- Ugovor prema frontendu: docs/sponzorski-trenuci-ugovor.md (izvor istine za
-- kolone viewova, potpis checkouta, stanja i kodove grešaka).
-- Nadograđuje 20260722120000_pinka_slots.sql — reserve_slots,
-- claim_slots_for_contribution i tg_contribution_state se NE diraju.
--
--   1. 'timeline' vrsta karte; slots.youtube_id/start_sec/end_sec
--   2. trajanje zakupa: slot_zones.run_days, slots.live_from/live_until
--      (trigger ih postavlja na prijelaz u 'sold'), expire_live_slots()
--   3. PROVJERA IZNOSA: mark_contribution_paid za kupnju mjesta s manjkom →
--      state 'failed' + underpaid, mjesto se otpušta, event za alarm
--   4. kreativa + podaci kupca na contributions; create_sponsor_contribution
--   5. viewovi public_sponsor_moments (izlog) i public_live_moments (prikaz)
--   6. stanje računa (fiskal) + lease RPC-ovi za webhook i retry
--   7. bucket sponsor-logos
--
-- ODLUKA (ugovor O1): jedna kampanja, jedna timeline karta za SVE epizode;
-- epizoda je slots.youtube_id. unique(campaign_id) na slot_maps OSTAJE, jer
-- reserve/claim/mark_paid — put novca — kartu traže po campaign_id.
--
-- 'timeline' je nova vrijednost enuma i ne smije se KORISTITI u istoj
-- transakciji u kojoj je dodana ("unsafe use of new value"). Zato viewovi i
-- funkcije uspoređuju kind::text, a seed živi u zasebnoj migraciji.
-- =============================================================================

alter type pinka_finance.slot_map_kind add value if not exists 'timeline';

-- ----- 1. timeline polja na mjestu -------------------------------------------
-- pos_x/pos_y su smallint za 2D crtanje (≤ 500) — NISU sekunde. Timeline ih
-- puni rednim brojem (pos_x = trenutak u epizodi, pos_y = epizoda).
alter table pinka_finance.slots
  add column if not exists youtube_id text,
  add column if not exists start_sec  integer,
  add column if not exists end_sec    integer,
  add column if not exists live_from  timestamptz,
  add column if not exists live_until timestamptz;

alter table pinka_finance.slots
  drop constraint if exists slots_timeline_shape,
  drop constraint if exists slots_youtube_id_format,
  drop constraint if exists slots_live_shape;

alter table pinka_finance.slots
  -- sve tri kolone zajedno ili nijedna; trenutak traje barem sekundu
  add constraint slots_timeline_shape check (
    (youtube_id is null and start_sec is null and end_sec is null) or
    (youtube_id is not null and start_sec >= 0 and end_sec > start_sec)),
  add constraint slots_youtube_id_format check (
    youtube_id is null or youtube_id ~ '^[A-Za-z0-9_-]{11}$'),
  -- zakup postoji samo dok je mjesto prodano
  add constraint slots_live_shape check (
    (live_from is null and live_until is null) or
    (state in ('sold','minted') and live_from is not null and live_until > live_from));

create index if not exists ix_slots_youtube
  on pinka_finance.slots(map_id, youtube_id, start_sec) where youtube_id is not null;

-- Istek zakupa (expire_live_slots) i javni view živih trenutaka.
create index if not exists ix_slots_live_until
  on pinka_finance.slots(live_until) where state = 'sold' and live_until is not null;

-- ----- 2. trajanje zakupa ----------------------------------------------------
alter table pinka_finance.slot_zones
  add column if not exists run_days smallint;

alter table pinka_finance.slot_zones
  drop constraint if exists slot_zones_run_days;
alter table pinka_finance.slot_zones
  add constraint slot_zones_run_days check (run_days is null or run_days between 1 and 366);

comment on column pinka_finance.slot_zones.run_days is
  'Koliko dana kupljeno mjesto traje. null = zauvijek (grid, sjedala).';

-- live_from/live_until se postavljaju TRIGGEROM na prijelaz u 'sold', a ne u
-- claim_slots_for_contribution. Tako ih dobije svaki put do 'sold' (kept,
-- reclaimed, relocated), a funkcija kroz koju prolazi novac ostaje netaknuta.
create or replace function pinka_finance.tg_slot_live() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_days smallint;
begin
  if new.state = 'sold' and old.state is distinct from 'sold' then
    select z.run_days into v_days from pinka_finance.slot_zones z where z.id = new.zone_id;
    if v_days is not null then
      new.live_from  := now();
      new.live_until := now() + make_interval(days => v_days);
    end if;
    if new.youtube_id is not null and new.contribution_id is not null then
      update pinka_finance.contributions
         set sold_slots = coalesce(sold_slots, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
               'slot_key', new.slot_key, 'youtube_id', new.youtube_id,
               'start_sec', new.start_sec, 'end_sec', new.end_sec, 'label', new.label,
               'price_cents', new.price_cents, 'live_from', new.live_from, 'live_until', new.live_until))
       where id = new.contribution_id
         and not coalesce(sold_slots, '[]'::jsonb) @> jsonb_build_array(jsonb_build_object('slot_key', new.slot_key));
    end if;
  elsif new.state not in ('sold','minted') then
    new.live_from  := null;
    new.live_until := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_slots_live on pinka_finance.slots;
create trigger trg_slots_live
  before update of state on pinka_finance.slots
  for each row execute function pinka_finance.tg_slot_live();

-- Istekli zakup → 'free'. Ispravnost NE ovisi o ovome (view gleda live_until,
-- create_sponsor_contribution ovo zove prije rezervacije); cron je higijena.
create or replace function pinka_finance.expire_live_slots()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  -- Kandidati se zaključavaju PRIJE updatea da bi se sačuvao stari
  -- contribution_id (RETURNING vidi već obrisanu vrijednost).
  with cand as (
    select s.id, s.slot_key, s.contribution_id, m.campaign_id
      from pinka_finance.slots s
      join pinka_finance.slot_maps m on m.id = s.map_id
     where s.state = 'sold'
       and s.live_until is not null
       and s.live_until <= now()
       for update of s skip locked
  ), expired as (
    update pinka_finance.slots s
       set state = 'free', contribution_id = null, holder_account_id = null,
           hold_session_key = null, hold_expires_at = null,
           relocated_from_slot_key = null, updated_at = now()
      from cand
     where s.id = cand.id
    returning cand.slot_key, cand.contribution_id, cand.campaign_id
  ), ev as (
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    select e.contribution_id, e.campaign_id, 'slot.expired', jsonb_build_object('slot_key', e.slot_key)
      from expired e
     where e.contribution_id is not null
  )
  select count(*) into v_n from expired;
  return v_n;
end;
$$;
revoke execute on function pinka_finance.expire_live_slots() from public, anon, authenticated;
grant  execute on function pinka_finance.expire_live_slots() to service_role;

-- ----- 3. kreativa, kupac, račun na doprinosu --------------------------------
alter table pinka_finance.contributions
  add column if not exists is_sponsor        boolean not null default false,
  add column if not exists link_url          text,
  add column if not exists logo_path         text,
  add column if not exists buyer_company     text,
  add column if not exists buyer_oib         text,
  add column if not exists buyer_vat_id      text,
  add column if not exists buyer_address     jsonb,
  add column if not exists buyer_reference   text,
  add column if not exists terms_accepted_at timestamptz,
  -- uplata manja od cijene kupnje mjesta (state = 'failed'); ručni povrat
  add column if not exists underpaid         boolean not null default false,
  add column if not exists owner_notified_at timestamptz,
  add column if not exists owner_notify_attempts integer not null default 0,
  -- Snapshot prodanih trenutaka (piše ga trg_slots_live na prijelaz u 'sold').
  -- Račun i status se ne smiju oslanjati na slots.contribution_id: istek zakupa
  -- ga briše, a retry računa može doći i nakon isteka.
  add column if not exists sold_slots jsonb,
  add column if not exists invoice_state        text,
  add column if not exists invoice_racun_id     bigint,
  add column if not exists invoice_number       text,
  add column if not exists invoice_attempts     integer not null default 0,
  add column if not exists invoice_locked_until timestamptz,
  add column if not exists invoice_next_at      timestamptz,
  add column if not exists invoice_last_error   text,
  add column if not exists invoice_updated_at   timestamptz;

alter table pinka_finance.contributions
  drop constraint if exists contributions_link_url_format,
  drop constraint if exists contributions_logo_path_format,
  drop constraint if exists contributions_buyer_company_len,
  drop constraint if exists contributions_buyer_oib_format,
  drop constraint if exists contributions_buyer_vat_format,
  drop constraint if exists contributions_buyer_address_size,
  drop constraint if exists contributions_buyer_reference_len,
  drop constraint if exists contributions_invoice_state_chk,
  drop constraint if exists contributions_invoice_error_len;

alter table pinka_finance.contributions
  add constraint contributions_link_url_format check (
    link_url is null or (char_length(link_url) <= 500 and link_url ~ '^https://[^\s]+$')) not valid,
  add constraint contributions_logo_path_format check (
    logo_path is null or logo_path ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.(png|jpe?g|webp)$') not valid,
  add constraint contributions_buyer_company_len check (
    buyer_company is null or char_length(buyer_company) between 1 and 200) not valid,
  add constraint contributions_buyer_oib_format check (
    buyer_oib is null or buyer_oib ~ '^[0-9]{11}$') not valid,
  add constraint contributions_buyer_vat_format check (
    buyer_vat_id is null or buyer_vat_id ~ '^[A-Z]{2}[A-Z0-9]{2,13}$') not valid,
  add constraint contributions_buyer_address_size check (
    buyer_address is null or pg_column_size(buyer_address) <= 2048) not valid,
  add constraint contributions_buyer_reference_len check (
    buyer_reference is null or char_length(buyer_reference) <= 100) not valid,
  add constraint contributions_invoice_state_chk check (
    invoice_state is null or invoice_state in ('pending','issued','sent','failed','skipped')) not valid,
  add constraint contributions_invoice_error_len check (
    invoice_last_error is null or char_length(invoice_last_error) <= 1000) not valid;

comment on column pinka_finance.contributions.underpaid is
  'Kupnja mjesta plaćena manje od cijene. state=''failed'', mjesto NIJE dodijeljeno. '
  'Povrat ručno (MPT nema refund API).';
comment on column pinka_finance.contributions.invoice_state is
  'Račun preko domovina-fiskal: null/pending → issued → sent; failed = retry (cron). '
  'skipped = račun se ne izdaje (npr. ručno).';

-- Red za retry računa.
create index if not exists ix_contributions_invoice_due
  on pinka_finance.contributions(invoice_next_at)
  where is_sponsor and state = 'paid' and coalesce(invoice_state, 'pending') in ('pending','issued','failed');

-- ----- 4. OIB kontrolna znamenka (ISO 7064, MOD 11,10) -----------------------
create or replace function pinka_finance.oib_valid(p text)
returns boolean
language plpgsql immutable
as $$
declare
  v_a integer := 10;
  i   integer;
begin
  if p is null or p !~ '^[0-9]{11}$' then return false; end if;
  for i in 1..10 loop
    v_a := (v_a + substr(p, i, 1)::integer) % 10;
    if v_a = 0 then v_a := 10; end if;
    v_a := (v_a * 2) % 11;
  end loop;
  return (11 - v_a) % 10 = substr(p, 11, 1)::integer;
end;
$$;

-- ----- 5. checkout: kreativa + kupac + rezervacija u JEDNOJ transakciji -------
-- Zaseban RPC umjesto proširenja create_contribution: još jedan defaultirani
-- parametar tamo = novi overload i PGRST203 za svaki postojeći klijent.
-- Iznos određuje server (zbroj cijena trenutaka); klijent ga ne šalje.
create or replace function pinka_finance.create_sponsor_contribution(
  p_campaign_id    uuid,
  p_slot_keys      text[],
  p_brand          text,
  p_tagline        text,
  p_link_url       text,
  p_logo_path      text,
  p_buyer          jsonb,
  p_terms_accepted boolean
) returns table (
  contribution_id     uuid,
  amount_cents        bigint,
  currency            text,
  destination_address text,
  slot_keys           text[],
  hold_expires_at     timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_campaign pinka_finance.campaigns;
  v_map      pinka_finance.slot_maps;
  v_keys     text[];
  v_n_found  integer;
  v_total    bigint;
  v_account  uuid;
  v_brand    text := pinka_finance.sanitize_ugc(p_brand);
  v_tagline  text := pinka_finance.sanitize_ugc(p_tagline);
  v_link     text := nullif(btrim(coalesce(p_link_url, '')), '');
  v_logo     text := nullif(btrim(coalesce(p_logo_path, '')), '');
  v_company  text := pinka_finance.sanitize_ugc(p_buyer->>'company');
  v_oib      text := nullif(regexp_replace(coalesce(p_buyer->>'oib', ''), '\s', '', 'g'), '');
  v_vat      text := nullif(upper(regexp_replace(coalesce(p_buyer->>'vat_id', ''), '\s', '', 'g')), '');
  v_email    text := nullif(lower(btrim(coalesce(p_buyer->>'email', ''))), '');
  v_ref      text := pinka_finance.sanitize_ugc(p_buyer->>'reference');
  v_addr     jsonb;
  v_country  text;
  v_id       uuid;
  v_hold     timestamptz;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_campaign from pinka_finance.campaigns
   where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  select * into v_map from pinka_finance.slot_maps where campaign_id = p_campaign_id;
  if not found or v_map.kind::text <> 'timeline' then raise exception 'not_sponsor_campaign'; end if;

  -- ── validacija kreative ──
  if coalesce(p_terms_accepted, false) is not true then raise exception 'invalid_sponsor:terms'; end if;
  if v_brand is null or char_length(v_brand) > 60 then raise exception 'invalid_sponsor:brand'; end if;
  if v_tagline is not null and char_length(v_tagline) > 120 then raise exception 'invalid_sponsor:tagline'; end if;
  if v_link is not null and (char_length(v_link) > 500 or v_link !~ '^https://[^\s/?#]+\.[^\s]*$') then
    raise exception 'invalid_sponsor:link_url';
  end if;
  if v_logo is not null then
    -- Samo vlastita mapa i samo stvarno uploadan objekt unutar limita. Bucket
    -- limit (204800 B, MIME) vrijedi pri uploadu; ovo je druga linija.
    if v_logo !~ ('^' || v_uid::text || '/[A-Za-z0-9_-]{1,64}\.(png|jpe?g|webp)$')
       or not exists (
         select 1 from storage.objects o
          where o.bucket_id = 'sponsor-logos' and o.name = v_logo
            and coalesce((o.metadata->>'size')::bigint, 0) between 1 and 204800
            and coalesce(o.metadata->>'mimetype', '') in ('image/png','image/jpeg','image/webp'))
    then
      raise exception 'invalid_sponsor:logo_path';
    end if;
  end if;

  -- ── validacija kupca ──
  if v_company is null or char_length(v_company) > 200 then raise exception 'invalid_sponsor:buyer_company'; end if;
  if v_oib is not null and not pinka_finance.oib_valid(v_oib) then raise exception 'invalid_sponsor:buyer_oib'; end if;
  if v_vat is not null and v_vat !~ '^[A-Z]{2}[A-Z0-9]{2,13}$' then raise exception 'invalid_sponsor:buyer_vat_id'; end if;
  if v_email is null or char_length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_sponsor:buyer_email';
  end if;
  if v_ref is not null and char_length(v_ref) > 100 then raise exception 'invalid_sponsor:buyer_reference'; end if;

  if p_buyer ? 'address' and jsonb_typeof(p_buyer->'address') = 'object' then
    v_country := upper(coalesce(nullif(btrim(p_buyer->'address'->>'country'), ''), 'HR'));
    if v_country !~ '^[A-Z]{2}$' then raise exception 'invalid_sponsor:buyer_address'; end if;
    v_addr := jsonb_strip_nulls(jsonb_build_object(
      'street',      pinka_finance.sanitize_ugc(p_buyer->'address'->>'street'),
      'city',        pinka_finance.sanitize_ugc(p_buyer->'address'->>'city'),
      'postal_code', pinka_finance.sanitize_ugc(p_buyer->'address'->>'postal_code'),
      'country',     v_country));
    if char_length(coalesce(v_addr->>'street', '')) > 200
       or char_length(coalesce(v_addr->>'city', '')) > 100
       or char_length(coalesce(v_addr->>'postal_code', '')) > 16 then
      raise exception 'invalid_sponsor:buyer_address';
    end if;
  end if;

  -- ── trenuci ──
  select array_agg(distinct k) into v_keys from unnest(p_slot_keys) k where k is not null;
  if v_keys is null or array_length(v_keys, 1) not between 1 and 3 then
    raise exception 'invalid_slot_keys';
  end if;

  -- Istekli zakupi u 'free' PRIJE rezervacije — inače bi istekao trenutak bio
  -- neprodajan dok ga cron ne počisti (ugovor O6).
  perform pinka_finance.expire_live_slots();

  select count(*), sum(z.price_cents) into v_n_found, v_total
    from pinka_finance.slots s
    join pinka_finance.slot_zones z on z.id = s.zone_id
   where s.map_id = v_map.id and s.slot_key = any (v_keys);
  if v_n_found <> array_length(v_keys, 1) then raise exception 'invalid_slot_keys'; end if;

  select id into v_account from public.accounts
   where primary_owner_user_id = v_uid and is_personal_account = true and deleted_at is null
   limit 1;

  insert into pinka_finance.contributions (
    campaign_id, contributor_account_id, amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message,
    is_sponsor, link_url, logo_path,
    buyer_company, buyer_oib, buyer_vat_id, buyer_email, buyer_address, buyer_reference,
    terms_accepted_at
  ) values (
    p_campaign_id, v_account, v_total, v_campaign.currency, 1, 'pending',
    v_campaign.destination_address, false, v_brand, v_tagline,
    true, v_link, v_logo,
    v_company, v_oib, v_vat, v_email, v_addr, v_ref,
    now()
  ) returning id into v_id;

  -- Ista transakcija: slot_taken rollbacka i doprinos (reserve_slots).
  perform pinka_finance.reserve_slots(v_id, v_keys, null);
  select min(s.hold_expires_at) into v_hold from pinka_finance.slots s where s.contribution_id = v_id;

  return query
    select v_id, v_total, v_campaign.currency, v_campaign.destination_address, v_keys, v_hold;
end;
$$;
revoke execute on function pinka_finance.create_sponsor_contribution(uuid,text[],text,text,text,text,jsonb,boolean)
  from public, anon;
grant  execute on function pinka_finance.create_sponsor_contribution(uuid,text[],text,text,text,text,jsonb,boolean)
  to authenticated, service_role;

-- ----- 6. mark_contribution_paid — PROVJERA IZNOSA ---------------------------
-- Do sada se amount_received_cents samo zapisivao. Uplata od 1 € zauzela bi
-- trenutak od 500 €. Pravilo za KUPNJU MJESTA (desired_slot_keys not null):
-- primljeno < cijena mjesta → 'failed' + underpaid, holdovi se otpuštaju,
-- event 'contribution.underpaid' (webhook iz njega šalje alarm).
--   * cijena = least(amount_cents, zbroj cijena zona) — grid donator koji je
--     obećao više od cijene kvadratića ne gubi ga ako pošalje manje od obećanja
--   * NEPOZNAT iznos (null) je manjak SAMO za sponzorski trenutak; grid i
--     sjedala zadržavaju staro ponašanje (H2: novac na Safeu se ne odbija)
-- Donacije (bez mjesta) ostaju kakve jesu — manjak donacije nije problem.
--
-- Povrat ostaje boolean (webhook se oslanja na to): true = prvi put obrađeno
-- (plaćeno ILI underpaid), false = retry / nepoznat sid. Webhook čita red da
-- razlikuje ishode.
create or replace function pinka_finance.mark_contribution_paid(
  p_sid                   text,
  p_tx_hash               text,
  p_amount_received_cents bigint default null,
  p_sender_iban           text   default null,
  p_sender_name           text   default null,
  p_key                   text   default null
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_updated integer;
  v_named   boolean := p_sender_name is not null and btrim(p_sender_name) <> '';
  v_iban_hash text := case
    when p_sender_iban is not null and p_key is not null
    then encode(extensions.hmac(upper(regexp_replace(p_sender_iban, '\s', '', 'g')), p_key, 'sha256'), 'hex')
    end;
  v_under   record;
begin
  -- (a) manjak na kupnji mjesta — PRIJE grane 'paid', inače trigger dodijeli mjesto
  for v_under in
    update pinka_finance.contributions
       set state                 = 'failed',
           underpaid             = true,
           forward_tx_hash       = p_tx_hash,
           amount_received_cents = p_amount_received_cents,
           payer_iban_hash       = coalesce(v_iban_hash, payer_iban_hash),
           updated_at            = now()
     where payment_intent_sid = p_sid
       and state in ('pending', 'expired', 'failed')
       and not underpaid
       and desired_slot_keys is not null
       and ((p_amount_received_cents is null and is_sponsor)
            or p_amount_received_cents < least(amount_cents, (
                 select coalesce(sum(z.price_cents), 0)
                   from pinka_finance.slots s
                   join pinka_finance.slot_maps m  on m.id = s.map_id
                   join pinka_finance.slot_zones z on z.id = s.zone_id
                  where m.campaign_id = contributions.campaign_id
                    and s.slot_key = any (contributions.desired_slot_keys))))
    returning id, campaign_id, amount_cents
  loop
    perform pinka_finance.release_slot_holds(v_under.id);
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (v_under.id, v_under.campaign_id, 'contribution.underpaid',
            jsonb_build_object('amount_cents', v_under.amount_cents,
                               'amount_received_cents', p_amount_received_cents,
                               'tx_hash', p_tx_hash));
  end loop;
  if found then return true; end if;

  -- (b) uobičajeni put (nepromijenjen osim `not underpaid`)
  update pinka_finance.contributions
     set state                    = 'paid',
         forward_tx_hash          = p_tx_hash,
         amount_received_cents    = coalesce(p_amount_received_cents, amount_received_cents, amount_cents),
         bank_verified            = v_named,
         identity_double_verified = v_named
           and pinka_finance.sepa_name_matches_identity(contributor_account_id, p_sender_name),
         payer_iban_hash          = coalesce(v_iban_hash, payer_iban_hash),
         paid_at                  = now(),
         updated_at               = now()
   where payment_intent_sid = p_sid
     and state in ('pending', 'expired', 'failed')
     and not underpaid;
  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;
revoke execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) to service_role;

-- ----- 7. javni viewovi ------------------------------------------------------
-- Javni URL loga. Lokalno: alter database postgres set
--   pinka.public_storage_url = 'http://127.0.0.1:55321/storage/v1/object/public';
create or replace function pinka_finance.public_storage_url()
returns text
language sql stable
as $$
  select coalesce(nullif(current_setting('pinka.public_storage_url', true), ''),
                  'https://api.domovina.ai/storage/v1/object/public');
$$;

-- Izlog: svi trenuci, BEZ ikakvih podataka o kupcu ili brandu.
create or replace view pinka_finance.public_sponsor_moments as
  select
    m.campaign_id,
    s.slot_key,
    s.youtube_id,
    s.start_sec,
    s.end_sec,
    s.label        as title,
    z.zone_index,
    z.label_key    as zone_label_key,
    z.price_cents,
    z.run_days,
    -- istekli hold i istekli zakup su slobodni ISTI TREN, bez joba (O6)
    case
      when s.state = 'held' and s.hold_expires_at <= now() then 'free'
      when s.state = 'sold' and s.live_until is not null and s.live_until <= now() then 'free'
      else s.state::text
    end as state,
    case when s.state = 'sold' and s.live_until > now() then s.live_until end as live_until
  from pinka_finance.slots s
  join pinka_finance.slot_zones z on z.id = s.zone_id
  join pinka_finance.slot_maps  m on m.id = s.map_id
  join pinka_finance.campaigns  c on c.id = m.campaign_id
 where m.kind::text = 'timeline'
   and s.youtube_id is not null
   and c.deleted_at is null
   and c.visibility in ('public','unlisted')
   and c.state in ('active','funded','closed');

alter view pinka_finance.public_sponsor_moments set (security_invoker = off);
grant select on pinka_finance.public_sponsor_moments to anon, authenticated, service_role;

-- Prikaz: samo ono što je SADA uživo. Nikad buyer_*, iznos ni 'held'.
create or replace view pinka_finance.public_live_moments as
  select
    s.slot_key,
    s.youtube_id,
    s.start_sec,
    s.end_sec,
    ct.display_name as brand,
    ct.message      as tagline,
    ct.link_url,
    case when ct.logo_path is not null
         then pinka_finance.public_storage_url() || '/sponsor-logos/' || ct.logo_path end as logo_url,
    ct.logo_path,
    s.live_from,
    s.live_until
  from pinka_finance.slots s
  join pinka_finance.slot_maps  m  on m.id = s.map_id
  join pinka_finance.campaigns  c  on c.id = m.campaign_id
  join pinka_finance.contributions ct on ct.id = s.contribution_id
 where m.kind::text = 'timeline'
   and s.youtube_id is not null
   and s.state = 'sold'
   and ct.state = 'paid'
   and ct.is_sponsor
   and not ct.message_hidden
   and s.live_from <= now()
   and s.live_until > now()
   and c.deleted_at is null
   and c.visibility in ('public','unlisted')
   and c.state in ('active','funded','closed');

alter view pinka_finance.public_live_moments set (security_invoker = off);
grant select on pinka_finance.public_live_moments to anon, authenticated, service_role;

-- ----- 8. status narudžbe (checkout panel) -----------------------------------
-- contribution_id je capability (isti model kao contribution_status). Bez PII.
create or replace function pinka_finance.sponsor_order_status(p_contribution_id uuid)
returns table (
  state                 text,
  underpaid             boolean,
  amount_cents          bigint,
  amount_received_cents bigint,
  paid_at               timestamptz,
  slot_unassigned       boolean,
  slots                 jsonb,
  invoice_state         text,
  invoice_number        text,
  hidden                boolean
)
language sql stable security definer set search_path = ''
as $$
  select c.state::text, c.underpaid, c.amount_cents, c.amount_received_cents, c.paid_at,
         c.slot_unassigned,
         coalesce((
           select jsonb_agg(jsonb_build_object(
                    'slot_key', s.slot_key, 'youtube_id', s.youtube_id,
                    'start_sec', s.start_sec, 'end_sec', s.end_sec,
                    'state', case when s.state = 'held' and s.hold_expires_at <= now() then 'free'
                                  else s.state::text end,
                    'live_from', s.live_from, 'live_until', s.live_until)
                  order by s.youtube_id, s.start_sec)
             from pinka_finance.slots s where s.contribution_id = c.id),
           -- zakup istekao (slots.contribution_id obrisan) → snapshot
           c.sold_slots, '[]'::jsonb),
         c.invoice_state, c.invoice_number, c.message_hidden
    from pinka_finance.contributions c
   where c.id = p_contribution_id and c.is_sponsor;
$$;
revoke execute on function pinka_finance.sponsor_order_status(uuid) from public;
grant  execute on function pinka_finance.sponsor_order_status(uuid) to anon, authenticated, service_role;

-- ----- 9. račun: lease + zapis (pinka-webhook i sponsor-cron) ----------------
-- Webhook MPT ponavlja do ~47 h, a dvaput izdan ili poslan račun je stvarna
-- šteta. Dvije brave: (1) Idempotency-Key = contribution id na fiskalu,
-- (2) ovaj lease — samo jedan pozivatelj u isto vrijeme radi korake za isti
-- doprinos, pa se /posalji-eracun ne zove dvaput paralelno.
create or replace function pinka_finance.sponsor_invoice_lease(
  p_contribution_id uuid,
  p_lease_seconds   integer default 120
) returns setof pinka_finance.contributions
language sql security definer set search_path = ''
as $$
  update pinka_finance.contributions
     set invoice_state        = coalesce(invoice_state, 'pending'),
         invoice_locked_until = now() + make_interval(secs => p_lease_seconds),
         invoice_attempts     = invoice_attempts + 1,
         invoice_updated_at   = now()
   where id = p_contribution_id
     and is_sponsor
     and state = 'paid'
     and coalesce(invoice_state, 'pending') in ('pending','issued','failed')
     and (invoice_locked_until is null or invoice_locked_until < now())
  returning *;
$$;
revoke execute on function pinka_finance.sponsor_invoice_lease(uuid,integer) from public, anon, authenticated;
grant  execute on function pinka_finance.sponsor_invoice_lease(uuid,integer) to service_role;

create or replace function pinka_finance.sponsor_invoice_record(
  p_contribution_id uuid,
  p_state           text,
  p_racun_id        bigint default null,
  p_number          text   default null,
  p_error           text   default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_attempts integer;
begin
  if p_state not in ('pending','issued','sent','failed','skipped') then
    raise exception 'invalid_invoice_state';
  end if;
  update pinka_finance.contributions
     set invoice_state        = p_state,
         invoice_racun_id     = coalesce(p_racun_id, invoice_racun_id),
         invoice_number       = coalesce(p_number, invoice_number),
         invoice_last_error   = left(p_error, 1000),
         invoice_locked_until = null,
         -- eksponencijalni backoff 2^n min, max 6 h; uspjeh briše raspored
         invoice_next_at      = case when p_state in ('sent','skipped') then null
                                     else now() + least(make_interval(mins => power(2, least(invoice_attempts, 9))::integer),
                                                        interval '6 hours') end,
         invoice_updated_at   = now()
   where id = p_contribution_id
  returning invoice_attempts into v_attempts;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  select id, campaign_id, 'invoice.' || p_state,
         jsonb_strip_nulls(jsonb_build_object('racun_id', p_racun_id, 'number', p_number,
                                              'error', left(p_error, 300), 'attempt', v_attempts))
    from pinka_finance.contributions where id = p_contribution_id;
end;
$$;
revoke execute on function pinka_finance.sponsor_invoice_record(uuid,text,bigint,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.sponsor_invoice_record(uuid,text,bigint,text,text) to service_role;

-- Što cron treba ponoviti. Nakon 12 pokušaja (~1,5 dan) red ostaje 'failed'
-- za ručni pregled — beskonačni retry bi mogao zatrpati fiskal.
create or replace function pinka_finance.sponsor_invoices_due(p_limit integer default 20)
returns setof uuid
language sql stable security definer set search_path = ''
as $$
  select id from pinka_finance.contributions
   where is_sponsor and state = 'paid'
     and coalesce(invoice_state, 'pending') in ('pending','issued','failed')
     and invoice_attempts < 12
     and (invoice_next_at is null or invoice_next_at <= now())
     and (invoice_locked_until is null or invoice_locked_until < now())
   order by paid_at
   limit p_limit;
$$;
revoke execute on function pinka_finance.sponsor_invoices_due(integer) from public, anon, authenticated;
grant  execute on function pinka_finance.sponsor_invoices_due(integer) to service_role;

-- ----- 10. obavijest vlasniku: točno jednom po doprinosu ---------------------
create or replace function pinka_finance.sponsor_claim_owner_notify(p_contribution_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  -- max 5 pokušaja: trajno neisporučiva obavijest ne smije zauvijek
  -- zauzimati cron (sponsor-cron je ponavlja dok je owner_notified_at null)
  update pinka_finance.contributions
     set owner_notified_at = now(), owner_notify_attempts = owner_notify_attempts + 1
   where id = p_contribution_id and is_sponsor and owner_notified_at is null
     and owner_notify_attempts < 5;
  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;
revoke execute on function pinka_finance.sponsor_claim_owner_notify(uuid) from public, anon, authenticated;
grant  execute on function pinka_finance.sponsor_claim_owner_notify(uuid) to service_role;

-- Povlačenje kreative iz linka u e-pošti (sponsor-moderate, HMAC token).
-- Vlasnik s prijavom i dalje može kroz set_contribution_message_hidden.
create or replace function pinka_finance.sponsor_set_hidden(p_contribution_id uuid, p_hidden boolean)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_campaign uuid;
begin
  update pinka_finance.contributions
     set message_hidden = p_hidden, updated_at = now()
   where id = p_contribution_id and is_sponsor
  returning campaign_id into v_campaign;
  if not found then return false; end if;
  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_contribution_id, v_campaign, case when p_hidden then 'sponsor.hidden' else 'sponsor.unhidden' end,
          '{}'::jsonb);
  return true;
end;
$$;
revoke execute on function pinka_finance.sponsor_set_hidden(uuid,boolean) from public, anon, authenticated;
grant  execute on function pinka_finance.sponsor_set_hidden(uuid,boolean) to service_role;

-- ----- 11. seed pomoćnici ----------------------------------------------------
-- Karta + zone. p_zones: [{"index":0,"price_cents":3000,"run_days":30,"label_key":"…"}]
-- Cijena je BRUTO (PDV 25 % uključen) i mora biti djeljiva s 5 centi, inače
-- neto = bruto/1,25 nije cijeli cent i račun ne bi zbrojio na plaćeni iznos.
create or replace function pinka_finance.seed_timeline_map(p_campaign_id uuid, p_zones jsonb)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_map uuid; v_z jsonb;
begin
  select id into v_map from pinka_finance.slot_maps where campaign_id = p_campaign_id;
  if v_map is null then
    insert into pinka_finance.slot_maps (campaign_id, kind, width, height, conflict_policy, max_holds_per_session)
    -- 3 neplaćena trenutka po sesiji. Anonimna prijava daje novu sesiju pa
    -- ovo nije prava zaštita od blokiranja inventara — vidi zaključak P9.
    values (p_campaign_id, 'timeline', 1, 1, 'flag_for_refund', 3)
    returning id into v_map;
  elsif (select kind::text from pinka_finance.slot_maps where id = v_map) <> 'timeline' then
    raise exception 'map_not_timeline';
  else
    update pinka_finance.slot_maps set max_holds_per_session = 3 where id = v_map;
  end if;

  for v_z in select * from jsonb_array_elements(p_zones) loop
    if ((v_z->>'price_cents')::integer) % 5 <> 0 then
      raise exception 'price_not_multiple_of_5:%', v_z->>'price_cents';
    end if;
    insert into pinka_finance.slot_zones (map_id, zone_index, price_cents, run_days, label_key)
    values (v_map, (v_z->>'index')::smallint, (v_z->>'price_cents')::integer,
            (v_z->>'run_days')::smallint, v_z->>'label_key')
    on conflict (map_id, zone_index) do update
      set price_cents = excluded.price_cents, run_days = excluded.run_days,
          label_key = excluded.label_key;
  end loop;
  return v_map;
end;
$$;
revoke execute on function pinka_finance.seed_timeline_map(uuid,jsonb) from public, anon, authenticated;
grant  execute on function pinka_finance.seed_timeline_map(uuid,jsonb) to service_role;

-- Trenuci jedne epizode. p_moments: [{"start":33,"end":220,"zone":2,"title":"…"}]
-- Idempotentno po slot_key; postojeći trenutak mijenja granice/naslov/zonu samo
-- dok je 'free' (prodan trenutak je obećanje).
create or replace function pinka_finance.seed_timeline_episode(
  p_campaign_id uuid,
  p_youtube_id  text,
  p_episode_ix  smallint,
  p_moments     jsonb
) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_map uuid; v_base integer; v_n integer;
begin
  select id into v_map from pinka_finance.slot_maps where campaign_id = p_campaign_id;
  if v_map is null then raise exception 'no_slot_map'; end if;
  select coalesce(max(token_id), -1) + 1 into v_base from pinka_finance.slots where map_id = v_map;

  insert into pinka_finance.slots
    (map_id, zone_id, slot_key, label, pos_x, pos_y, token_id, price_cents, youtube_id, start_sec, end_sec)
  select v_map, z.id,
         p_youtube_id || '@' || (m->>'start'),
         left(m->>'title', 300),
         (row_number() over (order by (m->>'start')::integer))::smallint - 1,
         p_episode_ix,
         v_base + (row_number() over (order by (m->>'start')::integer))::integer - 1,
         z.price_cents,
         p_youtube_id, (m->>'start')::integer, (m->>'end')::integer
    from jsonb_array_elements(p_moments) m
    join pinka_finance.slot_zones z on z.map_id = v_map and z.zone_index = (m->>'zone')::smallint
  on conflict (map_id, slot_key) do update
    set label = excluded.label, end_sec = excluded.end_sec, zone_id = excluded.zone_id,
        price_cents = excluded.price_cents, updated_at = now()
    where pinka_finance.slots.state = 'free';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function pinka_finance.seed_timeline_episode(uuid,text,smallint,jsonb) from public, anon, authenticated;
grant  execute on function pinka_finance.seed_timeline_episode(uuid,text,smallint,jsonb) to service_role;

-- ----- 12. storage: sponsor-logos --------------------------------------------
-- Javno čitanje (logo se prikazuje u playeru), upload samo u vlastitu mapu.
-- BEZ KYC-a (za razliku od pinka-covers): brand kupuje s anonimnom sesijom,
-- a logo postaje javno vidljiv u viewu tek nakon plaćanja. Nema update/delete:
-- kreativa koja je plaćena ne smije se tiho zamijeniti.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sponsor-logos', 'sponsor-logos', true, 204800,
        array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists sponsor_logos_insert on storage.objects;
create policy sponsor_logos_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'sponsor-logos'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and name ~ '^[0-9a-f-]{36}/[A-Za-z0-9_-]{1,64}\.(png|jpe?g|webp)$'
  );

-- ----- 13. pg_cron (opcionalno; ispravnost NE ovisi o ovome) ----------------
-- pg_cron je na produkciji dostupan, ali nije instaliran (7.10.2026.).
-- Kad se instalira: docs/sponzorski-trenuci-zakljucak.md, "Cron".
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('sponsor-expire-live', '*/10 * * * *',
                          'select pinka_finance.expire_live_slots()');
  end if;
end $$;

select 'OK sponzorski_trenuci' as status;
