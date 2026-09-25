-- =============================================================================
-- Stadion Maksimir — glasanje javnosti o 88 natječajnih radova
-- Frontend: github.com/stepanic/stadion-maksimir-natjecaj-2026 (web/, #/radovi)
--
-- Model: svaka Certilia-verificirana osoba ima TOČNO JEDAN glas = 100 bodova,
-- koje raspoređuje po radovima kako hoće (sve na jedan rad, ili 40/30/20/10…).
-- Zbroj bodova na listiću mora biti točno 100, pa svaka osoba teži jednako.
-- Listić se smije mijenjati do zatvaranja; broji se zadnja verzija (atomska
-- zamjena cijelog listića). Rezultati (zbroj bodova po radu) su javni UŽIVO.
--
-- Neslužbeno: nema veze s odlukom ocjenjivačkog suda (rezultati 24.9.2026.).
--
-- Tablice su u `domovina_ai` s prefiksom `maksimir_` NAMJERNO: nova shema bi
-- tražila izmjenu PGRST_DB_SCHEMAS na Coolifyju i db-migrate.sh backupa.
--
-- Identitet: isti obrazac kao Izborni dan (20260808120000_channel_voting.sql).
-- Listić se veže na TRAJNI pseudonim `maksimir_voters` (oib_hash unique,
-- user_id on delete SET NULL) — brisanje i ponovno otvaranje računa NE daje
-- drugi listić, nego vraća isti.
--
-- Ovo NIJE tajno glasovanje: voter_id → oib_hash postoji u bazi. Pojedinačni
-- listići se NIKAD ne objavljuju — samo agregati kroz maksimir_results().
--
-- Provjerljivost (lanac hasheva + OpenTimestamps):
-- Svaka predaja/izmjena/povlačenje listića dodaje red u `maksimir_log` —
-- append-only lanac hasheva (UPDATE/DELETE blokira trigger). Glasač dobiva
-- potvrdu (seq + hash + svoj pseudonim + bodove). Vanjska skripta
-- (stadion-maksimir-natjecaj-2026: scripts/maksimir_checkpoint.py) svaki sat
-- čita maksimir_snapshot() (vrh lanca + trenutni rezultati) i žigoše ga
-- OpenTimestampsom u Bitcoin — kontinuirano, ne samo na kraju. Nakon toga ni
-- povijest lanca ni objavljeni rezultati u tom trenutku ne mogu se tiho prepisati. Po zatvaranju cijeli lanac je javan
-- (maksimir_log) i svatko ga može ponovno izračunati i izbrojati.
--
--   hash_n = sha256( prev_hash ‖ '|' ‖ seq ‖ '|' ‖ pseudonym ‖ '|' ‖ revision
--                    ‖ '|' ‖ ts_ms ‖ '|' ‖ items_canon )           (hex, UTF-8)
--   genesis prev_hash = 64 × '0'
--   pseudonym   = sha256('maksimir:' ‖ voter_id)  — stalan po osobi, ne otkriva identitet
--   items_canon = 'CODE:bodovi,CODE:bodovi' sortirano po šifri (bajtno), '' = povlačenje
--
-- Javni ugovor (`client.schema('domovina_ai').rpc(...)`):
--   maksimir_results()                 → jsonb  (anon)
--   maksimir_log_head()                → jsonb  (anon; vrh lanca)
--   maksimir_snapshot()                → jsonb  (anon; vrh lanca + rezultati u JEDNOM
--                                        snapshotu baze — to se svaki sat žigoše)
--   maksimir_log(p_after, p_limit)     → jsonb  (anon; TEK nakon zatvaranja)
--   maksimir_my_ballot()               → jsonb  (authenticated; NE piše)
--   maksimir_accept_terms()            → void   (authenticated)
--   maksimir_cast_ballot(p_items)      → jsonb  (authenticated)
--       p_items = {"<code>": <bodovi 1..100>, ...}, zbroj = 100
--       p_items = {}                   → povlačenje listića
-- Greške (exception message): not_verified | terms_not_accepted |
--   voting_closed | invalid_ballot | unknown_entry | points_sum_not_100 |
--   log_not_public_yet
-- Interni wrapperi (service_role ONLY, za testove):
--   _maksimir_ballot_of(p_user_id), _maksimir_accept_terms_for(p_user_id),
--   _maksimir_cast_ballot_for(p_user_id, p_items)
-- =============================================================================

-- ----- radovi (88, iz sources/radovi.json; code je šifra rada s natječaja) --
create table if not exists domovina_ai.maksimir_entries (
  code   text primary key,
  n      int  not null unique,                  -- redni broj s popisa radova
  lead   text not null,                         -- nositelj rada (za admin pregled)
  status text not null,                         -- ranked | rejected (odluka žirija)
  constraint maksimir_entries_code_format check (code ~ '^[A-Z0-9]{9}$'),
  constraint maksimir_entries_status_allowed check (status in ('ranked','rejected'))
);

insert into domovina_ai.maksimir_entries (code, n, lead, status) values
  ('MJY2USY2W', 1, 'Engineering Design & Research Institute of Sichuan University', 'ranked'),
  ('X8G5VVECK', 2, 'Pulsar Arhitektura d.o.o.', 'ranked'),
  ('6PPWVBBBZ', 3, 'njiric plus arhitekti, d.o.o.', 'ranked'),
  ('JFHSTDJMQ', 4, 'Albert Wimmer ZT GmbH', 'ranked'),
  ('DPZC5ZDGB', 5, 'IPOSTUDIO Architetti srl', 'ranked'),
  ('WDYQY56G6', 6, 'SWOODING ARCHITECTS LIMITED', 'ranked'),
  ('PPWTPROZF', 7, 'ARHITEKTURA NOVA DOOEL Veles', 'ranked'),
  ('G2CPLFGEK', 8, 'STEFANO BOERI ARCHITETTI', 'ranked'),
  ('KPEEULHEN', 9, 'Dietrich/Untertrifaller Architekten ZT GmbH', 'ranked'),
  ('I6PSUQ0QD', 10, 'SV60 ARQUITECTOS', 'ranked'),
  ('JGLUCNGVP', 11, 'dejan miletic', 'ranked'),
  ('OYPODSV1H', 12, 'ADAT Studio srl', 'ranked'),
  ('MJ76JGHEI', 13, 'Mihaela Sladović', 'ranked'),
  ('SS9MPMWOY', 14, 'DONIS LTD', 'ranked'),
  ('Q1BIEWBQI', 15, 'JA Architecture StudioInc', 'ranked'),
  ('6TVJ3MUHR', 16, 'VG13 Architects Studio Associato', 'ranked'),
  ('HSQMCGBCH', 17, 'OPERADORA DE PRODUCTOS Y SERVICIOS AARM', 'ranked'),
  ('HV4FFIHDN', 18, 'RANDIĆ I SURADNICI d. o. o.', 'ranked'),
  ('PJ7KODKT5', 19, 'China Southwest Architectural Design and Research Institute Corp.Ltd', 'ranked'),
  ('WGBJHGUL5', 20, 'RMJM MANTOVA STP S.R.L.', 'ranked'),
  ('SS6SBB19I', 21, 'KÖZTI Zrt.', 'ranked'),
  ('LOUOR2NOD', 22, 'Gerber Architekten International GmbH', 'ranked'),
  ('M6ILWNLRB', 23, 'STUDIO ZA ARHITEKTURU d.o.o.', 'ranked'),
  ('I4EEQIWWW', 24, 'baukuh', 'ranked'),
  ('1EEPNNDDB', 25, 'Tim-Philipp Brendel', 'ranked'),
  ('JYXGFPAWY', 26, 'shesa srls', 'ranked'),
  ('YJEKYQPFE', 27, 'Sofija Poleksić', 'ranked'),
  ('ZDWBDEPPE', 28, 'RUBING PROJEKT d.o.o.', 'ranked'),
  ('WWUUTZSNC', 29, 'PROARH MATEKOVIĆ D.O.O.', 'ranked'),
  ('GJLXCWWPR', 30, 'Office for Metropolitan Architecture (O.M.A.) Stedebouw B.V.', 'ranked'),
  ('FQORKZEN0', 31, 'ZHA Architects Limited', 'ranked'),
  ('UXADSRW1U', 32, 'ATOM ARHITEKTURA d.o.o.', 'ranked'),
  ('CYFXC7LIM', 33, 'P2PA SPÓŁKA Z OGRANICZONĄ ODPOWIEDZIALNOŚCIĄ', 'ranked'),
  ('CGCSJW79U', 34, 'TVORZI - Architecture', 'ranked'),
  ('K1THJGC7W', 35, 'Studio Kaić arhitekti d.o.o.', 'ranked'),
  ('9TZIJAPW4', 36, 'Incept Arhitecture', 'ranked'),
  ('W3YS5VJBZ', 37, 'Plan Común', 'ranked'),
  ('UO5YMEAMR', 38, 'JEFF ALAN GARD', 'ranked'),
  ('SIAWCHRWI', 39, 'CBA Christian Bergmann Architecture GmbH', 'ranked'),
  ('OUEE4GMGC', 40, 'ppp architekten + generalplaner gmbh', 'ranked'),
  ('K2MEDVFXI', 41, 'ANDREA CAPUTO', 'ranked'),
  ('72ECW1UD7', 42, 'URBANE IDEJE d.o.o.', 'ranked'),
  ('SVFGQA8HM', 43, 'PROJEKT D.D. NOVA GORICA Podjetje za inženiring', 'ranked'),
  ('G8UJEOMVM', 44, 'GEplus arhitekti d.o.o', 'ranked'),
  ('TJML1KADC', 45, 'MOSSESSIAN ARCHITECTURE LIMITED', 'ranked'),
  ('BPKNHCZ5Y', 46, 'Tariq Khayyat Design Partners FZ-LLC', 'ranked'),
  ('9B9EEI64G', 47, 'STUDIO 3LHD d.o.o.', 'ranked'),
  ('J8B0FD4Q0', 48, 'CHYBIK + KRISTOF s.r.o.', 'ranked'),
  ('2AAVTUGWB', 49, 'Dunja Jelisavcic', 'ranked'),
  ('Y1AYSU2BI', 50, 'Margaret Arbanas', 'ranked'),
  ('2OXZFNNDT', 51, 'ARQUIVIO ARCHITECTS SLP', 'ranked'),
  ('KRQEHDKDD', 52, 'Moxon Architects Ltd', 'ranked'),
  ('TVHRJYYJT', 53, 'Degli Esposti Architetti S.r.l.', 'ranked'),
  ('KLHI95BLM', 54, 'ANDARCHITECTS LTD', 'ranked'),
  ('QTHYEBYMC', 55, 'VENDO PET d.o.o.', 'ranked'),
  ('0ZUFNG8CC', 56, 'SMAR Architecture Studio', 'rejected'),
  ('H66BNHW0U', 57, 'ingenhoven associates GmbH', 'ranked'),
  ('IN6KISUJT', 58, 'Nikola Polak', 'ranked'),
  ('HTKIZRN8V', 59, 'Matej Mauhar', 'ranked'),
  ('PWC6XWGWN', 60, 'Atelier Thomas Pucher ZT GmbH', 'ranked'),
  ('CIXSLMQWW', 61, 'BOKOROM DOO', 'ranked'),
  ('GY0F1A9OM', 62, 'XDGA', 'ranked'),
  ('NONDB5MRF', 63, 'Studio Stoitsova', 'ranked'),
  ('WP6WKTZ3Z', 64, 'BJARKE INGELS GROUP ARCHITECTURE SPAIN SLP', 'ranked'),
  ('HKJS1WQOK', 65, 'Patricia da Silva, Arquitectura, Unipessoal LDA', 'ranked'),
  ('WYYB64CFR', 66, 'ARK Arhitektura Krušec d.o.o.', 'ranked'),
  ('GGWUGWAZB', 67, 'de Architekten Cie. B.V.', 'ranked'),
  ('QK1YMPGVJ', 68, 'Patricio José Martínez García', 'ranked'),
  ('WWZGJZ9EO', 69, 'IEC Architects + Engineers', 'ranked'),
  ('EEADH5IWW', 70, 'ing4studio d.o.o.', 'ranked'),
  ('82WWCRXWE', 71, 'SIRRAH-PROJEKT d.o.o.', 'ranked'),
  ('RYX76HLBI', 72, 'O+M Architekten GmbH', 'ranked'),
  ('Y7CWWEEP5', 73, 'ECOLA', 'ranked'),
  ('LPMLOBLZN', 74, 'ATMOSFERA d.o.o.', 'ranked'),
  ('XTCOLQ2HZ', 75, 'Archea Associati srl', 'ranked'),
  ('7ITCHBTWU', 76, 'ZBIR studio d.o.o.', 'ranked'),
  ('KEQYRXFPS', 77, 'MEDPROSTOR, arhitekturni atelje d.o.o.', 'ranked'),
  ('X5Z6CZDRU', 78, 'Gianfranco Toso', 'ranked'),
  ('LV4YKMRVD', 79, 'Global Connect d.o.o.', 'ranked'),
  ('AXAHFUYJP', 80, 'DOMO-PLAN d.o.o.', 'ranked'),
  ('TCG3ZSILM', 81, 'Jorge Vidal Studio', 'ranked'),
  ('Y7ZXWDDBL', 82, 'Zoran Dmitrovic', 'ranked'),
  ('FSFJLMC2K', 83, '2K ARHITEKTONSKI URED d.o.o.', 'ranked'),
  ('EKQ6QK4AJ', 84, 'Pedro Pitarch Alonso', 'ranked'),
  ('ATQ1VGDWW', 85, 'Gordana Gregurić Miočić', 'ranked'),
  ('S7EE9DARZ', 86, 'Pablo Ramos Alderete', 'ranked'),
  ('AV3DOWDM4', 87, 'Radionica arhitekture d.o.o.', 'rejected'),
  ('E5WW92OVA', 88, 'Mirko Marić', 'rejected')
on conflict (code) do nothing;

-- ----- postavke (jedan red): prozor glasanja; null = bez ograničenja --------
create table if not exists domovina_ai.maksimir_settings (
  id        boolean primary key default true check (id),
  opens_at  timestamptz,
  closes_at timestamptz,
  constraint maksimir_settings_window check (closes_at is null or opens_at is null or closes_at > opens_at)
);

-- Rok je namjerno dalek: Certilia ima > 700 000 korisnika, a link se širi
-- organski. Mijenja se izravno u tablici, bez migracije.
insert into domovina_ai.maksimir_settings (id, closes_at)
values (true, '2027-12-31 23:59:59 Europe/Zagreb'::timestamptz)
on conflict (id) do nothing;

-- ----- glasači (trajni pseudonim; preživljava brisanje računa) --------------
create table if not exists domovina_ai.maksimir_voters (
  id           uuid primary key default gen_random_uuid(),
  oib_hash     text not null unique,            -- iz public.identity_verifications
  user_id      uuid references auth.users(id) on delete set null,  -- ★ NE cascade
  consented_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists ix_maksimir_voters_user on domovina_ai.maksimir_voters (user_id);

comment on column domovina_ai.maksimir_voters.user_id is
  'on delete SET NULL namjerno — listić preživljava brisanje računa '
  '(inače: obriši račun → ponovno verificiraj → drugi listić).';

drop trigger if exists trg_maksimir_voters_updated on domovina_ai.maksimir_voters;
create trigger trg_maksimir_voters_updated
  before update on domovina_ai.maksimir_voters
  for each row execute function public.touch_updated_at();

-- ----- listići (najviše JEDAN po glasaču — PK je voter_id) ------------------
create table if not exists domovina_ai.maksimir_ballots (
  voter_id   uuid primary key references domovina_ai.maksimir_voters(id) on delete cascade,
  revisions  int not null default 1 check (revisions >= 1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists domovina_ai.maksimir_ballot_items (
  voter_id uuid not null references domovina_ai.maksimir_ballots(voter_id) on delete cascade,
  code     text not null references domovina_ai.maksimir_entries(code),
  points   smallint not null check (points between 1 and 100),
  primary key (voter_id, code)
);
-- Zbroj = 100 po listiću provjerava _maksimir_cast_ballot_for (jedini put pisanja).

create index if not exists ix_maksimir_ballot_items_code
  on domovina_ai.maksimir_ballot_items (code);

-- ----- lanac hasheva (append-only; javni tek po zatvaranju) ------------------
-- NEMA FK na maksimir_voters: zapisnik mora preživjeti i brisanje glasača.
create table if not exists domovina_ai.maksimir_log (
  seq         bigint primary key check (seq >= 1),
  prev_hash   text not null check (prev_hash ~ '^[0-9a-f]{64}$'),
  hash        text not null unique check (hash ~ '^[0-9a-f]{64}$'),
  pseudonym   text not null check (pseudonym ~ '^[0-9a-f]{64}$'),
  revision    int  not null check (revision >= 0),        -- 0 = povlačenje
  ts_ms       bigint not null,
  items_canon text not null
);

create index if not exists ix_maksimir_log_pseudonym
  on domovina_ai.maksimir_log (pseudonym, seq desc);

create or replace function domovina_ai._maksimir_log_immutable()
returns trigger language plpgsql set search_path = '' as $$
begin
  raise exception 'maksimir_log is append-only';
end;
$$;

drop trigger if exists trg_maksimir_log_immutable on domovina_ai.maksimir_log;
create trigger trg_maksimir_log_immutable
  before update or delete on domovina_ai.maksimir_log
  for each row execute function domovina_ai._maksimir_log_immutable();

drop trigger if exists trg_maksimir_log_no_truncate on domovina_ai.maksimir_log;
create trigger trg_maksimir_log_no_truncate
  before truncate on domovina_ai.maksimir_log
  for each statement execute function domovina_ai._maksimir_log_immutable();

-- ----- grants / RLS ----------------------------------------------------------
-- ⚠ 20260520120600 daje default privileges na domovina_ai tablice za
--   anon/authenticated — zato su revokeovi ispod nužni, ne kozmetički.
alter table domovina_ai.maksimir_entries      enable row level security;
alter table domovina_ai.maksimir_settings     enable row level security;
alter table domovina_ai.maksimir_voters       enable row level security;
alter table domovina_ai.maksimir_ballots      enable row level security;
alter table domovina_ai.maksimir_ballot_items enable row level security;

revoke insert, update, delete on domovina_ai.maksimir_entries  from anon, authenticated;
revoke insert, update, delete on domovina_ai.maksimir_settings from anon, authenticated;
grant select on domovina_ai.maksimir_entries  to anon, authenticated;
grant select on domovina_ai.maksimir_settings to anon, authenticated;
grant select, insert, update, delete on domovina_ai.maksimir_entries  to service_role;
grant select, insert, update, delete on domovina_ai.maksimir_settings to service_role;

drop policy if exists maksimir_entries_select on domovina_ai.maksimir_entries;
create policy maksimir_entries_select on domovina_ai.maksimir_entries
  for select to anon, authenticated using (true);
drop policy if exists maksimir_settings_select on domovina_ai.maksimir_settings;
create policy maksimir_settings_select on domovina_ai.maksimir_settings
  for select to anon, authenticated using (true);

-- ZERO client policies: oib_hash i pojedinačni listići ne izlaze iz baze.
revoke all on domovina_ai.maksimir_voters       from public, anon, authenticated;
revoke all on domovina_ai.maksimir_ballots      from public, anon, authenticated;
revoke all on domovina_ai.maksimir_ballot_items from public, anon, authenticated;
grant select, insert, update, delete on domovina_ai.maksimir_voters       to service_role;
grant select, insert, update, delete on domovina_ai.maksimir_ballots      to service_role;
grant select, insert, update, delete on domovina_ai.maksimir_ballot_items to service_role;

alter table domovina_ai.maksimir_log enable row level security;
revoke all on domovina_ai.maksimir_log from public, anon, authenticated;
grant select, insert on domovina_ai.maksimir_log to service_role;

-- ----- _maksimir_is_open -----------------------------------------------------
create or replace function domovina_ai._maksimir_is_open()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select (s.opens_at is null or pg_catalog.now() >= s.opens_at)
       and (s.closes_at is null or pg_catalog.now() < s.closes_at)
      from domovina_ai.maksimir_settings s where s.id
  ), false);
$$;

revoke execute on function domovina_ai._maksimir_is_open() from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_is_open() to service_role;

-- ----- lanac: pseudonim, kanonski oblik, dodavanje -------------------------
create or replace function domovina_ai._maksimir_pseudonym(p_voter_id uuid)
returns text
language sql immutable set search_path = ''
as $$
  select pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('maksimir:' || p_voter_id::text, 'UTF8')), 'hex');
