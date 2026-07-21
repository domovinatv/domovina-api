-- =============================================================================
-- Mjesta (slots) — generički sloj za rezervaciju pojedinačno birljivih mjesta
--
-- Motivacija: donacijski grid 120×120 (kvadratić = doprinos, skuplje prema
-- središtu) i prodaja NUMERIRANIH ulaznica (konferencija, utakmica, koncert)
-- su isti tehnički problem: fiksan skup jedinstveno identificiranih mjesta,
-- pojedinačno birljivih, s atomarnim holdom preko ASINKRONE uplate.
--
-- Postojeći ticketing (20260716120000/…200) zna samo za KOLIČINE
-- (campaign_tiers.inventory_total/claimed); serial se dodjeljuje tek pri
-- izdavanju, a unit='seat' je puki natpis. Numerirano sjedalo ne postoji.
-- Ova migracija gradi taj sloj jednom; grid mu je prvi potrošač.
--
--   1. slot_maps   — jedna mapa po kampanji (kind grid|seatmap, politika sudara)
--   2. slot_zones  — cjenovni razredi (grid = koncentrični prstenovi, seatmap
--                    = sektori)
--   3. slots       — pojedinačno mjesto, PRE-SEEDANO u state='free'
--
-- KLJUČNA ODLUKA — mjesta se seedaju unaprijed. 14.400 redova po kampanji je
-- za Postgres trivijalno (~2 MB), a nosi tri stvari koje inače koštaju:
--   (a) rezervacija je JEDAN `update … where` — row lock i provjera u istoj
--       naredbi, isti obrazac kao 20260716120200:408-416. Bez insert/on-conflict
--       krađe, bez TOCTOU prozora, bez advisory lockova.
--   (b) "slobodno" je red u bazi, a ne ODSUTNOST reda → render i brojanje su
--       obični upiti.
--   (c) seat mapa ionako mora biti pre-seedana (sjedala fizički postoje, s
--       rupama za prolaze) → pre-seed je zajednički imenitelj, ne kompromis.
--
-- ISTEKLI HOLD NIJE ZASEBNO STANJE. Red ostaje 'held' s prošlim
-- hold_expires_at i tretira se kao slobodan na dva mjesta: u `where` klauzuli
-- rezervacije i u javnom viewu. Ispravnost time NE OVISI ni o jednom cronu.
-- (Partial unique s now() nije opcija — now() nije IMMUTABLE.)
--
-- NFT-ready od prvog dana: token_id je determinističan (grid = y*side + x,
-- seatmap = redni broj) i nepromjenjiv. Mint je faza 2 — kolone
-- onchain_token_address / token_uri / mint_tx_hash / minted_at stoje prazne.
-- Vidi docs/pinka-onchain-receipts-tokenization-plan.md.
--
-- TRI HAZARDA koja ova migracija rješava eksplicitno:
--   H1 TTL vs SEPA  — hold i rail intent umiru istovremeno po konstrukciji
--                     (attach_intent produžuje hold na intent.expires_at).
--   H2 kasna uplata — mark_contribution_paid prihvaća i 'expired'/'failed';
--                     claim_slots_for_contribution vraća/preseli mjesto.
--   H3 bez crona    — view + `where` klauzula nose ispravnost; žetva je higijena.
-- =============================================================================

-- ----- enumi -----------------------------------------------------------------
do $$ begin
  create type pinka_finance.slot_state as enum ('free','blocked','held','sold','minted');
exception when duplicate_object then null; end $$;

do $$ begin
  create type pinka_finance.slot_map_kind as enum ('grid','seatmap');
exception when duplicate_object then null; end $$;

-- Što s mjestom kad novac stigne a mjesto je izgubljeno:
--   relocate_same_or_better — grid: kupcu je svejedno koji točno piksel
--   flag_for_refund         — seatmap: sjedalo je obećanje, ne seli se tiho
do $$ begin
  create type pinka_finance.slot_conflict_policy as enum
    ('relocate_same_or_better','flag_for_refund');
exception when duplicate_object then null; end $$;

-- ----- 1. mape ---------------------------------------------------------------
create table if not exists pinka_finance.slot_maps (
  id          uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  kind        pinka_finance.slot_map_kind not null,
  width       smallint not null,
  height      smallint not null,
  conflict_policy pinka_finance.slot_conflict_policy not null,
  -- Provizorni TTL u create_contribution; attach_intent ga produžuje na
  -- stvarni vijek rail intenta (H1).
  hold_ttl_seconds      integer  not null default 600,
  -- Anti-grief: koliko mjesta jedna sesija smije držati neplaćeno.
  max_holds_per_session smallint not null default 9,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint slot_maps_dims check (width between 1 and 500 and height between 1 and 500),
  constraint slot_maps_ttl  check (hold_ttl_seconds between 60 and 86400),
  constraint slot_maps_holds check (max_holds_per_session between 1 and 200),
  -- MVP: jedna mapa po kampanji. Višednevni festival s više dvorana bi tražio
  -- ukidanje ovog uniquea + map_id u odabiru.
  unique (campaign_id)
);

drop trigger if exists trg_slot_maps_updated on pinka_finance.slot_maps;
create trigger trg_slot_maps_updated
  before update on pinka_finance.slot_maps
  for each row execute function public.touch_updated_at();

