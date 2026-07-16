-- =============================================================================
-- Događaji (E4) — organizator self-service: state machine, allowlist, DAC7
-- Reference: safe-wallet-monorepo/docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md
--            (§4, §6), handoffs/dogadjaji-4-organizator.md
--
-- Dodaje ono što organizatoru treba da event objavi BEZ developera:
--
--   1. pinka_finance.organizer_allowlist — moderacija objave (pilot: ručni
--      flag; upisuje ISKLJUČIVO operater kroz service_role/psql). Tko smije
--      publish odlučuje server, ne UI.
--   2. pinka_finance.organizer_records   — DAC7 evidencija organizatora
--      (pravni subjekt, OIB, adresa, financijski identifikator — polje-set
--      preuzet iz Tržnica M4). SENSITIVE: RLS service_role + vlastiti org
--      admin; NIKAD u javnom feedu.
--   3. update_event RPC (INVOKER)        — uređivanje eventa + tiera; tieri su
--      zaključani nakon objave (cijena/imenska), inventory smije samo rasti.
--   4. publish_event RPC (DEFINER)       — state machine draft→active→closed;
--      aktivacija gated na org admin + allowlist + pravi Safe
--      (campaigns_write_guard dodatno mirrora destination check).
--   5. organizer_overview RPC (DEFINER)  — jedan poziv za organizator UI:
--      moji org accounti (+ allowlist/record status) i moji eventi s tierima
--      (uklj. draftove — javni feed ih NE prikazuje).
--   6. upsert_organizer_record RPC       — DAC7 zapis, validacija server-side.
--
-- UGC napomena: opisi eventa idu u JAVNI feed — sanitizacija (kontrolni
-- znakovi van \n) + length limiti se rade server-side (sanitize_ugc +
-- postojeći events_description_*_len constrainti), ne u klijentu.
-- =============================================================================

-- ----- 1. organizer_allowlist (moderacija objave; pilot = ručni flag) ---------
create table if not exists pinka_finance.organizer_allowlist (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  note text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint organizer_allowlist_note_len check (note is null or char_length(note) <= 500)
);

comment on table pinka_finance.organizer_allowlist is
  'Org accounti kojima je dopušten publish eventa (E4 moderacija). Upis '
  'isključivo operater (service_role/psql); publish_event RPC provjerava '
  'članstvo server-side — klijentski flag ne postoji.';

alter table pinka_finance.organizer_allowlist enable row level security;

-- default privileges (20260530120200) daju select anon+authenticated → suzimo
revoke all on pinka_finance.organizer_allowlist from public, anon;
revoke insert, update, delete on pinka_finance.organizer_allowlist from authenticated;
grant select on pinka_finance.organizer_allowlist to authenticated;
grant select, insert, update, delete on pinka_finance.organizer_allowlist to service_role;

drop policy if exists organizer_allowlist_select on pinka_finance.organizer_allowlist;
create policy organizer_allowlist_select on pinka_finance.organizer_allowlist
  for select to authenticated
  using (public.is_account_member(account_id));

-- ----- 2. organizer_records (DAC7 evidencija — SENSITIVE) ----------------------
create table if not exists pinka_finance.organizer_records (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  legal_name text not null,
  oib text not null,
  address_line text not null,
  city text not null,
  postal_code text not null,
  country_code text not null default 'HR',
  contact_email text,
  financial_identifier_type text not null default 'safe_address',
  financial_identifier text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizer_records_legal_name_len check (char_length(legal_name) between 1 and 200),
  constraint organizer_records_oib_format check (oib ~ '^\d{11}$'),
  constraint organizer_records_address_len check (char_length(address_line) between 1 and 200),
  constraint organizer_records_city_len check (char_length(city) between 1 and 80),
  constraint organizer_records_postal_len check (char_length(postal_code) between 1 and 20),
  constraint organizer_records_country_format check (country_code ~ '^[A-Z]{2}$'),
  constraint organizer_records_email_len check (contact_email is null or char_length(contact_email) <= 200),
  constraint organizer_records_fin_type check (financial_identifier_type in ('iban', 'safe_address')),
  constraint organizer_records_fin_format check (
    (financial_identifier_type = 'iban' and financial_identifier ~ '^[A-Z]{2}\d{2}[A-Z0-9]{1,30}$')
    or (financial_identifier_type = 'safe_address' and financial_identifier ~ '^0x[0-9a-fA-F]{40}$')
  )
);

