-- =============================================================================
-- pinka.finance — permanent campaign SEPA QR (`cmp:` rail protocol)
-- Reference: pinka-onchain-receipts-tokenization-plan.md (Permanent campaign QR)
--
-- One reusable SEPA QR per campaign (blank amount). Every inbound Monerium order
-- to the campaign's permanent QR is forwarded to the campaign Safe by the rail
-- and reported to pinka-webhook as `type=contribution.sepa` — each becomes a
-- DISTINCT paid contribution. Mirrors record_onchain_contribution, but keyed by
-- monerium_order_id (one Monerium order = one settlement = one contribution).
--
-- Idempotency: unique index on monerium_order_id (the per-intent `mpt:` flow
-- leaves it NULL, so no collision with intent.paid contributions).
-- =============================================================================

create unique index if not exists ux_contributions_morder
  on pinka_finance.contributions(monerium_order_id)
  where monerium_order_id is not null;

create or replace function pinka_finance.record_sepa_contribution(
  p_campaign_id        uuid,
  p_monerium_order_id  text,
  p_amount_cents       bigint,
  p_tx_hash            text default null
) returns table (contribution_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_deleted timestamptz;
  v_dest    text;
begin
  if p_monerium_order_id is null or length(p_monerium_order_id) = 0 then
    raise exception 'monerium_order_id_required';
  end if;

  -- idempotent: same Monerium order already recorded → return existing
  select id into v_id
    from pinka_finance.contributions
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

  -- pending → paid (fires tg_contribution_created + tg_contribution_state:
  -- stats, funded-flip, token_position for tokenization campaigns).
  insert into pinka_finance.contributions (
    campaign_id, amount_cents, currency, state, anonymous,
    destination_address, monerium_order_id, forward_tx_hash
  ) values (
    p_campaign_id, p_amount_cents, 'eur', 'pending', false,
    v_dest, p_monerium_order_id, p_tx_hash
  ) returning id into v_id;

  update pinka_finance.contributions
     set state                 = 'paid',
         amount_received_cents = p_amount_cents,
         paid_at               = now(),
         updated_at            = now()
   where id = v_id;

  return query select v_id, true;
end;
$$;

revoke execute on function pinka_finance.record_sepa_contribution(uuid,text,bigint,text)
  from public, anon, authenticated;
grant execute on function pinka_finance.record_sepa_contribution(uuid,text,bigint,text)
  to service_role;

select 'OK pinka_finance sepa campaign qr' as status;