$$;

create or replace function domovina_ai._maksimir_items_canon(p_items jsonb)
returns text
language sql immutable set search_path = ''
as $$
  select coalesce(pg_catalog.string_agg(e.key || ':' || (e.value::numeric::int)::text, ',' order by e.key collate "C"), '')
    from pg_catalog.jsonb_each(coalesce(p_items, '{}'::jsonb)) e;
$$;

-- Zove se samo iz _maksimir_cast_ballot_for, NAKON zaključavanja glasača.
-- Globalni advisory lock serijalizira lanac (seq bez rupa, prev_hash točan);
-- redoslijed zaključavanja je uvijek glasač → lanac, pa nema deadlocka.
create or replace function domovina_ai._maksimir_append_log(p_voter_id uuid, p_revision int, p_items jsonb)
returns domovina_ai.maksimir_log
language plpgsql security definer set search_path = ''
as $$
declare
  v_prev domovina_ai.maksimir_log%rowtype;
  v_row  domovina_ai.maksimir_log%rowtype;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('domovina_ai.maksimir_log')::bigint);
  select * into v_prev from domovina_ai.maksimir_log order by seq desc limit 1;

  v_row.seq         := coalesce(v_prev.seq, 0) + 1;
  v_row.prev_hash   := coalesce(v_prev.hash, pg_catalog.repeat('0', 64));
  v_row.pseudonym   := domovina_ai._maksimir_pseudonym(p_voter_id);
  v_row.revision    := p_revision;
  v_row.ts_ms       := (extract(epoch from pg_catalog.clock_timestamp()) * 1000)::bigint;
  v_row.items_canon := domovina_ai._maksimir_items_canon(p_items);
  v_row.hash := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
      v_row.prev_hash || '|' || v_row.seq || '|' || v_row.pseudonym || '|' || v_row.revision
      || '|' || v_row.ts_ms || '|' || v_row.items_canon, 'UTF8')), 'hex');

  insert into domovina_ai.maksimir_log values (v_row.*);
  return v_row;