comment on table pinka_finance.organizer_records is
  'DAC7 evidencija organizatora (E4; polje-set = Tržnica M4): pravni subjekt, '
  'OIB, adresa, financijski identifikator. SENSITIVE — čitaju samo '
  'service_role i admin vlastitog org accounta; nikad u javnim viewovima ni '
  'feedu. Godišnje DAC7 izvještavanje (XML) je ručni operaterski korak.';

drop trigger if exists trg_organizer_records_updated on pinka_finance.organizer_records;
create trigger trg_organizer_records_updated
  before update on pinka_finance.organizer_records
  for each row execute function public.touch_updated_at();

alter table pinka_finance.organizer_records enable row level security;

revoke all on pinka_finance.organizer_records from public, anon;
revoke insert, update, delete on pinka_finance.organizer_records from authenticated;
grant select on pinka_finance.organizer_records to authenticated;
grant select, insert, update, delete on pinka_finance.organizer_records to service_role;

drop policy if exists organizer_records_select on pinka_finance.organizer_records;
create policy organizer_records_select on pinka_finance.organizer_records
  for select to authenticated
  using (public.has_role_on_account(account_id, 'admin'));

-- ----- 3. sanitize_ugc (opisi u javnom feedu) ----------------------------------
-- Uklanja C0 kontrolne znakove (osim \n i \t) + trim; prazno → null. Length
-- limiti ostaju na check constraintima (events_description_*_len ≤ 20000).
create or replace function pinka_finance.sanitize_ugc(p text)
returns text
language sql immutable
as $$
  select nullif(
    btrim(regexp_replace(coalesce(p, ''), '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g')),
    ''
  );
$$;

-- ----- 4. update_event (organizator; INVOKER — RLS vrijedi) --------------------
-- null param = polje se ne dira; prazan string = brisanje opcionalnog polja.
-- p_destination_address: organizator upisuje svoj Safe naknadno (draft se
-- kreira s nultom placeholder adresom); campaigns_write_guard i dalje
-- zaključava adresu nakon prve plaćene uplate (anti-rug).
-- p_tiers (null = ne diraj): [{id? (postojeći tier), title, price_cents,
--   inventory_total?, imenska?, sale_start?, sale_end?, description?, sort?}]
-- Pravila nakon objave (state <> 'draft'): cijena i imenska POSTOJEĆEG tiera su
-- zaključane (kupci su kupovali pod tim uvjetima); inventory_total ne smije
-- pasti ispod inventory_claimed; novi tieri se smiju dodavati.
create or replace function pinka_finance.update_event(
  p_campaign_id uuid,
  p_title text default null,
  p_destination_address text default null,
  p_event_type text default null,
  p_venue_name text default null,
  p_venue_address text default null,
  p_venue_city text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_timezone text default null,
  p_description_hr text default null,
  p_description_en text default null,
  p_cover_image_url text default null,
  p_organizer_name text default null,
  p_organizer_email text default null,
  p_organizer_web text default null,
  p_tiers jsonb default null
) returns jsonb
language plpgsql
-- security INVOKER (default): RLS update policies (org admin) i dalje vrijede
as $$
declare
  v_campaign pinka_finance.campaigns;
  v_event pinka_finance.events;
  v_tier jsonb;
  v_existing pinka_finance.campaign_tiers;
  v_tier_id uuid;
  v_price integer;
  v_inventory integer;
  v_sale_start timestamptz;
  v_sale_end timestamptz;
  v_starts timestamptz;
  v_ends timestamptz;
  v_updated integer := 0;
  v_added integer := 0;
