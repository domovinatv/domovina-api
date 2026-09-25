-- =============================================================================
-- Stadion Maksimir — dijeljenje glasa: JAVNO (ime + bodovi) ili ANONIMNO (ZK)
-- Nadogradnja na 20260925120000_maksimir_voting.sql. Frontend:
-- github.com/stepanic/stadion-maksimir-natjecaj-2026 (web/src/zk.ts, #/glasanje/g/<id>)
--
-- Faza 1 je u cijelosti OFFCHAIN. Što bi u kasnijim fazama trebalo preseliti
-- na blockchain opisano je u docs/glasanje-kako-radi.md (poglavlje „Sljedeće faze”).
--
-- 1. JAVNO. Glasač sam odluči da mu se listić javno prikaže, s imenom iz
--    eOsobne u obliku koji izabere: 'full' (Ime Prezime), 'initial' (Ime P.)
--    ili 'anon' (bez imena). Dobiva stalnu poveznicu /g/<id>. Isključivanjem
--    poveznica ostaje, ali više ne prikazuje ništa.
--
-- 2. ANONIMNO (Semaphore v4, Groth16 nad BN254). Preglednik glasača izradi
--    Semaphore identitet (tajni ključ NIKAD ne napušta preglednik) i ovdje
--    upiše samo njegov commitment = Poseidon(javni ključ). Svi commitmenti
--    potvrđenih glasača tvore grupu (LeanIMT Merkleovo stablo). Glasač zatim
--    u pregledniku izradi ZK dokaz: „ja sam jedan od N potvrđenih glasača”,
--    bez otkrivanja kojeg. Dokaz se sprema BEZ veze na glasača.
--    Svatko ga provjerava u pregledniku: SNARK (verifyProof) + korijen stabla
--    ponovno izračunat iz javnog zapisnika grupe do zk_seq.
--
--    Zapisnik grupe `maksimir_zk_log` je append-only lanac hasheva:
--      hash = sha256(prev_hash|seq|op|commitment)   (hex, UTF-8), genesis 64 × '0'
--      op   = 'add' | 'remove'
--    Grupa u točki seq = commitmenti redom dodavanja, bez uklonjenih.
--    Vrh zapisnika ulazi u satni snapshot (maksimir-snapshot/2) → Bitcoin.
--
--    Poruka i scope dokaza su fiksni (Semaphore kodira string kao bytes32 → bigint):
--      message = "glasao-sam"    → 46779715467123036996841617194389431189336537137425384514209209627004761014272
--      scope   = "maksimir-2026" → 49474226259215312994888701590181247581981161421217961257574660746611720716288
--    nullifier = Poseidon(scope, tajni ključ) → jedna osoba (jedan ključ) = jedan dokaz.
--
-- Granice (poštene): operater baze zna koji je glasač upisao koji commitment,
-- pa bi mogao povezati dokaz s osobom. Javnost ne može. SQL ne provjerava
-- SNARK (nema Poseidona/pairinga u Postgresu); provjeru radi svaki preglednik
-- koji otvori dokaz, a neispravan dokaz prikazuje se kao neispravan.
--
-- Javni ugovor (`client.schema('domovina_ai').rpc(...)`):
--   maksimir_set_public(p_mode)         → jsonb (authenticated; p_mode null = isključi)
--   maksimir_zk_register(p_commitment)  → jsonb (authenticated)
--   maksimir_zk_group()                 → jsonb (anon; cijeli zapisnik grupe, bez vremena)
--   maksimir_zk_share(p_proof, p_zk_seq)→ jsonb (anon; sprema dokaz, vraća id)
--   maksimir_share(p_id)                → jsonb (anon; javna objava ili ZK dokaz)
--   maksimir_public_ballots(p_limit)    → jsonb (anon; javni listići)
--   maksimir_my_ballot()                → + public_mode, share_id, zk_commitment
--   maksimir_snapshot()                 → schema maksimir-snapshot/2 (+ zk, public_voters)
-- Nove greške: no_ballot | invalid_mode | invalid_commitment | commitment_taken |
--   invalid_proof | unknown_zk_seq
-- =============================================================================

-- ----- javni prikaz ----------------------------------------------------------
alter table domovina_ai.maksimir_voters
  add column if not exists public_mode text,
  add column if not exists public_at   timestamptz;

do $$ begin
  alter table domovina_ai.maksimir_voters
    add constraint maksimir_voters_public_mode check (public_mode in ('full', 'initial', 'anon'));
exception when duplicate_object then null; end $$;

-- ----- objave (javne i ZK) ---------------------------------------------------
-- kind 'public': voter_id postavljen (jedna po glasaču), proof null
-- kind 'zk'    : voter_id NULL (namjerno nema veze na glasača), proof + nullifier
create table if not exists domovina_ai.maksimir_shares (
  id         text primary key check (id ~ '^[a-z0-9]{12}$'),
  kind       text not null check (kind in ('public', 'zk')),
  voter_id   uuid unique references domovina_ai.maksimir_voters(id) on delete cascade,
  proof      jsonb,
  zk_seq     bigint,
  nullifier  text unique,
  created_at timestamptz not null default now(),
  constraint maksimir_shares_shape check (
    (kind = 'public' and voter_id is not null and proof is null and nullifier is null)
    or (kind = 'zk' and voter_id is null and proof is not null and nullifier is not null and zk_seq >= 1))
);

-- ----- ZK grupa: append-only zapisnik + trenutni članovi ----------------------
create table if not exists domovina_ai.maksimir_zk_log (
  seq        bigint primary key check (seq >= 1),
  op         text not null check (op in ('add', 'remove')),
  commitment text not null check (commitment ~ '^[0-9]{1,78}$'),
  prev_hash  text not null check (prev_hash ~ '^[0-9a-f]{64}$'),
  hash       text not null unique check (hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()    -- samo za operatera; javni RPC ga ne vraća
);

drop trigger if exists trg_maksimir_zk_log_immutable on domovina_ai.maksimir_zk_log;
create trigger trg_maksimir_zk_log_immutable
  before update or delete on domovina_ai.maksimir_zk_log
  for each row execute function domovina_ai._maksimir_log_immutable();
drop trigger if exists trg_maksimir_zk_log_no_truncate on domovina_ai.maksimir_zk_log;
create trigger trg_maksimir_zk_log_no_truncate
  before truncate on domovina_ai.maksimir_zk_log
  for each statement execute function domovina_ai._maksimir_log_immutable();

-- Trenutni commitment po glasaču (operater zna vezu, javnost ne).
create table if not exists domovina_ai.maksimir_zk_members (
  voter_id   uuid primary key references domovina_ai.maksimir_voters(id) on delete cascade,
  commitment text not null unique,
  added_seq  bigint not null,
  created_at timestamptz not null default now()
);

alter table domovina_ai.maksimir_shares     enable row level security;
alter table domovina_ai.maksimir_zk_log     enable row level security;
alter table domovina_ai.maksimir_zk_members enable row level security;
revoke all on domovina_ai.maksimir_shares     from public, anon, authenticated;
revoke all on domovina_ai.maksimir_zk_log     from public, anon, authenticated;
revoke all on domovina_ai.maksimir_zk_members from public, anon, authenticated;
grant select, insert, update, delete on domovina_ai.maksimir_shares     to service_role;
grant select, insert                 on domovina_ai.maksimir_zk_log     to service_role;
grant select, insert, update, delete on domovina_ai.maksimir_zk_members to service_role;

-- ----- pomoćne ---------------------------------------------------------------
create or replace function domovina_ai._maksimir_new_share_id()
returns text language sql volatile set search_path = '' as $$
  select pg_catalog.substr(pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', ''), 1, 12);
$$;

-- Veličina polja BN254 (Semaphore): svaki javni signal mora biti manji.
create or replace function domovina_ai._maksimir_is_field(p text)
returns boolean language sql immutable set search_path = '' as $$
  select p is not null and p ~ '^[0-9]{1,78}$'
     and p::numeric < 21888242871839275222246405745257275088548364400416034343698204186575808495617::numeric;
$$;

create or replace function domovina_ai._maksimir_display_name(p_user_id uuid, p_mode text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_mode = 'full' and iv.first_name is not null
      then pg_catalog.initcap(pg_catalog.lower(iv.first_name)) || coalesce(' ' || pg_catalog.initcap(pg_catalog.lower(iv.last_name)), '')
    when p_mode = 'initial' and iv.first_name is not null
      then pg_catalog.initcap(pg_catalog.lower(iv.first_name)) || coalesce(' ' || pg_catalog.upper(pg_catalog.left(iv.last_name, 1)) || '.', '')
    else null
  end
  from (select 1) one
  left join public.identity_verifications iv on iv.user_id = p_user_id;
$$;

-- Glasač prijavljenog korisnika (verificiran, privola, zaključan za pisanje).
create or replace function domovina_ai._maksimir_voter_for_update(p_user_id uuid)
returns domovina_ai.maksimir_voters
language plpgsql security definer set search_path = '' as $$
declare
  v_hash  text;
  v_voter domovina_ai.maksimir_voters%rowtype;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then raise exception 'not_verified'; end if;
  select * into v_voter from domovina_ai.maksimir_voters where oib_hash = v_hash for update;
  if not found or v_voter.consented_at is null then raise exception 'terms_not_accepted'; end if;
  if not exists (select 1 from domovina_ai.maksimir_ballots b where b.voter_id = v_voter.id) then
    raise exception 'no_ballot';
  end if;
  return v_voter;
end;
$$;

create or replace function domovina_ai._maksimir_zk_append(p_op text, p_commitment text)
returns domovina_ai.maksimir_zk_log
language plpgsql security definer set search_path = '' as $$
declare
  v_prev domovina_ai.maksimir_zk_log%rowtype;
  v_row  domovina_ai.maksimir_zk_log%rowtype;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('domovina_ai.maksimir_zk_log')::bigint);
  select * into v_prev from domovina_ai.maksimir_zk_log order by seq desc limit 1;
  v_row.seq        := coalesce(v_prev.seq, 0) + 1;
  v_row.op         := p_op;
  v_row.commitment := p_commitment;
  v_row.prev_hash  := coalesce(v_prev.hash, pg_catalog.repeat('0', 64));
  v_row.hash := pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
      v_row.prev_hash || '|' || v_row.seq || '|' || v_row.op || '|' || v_row.commitment, 'UTF8')), 'hex');
  v_row.created_at := pg_catalog.now();
  insert into domovina_ai.maksimir_zk_log values (v_row.*);
  return v_row;
