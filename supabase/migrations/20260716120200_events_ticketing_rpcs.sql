-- =============================================================================
-- Događaji (E2) — RPC-evi + trigger proširenje
--
-- Tok (v. 11-dogadjaji §3.3):
--   1. organizator: create_event(...)            → campaign(type=tickets) + events + tiers
--   2. app: events-order → create_ticket_order   → pending narudžba + REZERVACIJA (TTL 20 min)
--   3. kupac plaća EURe kupčev Safe → organizatorov Safe (postojeći Send flow)
--   4. app: events-confirm {order_id, tx_hash}   → edge verificira receipt na Gnosis RPC-u
--      → confirm_ticket_order (service_role)     → paid + izdavanje N ulaznica (QR tokeni)
--   5. app: events-tickets                       → deliver_ticket_orders (tokeni jednokratno)
--
-- Autorizacijski model narudžbe: order id je client-generated random UUID —
-- bearer capability, isti presedan kao pinka_finance.contribution_status
-- (20260602120000). Backend nikad ne drži ključeve ni sredstva; "onchain
-- verifikacija JE autorizacija" za kreditiranje (pinka-onchain-confirm obrazac,
-- pooštren vezanjem tx-a uz KONKRETNU narudžbu + provjerom iznosa/primatelja).
--
-- Sve write funkcije: security definer set search_path = ''; eksplicitni
-- revoke/grant. create_event je security INVOKER (kao create_campaign) — RLS
-- insert policy (has_role_on_account admin + KYC) i dalje vrijedi.
-- =============================================================================

-- ----- create_event (organizator; INVOKER — RLS vrijedi) -----------------------
-- Nad obrascem create_campaign hardening: idempotencija (client-generated id;
-- retry vraća postojeći event), rate limit (campaigns_write_guard: 20/24 h),
-- server-side slug, cross-field validacija. Tieri se predaju kao jsonb array:
--   [{title, price_cents, inventory_total?, imenska?, sale_start?, sale_end?,
--     description?, sort?}]
create or replace function pinka_finance.create_event(
  p_id uuid,
  p_account_id uuid,
  p_title text,
  p_destination_address text,
  p_venue_name text,
  p_venue_city text,
  p_event_type text default 'ostalo',
  p_venue_address text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_timezone text default 'Europe/Zagreb',
  p_description_hr text default null,
  p_description_en text default null,
  p_cover_image_url text default null,
  p_organizer_name text default null,
  p_organizer_email text default null,
  p_organizer_web text default null,
  p_visibility text default 'private',
  p_tiers jsonb default '[]'::jsonb
) returns jsonb
language plpgsql
-- security INVOKER (default): RLS insert policy (admin + KYC) i dalje vrijedi
as $$
declare
  v_campaign jsonb;
  v_tier jsonb;
  v_price bigint;
  v_inventory integer;
  v_sale_start timestamptz;
  v_sale_end timestamptz;
  v_sort integer := 0;
