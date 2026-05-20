-- =============================================================================
-- 07 (extra) — Schema grants za anon/authenticated/service_role
--
-- PostgREST koristi anon (default) i authenticated (s JWT) Postgres role.
-- Bez table-level grants oni ne mogu ni napraviti query — RLS se evaluira TEK
-- nakon grant-a. Standardni Supabase pattern je grant SVE pa RLS reguliše.
--
-- Public schema već ima ove grants iz Supabase bootstrap-a; domovina_ai treba
-- iste eksplicitno.
-- =============================================================================

-- ----- domovina_ai schema usage ----------------------------------------------
grant usage on schema domovina_ai to anon, authenticated, service_role;

-- ----- table grants — RLS gating gore u 04 -----------------------------------
-- Grants su "may attempt"; RLS odlučuje "may see/modify".
grant select, insert, update, delete on all tables in schema domovina_ai
  to authenticated, service_role;

-- anon dobiva samo select (read-only) — pisanje uvijek treba authenticated
-- (anonymous Supabase user JE authenticated jer ima JWT, samo bez emaila).
grant select on all tables in schema domovina_ai to anon;

-- ----- sequences (bigserial id stupci) ---------------------------------------
grant usage, select on all sequences in schema domovina_ai
  to authenticated, service_role;

-- ----- function grants (već postavljeni u 03, ali default privileges) -------
grant execute on all functions in schema domovina_ai to authenticated, service_role;

-- ----- default privileges za buduće tablice ----------------------------------
-- Da ne moramo ručno dodavati grants za svaki novi table.
alter default privileges in schema domovina_ai grant
  select, insert, update, delete on tables to authenticated, service_role;
alter default privileges in schema domovina_ai grant
  select on tables to anon;
alter default privileges in schema domovina_ai grant
  usage, select on sequences to authenticated, service_role;
alter default privileges in schema domovina_ai grant
  execute on functions to authenticated, service_role;

-- ----- search_path za authenticated role ------------------------------------
-- Da Flutter klijent može pisati `watch_progress` umjesto `domovina_ai.watch_progress`
-- (opcionalno — supabase-js i supabase_flutter ionako fully qualify-aju).
-- Ovo NEMA utjecaj na security; RLS i grants su nepromijenjeni.
-- alter role authenticated set search_path to public, domovina_ai;
-- (Komentirano — bolje da klijenti eksplicitno koriste .schema('domovina_ai'))

select 'OK 07 grants_and_search_path' as status;