begin
  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  select * into v_event from pinka_finance.events where campaign_id = p_campaign_id;
  if not found then raise exception 'event_not_found'; end if;

  -- ── validacija (ista pravila kao create_event; strojni kodovi) ────────────
  if p_title is not null and (btrim(p_title) = '' or char_length(btrim(p_title)) < 3 or char_length(p_title) > 160) then
    raise exception 'invalid_title';
  end if;
  if p_destination_address is not null and p_destination_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_destination';
  end if;
  if p_event_type is not null and p_event_type !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'invalid_event_type';
  end if;
  if p_venue_name is not null and (btrim(p_venue_name) = '' or char_length(p_venue_name) > 160) then
    raise exception 'invalid_venue_name';
  end if;
  if p_venue_city is not null and (btrim(p_venue_city) = '' or char_length(p_venue_city) > 80) then
    raise exception 'invalid_venue_city';
  end if;
  if p_venue_address is not null and char_length(p_venue_address) > 200 then
    raise exception 'invalid_venue_address';
  end if;
  if p_timezone is not null and (btrim(p_timezone) = '' or char_length(p_timezone) > 64) then
    raise exception 'invalid_timezone';
  end if;
  if p_description_hr is not null and char_length(p_description_hr) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_description_en is not null and char_length(p_description_en) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_cover_image_url is not null and p_cover_image_url <> ''
     and (char_length(p_cover_image_url) > 1000 or p_cover_image_url !~* '^https://') then
    raise exception 'invalid_cover_url';
  end if;
  if p_organizer_name is not null and (btrim(p_organizer_name) = '' or char_length(p_organizer_name) > 160) then
    raise exception 'invalid_organizer_name';
  end if;
  if p_organizer_email is not null and char_length(p_organizer_email) > 200 then
    raise exception 'invalid_organizer_email';
  end if;
  if p_organizer_web is not null and char_length(p_organizer_web) > 200 then
    raise exception 'invalid_organizer_web';
  end if;

  v_starts := coalesce(p_starts_at, v_event.starts_at);
  v_ends   := coalesce(p_ends_at, v_event.ends_at);
  if v_starts is not null and v_ends is not null and v_ends <= v_starts then
    raise exception 'invalid_dates';
  end if;

  -- ── event detalji ──────────────────────────────────────────────────────────
  update pinka_finance.events set
    event_type      = coalesce(p_event_type, event_type),
    venue_name      = coalesce(btrim(p_venue_name), venue_name),
    venue_address   = case when p_venue_address is null then venue_address
                           else nullif(btrim(p_venue_address), '') end,
    venue_city      = coalesce(btrim(p_venue_city), venue_city),
    starts_at       = coalesce(p_starts_at, starts_at),
    ends_at         = coalesce(p_ends_at, ends_at),
    timezone        = coalesce(btrim(p_timezone), timezone),
    description_hr  = case when p_description_hr is null then description_hr
                           else pinka_finance.sanitize_ugc(p_description_hr) end,
    description_en  = case when p_description_en is null then description_en
                           else pinka_finance.sanitize_ugc(p_description_en) end,
    cover_image_url = case when p_cover_image_url is null then cover_image_url
                           else nullif(p_cover_image_url, '') end,
    organizer_name  = coalesce(btrim(p_organizer_name), organizer_name),
    organizer_email = case when p_organizer_email is null then organizer_email
                           else nullif(btrim(p_organizer_email), '') end,
    organizer_web   = case when p_organizer_web is null then organizer_web
                           else nullif(btrim(p_organizer_web), '') end
  where campaign_id = p_campaign_id;

  -- ── campaign zrcalna polja (naslov/opis/termini/cover/Safe) ────────────────
  -- destination: guard trigger (campaigns_write_guard) blokira promjenu nakon
  -- prve plaćene uplate — ovdje se namjerno NE zaobilazi (INVOKER put).
  update pinka_finance.campaigns set
    title           = coalesce(btrim(p_title), title),
    destination_address = coalesce(p_destination_address, destination_address),
    description     = case when p_description_hr is null then description
                           else pinka_finance.sanitize_ugc(p_description_hr) end,
    starts_at       = coalesce(p_starts_at, starts_at),
    ends_at         = coalesce(p_ends_at, ends_at),
    cover_image_url = case when p_cover_image_url is null then cover_image_url
                           else nullif(p_cover_image_url, '') end,
    updated_at      = now()
  where id = p_campaign_id;

  -- ── tieri ──────────────────────────────────────────────────────────────────
  if p_tiers is not null then
    if jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) > 50 then
      raise exception 'invalid_tiers';
    end if;

    for v_tier in select * from jsonb_array_elements(p_tiers) loop
      if jsonb_typeof(v_tier) <> 'object'
         or nullif(btrim(coalesce(v_tier->>'title', '')), '') is null
         or char_length(v_tier->>'title') > 160 then
        raise exception 'invalid_tier_title';
      end if;
      if v_tier->>'price_cents' is null or v_tier->>'price_cents' !~ '^\d{1,9}$' then
        raise exception 'invalid_tier_price';
      end if;
      if v_tier ? 'inventory_total'
         and jsonb_typeof(v_tier->'inventory_total') <> 'null'
         and v_tier->>'inventory_total' !~ '^\d{1,7}$' then
        raise exception 'invalid_tier_inventory';
      end if;
      begin
        v_sale_start := (v_tier->>'sale_start')::timestamptz;
        v_sale_end   := (v_tier->>'sale_end')::timestamptz;
      exception when others then
        raise exception 'invalid_tier_sale_window';
      end;
      if v_sale_start is not null and v_sale_end is not null and v_sale_end <= v_sale_start then
        raise exception 'invalid_tier_sale_window';
      end if;

      v_price := (v_tier->>'price_cents')::integer;
      v_inventory := case
        when v_tier ? 'inventory_total' and jsonb_typeof(v_tier->'inventory_total') <> 'null'
          then (v_tier->>'inventory_total')::integer
        else null
      end;

      if v_tier ? 'id' and nullif(v_tier->>'id', '') is not null then
        -- postojeći tier
        begin
          v_tier_id := (v_tier->>'id')::uuid;
        exception when others then
          raise exception 'invalid_tier_id';
        end;
        select * into v_existing from pinka_finance.campaign_tiers
          where id = v_tier_id and campaign_id = p_campaign_id
          for update;
        if not found then raise exception 'tier_not_found'; end if;

        -- nakon objave: cijena i imenska su zaključane (kupci kupuju pod tim uvjetima)
        if v_campaign.state <> 'draft'
           and (v_existing.price_cents <> v_price
                or v_existing.imenska <> coalesce((v_tier->>'imenska')::boolean, v_existing.imenska)) then
          raise exception 'tier_locked';
        end if;
        if v_inventory is not null and v_inventory < v_existing.inventory_claimed then
          raise exception 'inventory_below_claimed';
        end if;

        update pinka_finance.campaign_tiers set
          title           = btrim(v_tier->>'title'),
          description     = case when v_tier ? 'description'
                                 then pinka_finance.sanitize_ugc(v_tier->>'description')
                                 else description end,
          price_cents     = v_price,
          imenska         = coalesce((v_tier->>'imenska')::boolean, imenska),
          inventory_total = case when v_tier ? 'inventory_total' then v_inventory else inventory_total end,
          sale_start      = case when v_tier ? 'sale_start' then v_sale_start else sale_start end,
          sale_end        = case when v_tier ? 'sale_end' then v_sale_end else sale_end end,
          sort            = coalesce((v_tier->>'sort')::integer, sort),
          updated_at      = now()
        where id = v_tier_id;
        v_updated := v_updated + 1;
      else
        -- novi tier (smije i nakon objave — npr. Early Bird → Regular faza)
        insert into pinka_finance.campaign_tiers (
          campaign_id, title, description, kind, price_cents, inventory_total,
          imenska, sale_start, sale_end, unit, sort
        ) values (
          p_campaign_id, btrim(v_tier->>'title'),
          pinka_finance.sanitize_ugc(v_tier->>'description'),
          'ticket', v_price, v_inventory,
          coalesce((v_tier->>'imenska')::boolean, false),
          v_sale_start, v_sale_end, 'seat',
          coalesce((v_tier->>'sort')::integer,
                   (select coalesce(max(sort), -1) + 1 from pinka_finance.campaign_tiers
                     where campaign_id = p_campaign_id))
        );
        v_added := v_added + 1;
      end if;
    end loop;
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'updated', true,
    'tiers_updated', v_updated,
    'tiers_added', v_added
  );
