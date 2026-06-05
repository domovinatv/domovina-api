-- =============================================================================
-- pinka.finance — bank-verified + Certilia↔SEPA double verification
-- Reference: pinka-onchain-receipts-tokenization-plan.md
--
-- Monerium exposes the SEPA SENDER on inbound ("issue") orders
-- (counterpart.identifier.iban + counterpart.details.name). The rail already
-- stores it (monerium_orders.counterpart_iban/name) and now forwards it on the
-- intent.paid / contribution.sepa webhooks. Here we derive, per contribution:
--   • bank_verified           — paid via SEPA by a NAMED bank sender
--   • identity_double_verified — the SEPA sender name matches the contributor's
--                                Certilia/eID KYC name (independent 2nd factor)
--   • payer_iban_hash         — salted HMAC of the sender IBAN (repeat-payer /
--                                membership matching WITHOUT storing the raw IBAN)
--
-- Privacy (čl. 5(1)(c)): pinka stores only the BOOLEAN results + an IBAN HASH.
-- Raw sender name/IBAN live solely in the rail's D1 (system of record). The
-- public wall exposes booleans only — never a name or IBAN.
-- =============================================================================

alter table pinka_finance.contributions
  add column if not exists bank_verified            boolean not null default false,
  add column if not exists identity_double_verified boolean not null default false,
  add column if not exists payer_iban_hash          text;

comment on column pinka_finance.contributions.bank_verified is
  'Paid via SEPA by a named bank sender (Monerium counterpart present).';
comment on column pinka_finance.contributions.identity_double_verified is
  'SEPA sender name matches the contributor''s Certilia/eID KYC name (2nd factor).';
comment on column pinka_finance.contributions.payer_iban_hash is
  'HMAC-SHA256(sender IBAN, key) — repeat-payer/membership matching; no raw IBAN.';

create index if not exists ix_contributions_payer_iban_hash
  on pinka_finance.contributions(payer_iban_hash) where payer_iban_hash is not null;

-- ----- name normalisation (diacritic-fold + token-sort) ----------------------
-- "Marko Horvat" / "MARKO  HORVÁT" / "Horvat Marko" all normalise to "horvat marko".
create or replace function pinka_finance.norm_name(p text) returns text
language sql immutable
as $$
  select case when p is null then null else (
    select string_agg(tok, ' ' order by tok)
    from regexp_split_to_table(
      btrim(regexp_replace(
        lower(translate(
          p,
          'čćžšđ' || 'ČĆŽŠĐ' || 'áàâäãéèêëíìîïóòôöõúùûüñç',
          'cczsd' || 'cczsd' || 'aaaaaeeeeiiiiooooouuuunc'
        )),
        '[^a-z0-9]+', ' ', 'g'
      )),
      '\s+'
    ) as tok
    where tok <> ''
  ) end
$$;

-- True iff every token of the contributor's Certilia name appears in the SEPA
-- sender name (order-independent; tolerates extra/middle names on either side).
create or replace function pinka_finance.sepa_name_matches_identity(
  p_account uuid,
  p_sender  text
) returns boolean
language sql stable security definer set search_path = ''
as $$
  with cert as (
    select pinka_finance.norm_name(coalesce(iv.first_name,'') || ' ' || coalesce(iv.last_name,'')) as n
    from public.identity_verifications iv
    join public.accounts a on a.primary_owner_user_id = iv.user_id
    where a.id = p_account
    limit 1
  ), snd as (
    select pinka_finance.norm_name(p_sender) as n
  )
  select case
    when p_account is null
      or (select n from cert) is null or (select n from cert) = ''
      or (select n from snd)  is null or (select n from snd)  = ''
      then false
    else (
      select bool_and(tok = any(string_to_array((select n from snd), ' ')))
      from regexp_split_to_table((select n from cert), '\s+') as tok
      where tok <> ''
    )
  end
$$;
revoke execute on function pinka_finance.sepa_name_matches_identity(uuid,text) from public, anon, authenticated;
grant  execute on function pinka_finance.sepa_name_matches_identity(uuid,text) to service_role;