begin
  -- ── validacija event polja (strojni kodovi, kao create_campaign) ──────────
  if p_venue_name is null or btrim(p_venue_name) = '' or char_length(p_venue_name) > 160 then
    raise exception 'invalid_venue_name';
  end if;
  if p_venue_city is null or btrim(p_venue_city) = '' or char_length(p_venue_city) > 80 then
    raise exception 'invalid_venue_city';
  end if;
  if p_event_type is null or p_event_type !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'invalid_event_type';
  end if;
  if p_timezone is null or btrim(p_timezone) = '' or char_length(p_timezone) > 64 then
    raise exception 'invalid_timezone';
  end if;
  if p_tiers is null or jsonb_typeof(p_tiers) <> 'array' or jsonb_array_length(p_tiers) > 50 then
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
  end loop;

  -- ── campaign kroz postojeći hardening RPC (idempotencija + validacija) ────
  v_campaign := pinka_finance.create_campaign(
    p_id                     => p_id,
    p_account_id             => p_account_id,
    p_title                  => p_title,
    p_type                   => 'tickets',
    p_description            => p_description_hr,
    p_destination_address    => p_destination_address,
    p_subject_type           => 'event',
    p_visibility             => p_visibility,
    p_cover_image_url        => p_cover_image_url,
    p_starts_at              => p_starts_at,
    p_ends_at                => p_ends_at
  );

  -- retry s istim id-em: kampanja (i event/tieri) već postoje — vrati postojeće
  if coalesce((v_campaign->>'existing')::boolean, false) then
    return v_campaign || jsonb_build_object('event_created', false);
  end if;

  insert into pinka_finance.events (
    campaign_id, event_type, venue_name, venue_address, venue_city,
    starts_at, ends_at, timezone, description_hr, description_en,
    cover_image_url, organizer_name, organizer_email, organizer_web
  ) values (
    p_id, p_event_type, btrim(p_venue_name), nullif(btrim(coalesce(p_venue_address, '')), ''),
    btrim(p_venue_city), p_starts_at, p_ends_at, btrim(p_timezone),
    nullif(btrim(coalesce(p_description_hr, '')), ''), nullif(btrim(coalesce(p_description_en, '')), ''),
    p_cover_image_url, coalesce(nullif(btrim(coalesce(p_organizer_name, '')), ''), btrim(p_title)),
    nullif(btrim(coalesce(p_organizer_email, '')), ''), nullif(btrim(coalesce(p_organizer_web, '')), '')
  );

  for v_tier in select * from jsonb_array_elements(p_tiers) loop
    v_price := (v_tier->>'price_cents')::bigint;
    v_inventory := case
      when v_tier ? 'inventory_total' and jsonb_typeof(v_tier->'inventory_total') <> 'null'
        then (v_tier->>'inventory_total')::integer
      else null
    end;
    insert into pinka_finance.campaign_tiers (
      campaign_id, title, description, kind, price_cents, inventory_total,
      imenska, sale_start, sale_end, unit, sort
    ) values (
      p_id, btrim(v_tier->>'title'), nullif(btrim(coalesce(v_tier->>'description', '')), ''),
      'ticket', v_price::integer, v_inventory,
      coalesce((v_tier->>'imenska')::boolean, false),
      (v_tier->>'sale_start')::timestamptz, (v_tier->>'sale_end')::timestamptz,
      'seat', v_sort
    );
    v_sort := v_sort + 1;
  end loop;

  return v_campaign || jsonb_build_object('event_created', true);
end;
$$;

revoke execute on function pinka_finance.create_event(
  uuid, uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  text, text, text, text, text, text, text, text, jsonb
) from public, anon;
grant execute on function pinka_finance.create_event(
  uuid, uuid, text, text, text, text, text, text, timestamptz, timestamptz,
  text, text, text, text, text, text, text, text, jsonb
) to authenticated, service_role;

-- ----- expire_stale_ticket_orders (rezervacija s TTL-om — otpuštanje) ---------
-- Poziva se oportunistički iz events-order/events-tickets edge funkcija (i može
-- iz pg_crona kad/ako se doda; isti opt-in obrazac kao handoff cleanup 06).
-- Inventory otpušta tg_contribution_state (pending→expired, reserved).
create or replace function pinka_finance.expire_stale_ticket_orders()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_expired integer;
begin
  update pinka_finance.contributions
     set state = 'expired', updated_at = now()
   where state = 'pending'
     and reserved
     and reserve_expires_at is not null
     and reserve_expires_at < now();
  get diagnostics v_expired = row_count;
  return v_expired;
end;
$$;

revoke execute on function pinka_finance.expire_stale_ticket_orders() from public, anon, authenticated;
grant execute on function pinka_finance.expire_stale_ticket_orders() to service_role;

-- ----- tg_contribution_state — rezervacijska semantika ------------------------
-- Identično 20260530120300 + dvije izmjene za ulaznice (reserved=true):
--   * paid: inventory se NE inkrementira ponovno (rezerviran na create_ticket_order)
--   * pending→expired: rezervacija se OTPUŠTA (dekrement, floor 0)
create or replace function pinka_finance.tg_contribution_state() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_total bigint;
  v_count integer;
  v_contributors integer;
