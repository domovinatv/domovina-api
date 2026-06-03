-- =============================================================================
-- pinka_finance — channel-owner campaign administration (Faza A) + multi-episode
-- Reference: domovina-api/docs/pinka-finance-platform-plan.md
--
-- Cilj:
--   1. JEDNA kampanja ↔ VIŠE epizoda (epizoda ↦ ≤1 kampanja). Današnji model je
--      imao jedan campaigns.subject_ref → dodajemo join tablicu campaign_subjects.
--      Legacy stupce (campaigns.subject_type/subject_ref) NE diramo — pinka.io ih
--      i dalje piše; join tablica je aditivna, čita se kroz active_campaign_for_subject.
--   2. Verificirani vlasnik kanala (domovina_ai.channel_claims, role=primary,
--      status=verified) može upravljati kampanjama "ankeriranim" na taj kanal
--      (nova kolona campaigns.youtube_channel_id). Bridge identiteta = auth.uid().
--      Vlasništvo preko public.accounts (has_role_on_account) ostaje paralelno.
--
-- Doseg: SAMO upravljanje postojećim kampanjama. Kreiranje (+ Safe provisioning)
--   ostaje na pinka.io → INSERT/DELETE RLS politike NISU dirane.
--
-- Sve funkcije: security definer set search_path = '' (sve reference qualified).
-- =============================================================================

-- ===== A) anchor kanala + join tablica =======================================

alter table pinka_finance.campaigns
  add column if not exists youtube_channel_id text
    check (youtube_channel_id is null or youtube_channel_id ~ '^UC[0-9A-Za-z_-]{22}$');

create index if not exists ix_campaigns_channel
  on pinka_finance.campaigns(youtube_channel_id) where deleted_at is null;

create table if not exists pinka_finance.campaign_subjects (
  id           uuid primary key default gen_random_uuid(),
  campaign_id  uuid not null references pinka_finance.campaigns(id) on delete cascade,
  subject_type text not null default 'podcast_episode',
  subject_ref  text not null,
  created_at   timestamptz not null default now(),
  -- subjekt (npr. epizoda) može biti dio NAJVIŠE jedne kampanje
  unique (subject_type, subject_ref)
);
create index if not exists ix_campaign_subjects_campaign
  on pinka_finance.campaign_subjects(campaign_id);
create index if not exists ix_campaign_subjects_lookup
  on pinka_finance.campaign_subjects(subject_type, subject_ref);

alter table pinka_finance.campaign_subjects enable row level security;

-- select grant (default privileges već daju select anon/authenticated na nove
-- tablice; eksplicitno za jasnoću). Write ide samo kroz SECURITY DEFINER RPC-eve.
grant select on pinka_finance.campaign_subjects to anon, authenticated, service_role;
grant insert, update, delete on pinka_finance.campaign_subjects to service_role;

-- backfill legacy single subject u join (idempotentno)
insert into pinka_finance.campaign_subjects (campaign_id, subject_type, subject_ref)
select id, subject_type, subject_ref
from pinka_finance.campaigns
where subject_ref is not null and subject_type <> 'generic' and deleted_at is null
on conflict (subject_type, subject_ref) do nothing;

-- ===== B) bridge helper: verificirani vlasnik kanala =========================
-- auth.uid() (auth.users.id) == channel_claims.account_id za primary verified
-- claim. Stable + security definer; OR-grane u RLS-u gated `... is not null`.
create or replace function pinka_finance.is_verified_channel_owner(p_channel text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_channel is not null and exists (
    select 1 from domovina_ai.channel_claims cc
    where cc.youtube_channel_id = p_channel
      and cc.account_id = (select auth.uid())
      and cc.status = 'verified'
      and cc.role   = 'primary'
  );
$$;

revoke all on function pinka_finance.is_verified_channel_owner(text) from public;
grant execute on function pinka_finance.is_verified_channel_owner(text)
  to anon, authenticated, service_role;

-- ===== C) proširene RLS politike (extend, ne replace) ========================
-- Svuda: postojeći has_role_on_account(...) put OSTAJE; dodaje se OR za
-- verificiranog vlasnika kanala ankeriranog na campaigns.youtube_channel_id.

