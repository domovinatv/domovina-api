-- =============================================================================
-- pinka.finance — membership / recurring supporters (subscriptions)
-- Reference: pinka-onchain-receipts-tokenization-plan.md (members groundwork)
--
-- PRODUCT PRINCIPLE — recognition, NOT charging. This is pinka.io's core
-- differentiator vs traditional card recurring (Stripe + card mandate):
--   • The contributor APPROVES every single payment. SEPA is a PUSH rail: each
--     payment is initiated by the payer (manually via the permanent QR, or by a
--     standing order / trajni nalog they set at their OWN bank and can cancel
--     for free at any time). There is NO direct-debit mandate, NO stored card,
--     NO auto-charge — pinka cannot pull money, it can only observe it arrive.
--   • Because there are no card-processor fees, this makes recurring MICRO-
--     donations viable (cents-scale), which card recurring cannot do.
--   • It also can't be gamed the way card "subscriptions" can (e.g. a Revolut
--     virtual card cancelled right after setup so the recurring charge is only
--     apparent / never actually settles). Here every recorded payment is a real,
--     settled SEPA transfer.
--
-- We therefore RECOGNISE recurring supporters rather than charge them: every
-- paid contribution carries a salted `payer_iban_hash` (HMAC of the sender IBAN,
-- no raw PII — see 20260605130000), and (campaign_id, payer_iban_hash) uniquely
-- identifies a supporter relationship = a "subscription".
--
-- A subscription is AUTO-MAINTAINED by trigger from the contributions ledger:
--   • count / total / first / last / last amount   (re-summed, refund-robust)
--   • cadence + interval_days                       (inferred from payment gaps)
--   • next_expected_at = last + interval
--   • status: active (stored) | cancelled (sticky, manual); a fresh payment
--     reactivates a cancelled one. "lapsed" is TIME-DEPENDENT and derived live
--     (subscription_effective_status / subscriptions_view), never stored.
--
-- Privacy: same posture as the rest of pinka — no raw IBAN/name here, only the
-- hash + opt-in public display_name snapshot. Owner-facing (member list); not on
-- the public wall.
-- =============================================================================

-- ----- enums -----------------------------------------------------------------
do $$ begin
  create type pinka_finance.subscription_status as enum
    ('active','cancelled');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.subscription_cadence as enum
    ('monthly','quarterly','yearly','irregular','unknown');
exception when duplicate_object then null;
end $$;

-- ----- subscriptions (one per campaign × payer IBAN) -------------------------
create table if not exists pinka_finance.subscriptions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  payer_iban_hash text not null,                          -- HMAC; never raw IBAN
  contributor_account_id uuid references public.accounts(id) on delete set null,
  display_name text,                                      -- opt-in public snapshot, NOT PII
  status pinka_finance.subscription_status not null default 'active',
  cancelled_at timestamptz,
  cadence pinka_finance.subscription_cadence not null default 'unknown',
  interval_days integer,                                  -- inferred avg gap (null until 2 payments)
  contribution_count integer not null default 0,
  total_cents bigint not null default 0,
  first_contribution_at timestamptz,
  last_contribution_at timestamptz,
  last_amount_cents bigint,
  next_expected_at timestamptz,                           -- last_contribution_at + interval
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (campaign_id, payer_iban_hash)
);
create index if not exists ix_subscriptions_campaign
  on pinka_finance.subscriptions(campaign_id, status);
create index if not exists ix_subscriptions_contributor
  on pinka_finance.subscriptions(contributor_account_id)
  where contributor_account_id is not null;
create index if not exists ix_subscriptions_next_expected
  on pinka_finance.subscriptions(next_expected_at)
  where status = 'active';

drop trigger if exists trg_subscriptions_updated on pinka_finance.subscriptions;
create trigger trg_subscriptions_updated
  before update on pinka_finance.subscriptions
  for each row execute function public.touch_updated_at();

-- ----- effective status (derived live; "lapsed" depends on now()) ------------
-- Stored status is only active|cancelled. A member who quietly stops paying is
-- "lapsed": past next_expected_at plus a cadence-scaled grace (interval/3, min 7d).
create or replace function pinka_finance.subscription_effective_status(
  p_status        pinka_finance.subscription_status,
  p_next_expected timestamptz,
  p_interval_days integer
) returns text
language sql stable
as $$
  select case
    when p_status = 'cancelled' then 'cancelled'
    when p_next_expected is null then 'active'  -- cadence not established yet
    when now() > p_next_expected
                 + make_interval(days => greatest(7, coalesce(p_interval_days, 30) / 3))
      then 'lapsed'
    else 'active'
  end
$$;

-- ----- trigger: maintain subscription from the contributions ledger ----------
create or replace function pinka_finance.tg_contribution_subscription() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_count       integer;
  v_first       timestamptz;
  v_last        timestamptz;
  v_total       bigint;
  v_last_amount bigint;
  v_interval    integer;
  v_cadence     pinka_finance.subscription_cadence;
  v_next        timestamptz;