begin
  if new.state = old.state then
    return new;
  end if;

  -- log svaku tranziciju stanja
  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (
    new.id, new.campaign_id, 'contribution.' || new.state::text,
    jsonb_build_object(
      'from', old.state::text,
      'tx_hash', new.forward_tx_hash,
      'amount_received_cents', new.amount_received_cents
    )
  );

  -- ulaznice: istek pending narudžbe vraća rezervirani inventory
  if new.state = 'expired' and old.state = 'pending' and new.reserved and new.tier_id is not null then
    update pinka_finance.campaign_tiers
       set inventory_claimed = greatest(inventory_claimed - new.quantity, 0),
           updated_at = now()
     where id = new.tier_id;
  end if;

  if new.state = 'paid' then
    -- tier inventory (rezervirane ticket narudžbe su već ubrojane na create)
    if new.tier_id is not null and not new.reserved then
      update pinka_finance.campaign_tiers
         set inventory_claimed = inventory_claimed + new.quantity,
             updated_at = now()
       where id = new.tier_id;
    end if;

    -- autoritativni agregat (re-sum, ne inkrement — robusno na refundove kasnije)
    select coalesce(sum(amount_cents), 0), count(*)
      into v_total, v_count
      from pinka_finance.contributions
     where campaign_id = new.campaign_id and state = 'paid';

    select count(distinct contributor_account_id)
      into v_contributors
      from pinka_finance.contributions
     where campaign_id = new.campaign_id and state = 'paid'
       and contributor_account_id is not null;

    insert into pinka_finance.campaign_stats (
      campaign_id, total_raised_cents, contribution_count,
      contributor_count, last_contribution_at, updated_at
    ) values (
      new.campaign_id, v_total, v_count, v_contributors, now(), now()
    )
    on conflict (campaign_id) do update set
      total_raised_cents   = excluded.total_raised_cents,
      contribution_count   = excluded.contribution_count,
      contributor_count    = excluded.contributor_count,
      last_contribution_at = excluded.last_contribution_at,
      updated_at           = now();

    -- flip na funded kad je cilj dosegnut
    update pinka_finance.campaigns
       set state = 'funded'
     where id = new.campaign_id
       and goal_cents is not null
       and state = 'active'
       and v_total >= goal_cents;

    -- soft tokenizacija: jedna pozicija po doprinosu
    if exists (
      select 1 from pinka_finance.campaigns c
      where c.id = new.campaign_id and c.type = 'tokenization'
    ) then
      insert into pinka_finance.token_positions (
        campaign_id, contribution_id, holder_account_id, units, status
      ) values (
        new.campaign_id, new.id, new.contributor_account_id,
        coalesce(new.amount_received_cents, new.amount_cents), 'pending'
      )
      on conflict (contribution_id) do nothing;
    end if;
  end if;

  return new;
end;
$$;
-- trigger sam ostaje iz 20260530120300 (drop/create nije potreban za replace tijela)