end;
$$;

revoke execute on function domovina_ai._maksimir_pseudonym(uuid) from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_items_canon(jsonb) from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_append_log(uuid, int, jsonb) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_pseudonym(uuid) to service_role;
grant execute on function domovina_ai._maksimir_items_canon(jsonb) to service_role;
grant execute on function domovina_ai._maksimir_append_log(uuid, int, jsonb) to service_role;

-- ----- maksimir_log_head (anon; javni vrh lanca — ovo se žigoše) -------------
create or replace function domovina_ai.maksimir_log_head()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object('seq', l.seq, 'hash', l.hash, 'ts_ms', l.ts_ms)
       from domovina_ai.maksimir_log l order by l.seq desc limit 1),
    jsonb_build_object('seq', 0, 'hash', pg_catalog.repeat('0', 64), 'ts_ms', null));
$$;

revoke execute on function domovina_ai.maksimir_log_head() from public;
grant execute on function domovina_ai.maksimir_log_head() to anon, authenticated, service_role;

-- ----- maksimir_log (anon; cijeli lanac, TEK kad je glasanje zatvoreno) ------
-- Tijekom glasanja javan je samo vrh: pseudonim + vrijeme predaje bi inače
-- omogućili vezivanje listića uz osobu koja zna kad je netko glasao.
create or replace function domovina_ai.maksimir_log(p_after bigint default 0, p_limit int default 1000)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_closes timestamptz;
begin
  select closes_at into v_closes from domovina_ai.maksimir_settings where id;
  if v_closes is null or pg_catalog.now() < v_closes then
    raise exception 'log_not_public_yet';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(l) order by l.seq)
      from (select * from domovina_ai.maksimir_log
             where seq > coalesce(p_after, 0)
             order by seq
             limit least(greatest(coalesce(p_limit, 1000), 1), 5000)) l
  ), '[]'::jsonb);
