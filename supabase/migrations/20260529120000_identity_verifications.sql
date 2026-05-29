-- =============================================================================
-- 10 — Identity verifications (KYC iz Certilia / NIAS eID)
-- Reference: domovina.ai/docs/compliance/data-protection.md
--
-- Sprema VERIFICIRANI MINIMUM (data minimization, čl. 5(1)(c) GDPR):
--   OIB (enkriptiran), ime, prezime, datum rođenja, država.
-- NE sprema: fotografiju (čl. 9 biometrija — namjerno izbjegnuto), podatke o
-- ispravi, raw claimove.
--
-- Sigurnost (čl. 32 GDPR / TOMs):
--   - OIB enkriptiran pgcrypto-om (pgp_sym_encrypt); ključ živi u edge env-u
--     (KYC_ENCRYPTION_KEY), NIKAD u bazi ni repou.
--   - oib_hash (HMAC-SHA256 istim ključem) za anti-dup lookup bez dekripcije.
--   - RLS uključen, ZERO client policies → tablica je service_role-only.
--     Klijent dobiva samo siguran subset preko my_identity_status() (bez OIB-a).
--   - Brisanje računa kaskadno briše KYC (čl. 17 — pravo na zaborav).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ----- tablica ---------------------------------------------------------------
create table if not exists public.identity_verifications (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  provider           text not null default 'certilia',
  level_of_assurance text,
  oib_ciphertext     bytea not null,                 -- pgp_sym_encrypt(oib, key)
  oib_hash           text not null unique,           -- HMAC-SHA256(oib, key) hex
  first_name         text,
  last_name          text,
  date_of_birth      date,
  country            text,
  verified_at        timestamptz not null default now(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
-- oib_hash unique → jedan verificirani OIB = jedan račun (anti-duplikat).

drop trigger if exists trg_identity_verifications_updated on public.identity_verifications;
create trigger trg_identity_verifications_updated
  before update on public.identity_verifications
  for each row execute function public.touch_updated_at();

-- ----- RLS: service_role-only (kao user_passkeys) ---------------------------
alter table public.identity_verifications enable row level security;
-- Namjerno BEZ policy-ja za anon/authenticated — klijent NIKAD ne čita ovu
-- tablicu direktno (OIB je osjetljiv). Sve ide kroz RPC-eve ispod.
revoke all on public.identity_verifications from anon, authenticated;
grant select, insert, update, delete on public.identity_verifications to service_role;

-- ----- upsert (service_role / edge fn) --------------------------------------
-- Enkriptira OIB + računa hash; idempotentno po user_id. p_key = KYC_ENCRYPTION_KEY.
create or replace function public.upsert_identity_verification(
  p_user_id uuid,
  p_oib     text,
  p_first   text,
  p_last    text,
  p_dob     date,
  p_country text,
  p_key     text,
  p_provider text default 'certilia',
  p_loa     text default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_oib is null or length(p_oib) = 0 then
    raise exception 'oib_required';
  end if;

  insert into public.identity_verifications (
    user_id, provider, level_of_assurance,
    oib_ciphertext, oib_hash,
    first_name, last_name, date_of_birth, country, verified_at
  ) values (
    p_user_id, p_provider, p_loa,
    extensions.pgp_sym_encrypt(p_oib, p_key),
    encode(extensions.hmac(p_oib, p_key, 'sha256'), 'hex'),
    p_first, p_last, p_dob, p_country, now()
  )
  on conflict (user_id) do update set
    provider           = excluded.provider,
    level_of_assurance = excluded.level_of_assurance,
    oib_ciphertext     = excluded.oib_ciphertext,
    oib_hash           = excluded.oib_hash,
    first_name         = excluded.first_name,
    last_name          = excluded.last_name,
    date_of_birth      = excluded.date_of_birth,
    country            = excluded.country,
    verified_at        = now(),
    updated_at         = now();
end;
$$;

revoke execute on function public.upsert_identity_verification(uuid,text,text,text,date,text,text,text,text) from public, anon, authenticated;
grant execute on function public.upsert_identity_verification(uuid,text,text,text,date,text,text,text,text) to service_role;

-- ----- my_identity_status (authenticated) -----------------------------------
-- Siguran subset za prijavljenog usera — OIB i datum rođenja NIKAD ne izlaze.
create or replace function public.my_identity_status()
returns jsonb
language sql security definer set search_path = '' stable
as $$
  select coalesce(
    (select jsonb_build_object(
       'verified', true,
       'provider', provider,
       'first_name', first_name,
       'last_name', last_name,
       'country', country,
       'verified_at', verified_at)
     from public.identity_verifications
     where user_id = (select auth.uid())),
    jsonb_build_object('verified', false)
  );
$$;

revoke execute on function public.my_identity_status() from public, anon;
grant execute on function public.my_identity_status() to authenticated, service_role;

select 'OK 10 identity_verifications' as status;