-- ----- create_ticket_order (narudžba + rezervacija) ---------------------------
-- p_order_id je client-generated random UUID: idempotency ključ (retry vraća
-- postojeću narudžbu) I bearer capability za events-tickets (presedan:
-- contribution_status 20260602120000). p_holders: [{full_name, email?}] —
-- imenska ⇒ točno qty potpunih imena (MoMo: ulaznica glasi na ime).
create or replace function pinka_finance.create_ticket_order(
  p_order_id uuid,
  p_campaign_id uuid,
  p_tier_id uuid,
  p_quantity integer,
  p_holders jsonb default '[]'::jsonb,
  p_payer_address text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
  v_tier pinka_finance.campaign_tiers;
  v_existing pinka_finance.contributions;
  v_account uuid;
  v_verified boolean := false;
  v_holders jsonb := '[]'::jsonb;
  v_holder jsonb;
  v_recent integer;
  v_expires timestamptz;
  i integer;
begin
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_quantity is null or p_quantity < 1 or p_quantity > 10 then
    raise exception 'invalid_quantity';
  end if;
  if p_payer_address is not null and p_payer_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_payer_address';
  end if;

  -- oportunistički housekeeping: oslobodi istekle rezervacije prije checka
  perform pinka_finance.expire_stale_ticket_orders();

  -- ── idempotencija: retry s istim id-em vraća postojeću narudžbu ───────────
  select * into v_existing from pinka_finance.contributions where id = p_order_id;
  if found then
    return jsonb_build_object(
      'order_id', v_existing.id,
      'state', v_existing.state::text,
      'amount_cents', v_existing.amount_cents,
      'currency', v_existing.currency,
      'destination_address', v_existing.destination_address,
      'expires_at', v_existing.reserve_expires_at,
      'existing', true
    );
  end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  select * into v_tier from pinka_finance.campaign_tiers
    where id = p_tier_id and campaign_id = p_campaign_id;
  if not found then raise exception 'tier_not_found'; end if;
  if v_tier.kind <> 'ticket' then raise exception 'tier_not_ticket'; end if;
  if v_tier.sale_start is not null and now() < v_tier.sale_start then
    raise exception 'sale_not_started';
  end if;
  if v_tier.sale_end is not null and now() > v_tier.sale_end then
    raise exception 'sale_ended';
  end if;
  if v_tier.price_cents <= 0 then raise exception 'tier_price_missing'; end if;

  -- ── imenska ⇒ qty potpunih imena (trim; višak se odbacuje) ────────────────
  if v_tier.imenska then
    if p_holders is null or jsonb_typeof(p_holders) <> 'array'
       or jsonb_array_length(p_holders) < p_quantity then
      raise exception 'holders_incomplete';
    end if;
    for i in 0..(p_quantity - 1) loop
      v_holder := p_holders->i;
      if jsonb_typeof(v_holder) <> 'object'
         or nullif(btrim(coalesce(v_holder->>'full_name', '')), '') is null then
        raise exception 'holders_incomplete';
      end if;
      if char_length(v_holder->>'full_name') > 120
         or char_length(coalesce(v_holder->>'email', '')) > 200 then
        raise exception 'invalid_holder';
      end if;
      v_holders := v_holders || jsonb_build_object(
        'full_name', btrim(v_holder->>'full_name'),
        'email', nullif(btrim(coalesce(v_holder->>'email', '')), '')
      );
    end loop;
  end if;

  -- doprinositeljev personal account + KYC snapshot (kao create_contribution)
  select id into v_account from public.accounts
    where primary_owner_user_id = (select auth.uid())
      and is_personal_account = true
      and deleted_at is null
    limit 1;
  if (select auth.uid()) is not null then
    select exists(
      select 1 from public.identity_verifications iv
       where iv.user_id = (select auth.uid())
    ) into v_verified;
  end if;

  -- ── rate limit: max 10 narudžbi / h po kupcu (account ili payer Safe) ─────
  select count(*) into v_recent
  from pinka_finance.contributions c
  where c.created_at > now() - interval '1 hour'
    and (
      (v_account is not null and c.contributor_account_id = v_account)
      or (p_payer_address is not null and c.declared_payer_address = lower(p_payer_address))
    );
  if v_recent >= 10 then
    raise exception 'order_rate_limited';
  end if;

  -- ── rezervacija + oversell check u ISTOJ naredbi (row lock na tier) ───────
  update pinka_finance.campaign_tiers
     set inventory_claimed = inventory_claimed + p_quantity,
         updated_at = now()
   where id = p_tier_id
     and (inventory_total is null or inventory_claimed + p_quantity <= inventory_total);
  if not found then
    raise exception 'tier_sold_out';
  end if;

  v_expires := now() + interval '20 minutes';

  insert into pinka_finance.contributions (
    id, campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, contributor_verified,
    holders, reserved, reserve_expires_at, declared_payer_address
  ) values (
    p_order_id, p_campaign_id, p_tier_id, v_account,
    v_tier.price_cents::bigint * p_quantity, v_campaign.currency, p_quantity, 'pending',
    v_campaign.destination_address, false, coalesce(v_verified, false),
    v_holders, true, v_expires,
    case when p_payer_address is null then null else lower(p_payer_address) end
  );

  return jsonb_build_object(
    'order_id', p_order_id,
    'state', 'pending',
    'amount_cents', v_tier.price_cents::bigint * p_quantity,
    'currency', v_campaign.currency,
    'destination_address', v_campaign.destination_address,
    'expires_at', v_expires,
    'existing', false
  );
end;
$$;

revoke execute on function pinka_finance.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) from public, anon;
grant execute on function pinka_finance.create_ticket_order(uuid,uuid,uuid,integer,jsonb,text) to authenticated, service_role;

