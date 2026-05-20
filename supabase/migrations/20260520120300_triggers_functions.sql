-- =============================================================================
-- 03 — Triggers & helper functions
-- Reference: domovina.ai/docs/auth-and-database-plan-v3.md §triggers
--            domovina.ai/docs/backend-prompts/03-triggers-functions.md
--
-- Funkcije (sve security definer set search_path = ''):
--   generate_unique_slug(text)        — globalno jedinstven slug
--   handle_new_user()                 — AFTER INSERT auth.users → profile (+account ako ne-anon)
--   handle_user_promoted()            — AFTER UPDATE OF is_anonymous → account + activity event
--   guard_slug_immutable()            — Princip 2 enforce
--   check_membership_is_org()         — odbij membership na personal account
--   is_account_member(uuid)           — RLS helper
--   has_role_on_account(uuid, role)   — RLS helper s hierarhijom
--   log_event(text, uuid, jsonb)      — append na activity_events
--   log_membership_event()            — auto-emit eventova za member changes
--   domovina_ai.log_completion()      — auto-emit episode.completed eventa
-- =============================================================================

-- ===== generate_unique_slug =================================================
create or replace function public.generate_unique_slug(base_text text)
returns citext
language plpgsql security definer set search_path = ''
as $$
declare
  v_base public.citext;
  v_candidate public.citext;
  v_suffix int := 0;
begin
  -- ukloni @domain dio, lowercase, non-alphanum → '-', trim '-' s rubova
  v_base := lower(regexp_replace(split_part(coalesce(base_text, ''), '@', 1),
                                  '[^a-z0-9]+', '-', 'g'));
  v_base := trim(both '-' from v_base);
  if length(v_base) < 1 then v_base := 'user'; end if;
  if length(v_base) > 38 then v_base := substring(v_base, 1, 38); end if;

  v_candidate := v_base;
  loop
    exit when not exists (select 1 from public.accounts where slug = v_candidate);
    v_suffix := v_suffix + 1;
    v_candidate := v_base || '-' || v_suffix::text;
    -- safeguard: stane nakon ~10k pokusaja (vrlo nevjerojatno)
    exit when v_suffix > 10000;
  end loop;

  return v_candidate;
end;
$$;

-- ===== handle_new_user — AFTER INSERT auth.users ============================
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_slug public.citext;
  v_account_id uuid;
  v_name text;
begin
  -- 1. profile (uvijek) — BEZ email/is_anonymous (PII princip)
  insert into public.profiles (id, locale)
    values (new.id, 'hr')
    on conflict (id) do nothing;

  -- 2. personal account (samo ako NIJE anonymous — treba email/name za slug)
  if not coalesce(new.is_anonymous, false) then
    v_slug := public.generate_unique_slug(
      coalesce(new.email, new.raw_user_meta_data->>'name', 'user')
    );
    v_name := coalesce(new.raw_user_meta_data->>'name', new.email, v_slug::text);

    insert into public.accounts (primary_owner_user_id, is_personal_account, slug, name)
      values (new.id, true, v_slug, v_name)
      returning id into v_account_id;

    update public.profiles set active_account_id = v_account_id where id = new.id;

    insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
      values (new.id, v_account_id, 'account.created',
              jsonb_build_object('slug', v_slug::text, 'is_personal', true));
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users for each row
  execute function public.handle_new_user();

-- ===== handle_user_promoted — AFTER UPDATE OF is_anonymous ===================
-- Okida samo na flip: TRUE → FALSE (anonymous postaje permanent).
create or replace function public.handle_user_promoted()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_slug public.citext;
  v_account_id uuid;
  v_name text;
begin
  if not (coalesce(old.is_anonymous, false) = true
          and coalesce(new.is_anonymous, false) = false) then
    return new;
  end if;

  -- Idempotent: ako personal account već postoji, ne kreiraj duplikat
  select id into v_account_id
    from public.accounts
    where primary_owner_user_id = new.id
      and is_personal_account = true
      and deleted_at is null
    limit 1;

  if v_account_id is null then
    v_slug := public.generate_unique_slug(
      coalesce(new.email, new.raw_user_meta_data->>'name', 'user')
    );
    v_name := coalesce(new.raw_user_meta_data->>'name', new.email, v_slug::text);

    insert into public.accounts (primary_owner_user_id, is_personal_account, slug, name)
      values (new.id, true, v_slug, v_name)
      returning id into v_account_id;
  else
    select slug into v_slug from public.accounts where id = v_account_id;
  end if;

  update public.profiles set active_account_id = v_account_id where id = new.id;

  insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
    values (new.id, v_account_id, 'user.promoted',
            jsonb_build_object('slug', v_slug::text));

  return new;
end;
$$;

drop trigger if exists on_auth_user_promoted on auth.users;
create trigger on_auth_user_promoted
  after update of is_anonymous on auth.users for each row
  execute function public.handle_user_promoted();