-- ----- 2. cjenovne zone ------------------------------------------------------
create table if not exists pinka_finance.slot_zones (
  id          uuid primary key default gen_random_uuid(),
  map_id      uuid not null references pinka_finance.slot_maps(id) on delete cascade,
  -- 0 = najjeftinija (vanjski rub / zadnji red). Veći indeks = skuplje.
  -- Relokacija smije ići samo na zone_index >= traženog (nikad jeftinije).
  zone_index  smallint not null,
  price_cents integer  not null,
  -- ARB ključ, ne tekst — prijevod ostaje na klijentu (i18n pravilo repoa).
  label_key   text,
  created_at  timestamptz not null default now(),
  constraint slot_zones_price check (price_cents > 0),
  constraint slot_zones_index check (zone_index >= 0),
  unique (map_id, zone_index)
);

-- ----- 3. mjesta -------------------------------------------------------------
create table if not exists pinka_finance.slots (
  id       uuid primary key default gen_random_uuid(),
  map_id   uuid not null references pinka_finance.slot_maps(id) on delete cascade,
  zone_id  uuid not null references pinka_finance.slot_zones(id) on delete restrict,

  -- Kanonski identitet mjesta. grid: '60:60' | seatmap: 'A:12:7'
  slot_key text not null,
  -- Ono što korisnik vidi: 'Sektor A, red 12, sjedalo 7'. Grid ga ne treba.
  label    text,
  -- Koordinate za crtanje. Grid i seatmap su oboje 2D mape.
  pos_x    smallint not null,
  pos_y    smallint not null,
  -- NFT (faza 2): grid = y*side + x, seatmap = redni broj. Nepromjenjiv.
  token_id integer  not null,

  state    pinka_finance.slot_state not null default 'free',
  contribution_id   uuid references pinka_finance.contributions(id) on delete set null,
  holder_account_id uuid references public.accounts(id) on delete set null,
  holder_address    text,
  -- Snapshot cijene zone u trenutku prodaje (zona može poskupjeti poslije).
  price_cents integer not null,

  hold_session_key text,
  hold_expires_at  timestamptz,

  onchain_token_address text,
  onchain_chain_id      integer,
  token_uri             text,
  mint_tx_hash          text,
  minted_at             timestamptz,

  -- Trag automatske selidbe (H2, grana relocate_same_or_better).
  relocated_from_slot_key text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint slots_price check (price_cents > 0),
  constraint slots_holder_addr check (
    holder_address is null or holder_address ~ '^0x[0-9a-fA-F]{40}$'),
  -- 'held' MORA imati rok; sva ostala stanja ga NE SMIJU imati. Time je
  -- "istekli hold" jedini mogući oblik zombija, i on je namjerno dopušten.
  constraint slots_hold_ttl check (
    (state = 'held'  and hold_expires_at is not null) or
    (state <> 'held' and hold_expires_at is null))
);

-- ★ IDENTITET MJESTA. Sve pretrage i sve rezervacije idu ovuda.
create unique index if not exists ux_slots_map_key
  on pinka_finance.slots(map_id, slot_key);

-- Invarijanta za mint u fazi 2: token_id je jedinstven unutar mape.
create unique index if not exists ux_slots_map_token
  on pinka_finance.slots(map_id, token_id);

-- Render mape jednim scanom.
create index if not exists ix_slots_map_state
  on pinka_finance.slots(map_id, state);

-- Žetva isteklih holdova — zrcalo ix_contributions_reservation_expiry
-- (20260716120000:113-115).
create index if not exists ix_slots_hold_expiry
  on pinka_finance.slots(hold_expires_at) where state = 'held';

-- "Moja mjesta" + H2 lookup po doprinosu.
create index if not exists ix_slots_contribution
  on pinka_finance.slots(contribution_id) where contribution_id is not null;

-- Anti-grief brojanje aktivnih holdova po sesiji.
create index if not exists ix_slots_session
  on pinka_finance.slots(hold_session_key, hold_expires_at) where state = 'held';

drop trigger if exists trg_slots_updated on pinka_finance.slots;
create trigger trg_slots_updated
  before update on pinka_finance.slots
  for each row execute function public.touch_updated_at();

comment on table pinka_finance.slots is
  'Pojedinačno birljivo mjesto (grid kvadratić ili numerirano sjedalo). '
  'PRE-SEEDANO u state=''free''. Istekli hold ostaje ''held'' s prošlim '
  'hold_expires_at i tretira se kao slobodan u where-klauzulama i javnom viewu '
  '— ispravnost ne ovisi o cronu. token_id je NFT-ready i nepromjenjiv.';

-- ----- 4. doprinosi: nepromjenjiv zapis namjere -------------------------------
-- Preživi žetvu holda. Bez toga kasna uplata (H2) ne zna što je korisnik htio.
alter table pinka_finance.contributions
  add column if not exists desired_slot_keys text[],
  add column if not exists slot_unassigned    boolean not null default false;

comment on column pinka_finance.contributions.desired_slot_keys is
  'Što je korisnik izabrao. Nepromjenjivo — hold može isteći, namjera ne.';
comment on column pinka_finance.contributions.slot_unassigned is
  'Novac primljen, mjesto nije dodijeljeno (mapa puna ili flag_for_refund). '
  'Red za ručni follow-up / povrat.';

