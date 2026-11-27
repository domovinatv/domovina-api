-- =============================================================================
-- Ulaznice: arhiva („kanta”) objavljenih događaja
--
-- Izvor: domovina-ulaznice, Ivanov zahtjev 2026-11-27. Organizator (admin
-- računa) ili admin platforme objavljeni događaj premjesti u kantu; odande ga
-- isti ljudi vraćaju.
--
--   active/closed ──archive_event──▶ closed + private, archived_* = staro stanje
--                 ◀─unarchive_event── (state/visibility iz archived_*)
--
-- Zašto closed + private umjesto novog stanja: feed (`events-feed`: public +
-- active), RLS čitanja (public/unlisted + active/closed) i create_order
-- (`campaign_not_active`) već tako skrivaju događaj i zaustavljaju prodaju;
-- nijedna druga funkcija se ne mijenja. Prodane ulaznice ostaju valjane.
--
-- archived_* stupce mijenjaju samo ova dva RPC-a: events_write_guard ih bez
-- transakcijske zastavice `ulaznice.arhiva` vraća na staro, a arhiviranom
-- događaju ne da promijeniti stanje ni vidljivost izravnim PATCH-om.
-- Vraćanje u `active` ne traži allowlist (događaj je već bio objavljen), ali
-- rail gate vrijedi: događaj koji nitko ne može platiti se ne vraća u prodaju.
-- Skica se ne arhivira (ima „Obriši skicu”, delete_event_draft).
--
-- Idempotentno: if not exists, create or replace, duplicate_object.
-- =============================================================================

alter table ulaznice.events add column if not exists archived_at timestamptz;
alter table ulaznice.events add column if not exists archived_by uuid;
alter table ulaznice.events add column if not exists archived_state text;
alter table ulaznice.events add column if not exists archived_visibility text;

do $$ begin
  alter table ulaznice.events add constraint events_archived_chk check (
    (archived_at is null and archived_state is null and archived_visibility is null)
    or (archived_at is not null
        and archived_state in ('active', 'closed')
        and archived_visibility in ('private', 'unlisted', 'public'))
  );
exception when duplicate_object then null;
end $$;

comment on column ulaznice.events.archived_at is
  'Događaj u kanti (archive_event); null = nije arhiviran. Stanje prije arhive je u archived_state/archived_visibility.';

create index if not exists ix_events_archived
  on ulaznice.events (archived_at desc)
  where archived_at is not null and deleted_at is null;

-- ----- events_write_guard — + arhiva ------------------------------------------
-- Puno tijelo iz 20261125180000; novo je sve oko v_arhiva.
create or replace function ulaznice.events_write_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recent integer;
  v_arhiva boolean := coalesce(current_setting('ulaznice.arhiva', true), '') = '1';
begin
  if coalesce(auth.role(), '') <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.state := 'draft';
    new.submitted_at := null;
    new.reviewed_at := null;
    new.review_note := null;
    new.archived_at := null;
    new.archived_by := null;
    new.archived_state := null;
    new.archived_visibility := null;

    select count(*) into v_recent
    from ulaznice.events
    where account_id = new.account_id
      and created_at > now() - interval '24 hours';
    if v_recent >= 20 then
      raise exception 'campaign_rate_limited'
        using hint = 'Dosegnut dnevni limit kreiranja događaja.';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    new.account_id := old.account_id;

    if not ulaznice.is_platform_admin() then
      new.reviewed_at := old.reviewed_at;
      new.review_note := old.review_note;
    end if;

    -- arhiva: samo archive_event / unarchive_event (zastavica transakcije)
    if not v_arhiva then
      new.archived_at := old.archived_at;
      new.archived_by := old.archived_by;
      new.archived_state := old.archived_state;
      new.archived_visibility := old.archived_visibility;
      if old.archived_at is not null then
        new.state := old.state;
        new.visibility := old.visibility;
      end if;
    end if;

    -- aktivacija (S3b, odluka 111): isti uvjeti kao publish_event; admin
    -- platforme (approve_event) ili vraćanje iz arhive umjesto allowliste
    if new.state = 'active' and old.state is distinct from 'active' then
      if not ulaznice.is_platform_admin() and not v_arhiva and not exists (
        select 1 from ulaznice.organizer_allowlist al
         where al.account_id = new.account_id
      ) then
        raise exception 'organizer_not_allowlisted';
      end if;
      if not ulaznice.event_rail_ready(new.account_id, new.id) then
        raise exception 'event_no_working_rail'
          using hint = 'Događaj s plaćenim ulaznicama treba aktivan Stripe račun organizatora.';
      end if;
    end if;
  end if;

  return new;