end;
$$;

revoke execute on function domovina_ai.maksimir_log(bigint, int) from public;
grant execute on function domovina_ai.maksimir_log(bigint, int) to anon, authenticated, service_role;

-- ----- maksimir_results (anon; javni agregat, UŽIVO) -------------------------
-- points  = zbroj bodova svih listića za rad
-- share   = udio u svim glasovima, u postocima (points / (voters*100) * 100)
-- backers = broj osoba koje su radu dale > 0 bodova
create or replace function domovina_ai.maksimir_results()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with v as (select count(*)::int as n from domovina_ai.maksimir_ballots),
  t as (
    select e.code, e.n,
           coalesce(sum(i.points), 0)::int as points,
           count(i.voter_id)::int          as backers
      from domovina_ai.maksimir_entries e
      left join domovina_ai.maksimir_ballot_items i on i.code = e.code
     group by e.code, e.n
  )
  select jsonb_build_object(
    'open',      domovina_ai._maksimir_is_open(),
    'opens_at',  (select opens_at  from domovina_ai.maksimir_settings where id),
    'closes_at', (select closes_at from domovina_ai.maksimir_settings where id),
    'voters',    v.n,
    'results',   coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', t.code, 'points', t.points, 'backers', t.backers,
               'share', case when v.n = 0 then 0
                             else round(t.points::numeric / v.n, 2) end)
             order by t.points desc, t.n)
        from t), '[]'::jsonb)
  )
  from v;
