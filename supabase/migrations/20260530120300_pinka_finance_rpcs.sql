-- =============================================================================
-- 13 — pinka_finance RPC-evi + business trigeri
-- Reference: domovina-api/docs/pinka-finance-platform-plan.md §2, §3
--
-- Tok (Phase 1):
--   1. klijent/edge poziva pinka_finance.create_contribution(...)  → contribution (pending)
--   2. edge fn  POST pay-worker /api/intents { target=destination, metadata }
--   3. edge fn  pinka_finance.attach_intent(contribution_id, sid)  (service_role)
--   4. korisnik plati SEPA → Monerium mint → rail forwarda na campaign Safe
--   5. pay-worker outbound webhook → edge fn → pinka_finance.mark_contribution_paid(sid, tx)
--   6. trigeri: log event, campaign_stats, tier inventory, funded flip, token_position
--
-- Sve funkcije: security definer set search_path = '' (sve reference qualified).
-- =============================================================================

-- ----- create_contribution (authenticated + service_role) --------------------
-- Validira kampanju/tier/iznos, rezolvira doprinositeljev personal account iz
-- auth.uid() (null za cisti service/gost put), upisuje pending contribution.
-- Vraca podatke koje edge fn treba za kreiranje payment intenta.
create or replace function pinka_finance.create_contribution(
  p_campaign_id  uuid,
  p_amount_cents bigint,
  p_tier_id      uuid    default null,
  p_display_name text    default null,
  p_message      text    default null,
  p_anonymous    boolean default false,
  p_quantity     integer default 1
) returns table (
  contribution_id     uuid,
  amount_cents        bigint,
  currency            text,
  destination_address text
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
  v_tier     pinka_finance.campaign_tiers;
  v_account  uuid;
  v_qty      integer := greatest(coalesce(p_quantity, 1), 1);
  v_id       uuid;
begin
  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  if p_amount_cents is null
     or p_amount_cents < greatest(v_campaign.min_contribution_cents, 1) then
    raise exception 'amount_below_minimum';
  end if;

  if p_tier_id is not null then
    select * into v_tier from pinka_finance.campaign_tiers
      where id = p_tier_id and campaign_id = p_campaign_id;
    if not found then raise exception 'tier_not_found'; end if;
    if v_tier.inventory_total is not null
       and v_tier.inventory_claimed + v_qty > v_tier.inventory_total then
      raise exception 'tier_sold_out';
    end if;
  end if;

  -- doprinositeljev personal account (null ako nema JWT / gost / cisti service)
  select id into v_account from public.accounts
    where primary_owner_user_id = (select auth.uid())
      and is_personal_account = true
      and deleted_at is null
    limit 1;

  insert into pinka_finance.contributions (
    campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message
  ) values (
    p_campaign_id, p_tier_id, v_account,
    p_amount_cents, v_campaign.currency, v_qty, 'pending',
    v_campaign.destination_address, coalesce(p_anonymous, false),
    nullif(btrim(p_display_name), ''), nullif(btrim(p_message), '')
  ) returning id into v_id;

  return query
    select v_id, p_amount_cents, v_campaign.currency, v_campaign.destination_address;
end;
$$;

revoke execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) from public, anon;
grant  execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) to authenticated, service_role;

-- ----- attach_intent (service_role) ------------------------------------------
-- Edge fn nakon kreiranja payment intenta sprema sid na pending contribution.
create or replace function pinka_finance.attach_intent(
  p_contribution_id uuid,
  p_sid             text,
  p_monerium_order_id text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update pinka_finance.contributions
     set payment_intent_sid = p_sid,
         monerium_order_id  = coalesce(p_monerium_order_id, monerium_order_id),
         updated_at         = now()
   where id = p_contribution_id and state = 'pending';
end;
$$;

revoke execute on function pinka_finance.attach_intent(uuid,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.attach_intent(uuid,text,text) to service_role;

-- ----- mark_contribution_paid (service_role; webhook) ------------------------
-- Idempotentno: oznaci paid SAMO ako je jos pending. Vraca true ako je bas sad
-- prebaceno (false = vec paid / nepoznat sid). Trigeri rade ostalo.
create or replace function pinka_finance.mark_contribution_paid(
  p_sid                   text,
  p_tx_hash               text,
  p_amount_received_cents bigint default null
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_updated integer;
begin
  update pinka_finance.contributions
     set state                 = 'paid',
         forward_tx_hash       = p_tx_hash,
         amount_received_cents = coalesce(p_amount_received_cents, amount_received_cents, amount_cents),
         paid_at               = now(),
         updated_at            = now()
   where payment_intent_sid = p_sid and state = 'pending';
  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

revoke execute on function pinka_finance.mark_contribution_paid(text,text,bigint) from public, anon, authenticated;
grant  execute on function pinka_finance.mark_contribution_paid(text,text,bigint) to service_role;

-- =============================================================================
-- Trigeri
-- =============================================================================

-- ----- campaign insert → kreiraj prazan stats redak --------------------------
create or replace function pinka_finance.tg_campaign_created() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into pinka_finance.campaign_stats (campaign_id)
  values (new.id)
  on conflict (campaign_id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_campaign_created on pinka_finance.campaigns;
create trigger trg_campaign_created
  after insert on pinka_finance.campaigns
  for each row execute function pinka_finance.tg_campaign_created();

-- ----- contribution insert → log 'contribution.created' ----------------------
create or replace function pinka_finance.tg_contribution_created() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (
    new.id, new.campaign_id, 'contribution.created',
    jsonb_build_object('amount_cents', new.amount_cents, 'tier_id', new.tier_id, 'quantity', new.quantity)
  );
  return new;
end;
$$;

drop trigger if exists trg_contribution_created on pinka_finance.contributions;
create trigger trg_contribution_created
  after insert on pinka_finance.contributions
  for each row execute function pinka_finance.tg_contribution_created();

-- ----- contribution state change → events + stats + tier + funded + token ----
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

  if new.state = 'paid' then
    -- tier inventory
    if new.tier_id is not null then
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

drop trigger if exists trg_contribution_state on pinka_finance.contributions;
create trigger trg_contribution_state
  after update of state on pinka_finance.contributions
  for each row execute function pinka_finance.tg_contribution_state();

select 'OK 13 pinka_finance_rpcs' as status;