-- Veza ulaznice na mjesto (faza sjedala; sad samo stoji).
alter table pinka_finance.tickets
  add column if not exists slot_id uuid references pinka_finance.slots(id) on delete set null;

-- ----- 5. javni view ---------------------------------------------------------
-- Obrazac iz public_contributions (20260603120000:118-138): security_invoker
-- off + grant anon, jer anon NEMA pristup contributions (20260530120200:32).
create or replace view pinka_finance.public_slots as
  select
    m.campaign_id,
    s.map_id,
    s.slot_key,
    s.label,
    s.pos_x,
    s.pos_y,
    s.token_id,
    z.zone_index,
    s.price_cents,
    -- ★ H3 sloj 1: istekli hold je slobodan ISTOG TRENUTKA, bez ijednog joba.
    case when s.state = 'held' and s.hold_expires_at <= now() then 'free'
         else s.state::text end as state,
    -- Hold NE OTKRIVA NIŠTA — ni ime, ni iznos, ni poruku. Inače je besplatan
    -- hold vektor za oglašavanje bez plaćanja.
    case when s.state in ('sold','minted') then nullif(ct.display_name, '') end as display_name,
    case when s.state in ('sold','minted') and not coalesce(ct.message_hidden, false)
         then ct.message end as message,
    case when s.state in ('sold','minted')
         then coalesce(ct.contributor_verified and ct.display_name_verified, false)
         else false end as verified,
    s.minted_at,
    s.onchain_token_address
  from pinka_finance.slots s
  join pinka_finance.slot_zones z on z.id = s.zone_id
  join pinka_finance.slot_maps  m on m.id = s.map_id
  join pinka_finance.campaigns  c on c.id = m.campaign_id
  left join pinka_finance.contributions ct
    on ct.id = s.contribution_id and ct.anonymous = false
 where c.deleted_at is null
   and c.visibility = 'public'
   and c.state in ('active','funded','closed');

alter view pinka_finance.public_slots set (security_invoker = off);
grant select on pinka_finance.public_slots to anon, authenticated, service_role;

-- ----- 6. RLS ----------------------------------------------------------------
alter table pinka_finance.slot_maps  enable row level security;
alter table pinka_finance.slot_zones enable row level security;
alter table pinka_finance.slots      enable row level security;

grant select on pinka_finance.slot_maps, pinka_finance.slot_zones, pinka_finance.slots
  to anon, authenticated;
grant select, insert, update, delete
  on pinka_finance.slot_maps, pinka_finance.slot_zones, pinka_finance.slots
  to service_role;

drop policy if exists slot_maps_select on pinka_finance.slot_maps;
create policy slot_maps_select on pinka_finance.slot_maps
  for select to anon, authenticated
  using (exists (
    select 1 from pinka_finance.campaigns c
     where c.id = campaign_id and c.deleted_at is null
       and c.visibility in ('public','unlisted')
       and c.state in ('active','funded','closed')));

drop policy if exists slot_zones_select on pinka_finance.slot_zones;
create policy slot_zones_select on pinka_finance.slot_zones
  for select to anon, authenticated
  using (exists (
    select 1 from pinka_finance.slot_maps m
      join pinka_finance.campaigns c on c.id = m.campaign_id
     where m.id = map_id and c.deleted_at is null
       and c.visibility in ('public','unlisted')
       and c.state in ('active','funded','closed')));

-- Direktan select na slots (za budući Realtime — dvoje ljudi klikću isto
-- mjesto). Pisanje ISKLJUČIVO kroz security-definer RPC: nema write policy,
-- dosljedno contributions modelu (20260530120200:118-126).
drop policy if exists slots_select on pinka_finance.slots;
create policy slots_select on pinka_finance.slots
  for select to anon, authenticated
  using (exists (
    select 1 from pinka_finance.slot_maps m
      join pinka_finance.campaigns c on c.id = m.campaign_id
     where m.id = map_id and c.deleted_at is null
       and c.visibility in ('public','unlisted')
       and c.state in ('active','funded','closed')));

