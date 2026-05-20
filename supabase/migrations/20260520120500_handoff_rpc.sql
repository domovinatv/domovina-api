-- =============================================================================
-- 06 — Handoff RPC (M4 cross-device sign-in)
-- Reference: domovina.ai/docs/backend-prompts/06-handoff-rpc.md
--
-- Funkcije:
--   domovina_ai.create_handoff_token()                     — caller=authenticated, vraća 6-digit
--   domovina_ai.consume_handoff_token(text, text)          — service_role only (edge fn)
--   domovina_ai.cleanup_expired_handoffs()                 — pozove ga pg_cron (opcionalno)
--
-- pg_cron scheduling je NA KRAJU; ako extension nije instaliran preskače se.
-- =============================================================================

-- ===== create_handoff_token =================================================
-- Caller mora biti authenticated. Briše stare nepotrošene kodove istog usera,
-- generira novi 6-znamenkasti, retry-a do 5 puta na collision (vrlo nevjerojatno).
create or replace function domovina_ai.create_handoff_token()
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_code text;
  v_try int := 0;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  -- Cleanup postojećih nepotrošenih (jedan aktivan kod po useru)
  delete from domovina_ai.handoff_tokens
    where user_id = v_uid and consumed_at is null;

  loop
    v_code := lpad((floor(random() * 1000000))::int::text, 6, '0');
    begin
      insert into domovina_ai.handoff_tokens (code, user_id) values (v_code, v_uid);
      return v_code;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try >= 5 then
        raise exception 'handoff_code_collision' using errcode = '23505';
      end if;
    end;
  end loop;
end;
$$;

-- ===== consume_handoff_token ================================================
-- POZIVA SE ISKLJUČIVO IZ service_role (edge function), nikad iz Flutter klijenta.
-- Vraća user_id koji se sign-in-a; sign-in flow napravi caller (admin.generateLink).
create or replace function domovina_ai.consume_handoff_token(
  p_code text,
  p_device text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_user_id uuid;
  v_device domovina_ai.device_type;
begin
  if p_code !~ '^[0-9]{6}$' then
    raise exception 'invalid_code_format';
  end if;

  if p_device is not null and p_device <> '' then
    begin
      v_device := p_device::domovina_ai.device_type;
    exception when invalid_text_representation then
      raise exception 'invalid_device_type: %', p_device;
    end;
  end if;

  -- FOR UPDATE SKIP LOCKED → atomic claim, ako dva consume-a stignu istovremeno
  -- samo jedan dobije red.
  select user_id into v_user_id
    from domovina_ai.handoff_tokens
    where code = p_code
      and consumed_at is null
      and expires_at > now()
    for update skip locked;

  if v_user_id is null then
    raise exception 'invalid_or_expired_code';
  end if;

  update domovina_ai.handoff_tokens
    set consumed_at = now(),
        consumed_by_device = v_device
    where code = p_code;

  return jsonb_build_object('user_id', v_user_id, 'success', true);
end;
$$;

-- ===== cleanup_expired_handoffs ============================================
-- Brišemo tokens stare > 1 dan (bilo expired ili consumed).
create or replace function domovina_ai.cleanup_expired_handoffs()
returns int
language sql security definer set search_path = ''
as $$
  with deleted as (
    delete from domovina_ai.handoff_tokens
    where (expires_at < now() - interval '1 day')
       or (consumed_at < now() - interval '1 day')
    returning code
  )
  select count(*)::int from deleted;
$$;

-- ===== grants ==============================================================
-- create: caller=authenticated user
grant execute on function domovina_ai.create_handoff_token() to authenticated;
-- consume: SAMO service_role (edge function). Eksplicitno revoke za authenticated.
revoke execute on function domovina_ai.consume_handoff_token(text, text) from public;
revoke execute on function domovina_ai.consume_handoff_token(text, text) from authenticated;
-- cleanup: service_role only (pg_cron radi kao postgres anyway)
revoke execute on function domovina_ai.cleanup_expired_handoffs() from public;
revoke execute on function domovina_ai.cleanup_expired_handoffs() from authenticated;

-- ===== pg_cron schedule (opcionalno — preskoči ako extension nije dostupan) =
-- pg_cron baza je obično "postgres" — jobs se ne mogu zakazati iz arbitrarne DB
-- bez konfiguracije. U Coolify Supabase template-u pg_cron je dostupan ali
-- treba enable. Sigurnije ne dirati ovdje — dodati zasebno kad bude trebalo.
--
-- Ručno (kao postgres superuser, jednom):
--   create extension if not exists pg_cron;
--   select cron.schedule(
--     'cleanup-handoffs',
--     '*/15 * * * *',
--     $$select domovina_ai.cleanup_expired_handoffs();$$
--   );

select 'OK 06 handoff_rpc' as status;