end;
$$;

revoke execute on function pinka_finance.update_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, text,
  text, text, text, text, text, text, jsonb
) from public, anon;
grant execute on function pinka_finance.update_event(
  uuid, text, text, text, text, text, text, timestamptz, timestamptz, text,
  text, text, text, text, text, text, jsonb
) to authenticated, service_role;

-- ----- 5. publish_event (DEFINER — state machine + allowlist gating) -----------
-- draft → active (publish; postavlja i visibility='public' — TO je objava) i
-- active|funded → closed. Aktivacija zahtijeva: org admin + allowlist + pravi
-- Safe (destination). Server-side gating — UI je samo zrcalo.
create or replace function pinka_finance.publish_event(
  p_campaign_id uuid,
  p_target_state text default 'active'
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if p_target_state is null or p_target_state not in ('active', 'closed') then
    raise exception 'invalid_target_state';
  end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  if p_target_state = 'active' then
    if v_campaign.state <> 'draft' then
      raise exception 'invalid_state_transition';
    end if;
    -- moderacija: samo allowlistani organizatori smiju u javni feed (pilot flag)
    if not exists (
      select 1 from pinka_finance.organizer_allowlist al
      where al.account_id = v_campaign.account_id
    ) then
      raise exception 'organizer_not_allowlisted';
    end if;
    -- bez pravog Safe-a nema objave (mirror campaigns_write_guard poruke)
    if v_campaign.destination_address is null
       or v_campaign.destination_address !~ '^0x[0-9a-fA-F]{40}$'
       or v_campaign.destination_address ~* '^0x0{40}$' then
      raise exception 'campaign_destination_missing';
    end if;

    update pinka_finance.campaigns
       set state = 'active', visibility = 'public', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.published', v_campaign.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  else
    if v_campaign.state not in ('active', 'funded') then
      raise exception 'invalid_state_transition';
    end if;

    update pinka_finance.campaigns
       set state = 'closed', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.closed', v_campaign.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'state', p_target_state,
    'visibility', case when p_target_state = 'active' then 'public'
                       else v_campaign.visibility::text end
  );
