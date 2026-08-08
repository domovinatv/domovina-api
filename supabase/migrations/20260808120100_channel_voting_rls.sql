-- =============================================================================
-- Izborni dan — grants + RLS policies
-- Reference: domovina.ai/docs/plans/2026-08-08-glasanje-o-kanalima.md §5.1
--
--   vote_candidates / vote_rounds / vote_tallies
--        → SELECT za anon + authenticated (rezultati su javni, §4.3);
--          insert/update/delete NITKO osim service_role.
--   voters / votes
--        → ZERO client policies, isti model kao public.identity_verifications.
--          Klijent im pristupa isključivo kroz SECURITY DEFINER RPC-eve
--          (_rpcs migracija). Bez policy-ja + RLS on = klijent ne vidi ništa,
--          ali revokamo i grants da ne ovisimo samo o RLS-u.
--   candidate_follows
--        → select/insert/delete nad VLASTITIM user_id; update nema smisla.
--
-- ⚠ 20260520120600 postavlja `alter default privileges in schema domovina_ai
--   grant select, insert, update, delete on tables to authenticated` (+ select
--   za anon). Nove tablice to naslijede AUTOMATSKI — zato je svaki revoke ispod
--   nužan, ne kozmetički.
-- =============================================================================

-- ----- vote_candidates (javno čitljivo, service_role piše) -------------------
revoke insert, update, delete on domovina_ai.vote_candidates from anon, authenticated;
grant select on domovina_ai.vote_candidates to anon, authenticated;
grant select, insert, update, delete on domovina_ai.vote_candidates to service_role;

drop policy if exists vote_candidates_select on domovina_ai.vote_candidates;
create policy vote_candidates_select on domovina_ai.vote_candidates
  for select to anon, authenticated
  using (true);

-- ----- vote_rounds (javno čitljivo, service_role/RPC piše) -------------------
revoke insert, update, delete on domovina_ai.vote_rounds from anon, authenticated;
grant select on domovina_ai.vote_rounds to anon, authenticated;
grant select, insert, update, delete on domovina_ai.vote_rounds to service_role;
grant usage, select on sequence domovina_ai.vote_rounds_id_seq to service_role;
revoke all on sequence domovina_ai.vote_rounds_id_seq from anon, authenticated;

drop policy if exists vote_rounds_select on domovina_ai.vote_rounds;
create policy vote_rounds_select on domovina_ai.vote_rounds
  for select to anon, authenticated
  using (true);

-- ----- vote_tallies (javni agregat) ------------------------------------------
revoke insert, update, delete on domovina_ai.vote_tallies from anon, authenticated;
grant select on domovina_ai.vote_tallies to anon, authenticated;
grant select, insert, update, delete on domovina_ai.vote_tallies to service_role;

drop policy if exists vote_tallies_select on domovina_ai.vote_tallies;
create policy vote_tallies_select on domovina_ai.vote_tallies
  for select to anon, authenticated
  using (true);

-- ----- voters (ZERO client policies — pseudonim + niz) -----------------------
-- Namjerno BEZ ijedne policy za anon/authenticated. oib_hash ne smije nikad
-- izaći iz baze, a niz/zastavice klijent dobiva kroz my_voting_state().
revoke all on domovina_ai.voters from public, anon, authenticated;
grant select, insert, update, delete on domovina_ai.voters to service_role;

-- ----- votes (ZERO client policies — pojedinačni glas se NE objavljuje) ------
-- §4.3: glas za kanal s tagom political/religious može posredno otkriti
-- uvjerenje (GDPR čl. 9). Javni su samo agregati u vote_tallies.
revoke all on domovina_ai.votes from public, anon, authenticated;
grant select, insert, update, delete on domovina_ai.votes to service_role;
revoke all on sequence domovina_ai.votes_id_seq from anon, authenticated;
grant usage, select on sequence domovina_ai.votes_id_seq to service_role;

-- ----- candidate_follows (vlastiti redovi; radi bez verifikacije) ------------
revoke all on domovina_ai.candidate_follows from anon;
revoke update on domovina_ai.candidate_follows from authenticated;
grant select, insert, delete on domovina_ai.candidate_follows to authenticated;
grant select, insert, update, delete on domovina_ai.candidate_follows to service_role;

drop policy if exists candidate_follows_select on domovina_ai.candidate_follows;
create policy candidate_follows_select on domovina_ai.candidate_follows
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists candidate_follows_insert on domovina_ai.candidate_follows;
create policy candidate_follows_insert on domovina_ai.candidate_follows
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists candidate_follows_delete on domovina_ai.candidate_follows;
create policy candidate_follows_delete on domovina_ai.candidate_follows
  for delete to authenticated
  using (user_id = (select auth.uid()));

select 'OK channel_voting rls' as status;
