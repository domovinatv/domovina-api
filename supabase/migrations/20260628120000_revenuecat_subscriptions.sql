-- =============================================================================
-- RevenueCat entitlement mirror — domovina_ai.subscriptions
--
-- One row per user, written ONLY by the Cloudflare Worker webhook
-- (domovina.ai: POST /api/revenuecat/webhook) via the service role. The Flutter
-- app reads its own row on every platform (web/iOS/Android/macOS/TV) and gates
-- the `domovina_plus` entitlement on it.
--
-- See domovina.ai docs/payments/architecture.md. Idempotent.
-- =============================================================================

create table if not exists domovina_ai.subscriptions (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  rc_app_user_id       text not null,
  status               text not null default 'free',   -- 'active' | 'expired' | 'free'
  entitlement          text,                            -- 'domovina_plus' when active, else null
  product_id           text,                            -- e.g. 'domovina_plus_annual'
  store                text,                            -- 'app_store' | 'play_store' | 'rc_billing'
  period_type          text,                            -- 'normal' | 'trial' | 'intro'
  current_period_end   timestamptz,                     -- null for lifetime
  rc_event_type        text,                            -- last event applied (audit)
  environment          text,                            -- 'SANDBOX' | 'PRODUCTION'
  updated_at           timestamptz not null default now()
);

create index if not exists ix_subscriptions_status
  on domovina_ai.subscriptions(status);

-- ----- RLS: read-own only; no client write (service role bypasses RLS) -------
alter table domovina_ai.subscriptions enable row level security;

drop policy if exists subscriptions_select_own on domovina_ai.subscriptions;
create policy subscriptions_select_own
  on domovina_ai.subscriptions for select
  using (auth.uid() = user_id);

-- No insert/update/delete policy → only the service role (webhook) can write.

-- ----- explicit grants (domovina_ai default privileges already cover this,
-- but be explicit and self-documenting; RLS still gates row visibility) ------
grant select on domovina_ai.subscriptions to anon, authenticated;
grant select, insert, update, delete on domovina_ai.subscriptions to service_role;

-- ----- realtime: let the app's EntitlementService get instant row updates ----
-- Guarded: no-op if the publication is missing or the table is already in it,
-- so the surrounding migration transaction never aborts.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table domovina_ai.subscriptions;
    exception
      when duplicate_object then null;
    end;
  end if;
end $$;

select 'OK revenuecat_subscriptions' as status;