end;
$$;

revoke execute on function pinka_finance.publish_event(uuid, text) from public, anon;
grant execute on function pinka_finance.publish_event(uuid, text) to authenticated, service_role;

-- ----- 6. organizer_overview (DEFINER — jedan poziv za organizator UI) ---------
-- Moji org accounti (admin) s allowlist/DAC7 statusom + moji tickets eventi s
-- tierima, UKLJUČUJUĆI draftove (javni feed ih ne prikazuje). Bez PII kupaca.
create or replace function pinka_finance.organizer_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_accounts jsonb;
  v_events jsonb;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select coalesce(jsonb_agg(a.account_json order by a.name), '[]'::jsonb) into v_accounts
  from (
    select acc.name, jsonb_build_object(
      'id', acc.id,
      'name', acc.name,
      'is_personal', acc.is_personal_account,
      'allowlisted', exists (
        select 1 from pinka_finance.organizer_allowlist al where al.account_id = acc.id
      ),
      'has_record', exists (
        select 1 from pinka_finance.organizer_records r where r.account_id = acc.id
      )
    ) as account_json
    from public.accounts acc
    where acc.deleted_at is null
      and public.has_role_on_account(acc.id, 'admin')
  ) a;

  select coalesce(jsonb_agg(e.event_json order by e.created_at desc), '[]'::jsonb) into v_events
  from (
    select c.created_at, jsonb_build_object(
      'campaign_id', c.id,
      'account_id', c.account_id,
      'slug', c.slug,
      'title', c.title,
      'state', c.state::text,
      'visibility', c.visibility::text,
      'destination_address', c.destination_address,
      'event', (
        select jsonb_build_object(
          'event_type', ev.event_type,
          'venue_name', ev.venue_name,
          'venue_address', ev.venue_address,
          'venue_city', ev.venue_city,
          'starts_at', ev.starts_at,
          'ends_at', ev.ends_at,
          'timezone', ev.timezone,
          'description_hr', ev.description_hr,
          'description_en', ev.description_en,
          'cover_image_url', ev.cover_image_url,
          'organizer_name', ev.organizer_name,
          'organizer_email', ev.organizer_email,
          'organizer_web', ev.organizer_web
        )
        from pinka_finance.events ev where ev.campaign_id = c.id
      ),
      'tiers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'title', t.title,
          'description', t.description,
          'price_cents', t.price_cents,
          'inventory_total', t.inventory_total,
          'inventory_claimed', t.inventory_claimed,
          'imenska', t.imenska,
          'sale_start', t.sale_start,
          'sale_end', t.sale_end,
          'sort', t.sort
        ) order by t.sort)
        from pinka_finance.campaign_tiers t
        where t.campaign_id = c.id and t.kind = 'ticket'
      ), '[]'::jsonb)
    ) as event_json
    from pinka_finance.campaigns c
    where c.type = 'tickets'
      and c.deleted_at is null
      and public.has_role_on_account(c.account_id, 'admin')
  ) e;

  return jsonb_build_object('accounts', v_accounts, 'events', v_events);
