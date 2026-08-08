-- =============================================================================
-- Izborni dan — glasanje o sljedećem kanalu: schema
-- Reference: domovina.ai/docs/plans/2026-08-08-glasanje-o-kanalima.md §5
--            (+ §4.1 rupa s brisanjem računa, §7 rangiranje/kvorum)
--
-- Verificiran hrvatski građanin (Certilia) dobiva JEDAN glas po kalendarskom
-- danu (Europe/Zagreb) koji troši na 👍/👎 jednog kandidata iz podcast registra.
-- Glasanje teče u kolima od 14 dana; pobjednik kola se onboarda u pipeline.
--
-- ── Zašto postoji tablica `voters` (NE izbacivati „radi jednostavnosti") ─────
-- `public.identity_verifications.oib_hash` je unique → jedan OIB = jedan račun.
-- ALI `identity_verifications.user_id` je `on delete cascade`, pa brisanje
-- računa oslobađa `oib_hash`:
--     glasaj → obriši račun (cascade briše KYC red) → registriraj se ponovno
--            → verificiraj isti OIB → glasaj opet ISTI DAN
-- Zato se glas veže na TRAJNI pseudonim `domovina_ai.voters.id`, koji nosi
-- `oib_hash` i ima `user_id ... on delete SET NULL`. Nusprodukt: korisnik koji
-- obriše i ponovno napravi račun vraća svoj niz.
--
-- GDPR: `voters` ne sadrži ime, e-mail ni OIB u čitljivom obliku — samo izvedeni
-- HMAC iz `identity_verifications`. Osnova čuvanja nakon brisanja računa je
-- integritet glasanja (čl. 6(1)(f)); dokumentirati u /privacy. Redovi bez
-- aktivnosti 24 mjeseca brišu se rutinski (ručna obveza operatera do faze 5).
--
-- Ovo NIJE tajno glasovanje (§4.3): `voter_id → oib_hash` postoji u bazi.
-- Pojedinačni glasovi se NIKAD ne objavljuju — samo agregati (`vote_tallies`).
-- =============================================================================

-- ----- kandidati (snapshot registra, puni ga sync_voting_candidates.mjs) ------
create table if not exists domovina_ai.vote_candidates (
  slug                 text primary key,          -- registry slug, DOSLOVNO
  display_name         text not null,
  youtube_url          text not null,
  youtube_channel_id   text,
  avatar_url           text,                      -- CDN (cdn.domovina.ai/registry/avatars/<slug>.jpg)
  tags                 text[] not null default '{}',
  voditelji            text[] not null default '{}',
  subscribers          int,
  episodes_estimate    int,
  quality_score        int,                       -- 0–100, registry rubrika
  tier                 int,
  notes                text,
  source_type          text,                      -- channel | playlist | audio-primary
                       -- (registry youtube.type doslovno; prolaze i umbrella /
                       --  disputed / audio-only — Dart ih mapira u unknown)
  status               text not null default 'candidate',
                       -- candidate | winner | onboarding | onboarded | withdrawn
  onboarded_channel_id text,                      -- id u channels index.json kad završi
  registry_synced_at   timestamptz not null default now(),
  created_at           timestamptz not null default now(),
  constraint vote_candidates_slug_format
    check (slug ~ '^[a-z0-9][a-z0-9-]{0,79}$'),
  constraint vote_candidates_status_allowed
    check (status in ('candidate','winner','onboarding','onboarded','withdrawn')),
  constraint vote_candidates_display_name_len
    check (char_length(display_name) between 1 and 200),
  constraint vote_candidates_youtube_url_format
    check (char_length(youtube_url) <= 500 and youtube_url ~* '^https://'),
  constraint vote_candidates_avatar_url_format
    check (avatar_url is null or (char_length(avatar_url) <= 500 and avatar_url ~* '^https://')),
  constraint vote_candidates_source_type_format
    check (source_type is null or source_type ~ '^[a-z0-9-]{1,32}$'),
  constraint vote_candidates_quality_score_range
    check (quality_score is null or quality_score between 0 and 100),
  constraint vote_candidates_tags_size check (array_length(tags, 1) is null or array_length(tags, 1) <= 40),
  constraint vote_candidates_voditelji_size check (array_length(voditelji, 1) is null or array_length(voditelji, 1) <= 40)
);

create index if not exists ix_vote_candidates_status
  on domovina_ai.vote_candidates (status);
create index if not exists ix_vote_candidates_tags
  on domovina_ai.vote_candidates using gin (tags);

comment on table domovina_ai.vote_candidates is
  'Snapshot podcast registra (fetch.domovina.tv/data/podcasts_registry.json). '
  'Sync nikad ne briše kandidate s glasovima — samo status = ''withdrawn''.';

-- ----- kola (14 dana; kvorum je konfigurabilan PO KOLU) ----------------------
create table if not exists domovina_ai.vote_rounds (
  id               int generated always as identity primary key,
  starts_on        date not null,                 -- Europe/Zagreb kalendarski dan
  ends_on          date not null,                 -- UKLJUČIVO
  status           text not null default 'open',  -- open | closed
  winner_slug      text references domovina_ai.vote_candidates(slug),
  closed_at        timestamptz,
  no_winner_reason text,                          -- 'quorum_not_met'
  quorum_net       int not null default 10,       -- §7.2, podizivo bez migracije
  quorum_total     int not null default 25,
  created_at       timestamptz not null default now(),
  unique (starts_on),
  constraint vote_rounds_status_allowed check (status in ('open','closed')),
  constraint vote_rounds_dates_order check (ends_on >= starts_on),
  constraint vote_rounds_quorum_positive check (quorum_net >= 0 and quorum_total >= 0),
  constraint vote_rounds_no_winner_reason_allowed
    check (no_winner_reason is null or no_winner_reason in ('quorum_not_met'))
);

-- Partial unique index nad konstantnom vrijednošću → najviše JEDNO otvoreno kolo.
create unique index if not exists ux_vote_rounds_one_open
  on domovina_ai.vote_rounds (status) where status = 'open';

-- ----- glasači (trajni pseudonim; preživljava brisanje računa, §4.1) ---------
create table if not exists domovina_ai.voters (
  id             uuid primary key default gen_random_uuid(),
  oib_hash       text not null unique,            -- iz public.identity_verifications
  user_id        uuid references auth.users(id) on delete set null,  -- ★ NE cascade
  current_streak int  not null default 0,
  longest_streak int  not null default 0,
  flags          int  not null default 0 check (flags between 0 and 2),
  last_vote_day  date,
  total_votes    int  not null default 0,
  consented_at   timestamptz,                     -- §4.3 privola pri prvom glasu
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint voters_streaks_nonneg check (current_streak >= 0 and longest_streak >= 0),
  constraint voters_total_votes_nonneg check (total_votes >= 0)
);

create index if not exists ix_voters_user on domovina_ai.voters (user_id);

comment on column domovina_ai.voters.user_id is
  'on delete SET NULL namjerno — glasački identitet preživljava brisanje računa. '
  'Cascade bi probio „jedan čovjek, jedan glas" (obriši račun → ponovno verificiraj → glasaj opet).';

drop trigger if exists trg_voters_updated on domovina_ai.voters;
create trigger trg_voters_updated
  before update on domovina_ai.voters
  for each row execute function public.touch_updated_at();

-- ----- glasovi ---------------------------------------------------------------
create table if not exists domovina_ai.votes (
  id         bigint generated always as identity primary key,
  voter_id   uuid not null references domovina_ai.voters(id) on delete cascade,
  round_id   int  not null references domovina_ai.vote_rounds(id),
  slug       text not null references domovina_ai.vote_candidates(slug),
  direction  smallint not null check (direction in (-1, 1)),
  vote_day   date not null,                       -- Europe/Zagreb, SERVER-SIDE
  created_at timestamptz not null default now(),
  unique (voter_id, vote_day)                     -- ← srce „jedan glas dnevno"
);

create index if not exists ix_votes_round_slug on domovina_ai.votes (round_id, slug);
create index if not exists ix_votes_round_voter on domovina_ai.votes (round_id, voter_id);

comment on constraint votes_voter_id_vote_day_key on domovina_ai.votes is
  'Jedan glas po izbornom danu. Dupli tap / race: druga transakcija padne ovdje '
  'i cast_vote je pretvori u already_voted_today — tally se NE duplira.';

-- ----- agregat po kolu (materijaliziran; piše se u cast_vote transakciji) -----
-- Zašto materijalizirano a ne count(*) view: ljestvica se čita na svakom
-- otvaranju ekrana, a piše najviše jednom po glasaču dnevno.
create table if not exists domovina_ai.vote_tallies (
  round_id int  not null references domovina_ai.vote_rounds(id),
  slug     text not null references domovina_ai.vote_candidates(slug),
  up       int  not null default 0 check (up >= 0),
  down     int  not null default 0 check (down >= 0),
  net      int  generated always as (up - down) stored,
  primary key (round_id, slug)
);

create index if not exists ix_vote_tallies_rank
  on domovina_ai.vote_tallies (round_id, net desc, up desc);

-- ----- praćenje kandidata (BEZ verifikacije, za sve prijavljene) -------------
-- Tablica se stvara sada; UI (⚑ Prati) dolazi u kasnijem krugu.
create table if not exists domovina_ai.candidate_follows (
  user_id    uuid not null references auth.users(id) on delete cascade,
  slug       text not null references domovina_ai.vote_candidates(slug) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, slug)
);

create index if not exists ix_candidate_follows_slug
  on domovina_ai.candidate_follows (slug);

-- ----- enable RLS (policies + grants u _rls migraciji) -----------------------
alter table domovina_ai.vote_candidates   enable row level security;
alter table domovina_ai.vote_rounds       enable row level security;
alter table domovina_ai.voters            enable row level security;
alter table domovina_ai.votes             enable row level security;
alter table domovina_ai.vote_tallies      enable row level security;
alter table domovina_ai.candidate_follows enable row level security;

select 'OK channel_voting schema' as status;
