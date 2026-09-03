-- =============================================================================
-- Objava događaja uz BAREM JEDAN RADNI RAIL (Safe ILI Stripe)
--
-- Problem koji rješava: `publish_event` i trigger `campaigns_write_guard` traže
-- pravi Safe (`destination_address` ≠ null i ≠ 0x0…0) da bi kampanja postala
-- `active`. To je nasljeđe onchain raila i ispravno je za donacijske kampanje —
-- aktivacija bez Safe-a tamo znači donacije spaljene na nultu adresu.
--
-- Ali od U1 postoji drugi rail: organizator koji prodaje ulaznice karticom kroz
-- Stripe Connect (`organizer_payment_rails.stripe_charges_enabled`). Takav
-- organizator NEMA Safe i nikad ga neće imati — udruga s OIB-om i IBAN-om nema
-- razloga otvarati novčanik. Danas takav događaj ne može biti objavljen, pa ga
-- javni feed ne vidi: `events-feed` vraća `{"events":[]}` iako događaj postoji.
--
-- Odluka (docs/handoffs/u1 §Gotcha 7, u2 §Gotcha 5, plan 2026-09-03 §3.6):
-- gate se otpušta na **barem jedan radni rail**, ne ukida. Događaj tipa
-- `tickets` smije biti aktivan ako organizator ima `stripe_charges_enabled`;
-- sve ostalo (donacijske kampanje) ostaje netaknuto i dalje traži Safe.
--
-- Što se NE mijenja:
--   * donacijske kampanje (`type <> 'tickets'`) — i dalje strogi Safe gate,
--   * destination lock nakon prve plaćene uplate,
--   * allowlist moderacija objave,
--   * `has_role_on_account(..., 'admin')` autorizacija.
--
-- ⚠️ REVIEW(fable): razmotri je li „radni rail" trebao biti izveden stupac na
-- kampanji (npr. `campaigns.rail`) umjesto izvedene provjere pri svakoj
-- aktivaciji. Ovdje je namjerno izvedeno iz `organizer_payment_rails` jer je to
-- jedini izvor istine o tome prima li organizator uplate DANAS — denormalizirani
-- stupac bi se razišao čim Stripe pošalje `account.updated` s
-- `charges_enabled=false` (npr. istekla dokumentacija). Cijena je jedan
-- dodatan indeksirani lookup po aktivaciji, što je zanemarivo.
--
-- Idempotentno: drugi run je no-op (create or replace).
-- =============================================================================

-- ----- 1. event_rail_ready — jedan izvor istine o „ima li čime naplatiti" -----
--
-- security definer: trigger se izvršava u kontekstu pozivatelja (organizatora),
-- a `organizer_payment_rails` je RLS-zaključan na service_role za pisanje i
-- članstvo za čitanje. Bez definera bi organizator koji JEST admin, ali čita
-- kroz trigger, ovisio o tome je li policy baš tako posložena. Funkcija ne
-- otkriva ništa novo — vraća boolean, nikad `acct_…`.
create or replace function pinka_finance.event_rail_ready(
  p_account_id uuid,
  p_campaign_type text,
  p_destination_address text
) returns boolean
language sql stable security definer set search_path = ''
as $$
  select
    -- rail 1: pravi Safe (onchain) — vrijedi za svaki tip kampanje
    (p_destination_address is not null
     and p_destination_address ~ '^0x[0-9a-fA-F]{40}$'
     and p_destination_address !~* '^0x0{40}$')
    or
    -- rail 2: Stripe Connect, ISKLJUČIVO za ticketing kampanje
    (p_campaign_type = 'tickets' and exists (
      select 1 from pinka_finance.organizer_payment_rails r
       where r.account_id = p_account_id
         and r.stripe_account_id is not null
         and r.stripe_charges_enabled
    ));
$$;

comment on function pinka_finance.event_rail_ready(uuid, text, text) is
  'Ima li kampanja barem jedan radni rail za naplatu: pravi Safe (svi tipovi) '
  'ili Stripe Connect s charges_enabled (samo tickets). Koriste ga '
  'campaigns_write_guard i publish_event — jedan izvor istine, dva pozivatelja. '
  'Vraća boolean; acct_… nikad ne izlazi iz funkcije.';

revoke execute on function pinka_finance.event_rail_ready(uuid, text, text) from public, anon;
grant execute on function pinka_finance.event_rail_ready(uuid, text, text) to authenticated, service_role;

-- ----- 2. campaigns_write_guard — serverski mirror ---------------------------
-- Puno tijelo je prepisano jer `create or replace` ne zna za djelomičnu izmjenu.
-- Jedina promjena u odnosu na 20260611120000 je posljednji blok (aktivacija).
create or replace function pinka_finance.campaigns_write_guard()
returns trigger
language plpgsql
as $$
declare
  v_recent integer;
