-- =============================================================================
-- Događaji (U1) — Stripe rail: offchain naplata narudžbi ulaznica
-- Reference: domovina-ulaznice/docs/05-podatkovni-model.md §2,
--            domovina-ulaznice/docs/03-stripe-connect-0-posto.md,
--            domovina-ulaznice/docs/handoffs/u1-stripe-rail-backend.md
--
-- Postojeći onchain put (20260716120200 confirm_ticket_order) ostaje NETAKNUT.
-- Ova migracija dodaje drugi rail uz istu jezgru (events/tiers/contributions/
-- tickets), bez ijedne nove tablice ulaznica:
--
--   1. pinka_finance.organizer_payment_rails — Stripe Connect stanje po org
--      accountu (acct_…, charges/payouts enabled, invoice provider). Odvojena
--      tablica jer public.accounts je core shema koju dijele svi proizvodi.
--   2. contributions.payment_rail / external_payment_ref / buyer_email +
--      UNIQUE (payment_rail, external_payment_ref) — idempotencija plaćanja je
--      u BAZI, ne u aplikacijskom kodu (isti princip kao (tx_hash, log_index)).
--   3. confirm_ticket_order_offchain() — blizanac confirm_ticket_order sa
--      istom state-machine, istim izdavanjem ulaznica i istim audit tragom,
--      ali s (rail, external_ref) umjesto (tx_hash, log_index, from).
--
-- Model naplate: Stripe Connect DIRECT CHARGE na račun organizatora, 0 %
-- provizije. Novac NIKAD ne prolazi kroz platformu i backend NIKAD ne
-- razgovara sa Stripeom — jedini Stripe klijent je Cloudflare Worker
-- (domovina-ulaznice). Ovdje se bilježi samo ISHOD koji je Worker već
-- kriptografski verificirao (Stripe webhook potpis).
--
-- ⚠️ Sigurnosna razlika prema onchain putu: tamo je "onchain verifikacija JE
-- autorizacija" (dokaz je blockchain). Ovdje dokaz uplate postoji samo kao
-- Stripe potpis koji verificira Worker → edge funkcija events-stripe-confirm
-- MORA biti HMAC-zaštićena (EVENTS_STRIPE_CONFIRM_SECRET). Otvorena funkcija =
-- besplatne ulaznice.
--
-- Poslovni ne-uspjesi se vraćaju kao status jsonb, NIKAD kao exception —
-- exception bi rollbackao audit zapis u contribution_events (lekcija iz
-- safe-wallet-monorepo/docs/whitelabel-wallet/13-lekcije-sesije-dogadjaji.md §3).
--
-- Idempotentna (drugi run = no-op): if not exists / create or replace /
-- drop constraint if exists prije add.
-- =============================================================================

-- ----- 1. organizer_payment_rails --------------------------------------------
-- Stripe stanje dolazi ISKLJUČIVO iz webhooka (account.updated) preko Workera
-- sa service ključem — nikad iz browsera. Zato: select org adminu, write samo
-- service_role.
create table if not exists pinka_finance.organizer_payment_rails (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  stripe_account_id text unique,                            -- acct_… ; NIKAD u javnom feedu
  stripe_charges_enabled boolean not null default false,    -- iz account.updated webhooka
  stripe_payouts_enabled boolean not null default false,
  invoice_provider text not null default 'organizator',     -- organizator|fira|domovina_fiskal
  invoice_config jsonb,                                     -- tenant id / referenca na tajnu — NIKAD plaintext tajna
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint opr_stripe_acct_format
    check (stripe_account_id is null or stripe_account_id ~ '^acct_[A-Za-z0-9]+$'),
  constraint opr_invoice_provider_chk
    check (invoice_provider in ('organizator', 'fira', 'domovina_fiskal')),
  constraint opr_invoice_config_size
    check (invoice_config is null or pg_column_size(invoice_config) <= 8192)
);