begin
  -- only SEPA (named bank sender) contributions carry a hash; on-chain has none
  if new.payer_iban_hash is null then
    return new;
  end if;
  if new.state = old.state then
    return new;
  end if;

  -- re-sum the whole relationship from paid rows (robust to refunds)
  select count(*), min(paid_at), max(paid_at),
         coalesce(sum(coalesce(amount_received_cents, amount_cents)), 0)
    into v_count, v_first, v_last, v_total
    from pinka_finance.contributions
   where campaign_id = new.campaign_id
     and payer_iban_hash = new.payer_iban_hash
     and state = 'paid';

  -- everything refunded/none paid: zero the counters, leave status untouched
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

  -- average gap between payments (days); null until a second payment exists
  if v_count >= 2 and v_last > v_first then
    v_interval := greatest(1,
      round(extract(epoch from (v_last - v_first)) / 86400.0 / (v_count - 1))::integer);
  else
    v_interval := null;
  end if;

  v_cadence := case
    when v_interval is null            then 'unknown'
    when v_interval between  24 and  38 then 'monthly'
    when v_interval between  80 and 100 then 'quarterly'
    when v_interval between 330 and 400 then 'yearly'
    else 'irregular'
  end;

  v_next := case
    when v_interval is not null then v_last + make_interval(days => v_interval)
    else null
  end;

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
    -- retain the best-known identity / name once learned
    contributor_account_id = coalesce(
      pinka_finance.subscriptions.contributor_account_id, excluded.contributor_account_id),
    display_name = coalesce(excluded.display_name, pinka_finance.subscriptions.display_name),
    -- a new payment after a cancel = resubscribe; otherwise keep cancel sticky
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

drop trigger if exists trg_contribution_subscription on pinka_finance.contributions;
create trigger trg_contribution_subscription
  after update of state on pinka_finance.contributions
  for each row execute function pinka_finance.tg_contribution_subscription();

-- ----- cancel_subscription (campaign admin OR the subscriber) -----------------
-- Marks a subscription cancelled (sticky). A later payment auto-reactivates it.
create or replace function pinka_finance.cancel_subscription(p_subscription_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign uuid;
  v_account  uuid;
  v_owner    uuid;
begin
  select campaign_id, contributor_account_id
    into v_campaign, v_account
    from pinka_finance.subscriptions where id = p_subscription_id;
  if not found then
    return false;
  end if;

  select account_id into v_owner from pinka_finance.campaigns where id = v_campaign;

  if public.has_role_on_account(v_owner, 'admin')
     or (v_account is not null and public.is_account_member(v_account)) then
    update pinka_finance.subscriptions
       set status = 'cancelled', cancelled_at = now(), updated_at = now()
     where id = p_subscription_id;
    return true;
  end if;

  raise exception 'not_authorized';
end;
$$;
revoke execute on function pinka_finance.cancel_subscription(uuid) from public, anon;
grant  execute on function pinka_finance.cancel_subscription(uuid) to authenticated, service_role;

-- ----- RLS: subscriber sees own; campaign admin sees the campaign's members ---
alter table pinka_finance.subscriptions enable row level security;

grant select on pinka_finance.subscriptions to authenticated;
grant select, insert, update, delete on pinka_finance.subscriptions to service_role;

drop policy if exists subscriptions_select on pinka_finance.subscriptions;
create policy subscriptions_select on pinka_finance.subscriptions
  for select to authenticated
  using (
    public.is_account_member(contributor_account_id)
    or exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ----- subscriptions_view: adds live effective_status (RLS via invoker) -------
create or replace view pinka_finance.subscriptions_view
  with (security_invoker = on) as
  select
    s.*,
    pinka_finance.subscription_effective_status(
      s.status, s.next_expected_at, s.interval_days) as effective_status
  from pinka_finance.subscriptions s;

grant select on pinka_finance.subscriptions_view to authenticated, service_role;

-- ----- backfill from existing paid SEPA contributions ------------------------
-- The trigger only fires on future state changes; seed the table from history so
-- existing recurring supporters appear immediately. Idempotent (do nothing).
insert into pinka_finance.subscriptions (
  campaign_id, payer_iban_hash, contributor_account_id, display_name,
  status, cadence, interval_days, contribution_count, total_cents,
  first_contribution_at, last_contribution_at, last_amount_cents, next_expected_at
)
select
  agg.campaign_id, agg.payer_iban_hash, agg.contributor_account_id, agg.display_name,
  'active',
  case
    when agg.interval_days is null            then 'unknown'
    when agg.interval_days between  24 and  38 then 'monthly'
    when agg.interval_days between  80 and 100 then 'quarterly'
    when agg.interval_days between 330 and 400 then 'yearly'
    else 'irregular'
  end::pinka_finance.subscription_cadence,
  agg.interval_days, agg.cnt, agg.total,
  agg.first_at, agg.last_at, agg.last_amount,
  case when agg.interval_days is not null
       then agg.last_at + make_interval(days => agg.interval_days) else null end
from (
  select
    c.campaign_id,
    c.payer_iban_hash,
    (array_agg(c.contributor_account_id)
       filter (where c.contributor_account_id is not null))[1]            as contributor_account_id,
    (array_agg(nullif(btrim(c.display_name), '') order by c.paid_at desc)
       filter (where nullif(btrim(c.display_name), '') is not null))[1]    as display_name,
    count(*)                                                              as cnt,
    coalesce(sum(coalesce(c.amount_received_cents, c.amount_cents)), 0)   as total,
    min(c.paid_at)                                                        as first_at,
    max(c.paid_at)                                                        as last_at,
    (array_agg(coalesce(c.amount_received_cents, c.amount_cents)
       order by c.paid_at desc))[1]                                       as last_amount,
    case when count(*) >= 2 and max(c.paid_at) > min(c.paid_at)
         then greatest(1, round(extract(epoch from (max(c.paid_at) - min(c.paid_at)))
                                / 86400.0 / (count(*) - 1))::integer)
         else null end                                                    as interval_days
  from pinka_finance.contributions c
  where c.payer_iban_hash is not null and c.state = 'paid'
  group by c.campaign_id, c.payer_iban_hash
) agg
on conflict (campaign_id, payer_iban_hash) do nothing;

select 'OK pinka_finance subscriptions (memberships)' as status;
