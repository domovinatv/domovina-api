-- =============================================================================
-- Izborni dan — zastavice bliže Brilliant modelu (25.8.2026.)
--
-- Mijenja SAMO `domovina_ai._cast_vote_on`; shema, RLS i ostali RPC-evi ostaju.
-- Ostatak funkcije je doslovna kopija iz 20260808120200 — jedina razlika je
-- blok „streak prijelaz" na dnu.
--
-- ── Povod ───────────────────────────────────────────────────────────────────
-- Stvarni slučaj s produkcije: glas 12.8. (prvi ikad → niz 1, zastavica 1), pa
-- 12 propuštenih dana, pa glas 25.8. Ishod po staroj logici:
--     niz 1 → 1 (puknuo)      zastavice 1 → 2 (!)
-- Korisnik je propustio 12 dana, izgubio niz, i za to DOBIO zastavicu. Dvije
-- odluke iz predaje (docs/plans/2026-08-08-glasanje-predaja.md) su se u praksi
-- pokazale krivima:
--
--   Odluka 7 „zastavice se troše sve-ili-ništa" — praznina veća od broja
--   zastavica ih je ostavljala netaknutima. Namjera je bila „ne kazni dvaput",
--   ali posljedica je da zastavica NIKAD ne nestane osim kad nešto spasi, pa
--   prestaje biti resurs kojim se upravlja.
--
--   Nagrada `least(2, flags + 1)` bila je BEZUVJETNA — i na glasu koji je upravo
--   puknuo niz. Reset i nagrada u istom potezu.
--
-- ── Nova pravila ────────────────────────────────────────────────────────────
--   1. Nagrada za dolazak se dodjeljuje SAMO ako niz nije puknuo.
--      (Prvi glas ikad NIJE puknuće — on i dalje nosi zastavicu.)
--   2. Trošenje je DJELOMIČNO: kad praznina prelazi broj zastavica, pojedu se
--      sve što ih je bilo, i niz svejedno pukne. Kao na Brilliantu.
--
-- `flags_burned` od sada može biti > 0 uz `streak_saved = false` — to je novi
-- slučaj u ugovoru v1.1 („zastavice potrošene, niz ipak pukao") i klijent za
-- njega ima zasebnu poruku. `streak_saved = true` i dalje implicira `burned > 0`.
--
-- Što se NIJE mijenjalo: strop od 2 zastavice, granica dana (`vote_today()`),
-- kvorum, kola, i činjenica da nema crona — cijeli obračun se i dalje događa
-- lijeno, u trenutku sljedećeg glasa.
-- =============================================================================

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
  v_broke    boolean := false;
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

  -- ── streak prijelaz (§6.3, revidiran 25.8.2026. — vidi zaglavlje) ─────────
  v_flags := v_voter.flags;
  if v_voter.last_vote_day is null then
    v_streak := 1;                                            -- prvi glas ikad
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
      -- PUKNUO. Zastavice se troše i kad ne mogu spasiti niz: inače nikad ne
      -- nestanu osim kad nešto spase, pa prestaju biti resurs kojim se upravlja.
      v_burned := v_flags;
      v_flags  := 0;
      v_streak := 1;
      v_broke  := true;
    end if;
  end if;

  -- Nagrada za dolazak SAMO ako niz stoji — reset i nagrada u istom potezu su
  -- korisniku izgledali kao bug. Prvi glas ikad nije puknuće i nosi zastavicu.
  if not v_broke then
    v_flags := least(2, v_flags + 1);
  end if;

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
