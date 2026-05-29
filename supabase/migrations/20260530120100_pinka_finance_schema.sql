-- =============================================================================
-- 11 — pinka.finance domena (schema pinka_finance.*)
-- Reference: domovina-api/docs/pinka-finance-platform-plan.md
--
-- Generička platforma za grupno prikupljanje novca: donacije, crowdfunding,
-- tokenizacija (soft / attestation), ulaznice, nekretnine — sve isti model.
--
-- Princip (kao public.*):
--   - PII iskljucivo u auth.users; ovdje samo FK + opt-in javni stringovi
--     (display_name, message). Nikakav email/telefon/ime se ne sprema.
--   - slug immutable (citext, BEFORE UPDATE guard).
--   - soft-delete SAMO na master tablici (campaigns.deleted_at); djeca CASCADE.
--   - contribution_events append-only (kao public.activity_events).
--   - amount_cents integer; decimale samo na rubu rail-a.
--
-- Custody: per-campaign Gnosis Safe — campaigns.destination_address je odredisni
-- Safe; rail (pay.domovina.ai) forwarda EURe direktno tamo; pinka NE custodira.
--
-- RLS: samo enable ovdje; policies + grants u 12; RPC-evi + trigeri u 13.
-- =============================================================================

create schema if not exists pinka_finance;

-- citext / pgcrypto vec postoje iz core migracija; idempotentno za svaki slucaj.
create extension if not exists citext;

-- ----- enums (idempotent via do blocks) --------------------------------------
do $$ begin
  create type pinka_finance.campaign_type as enum
    ('donation','crowdfund','tokenization','tickets','realestate');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.campaign_state as enum
    ('draft','active','funded','closed','cancelled');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.campaign_visibility as enum
    ('private','unlisted','public');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.tier_kind as enum
    ('reward','ticket','token_tranche','none');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.contribution_state as enum
    ('pending','paid','failed','refunded','expired');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.position_status as enum
    ('pending','minted','transferred','burned');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type pinka_finance.payout_state as enum
    ('requested','approved','submitted','confirmed','failed');
exception when duplicate_object then null;
end $$;

-- ----- campaigns (master) ----------------------------------------------------
create table if not exists pinka_finance.campaigns (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,  -- korisnik
  slug citext not null unique,                          -- ★ immutable (guard ispod)
  type pinka_finance.campaign_type not null default 'donation',
  title text not null,
  description text,
  -- polimorfni subjekt onoga sto se financira (episode / nekretnina / event ...)
  subject_type text not null default 'generic',         -- 'podcast_episode' za MVP
  subject_ref text,                                      -- npr. youtubeId
  goal_cents bigint,                                     -- null = open-ended (donacija)
  min_contribution_cents integer not null default 100,
  currency text not null default 'eur',
  -- custody: per-campaign Gnosis Safe (counterfactual dok ne padne prvi forward)
  destination_address text not null,                    -- 0x… Safe; rail target
  chain text not null default 'gnosis',
  safe_deployed_at timestamptz,                          -- set kad Safe dobije code
  state pinka_finance.campaign_state not null default 'draft',
  visibility pinka_finance.campaign_visibility not null default 'private',
  cover_image_url text,
  starts_at timestamptz,
  ends_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  deleted_at timestamptz,                                -- ★ soft-delete (jedina)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint slug_format check (
    slug ~ '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$' or length(slug) = 1
  ),
  constraint goal_positive check (goal_cents is null or goal_cents > 0),
  constraint min_contribution_positive check (min_contribution_cents > 0)
);

create index if not exists ix_campaigns_account on pinka_finance.campaigns(account_id);
create index if not exists ix_campaigns_subject on pinka_finance.campaigns(subject_type, subject_ref);
create index if not exists ix_campaigns_state on pinka_finance.campaigns(state);
create index if not exists ix_campaigns_alive on pinka_finance.campaigns(id) where deleted_at is null;
-- javni feed: aktivne/finalne, javne, zive kampanje
create index if not exists ix_campaigns_public_feed
  on pinka_finance.campaigns(visibility, state, created_at desc)
  where deleted_at is null;

-- ----- campaign_tiers (reward / ticket / token tranche) ----------------------
create table if not exists pinka_finance.campaign_tiers (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  title text not null,
  description text,
  kind pinka_finance.tier_kind not null default 'reward',
  price_cents integer not null default 0,
  inventory_total integer,                               -- null = unlimited
  inventory_claimed integer not null default 0,
  unit text,                                             -- 'share' | 'seat' | null
  sort integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_nonneg check (price_cents >= 0),
  constraint inventory_sane check (inventory_total is null or inventory_total >= 0),
  constraint claimed_nonneg check (inventory_claimed >= 0)
);
create index if not exists ix_tiers_campaign on pinka_finance.campaign_tiers(campaign_id, sort);

