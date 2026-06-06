-- =============================================================================
-- pinka.finance — DECLARED recurrence schedule for subscriptions
-- Reference: 20260606120000_pinka_finance_subscriptions.sql
--            + [[recurring-recognition-not-charging]]
--
-- The base subscriptions feature INFERS cadence from observed payment gaps. This
-- adds a DECLARED schedule defined on the campaign (the obligation), so an
-- expected due date exists from the very FIRST payment — and a member who skips
-- the next cycle lapses on schedule, not only after we've seen two payments.
--
-- This is the shared rail for recurring obligations beyond memberships: on-chain
-- standing orders (trajni nalog) for utility bills, where a public utility
-- company is a campaign and the bill is due on a fixed day of the month — all
-- with NO transaction fees for any side. Still recognition, NEVER auto-charge:
-- the schedule is the EXPECTED date, the payer always pushes the payment.
--
--   campaigns.recurrence            none | monthly | quarterly | yearly
--   campaigns.recurrence_anchor_day NULL = anchor to each member's first payment
--                                   1..31 = fixed day of month (monthly; clamped
--                                   to month length, e.g. 31 → 28/29/30)
-- =============================================================================

do $$ begin
  create type pinka_finance.recurrence as enum
    ('none','monthly','quarterly','yearly');
exception when duplicate_object then null;
end $$;

alter table pinka_finance.campaigns
  add column if not exists recurrence            pinka_finance.recurrence not null default 'none',
  add column if not exists recurrence_anchor_day smallint;

do $$ begin
  alter table pinka_finance.campaigns
    add constraint recurrence_anchor_day_valid
    check (recurrence_anchor_day is null or recurrence_anchor_day between 1 and 31);
exception when duplicate_object then null;
end $$;

comment on column pinka_finance.campaigns.recurrence is
  'Declared recurring obligation cadence (membership / utility bill). none = one-off.';
comment on column pinka_finance.campaigns.recurrence_anchor_day is
  'Fixed day-of-month the payment is expected (1..31, clamped). NULL = anchor to '
  'each member''s own first-payment day.';

-- ----- next due date from a declared schedule --------------------------------
-- Next occurrence of `p_day` strictly after p_from, clamped to month length.
create or replace function pinka_finance._next_monthly_anchor(
  p_from timestamptz, p_day smallint
) returns timestamptz
language sql stable
as $$
  with base as (select date_trunc('month', p_from) as m0),
  cand as (
    select
      m0,
      least(p_day, extract(day from (m0 + interval '1 month - 1 day'))::int)  as d0,
      least(p_day, extract(day from (m0 + interval '2 month - 1 day'))::int)  as d1
    from base
  )
  select case
    when (m0 + make_interval(days => d0 - 1)) > p_from
      then  m0 + make_interval(days => d0 - 1)
    else   (m0 + interval '1 month') + make_interval(days => d1 - 1)
  end
  from cand
$$;

-- Anchor_day applies to monthly only; quarterly/yearly step from p_from.
create or replace function pinka_finance.next_due(
  p_from        timestamptz,
  p_recurrence  pinka_finance.recurrence,
  p_anchor_day  smallint
) returns timestamptz
language sql stable
as $$
  select case p_recurrence
    when 'monthly' then
      case when p_anchor_day is null
        then p_from + interval '1 month'
        else pinka_finance._next_monthly_anchor(p_from, p_anchor_day)
      end
    when 'quarterly' then p_from + interval '3 months'
    when 'yearly'    then p_from + interval '1 year'
    else null  -- 'none'
  end
$$;

-- nominal interval (days) for a declared cadence — scales the lapse grace
create or replace function pinka_finance.recurrence_nominal_days(
  p_recurrence pinka_finance.recurrence
) returns integer
language sql immutable
as $$
  select case p_recurrence
    when 'monthly'   then 30
    when 'quarterly' then 91
    when 'yearly'    then 365
    else null
  end
$$;

-- ----- trigger: maintain subscription, now schedule-aware ---------------------
create or replace function pinka_finance.tg_contribution_subscription() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_count       integer;
  v_first       timestamptz;
  v_last        timestamptz;
  v_total       bigint;
  v_last_amount bigint;
  v_obs         integer;     -- observed avg gap (days)
  v_interval    integer;     -- value stored (declared nominal or observed) for grace
  v_cadence     pinka_finance.subscription_cadence;  -- OBSERVED cadence
  v_next        timestamptz;
  v_rec         pinka_finance.recurrence;
  v_anchor      smallint;
