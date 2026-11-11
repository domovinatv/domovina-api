-- =============================================================================
-- Postavke kanala za vlasnika (domovina.ai/postavke-kanala, S2)
--
-- Vlasnik ili suradnik s potvrđenim vlasništvom uključuje/isključuje 20
-- funkcionalnosti nad kanalom (ili cijeli kanal). Svaka promjena ide u
-- append-only log; trajno brisanje = zahtjev u aplikaciji + potvrda telefonom
-- + izvršenje skriptom, nakon čega ostaje trajni tombstone.
--
--   1. channel_slugs            slug kataloga → UC (kampanje pinke se vežu po slugu)
--   2. channel_settings         RIJETKO: samo ključevi koje je vlasnik postavio
--   3. channel_settings_events  append-only log (trigger odbija UPDATE/DELETE/TRUNCATE
--                               za SVE uloge, uključivo service_role i postgres)
--   4. channel_deletion_requests  requested → cancelled | phone_confirmed → executed
--   5. channel_tombstones       trajno (trigger odbija UPDATE/DELETE/TRUNCATE)
--   6. pomoćne funkcije (efektivno stanje, pisac/čitač po BAZI, ne po JWT-u)
--   7. RPC-ovi (set, brisanje, log)
--   8. javni viewovi public_channel_settings / public_channel_tombstones
--   9. novac: create_contribution (donations), create_sponsor_contribution i
--      izlog (paid_sponsor_moments), public_live_moments (samo tombstone)
--
-- Ključevi su ugovor (odluka 1) i ne preimenuju se. Efektivno stanje: odluka 108.
-- Pisac: verified claim, role primary|collaborator, verified_at unutar 90 dana
-- (odluka 3); KYC se NE traži (odluka 200). Novac: odluka 109.
-- Greške: poruka POČINJE kodom (klijent uspoređuje po prefiksu do ':'), P0001.
-- =============================================================================

-- ----- 1. channel_slugs ------------------------------------------------------
create table if not exists domovina_ai.channel_slugs (
  slug               text primary key,
  youtube_channel_id text not null check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  updated_at         timestamptz default now()
);

create index if not exists ix_channel_slugs_channel
  on domovina_ai.channel_slugs(youtube_channel_id);

insert into domovina_ai.channel_slugs (slug, youtube_channel_id)
values ('domovina_tv', 'UCXXhnehl2pss0uYdfLRDtyw')
on conflict do nothing;

comment on table domovina_ai.channel_slugs is
  'Slug kataloga → YouTube UC. Kampanje pinke (subject_type=podcast_channel) se na kanal vežu po slugu. Puni ga i katalog (S3).';

-- ----- 2. channel_settings ---------------------------------------------------
create table if not exists domovina_ai.channel_settings (
  youtube_channel_id text primary key check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  settings           jsonb not null default '{}'::jsonb check (jsonb_typeof(settings) = 'object'),
  updated_at         timestamptz not null default now()
);

comment on table domovina_ai.channel_settings is
  'RIJETKO: samo ključevi koje je vlasnik postavio (boolean). Ključ koji nedostaje = true. '
  'Efektivno stanje: domovina_ai.channel_effective_settings(uc). Piše samo set_channel_setting.';

-- ----- 3. channel_settings_events (append-only) ------------------------------
create table if not exists domovina_ai.channel_settings_events (
  id                 bigint generated always as identity primary key,
  youtube_channel_id text not null check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  kind               text not null check (kind in ('setting','deletion_requested','deletion_cancelled',
                                                   'deletion_phone_confirmed','deletion_executed')),
  key                text,
  old_value          boolean,
  new_value          boolean,
  account_id         uuid,          -- namjerno bez FK: brisanje korisnika ne smije dirati log
  role               text,
  source             text not null check (source in ('app','phone','system')),
  request_id         uuid,
  note               text,
  created_at         timestamptz not null default now(),
  constraint channel_settings_events_setting_key check (kind <> 'setting' or key is not null)
);

create index if not exists ix_channel_settings_events_channel
  on domovina_ai.channel_settings_events(youtube_channel_id, created_at desc);

comment on table domovina_ai.channel_settings_events is
  'Append-only log promjena postavki i koraka brisanja kanala. UPDATE/DELETE/TRUNCATE odbija trigger za sve uloge.';

create or replace function domovina_ai.tg_channel_settings_events_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'append_only: channel_settings_events se ne mijenja ni ne briše (%)', tg_op
    using errcode = 'P0001';
end;
$$;

drop trigger if exists trg_channel_settings_events_append_only on domovina_ai.channel_settings_events;
create trigger trg_channel_settings_events_append_only
  before update or delete on domovina_ai.channel_settings_events
  for each row execute function domovina_ai.tg_channel_settings_events_append_only();

drop trigger if exists trg_channel_settings_events_no_truncate on domovina_ai.channel_settings_events;
create trigger trg_channel_settings_events_no_truncate
  before truncate on domovina_ai.channel_settings_events
  for each statement execute function domovina_ai.tg_channel_settings_events_append_only();

-- ----- 4. channel_deletion_requests ------------------------------------------
create table if not exists domovina_ai.channel_deletion_requests (
  id                 uuid primary key default gen_random_uuid(),
  youtube_channel_id text not null check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  channel_title      text not null,   -- snimka naslova iz claima u trenutku zahtjeva
  requested_by       uuid not null,   -- bez FK, kao i log
  requested_role     text,
  state              text not null default 'requested'
                       check (state in ('requested','cancelled','phone_confirmed','executed')),
  requested_at       timestamptz not null default now(),
  cancelled_at       timestamptz,
  cancelled_by       uuid,
  phone_confirmed_at timestamptz,
  phone_note         text,
  executed_at        timestamptz
);

-- Jedan otvoren zahtjev po kanalu.
create unique index if not exists ux_channel_deletion_requests_open
  on domovina_ai.channel_deletion_requests(youtube_channel_id)
  where state in ('requested','phone_confirmed');

create index if not exists ix_channel_deletion_requests_channel
  on domovina_ai.channel_deletion_requests(youtube_channel_id, requested_at desc);

