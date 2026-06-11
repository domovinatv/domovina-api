-- =============================================================================
-- pinka_finance — hardening kreiranja/uređivanja kampanje (server-side)
--
-- Do sada je validacija kampanje živjela u klijentu (static SPA piše direktno
-- u Postgres), a server je imao samo RLS + 3 check constrainta. Ova migracija
-- podiže server na razinu od koje klijent ne može pobjeći:
--
--   1. sanity/length constrainti (NOT VALID — postojeći redovi se ne diraju)
--   2. BEFORE INSERT guard: state se forsira na 'draft', rate limit po accountu
--   3. BEFORE UPDATE guard: destination_address se ZAKLJUČAVA nakon prve
--      plaćene uplate (anti-rug: kompromitirani račun ne može preusmjeriti
--      buduće donacije s tiskanih QR kodova); aktivacija bez pravog Safe-a
--      (nulta adresa) odbija se i serverski; account_id je immutable
--   4. pinka_finance.create_campaign(...) RPC — idempotentno kreiranje
--      (client-generated id; retry nakon prekida mreže vraća postojeću
--      kampanju umjesto 23505), slug se generira server-side (rješava race),
--      cross-field validacija (min ≤ cilj, datumi, koordinate…), metadata
--      whitelist (klijent smije poslati samo 'safe' ključ)
--   5. storage bucket 'pinka-covers' — cover slike kampanja (upload umjesto
--      free-text URL-a: bez hotlinkanja/tracking piksela); path mora počinjati
--      s auth.uid(), upload samo KYC-verificiran korisnik
--
-- Guardovi se primjenjuju SAMO na zahtjeve s auth.role() = 'authenticated'
-- (PostgREST klijenti); service_role / psql / edge fns prolaze netaknuto.
--
-- RPC je security INVOKER: postojeći RLS (has_role_on_account admin +
-- is_identity_verified) i dalje vrijedi za insert.
-- =============================================================================

-- ----- 1. sanity / length constrainti ---------------------------------------
alter table pinka_finance.campaigns
  drop constraint if exists campaigns_title_len,
  drop constraint if exists campaigns_description_len,
  drop constraint if exists campaigns_location_name_len,
  drop constraint if exists campaigns_subject_type_format,
  drop constraint if exists campaigns_subject_ref_len,
  drop constraint if exists campaigns_cover_url_format,
  drop constraint if exists campaigns_dates_order,
  drop constraint if exists campaigns_goal_sane,
  drop constraint if exists campaigns_min_sane,
  drop constraint if exists campaigns_metadata_size;

alter table pinka_finance.campaigns
  add constraint campaigns_title_len
    check (char_length(title) between 1 and 160) not valid,
  add constraint campaigns_description_len
    check (description is null or char_length(description) <= 20000) not valid,
  add constraint campaigns_location_name_len
    check (location_name is null or char_length(location_name) <= 160) not valid,
  add constraint campaigns_subject_type_format
    check (subject_type ~ '^[a-z0-9_]{1,40}$') not valid,
  add constraint campaigns_subject_ref_len
    check (subject_ref is null or char_length(subject_ref) <= 200) not valid,
  add constraint campaigns_cover_url_format
    check (cover_image_url is null
           or (char_length(cover_image_url) <= 1000 and cover_image_url ~* '^https://'))
    not valid,
  add constraint campaigns_dates_order
    check (starts_at is null or ends_at is null or ends_at > starts_at) not valid,
  -- cilj: ≤ 100 mil. € (sanity cap, ne poslovni limit)
  add constraint campaigns_goal_sane
    check (goal_cents is null or goal_cents <= 10000000000) not valid,
  -- najmanji doprinos: ≤ 10.000 €
  add constraint campaigns_min_sane
    check (min_contribution_cents <= 1000000) not valid,
  add constraint campaigns_metadata_size
    check (pg_column_size(metadata) <= 16384) not valid;

-- ----- 2./3. write guardovi (BEFORE INSERT/UPDATE) ---------------------------
create or replace function pinka_finance.campaigns_write_guard()
returns trigger
language plpgsql
as $$
declare
  v_recent integer;
