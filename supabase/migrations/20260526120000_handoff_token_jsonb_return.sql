-- =============================================================================
-- 07 — create_handoff_token() returns jsonb {code, expires_at}
--
-- Razlog: Flutter frontend očekuje objekt s expires_at da prikaže countdown
-- bez hardcodiranja 5-min TTL na client strani. expires_at je već default
-- u tablici (now() + 5min) — vraćamo ga iz INSERT ... RETURNING.
--
-- BREAKING: return type se mijenja text → jsonb. Mora DROP pa CREATE.
-- Nijedan drugi backend kod ne zove ovaj RPC (samo Flutter client).
-- =============================================================================

drop function if exists domovina_ai.create_handoff_token();

create or replace function domovina_ai.create_handoff_token()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_code text;
  v_expires_at timestamptz;
  v_try int := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  delete from domovina_ai.handoff_tokens
    where user_id = v_uid and consumed_at is null;

  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    begin
      insert into domovina_ai.handoff_tokens (code, user_id)
        values (v_code, v_uid)
        returning expires_at into v_expires_at;
      return jsonb_build_object('code', v_code, 'expires_at', v_expires_at);
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try >= 5 then
        raise exception 'handoff_code_collision' using errcode = '23505';
      end if;
    end;
  end loop;
end;
$$;

grant execute on function domovina_ai.create_handoff_token() to authenticated;

select 'OK 07 handoff_token_jsonb_return' as status;