-- Prijelazi: requested → cancelled | phone_confirmed, phone_confirmed → executed.
-- Sve ostalo (i izmjena bez prijelaza, i izmjena završenog zahtjeva) pada.
create or replace function domovina_ai.tg_channel_deletion_requests_transition()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'invalid_transition: zahtjev za brisanje se ne briše' using errcode = 'P0001';
  end if;
  if new.id is distinct from old.id
     or new.youtube_channel_id is distinct from old.youtube_channel_id
     or new.requested_by is distinct from old.requested_by
     or new.requested_at is distinct from old.requested_at then
    raise exception 'invalid_transition: identitet zahtjeva se ne mijenja' using errcode = 'P0001';
  end if;
  if (old.state = 'requested' and new.state in ('cancelled','phone_confirmed'))
     or (old.state = 'phone_confirmed' and new.state = 'executed') then
    return new;
  end if;
  raise exception 'invalid_transition: % → %', old.state, new.state using errcode = 'P0001';
end;
$$;

drop trigger if exists trg_channel_deletion_requests_transition on domovina_ai.channel_deletion_requests;
create trigger trg_channel_deletion_requests_transition
  before update or delete on domovina_ai.channel_deletion_requests
  for each row execute function domovina_ai.tg_channel_deletion_requests_transition();

