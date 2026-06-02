-- Fix record_onchain_contribution: contributions.destination_address is NOT NULL,
-- so the on-chain insert must snapshot the campaign's destination_address (the
-- Safe the donor sent EURe to). Caught by a rollback test before going live.

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
  v_dest    text;
begin
  select id into v_id
    from pinka_finance.contributions
   where forward_tx_hash = p_tx_hash and onchain_log_index = p_log_index;
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

  insert into pinka_finance.contributions (
    campaign_id, amount_cents, currency, state, anonymous,
    destination_address, forward_tx_hash, onchain_log_index, onchain_from
  ) values (
    p_campaign_id, p_amount_cents, 'eur', 'pending', false,
    v_dest, p_tx_hash, p_log_index, p_from
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
