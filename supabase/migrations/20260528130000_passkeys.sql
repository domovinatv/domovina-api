-- =============================================================================
-- 09 — Passkeys / WebAuthn (custom ceremony)
-- Reference: domovina.ai/docs/backend-prompts/05-auth-providers.md §5
--
-- GoTrue (v2.186) nema first-class passwordless passkey login → custom WebAuthn
-- ceremonija u Edge funkciji `passkey` (register/login start+finish).
--
-- Tablice (public — platform-core, vežu se na auth.users, dijeli ih N frontenda):
--   public.user_passkeys        — pohranjene credentiale (COSE public key, counter)
--   public.webauthn_challenges  — kratkotrajni anti-replay store start↔finish
--
-- Pristup: SAMO service_role (Edge fn s service key-em). Klijent NE čita/piše
-- direktno — sve ide kroz Edge funkciju. RLS uključen + zero client policies +
-- bez grantova za anon/authenticated → potpuno zatvoreno za PostgREST.
-- =============================================================================

-- ===== public.user_passkeys =================================================
create table if not exists public.user_passkeys (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  credential_id text not null unique,            -- base64url
  public_key    text not null,                   -- COSE key, base64url (PostgREST-friendly)
  sign_count    bigint not null default 0,
  transports    text[],                          -- ['internal','hybrid','usb',...]
  device_name   text,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz
);

create index if not exists ix_passkeys_user on public.user_passkeys(user_id);

alter table public.user_passkeys enable row level security;
-- Namjerno BEZ policy-ja za anon/authenticated: klijent nikad ne dira ovu tablicu
-- direktno; sva manipulacija ide kroz `passkey` Edge funkciju (service_role,
-- bypassa RLS). Bez grantova ispod PostgREST ne može ni pokušati query.

-- ===== public.webauthn_challenges ===========================================
-- Challenge se izda u /start, verificira i obriše u /finish. Kratkotrajno
-- (~5 min). user_id je nullable: kod login/start i new-signup register/start
-- još ne znamo (ili nemamo) usera.
create table if not exists public.webauthn_challenges (
  id          uuid primary key default gen_random_uuid(),
  challenge   text not null,                     -- base64url, izdan klijentu
  kind        text not null check (kind in ('register', 'login')),
  -- Kontekst registracije, pohranjen server-side da NE vjerujemo klijentu
  -- između /start i /finish:
  user_id     uuid references auth.users(id) on delete cascade,  -- add-to-existing (signed-in)
  email       text,                              -- new-signup (account identifier)
  expires_at  timestamptz not null default (now() + interval '5 minutes'),
  created_at  timestamptz not null default now()
);

create index if not exists ix_webauthn_challenges_challenge
  on public.webauthn_challenges(challenge);

alter table public.webauthn_challenges enable row level security;
-- Isto kao gore: zero client policies, samo service_role (Edge fn) pristupa.

-- ===== grants ===============================================================
-- Public schema default-no GRANT-a sve role-ovima preko Supabase bootstrapa +
-- ALTER DEFAULT PRIVILEGES. Eksplicitno REVOKE-amo da anon/authenticated NE mogu
-- ni pokušati dohvatiti credential/challenge redove preko PostgREST-a.
revoke all on public.user_passkeys from anon, authenticated;
revoke all on public.webauthn_challenges from anon, authenticated;
grant select, insert, update, delete on public.user_passkeys to service_role;
grant select, insert, update, delete on public.webauthn_challenges to service_role;

-- ===== cleanup_expired_webauthn_challenges ==================================
-- Briše istekle/zaostale challenge redove. Pozove ga pg_cron (vidi handoff
-- cleanup obrazac u 06) ili Edge fn oportunistički.
create or replace function public.cleanup_expired_webauthn_challenges()
returns int
language sql security definer set search_path = ''
as $$
  with deleted as (
    delete from public.webauthn_challenges
    where expires_at < now()
    returning id
  )
  select count(*)::int from deleted;
$$;

revoke execute on function public.cleanup_expired_webauthn_challenges() from public;
revoke execute on function public.cleanup_expired_webauthn_challenges() from anon, authenticated;
grant execute on function public.cleanup_expired_webauthn_challenges() to service_role;

-- ===== pg_cron schedule (opcionalno — vidi 06, isti razlog: ne diramo ovdje) =
--   select cron.schedule(
--     'cleanup-webauthn-challenges', '*/15 * * * *',
--     $$select public.cleanup_expired_webauthn_challenges();$$
--   );

select 'OK 09 passkeys' as status;
