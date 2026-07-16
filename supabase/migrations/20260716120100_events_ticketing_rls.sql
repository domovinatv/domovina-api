-- =============================================================================
-- Događaji (E2) — grants + RLS policies
--
-- Slijedi pinka obrasce (20260530120200):
--   events  — javno čitljivi kad je matična kampanja javno čitljiva (public|
--             unlisted + active/funded/closed) ili je caller član org accounta;
--             pisanje samo vlasnik (has_role_on_account admin) preko PostgREST-a
--             (isti model kao campaign_tiers).
--   tickets — PII + pravo ulaska: čitaju SAMO kupac (kontributor narudžbe) i
--             org admin; NIKAD anon; pisanje NIKAD s klijenta — isključivo
--             security-definer RPC-evi (confirm_ticket_order → izdavanje,
--             redeem u E3) ili service_role.
--
-- Napomena: alter default privileges iz 20260530120200 automatski daje select
-- na nove tablice anon+authenticated — za tickets to EKSPLICITNO revokamo.
-- =============================================================================

-- ----- events ----------------------------------------------------------------
grant select on pinka_finance.events to anon, authenticated, service_role;
grant insert, update, delete on pinka_finance.events to authenticated, service_role;

drop policy if exists events_select on pinka_finance.events;
create policy events_select on pinka_finance.events
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

drop policy if exists events_write on pinka_finance.events;
create policy events_write on pinka_finance.events
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

-- ----- tickets (SELECT only; write isključivo RPC/service_role) ---------------
revoke all on pinka_finance.tickets from public, anon;
revoke insert, update, delete on pinka_finance.tickets from authenticated;
grant select on pinka_finance.tickets to authenticated;
grant select, insert, update, delete on pinka_finance.tickets to service_role;

drop policy if exists tickets_select on pinka_finance.tickets;
create policy tickets_select on pinka_finance.tickets
  for select to authenticated
  using (
    exists (
      select 1 from pinka_finance.contributions ct
      where ct.id = contribution_id
        and public.is_account_member(ct.contributor_account_id)
    )
    or exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and public.has_role_on_account(c.account_id, 'admin')
    )
  );

select 'OK events_ticketing_rls' as status;
