-- =============================================================================
-- 11 — Channel ownership claims + Safe Multisig payout (domovina_ai)
-- Reference: domovina.ai/docs/channel-ownership-and-safe-payout-plan.md (D1–D4)
--            domovina.ai/docs/backend-prompts/09-channel-ownership.md
--
-- Feature: vlasnik YouTube kanala dokaže vlasništvo (server-side OAuth
-- channels.list?mine=true) → KYC gate → co-signer per-epizoda Safe Multisig.
--
-- Tablice:
--   channel_claims   (UC… claim; one_primary_per_channel partial unique D2)
--   episode_safes    (per-epizoda Safe metapodaci; javno čitljivo)
--   owner_wallets    (0x… EOA adresa; Safe co-signer kandidat)
--   safe_actions     (audit trail; SELECT samo verified vlasnik epizode)
--   oauth_states     (kratkotrajni PKCE/state store; service_role-only)
-- =============================================================================

-- ----- channel_claims --------------------------------------------------------
create table if not exists domovina_ai.channel_claims (
  id                  uuid primary key default gen_random_uuid(),
  account_id          uuid not null references auth.users(id) on delete cascade,
  youtube_channel_id  text not null check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  channel_title       text,
  google_sub          text not null,
  role                text not null default 'primary'
                        check (role in ('primary','collaborator')),
  status              text not null default 'pending'
                        check (status in ('pending','verified','revoked','disputed')),
  method              text not null default 'youtube_oauth',
  verified_at         timestamptz,
  last_checked_at     timestamptz,
  created_at          timestamptz not null default now(),
  unique (account_id, youtube_channel_id)
);

-- D2: samo JEDAN verified primary po kanalu. Collaboratori neograničeno.
create unique index if not exists one_primary_per_channel
  on domovina_ai.channel_claims (youtube_channel_id)
  where (role = 'primary' and status = 'verified');

create index if not exists ix_channel_claims_account
  on domovina_ai.channel_claims(account_id, created_at desc);

-- ----- episode_safes ---------------------------------------------------------
create table if not exists domovina_ai.episode_safes (
  episode_id          text primary key,
  youtube_channel_id  text not null,
  safe_address        text not null,
  chain_id            integer not null,
  threshold           smallint not null default 2,
  status              text not null default 'active'
                        check (status in ('active','frozen','settled')),
  created_at          timestamptz not null default now()
);

create index if not exists ix_episode_safes_channel
  on domovina_ai.episode_safes(youtube_channel_id);

-- ----- owner_wallets ---------------------------------------------------------
create table if not exists domovina_ai.owner_wallets (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references auth.users(id) on delete cascade,
  address       text not null check (address ~ '^0x[0-9a-fA-F]{40}$'),
  verified_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (account_id, address)
);

-- ----- safe_actions (audit) --------------------------------------------------
create table if not exists domovina_ai.safe_actions (
  id            uuid primary key default gen_random_uuid(),
  episode_id    text not null references domovina_ai.episode_safes(episode_id),
  account_id    uuid references auth.users(id),
  action        text not null,
  safe_tx_hash  text,
  payload       jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists ix_safe_actions_episode
  on domovina_ai.safe_actions(episode_id, created_at desc);

-- ----- oauth_states (PKCE/state za youtube-claim; service_role-only) ----------
create table if not exists domovina_ai.oauth_states (
  state              text primary key,
  account_id         uuid not null references auth.users(id) on delete cascade,
  youtube_channel_id text not null,
  code_verifier      text not null,
  purpose            text not null default 'youtube_claim',
  expires_at         timestamptz not null,
  created_at         timestamptz not null default now()
);

create index if not exists ix_oauth_states_expires
  on domovina_ai.oauth_states(expires_at);

-- ============================================================================
-- RLS
-- ============================================================================
alter table domovina_ai.channel_claims enable row level security;
alter table domovina_ai.episode_safes  enable row level security;
alter table domovina_ai.owner_wallets  enable row level security;
alter table domovina_ai.safe_actions   enable row level security;
alter table domovina_ai.oauth_states   enable row level security;

-- channel_claims: user vidi svoje; insert samo PENDING za sebe; status mijenja
-- isključivo service_role (nema update/delete policy za usera).
drop policy if exists claims_select_own on domovina_ai.channel_claims;
create policy claims_select_own on domovina_ai.channel_claims
  for select to authenticated using (account_id = (select auth.uid()));

drop policy if exists claims_insert_own on domovina_ai.channel_claims;
create policy claims_insert_own on domovina_ai.channel_claims
  for insert to authenticated
  with check (account_id = (select auth.uid()) and status = 'pending');

-- episode_safes: metapodaci javno čitljivi; pisanje samo service_role.
drop policy if exists safes_select_all on domovina_ai.episode_safes;
create policy safes_select_all on domovina_ai.episode_safes
  for select using (true);

-- owner_wallets: full CRUD samo vlasnik.
drop policy if exists wallets_all_own on domovina_ai.owner_wallets;
create policy wallets_all_own on domovina_ai.owner_wallets
  for all to authenticated
  using (account_id = (select auth.uid()))
  with check (account_id = (select auth.uid()));

-- safe_actions: user vidi akcije nad epizodama čiji je verified vlasnik.
drop policy if exists actions_select_owner on domovina_ai.safe_actions;
create policy actions_select_owner on domovina_ai.safe_actions
  for select to authenticated using (
    exists (
      select 1
      from domovina_ai.episode_safes es
      join domovina_ai.channel_claims cc
        on cc.youtube_channel_id = es.youtube_channel_id
      where es.episode_id = safe_actions.episode_id
        and cc.account_id = (select auth.uid())
        and cc.status = 'verified'
    )
  );

-- oauth_states: nema user policy — isključivo service_role (edge fn).

-- ============================================================================
-- Grants (RLS ostaje gatekeeper)
-- ============================================================================
grant usage on schema domovina_ai to anon, authenticated, service_role;

grant select, insert on domovina_ai.channel_claims to authenticated;
grant all on domovina_ai.channel_claims to service_role;

grant select on domovina_ai.episode_safes to anon, authenticated;
grant all on domovina_ai.episode_safes to service_role;

grant select, insert, update, delete on domovina_ai.owner_wallets to authenticated;
grant all on domovina_ai.owner_wallets to service_role;

grant select on domovina_ai.safe_actions to authenticated;
grant all on domovina_ai.safe_actions to service_role;

grant all on domovina_ai.oauth_states to service_role;

select 'OK 11 channel_ownership' as status;
