-- =============================================================================
-- Stadion Maksimir — spajanje faze 1 (offchain) s glasanjem na lancu (MaksimirGlasanjeV1)
-- Nadogradnja na 20260925120000, 20260925160000 i 20260925170000.
-- Plan: github.com/stepanic/stadion-maksimir-natjecaj-2026 docs/blockchain/08-integracija-s-fazom-1.md
--
-- Što se mijenja:
--
-- 1. MREŽE. `maksimir_chains` je popis ugovora (Gnosis, Chiado, lokalni Hardhat) s
--    javnom konfiguracijom za web. `counts = true` znači da se listići s tog ugovora
--    broje u rezultat; samo takav ugovor zatvara listić faze 1 („prijenos”).
--    `maksimir_settings.active_chain_id/active_contract` je ugovor koji web koristi.
--
-- 2. ZASTAVICA. `maksimir_settings.chain_from`:
--      null         → faza 1 kao dosad
--      > now()      → najava prijelaza, faza 1 i dalje prima listiće
--      <= now()     → faza 1 zatvorena za listiće i ZK upis/objavu; lanac faze 1 javan
--    `closes_at` ostaje kraj cijelog glasanja (= closesAt ugovora).
--
-- 3. REGISTRAR. Edge funkcija `maksimir-register` (service_role) zove
--    _maksimir_chain_register_for: jedna osoba = jedan commitment po ugovoru. Na ugovoru
--    s `counts` registracija u ISTOJ transakciji povlači listić faze 1 (red revision 0 u
--    lancu = „prijenos”), pa se ista osoba nikad ne broji dvaput. Nakon toga
--    maksimir_cast_ballot toj osobi vraća `chain_registered` (i pri povratku, v. plan).
--
-- 4. KEYSTORE (ADR 0001). Šifrirani omot ključa glasača pod sha256(credentialId).
--    Bez korisnika, OIB-a i commitmenta; bez passkeyja beskoristan. Samo dodavanje.
--
-- 5. OBJAVE S LANCA. Javna objava listića s lanca: baza drži ime (kao i dosad) +
--    nullifier + ZK dokaz vlasništva (scope listića, poruka veže pseudonim glasača);
--    SNARK i listić provjerava preglednik posjetitelja s lanca. Anonimna objava na
--    lancu: baza drži samo kratku poveznicu (id → transakcija `share`).
--
-- Javni ugovor (novo ili izmijenjeno):
--   maksimir_chain_config()                         → jsonb (anon)
--   maksimir_accept_chain_terms()                   → jsonb (authenticated; uvjeti v2)
--   maksimir_keystore_put(p_hash, p_blob)           → jsonb (anon; samo dodaje)
--   maksimir_keystore_get(p_hash)                   → jsonb (anon)
--   maksimir_set_public_chain(p_mode, p_chain_id, p_contract, p_nullifier, p_proof) → jsonb (authenticated)
--   maksimir_chain_share(p_chain_id, p_contract, p_tx_hash) → jsonb (anon)
--   maksimir_results()     → + phase1_open, chain_open, chain_from, active_chain
--   maksimir_my_ballot()   → + pseudonym, chain_consented, chain_registrations, chain_public
--   maksimir_share(p_id)   → + kind 'chain'; javna kartica + chain
--   maksimir_snapshot()    → schema maksimir-snapshot/3 (+ chain_from, phase1_final)
--   maksimir_log()         → javan od least(closes_at, chain_from)
-- Service_role:
--   _maksimir_chain_register_for(p_user_id, p_chain_id, p_contract, p_commitment) → jsonb
-- Nove greške: chain_registered | unknown_chain | invalid_blob | keystore_exists |
--   invalid_tx | not_registered | chain_terms_not_accepted
-- =============================================================================

-- ----- 1. mreže ---------------------------------------------------------------------
create table if not exists domovina_ai.maksimir_chains (
  chain_id     bigint  not null check (chain_id > 0),
  contract     text    not null check (contract ~ '^0x[0-9a-f]{40}$'),
  label        text    not null unique check (label ~ '^[a-z0-9-]{1,32}$'),
  counts       boolean not null default false,
  rpc_url      text    not null,
  relayer_url  text,
  explorer_url text,
  semaphore    text    not null check (semaphore ~ '^0x[0-9a-f]{40}$'),
  group_id     text    not null check (group_id ~ '^[0-9]{1,78}$'),
  deploy_block bigint  not null check (deploy_block >= 0),
  created_at   timestamptz not null default now(),
  primary key (chain_id, contract)
);

