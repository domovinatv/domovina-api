-- =============================================================================
-- 01 — Core identity (public.*)
-- Reference: domovina.ai/docs/auth-and-database-plan-v3.md
--            domovina.ai/docs/backend-prompts/01-core-identity.md
--
-- Tablice: profiles, accounts, accounts_memberships, activity_events
-- Extensions: citext, pg_trgm
-- Enums: member_role, visibility_level
-- RLS samo enable; policies su u 04-rls-policies.sql.
-- =============================================================================

-- ----- extensions ------------------------------------------------------------
create extension if not exists citext;
create extension if not exists pg_trgm;

-- ----- enums (idempotent via do blocks) --------------------------------------
do $$ begin
  create type public.member_role as enum ('owner','admin','member');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.visibility_level as enum ('private','public');
exception when duplicate_object then null;
end $$;

-- ----- profiles --------------------------------------------------------------
-- v3: NEMA email / is_anonymous mirror (PII princip — koristi auth.email() /
-- (auth.jwt() ->> 'is_anonymous')).
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  locale text not null default 'hr',
  timezone text not null default 'Europe/Zagreb',
  active_account_id uuid,  -- FK postavlja se ispod, nakon kreiranja accounts
  notification_prefs jsonb not null default '{}'::jsonb,
  onboarding_completed_at timestamptz,
  last_seen_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ----- accounts (unified user+org) -------------------------------------------
create table if not exists public.accounts (
  id uuid primary key default gen_random_uuid(),
  primary_owner_user_id uuid not null references auth.users(id) on delete cascade,
  is_personal_account boolean not null default false,
  slug citext not null unique,
  name text not null,
  avatar_url text,
  bio text,
  website_url text,
  -- GENERATED STORED: name + slug + bio za fuzzy typeahead
  search_text text generated always as (
    lower(name || ' ' || slug::text || ' ' || coalesce(bio, ''))
  ) stored,
  visibility public.visibility_level not null default 'private',
  metadata jsonb not null default '{}'::jsonb,
  deleted_at timestamptz,  -- ★ soft-delete (Princip 3 — sole table)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- GitHub-style slug; 1..40 chars, lowercase alphanum + dash, ne na rubovima
  constraint slug_format check (
    slug ~ '^[a-z0-9][a-z0-9-]{0,38}[a-z0-9]$' or length(slug) = 1
  )
);

-- jedan personal account po user-u (partial unique)
create unique index if not exists ix_one_personal_per_user
  on public.accounts(primary_owner_user_id)
  where is_personal_account = true;

-- profiles.active_account_id → accounts.id (postavi tek sad)
do $$ begin
  alter table public.profiles
    add constraint fk_profiles_active_account
    foreign key (active_account_id)
    references public.accounts(id) on delete set null;
exception when duplicate_object then null;
end $$;

-- ----- accounts_memberships (N:M user × org × role) -------------------------
-- check_membership_is_org trigger (u 03) odbija dodavanje membership-a na
-- personal account.
create table if not exists public.accounts_memberships (
  account_id uuid not null references public.accounts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  account_role public.member_role not null default 'member',
  display_name_override text,
  invited_by uuid references public.profiles(id) on delete set null,
  joined_at timestamptz not null default now(),
  last_active_at timestamptz,
  primary key (account_id, user_id)
);

-- ----- activity_events (append-only event stream) ---------------------------
-- v3 novo. log_event() helper u 03 piše ovamo; triggeri u 03 emit-aju eventove
-- za membership changes i episode completion od dana 1.
create table if not exists public.activity_events (
  id bigserial primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  target_account_id uuid references public.accounts(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ----- indexes ---------------------------------------------------------------
create index if not exists ix_accounts_primary_owner
  on public.accounts(primary_owner_user_id);
create index if not exists ix_accounts_slug
  on public.accounts(slug);
-- ★ GIN trgm — sub-ms fuzzy match na name/slug/bio kombinaciji
create index if not exists ix_accounts_search
  on public.accounts using gin (search_text gin_trgm_ops);
-- partial za "alive" — RLS policies dodaju AND deleted_at IS NULL
create index if not exists ix_accounts_alive
  on public.accounts(id) where deleted_at is null;

create index if not exists ix_memberships_user
  on public.accounts_memberships(user_id);
create index if not exists ix_memberships_account
  on public.accounts_memberships(account_id);

create index if not exists ix_activity_account_recent
  on public.activity_events(target_account_id, created_at desc);
create index if not exists ix_activity_actor
  on public.activity_events(actor_user_id, created_at desc);
create index if not exists ix_activity_type
  on public.activity_events(event_type, created_at desc);

-- ----- updated_at autotouch --------------------------------------------------
create or replace function public.touch_updated_at() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated on public.profiles;
create trigger trg_profiles_updated
  before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_accounts_updated on public.accounts;
create trigger trg_accounts_updated
  before update on public.accounts
  for each row execute function public.touch_updated_at();

-- ----- enable RLS (policies u 04) -------------------------------------------
alter table public.profiles              enable row level security;
alter table public.accounts              enable row level security;
alter table public.accounts_memberships  enable row level security;
alter table public.activity_events       enable row level security;

select 'OK 01 core_identity' as status;
