-- =============================================================================
-- Izborni dan — RPC-evi
-- Reference: domovina.ai/docs/plans/2026-08-08-glasanje-o-kanalima.md
--            §5.2 (ugovor), §6.2–6.3 (granica dana + streak), §7 (rangiranje,
--            kvorum, lijeno zatvaranje kola)
--
-- Javni ugovor (PostgREST, `client.schema('domovina_ai').rpc(...)`):
--   vote_today()                                            → date   (anon)
--   current_round()                                         → jsonb  (anon; PIŠE — lijeno otvara/zatvara kolo)
--   round_leaderboard(p_round_id, p_sort, p_tag,
--                     p_limit, p_offset, p_query)           → table  (anon)
--   my_voting_state()                                       → jsonb  (authenticated; NE piše)
--   cast_vote(p_slug, p_direction)                          → jsonb  (authenticated)
--   accept_voting_terms()                                   → void   (authenticated)
--
-- Interni / test wrapperi (service_role ONLY — dan se predaje kao parametar,
-- da se rubni slučajevi iz §6.4 testiraju BEZ mijenjanja now()):
--   _ensure_round(p_day)                                    → int
--   _voting_state_of(p_user_id, p_day)                      → jsonb
--   _cast_vote_on(p_user_id, p_slug, p_direction, p_day)    → jsonb
--   _accept_voting_terms_for(p_user_id)                     → void
--
-- Odstupanja od §5.2 (dogovorena s orkestratorom prije nego je T2 krenuo):
--   * imena parametara nose `p_` prefiks (konvencija repoa; §5.2 piše `slug, dir`)
--   * `p_query` je NOVI opcionalni parametar pretrage na round_leaderboard
--   * `today_vote` je `{"slug","direction"}` (§5.2 pokazuje samo null slučaj)
--
-- Sigurnosni model:
--   * SVE funkcije su `security definer set search_path = ''` (fully qualified).
--   * Datum se NIKAD ne prima od klijenta — javni RPC-evi ga računaju sami
--     preko domovina_ai.vote_today(); dan-kao-parametar postoji samo na
--     internim wrapperima koji su revoke-ani od anon/authenticated/public.
--   * cast_vote razrješava `voter` iz `public.identity_verifications.oib_hash`
--     (tablica je service_role-only) — zato SECURITY DEFINER.
-- =============================================================================

-- ----- vote_today (JEDINI izvor „danas") -------------------------------------
-- §6.2: granica dana je isključivo u Postgresu. Hrvatska mijenja sat u 03:00,
-- granica je 00:00 → DST ne dira ponoć.
create or replace function domovina_ai.vote_today()
returns date
language sql stable security definer set search_path = ''
as $$
  select (pg_catalog.now() at time zone 'Europe/Zagreb')::date;
$$;

revoke execute on function domovina_ai.vote_today() from public;
grant execute on function domovina_ai.vote_today() to anon, authenticated, service_role;

-- ----- _ensure_round (lijeno otvaranje/zatvaranje kola, §7.3) ----------------
-- Idempotentno, bez crona. Prvi korisnik nakon ponoći plaća ~5 ms.
-- Petlja jer korisnik može doći nakon VIŠE propuštenih kola.
create or replace function domovina_ai._ensure_round(p_day date)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_round  domovina_ai.vote_rounds%rowtype;
  v_winner text;
  v_new_id int;
  v_guard  int := 0;
begin
  -- brzi put: otvoreno kolo koje pokriva današnji dan → ništa za raditi,
  -- i NE uzimamo advisory lock (inače bi svaki glas bio globalno serijaliziran).
  select * into v_round from domovina_ai.vote_rounds where status = 'open' limit 1;
  if found and v_round.ends_on >= p_day then
    return v_round.id;
  end if;

  -- rollover put: serijaliziraj (dva korisnika mogu doći u istoj milisekundi)
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('domovina_ai.vote_rounds')::bigint);
  select * into v_round from domovina_ai.vote_rounds where status = 'open' limit 1;

  if not found then
    insert into domovina_ai.vote_rounds (starts_on, ends_on)
    values (p_day, p_day + 13)              -- 14 dana, ends_on uključivo
    returning id into v_new_id;
    return v_new_id;
  end if;

  while v_round.ends_on < p_day loop
    v_guard := v_guard + 1;
    if v_guard > 500 then
      raise exception 'round_rollover_runaway';
    end if;

    -- ── pobjednik: neto desc, tie-break deterministički, BEZ random() (§7.1) ──
    select t.slug into v_winner
      from domovina_ai.vote_tallies t
      join domovina_ai.vote_candidates c on c.slug = t.slug
     where t.round_id = v_round.id
       and c.status = 'candidate'
       and t.net >= v_round.quorum_net                      -- §7.2 kvorum
       and (t.up + t.down) >= v_round.quorum_total
     order by t.net desc, t.up desc, c.quality_score desc nulls last, t.slug asc
     limit 1;

    update domovina_ai.vote_rounds
       set status           = 'closed',
           winner_slug      = v_winner,
           no_winner_reason = case when v_winner is null then 'quorum_not_met' end,
           closed_at        = pg_catalog.now()
     where id = v_round.id;

    if v_winner is not null then
      update domovina_ai.vote_candidates set status = 'winner' where slug = v_winner;
    end if;

    insert into domovina_ai.vote_rounds (starts_on, ends_on, quorum_net, quorum_total)
    values (v_round.ends_on + 1, v_round.ends_on + 14, v_round.quorum_net, v_round.quorum_total)
    returning id into v_new_id;

    -- carry-over: bez pobjednika se trud glasača NE baca (§7.2)
    if v_winner is null then
      insert into domovina_ai.vote_tallies (round_id, slug, up, down)
      select v_new_id, t.slug, t.up, t.down
        from domovina_ai.vote_tallies t
        join domovina_ai.vote_candidates c on c.slug = t.slug
       where t.round_id = v_round.id
         and c.status = 'candidate'
         and (t.up > 0 or t.down > 0);
    end if;

    select * into v_round from domovina_ai.vote_rounds where id = v_new_id;
  end loop;

  return v_round.id;
