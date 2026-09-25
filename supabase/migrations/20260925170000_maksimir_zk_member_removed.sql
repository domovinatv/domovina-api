-- =============================================================================
-- Maksimir ZK grupa: svako brisanje člana zapisuje 'remove' u zapisnik grupe.
--
-- U 20260925160000 je maksimir_zk_members.voter_id `on delete cascade`, pa bi
-- brisanje glasača tiho maknulo člana iz tablice, a zapisnik grupe bi ga i dalje
-- sadržavao. Grupa iz zapisnika i broj članova (maksimir_zk_head) bi se razišli,
-- a maksimir_verify.py --zk bi to prijavio. Sad je jedini put uklanjanja okidač,
-- pa su zapisnik i tablica uvijek usklađeni.
-- =============================================================================

create or replace function domovina_ai._maksimir_zk_member_removed()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform domovina_ai._maksimir_zk_append('remove', old.commitment);
  return old;
end;
$$;

revoke execute on function domovina_ai._maksimir_zk_member_removed() from public, anon, authenticated;

drop trigger if exists trg_maksimir_zk_member_removed on domovina_ai.maksimir_zk_members;
create trigger trg_maksimir_zk_member_removed
  after delete on domovina_ai.maksimir_zk_members
  for each row execute function domovina_ai._maksimir_zk_member_removed();

-- Zamjena ključa: brisanje starog člana (okidač zapisuje 'remove'), pa 'add' novog.
create or replace function domovina_ai._maksimir_zk_register_for(p_user_id uuid, p_commitment text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_old   domovina_ai.maksimir_zk_members%rowtype;
  v_row   domovina_ai.maksimir_zk_log%rowtype;
begin
  if not domovina_ai._maksimir_is_field(p_commitment) or p_commitment = '0' then
    raise exception 'invalid_commitment';
  end if;
  v_voter := domovina_ai._maksimir_voter_for_update(p_user_id);

  select * into v_old from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;
  if found and v_old.commitment = p_commitment then
    return jsonb_build_object('seq', v_old.added_seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
  end if;
  if exists (select 1 from domovina_ai.maksimir_zk_log l where l.commitment = p_commitment) then
    raise exception 'commitment_taken';   -- ni trenutni ni uklonjeni commitment se ne smije ponoviti
  end if;

  if v_old.voter_id is not null then
    delete from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;   -- okidač: 'remove'
  end if;
  v_row := domovina_ai._maksimir_zk_append('add', p_commitment);
  insert into domovina_ai.maksimir_zk_members (voter_id, commitment, added_seq)
  values (v_voter.id, p_commitment, v_row.seq);

  return jsonb_build_object('seq', v_row.seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
end;
$$;

select 'OK maksimir_zk_member_removed' as status;