-- campaigns_select — vlasnik vidi i svoje draft/private kampanje
drop policy if exists campaigns_select on pinka_finance.campaigns;
create policy campaigns_select on pinka_finance.campaigns
  for select to anon, authenticated
  using (
    deleted_at is null
    and (
      (visibility in ('public','unlisted') and state in ('active','funded','closed'))
      or public.is_account_member(account_id)
      or pinka_finance.is_verified_channel_owner(youtube_channel_id)
    )
  );

-- campaigns_update — vlasnik kanala može mijenjati tekst/state/visibility
drop policy if exists campaigns_update on pinka_finance.campaigns;
create policy campaigns_update on pinka_finance.campaigns
  for update to authenticated
  using (
    deleted_at is null and (
      public.has_role_on_account(account_id, 'admin')
      or pinka_finance.is_verified_channel_owner(youtube_channel_id)
    )
  )
  with check (
    public.has_role_on_account(account_id, 'admin')
    or pinka_finance.is_verified_channel_owner(youtube_channel_id)
  );
-- INSERT (campaigns_insert) i DELETE (campaigns_delete) NISU dirani — kreiranje
-- i brisanje ostaju vezani na public.accounts admin/owner.

-- campaign_tiers write — vlasnik kanala smije uređivati tierove
drop policy if exists tiers_write on pinka_finance.campaign_tiers;
create policy tiers_write on pinka_finance.campaign_tiers
  for all to authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and (
        public.has_role_on_account(c.account_id, 'admin')
        or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
      )
    )
  )
  with check (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and (
        public.has_role_on_account(c.account_id, 'admin')
        or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
      )
    )
  );

-- contributions_select — vlasnik kanala vidi punu listu doprinosa za dashboard
drop policy if exists contributions_select on pinka_finance.contributions;
create policy contributions_select on pinka_finance.contributions
  for select to authenticated
  using (
    public.is_account_member(contributor_account_id)
    or exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and (
        public.has_role_on_account(c.account_id, 'admin')
        or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
      )
    )
  );

-- campaign_subjects_select — čitljivo kad je matična kampanja čitljiva
drop policy if exists campaign_subjects_select on pinka_finance.campaign_subjects;
create policy campaign_subjects_select on pinka_finance.campaign_subjects
  for select to anon, authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id
        and c.deleted_at is null
        and (
          (c.visibility in ('public','unlisted') and c.state in ('active','funded','closed'))
          or public.is_account_member(c.account_id)
          or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
        )
    )
  );

-- =============================================================================
-- RPC-evi
-- =============================================================================

