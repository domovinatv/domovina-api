-- =============================================================================
-- 04 — RLS policies
-- Reference: domovina.ai/docs/auth-and-database-plan-v3.md §RLS best practices
--            domovina.ai/docs/backend-prompts/04-rls-policies.md
--
-- Patterns:
--   - (select auth.uid()) — InitPlan caching (10-100× brže od goleg auth.uid())
--   - to authenticated   — eksplicitno ograniči (anon users ipak imaju non-null uid)
--   - deleted_at IS NULL — sve accounts queries (Princip 3)
--   - public.is_account_member(id), public.has_role_on_account(id, role) helperi (iz 03)
-- =============================================================================

-- ===== public.profiles ======================================================
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()));

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- ===== public.accounts ======================================================
drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts
  for select to authenticated
  using (
    deleted_at is null
    and (
      primary_owner_user_id = (select auth.uid())
      or public.is_account_member(id)
      or visibility = 'public'
    )
  );

drop policy if exists accounts_insert on public.accounts;
create policy accounts_insert on public.accounts
  for insert to authenticated
  with check (primary_owner_user_id = (select auth.uid()));

drop policy if exists accounts_update on public.accounts;
create policy accounts_update on public.accounts
  for update to authenticated
  using (
    deleted_at is null
    and (
      primary_owner_user_id = (select auth.uid())
      or public.has_role_on_account(id, 'admin')
    )
  )
  with check (
    primary_owner_user_id = (select auth.uid())
    or public.has_role_on_account(id, 'admin')
  );

drop policy if exists accounts_delete on public.accounts;
create policy accounts_delete on public.accounts
  for delete to authenticated
  using (primary_owner_user_id = (select auth.uid()));
-- Soft-delete (UPDATE deleted_at) prolazi accounts_update.

-- ===== public.accounts_memberships ==========================================
drop policy if exists memberships_select on public.accounts_memberships;
create policy memberships_select on public.accounts_memberships
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or public.is_account_member(account_id)
  );

drop policy if exists memberships_write on public.accounts_memberships;
create policy memberships_write on public.accounts_memberships
  for all to authenticated
  using (public.has_role_on_account(account_id, 'admin'))
  with check (public.has_role_on_account(account_id, 'admin'));

-- ===== public.activity_events ==============================================
-- SELECT samo (append-only); INSERT ide kroz log_event() security definer.
drop policy if exists activity_select on public.activity_events;
create policy activity_select on public.activity_events
  for select to authenticated
  using (
    actor_user_id = (select auth.uid())
    or public.is_account_member(target_account_id)
  );

-- ===== domovina_ai.watch_progress ===========================================
drop policy if exists wp_select on domovina_ai.watch_progress;
create policy wp_select on domovina_ai.watch_progress
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists wp_write on domovina_ai.watch_progress;
create policy wp_write on domovina_ai.watch_progress
  for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ===== domovina_ai.watch_sessions ===========================================
drop policy if exists ws_select on domovina_ai.watch_sessions;
create policy ws_select on domovina_ai.watch_sessions
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists ws_insert on domovina_ai.watch_sessions;
create policy ws_insert on domovina_ai.watch_sessions
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists ws_update on domovina_ai.watch_sessions;
create policy ws_update on domovina_ai.watch_sessions
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- ===== domovina_ai.favorites (owner = personal account ili org) =============
drop policy if exists fav_select on domovina_ai.favorites;
create policy fav_select on domovina_ai.favorites
  for select to authenticated
  using (public.is_account_member(owner_id));

drop policy if exists fav_insert on domovina_ai.favorites;
create policy fav_insert on domovina_ai.favorites
  for insert to authenticated
  with check (
    public.is_account_member(owner_id)
    and created_by = (select auth.uid())
  );

drop policy if exists fav_update on domovina_ai.favorites;
create policy fav_update on domovina_ai.favorites
  for update to authenticated
  using (
    created_by = (select auth.uid())
    or public.has_role_on_account(owner_id, 'admin')
  )
  with check (
    created_by = (select auth.uid())
    or public.has_role_on_account(owner_id, 'admin')
  );

drop policy if exists fav_delete on domovina_ai.favorites;
create policy fav_delete on domovina_ai.favorites
  for delete to authenticated
  using (
    created_by = (select auth.uid())
    or public.has_role_on_account(owner_id, 'admin')
  );

-- ===== domovina_ai.handoff_tokens ==========================================
drop policy if exists ho_select on domovina_ai.handoff_tokens;
create policy ho_select on domovina_ai.handoff_tokens
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists ho_insert on domovina_ai.handoff_tokens;
create policy ho_insert on domovina_ai.handoff_tokens
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists ho_delete on domovina_ai.handoff_tokens;
create policy ho_delete on domovina_ai.handoff_tokens
  for delete to authenticated
  using (user_id = (select auth.uid()));
-- consume_handoff_token RPC (06) je SECURITY DEFINER pa zaobilazi RLS.

-- ===== domovina_ai.onboarding_events (append-only) ==========================
drop policy if exists oe_select on domovina_ai.onboarding_events;
create policy oe_select on domovina_ai.onboarding_events
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists oe_insert on domovina_ai.onboarding_events;
create policy oe_insert on domovina_ai.onboarding_events
  for insert to authenticated
  with check (user_id = (select auth.uid()));

select 'OK 04 rls_policies' as status;
