-- =============================================================================
-- 12 — pinka_finance grants + RLS policies
-- Reference: domovina-api/docs/pinka-finance-platform-plan.md §3
--
-- Model pristupa:
--   campaigns / campaign_tiers / campaign_stats — javno citljive (anon) kad je
--     kampanja public|unlisted i state in (active,funded,closed); pisanje samo
--     vlasnik (has_role_on_account admin) preko PostgREST-a.
--   contributions / contribution_events / token_positions — citaju vlasnik
--     kampanje i sam doprinositelj; pisanje NIKAD direktno s klijenta — ide kroz
--     security-definer RPC-eve (13) ili service_role (edge webhook).
--   payouts — samo vlasnik kampanje cita; pisanje service_role / RPC.
--   public_contributions view — anon "zid donatora" (samo paid, ne-anonimni).
--
-- Helperi iz 03: public.is_account_member(uuid), public.has_role_on_account(uuid,role).
-- =============================================================================

-- ----- schema usage ----------------------------------------------------------
grant usage on schema pinka_finance to anon, authenticated, service_role;

-- ----- table grants ("may attempt"; RLS odlucuje "may see/modify") -----------
-- Javno citljive tablice: anon dobiva select.
grant select on pinka_finance.campaigns       to anon, authenticated, service_role;
grant select on pinka_finance.campaign_tiers  to anon, authenticated, service_role;
grant select on pinka_finance.campaign_stats  to anon, authenticated, service_role;
-- vlasnik upravlja kampanjom/tierovima preko PostgREST-a (RLS gating ispod)
grant insert, update, delete on pinka_finance.campaigns      to authenticated, service_role;
grant insert, update, delete on pinka_finance.campaign_tiers to authenticated, service_role;

-- Osjetljivije tablice: NEMA anon. authenticated samo SELECT (RLS gated); sav
-- write ide kroz RPC (security definer) ili service_role.
grant select on pinka_finance.contributions       to authenticated;
grant select on pinka_finance.contribution_events to authenticated;
grant select on pinka_finance.token_positions     to authenticated;
grant select on pinka_finance.payouts             to authenticated;
grant select, insert, update, delete on pinka_finance.contributions       to service_role;
grant select, insert, update, delete on pinka_finance.contribution_events to service_role;
grant select, insert, update, delete on pinka_finance.token_positions     to service_role;
grant select, insert, update, delete on pinka_finance.payouts             to service_role;
grant select, insert, update, delete on pinka_finance.campaign_stats      to service_role;

-- sequences (contribution_events bigserial)
grant usage, select on all sequences in schema pinka_finance to authenticated, service_role;

-- default privileges za buduce tablice/sekvence/funkcije
alter default privileges in schema pinka_finance grant select on tables to anon, authenticated;
alter default privileges in schema pinka_finance grant insert, update, delete on tables to service_role;
alter default privileges in schema pinka_finance grant usage, select on sequences to authenticated, service_role;
alter default privileges in schema pinka_finance grant execute on functions to authenticated, service_role;

-- =============================================================================
-- RLS policies
-- =============================================================================

-- ===== campaigns =============================================================
drop policy if exists campaigns_select on pinka_finance.campaigns;
create policy campaigns_select on pinka_finance.campaigns
  for select to anon, authenticated
  using (
    deleted_at is null
    and (
      (visibility in ('public','unlisted') and state in ('active','funded','closed'))
      or public.is_account_member(account_id)
    )
  );

drop policy if exists campaigns_insert on pinka_finance.campaigns;
create policy campaigns_insert on pinka_finance.campaigns
  for insert to authenticated
  with check (public.has_role_on_account(account_id, 'admin'));

drop policy if exists campaigns_update on pinka_finance.campaigns;
create policy campaigns_update on pinka_finance.campaigns
  for update to authenticated
  using (deleted_at is null and public.has_role_on_account(account_id, 'admin'))
  with check (public.has_role_on_account(account_id, 'admin'));

drop policy if exists campaigns_delete on pinka_finance.campaigns;
create policy campaigns_delete on pinka_finance.campaigns
  for delete to authenticated
  using (public.has_role_on_account(account_id, 'owner'));
-- Soft-delete (UPDATE deleted_at) prolazi campaigns_update.

-- ===== campaign_tiers ========================================================
drop policy if exists tiers_select on pinka_finance.campaign_tiers;
create policy tiers_select on pinka_finance.campaign_tiers
  for select to anon, authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id
        and c.deleted_at is null
        and (
          (c.visibility in ('public','unlisted') and c.state in ('active','funded','closed'))
          or public.is_account_member(c.account_id)
        )
    )
  );

drop policy if exists tiers_write on pinka_finance.campaign_tiers;
create policy tiers_write on pinka_finance.campaign_tiers
  for all to authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  )
  with check (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ===== contributions (SELECT only; write preko RPC/service_role) =============
drop policy if exists contributions_select on pinka_finance.contributions;
create policy contributions_select on pinka_finance.contributions
  for select to authenticated
  using (
    public.is_account_member(contributor_account_id)
    or exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ===== contribution_events (SELECT only, append-only) ========================
drop policy if exists contrib_events_select on pinka_finance.contribution_events;
create policy contrib_events_select on pinka_finance.contribution_events
  for select to authenticated
  using (
    exists (
      select 1 from pinka_finance.contributions ct
      where ct.id = contribution_id
        and (
          public.is_account_member(ct.contributor_account_id)
          or exists (
            select 1 from pinka_finance.campaigns c
            where c.id = ct.campaign_id and public.has_role_on_account(c.account_id, 'admin')
          )
        )
    )
  );

-- ===== token_positions (SELECT only) =========================================
drop policy if exists positions_select on pinka_finance.token_positions;
create policy positions_select on pinka_finance.token_positions
  for select to authenticated
  using (
    public.is_account_member(holder_account_id)
    or exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ===== payouts (SELECT only; vlasnik kampanje) ===============================
drop policy if exists payouts_select on pinka_finance.payouts;
create policy payouts_select on pinka_finance.payouts
  for select to authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

-- ===== campaign_stats (javno citljiv agregat) ================================
drop policy if exists stats_select on pinka_finance.campaign_stats;
create policy stats_select on pinka_finance.campaign_stats
  for select to anon, authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id
        and c.deleted_at is null
        and (
          (c.visibility in ('public','unlisted') and c.state in ('active','funded','closed'))
          or public.is_account_member(c.account_id)
        )
    )
  );

-- =============================================================================
-- public_contributions — "zid donatora" za javne kampanje
-- View se izvrsava s pravima vlasnika (security_invoker = off, default) pa
-- zaobilazi RLS donjih tablica; WHERE filter pusta samo siguran, javan subset.
-- =============================================================================
create or replace view pinka_finance.public_contributions as
  select
    ct.id,
    ct.campaign_id,
    ct.display_name,
    ct.message,
    ct.amount_cents,
    ct.currency,
    ct.created_at,
    ct.paid_at
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id
  where ct.state = 'paid'
    and ct.anonymous = false
    and c.deleted_at is null
    and c.visibility = 'public'
    and c.state in ('active','funded','closed');

grant select on pinka_finance.public_contributions to anon, authenticated, service_role;

select 'OK 12 pinka_finance_rls' as status;