-- ----- active_campaign_for_subject (anon + authenticated) --------------------
-- Vraća JEDNU aktivnu javnu/unlisted kampanju za (subject_type, bilo koji ref),
-- iz legacy stupaca ILI iz campaign_subjects join tablice. Jedinstvena točka
-- razrješenja "dual subject source". SECURITY DEFINER → zaobilazi RLS, pa WHERE
-- mora sam ograničiti na siguran javni subset.
create or replace function pinka_finance.active_campaign_for_subject(
  p_subject_type text,
  p_subject_refs text[]
) returns table (
  id                  uuid,
  slug                text,
  type                text,
  title               text,
  description         text,
  goal_cents          bigint,
  min_contribution_cents integer,
  currency            text,
  cover_image_url     text,
  state               text,
  destination_address text,
  chain               text,
  youtube_channel_id  text,
  total_raised_cents  bigint,
  contribution_count  integer,
  contributor_count   integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id, c.slug::text, c.type::text, c.title, c.description,
    c.goal_cents, c.min_contribution_cents, c.currency, c.cover_image_url,
    c.state::text, c.destination_address, c.chain, c.youtube_channel_id,
    coalesce(s.total_raised_cents, 0), coalesce(s.contribution_count, 0),
    coalesce(s.contributor_count, 0)
  from pinka_finance.campaigns c
  left join pinka_finance.campaign_stats s on s.campaign_id = c.id
  where c.deleted_at is null
    and c.visibility in ('public','unlisted')
    and c.state in ('active','funded')
    and (
      (c.subject_type = p_subject_type and c.subject_ref = any(p_subject_refs))
      or exists (
        select 1 from pinka_finance.campaign_subjects cs
        where cs.campaign_id = c.id
          and cs.subject_type = p_subject_type
          and cs.subject_ref = any(p_subject_refs)
      )
    )
  order by c.created_at desc
  limit 1;
$$;

revoke all on function pinka_finance.active_campaign_for_subject(text, text[]) from public;
grant execute on function pinka_finance.active_campaign_for_subject(text, text[])
  to anon, authenticated, service_role;

-- ----- ownership guard helper (interno) --------------------------------------
create or replace function pinka_finance._assert_can_admin_campaign(p_campaign_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_acc uuid; v_ch text;
begin
  select account_id, youtube_channel_id into v_acc, v_ch
    from pinka_finance.campaigns where id = p_campaign_id and deleted_at is null;
  if not found then raise exception 'campaign_not_found'; end if;
  if not (
    public.has_role_on_account(v_acc, 'admin')
    or pinka_finance.is_verified_channel_owner(v_ch)
  ) then
    raise exception 'not_authorized';
  end if;
end;
$$;

revoke all on function pinka_finance._assert_can_admin_campaign(uuid) from public, anon;
grant execute on function pinka_finance._assert_can_admin_campaign(uuid) to authenticated, service_role;

-- ----- set_campaign_episodes (authenticated; vlasnik) ------------------------
-- Zamijeni cijeli set epizoda kampanje. Ako je neka epizoda već u DRUGOJ
-- kampanji → raise 'episode_taken' (unique(subject_type,subject_ref)).
create or replace function pinka_finance.set_campaign_episodes(
  p_campaign_id uuid,
  p_episode_ids text[]
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);

  if exists (
    select 1 from pinka_finance.campaign_subjects cs
    where cs.subject_type = 'podcast_episode'
      and cs.subject_ref = any(coalesce(p_episode_ids, '{}'))
      and cs.campaign_id <> p_campaign_id
  ) then
    raise exception 'episode_taken';
  end if;

  delete from pinka_finance.campaign_subjects
   where campaign_id = p_campaign_id and subject_type = 'podcast_episode';

  if p_episode_ids is not null and array_length(p_episode_ids, 1) is not null then
    insert into pinka_finance.campaign_subjects (campaign_id, subject_type, subject_ref)
    select p_campaign_id, 'podcast_episode', x
    from unnest(p_episode_ids) as x
    on conflict (subject_type, subject_ref) do nothing;
  end if;
end;
$$;

revoke all on function pinka_finance.set_campaign_episodes(uuid, text[]) from public, anon;
grant execute on function pinka_finance.set_campaign_episodes(uuid, text[]) to authenticated, service_role;

-- ----- attach / detach pojedinog subjekta ------------------------------------
create or replace function pinka_finance.attach_campaign_subject(
  p_campaign_id uuid,
  p_subject_type text,
  p_subject_ref text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);
  if exists (
    select 1 from pinka_finance.campaign_subjects cs
    where cs.subject_type = p_subject_type and cs.subject_ref = p_subject_ref
      and cs.campaign_id <> p_campaign_id
  ) then
    raise exception 'episode_taken';
  end if;
  insert into pinka_finance.campaign_subjects (campaign_id, subject_type, subject_ref)
  values (p_campaign_id, p_subject_type, p_subject_ref)
  on conflict (subject_type, subject_ref) do nothing;
end;
$$;

revoke all on function pinka_finance.attach_campaign_subject(uuid, text, text) from public, anon;
grant execute on function pinka_finance.attach_campaign_subject(uuid, text, text) to authenticated, service_role;

create or replace function pinka_finance.detach_campaign_subject(
  p_campaign_id uuid,
  p_subject_type text,
  p_subject_ref text
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);
  delete from pinka_finance.campaign_subjects
   where campaign_id = p_campaign_id
     and subject_type = p_subject_type
     and subject_ref = p_subject_ref;
end;
$$;

revoke all on function pinka_finance.detach_campaign_subject(uuid, text, text) from public, anon;
grant execute on function pinka_finance.detach_campaign_subject(uuid, text, text) to authenticated, service_role;

select 'OK pinka_campaign_admin' as status;