end;
$$;

create or replace function domovina_ai.maksimir_zk_head()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'seq',     coalesce((select max(seq) from domovina_ai.maksimir_zk_log), 0),
    'hash',    coalesce((select hash from domovina_ai.maksimir_zk_log order by seq desc limit 1), pg_catalog.repeat('0', 64)),
    'members', (select count(*)::int from domovina_ai.maksimir_zk_members));
$$;

revoke execute on function domovina_ai._maksimir_new_share_id() from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_is_field(text) from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_display_name(uuid, text) from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_voter_for_update(uuid) from public, anon, authenticated;
revoke execute on function domovina_ai._maksimir_zk_append(text, text) from public, anon, authenticated;
revoke execute on function domovina_ai.maksimir_zk_head() from public;
grant execute on function domovina_ai.maksimir_zk_head() to anon, authenticated, service_role;

-- ----- 1. javni prikaz ---------------------------------------------------------
create or replace function domovina_ai._maksimir_set_public_for(p_user_id uuid, p_mode text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_id    text;
begin
  if p_mode is not null and p_mode not in ('full', 'initial', 'anon') then
    raise exception 'invalid_mode';
  end if;
  if p_mode is null then
    -- isključivanje ne traži listić (glas je možda već povučen)
    update domovina_ai.maksimir_voters v set public_mode = null, public_at = null
      from public.identity_verifications iv
     where iv.user_id = p_user_id and v.oib_hash = iv.oib_hash;
    return domovina_ai._maksimir_ballot_of(p_user_id);
  end if;

  v_voter := domovina_ai._maksimir_voter_for_update(p_user_id);
  update domovina_ai.maksimir_voters
     set public_mode = p_mode, public_at = coalesce(public_at, pg_catalog.now())
   where id = v_voter.id;
  select id into v_id from domovina_ai.maksimir_shares where voter_id = v_voter.id;
  if v_id is null then
    insert into domovina_ai.maksimir_shares (id, kind, voter_id)
    values (domovina_ai._maksimir_new_share_id(), 'public', v_voter.id);
  end if;
  return domovina_ai._maksimir_ballot_of(p_user_id);
end;
$$;

create or replace function domovina_ai.maksimir_set_public(p_mode text)
returns jsonb language sql security definer set search_path = '' as $$
  select domovina_ai._maksimir_set_public_for((select auth.uid()), p_mode);
$$;

revoke execute on function domovina_ai._maksimir_set_public_for(uuid, text) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_set_public_for(uuid, text) to service_role;
revoke execute on function domovina_ai.maksimir_set_public(text) from public, anon;
grant execute on function domovina_ai.maksimir_set_public(text) to authenticated, service_role;

-- ----- 2. ZK: upis commitmenta ----------------------------------------------------
-- Novi ključ istog glasača zamjenjuje stari: 'remove' starog + 'add' novog.
-- Redoslijed zaključavanja: glasač → zapisnik grupe (kao i kod lanca listića).
create or replace function domovina_ai._maksimir_zk_register_for(p_user_id uuid, p_commitment text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_old   domovina_ai.maksimir_zk_members%rowtype;
  v_row   domovina_ai.maksimir_zk_log%rowtype;
begin
  if not domovina_ai._maksimir_is_field(p_commitment) or p_commitment = '0' then
    raise exception 'invalid_commitment';
  end if;
  v_voter := domovina_ai._maksimir_voter_for_update(p_user_id);

  select * into v_old from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;
  if found and v_old.commitment = p_commitment then
    return jsonb_build_object('seq', v_old.added_seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
  end if;
  if exists (select 1 from domovina_ai.maksimir_zk_members m where m.commitment = p_commitment) then
    raise exception 'commitment_taken';
  end if;
  if exists (select 1 from domovina_ai.maksimir_zk_log l where l.commitment = p_commitment) then
    raise exception 'commitment_taken';   -- uklonjeni commitment se ne smije vratiti (replay zapisnika)
  end if;

  if v_old.voter_id is not null then
    perform domovina_ai._maksimir_zk_append('remove', v_old.commitment);
    delete from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;
  end if;
  v_row := domovina_ai._maksimir_zk_append('add', p_commitment);
  insert into domovina_ai.maksimir_zk_members (voter_id, commitment, added_seq)
  values (v_voter.id, p_commitment, v_row.seq);

  return jsonb_build_object('seq', v_row.seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
end;
$$;

create or replace function domovina_ai.maksimir_zk_register(p_commitment text)
returns jsonb language sql security definer set search_path = '' as $$
  select domovina_ai._maksimir_zk_register_for((select auth.uid()), p_commitment);
$$;

revoke execute on function domovina_ai._maksimir_zk_register_for(uuid, text) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_zk_register_for(uuid, text) to service_role;
revoke execute on function domovina_ai.maksimir_zk_register(text) from public, anon;
grant execute on function domovina_ai.maksimir_zk_register(text) to authenticated, service_role;

-- ----- 2. ZK: javni zapisnik grupe (bez vremena upisa) --------------------------
create or replace function domovina_ai.maksimir_zk_group()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'head', domovina_ai.maksimir_zk_head(),
    'log',  coalesce((select jsonb_agg(jsonb_build_object(
                        'seq', l.seq, 'op', l.op, 'commitment', l.commitment,
                        'prev_hash', l.prev_hash, 'hash', l.hash) order by l.seq)
                        from domovina_ai.maksimir_zk_log l), '[]'::jsonb));
$$;

revoke execute on function domovina_ai.maksimir_zk_group() from public;
grant execute on function domovina_ai.maksimir_zk_group() to anon, authenticated, service_role;

-- ----- 2. ZK: spremanje dokaza (anon — bez veze na glasača) ---------------------
-- SQL provjerava oblik, fiksnu poruku/scope i da zk_seq postoji; SNARK provjerava
-- svaki preglednik. Isti nullifier (ista osoba, isti ključ) vraća postojeću objavu.
create or replace function domovina_ai.maksimir_zk_share(p_proof jsonb, p_zk_seq bigint)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_message constant text := '46779715467123036996841617194389431189336537137425384514209209627004761014272';
  c_scope   constant text := '49474226259215312994888701590181247581981161421217961257574660746611720716288';
  v_depth int;
  v_id    text;
  v_head  bigint;
begin
  -- `is distinct from`: nedostajući ključ daje NULL, a `NULL <> 'x'` nije istina.
  if jsonb_typeof(p_proof) is distinct from 'object'
     or jsonb_typeof(p_proof->'merkleTreeDepth') is distinct from 'number'
     or jsonb_typeof(p_proof->'points') is distinct from 'array'
     or jsonb_array_length(p_proof->'points') <> 8 then
    raise exception 'invalid_proof';
  end if;
  v_depth := (p_proof->>'merkleTreeDepth')::int;
  if (p_proof->>'merkleTreeDepth')::numeric <> v_depth or v_depth not between 1 and 32
     or not domovina_ai._maksimir_is_field(p_proof->>'merkleTreeRoot')
     or not domovina_ai._maksimir_is_field(p_proof->>'nullifier')
     or p_proof->>'message' is distinct from c_message
     or p_proof->>'scope'   is distinct from c_scope
     or exists (select 1 from jsonb_array_elements_text(p_proof->'points') x where not domovina_ai._maksimir_is_field(x)) then
    raise exception 'invalid_proof';
  end if;
  select coalesce(max(seq), 0) into v_head from domovina_ai.maksimir_zk_log;
  if p_zk_seq is null or p_zk_seq < 1 or p_zk_seq > v_head then
    raise exception 'unknown_zk_seq';
  end if;

  select id into v_id from domovina_ai.maksimir_shares where nullifier = p_proof->>'nullifier';
  if v_id is null then
    v_id := domovina_ai._maksimir_new_share_id();
    insert into domovina_ai.maksimir_shares (id, kind, proof, zk_seq, nullifier)
    values (v_id, 'zk',
            jsonb_build_object('merkleTreeDepth', v_depth,
                               'merkleTreeRoot', p_proof->>'merkleTreeRoot',
                               'nullifier', p_proof->>'nullifier',
                               'message', c_message, 'scope', c_scope,
                               'points', p_proof->'points'),
            p_zk_seq, p_proof->>'nullifier')
    on conflict (nullifier) do nothing;
    select id into v_id from domovina_ai.maksimir_shares where nullifier = p_proof->>'nullifier';
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

revoke execute on function domovina_ai.maksimir_zk_share(jsonb, bigint) from public;
grant execute on function domovina_ai.maksimir_zk_share(jsonb, bigint) to anon, authenticated, service_role;

-- ----- javno čitanje objave ---------------------------------------------------------
create or replace function domovina_ai._maksimir_public_card(p_voter_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'mode',       v.public_mode,
    'name',       domovina_ai._maksimir_display_name(v.user_id, v.public_mode),
    'pseudonym',  domovina_ai._maksimir_pseudonym(v.id),
    'revisions',  b.revisions,
    'updated_at', b.updated_at,
    'items',      coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'points', i.points, 'lead', e.lead)
                                  order by i.points desc, e.n)
                              from domovina_ai.maksimir_ballot_items i
                              join domovina_ai.maksimir_entries e on e.code = i.code
                             where i.voter_id = v.id), '[]'::jsonb),
    'receipt',    (select to_jsonb(l) from domovina_ai.maksimir_log l
                    where l.pseudonym = domovina_ai._maksimir_pseudonym(v.id)
                    order by l.seq desc limit 1))
  from domovina_ai.maksimir_voters v
  join domovina_ai.maksimir_ballots b on b.voter_id = v.id
  where v.id = p_voter_id and v.public_mode is not null;
