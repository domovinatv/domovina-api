-- =============================================================================
-- pinka.finance — verified badge requires a faithful display name
-- Reference: pinka-onchain-receipts-tokenization-plan.md
--
-- A Certilia-verified contributor's name is prefilled, but they may edit it. An
-- eID "verified" badge next to an arbitrary self-typed name is misleading. So:
-- the wall's verification badges only apply when the DISPLAYED name faithfully
-- matches the contributor's Certilia identity (every displayed token belongs to
-- the eID name; empty name = no false claim, still counts). Change the name →
-- you keep the option but lose the badge.
--
--   display_name_verified — snapshot at creation: display_name is consistent
--                           with the contributor's Certilia/eID name.
-- View gates `verified` and `identity_double_verified` on it. `bank_verified`
-- stays independent (it's about the payment rail, not the displayed name).
-- =============================================================================

alter table pinka_finance.contributions
  add column if not exists display_name_verified boolean not null default false;

comment on column pinka_finance.contributions.display_name_verified is
  'Snapshot: the wall display_name faithfully matches the contributor''s Certilia '
  'name (every shown token ∈ eID name; empty name counts). Gates the eID badges.';

-- Every token of the DISPLAYED name must belong to the Certilia name set
-- (display ⊆ identity). "Marko" and "Marko Horvat" pass for eID "Marko Horvat";
-- "Marko Kovač" fails. Empty display = true (anonymous-on-wall, no false claim).
create or replace function pinka_finance.display_name_matches_identity(
  p_account uuid,
  p_display text
) returns boolean
language sql stable security definer set search_path = ''
as $$
  with cert as (
    select pinka_finance.norm_name(coalesce(iv.first_name,'') || ' ' || coalesce(iv.last_name,'')) as n
    from public.identity_verifications iv
    join public.accounts a on a.primary_owner_user_id = iv.user_id
    where a.id = p_account
    limit 1
  ), disp as (
    select pinka_finance.norm_name(p_display) as n
  )
  select case
    when p_account is null then false
    when (select n from cert) is null or (select n from cert) = '' then false
    when (select n from disp) is null or (select n from disp) = '' then true
    else (
      select bool_and(tok = any(string_to_array((select n from cert), ' ')))
      from regexp_split_to_table((select n from disp), '\s+') as tok
      where tok <> ''
    )
  end
$$;
revoke execute on function pinka_finance.display_name_matches_identity(uuid,text) from public, anon, authenticated;
grant  execute on function pinka_finance.display_name_matches_identity(uuid,text) to service_role, authenticated;

-- ----- create_contribution — snapshot display_name_verified ------------------
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
  v_verified boolean := false;
  v_display_ok boolean := false;
  v_qty      integer := greatest(coalesce(p_quantity, 1), 1);
  v_name     text := nullif(btrim(p_display_name), '');
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

  -- displayed name must faithfully match the eID identity to keep the badge
  v_display_ok := pinka_finance.display_name_matches_identity(v_account, v_name);

  insert into pinka_finance.contributions (
    campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message,
    contributor_verified, display_name_verified
  ) values (
    p_campaign_id, p_tier_id, v_account,
    p_amount_cents, v_campaign.currency, v_qty, 'pending',
    v_campaign.destination_address, coalesce(p_anonymous, false),
    v_name, nullif(btrim(p_message), ''),
    coalesce(v_verified, false), coalesce(v_display_ok, false)
  ) returning id into v_id;

  return query
    select v_id, p_amount_cents, v_campaign.currency, v_campaign.destination_address;
end;
$$;
revoke execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) from public, anon;
grant  execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) to authenticated, service_role;

-- ----- public wall: gate eID badges on the display-name match ----------------
create or replace view pinka_finance.public_contributions as
  select
    ct.id,
    ct.campaign_id,
    ct.display_name,
    case when ct.message_hidden then null else ct.message end       as message,
    ct.amount_cents,
    ct.currency,
    ct.created_at,
    ct.paid_at,
    case when ct.message_hidden then null else ct.link_preview end   as link_preview,
    (ct.contributor_verified and ct.display_name_verified)          as verified,
    ct.bank_verified                                                as bank_verified,
    (ct.identity_double_verified and ct.display_name_verified)      as identity_double_verified
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id
  where ct.state = 'paid'
    and ct.anonymous = false
    and c.deleted_at is null
    and c.visibility = 'public'
    and c.state in ('active','funded','closed');

grant select on pinka_finance.public_contributions to anon, authenticated, service_role;

select 'OK pinka_finance display_name_verified' as status;