-- ----- contributions (novac unutra) ------------------------------------------
create table if not exists pinka_finance.contributions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  tier_id uuid references pinka_finance.campaign_tiers(id) on delete set null,
  contributor_account_id uuid references public.accounts(id) on delete set null,  -- null = gost
  amount_cents bigint not null,                          -- obecano
  amount_received_cents bigint,                          -- stvarno primljeno (rail)
  currency text not null default 'eur',
  quantity integer not null default 1,                   -- ulaznice / units
  state pinka_finance.contribution_state not null default 'pending',
  -- veza na rail (Cloudflare D1 payment_intents.sid)
  payment_intent_sid text,
  monerium_order_id text,
  forward_tx_hash text,                                  -- Gnosis tx
  destination_address text not null,                     -- snapshot campaign.destination
  anonymous boolean not null default false,
  display_name text,                                     -- opt-in javno, NE PII
  message text,                                          -- opt-in javna poruka
  created_at timestamptz not null default now(),
  paid_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint amount_positive check (amount_cents > 0),
  constraint quantity_positive check (quantity > 0)
);
-- jedan intent = jedna contribution
create unique index if not exists ux_contributions_sid
  on pinka_finance.contributions(payment_intent_sid)
  where payment_intent_sid is not null;
create index if not exists ix_contributions_campaign on pinka_finance.contributions(campaign_id, state);
create index if not exists ix_contributions_contributor on pinka_finance.contributions(contributor_account_id);
create index if not exists ix_contributions_state on pinka_finance.contributions(state);

-- ----- contribution_events (append-only audit) -------------------------------
create table if not exists pinka_finance.contribution_events (
  id bigserial primary key,
  contribution_id uuid not null references pinka_finance.contributions(id) on delete cascade,
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  event_type text not null,                              -- contribution.created|paid|…
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ix_contrib_events_contribution
  on pinka_finance.contribution_events(contribution_id, created_at desc);
create index if not exists ix_contrib_events_campaign
  on pinka_finance.contribution_events(campaign_id, created_at desc);

-- ----- token_positions (soft tokenizacija) -----------------------------------
-- MVP: units + opcionalni passkey-potpisani SBT (attestation_uid). NIJE prenosivi
-- vrijednosni papir; onchain_token_address ostaje null dok (ako ikad) ne dodje
-- pravi minting iza pravne strukture (Phase 4).
create table if not exists pinka_finance.token_positions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  contribution_id uuid not null references pinka_finance.contributions(id) on delete cascade,
  holder_account_id uuid references public.accounts(id) on delete set null,
  units numeric not null default 0,
  onchain_token_address text,                            -- null dok nije mintano
  onchain_token_id text,
  attestation_uid text,                                  -- Phase-5 SBT
  status pinka_finance.position_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (contribution_id)                               -- jedna pozicija po doprinosu
);
create index if not exists ix_positions_campaign on pinka_finance.token_positions(campaign_id);
create index if not exists ix_positions_holder on pinka_finance.token_positions(holder_account_id);

-- ----- payouts (novac van) ---------------------------------------------------
create table if not exists pinka_finance.payouts (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  amount_cents bigint not null,
  destination text not null,                             -- IBAN (Monerium redeem) ili 0x
  state pinka_finance.payout_state not null default 'requested',
  tx_hash text,
  monerium_redeem_order_id text,
  requested_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payout_amount_positive check (amount_cents > 0)
);
create index if not exists ix_payouts_campaign on pinka_finance.payouts(campaign_id, created_at desc);

-- ----- campaign_stats (denorm cache; trigger u 13) ---------------------------
create table if not exists pinka_finance.campaign_stats (
  campaign_id uuid primary key references pinka_finance.campaigns(id) on delete cascade,
  total_raised_cents bigint not null default 0,
  contribution_count integer not null default 0,
  contributor_count integer not null default 0,
  last_contribution_at timestamptz,
  updated_at timestamptz not null default now()
);

-- ----- updated_at autotouch (reuse public.touch_updated_at) -------------------
drop trigger if exists trg_campaigns_updated on pinka_finance.campaigns;
create trigger trg_campaigns_updated
  before update on pinka_finance.campaigns
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_tiers_updated on pinka_finance.campaign_tiers;
create trigger trg_tiers_updated
  before update on pinka_finance.campaign_tiers
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_contributions_updated on pinka_finance.contributions;
create trigger trg_contributions_updated
  before update on pinka_finance.contributions
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_positions_updated on pinka_finance.token_positions;
create trigger trg_positions_updated
  before update on pinka_finance.token_positions
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_payouts_updated on pinka_finance.payouts;
create trigger trg_payouts_updated
  before update on pinka_finance.payouts
  for each row execute function public.touch_updated_at();

-- ----- slug immutability guard -----------------------------------------------
create or replace function pinka_finance.guard_immutable_slug() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.slug is distinct from old.slug then
    raise exception 'slug_immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_campaigns_slug_guard on pinka_finance.campaigns;
create trigger trg_campaigns_slug_guard
  before update on pinka_finance.campaigns
  for each row execute function pinka_finance.guard_immutable_slug();

-- ----- enable RLS (policies u 12) -------------------------------------------
alter table pinka_finance.campaigns           enable row level security;
alter table pinka_finance.campaign_tiers      enable row level security;
alter table pinka_finance.contributions       enable row level security;
alter table pinka_finance.contribution_events enable row level security;
alter table pinka_finance.token_positions     enable row level security;
alter table pinka_finance.payouts             enable row level security;
alter table pinka_finance.campaign_stats      enable row level security;

select 'OK 11 pinka_finance_schema' as status;
