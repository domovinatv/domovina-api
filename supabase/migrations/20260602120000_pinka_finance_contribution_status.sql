-- =============================================================================
-- pinka_finance.contribution_status(uuid) — guest-pollable payment status
-- =============================================================================
-- Problem: the contribute checkout (often a GUEST / anonymous Supabase session)
-- has no account, so contributor_account_id is NULL and the contributions_select
-- RLS policy (is_account_member) blocks the client from reading its OWN row.
-- The panel's poll therefore never observed state='paid' → no live "paid" flip
-- (only a manual browser refresh showed updated public stats).
--
-- Fix: a SECURITY DEFINER function keyed by the contribution UUID. The id is an
-- unguessable random UUID the client already received from create_contribution,
-- so knowing it acts as a bearer capability. The function returns ONLY the
-- payment state + paid_at (no PII, amount, message, sid), so it is safe to
-- expose by-id to anon/authenticated. Used for the post-payment poll.

create or replace function pinka_finance.contribution_status(p_contribution_id uuid)
returns table (state text, paid_at timestamptz)
language sql
stable
security definer
set search_path = pinka_finance, public
as $$
  select c.state::text, c.paid_at
  from pinka_finance.contributions c
  where c.id = p_contribution_id;
$$;

revoke all on function pinka_finance.contribution_status(uuid) from public;
grant execute on function pinka_finance.contribution_status(uuid) to anon, authenticated, service_role;