-- ===== guard_slug_immutable (Princip 2) =====================================
-- Plain plpgsql (NE security definer — to nije RLS check, već app rule)
create or replace function public.guard_slug_immutable() returns trigger
language plpgsql
as $$
begin
  if old.slug is distinct from new.slug then
    raise exception 'slug is immutable in v1 (changed from % to %)',
      old.slug, new.slug
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_slug_immutable on public.accounts;
create trigger trg_guard_slug_immutable
  before update on public.accounts
  for each row execute function public.guard_slug_immutable();

-- ===== check_membership_is_org ==============================================
-- Membership ne smije postojati na personal accountu (jer personal = jedna osoba).
create or replace function public.check_membership_is_org() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_is_personal boolean;
begin
  select is_personal_account into v_is_personal
    from public.accounts where id = new.account_id;
  if v_is_personal is null then
    raise exception 'account % does not exist', new.account_id;
  end if;
  if v_is_personal then
    raise exception 'cannot add membership to personal account %', new.account_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_check_membership_is_org on public.accounts_memberships;
create trigger trg_check_membership_is_org
  before insert or update on public.accounts_memberships
  for each row execute function public.check_membership_is_org();

-- ===== is_account_member (RLS helper) =======================================
create or replace function public.is_account_member(p_account uuid)
returns boolean
language sql security definer set search_path = '' stable
as $$
  select exists (
    select 1 from public.accounts a
    where a.id = p_account
      and a.deleted_at is null
      and (
        a.primary_owner_user_id = (select auth.uid())
        or exists (
          select 1 from public.accounts_memberships m
          where m.account_id = p_account
            and m.user_id = (select auth.uid())
        )
      )
  );
$$;

-- ===== has_role_on_account (RLS helper, hierarhija owner > admin > member) ==
create or replace function public.has_role_on_account(
  p_account uuid,
  p_min_role public.member_role default 'member'
)
returns boolean
language sql security definer set search_path = '' stable
as $$
  select exists (
    select 1 from public.accounts a
    where a.id = p_account
      and a.deleted_at is null
      and (
        a.primary_owner_user_id = (select auth.uid())   -- owner uvijek prolazi
        or exists (
          select 1 from public.accounts_memberships m
          where m.account_id = p_account
            and m.user_id = (select auth.uid())
            and (
              p_min_role = 'member'
              or (p_min_role = 'admin' and m.account_role in ('admin','owner'))
              or (p_min_role = 'owner' and m.account_role = 'owner')
            )
        )
      )
  );
$$;

grant execute on function public.is_account_member(uuid) to authenticated;
grant execute on function public.has_role_on_account(uuid, public.member_role) to authenticated;

-- ===== log_event (append-only helper za activity_events) ====================
create or replace function public.log_event(
  p_event_type text,
  p_target_account_id uuid,
  p_payload jsonb default '{}'::jsonb
) returns void
language sql security definer set search_path = ''
as $$
  insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
  values ((select auth.uid()), p_target_account_id, p_event_type, p_payload);
$$;

grant execute on function public.log_event(text, uuid, jsonb) to authenticated;

-- ===== log_membership_event (auto-emit eventova) ============================
create or replace function public.log_membership_event() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (tg_op = 'INSERT') then
    insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
    values (
      coalesce(new.invited_by, new.user_id),
      new.account_id,
      'member.joined',
      jsonb_build_object('user_id', new.user_id, 'role', new.account_role::text)
    );
  elsif (tg_op = 'UPDATE' and old.account_role is distinct from new.account_role) then
    insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
    values (
      (select auth.uid()),
      new.account_id,
      'member.role_changed',
      jsonb_build_object(
        'user_id', new.user_id,
        'old_role', old.account_role::text,
        'new_role', new.account_role::text
      )
    );
  elsif (tg_op = 'DELETE') then
    insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
    values (
      (select auth.uid()),
      old.account_id,
      'member.removed',
      jsonb_build_object('user_id', old.user_id, 'role', old.account_role::text)
    );
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_log_membership on public.accounts_memberships;
create trigger trg_log_membership
  after insert or update or delete on public.accounts_memberships
  for each row execute function public.log_membership_event();

-- ===== log_completion (flip completed false → true) =========================
create or replace function domovina_ai.log_completion() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if (tg_op = 'UPDATE'
      and coalesce(old.completed, false) = false
      and coalesce(new.completed, false) = true) then
    insert into public.activity_events (actor_user_id, target_account_id, event_type, payload)
    select new.user_id, a.id, 'episode.completed',
           jsonb_build_object('episode_id', new.episode_id,
                              'duration', new.duration_seconds)
    from public.accounts a
    where a.primary_owner_user_id = new.user_id
      and a.is_personal_account = true
      and a.deleted_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_log_completion on domovina_ai.watch_progress;
create trigger trg_log_completion
  after update on domovina_ai.watch_progress
  for each row execute function domovina_ai.log_completion();

select 'OK 03 triggers_functions' as status;
