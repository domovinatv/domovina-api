-- =============================================================================
-- pinka_finance — contributor_count broji IDENTITETE donatora, ne samo račune
--
-- Problem: contributor_count = count(distinct contributor_account_id) računa
-- samo prijavljene korisnike s platform accountom. SVE on-chain donacije
-- (EIP-681 QR, in-app wallet, Monerium mint) i guest SEPA uplate imaju
-- contributor_account_id NULL → kampanja s 30 stvarnih donacija pokazuje
-- "0 podupiratelja".
--
-- Fix: identitet donatora = najjači dostupni ključ, po prioritetu:
--   1. contributor_account_id  (prijavljeni korisnik — spaja sve njegove uplate)
--   2. lower(onchain_from)     (wallet adresa — spaja uplate istog novčanika)
--   3. payer_iban_hash         (bank-verified SEPA — spaja uplate istog računa)
--   4. id                      (fallback: svaka donacija = jedan podupiratelj)
--
-- Poznata nesavršenost: povijesni rail-forwardi dijele onchain_from (MPT rail
-- Safe) pa se kolabiraju u jednog podupiratelja — prihvatljivo (rijedak,
-- povijesni slučaj; budući rail forwardi nose sid → account ili iban hash).
--
-- Funkcija je zadnje redefinirana u 20260716120200 (events rezervacije);
-- ovo je ISTA verzija s izmijenjenim v_contributors izračunom + jednokratni
-- re-sum postojećih campaign_stats.
-- =============================================================================

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

  -- log svaku tranziciju stanja
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

    -- autoritativni agregat (re-sum, ne inkrement — robusno na refundove kasnije)
    select coalesce(sum(amount_cents), 0), count(*)
      into v_total, v_count
      from pinka_finance.contributions
     where campaign_id = new.campaign_id and state = 'paid';

    -- podupiratelji = distinct identiteti (account ∪ wallet ∪ iban ∪ fallback)
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

    -- flip na funded kad je cilj dosegnut
    update pinka_finance.campaigns
       set state = 'funded'
     where id = new.campaign_id
       and goal_cents is not null
       and state = 'active'
       and v_total >= goal_cents;

    -- soft tokenizacija: jedna pozicija po doprinosu
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
  end if;

  return new;
end;
$$;

-- ----- jednokratni re-sum postojećih statistika ------------------------------
with agg as (
  select campaign_id,
         coalesce(sum(amount_cents), 0)          as total,
         count(*)                                 as cnt,
         count(distinct coalesce(
           contributor_account_id::text,
           nullif(lower(onchain_from), ''),
           payer_iban_hash,
           id::text
         ))                                       as contribs,
         max(paid_at)                             as last_paid
    from pinka_finance.contributions
   where state = 'paid'
   group by campaign_id
)
insert into pinka_finance.campaign_stats (
  campaign_id, total_raised_cents, contribution_count,
  contributor_count, last_contribution_at, updated_at
)
select campaign_id, total, cnt, contribs, last_paid, now() from agg
on conflict (campaign_id) do update set
  total_raised_cents   = excluded.total_raised_cents,
  contribution_count   = excluded.contribution_count,
  contributor_count    = excluded.contributor_count,
  last_contribution_at = excluded.last_contribution_at,
  updated_at           = now();

select 'OK pinka_contributor_identity' as status;
