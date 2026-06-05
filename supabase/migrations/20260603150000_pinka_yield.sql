-- =============================================================================
-- pinka_finance — yield faza: idle EURe kampanje oplođuje se na Aave v3 (Gnosis)
-- Reference: domovina-api/docs/pinka-yield-execution.md
--
-- Model: per-campaign opt-in (vlasnik toggla, default OFF; flag u
-- campaigns.metadata.yield.enabled). Prinos PRIPADA kampanji → povećava
-- raspoloživo za isplatu. Glavnica supplyana u Aave i dalje je dio
-- total_raised_cents (ista sredstva) → NE dvostruko brojimo; jedini dodatak je
-- accrued_yield_cents. Stanje pozicije održava off-chain keeper (pay.domovina.ai/
-- ops, Zodiac Roles + DeFi Kit) preko service_role RPC-eva — vidi docs.
--
-- Cilj venue = Aave v3 na Gnosisu (Aave v4 je Ethereum-only, bez EURe/Gnosisa).
-- `protocol` stupac predviđa kasniju promjenu venuea.
-- =============================================================================

-- ===== yield_positions (jedna po kampanji) ===================================
create table if not exists pinka_finance.yield_positions (
  campaign_id         uuid primary key references pinka_finance.campaigns(id) on delete cascade,
  protocol            text not null default 'aave_v3_gnosis',
  asset               text not null default 'EURe',
  principal_cents     bigint not null default 0,   -- neto supplyano (deposit − withdraw)
  last_balance_cents  bigint not null default 0,   -- zadnji očitani aToken saldo
  accrued_yield_cents bigint not null default 0,   -- max(last_balance − principal, 0)
  atoken_address      text,
  status              text not null default 'idle'
                        check (status in ('idle','active','paused')),
  last_synced_at      timestamptz,
  updated_at          timestamptz not null default now(),
  constraint principal_nonneg check (principal_cents >= 0),
  constraint accrued_nonneg check (accrued_yield_cents >= 0)
);

alter table pinka_finance.yield_positions enable row level security;

grant select on pinka_finance.yield_positions to anon, authenticated, service_role;
grant insert, update, delete on pinka_finance.yield_positions to service_role;

-- select: čitljivo kad je matična kampanja čitljiva (vlasnik kampanje/kanala
-- ili javna kampanja). Prinos je dio transparentnog prikaza.
drop policy if exists yield_positions_select on pinka_finance.yield_positions;
create policy yield_positions_select on pinka_finance.yield_positions
  for select to anon, authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id
        and c.deleted_at is null
        and (
          (c.visibility in ('public','unlisted') and c.state in ('active','funded','closed'))
          or public.is_account_member(c.account_id)
          or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
        )
    )
  );

-- ===== set_campaign_yield (authenticated; vlasnik toggla opt-in) =============
create or replace function pinka_finance.set_campaign_yield(
  p_campaign_id uuid,
  p_enabled     boolean
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);
  update pinka_finance.campaigns
     set metadata = jsonb_set(
           coalesce(metadata, '{}'::jsonb),
           '{yield,enabled}',
           to_jsonb(coalesce(p_enabled, false)),
           true
         ),
         updated_at = now()
   where id = p_campaign_id;
  -- osiguraj poziciju (idle) da se prinos može pratiti čim keeper krene
  insert into pinka_finance.yield_positions (campaign_id, status)
  values (p_campaign_id, case when p_enabled then 'idle' else 'paused' end)
  on conflict (campaign_id) do update set
    status = case when p_enabled then 'active' else 'paused' end,
    updated_at = now();
end;
$$;

revoke all on function pinka_finance.set_campaign_yield(uuid, boolean) from public, anon;
grant execute on function pinka_finance.set_campaign_yield(uuid, boolean) to authenticated, service_role;