$$;

revoke execute on function domovina_ai.maksimir_results() from public;
grant execute on function domovina_ai.maksimir_results() to anon, authenticated, service_role;

-- ----- _maksimir_ballot_of / maksimir_my_ballot (NE piše) --------------------
create or replace function domovina_ai._maksimir_ballot_of(p_user_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_hash  text;
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_items jsonb;
  v_upd   timestamptz;
  v_rcpt  jsonb;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash
      from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;

  if v_hash is not null then
    select * into v_voter from domovina_ai.maksimir_voters where oib_hash = v_hash;
    if found then
      select b.updated_at into v_upd from domovina_ai.maksimir_ballots b where b.voter_id = v_voter.id;
      select jsonb_object_agg(i.code, i.points) into v_items
        from domovina_ai.maksimir_ballot_items i where i.voter_id = v_voter.id;
      -- potvrda = zadnji red lanca ovog glasača (sve što treba za provjeru)
      select to_jsonb(l) into v_rcpt
        from domovina_ai.maksimir_log l
       where l.pseudonym = domovina_ai._maksimir_pseudonym(v_voter.id)
       order by l.seq desc limit 1;
    end if;
  end if;

  return jsonb_build_object(
    'verified',   v_hash is not null,
    'consented',  v_voter.consented_at is not null,
    'open',       domovina_ai._maksimir_is_open(),
    'items',      coalesce(v_items, '{}'::jsonb),
    'updated_at', v_upd,
    'receipt',    v_rcpt
  );
end;
$$;

revoke execute on function domovina_ai._maksimir_ballot_of(uuid) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_ballot_of(uuid) to service_role;

create or replace function domovina_ai.maksimir_my_ballot()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select domovina_ai._maksimir_ballot_of((select auth.uid()));
$$;

revoke execute on function domovina_ai.maksimir_my_ballot() from public, anon;
grant execute on function domovina_ai.maksimir_my_ballot() to authenticated, service_role;

-- ----- _maksimir_accept_terms_for / maksimir_accept_terms (privola) ----------
create or replace function domovina_ai._maksimir_accept_terms_for(p_user_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare v_hash text;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash
      from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then
    raise exception 'not_verified';
  end if;

  insert into domovina_ai.maksimir_voters (oib_hash, user_id, consented_at)
  values (v_hash, p_user_id, pg_catalog.now())
  on conflict (oib_hash) do update
    set user_id      = excluded.user_id,
        consented_at = coalesce(domovina_ai.maksimir_voters.consented_at, excluded.consented_at);
end;
$$;

revoke execute on function domovina_ai._maksimir_accept_terms_for(uuid) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_accept_terms_for(uuid) to service_role;

create or replace function domovina_ai.maksimir_accept_terms()
returns void
language sql security definer set search_path = ''
as $$
  select domovina_ai._maksimir_accept_terms_for((select auth.uid()));
$$;

revoke execute on function domovina_ai.maksimir_accept_terms() from public, anon;
grant execute on function domovina_ai.maksimir_accept_terms() to authenticated, service_role;

-- ----- _maksimir_cast_ballot_for (jezgra — JEDNA transakcija) ---------------
-- Validacija cijelog listića PRIJE ikakvog pisanja; onda zaključaj glasača i
-- zamijeni listić (delete stavki + insert novih). Dva paralelna slanja istog
-- glasača serijalizira `for update` na maksimir_voters.
create or replace function domovina_ai._maksimir_cast_ballot_for(p_user_id uuid, p_items jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash  text;
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_sum   int := 0;
  v_count int := 0;
  v_rev   int := 0;
  r       record;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash
      from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then
    raise exception 'not_verified';
  end if;

  if not domovina_ai._maksimir_is_open() then
    raise exception 'voting_closed';
  end if;

  -- ── validacija oblika: objekt {code: cijeli broj 1..100} ─────────────────
  if p_items is null or jsonb_typeof(p_items) <> 'object' then
    raise exception 'invalid_ballot';
  end if;
  for r in select key, value from jsonb_each(p_items) loop
    if jsonb_typeof(r.value) <> 'number'
       or (r.value)::numeric <> trunc((r.value)::numeric)
       or (r.value)::numeric not between 1 and 100 then
      raise exception 'invalid_ballot';
    end if;
    if not exists (select 1 from domovina_ai.maksimir_entries e where e.code = r.key) then
      raise exception 'unknown_entry';
    end if;
    v_sum   := v_sum + (r.value)::int;
    v_count := v_count + 1;
  end loop;
  if v_count > 0 and v_sum <> 100 then
    raise exception 'points_sum_not_100';
  end if;

  -- ── glasač + privola ───────────────────────────────────────────────────────
  insert into domovina_ai.maksimir_voters (oib_hash, user_id)
  values (v_hash, p_user_id)
  on conflict (oib_hash) do update set user_id = excluded.user_id
  returning * into v_voter;

  if v_voter.consented_at is null then
    raise exception 'terms_not_accepted';
  end if;

  select * into v_voter from domovina_ai.maksimir_voters where id = v_voter.id for update;

  -- ── zamjena listića ────────────────────────────────────────────────────────
  if v_count = 0 then
    delete from domovina_ai.maksimir_ballots where voter_id = v_voter.id;   -- povlačenje
    if found then
      perform domovina_ai._maksimir_append_log(v_voter.id, 0, '{}'::jsonb);
    end if;
  else
    insert into domovina_ai.maksimir_ballots (voter_id)
    values (v_voter.id)
    on conflict (voter_id) do update
      set revisions  = domovina_ai.maksimir_ballots.revisions + 1,
          updated_at = pg_catalog.now()
    returning revisions into v_rev;

    delete from domovina_ai.maksimir_ballot_items where voter_id = v_voter.id;
    insert into domovina_ai.maksimir_ballot_items (voter_id, code, points)
    select v_voter.id, key, value::int::smallint from jsonb_each_text(p_items);

    perform domovina_ai._maksimir_append_log(v_voter.id, v_rev, p_items);
  end if;

  return domovina_ai._maksimir_ballot_of(p_user_id);
end;
$$;

revoke execute on function domovina_ai._maksimir_cast_ballot_for(uuid, jsonb) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_cast_ballot_for(uuid, jsonb) to service_role;

create or replace function domovina_ai.maksimir_cast_ballot(p_items jsonb)
returns jsonb
language sql security definer set search_path = ''
as $$
  select domovina_ai._maksimir_cast_ballot_for((select auth.uid()), p_items);
$$;

revoke execute on function domovina_ai.maksimir_cast_ballot(jsonb) from public, anon;
grant execute on function domovina_ai.maksimir_cast_ballot(jsonb) to authenticated, service_role;

-- ----- maksimir_snapshot (anon; ovo se svaki sat žigoše u Bitcoin) ----------
-- Jedan SQL izraz = jedan MVCC snapshot → vrh lanca i rezultati su dosljedni:
-- rezultati su točno zbroj zadnjih revizija po pseudonimu u lancu do `head.seq`.
create or replace function domovina_ai.maksimir_snapshot()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'schema',  'maksimir-snapshot/1',
    'at',      pg_catalog.now(),
    'head',    domovina_ai.maksimir_log_head()
  ) || domovina_ai.maksimir_results();
$$;

revoke execute on function domovina_ai.maksimir_snapshot() from public;
grant execute on function domovina_ai.maksimir_snapshot() to anon, authenticated, service_role;

select 'OK maksimir_voting' as status;
