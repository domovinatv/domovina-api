-- =============================================================================
-- Gostujuća donacija — pinka-contribute bez Supabase sesije
--
-- Anonimne prijave se gase (docs/sponzorski-trenuci-zakljucak.md §7): 99 %
-- korisnika u auth.users bili su jednokratni anonimni posjetitelji, a samo 3 od
-- 3.028 su ikad prešla u stalni račun. Jedino što je anonimna sesija stvarno
-- nosila bila je uplata bez prijave. Ona sada ide kao GOST — bez lažnog
-- korisnika, istim obrascem kao events-order (service klijent).
--
-- Kočnica zloupotrebe: limit po IP-u (ovdje, dijeljen kroz sve instance edge
-- runtimea) + Turnstile u edge funkciji kad je TURNSTILE_SECRET_KEY postavljen.
-- Gost NE smije rezervirati mjesta (grid/sjedala/trenutke) — hold bez računa
-- je besplatno blokiranje inventara (P9); mjesta traže pravi račun.
-- IP se ne sprema: ključ je HMAC(IP) izračunat u edge funkciji.
--
-- create_contribution se NE mijenja: pozvan service klijentom ima
-- auth.uid() = null → contributor_account_id null (kao anonimna sesija danas,
-- jer anonimni korisnik nema personal account), a hold se veže na 'c:<id>'.
-- =============================================================================

create table if not exists pinka_finance.guest_rate_hits (
  key          text        not null,
  window_start timestamptz not null,
  hits         integer     not null default 0,
  primary key (key, window_start)
);

alter table pinka_finance.guest_rate_hits enable row level security;
-- Nema policyja: piše i čita samo guest_rate_hit (security definer).
revoke all on pinka_finance.guest_rate_hits from anon, authenticated;
grant select, insert, update, delete on pinka_finance.guest_rate_hits to service_role;

comment on table pinka_finance.guest_rate_hits is
  'Brojač gostujućih zahtjeva po HMAC(IP) i vremenskom prozoru. Bez PII.';

-- true = zahtjev smije proći. Prozor je fiksan (floor(epoch / w) * w).
-- p_count = false: samo provjera, kvota se ne troši. pinka-contribute broji
-- tek USPJEŠAN doprinos — neuspjeli pokušaji (409, 400) ne smiju potrošiti
-- kvotu svima iza istog IP-a (CGNAT mobilnih mreža, Wi-Fi na događaju).
drop function if exists pinka_finance.guest_rate_hit(text,integer,integer);
create or replace function pinka_finance.guest_rate_hit(
  p_key            text,
  p_limit          integer,
  p_window_seconds integer,
  p_count          boolean default true
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_start timestamptz := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  v_hits integer;
begin
  if p_key is null or char_length(p_key) > 200 then raise exception 'invalid_key'; end if;

  if not p_count then
    select hits into v_hits from pinka_finance.guest_rate_hits
     where key = p_key and window_start = v_start;
    return coalesce(v_hits, 0) < p_limit;
  end if;

  insert into pinka_finance.guest_rate_hits as g (key, window_start, hits)
  values (p_key, v_start, 1)
  on conflict (key, window_start) do update set hits = g.hits + 1
  returning hits into v_hits;

  -- higijena: stari prozori (jeftino, indeks je primarni ključ)
  if random() < 0.02 then
    delete from pinka_finance.guest_rate_hits where window_start < now() - interval '2 days';
  end if;

  return v_hits <= p_limit;
end;
$$;
revoke execute on function pinka_finance.guest_rate_hit(text,integer,integer,boolean) from public, anon, authenticated;
grant  execute on function pinka_finance.guest_rate_hit(text,integer,integer,boolean) to service_role;

select 'OK pinka_guest_contribute' as status;