-- ===== keeper RPC-evi (service_role) =========================================
create or replace function pinka_finance.record_yield_deposit(
  p_campaign_id uuid, p_cents bigint, p_atoken text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  insert into pinka_finance.yield_positions (campaign_id, principal_cents, atoken_address, status)
  values (p_campaign_id, greatest(coalesce(p_cents,0),0), p_atoken, 'active')
  on conflict (campaign_id) do update set
    principal_cents = pinka_finance.yield_positions.principal_cents + greatest(coalesce(p_cents,0),0),
    atoken_address  = coalesce(p_atoken, pinka_finance.yield_positions.atoken_address),
    status          = 'active',
    updated_at      = now();
end;
$$;

create or replace function pinka_finance.record_yield_withdraw(
  p_campaign_id uuid, p_cents bigint
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update pinka_finance.yield_positions
     set principal_cents = greatest(principal_cents - greatest(coalesce(p_cents,0),0), 0),
         updated_at = now()
   where campaign_id = p_campaign_id;
end;
$$;

create or replace function pinka_finance.sync_yield_balance(
  p_campaign_id uuid, p_balance_cents bigint, p_atoken text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
declare v_bal bigint := greatest(coalesce(p_balance_cents,0),0);
begin
  insert into pinka_finance.yield_positions (
    campaign_id, last_balance_cents, accrued_yield_cents, atoken_address, last_synced_at, status
  ) values (
    p_campaign_id, v_bal, 0, p_atoken, now(), 'active'
  )
  on conflict (campaign_id) do update set
    last_balance_cents  = v_bal,
    accrued_yield_cents = greatest(v_bal - pinka_finance.yield_positions.principal_cents, 0),
    atoken_address      = coalesce(p_atoken, pinka_finance.yield_positions.atoken_address),
    last_synced_at      = now(),
    updated_at          = now();
end;
$$;

revoke all on function pinka_finance.record_yield_deposit(uuid, bigint, text) from public, anon, authenticated;
revoke all on function pinka_finance.record_yield_withdraw(uuid, bigint)       from public, anon, authenticated;
revoke all on function pinka_finance.sync_yield_balance(uuid, bigint, text)    from public, anon, authenticated;
grant execute on function pinka_finance.record_yield_deposit(uuid, bigint, text) to service_role;
grant execute on function pinka_finance.record_yield_withdraw(uuid, bigint)       to service_role;
grant execute on function pinka_finance.sync_yield_balance(uuid, bigint, text)    to service_role;

-- ===== request_payout: available + accrued_yield =============================
-- create or replace (iz 20260603140000_pinka_payouts.sql) — available sada
-- uključuje akumulirani prinos (prinos pripada kampanji).
create or replace function pinka_finance.request_payout(
  p_campaign_id  uuid,
  p_destination  text,
  p_amount_cents bigint
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dest      text := btrim(coalesce(p_destination, ''));
  v_kyc       boolean;
  v_available bigint;
  v_id        uuid;
begin
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);

  select coalesce((u.raw_app_meta_data->>'kyc_verified')::boolean, false)
    into v_kyc from auth.users u where u.id = (select auth.uid());
  if not coalesce(v_kyc, false) then
    raise exception 'kyc_required';
  end if;

  if not (
    v_dest ~ '^0x[0-9a-fA-F]{40}$'
    or upper(replace(v_dest, ' ', '')) ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'
  ) then
    raise exception 'invalid_destination';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'invalid_amount';
  end if;

  -- raspoloživo = prikupljeno − aktivne isplate + akumulirani prinos (kampanji)
  select coalesce(s.total_raised_cents, 0)
       - coalesce((
           select sum(p.amount_cents) from pinka_finance.payouts p
           where p.campaign_id = p_campaign_id
             and p.state in ('requested','approved','submitted','confirmed')
         ), 0)
       + coalesce((
           select y.accrued_yield_cents from pinka_finance.yield_positions y
           where y.campaign_id = p_campaign_id
         ), 0)
    into v_available
    from pinka_finance.campaign_stats s
   where s.campaign_id = p_campaign_id;
  v_available := coalesce(v_available, 0);

  if p_amount_cents > v_available then
    raise exception 'amount_exceeds_available';
  end if;

  insert into pinka_finance.payouts (
    campaign_id, amount_cents, destination, state, requested_by
  ) values (
    p_campaign_id, p_amount_cents, v_dest, 'requested', (select auth.uid())
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function pinka_finance.request_payout(uuid, text, bigint) from public, anon;
grant execute on function pinka_finance.request_payout(uuid, text, bigint) to authenticated, service_role;

select 'OK pinka_yield' as status;