comment on table pinka_finance.organizer_payment_rails is
  'Stripe Connect stanje organizatora (U1). stripe_account_id je acct_… i NIKAD '
  'ne ide u javne odgovore — feed dobiva izvedeni boolean. Piše isključivo '
  'service_role (Worker nakon verifikacije Stripe webhook potpisa); '
  'invoice_config drži referencu na tajnu, nikad samu tajnu.';

drop trigger if exists trg_organizer_payment_rails_updated on pinka_finance.organizer_payment_rails;
create trigger trg_organizer_payment_rails_updated
  before update on pinka_finance.organizer_payment_rails
  for each row execute function public.touch_updated_at();

alter table pinka_finance.organizer_payment_rails enable row level security;

-- default privileges (20260530120200) daju select anon+authenticated → suzimo
-- (isti obrazac kao organizer_allowlist / organizer_records u 20260717130000)
revoke all on pinka_finance.organizer_payment_rails from public, anon;
revoke insert, update, delete on pinka_finance.organizer_payment_rails from authenticated;
grant select on pinka_finance.organizer_payment_rails to authenticated;
grant select, insert, update, delete on pinka_finance.organizer_payment_rails to service_role;

drop policy if exists organizer_payment_rails_select on pinka_finance.organizer_payment_rails;
create policy organizer_payment_rails_select on pinka_finance.organizer_payment_rails
  for select to authenticated
  using (public.has_role_on_account(account_id, 'admin'));

-- ----- 2. contributions: rail + vanjska referenca plaćanja --------------------
-- payment_rail s defaultom 'onchain' znači da postojeći redovi i cijeli
-- postojeći onchain tok ostaju bit-identični.
alter table pinka_finance.contributions
  add column if not exists payment_rail text not null default 'onchain',   -- onchain|stripe
  add column if not exists external_payment_ref text,                      -- pi_… za stripe
  add column if not exists buyer_email text;                               -- dostava ulaznica (web kupac nema wallet)

alter table pinka_finance.contributions
  drop constraint if exists contributions_payment_rail_chk,
  drop constraint if exists contributions_external_ref_format,
  drop constraint if exists contributions_buyer_email_len;
alter table pinka_finance.contributions
  add constraint contributions_payment_rail_chk
    check (payment_rail in ('onchain', 'stripe')) not valid,
  add constraint contributions_external_ref_format
    check (external_payment_ref is null or external_payment_ref ~ '^[A-Za-z0-9_-]{6,255}$') not valid,
  add constraint contributions_buyer_email_len
    check (buyer_email is null or char_length(buyer_email) <= 200) not valid;

-- IDEMPOTENCIJA PLAĆANJA: jedan Stripe PaymentIntent smije kreditirati točno
-- jednu narudžbu. Isti princip kao ux_contributions_onchain (tx_hash, log_index)
-- — u BAZI, ne u kodu. Ponovljena dostava webhooka vraća already_paid.
create unique index if not exists ux_contributions_external_payment
  on pinka_finance.contributions (payment_rail, external_payment_ref)
  where external_payment_ref is not null;

comment on column pinka_finance.contributions.payment_rail is
  'onchain (EURe na organizatorov Safe) | stripe (direct charge na acct organizatora).';
comment on column pinka_finance.contributions.external_payment_ref is
  'Vanjski identifikator uplate (Stripe payment_intent pi_…). Uz payment_rail '
  'čini unique ključ idempotencije — jedna uplata kreditira jednu narudžbu.';
comment on column pinka_finance.contributions.buyer_email is
  'E-mail kupca za dostavu ulaznica (web kupac nema wallet ni GoTrue račun). PII.';