begin
  if new.payer_iban_hash is null then
    return new;
  end if;
  if new.state = old.state then
    return new;
  end if;

  select recurrence, recurrence_anchor_day
    into v_rec, v_anchor
    from pinka_finance.campaigns where id = new.campaign_id;
  v_rec := coalesce(v_rec, 'none');

  select count(*), min(paid_at), max(paid_at),
         coalesce(sum(coalesce(amount_received_cents, amount_cents)), 0)
    into v_count, v_first, v_last, v_total
    from pinka_finance.contributions
   where campaign_id = new.campaign_id
     and payer_iban_hash = new.payer_iban_hash
     and state = 'paid';

  if v_count = 0 then
    update pinka_finance.subscriptions
       set contribution_count = 0, total_cents = 0,
           next_expected_at = null, updated_at = now()
     where campaign_id = new.campaign_id
       and payer_iban_hash = new.payer_iban_hash;
    return new;
  end if;

  select coalesce(amount_received_cents, amount_cents) into v_last_amount
    from pinka_finance.contributions
   where campaign_id = new.campaign_id
     and payer_iban_hash = new.payer_iban_hash
     and state = 'paid'
   order by paid_at desc nulls last
   limit 1;

  if v_count >= 2 and v_last > v_first then
    v_obs := greatest(1,
      round(extract(epoch from (v_last - v_first)) / 86400.0 / (v_count - 1))::integer);
  else
    v_obs := null;
  end if;

  v_cadence := case
    when v_obs is null            then 'unknown'
    when v_obs between  24 and  38 then 'monthly'
    when v_obs between  80 and 100 then 'quarterly'
    when v_obs between 330 and 400 then 'yearly'
    else 'irregular'
  end;

  if v_rec <> 'none' then
    -- declared schedule drives the expected date from the first payment on
    v_next     := pinka_finance.next_due(v_last, v_rec, v_anchor);
    v_interval := coalesce(v_obs, pinka_finance.recurrence_nominal_days(v_rec));
  else
    v_interval := v_obs;
    v_next     := case when v_obs is not null
                       then v_last + make_interval(days => v_obs) else null end;
  end if;

  insert into pinka_finance.subscriptions (
    campaign_id, payer_iban_hash, contributor_account_id, display_name,
    status, cadence, interval_days, contribution_count, total_cents,
    first_contribution_at, last_contribution_at, last_amount_cents, next_expected_at
  ) values (
    new.campaign_id, new.payer_iban_hash, new.contributor_account_id,
    nullif(btrim(new.display_name), ''),
    'active', v_cadence, v_interval, v_count, v_total,
    v_first, v_last, v_last_amount, v_next
  )
  on conflict (campaign_id, payer_iban_hash) do update set
    contributor_account_id = coalesce(
      pinka_finance.subscriptions.contributor_account_id, excluded.contributor_account_id),
    display_name = coalesce(excluded.display_name, pinka_finance.subscriptions.display_name),
    status = case
      when pinka_finance.subscriptions.status = 'cancelled'
           and excluded.contribution_count > pinka_finance.subscriptions.contribution_count
        then 'active'::pinka_finance.subscription_status
      else pinka_finance.subscriptions.status
    end,
    cancelled_at = case
      when pinka_finance.subscriptions.status = 'cancelled'
           and excluded.contribution_count > pinka_finance.subscriptions.contribution_count
        then null
      else pinka_finance.subscriptions.cancelled_at
    end,
    cadence              = excluded.cadence,
    interval_days        = excluded.interval_days,
    contribution_count   = excluded.contribution_count,
    total_cents          = excluded.total_cents,
    first_contribution_at = excluded.first_contribution_at,
    last_contribution_at = excluded.last_contribution_at,
    last_amount_cents    = excluded.last_amount_cents,
    next_expected_at     = excluded.next_expected_at,
    updated_at           = now();

  return new;
end;
$$;

-- ----- recompute schedule live when the owner edits campaign terms ------------
create or replace function pinka_finance.tg_campaign_recurrence() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.recurrence is not distinct from old.recurrence
     and new.recurrence_anchor_day is not distinct from old.recurrence_anchor_day then
    return new;
  end if;

  update pinka_finance.subscriptions s
     set interval_days = case
           when new.recurrence <> 'none'
             then coalesce(s.interval_days, pinka_finance.recurrence_nominal_days(new.recurrence))
           else s.interval_days end,
         next_expected_at = case
           when new.recurrence <> 'none'
             then pinka_finance.next_due(s.last_contribution_at, new.recurrence, new.recurrence_anchor_day)
           when s.interval_days is not null
             then s.last_contribution_at + make_interval(days => s.interval_days)
           else null end,
         updated_at = now()
   where s.campaign_id = new.id
     and s.last_contribution_at is not null;
  return new;
end;
$$;

drop trigger if exists trg_campaign_recurrence on pinka_finance.campaigns;
create trigger trg_campaign_recurrence
  after update of recurrence, recurrence_anchor_day on pinka_finance.campaigns
  for each row execute function pinka_finance.tg_campaign_recurrence();

-- ----- view: expose effective (declared-or-observed) cadence + terms ---------
create or replace view pinka_finance.subscriptions_view
  with (security_invoker = on) as
  select
    s.*,
    pinka_finance.subscription_effective_status(
      s.status, s.next_expected_at, s.interval_days)              as effective_status,
    case when c.recurrence <> 'none'
         then c.recurrence::text else s.cadence::text end          as effective_cadence,
    (c.recurrence <> 'none')                                       as declared,
    c.recurrence                                                   as campaign_recurrence,
    c.recurrence_anchor_day                                        as campaign_anchor_day
  from pinka_finance.subscriptions s
  join pinka_finance.campaigns c on c.id = s.campaign_id;

grant select on pinka_finance.subscriptions_view to authenticated, service_role;

select 'OK pinka_finance subscription schedule (declared recurrence)' as status;