begin
  -- samo PostgREST 'authenticated' klijenti; service_role/psql netaknuti
  if coalesce(auth.role(), '') <> 'authenticated' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- kampanja se UVIJEK rađa kao nacrt — aktivaciju radi eksplicitni update
    new.state := 'draft';
    new.safe_deployed_at := null;

    -- anti-spam: max 20 kampanja po accountu u 24 h (KYC korisnik je poznat,
    -- ali i poznat korisnik može naštancati smeće)
    select count(*) into v_recent
    from pinka_finance.campaigns
    where account_id = new.account_id
      and created_at > now() - interval '24 hours';
    if v_recent >= 20 then
      raise exception 'campaign_rate_limited'
        using hint = 'Dosegnut dnevni limit kreiranja kampanja.';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    -- vlasništvo se ne prenosi update-om
    new.account_id := old.account_id;

    -- destination lock: nakon prve PLAĆENE uplate adresa je nepromjenjiva
    -- (tiskani QR / permanentni linkovi vode na kampanju — preusmjeravanje
    -- budućih uplata je rug-vektor kompromitiranog računa)
    if new.destination_address is distinct from old.destination_address then
      if exists (
        select 1 from pinka_finance.contributions c
        where c.campaign_id = old.id and c.state = 'paid'
      ) then
        raise exception 'campaign_destination_locked'
          using hint = 'Adresa računa je zaključana nakon prve uplate.';
      end if;
    end if;
  end if;

  -- ── IZMJENA 20260903: aktivacija traži BAREM JEDAN radni rail ──────────────
  -- Donacijska kampanja bez Safe-a = donacije spaljene na nultu adresu (staro
  -- pravilo, ostaje). Ticketing kampanja s radnim Stripeom nema Safe i ne treba
  -- ga — novac ide direct chargeom na račun organizatora.
  if new.state = 'active'
     and not pinka_finance.event_rail_ready(
           new.account_id, new.type::text, new.destination_address) then
    if new.type::text = 'tickets' then
      raise exception 'event_no_working_rail'
        using hint = 'Događaj treba Safe ILI aktivan Stripe račun organizatora.';
    else
      raise exception 'campaign_destination_missing'
        using hint = 'Kampanja ne može biti aktivna bez računa (Safe).';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists campaigns_write_guard on pinka_finance.campaigns;
create trigger campaigns_write_guard
  before insert or update on pinka_finance.campaigns
  for each row execute function pinka_finance.campaigns_write_guard();

-- ----- 3. publish_event — isti gate, ranija i ljepša poruka -------------------
-- Puno tijelo prepisano iz 20260717130000; jedina promjena je Safe provjera.
create or replace function pinka_finance.publish_event(
  p_campaign_id uuid,
  p_target_state text default 'active'
) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_campaign pinka_finance.campaigns;
begin
  if (select auth.uid()) is null then raise exception 'not_authenticated'; end if;
  if p_target_state is null or p_target_state not in ('active', 'closed') then
    raise exception 'invalid_target_state';
  end if;

  select * into v_campaign from pinka_finance.campaigns
    where id = p_campaign_id and deleted_at is null
    for update;
  if not found then raise exception 'campaign_not_found'; end if;
  if v_campaign.type <> 'tickets' then raise exception 'campaign_not_tickets'; end if;
  if not public.has_role_on_account(v_campaign.account_id, 'admin') then
    raise exception 'not_authorized';
  end if;

  if p_target_state = 'active' then
    if v_campaign.state <> 'draft' then
      raise exception 'invalid_state_transition';
    end if;
    -- moderacija: samo allowlistani organizatori smiju u javni feed (pilot flag)
    if not exists (
      select 1 from pinka_finance.organizer_allowlist al
      where al.account_id = v_campaign.account_id
    ) then
      raise exception 'organizer_not_allowlisted';
    end if;

    -- ── IZMJENA 20260903 ────────────────────────────────────────────────────
    -- Bilo: bez pravog Safe-a nema objave. Sad: bez ijednog radnog raila nema
    -- objave. Organizator koji prodaje samo karticom prolazi; organizator bez
    -- ijednog načina naplate i dalje ne može objaviti događaj koji nitko ne
    -- može platiti.
    if not pinka_finance.event_rail_ready(
         v_campaign.account_id, v_campaign.type::text, v_campaign.destination_address) then
      raise exception 'event_no_working_rail';
    end if;

    update pinka_finance.campaigns
       set state = 'active', visibility = 'public', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.published', v_campaign.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  else
    if v_campaign.state not in ('active', 'funded') then
      raise exception 'invalid_state_transition';
    end if;

    update pinka_finance.campaigns
       set state = 'closed', updated_at = now()
     where id = p_campaign_id;

    perform public.log_event('event.closed', v_campaign.account_id,
      jsonb_build_object('campaign_id', p_campaign_id));
  end if;

  return jsonb_build_object(
    'campaign_id', p_campaign_id,
    'state', p_target_state,
    'visibility', case when p_target_state = 'active' then 'public'
                       else v_campaign.visibility::text end
  );
end;
$$;

revoke execute on function pinka_finance.publish_event(uuid, text) from public, anon;
grant execute on function pinka_finance.publish_event(uuid, text) to authenticated, service_role;
