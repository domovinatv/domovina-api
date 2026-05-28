-- =============================================================================
-- 08 — migrate_anon_data() RPC (M3 anon → permanent promocija)
--
-- Frontend (auth_service.dart) nakon anon→permanent promocije zove
-- domovina_ai.migrate_anon_data(p_anon_id) da prebaci watch state s anon usera
-- na novopromovirani permanent user.
--
-- Vlasništvo (NE miješati):
--   watch_progress.user_id → public.profiles  (per-user, PK (user_id, episode_id))
--   watch_sessions.user_id → public.profiles  (append-only)
--   favorites.owner_id     → public.accounts  (NE diramo ovdje — account-scoped)
--
-- security definer + search_path = '' → bypassa RLS (owner = postgres),
-- ali interno gate-amo na auth.uid() i provjeru da caller NIJE anon.
--
-- NB: bez inline begin/commit — db-migrate.sh već wrappa svaku migraciju u
-- transakciju + tracking insert (vidi scripts/db-migrate.sh).
-- =============================================================================

create or replace function domovina_ai.migrate_anon_data(p_anon_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_moved_progress int := 0;
  v_moved_sessions int := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- caller mora biti promovirani (ne anon) user
  if coalesce((select auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'caller_still_anonymous' using errcode = '42501';
  end if;

  -- watch_progress: prebaci anon redove koji NE konfliktiraju s postojećima
  update domovina_ai.watch_progress wp
     set user_id = v_uid
   where wp.user_id = p_anon_id
     and not exists (
       select 1 from domovina_ai.watch_progress wp2
        where wp2.user_id = v_uid and wp2.episode_id = wp.episode_id
     );
  get diagnostics v_moved_progress = row_count;

  -- konflikti: permanent verzija pobjeđuje, briši anon duplikate
  delete from domovina_ai.watch_progress where user_id = p_anon_id;

  -- watch_sessions: append-only, samo re-owner
  update domovina_ai.watch_sessions
     set user_id = v_uid
   where user_id = p_anon_id;
  get diagnostics v_moved_sessions = row_count;

  return jsonb_build_object(
    'moved_watch_progress', v_moved_progress,
    'moved_watch_sessions', v_moved_sessions,
    'new_user_id', v_uid
  );
end;
$$;

grant execute on function domovina_ai.migrate_anon_data(uuid) to authenticated;

select 'OK 08 anon_data_migration_rpc' as status;