-- ----- confirm_ticket_order (service_role; poziva events-confirm) -------------
-- Veže verificirani EURe transfer (tx_hash + log_index, iznos/primatelj već
-- provjereni na Gnosis RPC-u u edge funkciji) uz KONKRETNU narudžbu i
-- idempotentno izda quantity ulaznica. Tokeni se NE vraćaju odavde — dostava
-- ide isključivo kroz deliver_ticket_orders (jednokratno).
--
-- Poslovni ne-uspjesi (tx_already_credited, amount_insufficient,
-- expired_sold_out) se vraćaju kao status jsonb, NE kao exception — exception
-- bi rollbackao audit event za ručno sparivanje (§8 reconciliation).
create or replace function pinka_finance.confirm_ticket_order(
  p_order_id uuid,
  p_tx_hash text,
  p_log_index integer,
  p_from text,
  p_amount_cents bigint
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order pinka_finance.contributions;
  v_tier pinka_finance.campaign_tiers;
  v_other uuid;
  v_token text;
  v_serial text;
  v_prefix text;
  v_base integer;
  v_slug text;
  v_holder jsonb;
  v_serials text[] := '{}';
  i integer;
begin
  select * into v_order from pinka_finance.contributions
    where id = p_order_id
    for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.tier_id is null or not v_order.reserved then
    raise exception 'not_a_ticket_order';
  end if;

  -- idempotencija: isti tx za istu narudžbu = no-op (ulaznice već izdane)
  if v_order.state = 'paid' then
    if v_order.forward_tx_hash = p_tx_hash
       and v_order.onchain_log_index is not distinct from p_log_index then
      select coalesce(array_agg(t.serial order by t.serial), '{}') into v_serials
        from pinka_finance.tickets t where t.contribution_id = p_order_id;
      return jsonb_build_object('status', 'already_paid', 'order_id', p_order_id, 'serials', v_serials);
    end if;
    raise exception 'order_already_paid';
  end if;
  if v_order.state not in ('pending', 'expired') then
    raise exception 'order_not_payable';
  end if;

  -- (tx, log) smije kreditirati SAMO jednom — i preko ingest/confirm puteva
  select id into v_other from pinka_finance.contributions
    where forward_tx_hash = p_tx_hash and onchain_log_index = p_log_index
      and id <> p_order_id;
  if found then
    -- nesparena uplata (npr. cron ingest ju je već kreditirao kao generičku
    -- donaciju) → označi za ručno sparivanje, ne dupliciraj kredit (§8)
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.match_conflict',
            jsonb_build_object('tx_hash', p_tx_hash, 'log_index', p_log_index, 'other_contribution_id', v_other));
    return jsonb_build_object('status', 'tx_already_credited', 'order_id', p_order_id);
  end if;

  if p_amount_cents is null or p_amount_cents < v_order.amount_cents then
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.underpaid',
            jsonb_build_object('tx_hash', p_tx_hash, 'log_index', p_log_index,
                               'expected_cents', v_order.amount_cents, 'received_cents', p_amount_cents));
    return jsonb_build_object('status', 'amount_insufficient', 'order_id', p_order_id,
                              'expected_cents', v_order.amount_cents, 'received_cents', p_amount_cents);
  end if;

  -- istekla rezervacija, a uplata je stvarno sletjela → pokušaj ponovno zauzeti
  if v_order.state = 'expired' then
    update pinka_finance.campaign_tiers
       set inventory_claimed = inventory_claimed + v_order.quantity,
           updated_at = now()
     where id = v_order.tier_id
       and (inventory_total is null or inventory_claimed + v_order.quantity <= inventory_total);
    if not found then
      insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
      values (p_order_id, v_order.campaign_id, 'ticket_order.expired_sold_out',
              jsonb_build_object('tx_hash', p_tx_hash, 'log_index', p_log_index));
      return jsonb_build_object('status', 'expired_sold_out', 'order_id', p_order_id);
    end if;
  end if;

  update pinka_finance.contributions
     set state                 = 'paid',
         forward_tx_hash       = p_tx_hash,
         onchain_log_index     = p_log_index,
         onchain_from          = lower(coalesce(p_from, '')),
         amount_received_cents = p_amount_cents,
         paid_at               = now(),
         updated_at            = now()
   where id = p_order_id;

  -- ── izdavanje ulaznica: serial + random 32-bajtni token (u bazi hash) ─────
  -- advisory lock po kampanji serijalizira brojač seriala (race dva confirma)
  perform pg_advisory_xact_lock(hashtext('pinka_tickets_' || v_order.campaign_id::text));

  select slug::text into v_slug from pinka_finance.campaigns where id = v_order.campaign_id;
  v_prefix := upper(left(regexp_replace(coalesce(v_slug, ''), '[^a-zA-Z]', '', 'g'), 3));
  if v_prefix = '' then v_prefix := 'EVT'; end if;
  select count(*)::integer into v_base from pinka_finance.tickets where campaign_id = v_order.campaign_id;

  for i in 1..v_order.quantity loop
    v_serial := v_prefix || '-' || lpad((v_base + i)::text, 6, '0');
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_holder := case
      when v_order.holders is not null and jsonb_typeof(v_order.holders) = 'array'
        then v_order.holders->(i - 1)
      else null
    end;
    insert into pinka_finance.tickets (
      contribution_id, campaign_id, tier_id, serial,
      holder_name, holder_email, qr_token_hash, qr_token_once, state
    ) values (
      p_order_id, v_order.campaign_id, v_order.tier_id, v_serial,
      v_holder->>'full_name', v_holder->>'email',
      encode(extensions.digest(v_token, 'sha256'), 'hex'), v_token, 'issued'
    );
    v_serials := v_serials || v_serial;
  end loop;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_order_id, v_order.campaign_id, 'tickets.issued',
          jsonb_build_object('count', v_order.quantity, 'serials', to_jsonb(v_serials)));

  return jsonb_build_object('status', 'paid', 'order_id', p_order_id, 'serials', v_serials);