-- ----- 3. confirm_ticket_order_offchain (service_role; events-stripe-confirm) --
-- Blizanac confirm_ticket_order (20260716120200:457). Razlike su SAMO u ključu
-- uplate — (p_rail, p_external_ref) umjesto (tx_hash, log_index) — i u tome što
-- se e-mail kupca snima za dostavu. Sve ostalo je namjerno identično:
--   1. select … for update na narudžbi
--   2. idempotencija: paid + isti (rail, ref) → already_paid + serials
--   3. konflikt: isti (rail, ref) na DRUGOJ narudžbi → audit + tx_already_credited
--   4. manjak iznosa → audit + amount_insufficient
--   5. istekla rezervacija → re-rezervacija; ne stane → audit + expired_sold_out
--   6. poslovni ne-uspjeh = status jsonb, NIKAD exception (audit mora preživjeti)
--
-- Odstupanje od onchain blizanca (svjesno, v. Zapisnik U1): druga uplata na već
-- plaćenu narudžbu NIJE exception nego status 'duplicate_payment' + audit. Kod
-- Stripea to znači da je kupac stvarno dvaput naplaćen (dvije checkout sesije
-- iste narudžbe) — Worker na taj status radi refund, a exception bi rollbackao
-- upravo taj trag. Onchain blizanac tu i dalje raisa order_already_paid.
--
-- Tokeni se NE vraćaju odavde — dostava ide isključivo kroz
-- deliver_ticket_orders (jednokratno), isti invariant kao onchain put.
create or replace function pinka_finance.confirm_ticket_order_offchain(
  p_order_id uuid,
  p_rail text,
  p_external_ref text,
  p_amount_cents bigint,
  p_payer_email text default null
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order pinka_finance.contributions;
  v_other uuid;
  v_token text;
  v_serial text;
  v_prefix text;
  v_base integer;
  v_slug text;
  v_holder jsonb;
  v_serials text[] := '{}';
  v_email text;
  i integer;
begin
  -- ── validacija ulaza (strojni kodovi; ovo su programske, ne poslovne greške) ─
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_rail is null or p_rail not in ('stripe') then raise exception 'invalid_rail'; end if;
  if p_external_ref is null or p_external_ref !~ '^[A-Za-z0-9_-]{6,255}$' then
    raise exception 'invalid_external_ref';
  end if;
  v_email := nullif(btrim(coalesce(p_payer_email, '')), '');
  if v_email is not null and char_length(v_email) > 200 then
    raise exception 'invalid_payer_email';
  end if;

  select * into v_order from pinka_finance.contributions
    where id = p_order_id
    for update;
  if not found then raise exception 'order_not_found'; end if;
  if v_order.tier_id is null or not v_order.reserved then
    raise exception 'not_a_ticket_order';
  end if;

  -- ── 2. idempotencija: ista uplata na istu narudžbu = no-op ─────────────────
  if v_order.state = 'paid' then
    if v_order.payment_rail = p_rail
       and v_order.external_payment_ref is not distinct from p_external_ref then
      select coalesce(array_agg(t.serial order by t.serial), '{}') into v_serials
        from pinka_finance.tickets t where t.contribution_id = p_order_id;
      return jsonb_build_object('status', 'already_paid', 'order_id', p_order_id, 'serials', v_serials);
    end if;
    -- DRUGA uplata na već plaćenu narudžbu: kupac je naplaćen dvaput →
    -- trag za refund (Worker), ne exception (rollbackao bi trag).
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.duplicate_payment',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'credited_rail', v_order.payment_rail,
                               'credited_ref', v_order.external_payment_ref,
                               'amount_cents', p_amount_cents));
    return jsonb_build_object('status', 'duplicate_payment', 'order_id', p_order_id,
                              'credited_ref', v_order.external_payment_ref);
  end if;
  if v_order.state not in ('pending', 'expired') then
    raise exception 'order_not_payable';
  end if;

  -- ── 3. (rail, ref) smije kreditirati SAMO jednu narudžbu ───────────────────
  select id into v_other from pinka_finance.contributions
    where payment_rail = p_rail and external_payment_ref = p_external_ref
      and id <> p_order_id;
  if found then
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.match_conflict',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'other_contribution_id', v_other));
    return jsonb_build_object('status', 'tx_already_credited', 'order_id', p_order_id);
  end if;

  -- ── 4. iznos mora pokriti narudžbu ─────────────────────────────────────────
  if p_amount_cents is null or p_amount_cents < v_order.amount_cents then
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.underpaid',
            jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref,
                               'expected_cents', v_order.amount_cents,
                               'received_cents', p_amount_cents));
    return jsonb_build_object('status', 'amount_insufficient', 'order_id', p_order_id,
                              'expected_cents', v_order.amount_cents, 'received_cents', p_amount_cents);
  end if;

  -- ── 5. istekla rezervacija, a uplata je stvarno naplaćena → re-rezerviraj ──
  -- (poznati prozor: Stripe checkout TTL min. 30 min > naša rezervacija 20 min)
  if v_order.state = 'expired' then
    update pinka_finance.campaign_tiers
       set inventory_claimed = inventory_claimed + v_order.quantity,
           updated_at = now()
     where id = v_order.tier_id
       and (inventory_total is null or inventory_claimed + v_order.quantity <= inventory_total);
    if not found then
      insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
      values (p_order_id, v_order.campaign_id, 'ticket_order.expired_sold_out',
              jsonb_build_object('rail', p_rail, 'external_ref', p_external_ref));
      return jsonb_build_object('status', 'expired_sold_out', 'order_id', p_order_id);
    end if;
  end if;

  update pinka_finance.contributions
     set state                 = 'paid',
         payment_rail          = p_rail,
         external_payment_ref  = p_external_ref,
         amount_received_cents = p_amount_cents,
         buyer_email           = coalesce(v_email, buyer_email),
         paid_at               = now(),
         updated_at            = now()
   where id = p_order_id;

  -- ── izdavanje ulaznica: identično confirm_ticket_order ────────────────────
  -- advisory lock po kampanji serijalizira brojač seriala (race dva confirma)
  perform pg_advisory_xact_lock(hashtext('pinka_tickets_' || v_order.campaign_id::text));

  select slug::text into v_slug from pinka_finance.campaigns where id = v_order.campaign_id;
  v_prefix := upper(left(regexp_replace(coalesce(v_slug, ''), '[^a-zA-Z]', '', 'g'), 3));
  if v_prefix = '' then v_prefix := 'EVT'; end if;
  select count(*)::integer into v_base from pinka_finance.tickets where campaign_id = v_order.campaign_id;

  for i in 1..v_order.quantity loop
    v_serial := v_prefix || '-' || lpad((v_base + i)::text, 6, '0');
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    v_holder := case
      when v_order.holders is not null and jsonb_typeof(v_order.holders) = 'array'
        then v_order.holders->(i - 1)
      else null
    end;
    insert into pinka_finance.tickets (
      contribution_id, campaign_id, tier_id, serial,
      holder_name, holder_email, qr_token_hash, qr_token_once, state
    ) values (
      p_order_id, v_order.campaign_id, v_order.tier_id, v_serial,
      -- holder_email ostaje holderov (kao onchain blizanac); e-mail kupca živi
      -- na contributions.buyer_email i ne upisuje se tuđoj ulaznici
      v_holder->>'full_name', v_holder->>'email',
      encode(extensions.digest(v_token, 'sha256'), 'hex'), v_token, 'issued'
    );
    v_serials := v_serials || v_serial;
  end loop;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_order_id, v_order.campaign_id, 'tickets.issued',
          jsonb_build_object('count', v_order.quantity, 'serials', to_jsonb(v_serials),
                             'rail', p_rail, 'external_ref', p_external_ref));

  return jsonb_build_object('status', 'paid', 'order_id', p_order_id, 'serials', v_serials);
end;
$$;

revoke execute on function pinka_finance.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  from public, anon, authenticated;
grant execute on function pinka_finance.confirm_ticket_order_offchain(uuid, text, text, bigint, text)
  to service_role;

select 'OK events_stripe_rail' as status;