end;
$$;

revoke execute on function domovina_ai._ensure_round(date) from public, anon, authenticated;
grant execute on function domovina_ai._ensure_round(date) to service_role;

-- ----- current_round (anon; lijeno otvara/zatvara kolo) ----------------------
create or replace function domovina_ai.current_round()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_day    date := domovina_ai.vote_today();
  v_id     int;
  v_r      domovina_ai.vote_rounds%rowtype;
  v_total  int;
  v_voters int;
begin
  v_id := domovina_ai._ensure_round(v_day);
  select * into v_r from domovina_ai.vote_rounds where id = v_id;

  select pg_catalog.count(*), pg_catalog.count(distinct v.voter_id)
    into v_total, v_voters
    from domovina_ai.votes v
   where v.round_id = v_id;

  return jsonb_build_object(
    'id',           v_r.id,
    'starts_on',    v_r.starts_on,
    'ends_on',      v_r.ends_on,
    'status',       v_r.status,
    'days_left',    greatest(0, v_r.ends_on - v_day),
    'today',        v_day,
    'quorum_net',   v_r.quorum_net,
    'quorum_total', v_r.quorum_total,
    'total_votes',  v_total,     -- §11.3 transparentnost: agregati su javni
    'voters',       v_voters
  );
end;
$$;

revoke execute on function domovina_ai.current_round() from public;
grant execute on function domovina_ai.current_round() to anon, authenticated, service_role;

-- ----- _voting_state_of (čista projekcija §6.3 — NIJEDAN upis) ---------------
-- Isti izraz koji cast_vote koristi za upis; ovdje samo za prikaz.
create or replace function domovina_ai._voting_state_of(p_user_id uuid, p_day date)
returns jsonb
language plpgsql security definer set search_path = '' stable
as $$
declare
  v_hash       text;
  v_v          domovina_ai.voters%rowtype;
  v_r          domovina_ai.vote_rounds%rowtype;
  v_round      jsonb := null;
  v_missed     int := 0;
  v_voted      boolean := false;
  v_streak     int := 0;
  v_at_risk    boolean := false;
  v_burn       int := 0;
  v_today_vote jsonb := null;