alter table domovina_ai.maksimir_settings
  add column if not exists chain_from      timestamptz,
  add column if not exists active_chain_id bigint,
  add column if not exists active_contract text;

do $$ begin
  alter table domovina_ai.maksimir_settings
    add constraint maksimir_settings_active_chain
    foreign key (active_chain_id, active_contract) references domovina_ai.maksimir_chains (chain_id, contract);
exception when duplicate_object then null; end $$;

alter table domovina_ai.maksimir_voters
  add column if not exists chain_consented_at timestamptz;

-- ----- 2. registracije (jedna osoba = jedan commitment po ugovoru) --------------------
create table if not exists domovina_ai.maksimir_chain_registrations (
  chain_id     bigint not null,
  contract     text   not null,
  oib_hash     text   not null,
  voter_id     uuid   not null references domovina_ai.maksimir_voters(id),   -- bez cascade: registracija je trajna
  commitment   text   not null check (commitment ~ '^[0-9]{1,78}$'),
  counts       boolean not null,
  transfer_seq bigint,                                   -- red „prijenos” u maksimir_log (ako je bio listić)
  created_at   timestamptz not null default now(),
  primary key (chain_id, contract, oib_hash),
  unique (chain_id, contract, commitment),
  foreign key (chain_id, contract) references domovina_ai.maksimir_chains (chain_id, contract)
);

create index if not exists ix_maksimir_chain_reg_voter on domovina_ai.maksimir_chain_registrations (voter_id);

-- ----- 3. keystore -----------------------------------------------------------------------
create table if not exists domovina_ai.maksimir_keystore (
  credential_id_hash text primary key check (credential_id_hash ~ '^[0-9a-f]{64}$'),
  blob       jsonb not null,
  created_at timestamptz not null default now()
);

-- ----- 4. javna objava listića s lanca --------------------------------------------------
create table if not exists domovina_ai.maksimir_chain_public (
  voter_id   uuid primary key references domovina_ai.maksimir_voters(id) on delete cascade,
  chain_id   bigint not null,
  contract   text   not null,
  nullifier  text   not null check (nullifier ~ '^[0-9]{1,78}$'),
  proof      jsonb  not null,
  created_at timestamptz not null default now(),
  foreign key (chain_id, contract) references domovina_ai.maksimir_chains (chain_id, contract)
);

-- anonimna objava na lancu: kratka poveznica id → transakcija
alter table domovina_ai.maksimir_shares
  add column if not exists chain_id bigint,
  add column if not exists contract text,
  add column if not exists tx_hash  text unique check (tx_hash ~ '^0x[0-9a-f]{64}$');

alter table domovina_ai.maksimir_shares drop constraint if exists maksimir_shares_kind_check;
alter table domovina_ai.maksimir_shares add constraint maksimir_shares_kind_check check (kind in ('public', 'zk', 'chain'));
alter table domovina_ai.maksimir_shares drop constraint if exists maksimir_shares_shape;
alter table domovina_ai.maksimir_shares add constraint maksimir_shares_shape check (
  (kind = 'public' and voter_id is not null and proof is null and nullifier is null and tx_hash is null)
  or (kind = 'zk' and voter_id is null and proof is not null and nullifier is not null and zk_seq >= 1 and tx_hash is null)
  or (kind = 'chain' and voter_id is null and proof is null and nullifier is null
      and chain_id is not null and contract is not null and tx_hash is not null));

do $$ begin
  alter table domovina_ai.maksimir_shares
    add constraint maksimir_shares_chain foreign key (chain_id, contract)
    references domovina_ai.maksimir_chains (chain_id, contract);
exception when duplicate_object then null; end $$;

alter table domovina_ai.maksimir_chains              enable row level security;
alter table domovina_ai.maksimir_chain_registrations enable row level security;
alter table domovina_ai.maksimir_keystore            enable row level security;
alter table domovina_ai.maksimir_chain_public        enable row level security;
revoke all on domovina_ai.maksimir_chains              from public, anon, authenticated;
revoke all on domovina_ai.maksimir_chain_registrations from public, anon, authenticated;
revoke all on domovina_ai.maksimir_keystore            from public, anon, authenticated;
revoke all on domovina_ai.maksimir_chain_public        from public, anon, authenticated;
grant select, insert, update, delete on domovina_ai.maksimir_chains              to service_role;
grant select, insert, update         on domovina_ai.maksimir_chain_registrations to service_role;
grant select, insert                 on domovina_ai.maksimir_keystore            to service_role;
grant select, insert, update, delete on domovina_ai.maksimir_chain_public        to service_role;