-- ----- 5. channel_tombstones (trajno) ----------------------------------------
create table if not exists domovina_ai.channel_tombstones (
  youtube_channel_id text primary key check (youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$'),
  channel_title      text,
  slugs              text[] not null default '{}',
  request_id         uuid,
  requested_at       timestamptz,
  phone_confirmed_at timestamptz,
  deleted_at         timestamptz not null default now()
);

create index if not exists ix_channel_tombstones_slugs
  on domovina_ai.channel_tombstones using gin (slugs);

comment on table domovina_ai.channel_tombstones is
  'Trajni zapis obrisanog kanala. Katalog ga nikad više ne uvrštava. UPDATE/DELETE/TRUNCATE odbija trigger za sve uloge.';

create or replace function domovina_ai.tg_channel_tombstones_permanent()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'tombstone_permanent: channel_tombstones se ne mijenja ni ne briše (%)', tg_op
    using errcode = 'P0001';
end;
$$;

drop trigger if exists trg_channel_tombstones_permanent on domovina_ai.channel_tombstones;
create trigger trg_channel_tombstones_permanent
  before update or delete on domovina_ai.channel_tombstones
  for each row execute function domovina_ai.tg_channel_tombstones_permanent();

drop trigger if exists trg_channel_tombstones_no_truncate on domovina_ai.channel_tombstones;
create trigger trg_channel_tombstones_no_truncate
  before truncate on domovina_ai.channel_tombstones
  for each statement execute function domovina_ai.tg_channel_tombstones_permanent();

-- ----- 6. pomoćne funkcije ---------------------------------------------------
-- Redoslijed je ugovor (odluka 1).
create or replace function domovina_ai.channel_setting_keys()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select array[
    'channel_enabled', 'processing', 'home_featured', 'in_app_search', 'search_engines',
    'push_notifications', 'cdn_playback', 'share_clips', 'ebook',
    'article_summary', 'transcript_subtitles', 'english_translation', 'magisterium',
    'highlights_reels', 'persons_mentions', 'news_portal', 'ai_assistants',
    'donations', 'paid_sponsor_moments', 'sponsors_in_video'
  ]::text[];
$$;

-- Svih 20 ključeva s efektivnim booleanima (odluka 108):
--   tombstone ili channel_enabled=false → sve false
--   transcript_subtitles=false → AI skupina false (pa tranzitivno ebook, share_clips)
--   article_summary=false → ebook, magisterium, english_translation, share_clips, news_portal
--   nepoznat UC / nema retka → sve true
create or replace function domovina_ai.channel_effective_settings(p_youtube_channel_id text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_keys constant text[] := domovina_ai.channel_setting_keys();
  v_ai   constant text[] := array['article_summary','transcript_subtitles','english_translation',
                                  'magisterium','highlights_reels','persons_mentions',
                                  'news_portal','ai_assistants'];
  v_raw  jsonb;
  v_res  jsonb := '{}'::jsonb;
  v_k    text;
begin
  if exists (select 1 from domovina_ai.channel_tombstones t
              where t.youtube_channel_id = p_youtube_channel_id) then
    select jsonb_object_agg(k, false) into v_res from unnest(v_keys) k;
    return v_res;
  end if;

  select s.settings into v_raw from domovina_ai.channel_settings s
   where s.youtube_channel_id = p_youtube_channel_id;
  v_raw := coalesce(v_raw, '{}'::jsonb);

  foreach v_k in array v_keys loop
    v_res := v_res || jsonb_build_object(
      v_k, coalesce(case when jsonb_typeof(v_raw -> v_k) = 'boolean'
                         then (v_raw ->> v_k)::boolean end, true));
  end loop;

  if not (v_res ->> 'channel_enabled')::boolean then
    select jsonb_object_agg(k, false) into v_res from unnest(v_keys) k;
    return v_res;
  end if;

  if not (v_res ->> 'transcript_subtitles')::boolean then
    foreach v_k in array v_ai loop
      v_res := v_res || jsonb_build_object(v_k, false);
    end loop;
  end if;

  if not (v_res ->> 'article_summary')::boolean then
    v_res := v_res || jsonb_build_object(
      'ebook', false, 'magisterium', false, 'english_translation', false,
      'share_clips', false, 'news_portal', false);
  end if;

  return v_res;
end;
$$;

create or replace function domovina_ai.channel_setting_enabled(p_youtube_channel_id text, p_key text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p_key is null or not (p_key = any (domovina_ai.channel_setting_keys())) then
    raise exception 'unknown_key: %', coalesce(p_key, '<null>') using errcode = 'P0001';
  end if;
  return (domovina_ai.channel_effective_settings(p_youtube_channel_id) ->> p_key)::boolean;
end;
$$;

-- Nepoznat slug → true. Slug koji više nije u channel_slugs, a pamti ga
-- tombstone, i dalje vodi na obrisani kanal (→ false).
create or replace function domovina_ai.channel_setting_enabled_by_slug(p_slug text, p_key text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v_uc text;
begin
  if p_key is null or not (p_key = any (domovina_ai.channel_setting_keys())) then
    raise exception 'unknown_key: %', coalesce(p_key, '<null>') using errcode = 'P0001';
  end if;
  select cs.youtube_channel_id into v_uc from domovina_ai.channel_slugs cs where cs.slug = p_slug;
  if v_uc is null then
    select t.youtube_channel_id into v_uc from domovina_ai.channel_tombstones t
     where p_slug = any (t.slugs) limit 1;
  end if;
  if v_uc is null then return true; end if;
  return domovina_ai.channel_setting_enabled(v_uc, p_key);
end;
$$;

-- Pisac: verified claim, primary|collaborator, potvrđen unutar 90 dana.
-- Čita BAZU (odluka 3) — JWT claim bi mogao biti zastario.
create or replace function domovina_ai.is_channel_settings_writer(p_youtube_channel_id text, p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from domovina_ai.channel_claims cc
     where cc.account_id = p_user
       and cc.youtube_channel_id = p_youtube_channel_id
       and cc.status = 'verified'
       and cc.role in ('primary','collaborator')
       and cc.verified_at > now() - interval '90 days');
$$;

-- Čitač loga: isto, ali bilo koje starosti potvrde.
create or replace function domovina_ai.is_channel_settings_reader(p_youtube_channel_id text, p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from domovina_ai.channel_claims cc
     where cc.account_id = p_user
       and cc.youtube_channel_id = p_youtube_channel_id
       and cc.status = 'verified'
       and cc.role in ('primary','collaborator'));
$$;

-- ----- 7. RPC-ovi -------------------------------------------------------------
create or replace function domovina_ai.set_channel_setting(
  p_youtube_channel_id text,
  p_key                text,
  p_value              boolean
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_role     text;
  v_settings jsonb;
  v_old      boolean;
begin
  if v_uid is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  if p_key is null or not (p_key = any (domovina_ai.channel_setting_keys())) then
    raise exception 'unknown_key: %', coalesce(p_key, '<null>') using errcode = 'P0001';
  end if;
  if p_value is null then raise exception 'invalid_value: vrijednost mora biti true ili false' using errcode = 'P0001'; end if;
  if exists (select 1 from domovina_ai.channel_tombstones t
              where t.youtube_channel_id = p_youtube_channel_id) then
    raise exception 'channel_deleted' using errcode = 'P0001';
  end if;

  select cc.role into v_role from domovina_ai.channel_claims cc
   where cc.account_id = v_uid
     and cc.youtube_channel_id = p_youtube_channel_id
     and cc.status = 'verified'
     and cc.role in ('primary','collaborator')
     and cc.verified_at > now() - interval '90 days';
  if not found then raise exception 'not_owner' using errcode = 'P0001'; end if;

  -- Serijalizira istovremene promjene istog kanala (i prvi upis, kad redak još ne postoji).
  perform pg_advisory_xact_lock(hashtextextended('domovina_ai.channel_settings:' || p_youtube_channel_id, 0));

  select s.settings into v_settings from domovina_ai.channel_settings s
   where s.youtube_channel_id = p_youtube_channel_id;
  v_old := coalesce(case when jsonb_typeof(v_settings -> p_key) = 'boolean'
                         then (v_settings ->> p_key)::boolean end, true);

  if v_old = p_value then
    return domovina_ai.channel_effective_settings(p_youtube_channel_id);
  end if;

  insert into domovina_ai.channel_settings as s (youtube_channel_id, settings, updated_at)
  values (p_youtube_channel_id, jsonb_build_object(p_key, p_value), now())
  on conflict (youtube_channel_id) do update
     set settings   = jsonb_set(s.settings, array[p_key], to_jsonb(p_value), true),
         updated_at = now();

  insert into domovina_ai.channel_settings_events (
    youtube_channel_id, kind, key, old_value, new_value, account_id, role, source)
  values (p_youtube_channel_id, 'setting', p_key, v_old, p_value, v_uid, v_role, 'app');

  return domovina_ai.channel_effective_settings(p_youtube_channel_id);
end;
$$;

create or replace function domovina_ai.request_channel_deletion(
  p_youtube_channel_id text,
  p_confirm_name       text
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_role  text;
  v_title text;
  v_id    uuid;
begin
  if v_uid is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  if exists (select 1 from domovina_ai.channel_tombstones t
              where t.youtube_channel_id = p_youtube_channel_id) then
    raise exception 'channel_deleted' using errcode = 'P0001';
  end if;

  select cc.role, nullif(btrim(cc.channel_title), '') into v_role, v_title
    from domovina_ai.channel_claims cc
   where cc.account_id = v_uid
     and cc.youtube_channel_id = p_youtube_channel_id
     and cc.status = 'verified'
     and cc.role in ('primary','collaborator')
     and cc.verified_at > now() - interval '90 days';
  if not found then raise exception 'not_owner' using errcode = 'P0001'; end if;

  if v_title is null or btrim(coalesce(p_confirm_name, '')) is distinct from v_title then
    raise exception 'confirm_name_mismatch' using errcode = 'P0001';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('domovina_ai.channel_settings:' || p_youtube_channel_id, 0));

  if exists (select 1 from domovina_ai.channel_deletion_requests r
              where r.youtube_channel_id = p_youtube_channel_id
                and r.state in ('requested','phone_confirmed')) then
    raise exception 'deletion_already_requested' using errcode = 'P0001';
  end if;

  insert into domovina_ai.channel_deletion_requests (
    youtube_channel_id, channel_title, requested_by, requested_role, state, requested_at)
  values (p_youtube_channel_id, v_title, v_uid, v_role, 'requested', now())
  returning id into v_id;

  insert into domovina_ai.channel_settings_events (
    youtube_channel_id, kind, account_id, role, source, request_id)
  values (p_youtube_channel_id, 'deletion_requested', v_uid, v_role, 'app', v_id);

  return v_id;
exception
  when unique_violation then
    raise exception 'deletion_already_requested' using errcode = 'P0001';
end;
$$;

-- Otkazuje bilo koji pisac kanala, ne nužno onaj koji je tražio. Samo iz 'requested'.
create or replace function domovina_ai.cancel_channel_deletion(p_youtube_channel_id text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_role text;
  v_id   uuid;
begin
  if v_uid is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  if exists (select 1 from domovina_ai.channel_tombstones t
              where t.youtube_channel_id = p_youtube_channel_id) then
    raise exception 'channel_deleted' using errcode = 'P0001';
  end if;

  select cc.role into v_role from domovina_ai.channel_claims cc
   where cc.account_id = v_uid
     and cc.youtube_channel_id = p_youtube_channel_id
     and cc.status = 'verified'
     and cc.role in ('primary','collaborator')
     and cc.verified_at > now() - interval '90 days';
  if not found then raise exception 'not_owner' using errcode = 'P0001'; end if;

  select r.id into v_id from domovina_ai.channel_deletion_requests r
   where r.youtube_channel_id = p_youtube_channel_id and r.state = 'requested'
   for update;
  if not found then raise exception 'no_open_request' using errcode = 'P0001'; end if;

  update domovina_ai.channel_deletion_requests
     set state = 'cancelled', cancelled_at = now(), cancelled_by = v_uid
   where id = v_id;

  insert into domovina_ai.channel_settings_events (
    youtube_channel_id, kind, account_id, role, source, request_id)
  values (p_youtube_channel_id, 'deletion_cancelled', v_uid, v_role, 'app', v_id);

  return v_id;
end;
$$;

-- Poziv na +385 98 967 9022 potvrđen. SAMO service_role.
create or replace function domovina_ai.confirm_channel_deletion_by_phone(p_request_id uuid, p_note text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_req domovina_ai.channel_deletion_requests;
begin
  select * into v_req from domovina_ai.channel_deletion_requests r
   where r.id = p_request_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if v_req.state <> 'requested' then
    raise exception 'invalid_state: %', v_req.state using errcode = 'P0001';
  end if;

  update domovina_ai.channel_deletion_requests
     set state = 'phone_confirmed', phone_confirmed_at = now(),
         phone_note = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_request_id;

  insert into domovina_ai.channel_settings_events (
    youtube_channel_id, kind, source, request_id, note)
  values (v_req.youtube_channel_id, 'deletion_phone_confirmed', 'phone', p_request_id,
          nullif(btrim(coalesce(p_note, '')), ''));
end;
$$;

-- Zove ga skripta brisanja (S9) nakon što je sadržaj uklonjen. SAMO service_role.
-- Slugovi tombstonea = p_slugs ∪ slugovi kanala iz channel_slugs.
create or replace function domovina_ai.mark_channel_deletion_executed(p_request_id uuid, p_slugs text[])
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_req   domovina_ai.channel_deletion_requests;
  v_slugs text[];
begin
  select * into v_req from domovina_ai.channel_deletion_requests r
   where r.id = p_request_id for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if v_req.state <> 'phone_confirmed' then
    raise exception 'invalid_state: %', v_req.state using errcode = 'P0001';
  end if;

  select coalesce(array_agg(distinct s order by s), '{}') into v_slugs
    from (
      select unnest(coalesce(p_slugs, '{}'::text[])) as s
      union
      select cs.slug from domovina_ai.channel_slugs cs
       where cs.youtube_channel_id = v_req.youtube_channel_id
    ) x
   where nullif(btrim(s), '') is not null;

  update domovina_ai.channel_deletion_requests
     set state = 'executed', executed_at = now()
   where id = p_request_id;

  insert into domovina_ai.channel_tombstones (
    youtube_channel_id, channel_title, slugs, request_id, requested_at, phone_confirmed_at, deleted_at)
  values (v_req.youtube_channel_id, v_req.channel_title, v_slugs, v_req.id,
          v_req.requested_at, v_req.phone_confirmed_at, now())
  on conflict (youtube_channel_id) do nothing;

  insert into domovina_ai.channel_settings_events (
    youtube_channel_id, kind, source, request_id)
  values (v_req.youtube_channel_id, 'deletion_executed', 'system', p_request_id);
end;
$$;

-- Log od najnovijeg; paginacija po id-u (p_before = id zadnjeg viđenog).
create or replace function domovina_ai.get_channel_settings_log(
  p_youtube_channel_id text,
  p_limit              integer default 100,
  p_before             bigint  default null
) returns setof domovina_ai.channel_settings_events
language plpgsql stable security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'login_required' using errcode = 'P0001'; end if;
  if not domovina_ai.is_channel_settings_reader(p_youtube_channel_id, v_uid) then
    raise exception 'not_owner' using errcode = 'P0001';
  end if;

  return query
    select e.* from domovina_ai.channel_settings_events e
     where e.youtube_channel_id = p_youtube_channel_id
       and (p_before is null or e.id < p_before)
     order by e.id desc
     limit least(greatest(coalesce(p_limit, 100), 1), 500);
end;
$$;

-- ----- RLS + grantovi tablica ----------------------------------------------
-- Zadane privilegije sheme domovina_ai daju authenticated arwd i anon r na
-- svaku novu tablicu — zato prvo revoke all, pa izričito ono što treba.
alter table domovina_ai.channel_slugs             enable row level security;
alter table domovina_ai.channel_settings          enable row level security;
alter table domovina_ai.channel_settings_events   enable row level security;
alter table domovina_ai.channel_deletion_requests enable row level security;
alter table domovina_ai.channel_tombstones        enable row level security;

revoke all on domovina_ai.channel_slugs             from public, anon, authenticated;
revoke all on domovina_ai.channel_settings          from public, anon, authenticated;
revoke all on domovina_ai.channel_settings_events   from public, anon, authenticated;
revoke all on domovina_ai.channel_deletion_requests from public, anon, authenticated;
revoke all on domovina_ai.channel_tombstones        from public, anon, authenticated;
revoke all on sequence domovina_ai.channel_settings_events_id_seq from public, anon, authenticated;

-- slug → UC je javan podatak (katalog ga ionako objavljuje).
grant select on domovina_ai.channel_slugs to anon, authenticated;
drop policy if exists channel_slugs_select_all on domovina_ai.channel_slugs;
create policy channel_slugs_select_all on domovina_ai.channel_slugs
  for select to anon, authenticated using (true);

-- Log i zahtjeve za brisanje čitaju samo čitači tog kanala. Pisanja nema.
grant select on domovina_ai.channel_settings_events to authenticated;
drop policy if exists channel_settings_events_select_reader on domovina_ai.channel_settings_events;
create policy channel_settings_events_select_reader on domovina_ai.channel_settings_events
  for select to authenticated
  using (domovina_ai.is_channel_settings_reader(youtube_channel_id, (select auth.uid())));

grant select on domovina_ai.channel_deletion_requests to authenticated;
drop policy if exists channel_deletion_requests_select_reader on domovina_ai.channel_deletion_requests;
create policy channel_deletion_requests_select_reader on domovina_ai.channel_deletion_requests
  for select to authenticated
  using (domovina_ai.is_channel_settings_reader(youtube_channel_id, (select auth.uid())));

-- channel_settings i channel_tombstones: bez policyja; javno samo kroz viewove.

grant all on domovina_ai.channel_slugs             to service_role;
grant all on domovina_ai.channel_settings          to service_role;
grant all on domovina_ai.channel_settings_events   to service_role;
grant all on domovina_ai.channel_deletion_requests to service_role;
grant all on domovina_ai.channel_tombstones        to service_role;
grant usage, select on sequence domovina_ai.channel_settings_events_id_seq to service_role;

-- ----- grantovi funkcija -----------------------------------------------------
revoke execute on function domovina_ai.tg_channel_settings_events_append_only() from public, anon, authenticated;
revoke execute on function domovina_ai.tg_channel_deletion_requests_transition() from public, anon, authenticated;
revoke execute on function domovina_ai.tg_channel_tombstones_permanent() from public, anon, authenticated;

revoke execute on function domovina_ai.channel_setting_keys() from public;
revoke execute on function domovina_ai.channel_effective_settings(text) from public;
revoke execute on function domovina_ai.channel_setting_enabled(text,text) from public;
revoke execute on function domovina_ai.channel_setting_enabled_by_slug(text,text) from public;
grant  execute on function domovina_ai.channel_setting_keys() to anon, authenticated, service_role;
grant  execute on function domovina_ai.channel_effective_settings(text) to anon, authenticated, service_role;
grant  execute on function domovina_ai.channel_setting_enabled(text,text) to anon, authenticated, service_role;
grant  execute on function domovina_ai.channel_setting_enabled_by_slug(text,text) to anon, authenticated, service_role;

-- authenticated mora imati EXECUTE jer ih zovu RLS policyji.
revoke execute on function domovina_ai.is_channel_settings_writer(text,uuid) from public, anon;
revoke execute on function domovina_ai.is_channel_settings_reader(text,uuid) from public, anon;
grant  execute on function domovina_ai.is_channel_settings_writer(text,uuid) to authenticated, service_role;
grant  execute on function domovina_ai.is_channel_settings_reader(text,uuid) to authenticated, service_role;

revoke execute on function domovina_ai.set_channel_setting(text,text,boolean) from public, anon, service_role;
revoke execute on function domovina_ai.request_channel_deletion(text,text) from public, anon, service_role;
revoke execute on function domovina_ai.cancel_channel_deletion(text) from public, anon, service_role;
revoke execute on function domovina_ai.get_channel_settings_log(text,integer,bigint) from public, anon, service_role;
grant  execute on function domovina_ai.set_channel_setting(text,text,boolean) to authenticated;
grant  execute on function domovina_ai.request_channel_deletion(text,text) to authenticated;
grant  execute on function domovina_ai.cancel_channel_deletion(text) to authenticated;
grant  execute on function domovina_ai.get_channel_settings_log(text,integer,bigint) to authenticated;

revoke execute on function domovina_ai.confirm_channel_deletion_by_phone(uuid,text) from public, anon, authenticated;
revoke execute on function domovina_ai.mark_channel_deletion_executed(uuid,text[]) from public, anon, authenticated;
grant  execute on function domovina_ai.confirm_channel_deletion_by_phone(uuid,text) to service_role;
grant  execute on function domovina_ai.mark_channel_deletion_executed(uuid,text[]) to service_role;

-- ----- 8. javni viewovi -------------------------------------------------------
-- S3 poller čita po kursoru updated_at. Tombstone: updated_at = deleted_at.
create or replace view domovina_ai.public_channel_settings as
  with ucs as (
    select s.youtube_channel_id from domovina_ai.channel_settings s
    union
    select t.youtube_channel_id from domovina_ai.channel_tombstones t
  )
  select
    u.youtube_channel_id,
    coalesce(s.settings, '{}'::jsonb)                         as settings,
    domovina_ai.channel_effective_settings(u.youtube_channel_id) as effective,
    coalesce(t.deleted_at, s.updated_at)                      as updated_at,
    (t.youtube_channel_id is not null)                        as tombstoned
  from ucs u
  left join domovina_ai.channel_settings   s on s.youtube_channel_id = u.youtube_channel_id
  left join domovina_ai.channel_tombstones t on t.youtube_channel_id = u.youtube_channel_id;

alter view domovina_ai.public_channel_settings set (security_invoker = off);
revoke all on domovina_ai.public_channel_settings from public, anon, authenticated;
grant select on domovina_ai.public_channel_settings to anon, authenticated, service_role;

create or replace view domovina_ai.public_channel_tombstones as
  select t.youtube_channel_id, t.channel_title, t.slugs,
         t.requested_at, t.phone_confirmed_at, t.deleted_at
    from domovina_ai.channel_tombstones t;

alter view domovina_ai.public_channel_tombstones set (security_invoker = off);
revoke all on domovina_ai.public_channel_tombstones from public, anon, authenticated;
grant select on domovina_ai.public_channel_tombstones to anon, authenticated, service_role;

-- ----- 9. novac (odluka 109) --------------------------------------------------
-- Kampanja → UC kanala, na JEDNOM mjestu:
--   podcast_channel → channel_slugs(slug = subject_ref), pa slug iz tombstonea
--   podcast_episode → episode_safes(episode_id = subject_ref)
--   inače / bez mapiranja → campaigns.youtube_channel_id (sidro vlasništva), pa null
-- null = kanal nepoznat → provjera prekidača dopušta (ništa se ne blokira naslijepo).
create or replace function pinka_finance.campaign_channel_uc(p_campaign_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_c  pinka_finance.campaigns;
  v_uc text;
begin
  select * into v_c from pinka_finance.campaigns where id = p_campaign_id;
  if not found then return null; end if;

  if v_c.subject_type = 'podcast_channel' and v_c.subject_ref is not null then
    select cs.youtube_channel_id into v_uc from domovina_ai.channel_slugs cs
     where cs.slug = v_c.subject_ref;
    if v_uc is null then
      select t.youtube_channel_id into v_uc from domovina_ai.channel_tombstones t
       where v_c.subject_ref = any (t.slugs) limit 1;
    end if;
  elsif v_c.subject_type = 'podcast_episode' and v_c.subject_ref is not null then
    select es.youtube_channel_id into v_uc from domovina_ai.episode_safes es
     where es.episode_id = v_c.subject_ref;
  end if;

  return coalesce(v_uc, v_c.youtube_channel_id);
end;
$$;

-- true = prekidač kanala dopušta. Kanal nepoznat → true.
create or replace function pinka_finance.campaign_channel_setting_enabled(p_campaign_id uuid, p_key text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare v_uc text := pinka_finance.campaign_channel_uc(p_campaign_id);
begin
  if v_uc is null then
    -- i dalje validira ključ
    perform domovina_ai.channel_setting_enabled(null, p_key);
    return true;
  end if;
  return domovina_ai.channel_setting_enabled(v_uc, p_key);
end;
$$;

-- Kampanja sponzorskih trenutaka = ima timeline kartu (isto pravilo kao
-- 'not_sponsor_campaign' u create_sponsor_contribution).
create or replace function pinka_finance.campaign_is_sponsor_moments(p_campaign_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from pinka_finance.slot_maps m
                  where m.campaign_id = p_campaign_id and m.kind::text = 'timeline');
$$;

revoke execute on function pinka_finance.campaign_channel_uc(uuid) from public, anon, authenticated;
revoke execute on function pinka_finance.campaign_channel_setting_enabled(uuid,text) from public, anon, authenticated;
revoke execute on function pinka_finance.campaign_is_sponsor_moments(uuid) from public, anon, authenticated;
-- anon i authenticated MORAJU imati EXECUTE: public_sponsor_moments i public_live_moments
-- (security_invoker=off) ih zovu, a EXECUTE funkcije u pogledu Postgres provjerava nad
-- ulogom koja čita pogled. Bez ovoga izlog i „Sponzorirano” padaju svima (uhvatio S2 test).
-- Obje su security definer i vraćaju samo UC ili boolean.
grant  execute on function pinka_finance.campaign_channel_uc(uuid) to anon, authenticated, service_role;
grant  execute on function pinka_finance.campaign_channel_setting_enabled(uuid,text) to anon, authenticated, service_role;
grant  execute on function pinka_finance.campaign_is_sponsor_moments(uuid) to service_role;

-- create_contribution: tijelo TOČNO iz 20260722120000_pinka_slots.sql (§12),
-- jedina razlika je provjera prekidača na početku. Gostujuća grana
-- pinka-contribute (20261007130000) zove ISTU funkciju service klijentom, pa
-- je pokrivena. Kampanja s timeline kartom (sponzorski crowdfund) se ravna po
-- paid_sponsor_moments, ne po donations.
create or replace function pinka_finance.create_contribution(
  p_campaign_id  uuid,
  p_amount_cents bigint,
  p_tier_id      uuid    default null,
  p_display_name text    default null,
  p_message      text    default null,
  p_anonymous    boolean default false,
  p_quantity     integer default 1,
  p_slot_keys    text[]  default null
) returns table (
  contribution_id     uuid,
  amount_cents        bigint,
  currency            text,
  destination_address text,
  slot_keys           text[],
  hold_expires_at     timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
  v_tier     pinka_finance.campaign_tiers;
  v_account  uuid;
  v_verified boolean := false;
  v_display_ok boolean := false;
  v_qty      integer := greatest(coalesce(p_quantity, 1), 1);
  v_name     text := nullif(btrim(p_display_name), '');
  v_id       uuid;
  v_hold     timestamptz;
begin
  -- Postavke kanala (20261111120000): vlasnik je isključio donacije / trenutke.
  if pinka_finance.campaign_is_sponsor_moments(p_campaign_id) then
    if not pinka_finance.campaign_channel_setting_enabled(p_campaign_id, 'paid_sponsor_moments') then
      raise exception 'sponsor_moments_disabled' using errcode = 'P0001';
    end if;
  elsif not pinka_finance.campaign_channel_setting_enabled(p_campaign_id, 'donations') then
    raise exception 'donations_disabled' using errcode = 'P0001';
  end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  if p_amount_cents is null
     or p_amount_cents < greatest(v_campaign.min_contribution_cents, 1) then
    raise exception 'amount_below_minimum';
  end if;

  if p_tier_id is not null then
    select * into v_tier from pinka_finance.campaign_tiers
      where id = p_tier_id and campaign_id = p_campaign_id;
    if not found then raise exception 'tier_not_found'; end if;
    if v_tier.inventory_total is not null
       and v_tier.inventory_claimed + v_qty > v_tier.inventory_total then
      raise exception 'tier_sold_out';
    end if;
  end if;

  select id into v_account from public.accounts
    where primary_owner_user_id = (select auth.uid())
      and is_personal_account = true
      and deleted_at is null
    limit 1;

  if (select auth.uid()) is not null then
    select exists(
      select 1 from public.identity_verifications iv
       where iv.user_id = (select auth.uid())
    ) into v_verified;
  end if;

  v_display_ok := pinka_finance.display_name_matches_identity(v_account, v_name);

  insert into pinka_finance.contributions (
    campaign_id, tier_id, contributor_account_id,
    amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message,
    contributor_verified, display_name_verified
  ) values (
    p_campaign_id, p_tier_id, v_account,
    p_amount_cents, v_campaign.currency, v_qty, 'pending',
    v_campaign.destination_address, coalesce(p_anonymous, false),
    v_name, nullif(btrim(p_message), ''),
    coalesce(v_verified, false), coalesce(v_display_ok, false)
  ) returning id into v_id;

  -- Rezervacija u ISTOJ transakciji. Ako padne, cijeli doprinos nestaje.
  if p_slot_keys is not null and array_length(p_slot_keys, 1) > 0 then
    perform pinka_finance.reserve_slots(v_id, p_slot_keys, null);
    select min(s.hold_expires_at) into v_hold
      from pinka_finance.slots s where s.contribution_id = v_id;
  end if;

  return query
    select v_id, p_amount_cents, v_campaign.currency, v_campaign.destination_address,
           p_slot_keys, v_hold;
end;
$$;
revoke execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer,text[])
  from public, anon;
grant  execute on function pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer,text[])
  to authenticated, service_role;

-- create_sponsor_contribution: tijelo TOČNO iz 20261007120000_sponzorski_trenuci.sql
-- (§5), jedina razlika je provjera prekidača na početku.
create or replace function pinka_finance.create_sponsor_contribution(
  p_campaign_id    uuid,
  p_slot_keys      text[],
  p_brand          text,
  p_tagline        text,
  p_link_url       text,
  p_logo_path      text,
  p_buyer          jsonb,
  p_terms_accepted boolean
) returns table (
  contribution_id     uuid,
  amount_cents        bigint,
  currency            text,
  destination_address text,
  slot_keys           text[],
  hold_expires_at     timestamptz
)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_campaign pinka_finance.campaigns;
  v_map      pinka_finance.slot_maps;
  v_keys     text[];
  v_n_found  integer;
  v_total    bigint;
  v_account  uuid;
  v_brand    text := pinka_finance.sanitize_ugc(p_brand);
  v_tagline  text := pinka_finance.sanitize_ugc(p_tagline);
  v_link     text := nullif(btrim(coalesce(p_link_url, '')), '');
  v_logo     text := nullif(btrim(coalesce(p_logo_path, '')), '');
  v_company  text := pinka_finance.sanitize_ugc(p_buyer->>'company');
  v_oib      text := nullif(regexp_replace(coalesce(p_buyer->>'oib', ''), '\s', '', 'g'), '');
  v_vat      text := nullif(upper(regexp_replace(coalesce(p_buyer->>'vat_id', ''), '\s', '', 'g')), '');
  v_email    text := nullif(lower(btrim(coalesce(p_buyer->>'email', ''))), '');
  v_ref      text := pinka_finance.sanitize_ugc(p_buyer->>'reference');
  v_addr     jsonb;
  v_country  text;
  v_id       uuid;
  v_hold     timestamptz;
begin
  -- Postavke kanala (20261111120000): vlasnik je isključio plaćene trenutke.
  if not pinka_finance.campaign_channel_setting_enabled(p_campaign_id, 'paid_sponsor_moments') then
    raise exception 'sponsor_moments_disabled' using errcode = 'P0001';
  end if;

  if v_uid is null then raise exception 'not_authenticated'; end if;
  -- Sponzor mora imati PRAVI račun (Google/Apple/e-pošta): provjerena e-pošta
  -- za B2B i limit holdova po stvarnoj osobi, ne po besplatnoj anonimnoj sesiji
  -- (P9). Anonimne prijave se gase — docs/sponzorski-trenuci-zakljucak.md §7.
  if coalesce(((select auth.jwt()) ->> 'is_anonymous')::boolean, false) then
    raise exception 'login_required';
  end if;

  select * into v_campaign from pinka_finance.campaigns
   where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.state <> 'active' then raise exception 'campaign_not_active'; end if;

  select * into v_map from pinka_finance.slot_maps where campaign_id = p_campaign_id;
  if not found or v_map.kind::text <> 'timeline' then raise exception 'not_sponsor_campaign'; end if;

  -- ── validacija kreative ──
  if coalesce(p_terms_accepted, false) is not true then raise exception 'invalid_sponsor:terms'; end if;
  if v_brand is null or char_length(v_brand) > 60 then raise exception 'invalid_sponsor:brand'; end if;
  if v_tagline is not null and char_length(v_tagline) > 120 then raise exception 'invalid_sponsor:tagline'; end if;
  if v_link is not null and (char_length(v_link) > 500 or v_link !~ '^https://[^\s/?#]+\.[^\s]*$') then
    raise exception 'invalid_sponsor:link_url';
  end if;
  if v_logo is not null then
    -- Samo vlastita mapa i samo stvarno uploadan objekt unutar limita. Bucket
    -- limit (204800 B, MIME) vrijedi pri uploadu; ovo je druga linija.
    if v_logo !~ ('^' || v_uid::text || '/[A-Za-z0-9_-]{1,64}\.(png|jpe?g|webp)$')
       or not exists (
         select 1 from storage.objects o
          where o.bucket_id = 'sponsor-logos' and o.name = v_logo
            and coalesce((o.metadata->>'size')::bigint, 0) between 1 and 204800
            and coalesce(o.metadata->>'mimetype', '') in ('image/png','image/jpeg','image/webp'))
    then
      raise exception 'invalid_sponsor:logo_path';
    end if;
  end if;

  -- ── validacija kupca ──
  if v_company is null or char_length(v_company) > 200 then raise exception 'invalid_sponsor:buyer_company'; end if;
  if v_oib is not null and not pinka_finance.oib_valid(v_oib) then raise exception 'invalid_sponsor:buyer_oib'; end if;
  if v_vat is not null and v_vat !~ '^[A-Z]{2}[A-Z0-9]{2,13}$' then raise exception 'invalid_sponsor:buyer_vat_id'; end if;
  if v_email is null or char_length(v_email) > 200 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_sponsor:buyer_email';
  end if;
  if v_ref is not null and char_length(v_ref) > 100 then raise exception 'invalid_sponsor:buyer_reference'; end if;

  if p_buyer ? 'address' and jsonb_typeof(p_buyer->'address') = 'object' then
    v_country := upper(coalesce(nullif(btrim(p_buyer->'address'->>'country'), ''), 'HR'));
    if v_country !~ '^[A-Z]{2}$' then raise exception 'invalid_sponsor:buyer_address'; end if;
    v_addr := jsonb_strip_nulls(jsonb_build_object(
      'street',      pinka_finance.sanitize_ugc(p_buyer->'address'->>'street'),
      'city',        pinka_finance.sanitize_ugc(p_buyer->'address'->>'city'),
      'postal_code', pinka_finance.sanitize_ugc(p_buyer->'address'->>'postal_code'),
      'country',     v_country));
    if char_length(coalesce(v_addr->>'street', '')) > 200
       or char_length(coalesce(v_addr->>'city', '')) > 100
       or char_length(coalesce(v_addr->>'postal_code', '')) > 16 then
      raise exception 'invalid_sponsor:buyer_address';
    end if;
  end if;

  -- ── trenuci ──
  select array_agg(distinct k) into v_keys from unnest(p_slot_keys) k where k is not null;
  if v_keys is null or array_length(v_keys, 1) not between 1 and 3 then
    raise exception 'invalid_slot_keys';
  end if;

  -- Istekli zakupi u 'free' PRIJE rezervacije — inače bi istekao trenutak bio
  -- neprodajan dok ga cron ne počisti (ugovor O6).
  perform pinka_finance.expire_live_slots();

  select count(*), sum(z.price_cents) into v_n_found, v_total
    from pinka_finance.slots s
    join pinka_finance.slot_zones z on z.id = s.zone_id
   where s.map_id = v_map.id and s.slot_key = any (v_keys);
  if v_n_found <> array_length(v_keys, 1) then raise exception 'invalid_slot_keys'; end if;

  select id into v_account from public.accounts
   where primary_owner_user_id = v_uid and is_personal_account = true and deleted_at is null
   limit 1;

  insert into pinka_finance.contributions (
    campaign_id, contributor_account_id, amount_cents, currency, quantity, state,
    destination_address, anonymous, display_name, message,
    is_sponsor, link_url, logo_path,
    buyer_company, buyer_oib, buyer_vat_id, buyer_email, buyer_address, buyer_reference,
    terms_accepted_at
  ) values (
    p_campaign_id, v_account, v_total, v_campaign.currency, 1, 'pending',
    v_campaign.destination_address, false, v_brand, v_tagline,
    true, v_link, v_logo,
    v_company, v_oib, v_vat, v_email, v_addr, v_ref,
    now()
  ) returning id into v_id;

  -- Ista transakcija: slot_taken rollbacka i doprinos (reserve_slots).
  perform pinka_finance.reserve_slots(v_id, v_keys, null);
  select min(s.hold_expires_at) into v_hold from pinka_finance.slots s where s.contribution_id = v_id;

  return query
    select v_id, v_total, v_campaign.currency, v_campaign.destination_address, v_keys, v_hold;
end;
$$;
revoke execute on function pinka_finance.create_sponsor_contribution(uuid,text[],text,text,text,text,jsonb,boolean)
  from public, anon;
grant  execute on function pinka_finance.create_sponsor_contribution(uuid,text[],text,text,text,text,jsonb,boolean)
  to authenticated, service_role;

-- Izlog: definicija iz 20261007120000 §7; kanal s paid_sponsor_moments=false
-- (ili tombstoneom) ne pokazuje ponudu. Prekidač se računa jednom po kampanji.
create or replace view pinka_finance.public_sponsor_moments as
  with offered as materialized (
    select c.id
      from pinka_finance.campaigns c
     where c.deleted_at is null
       and c.visibility in ('public','unlisted')
       and c.state in ('active','funded','closed')
       and pinka_finance.campaign_channel_setting_enabled(c.id, 'paid_sponsor_moments')
  )
  select
    m.campaign_id,
    s.slot_key,
    s.youtube_id,
    s.start_sec,
    s.end_sec,
    s.label        as title,
    z.zone_index,
    z.label_key    as zone_label_key,
    z.price_cents,
    z.run_days,
    -- istekli hold i istekli zakup su slobodni ISTI TREN, bez joba (O6)
    case
      when s.state = 'held' and s.hold_expires_at <= now() then 'free'
      when s.state = 'sold' and s.live_until is not null and s.live_until <= now() then 'free'
      else s.state::text
    end as state,
    case when s.state = 'sold' and s.live_until > now() then s.live_until end as live_until
  from pinka_finance.slots s
  join pinka_finance.slot_zones z on z.id = s.zone_id
  join pinka_finance.slot_maps  m on m.id = s.map_id
  join offered                  o on o.id = m.campaign_id
 where m.kind::text = 'timeline'
   and s.youtube_id is not null;

alter view pinka_finance.public_sponsor_moments set (security_invoker = off);
grant select on pinka_finance.public_sponsor_moments to anon, authenticated, service_role;

-- Prikaz: definicija iz 20261007120000 §7. VEĆ PRODAN trenutak traje do
-- live_until i kad je ključ isključen (odluka 109) — skriva ga samo tombstone.
create or replace view pinka_finance.public_live_moments as
  select
    s.slot_key,
    s.youtube_id,
    s.start_sec,
    s.end_sec,
    ct.display_name as brand,
    ct.message      as tagline,
    ct.link_url,
    case when ct.logo_path is not null
         then pinka_finance.public_storage_url() || '/sponsor-logos/' || ct.logo_path end as logo_url,
    ct.logo_path,
    s.live_from,
    s.live_until
  from pinka_finance.slots s
  join pinka_finance.slot_maps  m  on m.id = s.map_id
  join pinka_finance.campaigns  c  on c.id = m.campaign_id
  join pinka_finance.contributions ct on ct.id = s.contribution_id
 where m.kind::text = 'timeline'
   and s.youtube_id is not null
   and s.state = 'sold'
   and ct.state = 'paid'
   and ct.is_sponsor
   and not ct.message_hidden
   and s.live_from <= now()
   and s.live_until > now()
   and c.deleted_at is null
   and c.visibility in ('public','unlisted')
   and c.state in ('active','funded','closed')
   and not exists (
     select 1 from domovina_ai.channel_tombstones t
      where t.youtube_channel_id = pinka_finance.campaign_channel_uc(c.id));

alter view pinka_finance.public_live_moments set (security_invoker = off);
grant select on pinka_finance.public_live_moments to anon, authenticated, service_role;

notify pgrst, 'reload schema';

select 'OK postavke_kanala' as status;