begin
  select * into v_r from domovina_ai.vote_rounds where status = 'open' limit 1;
  if found then
    v_round := jsonb_build_object(
      'id',        v_r.id,
      'starts_on', v_r.starts_on,
      'ends_on',   v_r.ends_on,
      'days_left', greatest(0, v_r.ends_on - p_day)
    );
  end if;

  if p_user_id is not null then
    select iv.oib_hash into v_hash
      from public.identity_verifications iv
     where iv.user_id = p_user_id;
  end if;

  if v_hash is null then
    return jsonb_build_object(
      'verified', false, 'consented', false, 'voted_today', false,
      'today', p_day, 'streak', 0, 'longest_streak', 0, 'flags', 0,
      'streak_at_risk', false, 'flags_that_will_burn', 0,
      'last_vote_day', null, 'today_vote', null, 'round', v_round
    );
  end if;

  select * into v_v from domovina_ai.voters where oib_hash = v_hash;
  if not found then
    -- verificiran, ali još nije prihvatio uvjete / nikad glasao
    return jsonb_build_object(
      'verified', true, 'consented', false, 'voted_today', false,
      'today', p_day, 'streak', 0, 'longest_streak', 0, 'flags', 0,
      'streak_at_risk', false, 'flags_that_will_burn', 0,
      'last_vote_day', null, 'today_vote', null, 'round', v_round
    );
  end if;

  v_voted  := coalesce(v_v.last_vote_day = p_day, false);
  v_missed := case when v_v.last_vote_day is null then 0
                   else greatest(0, p_day - v_v.last_vote_day - 1) end;

  -- displayed_streak (§6.3): niz koji je već pukao prikazuje se kao 0
  v_streak := case
                when v_voted then v_v.current_streak
                when v_v.last_vote_day is null then 0
                when v_missed <= v_v.flags then v_v.current_streak
                else 0
              end;

  -- „zadnji dan obrane" — točno onoliko propuštenih koliko ima zastavica
  v_at_risk := (not v_voted) and v_v.last_vote_day is not null and v_missed = v_v.flags;

  -- koliko bi zastavica izgorjelo da glasa SADA (0 ako je niz ionako pukao)
  v_burn := case when (not v_voted) and v_missed <= v_v.flags then v_missed else 0 end;

  if v_voted then
    select jsonb_build_object('slug', vt.slug, 'direction', vt.direction)
      into v_today_vote
      from domovina_ai.votes vt
     where vt.voter_id = v_v.id and vt.vote_day = p_day;
  end if;

  return jsonb_build_object(
    'verified',             true,
    'consented',            v_v.consented_at is not null,
    'voted_today',          v_voted,
    'today',                p_day,
    'streak',               v_streak,
    'longest_streak',       v_v.longest_streak,
    'flags',                v_v.flags,
    'streak_at_risk',       v_at_risk,
    'flags_that_will_burn', v_burn,
    'last_vote_day',        v_v.last_vote_day,
    'today_vote',           v_today_vote,
    'round',                v_round
  );
end;
$$;

revoke execute on function domovina_ai._voting_state_of(uuid, date) from public, anon, authenticated;
grant execute on function domovina_ai._voting_state_of(uuid, date) to service_role;

-- ----- my_voting_state (authenticated; NE piše) ------------------------------
-- Namjerno NE zove _ensure_round — §5.2 kaže „projekcija bez ikakvog upisa".
-- Klijent prvo zove current_round() (koji rollovera), pa ovo.
create or replace function domovina_ai.my_voting_state()
returns jsonb
language sql security definer set search_path = '' stable
as $$
  select domovina_ai._voting_state_of((select auth.uid()), domovina_ai.vote_today());
$$;

revoke execute on function domovina_ai.my_voting_state() from public, anon;
grant execute on function domovina_ai.my_voting_state() to authenticated, service_role;