end;
$$;

revoke execute on function pinka_finance.confirm_ticket_order(uuid,text,integer,text,bigint) from public, anon, authenticated;
grant execute on function pinka_finance.confirm_ticket_order(uuid,text,integer,text,bigint) to service_role;

-- ----- deliver_ticket_orders (service_role; poziva events-tickets) ------------
-- Dostava narudžbi + ulaznica kupcu autoriziranom posjedovanjem order UUID-ova
-- (bearer capability). QR token se isporučuje JEDNOKRATNO: qr_token_once se
-- briše nakon dostave — u bazi trajno ostaje samo hash.
create or replace function pinka_finance.deliver_ticket_orders(p_order_ids uuid[])
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if p_order_ids is null or array_length(p_order_ids, 1) is null then
    return '[]'::jsonb;
  end if;
  if array_length(p_order_ids, 1) > 50 then
    raise exception 'too_many_orders';
  end if;

  -- oportunistički housekeeping (isti kao create_ticket_order)
  perform pinka_finance.expire_stale_ticket_orders();

  select coalesce(jsonb_agg(o.order_json), '[]'::jsonb) into v_result
  from (
    select jsonb_build_object(
      'order_id', c.id,
      'state', c.state::text,
      'quantity', c.quantity,
      'amount_cents', c.amount_cents,
      'currency', c.currency,
      'expires_at', c.reserve_expires_at,
      'tx_hash', c.forward_tx_hash,
      'tickets', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'serial', t.serial,
          'holder_name', t.holder_name,
          'holder_email', t.holder_email,
          'state', t.state::text,
          'checked_in_at', t.checked_in_at,
          'qr_token', t.qr_token_once
        ) order by t.serial)
        from pinka_finance.tickets t
        where t.contribution_id = c.id
      ), '[]'::jsonb)
    ) as order_json
    from pinka_finance.contributions c
    where c.id = any(p_order_ids)
      and c.tier_id is not null
      and c.reserved
  ) o;

  -- jednokratna dostava: plaintext se briše, ostaje samo hash
  update pinka_finance.tickets
     set qr_token_once = null,
         updated_at = now()
   where contribution_id = any(p_order_ids)
     and qr_token_once is not null;

  return v_result;
end;
$$;

revoke execute on function pinka_finance.deliver_ticket_orders(uuid[]) from public, anon, authenticated;
grant execute on function pinka_finance.deliver_ticket_orders(uuid[]) to service_role;

-- ----- list_my_tickets (authenticated; pinka SPA korisnici) -------------------
-- Ulaznice prijavljenog korisnika (kontributor narudžbe). BEZ QR tokena —
-- tokeni idu isključivo kroz jednokratnu dostavu (deliver_ticket_orders).
create or replace function pinka_finance.list_my_tickets()
returns table (
  ticket_id uuid,
  contribution_id uuid,
  campaign_id uuid,
  campaign_title text,
  serial text,
  holder_name text,
  state text,
  checked_in_at timestamptz,
  created_at timestamptz
)
language sql stable security definer set search_path = ''
as $$
  select t.id, t.contribution_id, t.campaign_id, c.title,
         t.serial, t.holder_name, t.state::text, t.checked_in_at, t.created_at
  from pinka_finance.tickets t
  join pinka_finance.contributions ct on ct.id = t.contribution_id
  join pinka_finance.campaigns c on c.id = t.campaign_id
  where ct.contributor_account_id is not null
    and public.is_account_member(ct.contributor_account_id)
  order by t.created_at desc, t.serial;
$$;

revoke execute on function pinka_finance.list_my_tickets() from public, anon;
grant execute on function pinka_finance.list_my_tickets() to authenticated, service_role;

select 'OK events_ticketing_rpcs' as status;