$$;

revoke execute on function domovina_ai._maksimir_public_card(uuid) from public, anon, authenticated;

create or replace function domovina_ai.maksimir_share(p_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case s.kind
    when 'public' then jsonb_build_object(
      'id', s.id, 'kind', 'public', 'created_at', s.created_at,
      'card', domovina_ai._maksimir_public_card(s.voter_id))       -- null = više nije javno
    else jsonb_build_object(
      'id', s.id, 'kind', 'zk', 'created_at', s.created_at,
      'proof', s.proof, 'zk_seq', s.zk_seq)
  end
  from domovina_ai.maksimir_shares s where s.id = p_id;
$$;

revoke execute on function domovina_ai.maksimir_share(text) from public;
grant execute on function domovina_ai.maksimir_share(text) to anon, authenticated, service_role;

create or replace function domovina_ai.maksimir_public_ballots(p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'count', (select count(*)::int from domovina_ai.maksimir_voters v
               join domovina_ai.maksimir_ballots b on b.voter_id = v.id where v.public_mode is not null),
    'zk_shares', (select count(*)::int from domovina_ai.maksimir_shares where kind = 'zk'),
    'ballots', coalesce((
      select jsonb_agg(domovina_ai._maksimir_public_card(x.voter_id) || jsonb_build_object('id', x.id)
                       order by x.updated_at desc)
        from (select s.id, s.voter_id, b.updated_at
                from domovina_ai.maksimir_shares s
                join domovina_ai.maksimir_voters v on v.id = s.voter_id and v.public_mode is not null
                join domovina_ai.maksimir_ballots b on b.voter_id = v.id
               where s.kind = 'public'
               order by b.updated_at desc
               limit least(greatest(coalesce(p_limit, 100), 1), 500)) x), '[]'::jsonb));
$$;

revoke execute on function domovina_ai.maksimir_public_ballots(int) from public;
grant execute on function domovina_ai.maksimir_public_ballots(int) to anon, authenticated, service_role;

-- ----- maksimir_my_ballot: + public_mode, share_id, zk_commitment ---------------------
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
  v_share text;
  v_zk    text;
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
      select s.id into v_share from domovina_ai.maksimir_shares s where s.voter_id = v_voter.id;
      select m.commitment into v_zk from domovina_ai.maksimir_zk_members m where m.voter_id = v_voter.id;
    end if;
  end if;

  return jsonb_build_object(
    'verified',      v_hash is not null,
    'consented',     v_voter.consented_at is not null,
    'open',          domovina_ai._maksimir_is_open(),
    'items',         coalesce(v_items, '{}'::jsonb),
    'updated_at',    v_upd,
    'receipt',       v_rcpt,
    'public_mode',   v_voter.public_mode,
    'share_id',      v_share,
    'zk_commitment', v_zk
  );
end;
$$;

-- ----- snapshot v2: + vrh ZK zapisnika i broj javnih glasača ---------------------------
-- Dodana polja ne mijenjaju provjeru lanca listića (maksimir_verify.py ih čita samo ako postoje).
create or replace function domovina_ai.maksimir_snapshot()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'schema',        'maksimir-snapshot/2',
    'at',            pg_catalog.now(),
    'head',          domovina_ai.maksimir_log_head(),
    'zk',            domovina_ai.maksimir_zk_head(),
    'public_voters', (select count(*)::int from domovina_ai.maksimir_voters v
                       join domovina_ai.maksimir_ballots b on b.voter_id = v.id where v.public_mode is not null)
  ) || domovina_ai.maksimir_results();
$$;

select 'OK maksimir_share_zk' as status;
