-- =============================================================================
-- pinka_finance — payout request flow (vlasnik kanala traži isplatu kampanje)
-- Reference: domovina-api/docs/pinka-payout-execution.md
--
-- Model: platform-custody + payout-request (BEZ multisiga). Owner wallet je
-- ODREDIŠTE isplate, ne Safe co-signer. Donacije sjede na campaign Safe
-- (destination_address, 1-of-1 ekosustavni signer). Vlasnik verificiranog kanala
-- (∧ KYC) zatraži isplatu → upiše payouts red (state='requested'). Off-chain
-- izvršitelj (pay.domovina.ai / ops, vidi docs) izvrši Monerium redeem (IBAN) ili
-- Safe transfer (0x) i pomakne state + tx_hash/monerium_redeem_order_id.
--
-- `payouts` tablica + `payout_state` enum već postoje (schema migracija 11).
-- Ovdje: SELECT RLS za vlasnika kanala + SECURITY DEFINER request RPC. INSERT
-- ide isključivo kroz RPC (klijent nema insert policy).
-- =============================================================================

-- ===== RLS: vlasnik kampanje ILI verificirani vlasnik kanala čita isplate =====
drop policy if exists payouts_select on pinka_finance.payouts;
create policy payouts_select on pinka_finance.payouts
  for select to authenticated
  using (
    exists (
      select 1 from pinka_finance.campaigns c
      where c.id = campaign_id and (
        public.has_role_on_account(c.account_id, 'admin')
        or pinka_finance.is_verified_channel_owner(c.youtube_channel_id)
      )
    )
  );

-- ===== request_payout (authenticated; vlasnik ∧ KYC) =========================
-- Autorizacija JE na request strani (ownership + KYC); izvršenje je off-chain
-- ekosustavnim signerom — zato je 1-of-1 Safe dovoljan.
create or replace function pinka_finance.request_payout(
  p_campaign_id  uuid,
  p_destination  text,
  p_amount_cents bigint
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dest      text := btrim(coalesce(p_destination, ''));
  v_kyc       boolean;
  v_available bigint;
  v_id        uuid;
begin
  -- 1. vlasništvo (account admin ILI verificirani vlasnik kanala kampanje)
  perform pinka_finance._assert_can_admin_campaign(p_campaign_id);

  -- 2. KYC — autoritativno iz baze (NE iz JWT-a; Certilia upiše naknadno)
  select coalesce((u.raw_app_meta_data->>'kyc_verified')::boolean, false)
    into v_kyc
    from auth.users u
   where u.id = (select auth.uid());
  if not coalesce(v_kyc, false) then
    raise exception 'kyc_required';
  end if;

  -- 3. odredište: 0x EVM adresa ILI IBAN
  if not (
    v_dest ~ '^0x[0-9a-fA-F]{40}$'
    or upper(replace(v_dest, ' ', '')) ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'
  ) then
    raise exception 'invalid_destination';
  end if;

  -- 4. iznos > 0 i ≤ raspoloživo (prikupljeno − već zatraženo/u obradi/isplaćeno)
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'invalid_amount';
  end if;

  select coalesce(s.total_raised_cents, 0)
       - coalesce((
           select sum(p.amount_cents) from pinka_finance.payouts p
           where p.campaign_id = p_campaign_id
             and p.state in ('requested','approved','submitted','confirmed')
         ), 0)
    into v_available
    from pinka_finance.campaign_stats s
   where s.campaign_id = p_campaign_id;
  v_available := coalesce(v_available, 0);

  if p_amount_cents > v_available then
    raise exception 'amount_exceeds_available';
  end if;

  -- 5. upiši zahtjev
  insert into pinka_finance.payouts (
    campaign_id, amount_cents, destination, state, requested_by
  ) values (
    p_campaign_id, p_amount_cents, v_dest, 'requested', (select auth.uid())
  ) returning id into v_id;

  return v_id;
end;
$$;

revoke all on function pinka_finance.request_payout(uuid, text, bigint) from public, anon;
grant execute on function pinka_finance.request_payout(uuid, text, bigint) to authenticated, service_role;

select 'OK pinka_payouts' as status;
