-- =============================================================================
-- On-chain donations — record EURe transfers sent directly to a campaign Safe
-- =============================================================================
-- Donors can scan an EIP-681 QR with the DOMOVINA wallet (or any wallet) and
-- send EURe straight to campaigns.destination_address — no SEPA, no rail sid.
-- An indexer (pay.domovina.ai worker cron) scans EURe Transfer logs to campaign
-- Safes and calls record_onchain_contribution(...) per transfer. Idempotent on
-- (forward_tx_hash, onchain_log_index) so re-scans never double-credit.
--
-- Reuses the existing trigger machinery: insert pending (fires created event)
-- then flip to paid (fires tg_contribution_state → stats re-sum + funded flip).

alter table pinka_finance.contributions
  add column if not exists onchain_from      text,   -- donor address (provenance / wall)
  add column if not exists onchain_log_index integer; -- EURe Transfer log index within the tx

-- Idempotency key for on-chain credits (one EURe Transfer = one contribution).
create unique index if not exists ux_contributions_onchain
  on pinka_finance.contributions (forward_tx_hash, onchain_log_index)
  where onchain_log_index is not null;

-- service_role-only: called by the pinka-onchain-ingest edge fn after it verifies
-- the HMAC from the indexer. Resolves nothing itself (caller passes campaign_id).
create or replace function pinka_finance.record_onchain_contribution(
  p_campaign_id uuid,
  p_tx_hash     text,
  p_log_index   integer,
  p_from        text,
  p_amount_cents bigint
) returns table (contribution_id uuid, created boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_deleted timestamptz;
begin
  -- idempotent: this exact transfer already credited?
  select id into v_id
    from pinka_finance.contributions
   where forward_tx_hash = p_tx_hash and onchain_log_index = p_log_index;
  if found then
    return query select v_id, false;
    return;
  end if;

  -- campaign must exist and not be soft-deleted
  select deleted_at into v_deleted from pinka_finance.campaigns where id = p_campaign_id;
  if not found or v_deleted is not null then
    raise exception 'unknown_or_deleted_campaign %', p_campaign_id;
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'invalid_amount_cents %', p_amount_cents;
  end if;

  -- insert pending (fires tg_contribution_created), then flip to paid (fires
  -- tg_contribution_state → tier/stats/funded). Mirrors the fiat create→mark path.
  insert into pinka_finance.contributions (
    campaign_id, amount_cents, currency, state, anonymous,
    forward_tx_hash, onchain_log_index, onchain_from
  ) values (
    p_campaign_id, p_amount_cents, 'eur', 'pending', false,
    p_tx_hash, p_log_index, p_from
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

revoke execute on function pinka_finance.record_onchain_contribution(uuid,text,integer,text,bigint)
  from public, anon, authenticated;
grant execute on function pinka_finance.record_onchain_contribution(uuid,text,integer,text,bigint)
  to service_role;
