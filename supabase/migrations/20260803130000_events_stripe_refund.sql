-- =============================================================================
-- Događaji (U1/U2) — povrat plaćene narudžbe ulaznica
-- Reference: domovina-ulaznice/docs/03-stripe-connect-0-posto.md §4/§5,
--            domovina-ulaznice/docs/handoffs/u2-javna-prodaja-web.md (webhooks)
--
-- Zašto novi RPC, a ne postojeći void_ticket: void_ticket je organizatorska
-- radnja i traži `auth.uid()` + `has_role_on_account(admin)`. Worker se
-- autentificira service ključem i NEMA `auth.uid()` — pozvao bi ga i dobio
-- `not_authenticated`. Povrat je uz to operacija nad CIJELOM narudžbom
-- (contribution + sve njezine ulaznice + inventory + audit), pa mora biti
-- jedna transakcija, a ne petlja po ulaznicama iz Workera.
--
-- Tko ga zove: isključivo domovina-ulaznice Worker (service_role) nakon što je
-- Stripe potvrdio povrat — bilo naš automatski refund (`expired_sold_out`,
-- `duplicate_payment`) bilo vanjski povrat kroz Stripe dashboard
-- (`charge.refunded` webhook). Novac vraća Stripe; ovdje se samo bilježi ishod.
--
-- Poslovni ishodi kao status jsonb, NIKAD exception (ista lekcija kao U1).
-- Idempotentno: drugi poziv na već vraćenu narudžbu = `already_refunded`.
-- =============================================================================

create or replace function pinka_finance.refund_ticket_order(
  p_order_id uuid,
  p_amount_cents bigint default null,     -- null = pun povrat
  p_reason text default null,             -- expired_sold_out | duplicate_payment | organizator | dispute
  p_external_ref text default null        -- pi_… povrata (trag prema Stripeu)
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order pinka_finance.contributions;
  v_voided integer := 0;
  v_kept integer := 0;
  v_total bigint;
  v_count integer;
  v_contributors integer;
begin
  if p_order_id is null then raise exception 'order_id_required'; end if;
  if p_reason is not null and char_length(p_reason) > 60 then raise exception 'invalid_reason'; end if;

  select * into v_order from pinka_finance.contributions
    where id = p_order_id
    for update;
  if not found then
    return jsonb_build_object('status', 'not_found', 'order_id', p_order_id);
  end if;
  if v_order.tier_id is null or not v_order.reserved then
    return jsonb_build_object('status', 'not_a_ticket_order', 'order_id', p_order_id);
  end if;

  if v_order.state = 'refunded' then
    select count(*) filter (where t.state = 'void'),
           count(*) filter (where t.state = 'checked_in')
      into v_voided, v_kept
      from pinka_finance.tickets t where t.contribution_id = p_order_id;
    return jsonb_build_object('status', 'already_refunded', 'order_id', p_order_id,
                              'voided', v_voided, 'kept_checked_in', v_kept);
  end if;
  if v_order.state <> 'paid' then
    -- npr. pending narudžba na koju je stigao refund → nema što vratiti u bazi
    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (p_order_id, v_order.campaign_id, 'ticket_order.refund_unexpected',
            jsonb_build_object('state', v_order.state::text, 'reason', p_reason,
                               'external_ref', p_external_ref));
    return jsonb_build_object('status', 'not_paid', 'order_id', p_order_id,
                              'state', v_order.state::text);
  end if;

  -- ── poništi izdane ulaznice; iskorištene ostaju (ulaz se već dogodio) ──────
  update pinka_finance.tickets
     set state = 'void', updated_at = now()
   where contribution_id = p_order_id and state = 'issued';
  get diagnostics v_voided = row_count;

  select count(*)::integer into v_kept
    from pinka_finance.tickets
   where contribution_id = p_order_id and state = 'checked_in';

  -- ── oslobodi inventory za poništene komade (mjesto se vraća u prodaju) ─────
  -- Samo za poništene: ulaznica na kojoj je netko već ušao nije slobodno mjesto.
  if v_voided > 0 then
    update pinka_finance.campaign_tiers
       set inventory_claimed = greatest(inventory_claimed - v_voided, 0),
           updated_at = now()
     where id = v_order.tier_id;
  end if;

  -- ── stanje narudžbe ───────────────────────────────────────────────────────
  -- tg_contribution_state loguje tranziciju; agregat re-sumira samo na 'paid',
  -- pa ga ovdje osvježavamo sami da campaign_stats ne ostane napuhan.
  update pinka_finance.contributions
     set state = 'refunded', updated_at = now()
   where id = p_order_id;

  select coalesce(sum(amount_cents), 0), count(*)
    into v_total, v_count
    from pinka_finance.contributions
   where campaign_id = v_order.campaign_id and state = 'paid';
  select count(distinct contributor_account_id)
    into v_contributors
    from pinka_finance.contributions
   where campaign_id = v_order.campaign_id and state = 'paid'
     and contributor_account_id is not null;

  insert into pinka_finance.campaign_stats (
    campaign_id, total_raised_cents, contribution_count, contributor_count, updated_at
  ) values (v_order.campaign_id, v_total, v_count, v_contributors, now())
  on conflict (campaign_id) do update set
    total_raised_cents = excluded.total_raised_cents,
    contribution_count = excluded.contribution_count,
    contributor_count  = excluded.contributor_count,
    updated_at         = now();

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_order_id, v_order.campaign_id, 'ticket_order.refunded',
          jsonb_build_object('reason', p_reason, 'external_ref', p_external_ref,
                             'amount_cents', coalesce(p_amount_cents, v_order.amount_cents),
                             'voided', v_voided, 'kept_checked_in', v_kept,
                             'rail', v_order.payment_rail));

  return jsonb_build_object('status', 'refunded', 'order_id', p_order_id,
                            'voided', v_voided, 'kept_checked_in', v_kept);
end;
$$;

revoke execute on function pinka_finance.refund_ticket_order(uuid, bigint, text, text)
  from public, anon, authenticated;
grant execute on function pinka_finance.refund_ticket_order(uuid, bigint, text, text)
  to service_role;

select 'OK events_stripe_refund' as status;