begin
  -- samo PostgREST 'authenticated' klijenti; service_role/psql netaknuti
  if coalesce(auth.role(), '') <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- kampanja se UVIJEK rađa kao nacrt — aktivaciju radi eksplicitni update
    new.state := 'draft';
    new.safe_deployed_at := null;

    -- anti-spam: max 20 kampanja po accountu u 24 h (KYC korisnik je poznat,
    -- ali i poznat korisnik može naštancati smeće)
    select count(*) into v_recent
    from pinka_finance.campaigns
    where account_id = new.account_id
      and created_at > now() - interval '24 hours';
    if v_recent >= 20 then
      raise exception 'campaign_rate_limited'
        using hint = 'Dosegnut dnevni limit kreiranja kampanja.';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- vlasništvo se ne prenosi update-om
    new.account_id := old.account_id;

    -- destination lock: nakon prve PLAĆENE uplate adresa je nepromjenjiva
    -- (tiskani QR / permanentni linkovi vode na kampanju — preusmjeravanje
    -- budućih uplata je rug-vektor kompromitiranog računa)
    if new.destination_address is distinct from old.destination_address then
      if exists (
        select 1 from pinka_finance.contributions c
        where c.campaign_id = old.id and c.state = 'paid'
      ) then
        raise exception 'campaign_destination_locked'
          using hint = 'Adresa računa je zaključana nakon prve uplate.';
      end if;
    end if;
  end if;

  -- aktivacija bez pravog Safe-a = donacije na nultu adresu (spaljene).
  -- UI guard postoji; ovo je serverski mirror.
  if new.state = 'active'
     and (new.destination_address is null
          or new.destination_address ~* '^0x0{40}$') then
    raise exception 'campaign_destination_missing'
      using hint = 'Kampanja ne može biti aktivna bez računa (Safe).';
  end if;

  return new;
end;
$$;

drop trigger if exists campaigns_write_guard on pinka_finance.campaigns;
create trigger campaigns_write_guard
  before insert or update on pinka_finance.campaigns
  for each row execute function pinka_finance.campaigns_write_guard();

-- ----- 4. create_campaign RPC ------------------------------------------------
-- SQL slugify — zrcali lib/format.ts slugify (lowercase, hr dijakritici,
-- alfanum + crtice, max 60, rubovi alfanum)
create or replace function pinka_finance.slugify(p text)
returns text
language sql
immutable
as $$
  select regexp_replace(
    left(
      regexp_replace(
        regexp_replace(
          translate(lower(coalesce(p, '')), 'čćžšđ', 'cczsd'),
          '[^a-z0-9]+', '-', 'g'),
        '(^-+|-+$)', '', 'g'),
      60),
    '-+$', '');
$$;

