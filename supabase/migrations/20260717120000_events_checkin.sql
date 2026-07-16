-- =============================================================================
-- Događaji (E3) — check-in: redeem_ticket + void_ticket
-- Reference: safe-wallet-monorepo/docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md
--            (§3.4 check-in), handoffs/dogadjaji-3-qr-checkin.md
--
-- Model (nadovezuje se na E2 20260716120000..120200):
--   * QR ulaznice nosi opaque 32-bajtni token (payload `dgdj1:<token>` u appu);
--     u bazi je trajno SAMO sha256 hash (qr_token_hash unique).
--   * redeem_ticket(qr_token): hash lookup → org-admin autorizacija →
--     issued→checked_in ATOMARNO u jednoj UPDATE naredbi (uz row lock);
--     idempotentno — drugi sken vraća podatke PRVOG ulaska sa statusom
--     'already_checked_in' (anti-double-entry: vrijeme + tko je skenirao).
--   * void_ticket(ticket_id): organizatorsko poništenje (refund evidencija);
--     samo issued → void; iskorištena ulaznica se ne može poništiti.
--
-- Autorizacija ISKLJUČIVO server-side: pozivatelj mora biti GoTrue korisnik s
-- has_role_on_account(campaign.account_id, 'admin') — klijentski flag nikad
-- nije dovoljan (skener u walletu je samo UI). Edge funkcija events-checkin
-- zove RPC user klijentom (anon key + Authorization header), pa auth.uid()
-- vrijedi i u security definer tijelu.
--
-- Poslovni ishodi skena (not_found / void / already_checked_in) se vraćaju kao
-- status jsonb, NE kao exception — exception bi rollbackao audit event
-- (contribution_events) o pokušaju dvostrukog ulaska. Exceptioni su rezervirani
-- za neispravan poziv (invalid_token, not_authenticated, not_authorized).
-- =============================================================================

-- ----- redeem_ticket (org admin; poziva events-checkin user klijentom) --------
create or replace function pinka_finance.redeem_ticket(p_qr_token text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_hash text;
  v_ticket pinka_finance.tickets;
  v_campaign pinka_finance.campaigns;
  v_tier_title text;
  v_by_email text;
  v_count integer;
  v_now timestamptz;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated';
  end if;
  if p_qr_token is null or p_qr_token !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_token';
  end if;

  v_hash := encode(extensions.digest(p_qr_token, 'sha256'), 'hex');

  -- row lock serijalizira dva istovremena skena iste ulaznice
  select * into v_ticket
    from pinka_finance.tickets
   where qr_token_hash = v_hash
     for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into v_campaign
    from pinka_finance.campaigns
   where id = v_ticket.campaign_id and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  -- autorizacija: SAMO admin organizatorovog org accounta smije redeem
  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  select title into v_tier_title
    from pinka_finance.campaign_tiers
   where id = v_ticket.tier_id;

  if v_ticket.state = 'void' then
    return jsonb_build_object(
      'status', 'void',
      'serial', v_ticket.serial,
      'event_title', v_campaign.title
    );
  end if;

  if v_ticket.state = 'checked_in' then
    -- anti-double-entry: vrati PRVI ulazak (vrijeme + tko je skenirao) + audit
    select u.email into v_by_email from auth.users u where u.id = v_ticket.checked_in_by;

    insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
    values (v_ticket.contribution_id, v_ticket.campaign_id, 'ticket.checkin_duplicate',
            jsonb_build_object('serial', v_ticket.serial,
                               'first_checked_in_at', v_ticket.checked_in_at,
                               'attempted_by', (select auth.uid())));

    select count(*)::integer into v_count
      from pinka_finance.tickets
     where campaign_id = v_ticket.campaign_id and state = 'checked_in';

    return jsonb_build_object(
      'status', 'already_checked_in',
      'serial', v_ticket.serial,
      'holder_name', v_ticket.holder_name,
      'tier_title', v_tier_title,
      'event_title', v_campaign.title,
      'checked_in_at', v_ticket.checked_in_at,
      'checked_in_by_email', v_by_email,
      'checked_in_count', v_count
    );
  end if;

  -- issued → checked_in: state tranzicija u JEDNOJ naredbi (idempotencija na
  -- razini SQL-a; uz gornji for update lock race dva skenera je nemoguć)
  v_now := now();
  update pinka_finance.tickets
     set state = 'checked_in',
         checked_in_at = v_now,
         checked_in_by = (select auth.uid()),
         updated_at = v_now
   where id = v_ticket.id and state = 'issued';

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (v_ticket.contribution_id, v_ticket.campaign_id, 'ticket.checked_in',
          jsonb_build_object('serial', v_ticket.serial, 'by', (select auth.uid())));

  select count(*)::integer into v_count
    from pinka_finance.tickets
   where campaign_id = v_ticket.campaign_id and state = 'checked_in';

  return jsonb_build_object(
    'status', 'checked_in',
    'serial', v_ticket.serial,
    'holder_name', v_ticket.holder_name,
    'tier_title', v_tier_title,
    'event_title', v_campaign.title,
    'checked_in_at', v_now,
    'checked_in_count', v_count
  );
end;
$$;

revoke execute on function pinka_finance.redeem_ticket(text) from public, anon;
grant execute on function pinka_finance.redeem_ticket(text) to authenticated, service_role;

-- ----- void_ticket (org admin; refund/poništenje evidencija) -------------------
create or replace function pinka_finance.void_ticket(p_ticket_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_ticket pinka_finance.tickets;
  v_campaign pinka_finance.campaigns;
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated';
  end if;
  if p_ticket_id is null then
    raise exception 'ticket_id_required';
  end if;

  select * into v_ticket
    from pinka_finance.tickets
   where id = p_ticket_id
     for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  select * into v_campaign
    from pinka_finance.campaigns
   where id = v_ticket.campaign_id and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  if v_ticket.state = 'void' then
    return jsonb_build_object('status', 'already_void', 'serial', v_ticket.serial);
  end if;
  if v_ticket.state = 'checked_in' then
    -- iskorištena ulaznica se ne poništava (ulaz se već dogodio)
    return jsonb_build_object(
      'status', 'already_checked_in',
      'serial', v_ticket.serial,
      'checked_in_at', v_ticket.checked_in_at
    );
  end if;

  update pinka_finance.tickets
     set state = 'void', updated_at = now()
   where id = v_ticket.id and state = 'issued';

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (v_ticket.contribution_id, v_ticket.campaign_id, 'ticket.voided',
          jsonb_build_object('serial', v_ticket.serial, 'by', (select auth.uid())));

  return jsonb_build_object('status', 'voided', 'serial', v_ticket.serial);
end;
$$;

revoke execute on function pinka_finance.void_ticket(uuid) from public, anon;
grant execute on function pinka_finance.void_ticket(uuid) to authenticated, service_role;

select 'OK events_checkin' as status;