end;
$$;

revoke execute on function ulaznice.events_write_guard() from public, anon, authenticated;

-- ----- archive_event (admin računa ili admin platforme; DEFINER) --------------
create or replace function ulaznice.archive_event(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if not (public.has_role_on_account(v_event.account_id, 'admin') or ulaznice.is_platform_admin()) then
    raise exception 'not_authorized';
  end if;

  -- ponovno arhiviranje je no-op
  if v_event.archived_at is not null then
    return jsonb_build_object('campaign_id', p_campaign_id, 'archived_at', v_event.archived_at);
  end if;
  if v_event.state = 'draft' then raise exception 'event_is_draft'; end if;

  perform set_config('ulaznice.arhiva', '1', true);
  update ulaznice.events
     set archived_at = now(),
         archived_by = (select auth.uid()),
         archived_state = state,
         archived_visibility = visibility,
         state = 'closed',
         visibility = 'private',
         updated_at = now()
   where id = p_campaign_id;
  perform set_config('ulaznice.arhiva', '', true);

  perform public.log_event('event.archived', v_event.account_id,
    jsonb_build_object('campaign_id', p_campaign_id, 'by', (select auth.uid()),
                       'state', v_event.state, 'visibility', v_event.visibility));

  return jsonb_build_object('campaign_id', p_campaign_id, 'archived_at', now());
end;
$$;

revoke execute on function ulaznice.archive_event(uuid) from public, anon;
grant execute on function ulaznice.archive_event(uuid) to authenticated, service_role;

-- ----- unarchive_event (admin računa ili admin platforme; DEFINER) ------------
create or replace function ulaznice.unarchive_event(p_campaign_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_event ulaznice.events;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select * into v_event from ulaznice.events
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if not (public.has_role_on_account(v_event.account_id, 'admin') or ulaznice.is_platform_admin()) then
    raise exception 'not_authorized';
  end if;
  if v_event.archived_at is null then raise exception 'event_not_archived'; end if;
  if v_event.archived_state = 'active'
     and not ulaznice.event_rail_ready(v_event.account_id, v_event.id) then
    raise exception 'event_no_working_rail';
  end if;

  perform set_config('ulaznice.arhiva', '1', true);
  update ulaznice.events
     set state = v_event.archived_state,
         visibility = v_event.archived_visibility,
         archived_at = null,
         archived_by = null,
         archived_state = null,
         archived_visibility = null,
         updated_at = now()
   where id = p_campaign_id;
  perform set_config('ulaznice.arhiva', '', true);

  perform public.log_event('event.unarchived', v_event.account_id,
    jsonb_build_object('campaign_id', p_campaign_id, 'by', (select auth.uid())));

  return jsonb_build_object('campaign_id', p_campaign_id,
    'state', v_event.archived_state, 'visibility', v_event.archived_visibility);
end;
$$;

revoke execute on function ulaznice.unarchive_event(uuid) from public, anon;
grant execute on function ulaznice.unarchive_event(uuid) to authenticated, service_role;

-- ----- platform_events (admin platforme; DEFINER) -----------------------------
-- Svi objavljeni i arhivirani događaji svih organizatora (skice su u
-- review_queue / pregledu organizatora), da ih admin može arhivirati i vratiti.
create or replace function ulaznice.platform_events()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_events jsonb;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if not ulaznice.is_platform_admin() then raise exception 'not_authorized'; end if;

  select coalesce(jsonb_agg(e.event_json order by e.starts_at desc nulls last, e.created_at desc), '[]'::jsonb)
    into v_events
  from (
    select ev.starts_at, ev.created_at, jsonb_build_object(
      'campaign_id', ev.id,
      'account_id', ev.account_id,
      'account_name', acc.name,
      'slug', ev.slug,
      'title', ev.title,
      'state', ev.state,
      'visibility', ev.visibility,
      'archived_at', ev.archived_at,
      'archived_state', ev.archived_state,
      'starts_at', ev.starts_at,
      'venue_city', ev.venue_city,
      'claimed', coalesce((
        select sum(t.inventory_claimed) from ulaznice.ticket_tiers t where t.event_id = ev.id
      ), 0)
    ) as event_json
    from ulaznice.events ev
    join public.accounts acc on acc.id = ev.account_id
    where ev.deleted_at is null
      and (ev.state <> 'draft' or ev.archived_at is not null)
  ) e;

  return jsonb_build_object('events', v_events);
end;
$$;

revoke execute on function ulaznice.platform_events() from public, anon;
grant execute on function ulaznice.platform_events() to authenticated, service_role;

-- ----- organizer_overview — + archived_at -------------------------------------
-- Puno tijelo iz 20261125180000; novo je samo 'archived_at' na događaju.
create or replace function ulaznice.organizer_overview()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_accounts jsonb;
  v_events jsonb;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;

  select coalesce(jsonb_agg(a.account_json order by a.name), '[]'::jsonb) into v_accounts
  from (
    select acc.name, jsonb_build_object(
      'id', acc.id,
      'name', acc.name,
      'is_personal', acc.is_personal_account,
      'allowlisted', exists (
        select 1 from ulaznice.organizer_allowlist al where al.account_id = acc.id
      ),
      'has_record', exists (
        select 1 from ulaznice.organizer_records r where r.account_id = acc.id
      )
    ) as account_json
    from public.accounts acc
    where acc.deleted_at is null
      and public.has_role_on_account(acc.id, 'admin')
  ) a;

  select coalesce(jsonb_agg(e.event_json order by e.created_at desc), '[]'::jsonb) into v_events
  from (
    select ev.created_at, jsonb_build_object(
      'campaign_id', ev.id,
      'account_id', ev.account_id,
      'slug', ev.slug,
      'title', ev.title,
      'state', ev.state,
      'visibility', ev.visibility,
      'submitted_at', ev.submitted_at,
      'reviewed_at', ev.reviewed_at,
      'review_note', ev.review_note,
      'archived_at', ev.archived_at,
      'destination_address', null,
      'event', jsonb_build_object(
        'event_type', ev.event_type,
        'venue_name', ev.venue_name,
        'venue_address', ev.venue_address,
        'venue_city', ev.venue_city,
        'starts_at', ev.starts_at,
        'ends_at', ev.ends_at,
        'timezone', ev.timezone,
        'description_hr', ev.description_hr,
        'description_en', ev.description_en,
        'cover_image_url', ev.cover_image_url,
        'organizer_name', ev.organizer_name,
        'organizer_email', ev.organizer_email,
        'organizer_web', ev.organizer_web
      ),
      'tiers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', t.id,
          'title', t.title,
          'description', t.description,
          'price_cents', t.price_cents,
          'inventory_total', t.inventory_total,
          'inventory_claimed', t.inventory_claimed,
          'imenska', t.imenska,
          'sale_start', t.sale_start,
          'sale_end', t.sale_end,
          'sort', t.sort
        ) order by t.sort)
        from ulaznice.ticket_tiers t
        where t.event_id = ev.id
      ), '[]'::jsonb)
    ) as event_json
    from ulaznice.events ev
    where ev.deleted_at is null
      and public.has_role_on_account(ev.account_id, 'admin')
  ) e;

  return jsonb_build_object(
    'accounts', v_accounts,
    'events', v_events,
    'platform_admin', ulaznice.is_platform_admin()
  );
end;
$$;

revoke execute on function ulaznice.organizer_overview() from public, anon;
grant execute on function ulaznice.organizer_overview() to authenticated, service_role;
notify pgrst, 'reload schema';

select 'OK ulaznice_arhiva' as status;
