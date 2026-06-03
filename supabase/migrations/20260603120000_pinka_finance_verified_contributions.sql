-- =============================================================================
-- pinka.finance — verificirana uplata (Certilia / NIAS eID → implicitni KYC/AML)
-- Reference: docs/pinka-finance-platform-plan.md, supabase/functions/certilia
--
-- Cilj: kad je doprinositelj prijavljen preko eOsobne (Certilia), uplatu vodimo
-- kao 100% verificiranu — stvarna osoba potvrđena od RH je vezana uz uplatu.
--
-- Pristup: NEPROMJENJIVI SNAPSHOT u trenutku kreiranja doprinosa, ne live join.
--   - create_contribution rezolvira auth.uid() → public.accounts (vec radi) i
--     dodatno provjerava postoji li public.identity_verifications za tog usera;
--     rezultat (boolean) se zamrzava u contributions.contributor_verified.
--   - To je AML/audit zapis: "ova uplata = Certilia-verificirana osoba @ vrijeme".
--     OIB/ime ostaju iskljucivo u sifriranoj identity_verifications (cl.5(1)(c)).
--   - public_contributions view izlaze SAMO boolean `verified` — nikad OIB ni
--     bilo koji PII. View se izvrsava s pravima vlasnika (security_invoker off),
--     pa cita snapshot kolonu i kad je RLS na contributions ukljucen.
--
-- Audit trag (kad treba povezati uplatu sa stvarnom osobom za AML/regulatora):
--   contribution.contributor_account_id → public.accounts.primary_owner_user_id
--   → public.identity_verifications (sifrirani OIB, ime, LoA, verified_at).
-- =============================================================================

-- ----- 1) snapshot kolona ----------------------------------------------------
alter table pinka_finance.contributions
  add column if not exists contributor_verified boolean not null default false;

comment on column pinka_finance.contributions.contributor_verified is
  'Snapshot: doprinositelj je u trenutku uplate bio Certilia/eID verificiran '
  '(implicitni KYC/AML). Immutable AML zapis; PII ostaje u identity_verifications.';

-- ----- 2) create_contribution — upisi verified snapshot ----------------------
-- Identicno postojecoj funkciji (20260530120300) + rezolucija v_verified iz
-- public.identity_verifications za auth.uid() i upis u novu kolonu.
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

  -- KYC snapshot: ima li prijavljeni user verificirani eID identitet?
  -- (identity_verifications je keyed po auth.users.id; jedan red = verificiran)
  if (select auth.uid()) is not null then
    select exists(
      select 1 from public.identity_verifications iv
       where iv.user_id = (select auth.uid())
    ) into v_verified;
  end if;

  insert into pinka_finance.contributions (
    campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message,
    contributor_verified
  ) values (
    p_campaign_id, p_tier_id, v_account,
    p_amount_cents, v_campaign.currency, v_qty, 'pending',
    v_campaign.destination_address, coalesce(p_anonymous, false),
    nullif(btrim(p_display_name), ''), nullif(btrim(p_message), ''),
    coalesce(v_verified, false)
  ) returning id into v_id;

  return query
    select v_id, p_amount_cents, v_campaign.currency, v_campaign.destination_address;
end;
$$;

revoke execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) from public, anon;
grant  execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer) to authenticated, service_role;

-- ----- 3) public_contributions view — izlozi `verified` ----------------------
-- Zadrzi sve iz 20260602150000 (link_preview + message_hidden) + dodaj verified.
-- Samo boolean izlazi; OIB/ime se NIKAD ne projeciraju u view.
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
    ct.contributor_verified                                          as verified
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id
  where ct.state = 'paid'
    and ct.anonymous = false
    and c.deleted_at is null
    and c.visibility = 'public'
    and c.state in ('active','funded','closed');

grant select on pinka_finance.public_contributions to anon, authenticated, service_role;

select 'OK pinka_finance verified contributions' as status;