-- ----- mark_contribution_paid (intent path) — + sender verification ----------
drop function if exists pinka_finance.mark_contribution_paid(text,text,bigint);
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
   where payment_intent_sid = p_sid and state = 'pending';
  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;
revoke execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.mark_contribution_paid(text,text,bigint,text,text,text) to service_role;

-- ----- record_sepa_contribution (cmp: permanent QR) — + sender verification --
drop function if exists pinka_finance.record_sepa_contribution(uuid,text,bigint,text);
create or replace function pinka_finance.record_sepa_contribution(
  p_campaign_id       uuid,
  p_monerium_order_id text,
  p_amount_cents      bigint,
  p_tx_hash           text default null,
  p_sender_iban       text default null,
  p_sender_name       text default null,
  p_key               text default null
) returns table (contribution_id uuid, created boolean)
language plpgsql security definer set search_path = ''
as $$
declare
  v_id      uuid;
  v_deleted timestamptz;
  v_dest    text;
  v_named   boolean := p_sender_name is not null and btrim(p_sender_name) <> '';
  v_hash    text := case
    when p_sender_iban is not null and p_key is not null
    then encode(extensions.hmac(upper(regexp_replace(p_sender_iban, '\s', '', 'g')), p_key, 'sha256'), 'hex')
    else null end;
begin
  if p_monerium_order_id is null or length(p_monerium_order_id) = 0 then
    raise exception 'monerium_order_id_required';
  end if;

  select id into v_id from pinka_finance.contributions
   where monerium_order_id = p_monerium_order_id;
  if found then
    return query select v_id, false;
    return;
  end if;

  select deleted_at, destination_address into v_deleted, v_dest
    from pinka_finance.campaigns where id = p_campaign_id;
  if not found or v_deleted is not null then
    raise exception 'unknown_or_deleted_campaign %', p_campaign_id;
  end if;
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'invalid_amount_cents %', p_amount_cents;
  end if;

  -- cmp: QR has no logged-in contributor → no Certilia identity to match, so
  -- identity_double_verified stays false; bank_verified reflects a named sender.
  insert into pinka_finance.contributions (
    campaign_id, amount_cents, currency, state, anonymous,
    destination_address, monerium_order_id, forward_tx_hash,
    bank_verified, identity_double_verified, payer_iban_hash
  ) values (
    p_campaign_id, p_amount_cents, 'eur', 'pending', false,
    v_dest, p_monerium_order_id, p_tx_hash,
    v_named, false, v_hash
  ) returning id into v_id;

  update pinka_finance.contributions
     set state = 'paid', amount_received_cents = p_amount_cents,
         paid_at = now(), updated_at = now()
   where id = v_id;

  return query select v_id, true;
end;
$$;
revoke execute on function pinka_finance.record_sepa_contribution(uuid,text,bigint,text,text,text,text) from public, anon, authenticated;
grant  execute on function pinka_finance.record_sepa_contribution(uuid,text,bigint,text,text,text,text) to service_role;

-- ----- public wall: expose the boolean verification flags --------------------
create or replace view pinka_finance.public_contributions as
  select
    ct.id,
    ct.campaign_id,
    ct.display_name,
    case when ct.message_hidden then null else ct.message end       as message,
    ct.amount_cents,
    ct.currency,
    ct.created_at,
    ct.paid_at,
    case when ct.message_hidden then null else ct.link_preview end   as link_preview,
    ct.contributor_verified                                          as verified,
    ct.bank_verified                                                 as bank_verified,
    ct.identity_double_verified                                      as identity_double_verified
  from pinka_finance.contributions ct
  join pinka_finance.campaigns c on c.id = ct.campaign_id
  where ct.state = 'paid'
    and ct.anonymous = false
    and c.deleted_at is null
    and c.visibility = 'public'
    and c.state in ('active','funded','closed');

grant select on pinka_finance.public_contributions to anon, authenticated, service_role;

select 'OK pinka_finance bank-verified + double verification' as status;