-- ----- faze -------------------------------------------------------------------------------
-- Faza 1 prima listiće (i ZK upis/objavu): unutar roka i prije chain_from.
create or replace function domovina_ai._maksimir_is_open()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select (s.opens_at is null or pg_catalog.now() >= s.opens_at)
       and (s.closes_at is null or pg_catalog.now() < s.closes_at)
       and (s.chain_from is null or pg_catalog.now() < s.chain_from)
      from domovina_ai.maksimir_settings s where s.id
  ), false);
$$;

-- Registracija na lancu: unutar roka (ugovor ionako odbija nakon closesAt).
create or replace function domovina_ai._maksimir_chain_open()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select (s.opens_at is null or pg_catalog.now() >= s.opens_at)
       and (s.closes_at is null or pg_catalog.now() < s.closes_at)
      from domovina_ai.maksimir_settings s where s.id
  ), false);
$$;

revoke execute on function domovina_ai._maksimir_chain_open() from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_chain_open() to service_role;

create or replace function domovina_ai._maksimir_chain_json(c domovina_ai.maksimir_chains)
returns jsonb language sql immutable set search_path = '' as $$
  select case when c.chain_id is null then null else jsonb_build_object(
    'chainId', c.chain_id, 'contract', c.contract, 'label', c.label, 'counts', c.counts,
    'rpcUrl', c.rpc_url, 'relayerUrl', c.relayer_url, 'explorerUrl', c.explorer_url,
    'semaphore', c.semaphore, 'groupId', c.group_id, 'deployBlock', c.deploy_block) end;
$$;

revoke execute on function domovina_ai._maksimir_chain_json(domovina_ai.maksimir_chains) from public, anon, authenticated;

create or replace function domovina_ai.maksimir_chain_config()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'chain_from',  (select chain_from from domovina_ai.maksimir_settings where id),
    'active',      (select domovina_ai._maksimir_chain_json(c)
                      from domovina_ai.maksimir_settings s
                      join domovina_ai.maksimir_chains c
                        on c.chain_id = s.active_chain_id and c.contract = s.active_contract
                     where s.id),
    'chains',      coalesce((select jsonb_agg(domovina_ai._maksimir_chain_json(c) order by c.counts desc, c.label)
                               from domovina_ai.maksimir_chains c), '[]'::jsonb));
$$;

revoke execute on function domovina_ai.maksimir_chain_config() from public;
grant execute on function domovina_ai.maksimir_chain_config() to anon, authenticated, service_role;

-- ----- lanac faze 1 javan od prijelaza ------------------------------------------------------
create or replace function domovina_ai.maksimir_log(p_after bigint default 0, p_limit int default 1000)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_public timestamptz;
begin
  select least(closes_at, chain_from) into v_public from domovina_ai.maksimir_settings where id;
  if v_public is null or pg_catalog.now() < v_public then
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

-- ----- predaja listića faze 1: + zatvaranje prijelazom i registracijom na lancu --------------
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

  -- Tko je upisan na ugovor koji se broji, glasa samo na lancu (i pri povratku na fazu 1).
  if exists (select 1 from domovina_ai.maksimir_chain_registrations cr
              where cr.oib_hash = v_hash and cr.counts) then
    raise exception 'chain_registered';
  end if;

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

  insert into domovina_ai.maksimir_voters (oib_hash, user_id)
  values (v_hash, p_user_id)
  on conflict (oib_hash) do update set user_id = excluded.user_id
  returning * into v_voter;

  if v_voter.consented_at is null then
    raise exception 'terms_not_accepted';
  end if;

  select * into v_voter from domovina_ai.maksimir_voters where id = v_voter.id for update;

  -- Registracija na lancu mogla se dogoditi dok smo čekali zaključavanje.
  if exists (select 1 from domovina_ai.maksimir_chain_registrations cr
              where cr.oib_hash = v_hash and cr.counts) then
    raise exception 'chain_registered';
  end if;

  if v_count = 0 then
    delete from domovina_ai.maksimir_ballots where voter_id = v_voter.id;
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