end;
$$;

revoke execute on function pinka_finance.organizer_overview() from public, anon;
grant execute on function pinka_finance.organizer_overview() to authenticated, service_role;

-- ----- 7. upsert_organizer_record (DEFINER — DAC7 zapis) -----------------------
create or replace function pinka_finance.upsert_organizer_record(
  p_account_id uuid,
  p_legal_name text,
  p_oib text,
  p_address_line text,
  p_city text,
  p_postal_code text,
  p_country_code text default 'HR',
  p_contact_email text default null,
  p_financial_identifier_type text default 'safe_address',
  p_financial_identifier text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  -- service_role smije direktno (operaterski unos); inače org admin
  if coalesce((select auth.role()), '') <> 'service_role' then
    if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
    if not public.has_role_on_account(p_account_id, 'admin') then
      raise exception 'not_authorized';
    end if;
  end if;

  if p_legal_name is null or btrim(p_legal_name) = '' or char_length(p_legal_name) > 200 then
    raise exception 'invalid_legal_name';
  end if;
  if p_oib is null or p_oib !~ '^\d{11}$' then
    raise exception 'invalid_oib';
  end if;
  if p_address_line is null or btrim(p_address_line) = '' or char_length(p_address_line) > 200 then
    raise exception 'invalid_address';
  end if;
  if p_city is null or btrim(p_city) = '' or char_length(p_city) > 80 then
    raise exception 'invalid_city';
  end if;
  if p_postal_code is null or btrim(p_postal_code) = '' or char_length(p_postal_code) > 20 then
    raise exception 'invalid_postal_code';
  end if;
  if p_country_code is null or p_country_code !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country_code';
  end if;
  if p_contact_email is not null and char_length(p_contact_email) > 200 then
    raise exception 'invalid_contact_email';
  end if;
  if p_financial_identifier_type is null
     or p_financial_identifier_type not in ('iban', 'safe_address') then
    raise exception 'invalid_financial_identifier_type';
  end if;
  if p_financial_identifier is null
     or (p_financial_identifier_type = 'iban'
         and p_financial_identifier !~ '^[A-Z]{2}\d{2}[A-Z0-9]{1,30}$')
     or (p_financial_identifier_type = 'safe_address'
         and p_financial_identifier !~ '^0x[0-9a-fA-F]{40}$') then
    raise exception 'invalid_financial_identifier';
  end if;

  insert into pinka_finance.organizer_records (
    account_id, legal_name, oib, address_line, city, postal_code,
    country_code, contact_email, financial_identifier_type, financial_identifier
  ) values (
    p_account_id, btrim(p_legal_name), p_oib, btrim(p_address_line), btrim(p_city),
    btrim(p_postal_code), p_country_code,
    nullif(btrim(coalesce(p_contact_email, '')), ''),
    p_financial_identifier_type, p_financial_identifier
  )
  on conflict (account_id) do update set
    legal_name                = excluded.legal_name,
    oib                       = excluded.oib,
    address_line              = excluded.address_line,
    city                      = excluded.city,
    postal_code               = excluded.postal_code,
    country_code              = excluded.country_code,
    contact_email             = excluded.contact_email,
    financial_identifier_type = excluded.financial_identifier_type,
    financial_identifier      = excluded.financial_identifier,
    updated_at                = now();

  -- audit bez PII u payloadu
  perform public.log_event('organizer_record.upserted', p_account_id,
    jsonb_build_object('account_id', p_account_id));

  return jsonb_build_object('account_id', p_account_id, 'saved', true);
end;
$$;

revoke execute on function pinka_finance.upsert_organizer_record(
  uuid, text, text, text, text, text, text, text, text, text
) from public, anon;
grant execute on function pinka_finance.upsert_organizer_record(
  uuid, text, text, text, text, text, text, text, text, text
) to authenticated, service_role;

select 'OK events_organizer' as status;
