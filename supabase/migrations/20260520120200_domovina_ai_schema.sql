-- =============================================================================
-- 02 — domovina_ai schema (Netflix-style watch state + MVP extras)
-- Reference: domovina.ai/docs/auth-and-database-plan-v3.md
--            domovina.ai/docs/backend-prompts/02-domovina-ai-schema.md
--
-- Tablice:
--   watch_progress     (s episode_title/thumbnail_url denorm cache)
--   watch_sessions     (append-only audit log za analytics)
--   favorites          (MVP — owner = personal account ili org)
--   handoff_tokens     (M4 cross-device sign-in, 6-digit code)
--   onboarding_events  (M1-M4 telemetrija)
-- View:
--   v_continue_watching (denorm "Continue watching" carousel)
-- Enums: device_type, playlist_visibility (seed za Faze 6+)
-- =============================================================================

create schema if not exists domovina_ai;

-- ----- enums -----------------------------------------------------------------
do $$ begin
  create type domovina_ai.device_type as enum ('web','ios','android','macos');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type domovina_ai.playlist_visibility as enum ('private','members','public');
exception when duplicate_object then null;
end $$;

-- ----- watch_progress ("GDJE si stao") --------------------------------------
-- v3 add: episode_title + episode_thumbnail_url denorm cache iz CDN-a.
create table if not exists domovina_ai.watch_progress (
  user_id uuid not null references public.profiles(id) on delete cascade,
  episode_id text not null,        -- YouTube videoId
  channel_id text not null,
  position_seconds int not null default 0 check (position_seconds >= 0),
  duration_seconds int not null check (duration_seconds > 0),
  percent_complete numeric generated always as (
    least(100, (position_seconds::numeric / nullif(duration_seconds, 0)) * 100)
  ) stored,
  completed boolean generated always as (
    position_seconds::numeric / nullif(duration_seconds, 0) >= 0.9
  ) stored,
  episode_title text,              -- ★ denorm cache za "Continue watching"
  episode_thumbnail_url text,      -- ★ denorm cache (CDN URL)
  playback_rate numeric not null default 1.0,
  audio_track text,
  subtitle_track text,
  watch_count int not null default 1,
  last_watched_at timestamptz not null default now(),
  last_device domovina_ai.device_type,
  created_at timestamptz not null default now(),
  primary key (user_id, episode_id)
);

-- ----- watch_sessions (append-only audit log) -------------------------------
create table if not exists domovina_ai.watch_sessions (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  episode_id text not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  start_position_seconds int,
  end_position_seconds int,
  pause_count int not null default 0,
  seek_count int not null default 0,
  completed_normally boolean,
  device domovina_ai.device_type,
  user_agent text
);

-- ----- favorites (owner = personal account ili org) -------------------------
create table if not exists domovina_ai.favorites (
  owner_id uuid not null references public.accounts(id) on delete cascade,
  episode_id text not null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  notes text,
  position int,
  created_at timestamptz not null default now(),
  primary key (owner_id, episode_id)
);

-- ----- handoff_tokens (M4 cross-device 6-digit code) ------------------------
create table if not exists domovina_ai.handoff_tokens (
  code text primary key check (code ~ '^[0-9]{6}$'),
  user_id uuid not null references public.profiles(id) on delete cascade,
  source_device domovina_ai.device_type,
  expires_at timestamptz not null default (now() + interval '5 minutes'),
  consumed_at timestamptz,
  consumed_by_device domovina_ai.device_type,
  created_at timestamptz not null default now()
);

-- ----- onboarding_events (telemetry za M1-M4) -------------------------------
-- event ∈ {moment_shown, moment_dismissed, auth_started, auth_completed, auth_failed}
-- moment_id ∈ {m1, m2, m3, m4, null}
-- provider ∈ {google, apple, email, passkey, null}
create table if not exists domovina_ai.onboarding_events (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  event text not null,
  moment_id text,
  provider text,
  properties jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- ----- indexes ---------------------------------------------------------------
create index if not exists ix_wp_continue
  on domovina_ai.watch_progress(user_id, last_watched_at desc);
create index if not exists ix_wp_completed
  on domovina_ai.watch_progress(user_id, completed, last_watched_at desc);

create index if not exists ix_ws_user
  on domovina_ai.watch_sessions(user_id, started_at desc);
create index if not exists ix_ws_episode
  on domovina_ai.watch_sessions(episode_id, started_at desc);

create index if not exists ix_fav_owner
  on domovina_ai.favorites(owner_id, created_at desc);

create index if not exists ix_ho_user
  on domovina_ai.handoff_tokens(user_id, created_at desc);
create index if not exists ix_ho_expires
  on domovina_ai.handoff_tokens(expires_at) where consumed_at is null;

create index if not exists ix_oe_user
  on domovina_ai.onboarding_events(user_id, created_at desc);
create index if not exists ix_oe_event
  on domovina_ai.onboarding_events(event, created_at desc);

-- ----- v_continue_watching view (Postgres 15+ nasljeđuje RLS) ---------------
create or replace view domovina_ai.v_continue_watching as
select user_id, episode_id, channel_id, position_seconds, duration_seconds,
       percent_complete, episode_title, episode_thumbnail_url,
       last_watched_at, last_device
from domovina_ai.watch_progress
where not completed
  and position_seconds > 30
order by last_watched_at desc;

-- ----- enable RLS (policies u 04) -------------------------------------------
alter table domovina_ai.watch_progress     enable row level security;
alter table domovina_ai.watch_sessions     enable row level security;
alter table domovina_ai.favorites          enable row level security;
alter table domovina_ai.handoff_tokens     enable row level security;
alter table domovina_ai.onboarding_events  enable row level security;

select 'OK 02 domovina_ai_schema' as status;