-- ----- ZK faze 1: upis i objava zatvaraju se prijelazom ----------------------------------------
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
  if not domovina_ai._maksimir_is_open() then
    raise exception 'voting_closed';
  end if;
  v_voter := domovina_ai._maksimir_voter_for_update(p_user_id);

  select * into v_old from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;
  if found and v_old.commitment = p_commitment then
    return jsonb_build_object('seq', v_old.added_seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
  end if;
  if exists (select 1 from domovina_ai.maksimir_zk_log l where l.commitment = p_commitment) then
    raise exception 'commitment_taken';
  end if;

  if v_old.voter_id is not null then
    delete from domovina_ai.maksimir_zk_members where voter_id = v_voter.id;   -- okidač: 'remove'
  end if;
  v_row := domovina_ai._maksimir_zk_append('add', p_commitment);
  insert into domovina_ai.maksimir_zk_members (voter_id, commitment, added_seq)
  values (v_voter.id, p_commitment, v_row.seq);

  return jsonb_build_object('seq', v_row.seq, 'commitment', p_commitment, 'head', domovina_ai.maksimir_zk_head());
end;
$$;

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
  if not domovina_ai._maksimir_is_open() then
    raise exception 'voting_closed';
  end if;
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

-- ----- uvjeti v2 (listić javan pod pseudonimom na lancu) -------------------------------------------
create or replace function domovina_ai._maksimir_accept_chain_terms_for(p_user_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_hash text;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then
    raise exception 'not_verified';
  end if;
  insert into domovina_ai.maksimir_voters (oib_hash, user_id, consented_at, chain_consented_at)
  values (v_hash, p_user_id, pg_catalog.now(), pg_catalog.now())
  on conflict (oib_hash) do update
    set user_id            = excluded.user_id,
        consented_at       = coalesce(domovina_ai.maksimir_voters.consented_at, excluded.consented_at),
        chain_consented_at = coalesce(domovina_ai.maksimir_voters.chain_consented_at, excluded.chain_consented_at);
  return domovina_ai._maksimir_ballot_of(p_user_id);
end;
$$;

revoke execute on function domovina_ai._maksimir_accept_chain_terms_for(uuid) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_accept_chain_terms_for(uuid) to service_role;

create or replace function domovina_ai.maksimir_accept_chain_terms()
returns jsonb language sql security definer set search_path = '' as $$
  select domovina_ai._maksimir_accept_chain_terms_for((select auth.uid()));
$$;

revoke execute on function domovina_ai.maksimir_accept_chain_terms() from public, anon;
grant execute on function domovina_ai.maksimir_accept_chain_terms() to authenticated, service_role;

-- ----- registrar (zove ga samo edge funkcija maksimir-register) ------------------------------------
-- Vraća { status: ok | already_registered | commitment_taken, … }; greške oblika su iznimke.
create or replace function domovina_ai._maksimir_chain_register_for(
  p_user_id uuid, p_chain_id bigint, p_contract text, p_commitment text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash  text;
  v_chain domovina_ai.maksimir_chains%rowtype;
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_reg   domovina_ai.maksimir_chain_registrations%rowtype;
  v_items jsonb;
  v_log   domovina_ai.maksimir_log%rowtype;
begin
  if p_user_id is not null then
    select iv.oib_hash into v_hash from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then
    raise exception 'not_verified';
  end if;
  select * into v_chain from domovina_ai.maksimir_chains
   where chain_id = p_chain_id and contract = pg_catalog.lower(p_contract);
  if not found then
    raise exception 'unknown_chain';
  end if;
  if not domovina_ai._maksimir_is_field(p_commitment) or p_commitment = '0' then
    raise exception 'invalid_commitment';
  end if;
  if not domovina_ai._maksimir_chain_open() then
    raise exception 'voting_closed';
  end if;

  select * into v_voter from domovina_ai.maksimir_voters where oib_hash = v_hash for update;
  if not found or v_voter.chain_consented_at is null then
    raise exception 'chain_terms_not_accepted';
  end if;

  select * into v_reg from domovina_ai.maksimir_chain_registrations
   where chain_id = v_chain.chain_id and contract = v_chain.contract and oib_hash = v_hash;
  if found then
    if v_reg.commitment = p_commitment then
      return jsonb_build_object('status', 'ok', 'commitment', v_reg.commitment, 'existing', true,
                                'transfer_seq', v_reg.transfer_seq, 'chain', domovina_ai._maksimir_chain_json(v_chain));
    end if;
    return jsonb_build_object('status', 'already_registered', 'commitment', v_reg.commitment);
  end if;
  if exists (select 1 from domovina_ai.maksimir_chain_registrations
              where chain_id = v_chain.chain_id and contract = v_chain.contract and commitment = p_commitment) then
    return jsonb_build_object('status', 'commitment_taken');
  end if;

  v_reg.chain_id   := v_chain.chain_id;
  v_reg.contract   := v_chain.contract;
  v_reg.oib_hash   := v_hash;
  v_reg.voter_id   := v_voter.id;
  v_reg.commitment := p_commitment;
  v_reg.counts     := v_chain.counts;
  v_reg.created_at := pg_catalog.now();

  -- Prijenos: listić faze 1 prestaje se brojati u istoj transakciji (revision 0 u lancu).
  if v_chain.counts then
    select jsonb_object_agg(i.code, i.points) into v_items
      from domovina_ai.maksimir_ballot_items i where i.voter_id = v_voter.id;
    delete from domovina_ai.maksimir_ballots where voter_id = v_voter.id;
    if found then
      v_log := domovina_ai._maksimir_append_log(v_voter.id, 0, '{}'::jsonb);
      v_reg.transfer_seq := v_log.seq;
    end if;
  end if;

  insert into domovina_ai.maksimir_chain_registrations values (v_reg.*);
  return jsonb_build_object('status', 'ok', 'commitment', p_commitment, 'existing', false,
                            'transfer_seq', v_reg.transfer_seq, 'transferred', coalesce(v_items, '{}'::jsonb),
                            'chain', domovina_ai._maksimir_chain_json(v_chain));
end;
$$;

revoke execute on function domovina_ai._maksimir_chain_register_for(uuid, bigint, text, text) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_chain_register_for(uuid, bigint, text, text) to service_role;

-- ----- keystore (anon; samo dodaje) -------------------------------------------------------------------
create or replace function domovina_ai.maksimir_keystore_put(p_hash text, p_blob jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old jsonb;
begin
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_blob';
  end if;
  if jsonb_typeof(p_blob) is distinct from 'object' or pg_catalog.octet_length(p_blob::text) > 2048 then
    raise exception 'invalid_blob';
  end if;
  insert into domovina_ai.maksimir_keystore (credential_id_hash, blob) values (p_hash, p_blob)
  on conflict (credential_id_hash) do nothing;
  select blob into v_old from domovina_ai.maksimir_keystore where credential_id_hash = p_hash;
  if v_old <> p_blob then
    raise exception 'keystore_exists';   -- omot se ne prepisuje (v. ADR 0001, plan 08)
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function domovina_ai.maksimir_keystore_get(p_hash text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select blob from domovina_ai.maksimir_keystore where credential_id_hash = p_hash;
$$;

revoke execute on function domovina_ai.maksimir_keystore_put(text, jsonb) from public;
revoke execute on function domovina_ai.maksimir_keystore_get(text) from public;
grant execute on function domovina_ai.maksimir_keystore_put(text, jsonb) to anon, authenticated, service_role;
grant execute on function domovina_ai.maksimir_keystore_get(text) to anon, authenticated, service_role;

-- ----- javna objava listića s lanca ------------------------------------------------------------------
-- Dokaz vlasništva nullifiera: Semaphore dokaz sa scope = BALLOT_SCOPE (isti nullifier kao
-- listić) i porukom keccak256(abi.encode(keccak256("maksimir-javno"), chainId, ugovor,
-- bytes32 pseudonim)). SQL provjerava oblik i scope; poruku, SNARK i korijen provjerava
-- preglednik posjetitelja (Postgres nema keccak ni pairing).
create or replace function domovina_ai._maksimir_set_public_chain_for(
  p_user_id uuid, p_mode text, p_chain_id bigint, p_contract text, p_nullifier text, p_proof jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c_ballot_scope constant text := '49474226259215312994888701590182260559525090119511958701658821262471327645696';
  v_hash  text;
  v_voter domovina_ai.maksimir_voters%rowtype;
  v_depth int;
begin
  if p_mode is null or p_mode not in ('full', 'initial', 'anon') then
    raise exception 'invalid_mode';
  end if;
  if p_user_id is not null then
    select iv.oib_hash into v_hash from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then
    raise exception 'not_verified';
  end if;
  select * into v_voter from domovina_ai.maksimir_voters where oib_hash = v_hash for update;
  if not found or v_voter.chain_consented_at is null then
    raise exception 'chain_terms_not_accepted';
  end if;
  if not exists (select 1 from domovina_ai.maksimir_chain_registrations cr
                  where cr.oib_hash = v_hash and cr.chain_id = p_chain_id
                    and cr.contract = pg_catalog.lower(p_contract)) then
    raise exception 'not_registered';
  end if;

  if jsonb_typeof(p_proof) is distinct from 'object'
     or jsonb_typeof(p_proof->'merkleTreeDepth') is distinct from 'number'
     or jsonb_typeof(p_proof->'points') is distinct from 'array'
     or jsonb_array_length(p_proof->'points') <> 8 then
    raise exception 'invalid_proof';
  end if;
  v_depth := (p_proof->>'merkleTreeDepth')::int;
  if (p_proof->>'merkleTreeDepth')::numeric <> v_depth or v_depth not between 1 and 32
     or not domovina_ai._maksimir_is_field(p_proof->>'merkleTreeRoot')
     or p_proof->>'nullifier' is distinct from p_nullifier
     or not domovina_ai._maksimir_is_field(p_nullifier)
     or not (p_proof->>'message') ~ '^[0-9]{1,78}$'
     or p_proof->>'scope' is distinct from c_ballot_scope
     or exists (select 1 from jsonb_array_elements_text(p_proof->'points') x where not domovina_ai._maksimir_is_field(x)) then
    raise exception 'invalid_proof';
  end if;

  insert into domovina_ai.maksimir_chain_public (voter_id, chain_id, contract, nullifier, proof)
  values (v_voter.id, p_chain_id, pg_catalog.lower(p_contract), p_nullifier,
          jsonb_build_object('merkleTreeDepth', v_depth,
                             'merkleTreeRoot', p_proof->>'merkleTreeRoot',
                             'nullifier', p_nullifier,
                             'message', p_proof->>'message',
                             'scope', c_ballot_scope,
                             'points', p_proof->'points'))
  on conflict (voter_id) do update
    set chain_id = excluded.chain_id, contract = excluded.contract,
        nullifier = excluded.nullifier, proof = excluded.proof, created_at = pg_catalog.now();

  update domovina_ai.maksimir_voters
     set public_mode = p_mode, public_at = coalesce(public_at, pg_catalog.now())
   where id = v_voter.id;
  if not exists (select 1 from domovina_ai.maksimir_shares where voter_id = v_voter.id) then
    insert into domovina_ai.maksimir_shares (id, kind, voter_id)
    values (domovina_ai._maksimir_new_share_id(), 'public', v_voter.id);
  end if;
  return domovina_ai._maksimir_ballot_of(p_user_id);
end;
$$;

revoke execute on function domovina_ai._maksimir_set_public_chain_for(uuid, text, bigint, text, text, jsonb) from public, anon, authenticated;
grant execute on function domovina_ai._maksimir_set_public_chain_for(uuid, text, bigint, text, text, jsonb) to service_role;

create or replace function domovina_ai.maksimir_set_public_chain(
  p_mode text, p_chain_id bigint, p_contract text, p_nullifier text, p_proof jsonb)
returns jsonb language sql security definer set search_path = '' as $$
  select domovina_ai._maksimir_set_public_chain_for((select auth.uid()), p_mode, p_chain_id, p_contract, p_nullifier, p_proof);
$$;

revoke execute on function domovina_ai.maksimir_set_public_chain(text, bigint, text, text, jsonb) from public, anon;
grant execute on function domovina_ai.maksimir_set_public_chain(text, bigint, text, text, jsonb) to authenticated, service_role;

-- Promjena oblika imena (ili ponovno uključivanje) i za glasača čiji je listić na lancu:
-- dosad je traženo da postoji listić faze 1 (no_ballot), a nakon prijenosa ga više nema.
create or replace function domovina_ai._maksimir_set_public_for(p_user_id uuid, p_mode text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_hash  text;
  v_voter domovina_ai.maksimir_voters%rowtype;
begin
  if p_mode is not null and p_mode not in ('full', 'initial', 'anon') then
    raise exception 'invalid_mode';
  end if;
  if p_mode is null then
    update domovina_ai.maksimir_voters v set public_mode = null, public_at = null
      from public.identity_verifications iv
     where iv.user_id = p_user_id and v.oib_hash = iv.oib_hash;
    return domovina_ai._maksimir_ballot_of(p_user_id);
  end if;

  if p_user_id is not null then
    select iv.oib_hash into v_hash from public.identity_verifications iv where iv.user_id = p_user_id;
  end if;
  if v_hash is null then raise exception 'not_verified'; end if;
  select * into v_voter from domovina_ai.maksimir_voters where oib_hash = v_hash for update;
  if not found or v_voter.consented_at is null then raise exception 'terms_not_accepted'; end if;
  if not exists (select 1 from domovina_ai.maksimir_ballots b where b.voter_id = v_voter.id)
     and not exists (select 1 from domovina_ai.maksimir_chain_public cp where cp.voter_id = v_voter.id) then
    raise exception 'no_ballot';
  end if;

  update domovina_ai.maksimir_voters
     set public_mode = p_mode, public_at = coalesce(public_at, pg_catalog.now())
   where id = v_voter.id;
  if not exists (select 1 from domovina_ai.maksimir_shares where voter_id = v_voter.id) then
    insert into domovina_ai.maksimir_shares (id, kind, voter_id)
    values (domovina_ai._maksimir_new_share_id(), 'public', v_voter.id);
  end if;
  return domovina_ai._maksimir_ballot_of(p_user_id);
end;
$$;

-- ----- anonimna objava na lancu: kratka poveznica ----------------------------------------------------
-- Baza ne zna je li transakcija stvarna; stranica objave to provjerava s lanca (AnonymousShare).
-- Ključ je tx_hash: ista transakcija uvijek daje istu poveznicu.
create or replace function domovina_ai.maksimir_chain_share(p_chain_id bigint, p_contract text, p_tx_hash text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_id text;
begin
  if p_tx_hash is null or pg_catalog.lower(p_tx_hash) !~ '^0x[0-9a-f]{64}$' then
    raise exception 'invalid_tx';
  end if;
  if not exists (select 1 from domovina_ai.maksimir_chains
                  where chain_id = p_chain_id and contract = pg_catalog.lower(p_contract)) then
    raise exception 'unknown_chain';
  end if;
  insert into domovina_ai.maksimir_shares (id, kind, chain_id, contract, tx_hash)
  values (domovina_ai._maksimir_new_share_id(), 'chain', p_chain_id, pg_catalog.lower(p_contract), pg_catalog.lower(p_tx_hash))
  on conflict (tx_hash) do nothing;
  select id into v_id from domovina_ai.maksimir_shares where tx_hash = pg_catalog.lower(p_tx_hash);
  return jsonb_build_object('id', v_id);
end;
$$;

revoke execute on function domovina_ai.maksimir_chain_share(bigint, text, text) from public;
grant execute on function domovina_ai.maksimir_chain_share(bigint, text, text) to anon, authenticated, service_role;

-- ----- javna kartica: listić faze 1 i/ili listić s lanca ----------------------------------------------
create or replace function domovina_ai._maksimir_public_card(p_voter_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'mode',       v.public_mode,
    'name',       domovina_ai._maksimir_display_name(v.user_id, v.public_mode),
    'pseudonym',  domovina_ai._maksimir_pseudonym(v.id),
    'revisions',  coalesce(b.revisions, 0),
    'updated_at', coalesce(b.updated_at, cp.created_at),
    'items',      coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'points', i.points, 'lead', e.lead)
                                  order by i.points desc, e.n)
                              from domovina_ai.maksimir_ballot_items i
                              join domovina_ai.maksimir_entries e on e.code = i.code
                             where i.voter_id = v.id), '[]'::jsonb),
    'receipt',    (select to_jsonb(l) from domovina_ai.maksimir_log l
                    where l.pseudonym = domovina_ai._maksimir_pseudonym(v.id)
                    order by l.seq desc limit 1),
    'chain',      case when cp.voter_id is null then null else jsonb_build_object(
                    'chainId', cp.chain_id, 'contract', cp.contract,
                    'nullifier', cp.nullifier, 'proof', cp.proof) end)
  from domovina_ai.maksimir_voters v
  left join domovina_ai.maksimir_ballots b on b.voter_id = v.id
  left join domovina_ai.maksimir_chain_public cp on cp.voter_id = v.id
  where v.id = p_voter_id and v.public_mode is not null
    and (b.voter_id is not null or cp.voter_id is not null);
$$;

create or replace function domovina_ai.maksimir_share(p_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case s.kind
    when 'public' then jsonb_build_object(
      'id', s.id, 'kind', 'public', 'created_at', s.created_at,
      'card', domovina_ai._maksimir_public_card(s.voter_id))
    when 'chain' then jsonb_build_object(
      'id', s.id, 'kind', 'chain', 'created_at', s.created_at,
      'chainId', s.chain_id, 'contract', s.contract, 'txHash', s.tx_hash)
    else jsonb_build_object(
      'id', s.id, 'kind', 'zk', 'created_at', s.created_at,
      'proof', s.proof, 'zk_seq', s.zk_seq)
  end
  from domovina_ai.maksimir_shares s where s.id = p_id;
$$;

create or replace function domovina_ai.maksimir_public_ballots(p_limit int default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  with pub as (
    select s.id, s.voter_id, coalesce(b.updated_at, cp.created_at) as updated_at
      from domovina_ai.maksimir_shares s
      join domovina_ai.maksimir_voters v on v.id = s.voter_id and v.public_mode is not null
      left join domovina_ai.maksimir_ballots b on b.voter_id = v.id
      left join domovina_ai.maksimir_chain_public cp on cp.voter_id = v.id
     where s.kind = 'public' and (b.voter_id is not null or cp.voter_id is not null))
  select jsonb_build_object(
    'count',     (select count(*)::int from pub),
    'zk_shares', (select count(*)::int from domovina_ai.maksimir_shares where kind in ('zk', 'chain')),
    'ballots',   coalesce((
      select jsonb_agg(domovina_ai._maksimir_public_card(x.voter_id) || jsonb_build_object('id', x.id)
                       order by x.updated_at desc)
        from (select * from pub order by updated_at desc
               limit least(greatest(coalesce(p_limit, 100), 1), 500)) x), '[]'::jsonb));
$$;

-- ----- moj listić: + pseudonim, uvjeti v2, registracije, javni listić s lanca ----------------------------
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
  v_regs  jsonb;
  v_cpub  jsonb;
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
      select to_jsonb(l) into v_rcpt
        from domovina_ai.maksimir_log l
       where l.pseudonym = domovina_ai._maksimir_pseudonym(v_voter.id)
       order by l.seq desc limit 1;
      select s.id into v_share from domovina_ai.maksimir_shares s where s.voter_id = v_voter.id;
      select m.commitment into v_zk from domovina_ai.maksimir_zk_members m where m.voter_id = v_voter.id;
      select cp_json into v_cpub from (
        select jsonb_build_object('chainId', cp.chain_id, 'contract', cp.contract, 'nullifier', cp.nullifier) as cp_json
          from domovina_ai.maksimir_chain_public cp where cp.voter_id = v_voter.id) q;
    end if;
    select jsonb_agg(jsonb_build_object('chainId', cr.chain_id, 'contract', cr.contract,
                                        'commitment', cr.commitment, 'counts', cr.counts,
                                        'transfer_seq', cr.transfer_seq) order by cr.created_at)
      into v_regs
      from domovina_ai.maksimir_chain_registrations cr where cr.oib_hash = v_hash;
  end if;

  return jsonb_build_object(
    'verified',            v_hash is not null,
    'consented',           v_voter.consented_at is not null,
    'chain_consented',     v_voter.chain_consented_at is not null,
    'open',                domovina_ai._maksimir_is_open(),
    'items',               coalesce(v_items, '{}'::jsonb),
    'updated_at',          v_upd,
    'receipt',             v_rcpt,
    'pseudonym',           case when v_voter.id is null then null else domovina_ai._maksimir_pseudonym(v_voter.id) end,
    'public_mode',         v_voter.public_mode,
    'share_id',            v_share,
    'zk_commitment',       v_zk,
    'chain_registrations', coalesce(v_regs, '[]'::jsonb),
    'chain_public',        v_cpub
  );
end;
$$;

-- ----- rezultati: + faza -------------------------------------------------------------------------------
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
    'open',        domovina_ai._maksimir_is_open(),
    'phase1_open', domovina_ai._maksimir_is_open(),
    'chain_open',  domovina_ai._maksimir_chain_open(),
    'opens_at',    (select opens_at   from domovina_ai.maksimir_settings where id),
    'closes_at',   (select closes_at  from domovina_ai.maksimir_settings where id),
    'chain_from',  (select chain_from from domovina_ai.maksimir_settings where id),
    'voters',      v.n,
    'results',     coalesce((
      select jsonb_agg(jsonb_build_object(
               'code', t.code, 'points', t.points, 'backers', t.backers,
               'share', case when v.n = 0 then 0
                             else round(t.points::numeric / v.n, 2) end)
             order by t.points desc, t.n)
        from t), '[]'::jsonb)
  )
  from v;
$$;

-- ----- snapshot v3: + prijelaz (stanje lanca dodaje scripts/maksimir_checkpoint.py) -------------------
create or replace function domovina_ai.maksimir_snapshot()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'schema',        'maksimir-snapshot/3',
    'at',            pg_catalog.now(),
    'head',          domovina_ai.maksimir_log_head(),
    'zk',            domovina_ai.maksimir_zk_head(),
    'chain_from',    (select chain_from from domovina_ai.maksimir_settings where id),
    'phase1_final',  coalesce((select chain_from <= pg_catalog.now() from domovina_ai.maksimir_settings where id), false),
    'public_voters', (select count(*)::int from domovina_ai.maksimir_voters v
                       left join domovina_ai.maksimir_ballots b on b.voter_id = v.id
                       left join domovina_ai.maksimir_chain_public cp on cp.voter_id = v.id
                      where v.public_mode is not null and (b.voter_id is not null or cp.voter_id is not null))
  ) || domovina_ai.maksimir_results();
$$;

select 'OK maksimir_chain' as status;