-- ----- _accept_voting_terms_for / accept_voting_terms (§4.3 privola) ---------
create or replace function domovina_ai._accept_voting_terms_for(p_user_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_hash text;
begin
  if p_user_id is null then
    raise exception 'not_verified';
  end if;

  select iv.oib_hash into v_hash
    from public.identity_verifications iv
   where iv.user_id = p_user_id;

  if v_hash is null then
    raise exception 'not_verified';
  end if;

  insert into domovina_ai.voters (oib_hash, user_id, consented_at)
  values (v_hash, p_user_id, pg_catalog.now())
  on conflict (oib_hash) do update
    set user_id      = excluded.user_id,
        consented_at = coalesce(domovina_ai.voters.consented_at, excluded.consented_at),
        updated_at   = pg_catalog.now();
end;
$$;

revoke execute on function domovina_ai._accept_voting_terms_for(uuid) from public, anon, authenticated;
grant execute on function domovina_ai._accept_voting_terms_for(uuid) to service_role;

create or replace function domovina_ai.accept_voting_terms()
returns void
language sql security definer set search_path = ''
as $$
  select domovina_ai._accept_voting_terms_for((select auth.uid()));
$$;

revoke execute on function domovina_ai.accept_voting_terms() from public, anon;
grant execute on function domovina_ai.accept_voting_terms() to authenticated, service_role;

-- ----- _cast_vote_on (jezgra — JEDNA transakcija) ----------------------------
-- Redoslijed je bitan: insert u votes IDE PRVI (unique constraint je čuvar),
-- pa tek onda tally i streak — ako druga (paralelna) transakcija padne na
-- unique violation, rollback poništi i njezin tally inkrement.
create or replace function domovina_ai._cast_vote_on(
  p_user_id   uuid,
  p_slug      text,
  p_direction int,
  p_day       date
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash     text;
  v_voter    domovina_ai.voters%rowtype;
  v_status   text;
  v_round_id int;
  v_r        domovina_ai.vote_rounds%rowtype;
  v_missed   int;
  v_streak   int;
  v_flags    int;
  v_burned   int := 0;
  v_saved    boolean := false;
begin
  if p_direction is null or p_direction not in (-1, 1) then
    raise exception 'invalid_direction';
  end if;
  if p_user_id is null then
    raise exception 'not_verified';
  end if;

  -- ── identitet: oib_hash iz service_role-only tablice (zato definer) ───────
  select iv.oib_hash into v_hash
    from public.identity_verifications iv
   where iv.user_id = p_user_id;
  if v_hash is null then
    raise exception 'not_verified';
  end if;

  -- trajni pseudonim: isti oib_hash → isti voter_id, i nakon brisanja računa
  -- (§4.1). Ovime se niz i zastavice vraćaju novom računu iste osobe.
  insert into domovina_ai.voters (oib_hash, user_id)
  values (v_hash, p_user_id)
  on conflict (oib_hash) do update
    set user_id    = excluded.user_id,
        updated_at = pg_catalog.now()
  returning * into v_voter;

  if v_voter.consented_at is null then
    raise exception 'terms_not_accepted';
  end if;

  -- ── kandidat mora biti u igri (winner/withdrawn/onboarded ispadaju) ───────
  select c.status into v_status
    from domovina_ai.vote_candidates c
   where c.slug = p_slug
     for share;
  if v_status is null or v_status <> 'candidate' then
    raise exception 'candidate_not_available';
  end if;

  -- ── kolo: glas na dan `ends_on` ULAZI u kolo koje se zatvara (§6.4) ───────
  v_round_id := domovina_ai._ensure_round(p_day);
  select * into v_r from domovina_ai.vote_rounds where id = v_round_id;
  if v_r.status <> 'open' or v_r.ends_on < p_day or v_r.starts_on > p_day then
    raise exception 'round_closed';
  end if;

  -- ── serijalizacija duplog tapa: zaključaj glasača, pa provjeri dan ────────
  select * into v_voter from domovina_ai.voters where id = v_voter.id for update;

  if v_voter.last_vote_day is not null and v_voter.last_vote_day > p_day then
    raise exception 'vote_day_in_past';   -- dohvatljivo samo kroz test wrapper
  end if;

  if exists (select 1 from domovina_ai.votes vt
              where vt.voter_id = v_voter.id and vt.vote_day = p_day) then
    raise exception 'already_voted_today';
  end if;

  begin
    insert into domovina_ai.votes (voter_id, round_id, slug, direction, vote_day)
    values (v_voter.id, v_round_id, p_slug, p_direction::smallint, p_day);
  exception when unique_violation then
    raise exception 'already_voted_today';
  end;

  insert into domovina_ai.vote_tallies (round_id, slug, up, down)
  values (v_round_id, p_slug,
          case when p_direction = 1 then 1 else 0 end,
          case when p_direction = -1 then 1 else 0 end)
  on conflict (round_id, slug) do update
    set up   = domovina_ai.vote_tallies.up   + excluded.up,
        down = domovina_ai.vote_tallies.down + excluded.down;

  -- ── streak prijelaz (§6.3) ────────────────────────────────────────────────
  v_flags := v_voter.flags;
  if v_voter.last_vote_day is null then
    v_streak := 1;
  else
    v_missed := greatest(0, p_day - v_voter.last_vote_day - 1);
    if v_missed = 0 then
      v_streak := v_voter.current_streak + 1;                 -- uzastopno
    elsif v_missed <= v_flags then
      v_flags  := v_flags - v_missed;                         -- SPAŠENO
      v_burned := v_missed;
      v_saved  := true;
      v_streak := v_voter.current_streak + 1;
    else
      v_streak := 1;                                          -- PUKNUO;
      -- zastavice se NAMJERNO ne troše kad ne mogu spasiti niz (§2.1 / §6.3):
      -- sve-ili-ništa, da propust ne bude dvostruko kažnjen.
    end if;
  end if;

  v_flags := least(2, v_flags + 1);   -- nagrada za današnji dolazak, strop 2

  update domovina_ai.voters
     set current_streak = v_streak,
         longest_streak = greatest(longest_streak, v_streak),
         flags          = v_flags,
         last_vote_day  = p_day,
         total_votes    = total_votes + 1
   where id = v_voter.id;

  return domovina_ai._voting_state_of(p_user_id, p_day)
       || jsonb_build_object('flags_burned', v_burned, 'streak_saved', v_saved);
end;
$$;

revoke execute on function domovina_ai._cast_vote_on(uuid, text, int, date) from public, anon, authenticated;
grant execute on function domovina_ai._cast_vote_on(uuid, text, int, date) to service_role;

-- ----- cast_vote (authenticated; dan se NE prima od klijenta) ----------------
create or replace function domovina_ai.cast_vote(p_slug text, p_direction int)
returns jsonb
language sql security definer set search_path = ''
as $$
  select domovina_ai._cast_vote_on(
    (select auth.uid()), p_slug, p_direction, domovina_ai.vote_today()
  );
$$;

revoke execute on function domovina_ai.cast_vote(text, int) from public, anon;
grant execute on function domovina_ai.cast_vote(text, int) to authenticated, service_role;

-- ----- round_leaderboard (anon) ----------------------------------------------
-- `rank` je uvijek GLOBALNI poredak ljestvice (§7.1 tie-break), neovisno o
-- p_sort — chip „Nasumično"/„Najmanje glasova" mijenja redoslijed prikaza, ne
-- broj pored imena. Nasumično je deterministički sjemenovano (kolo + dan) da
-- paginacija ne ponavlja/preskače kandidate.
create or replace function domovina_ai.round_leaderboard(
  p_round_id int  default null,
  p_sort     text default 'leaderboard',
  p_tag      text default null,
  p_limit    int  default 50,
  p_offset   int  default 0,
  p_query    text default null
)
returns table (
  slug               text,
  display_name       text,
  youtube_url        text,
  youtube_channel_id text,
  avatar_url         text,
  tags               text[],
  voditelji          text[],
  subscribers        int,
  episodes_estimate  int,
  quality_score      int,
  tier               int,
  notes              text,
  source_type        text,
  status             text,
  up                 int,
  down               int,
  net                int,
  rank               int
)
language plpgsql security definer set search_path = '' stable
as $$
#variable_conflict use_column
declare
  v_round  int;
  v_sort   text := coalesce(p_sort, 'leaderboard');
  v_limit  int  := least(greatest(coalesce(p_limit, 50), 1), 500);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_query  text := nullif(btrim(coalesce(p_query, '')), '');
  v_seed   text;
begin
  if v_sort not in ('leaderboard', 'random', 'least_votes') then
    raise exception 'invalid_sort';
  end if;

  v_round := coalesce(
    p_round_id,
    (select r.id from domovina_ai.vote_rounds r where r.status = 'open' limit 1)
  );
  if v_round is null then
    return;                                    -- nema kola → prazna ljestvica
  end if;

  v_seed := v_round::text || '|' || domovina_ai.vote_today()::text;

  return query
  with base as (
    select c.slug, c.display_name, c.youtube_url, c.youtube_channel_id,
           c.avatar_url, c.tags, c.voditelji, c.subscribers, c.episodes_estimate,
           c.quality_score, c.tier, c.notes, c.source_type, c.status,
           coalesce(t.up, 0)   as up,
           coalesce(t.down, 0) as down,
           coalesce(t.net, 0)  as net
      from domovina_ai.vote_candidates c
      left join domovina_ai.vote_tallies t
             on t.round_id = v_round and t.slug = c.slug
     where c.status = 'candidate'
  ), ranked as (
    select b.*,
           (pg_catalog.rank() over (
              order by b.net desc, b.up desc, b.quality_score desc nulls last, b.slug asc
           ))::int as rank
      from base b
  )
  select k.slug, k.display_name, k.youtube_url, k.youtube_channel_id,
         k.avatar_url, k.tags, k.voditelji, k.subscribers, k.episodes_estimate,
         k.quality_score, k.tier, k.notes, k.source_type, k.status,
         k.up, k.down, k.net, k.rank
    from ranked k
   where (p_tag is null or p_tag = any (k.tags))
     and (v_query is null
          or k.display_name ilike '%' || v_query || '%'
          or k.slug         ilike '%' || v_query || '%')
   order by
     case when v_sort = 'leaderboard'  then k.rank end asc,
     case when v_sort = 'least_votes'  then (k.up + k.down) end asc,
     case when v_sort in ('random', 'least_votes')
          then pg_catalog.md5(k.slug || v_seed) end asc,
     k.slug asc
   limit v_limit offset v_offset;
end;
$$;

revoke execute on function domovina_ai.round_leaderboard(int, text, text, int, int, text) from public;
grant execute on function domovina_ai.round_leaderboard(int, text, text, int, int, text)
  to anon, authenticated, service_role;

select 'OK channel_voting rpcs' as status;