create or replace function pinka_finance.create_campaign(
  p_id uuid,
  p_account_id uuid,
  p_title text,
  p_type text default 'donation',
  p_description text default null,
  p_goal_cents bigint default null,
  p_min_contribution_cents integer default 100,
  p_destination_address text default null,
  p_subject_type text default 'generic',
  p_subject_ref text default null,
  p_visibility text default 'private',
  p_recurrence text default 'none',
  p_recurrence_anchor_day integer default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_location_name text default null,
  p_cover_image_url text default null,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
-- security INVOKER (default): RLS insert policy (admin + KYC) i dalje vrijedi
as $$
declare
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_base text;
  v_slug text;
  v_existing record;
  v_constraint text;
  v_meta jsonb;
  i integer;
begin
  -- ── idempotencija: retry s istim client-generated id vraća postojeću ──────
  select id, slug into v_existing
  from pinka_finance.campaigns
  where id = p_id and account_id = p_account_id;
  if found then
    return jsonb_build_object('id', v_existing.id, 'slug', v_existing.slug, 'existing', true);
  end if;

  -- ── validacija (poruke su strojni kodovi; klijent ih mapira na i18n) ──────
  if v_title is null or char_length(v_title) < 3 or char_length(v_title) > 160 then
    raise exception 'invalid_title';
  end if;
  if p_description is not null and char_length(p_description) > 20000 then
    raise exception 'invalid_description';
  end if;
  if p_type is null or p_type not in ('donation','crowdfund','tokenization','tickets','realestate') then
    raise exception 'invalid_type';
  end if;
  if p_visibility is null or p_visibility not in ('private','unlisted','public') then
    raise exception 'invalid_visibility';
  end if;
  if p_recurrence is null or p_recurrence not in ('none','monthly','quarterly','yearly') then
    raise exception 'invalid_recurrence';
  end if;
  if p_recurrence_anchor_day is not null
     and (p_recurrence <> 'monthly' or p_recurrence_anchor_day not between 1 and 31) then
    raise exception 'invalid_anchor_day';
  end if;
  if p_goal_cents is not null and (p_goal_cents < 100 or p_goal_cents > 10000000000) then
    raise exception 'invalid_goal';
  end if;
  if p_min_contribution_cents is null
     or p_min_contribution_cents < 1 or p_min_contribution_cents > 1000000 then
    raise exception 'invalid_min_contribution';
  end if;
  if p_goal_cents is not null and p_min_contribution_cents > p_goal_cents then
    raise exception 'min_exceeds_goal';
  end if;
  if p_destination_address is null or p_destination_address !~ '^0x[0-9a-fA-F]{40}$' then
    raise exception 'invalid_destination';
  end if;
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'invalid_location';
  end if;
  if p_latitude is not null
     and (p_latitude not between -90 and 90 or p_longitude not between -180 and 180) then
    raise exception 'invalid_location';
  end if;
  if p_location_name is not null and char_length(p_location_name) > 160 then
    raise exception 'invalid_location_name';
  end if;
  if p_subject_type is null or p_subject_type !~ '^[a-z0-9_]{1,40}$' then
    raise exception 'invalid_subject_type';
  end if;
  if p_subject_ref is not null and char_length(p_subject_ref) > 200 then
    raise exception 'invalid_subject_ref';
  end if;
  if p_cover_image_url is not null
     and (char_length(p_cover_image_url) > 1000 or p_cover_image_url !~* '^https://') then
    raise exception 'invalid_cover_url';
  end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception 'invalid_dates';
  end if;
  if p_ends_at is not null and p_ends_at <= now() then
    raise exception 'invalid_dates';
  end if;

  -- metadata whitelist: klijent smije poslati samo 'safe' (custody zapis)
  v_meta := case
    when p_metadata ? 'safe' then jsonb_build_object('safe', p_metadata->'safe')
    else '{}'::jsonb
  end;

  -- ── slug server-side (unique race riješen retryjem na 23505) ─────────────
  v_base := coalesce(nullif(pinka_finance.slugify(v_title), ''), 'kampanja');
  for i in 0..9 loop
    v_slug := case
      when i = 0 then v_base
      when i < 9 then left(v_base, 58) || '-' || (i + 1)::text
      else left(v_base, 51) || '-' || substr(md5(random()::text), 1, 8)
    end;
    begin
      insert into pinka_finance.campaigns (
        id, account_id, slug, type, title, description,
        goal_cents, min_contribution_cents, destination_address,
        subject_type, subject_ref, visibility,
        recurrence, recurrence_anchor_day,
        latitude, longitude, location_name,
        cover_image_url, starts_at, ends_at,
        state, metadata
      ) values (
        p_id, p_account_id, v_slug,
        p_type::pinka_finance.campaign_type, v_title, nullif(btrim(coalesce(p_description, '')), ''),
        p_goal_cents, p_min_contribution_cents, p_destination_address,
        p_subject_type, nullif(btrim(coalesce(p_subject_ref, '')), ''),
        p_visibility::pinka_finance.campaign_visibility,
        p_recurrence::pinka_finance.recurrence,
        case when p_recurrence = 'monthly' then p_recurrence_anchor_day else null end,
        p_latitude, p_longitude, nullif(btrim(coalesce(p_location_name, '')), ''),
        p_cover_image_url, p_starts_at, p_ends_at,
        'draft', v_meta
      );
      return jsonb_build_object('id', p_id, 'slug', v_slug, 'existing', false);
    exception when unique_violation then
      get stacked diagnostics v_constraint = CONSTRAINT_NAME;
      -- pkey sudar = tuđa kampanja s tim id-em (vlastitu smo vratili gore)
      if v_constraint = 'campaigns_pkey' then
        raise exception 'campaign_exists';
      end if;
      -- slug zauzet → sljedeći kandidat
    end;
  end loop;
  raise exception 'slug_collision';
end;
$$;

revoke execute on function pinka_finance.create_campaign(
  uuid, uuid, text, text, text, bigint, integer, text, text, text, text,
  text, integer, double precision, double precision, text, text,
  timestamptz, timestamptz, jsonb
) from public, anon;
grant execute on function pinka_finance.create_campaign(
  uuid, uuid, text, text, text, bigint, integer, text, text, text, text,
  text, integer, double precision, double precision, text, text,
  timestamptz, timestamptz, jsonb
) to authenticated, service_role;

-- ----- 5. storage: pinka-covers (cover slike kampanja) -----------------------
-- Public-read bucket; upload samo prijavljeni + KYC-verificirani korisnik i
-- isključivo u vlastiti folder ({auth.uid()}/...). Limit 5 MB, samo slike.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pinka-covers', 'pinka-covers', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/avif']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists pinka_covers_insert on storage.objects;
create policy pinka_covers_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'pinka-covers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.is_identity_verified()
  );

drop policy if exists pinka_covers_update on storage.objects;
create policy pinka_covers_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'pinka-covers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'pinka-covers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists pinka_covers_delete on storage.objects;
create policy pinka_covers_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'pinka-covers'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

select 'OK pinka_campaign_hardening' as status;