-- ----- 7. seed: grid ---------------------------------------------------------
-- Zona ćelije = udaljenost od najbližeg ruba, mapirana na prsten. Cijene su
-- default 1 €…1000 € u geometrijskoj progresiji; donjih pet se poklapa s
-- preset čipovima u pinka_contribute_panel.dart (_presetsCents).
create or replace function pinka_finance.seed_grid_map(
  p_campaign_id uuid,
  p_side        integer default 120,
  p_prices      integer[] default array[100,200,500,1000,2000,5000,10000,20000,50000,100000]
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_map    uuid;
  v_zones  integer := array_length(p_prices, 1);
  v_band   numeric;
begin
  if v_zones is null or v_zones < 1 then raise exception 'no_prices'; end if;
  if p_side < 2 then raise exception 'side_too_small'; end if;

  insert into pinka_finance.slot_maps (campaign_id, kind, width, height, conflict_policy)
  values (p_campaign_id, 'grid', p_side, p_side, 'relocate_same_or_better')
  returning id into v_map;

  -- zone_index 0 = vanjski rub (najjeftinije) … v_zones-1 = jezgra
  insert into pinka_finance.slot_zones (map_id, zone_index, price_cents, label_key)
  select v_map, i - 1, p_prices[i], 'pinkaSlotZone' || (i - 1)::text
    from generate_series(1, v_zones) i;

  -- Debljina prstena u ćelijama. Maksimalna udaljenost od ruba je floor(side/2).
  v_band := (p_side / 2.0) / v_zones;

  insert into pinka_finance.slots (map_id, zone_id, slot_key, pos_x, pos_y, token_id, price_cents)
  select
    v_map,
    z.id,
    x || ':' || y,
    x, y,
    y * p_side + x,
    z.price_cents
  from generate_series(0, p_side - 1) x
  cross join generate_series(0, p_side - 1) y
  cross join lateral (
    select zz.id, zz.price_cents
      from pinka_finance.slot_zones zz
     where zz.map_id = v_map
       -- floor(), NE ::integer — cast u Postgresu ZAOKRUŽUJE, pa bi ćelija na
       -- pola prstena pobjegla u sljedeću zonu (layer 3 / band 6 = 0.5 → 1).
       and zz.zone_index = least(
             floor(least(x, y, p_side - 1 - x, p_side - 1 - y)::numeric / v_band)::integer,
             v_zones - 1)
  ) z;

  return v_map;
end;
$$;
revoke execute on function pinka_finance.seed_grid_map(uuid,integer,integer[]) from public, anon, authenticated;
grant  execute on function pinka_finance.seed_grid_map(uuid,integer,integer[]) to service_role;

-- ----- 8. seed: seatmap ------------------------------------------------------
-- p_layout: {"conflict_policy":"flag_for_refund",
--            "zones":[{"index":0,"price_cents":1500,"label_key":"…"}, …],
--            "seats":[{"key":"A:12:7","label":"Sektor A, red 12, sj. 7",
--                      "x":10,"y":4,"zone":0,"blocked":false}, …]}
create or replace function pinka_finance.seed_seatmap(
  p_campaign_id uuid,
  p_layout      jsonb
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_map uuid;
  v_w   integer;
  v_h   integer;
begin
  select coalesce(max((s->>'x')::int), 0) + 1, coalesce(max((s->>'y')::int), 0) + 1
    into v_w, v_h
    from jsonb_array_elements(p_layout->'seats') s;

  insert into pinka_finance.slot_maps (campaign_id, kind, width, height, conflict_policy)
  values (p_campaign_id, 'seatmap', v_w, v_h,
          coalesce((p_layout->>'conflict_policy')::pinka_finance.slot_conflict_policy,
                   'flag_for_refund'))
  returning id into v_map;

  insert into pinka_finance.slot_zones (map_id, zone_index, price_cents, label_key)
  select v_map, (z->>'index')::smallint, (z->>'price_cents')::integer, z->>'label_key'
    from jsonb_array_elements(p_layout->'zones') z;

  insert into pinka_finance.slots
    (map_id, zone_id, slot_key, label, pos_x, pos_y, token_id, price_cents, state)
  select
    v_map, zz.id,
    s->>'key', s->>'label',
    (s->>'x')::smallint, (s->>'y')::smallint,
    (row_number() over (order by s->>'key'))::integer - 1,
    zz.price_cents,
    case when coalesce((s->>'blocked')::boolean, false) then 'blocked'::pinka_finance.slot_state
         else 'free'::pinka_finance.slot_state end
  from jsonb_array_elements(p_layout->'seats') s
  join pinka_finance.slot_zones zz
    on zz.map_id = v_map and zz.zone_index = (s->>'zone')::smallint;

  return v_map;
end;
$$;
revoke execute on function pinka_finance.seed_seatmap(uuid,jsonb) from public, anon, authenticated;
grant  execute on function pinka_finance.seed_seatmap(uuid,jsonb) to service_role;

-- ----- 9. žetva isteklih holdova (H3, sloj 3 — HIGIJENA, ne ispravnost) -------
create or replace function pinka_finance.expire_stale_slot_holds()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  update pinka_finance.slots
     set state = 'free',
         contribution_id = null,
         holder_account_id = null,
         hold_session_key = null,
         hold_expires_at = null,
         updated_at = now()
   where state = 'held'
     and hold_expires_at is not null
     -- Grace: dok red postoji, claim_slots_for_contribution ga može jeftino
     -- vratiti kasnoj uplati (H2, grana 'reclaimed').
     and hold_expires_at < now() - interval '24 hours';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function pinka_finance.expire_stale_slot_holds() from public, anon, authenticated;
grant  execute on function pinka_finance.expire_stale_slot_holds() to service_role;

-- pg_cron (opcionalno; ispravnost NE ovisi o ovome):
--   select cron.schedule('pinka-slot-holds', '*/15 * * * *',
--     $$select pinka_finance.expire_stale_slot_holds()$$);

-- ----- 10. otpuštanje holdova jednog doprinosa -------------------------------
create or replace function pinka_finance.release_slot_holds(p_contribution_id uuid)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_n integer;
begin
  update pinka_finance.slots
     set state = 'free', contribution_id = null, holder_account_id = null,
         hold_session_key = null, hold_expires_at = null, updated_at = now()
   where contribution_id = p_contribution_id and state = 'held';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function pinka_finance.release_slot_holds(uuid) from public, anon, authenticated;
grant  execute on function pinka_finance.release_slot_holds(uuid) to service_role;

-- ----- 11. rezervacija -------------------------------------------------------
-- All-or-nothing. Zove se UNUTAR create_contribution (ista transakcija) —
-- zaseban klijentski poziv bi ostavio prozor u kojem doprinos živi bez mjesta.
create or replace function pinka_finance.reserve_slots(
  p_contribution_id uuid,
  p_slot_keys       text[],
  p_ttl_seconds     integer default null
) returns bigint
language plpgsql security definer set search_path = ''
as $$
declare
  v_c        pinka_finance.contributions;
  v_map      pinka_finance.slot_maps;
  v_keys     text[];
  v_key      text;
  v_session  text;
  v_held     integer;
  v_ttl      integer;
  v_total    bigint := 0;
  v_price    integer;
begin
  select * into v_c from pinka_finance.contributions where id = p_contribution_id;
  if not found then raise exception 'contribution_not_found'; end if;

  select * into v_map from pinka_finance.slot_maps where campaign_id = v_c.campaign_id;
  if not found then raise exception 'no_slot_map'; end if;

  -- ★ DETERMINISTIČKI REDOSLIJED ZAKLJUČAVANJA.
  -- Dvije istovremene rezervacije s preklapajućim skupovima ({A,B} i {B,A})
  -- zaključavaju redove obrnutim redoslijedom i DEADLOCKAJU. Sortiranje po
  -- slot_key to isključuje. Bez ovoga se bug pojavi tek pod opterećenjem.
  select array_agg(k order by k) into v_keys
    from unnest(p_slot_keys) k where k is not null;
  if v_keys is null or array_length(v_keys, 1) = 0 then
    raise exception 'no_slots_requested';
  end if;

  v_ttl := coalesce(p_ttl_seconds, v_map.hold_ttl_seconds);
  v_session := coalesce((select auth.uid())::text, 'c:' || p_contribution_id::text);

  -- Anti-grief (obrazac rate limita iz 20260716120200).
  select count(*) into v_held
    from pinka_finance.slots
   where hold_session_key = v_session and state = 'held' and hold_expires_at > now();
  if v_held + array_length(v_keys, 1) > v_map.max_holds_per_session then
    raise exception 'too_many_holds';
  end if;

  foreach v_key in array v_keys loop
    -- ★★ ATOMARNA REZERVACIJA, JEDNA NAREDBA.
    -- Row lock i provjera dostupnosti zajedno; drugi pisac čeka pa vidi
    -- ažurirani red i ne prolazi. Istekli hold se preuzima in-place (H3 sloj 2).
    update pinka_finance.slots s
       set state = 'held',
           contribution_id = p_contribution_id,
           holder_account_id = v_c.contributor_account_id,
           hold_session_key = v_session,
           hold_expires_at = now() + make_interval(secs => v_ttl),
           price_cents = z.price_cents,
           relocated_from_slot_key = null,
           updated_at = now()
      from pinka_finance.slot_zones z
     where s.map_id = v_map.id
       and s.slot_key = v_key
       and z.id = s.zone_id
       and (s.state = 'free'
            or (s.state = 'held' and s.hold_expires_at <= now()))
     returning s.price_cents into v_price;

    if not found then
      -- Rollback CIJELE transakcije, uključujući doprinos. Ispravno: korisnik
      -- još nije platio, pa je poništenje intenta točno ponašanje.
      raise exception 'slot_taken:%', v_key;
    end if;

    v_total := v_total + v_price;
  end loop;

  -- ★ CIJENU ODREĐUJE SERVER. Klijent ne smije tvrditi da je jezgra 1 €.
  if v_c.amount_cents < v_total then
    raise exception 'amount_below_slot_price:%', v_total;
  end if;

  update pinka_finance.contributions
     set desired_slot_keys = v_keys, updated_at = now()
   where id = p_contribution_id;

  return v_total;
end;
$$;
revoke execute on function pinka_finance.reserve_slots(uuid,text[],integer) from public, anon, authenticated;
grant  execute on function pinka_finance.reserve_slots(uuid,text[],integer) to service_role;

-- ----- 12. create_contribution — proširenje na mjesta ------------------------
-- GOTCHA: defaultirani parametri stvaraju NOVI overload; stari ostaje i
-- PostgREST baca PGRST203 (ambiguous). Zato drop stare signature prvo —
-- isti potez kao 20260605130000:90. Nakon migracije: notify pgrst, 'reload schema'.
drop function if exists pinka_finance.create_contribution(uuid,bigint,uuid,text,text,boolean,integer);

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

-- ----- 13. attach_intent — H1: hold živi točno koliko i intent ---------------
drop function if exists pinka_finance.attach_intent(uuid,text,text);

create or replace function pinka_finance.attach_intent(
  p_contribution_id   uuid,
  p_sid               text,
  p_monerium_order_id text        default null,
  p_hold_expires_at   timestamptz default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update pinka_finance.contributions
     set payment_intent_sid = coalesce(p_sid, payment_intent_sid),
         monerium_order_id  = coalesce(p_monerium_order_id, monerium_order_id),
         updated_at = now()
   where id = p_contribution_id;

  if p_hold_expires_at is not null then
    update pinka_finance.slots
       set hold_expires_at = greatest(
             hold_expires_at,
             -- Rail hard cap je 24 h (pay.domovina.ai api.ts:37) — držati hold
             -- duže nego što intent živi nema smisla.
             least(p_hold_expires_at, now() + interval '24 hours')),
           updated_at = now()
     where contribution_id = p_contribution_id and state = 'held';
  end if;
end;
$$;
revoke execute on function pinka_finance.attach_intent(uuid,text,text,timestamptz) from public, anon, authenticated;
grant  execute on function pinka_finance.attach_intent(uuid,text,text,timestamptz) to service_role;

-- ----- 14. claim: dodjela mjesta na uplatu (H2) ------------------------------
-- Zove se ISKLJUČIVO iz tg_contribution_state na prijelaz u 'paid'.
-- NIKAD ne raise-a — exception bi rollbackao uplatu.
create or replace function pinka_finance.claim_slots_for_contribution(p_contribution_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_c       pinka_finance.contributions;
  v_map     pinka_finance.slot_maps;
  v_key     text;
  v_zone    smallint;
  v_x       smallint;
  v_y       smallint;
  v_new     text;
  v_out     jsonb := '[]'::jsonb;
  v_ok      boolean;
begin
  select * into v_c from pinka_finance.contributions where id = p_contribution_id;
  if not found or v_c.desired_slot_keys is null then
    return jsonb_build_object('outcome', 'none');
  end if;

  select * into v_map from pinka_finance.slot_maps where campaign_id = v_c.campaign_id;
  if not found then return jsonb_build_object('outcome', 'no_map'); end if;

  foreach v_key in array v_c.desired_slot_keys loop
    -- (1) naš hold još stoji → promoviraj u 'sold'
    update pinka_finance.slots
       set state = 'sold', hold_expires_at = null, hold_session_key = null,
           updated_at = now()
     where map_id = v_map.id and slot_key = v_key
       and contribution_id = p_contribution_id and state = 'held';
    if found then
      v_out := v_out || jsonb_build_object('slot_key', v_key, 'outcome', 'kept');
      continue;
    end if;

    -- (1b) već 'sold'/'minted' nama → idempotentno (webhook retry)
    if exists (select 1 from pinka_finance.slots
                where map_id = v_map.id and slot_key = v_key
                  and contribution_id = p_contribution_id
                  and state in ('sold','minted')) then
      v_out := v_out || jsonb_build_object('slot_key', v_key, 'outcome', 'kept');
      continue;
    end if;

    -- (2) hold istekao ali mjesto još slobodno → vrati ga
    update pinka_finance.slots
       set state = 'sold', contribution_id = p_contribution_id,
           holder_account_id = v_c.contributor_account_id,
           hold_session_key = null, hold_expires_at = null, updated_at = now()
     where map_id = v_map.id and slot_key = v_key
       and (state = 'free' or (state = 'held' and hold_expires_at <= now()));
    if found then
      v_out := v_out || jsonb_build_object('slot_key', v_key, 'outcome', 'reclaimed');
      continue;
    end if;

    -- (3) netko drugi ga je uzeo → politika mape odlučuje
    if v_map.conflict_policy = 'flag_for_refund' then
      -- Sjedalo je obećanje. Ne seli se tiho — ide u red za povrat.
      v_out := v_out || jsonb_build_object('slot_key', v_key, 'outcome', 'lost');
      update pinka_finance.contributions set slot_unassigned = true, updated_at = now()
       where id = p_contribution_id;
      insert into pinka_finance.contribution_events
        (contribution_id, campaign_id, event_type, payload)
      values (p_contribution_id, v_c.campaign_id, 'slot.lost',
              jsonb_build_object('slot_key', v_key));
      continue;
    end if;

    -- relocate_same_or_better: najbliže slobodno mjesto u ISTOJ ili SKUPLJOJ
    -- zoni. Nikad jeftinije — cijena te zone je već plaćena.
    select z.zone_index, s.pos_x, s.pos_y into v_zone, v_x, v_y
      from pinka_finance.slots s join pinka_finance.slot_zones z on z.id = s.zone_id
     where s.map_id = v_map.id and s.slot_key = v_key;

    v_ok := false;
    for v_new in
      select s.slot_key
        from pinka_finance.slots s join pinka_finance.slot_zones z on z.id = s.zone_id
       where s.map_id = v_map.id
         and z.zone_index >= v_zone
         and (s.state = 'free' or (s.state = 'held' and s.hold_expires_at <= now()))
       order by (s.pos_x - v_x) * (s.pos_x - v_x) + (s.pos_y - v_y) * (s.pos_y - v_y)
       limit 25
    loop
      update pinka_finance.slots
         set state = 'sold', contribution_id = p_contribution_id,
             holder_account_id = v_c.contributor_account_id,
             hold_session_key = null, hold_expires_at = null,
             relocated_from_slot_key = v_key, updated_at = now()
       where map_id = v_map.id and slot_key = v_new
         and (state = 'free' or (state = 'held' and hold_expires_at <= now()));
      if found then v_ok := true; exit; end if;
      -- utrka: netko nam je preoteo i zamjenu → sljedeći kandidat
    end loop;

    if v_ok then
      v_out := v_out || jsonb_build_object('slot_key', v_new, 'outcome', 'relocated',
                                           'from', v_key);
      insert into pinka_finance.contribution_events
        (contribution_id, campaign_id, event_type, payload)
      values (p_contribution_id, v_c.campaign_id, 'slot.relocated',
              jsonb_build_object('from', v_key, 'to', v_new));
    else
      -- (4) mapa puna → novac ostaje primljen, mjesto se ne dodjeljuje
      v_out := v_out || jsonb_build_object('slot_key', v_key, 'outcome', 'unassigned');
      update pinka_finance.contributions set slot_unassigned = true, updated_at = now()
       where id = p_contribution_id;
      insert into pinka_finance.contribution_events
        (contribution_id, campaign_id, event_type, payload)
      values (p_contribution_id, v_c.campaign_id, 'slot.unassigned',
              jsonb_build_object('slot_key', v_key));
    end if;
  end loop;

  return jsonb_build_object('outcome', 'done', 'slots', v_out);
end;
$$;
revoke execute on function pinka_finance.claim_slots_for_contribution(uuid) from public, anon, authenticated;
grant  execute on function pinka_finance.claim_slots_for_contribution(uuid) to service_role;

-- ----- 15. mark_contribution_paid — prihvati KASNU uplatu (H2) ---------------
-- ★ NAJVAŽNIJA IZMJENA. Prije: `and state = 'pending'`. Novac je na Safeu;
-- odbiti ga zato što je istekao NAŠ INTERNI timer je najgori mogući ishod —
-- korisnik ostaje bez mjesta i bez potvrde. 'paid' i 'refunded' ostaju
-- isključeni pa idempotencija (v_updated > 0) preživi.
create or replace function pinka_finance.mark_contribution_paid(
  p_sid                   text,
  p_tx_hash               text,
  p_amount_received_cents bigint default null,
  p_sender_iban           text   default null,
  p_sender_name           text   default null,
  p_key                   text   default null
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  v_updated integer;
  v_named   boolean := p_sender_name is not null and btrim(p_sender_name) <> '';
begin
  update pinka_finance.contributions
     set state                    = 'paid',
         forward_tx_hash          = p_tx_hash,
         amount_received_cents    = coalesce(p_amount_received_cents, amount_received_cents, amount_cents),
         bank_verified            = v_named,
         identity_double_verified = v_named
           and pinka_finance.sepa_name_matches_identity(contributor_account_id, p_sender_name),
         payer_iban_hash          = case
           when p_sender_iban is not null and p_key is not null
           then encode(extensions.hmac(upper(regexp_replace(p_sender_iban, '\s', '', 'g')), p_key, 'sha256'), 'hex')
           else payer_iban_hash end,
         paid_at                  = now(),
         updated_at               = now()
   where payment_intent_sid = p_sid
     and state in ('pending', 'expired', 'failed');
  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;
revoke execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) to service_role;

-- ----- 16. tg_contribution_state — mjesta + regresija ulaznica ---------------
-- Nasljeđuje ŽIVU verziju iz 20260721120000:25-120 (ne stariju iz 20260716120200).
create or replace function pinka_finance.tg_contribution_state() returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_total bigint;
  v_count integer;
  v_contributors integer;
begin
  if new.state = old.state then
    return new;
  end if;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (
    new.id, new.campaign_id, 'contribution.' || new.state::text,
    jsonb_build_object(
      'from', old.state::text,
      'tx_hash', new.forward_tx_hash,
      'amount_received_cents', new.amount_received_cents
    )
  );

  -- ulaznice: istek pending narudžbe vraća rezervirani inventory
  if new.state = 'expired' and old.state = 'pending' and new.reserved and new.tier_id is not null then
    update pinka_finance.campaign_tiers
       set inventory_claimed = greatest(inventory_claimed - new.quantity, 0),
           updated_at = now()
     where id = new.tier_id;
  end if;

  if new.state = 'paid' then
    -- tier inventory (rezervirane ticket narudžbe su već ubrojane na create)
    if new.tier_id is not null and not new.reserved then
      update pinka_finance.campaign_tiers
         set inventory_claimed = inventory_claimed + new.quantity,
             updated_at = now()
       where id = new.tier_id;
    end if;

    -- ★ REGRESIJA KOJU OTVARA §15: sad je moguć prijelaz expired→paid. Za
    -- rezerviranu ticket narudžbu inventory je već VRAĆEN na expire, a gornja
    -- grana ga neće ponovno uzeti (traži `not new.reserved`) → tihi oversell.
    if old.state = 'expired' and new.reserved and new.tier_id is not null then
      update pinka_finance.campaign_tiers
         set inventory_claimed = inventory_claimed + new.quantity,
             updated_at = now()
       where id = new.tier_id;
    end if;

    -- autoritativni agregat (re-sum, ne inkrement — robusno na refundove)
    select coalesce(sum(amount_cents), 0), count(*)
      into v_total, v_count
      from pinka_finance.contributions
     where campaign_id = new.campaign_id and state = 'paid';

    select count(distinct coalesce(
             contributor_account_id::text,
             nullif(lower(onchain_from), ''),
             payer_iban_hash,
             id::text
           ))
      into v_contributors
      from pinka_finance.contributions
     where campaign_id = new.campaign_id and state = 'paid';

    insert into pinka_finance.campaign_stats (
      campaign_id, total_raised_cents, contribution_count,
      contributor_count, last_contribution_at, updated_at
    ) values (
      new.campaign_id, v_total, v_count, v_contributors, now(), now()
    )
    on conflict (campaign_id) do update set
      total_raised_cents   = excluded.total_raised_cents,
      contribution_count   = excluded.contribution_count,
      contributor_count    = excluded.contributor_count,
      last_contribution_at = excluded.last_contribution_at,
      updated_at           = now();

    update pinka_finance.campaigns
       set state = 'funded'
     where id = new.campaign_id
       and goal_cents is not null
       and state = 'active'
       and v_total >= goal_cents;

    if exists (
      select 1 from pinka_finance.campaigns c
      where c.id = new.campaign_id and c.type = 'tokenization'
    ) then
      insert into pinka_finance.token_positions (
        campaign_id, contribution_id, holder_account_id, units, status
      ) values (
        new.campaign_id, new.id, new.contributor_account_id,
        coalesce(new.amount_received_cents, new.amount_cents), 'pending'
      )
      on conflict (contribution_id) do nothing;
    end if;

    -- ★ MJESTA. Exception ovdje bi rollbackao CIJELU uplatu — nikad.
    -- Poslovni neuspjeh je podatak (event), ne exception. Isti princip kao
    -- confirm_ticket_order u 20260716120200.
    if new.desired_slot_keys is not null then
      begin
        perform pinka_finance.claim_slots_for_contribution(new.id);
      exception when others then
        insert into pinka_finance.contribution_events
          (contribution_id, campaign_id, event_type, payload)
        values (new.id, new.campaign_id, 'slot.claim_failed',
                jsonb_build_object('error', sqlerrm));
      end;
    end if;
  end if;

  -- refund oslobađa mjesta — inače refundirana donacija zauvijek drži kvadratić
  if new.state = 'refunded' and old.state = 'paid' then
    update pinka_finance.slots
       set state = 'free', contribution_id = null, holder_account_id = null,
           hold_session_key = null, hold_expires_at = null, updated_at = now()
     where contribution_id = new.id and state = 'sold';
  end if;

  return new;
end;
$$;

-- ----- 17. on-chain put: veži uplatu uz POSTOJEĆI doprinos -------------------
-- Rupa koju zatvara: record_onchain_contribution (20260602140000:24-58) uvijek
-- INSERTA NOVI doprinos. Za mjesta to znači — korisnik izabere kvadratić (hold
-- nastane uz pending doprinos), plati in-app novčanikom, a confirm napravi
-- DRUGI doprinos bez mjesta → hold istekne, korisnik je platio i nije dobio
-- ništa. Ova funkcija umjesto toga kreditira konkretan pending doprinos.
--
-- Dijeli isti idempotency ključ (forward_tx_hash, onchain_log_index) kao
-- record_onchain_contribution, pa se dva puta nikad ne dupliraju.
create or replace function pinka_finance.confirm_slot_contribution(
  p_campaign_id     uuid,
  p_contribution_id uuid,
  p_tx_hash         text,
  p_log_index       integer,
  p_from            text,
  p_amount_cents    bigint
) returns table (contribution_id uuid, credited boolean)
language plpgsql security definer set search_path = ''
as $$
declare
  v_id  uuid;
  v_c   pinka_finance.contributions;
  v_n   integer;
begin
  -- idempotencija: taj (tx, log) je već negdje proknjižen
  select id into v_id
    from pinka_finance.contributions
   where forward_tx_hash = p_tx_hash and onchain_log_index = p_log_index;
  if found then
    return query select v_id, false;
    return;
  end if;

  select * into v_c from pinka_finance.contributions where id = p_contribution_id;
  if not found then raise exception 'contribution_not_found'; end if;
  -- doprinos MORA pripadati kampanji čiju je destination_address edge funkcija
  -- verificirala u Transfer logu — inače bi se tuđa uplata mogla pripisati
  -- doprinosu druge kampanje
  if v_c.campaign_id <> p_campaign_id then raise exception 'campaign_mismatch'; end if;

  if v_c.state = 'paid' then
    return query select v_c.id, false;
    return;
  end if;

  if p_amount_cents is null or p_amount_cents < v_c.amount_cents then
    raise exception 'amount_below_contribution';
  end if;

  -- Ista tolerantnost kao mark_contribution_paid: novac je na lancu, odbiti ga
  -- zbog isteklog internog timera je najgori ishod (H2).
  update pinka_finance.contributions
     set state                 = 'paid',
         forward_tx_hash       = p_tx_hash,
         onchain_log_index     = p_log_index,
         onchain_from          = p_from,
         amount_received_cents = p_amount_cents,
         paid_at               = now(),
         updated_at            = now()
   where id = p_contribution_id
     and state in ('pending','expired','failed');
  get diagnostics v_n = row_count;

  return query select p_contribution_id, v_n > 0;
end;
$$;
revoke execute on function pinka_finance.confirm_slot_contribution(uuid,uuid,text,integer,text,bigint)
  from public, anon, authenticated;
grant  execute on function pinka_finance.confirm_slot_contribution(uuid,uuid,text,integer,text,bigint)
  to service_role;

select 'OK pinka_slots' as status;
