-- =============================================================================
-- Rotacija QR tokena — ponovna dostava ulaznice koju je kupac izgubio
--
-- Problem koji rješava: `deliver_ticket_orders` isporučuje plaintext tokena
-- JEDNOKRATNO i briše `qr_token_once`. To je dobar invariant (u bazi trajno
-- samo hash), ali ima posljedicu koju je U1 ostavio otvorenom (§Gotcha 3):
-- kupac koji izgubi e-mail više NIKAD ne može dobiti svoj QR. Danas je svaki
-- takav slučaj ručna intervencija podrške, a na događaju s nekoliko stotina
-- ljudi to nije rub nego svakodnevica.
--
-- Odabrana opcija: (b) iz U1 §Gotcha 3 — **rotacija**. Ulaznici se izdaje NOVI
-- token, stari hash prestaje vrijediti. Time:
--   * kupac dobije upotrebljivu ulaznicu,
--   * izgubljeni/proslijeđeni stari QR prestaje raditi na ulazu (to je
--     sigurnosno svojstvo, ne nuspojava — inače bi „ponovna dostava" bila
--     tvornica duplikata iste ulaznice),
--   * invariant „u bazi trajno samo hash" ostaje netaknut.
--
-- Što se NE rotira:
--   * `checked_in` — osoba je već ušla; nova ulaznica ne bi imala svrhu, a
--     rotacija bi omogućila drugi ulaz na isti serial,
--   * `void` — poništena ulaznica ostaje poništena.
--
-- Autorizacija: service_role only. Pozivatelj je Worker, koji je prije poziva
-- već dokazao posjedovanje `order_id` (bearer capability, isti model kao
-- `contribution_status`) i potrošio svoj rate limit. Baza dodatno drži tvrdi
-- limit (v. dolje) da kompromitiran Worker ne može vrtjeti rotacije u petlju.
--
-- ⚠️ REVIEW(fable): dvije odluke vrijedne osporavanja.
--   1. Limit je 5 rotacija / 24 h po narudžbi, brojan iz `contribution_events`
--      umjesto iz novog stupca. Prednost: bez promjene sheme i s punim audit
--      tragom. Mana: count nad tablicom događaja pri svakom pozivu. Ako se
--      pokaže sporim, indeks `(contribution_id, event_type, created_at)` je
--      jeftiniji potez od denormalizacije.
--   2. Rotira se CIJELA narudžba, ne pojedina ulaznica. Za kupca koji je
--      proslijedio jednu ulaznicu prijatelju to znači da mu i prijateljev QR
--      prestane vrijediti. Alternativa (rotacija po serialu) traži da kupac
--      zna koji je serial izgubio — što u praksi ne zna. Ako se pokaže da
--      grupne kupnje pate, dodaj `p_serials text[] default null`.
--
-- Idempotentno: drugi run je no-op.
-- =============================================================================

create or replace function pinka_finance.rotate_ticket_tokens(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_order pinka_finance.contributions;
  v_recent integer;
  v_rotated integer := 0;
  v_ticket record;
  v_token text;
  v_result jsonb;
begin
  if p_order_id is null then
    return jsonb_build_object('status', 'order_not_found');
  end if;

  select * into v_order
    from pinka_finance.contributions
   where id = p_order_id and tier_id is not null
   for update;
  if not found then
    return jsonb_build_object('status', 'order_not_found');
  end if;

  -- Rotacija je operacija nad PLAĆENOM narudžbom. Rezervacija bez uplate nema
  -- ulaznica, pa ni tokena.
  if v_order.state <> 'paid' then
    return jsonb_build_object('status', 'order_not_paid', 'state', v_order.state::text);
  end if;

  -- tvrdi limit u bazi (Workerov KV limit je prvi sloj, ovo je drugi)
  select count(*)::integer into v_recent
    from pinka_finance.contribution_events
   where contribution_id = p_order_id
     and event_type = 'ticket.token_rotated'
     and created_at > now() - interval '24 hours';
  if v_recent >= 5 then
    return jsonb_build_object('status', 'rate_limited', 'rotations_24h', v_recent);
  end if;

  -- Nova vrijednost po ulaznici. Petlja (a ne jedan UPDATE) jer svaka ulaznica
  -- mora dobiti SVOJ token — jedan `gen_random_bytes` u set-klauzuli bi se u
  -- Postgresu izračunao po retku, ali oslanjati se na to je krhko i nečitljivo.
  for v_ticket in
    select id from pinka_finance.tickets
     where contribution_id = p_order_id
       and state = 'issued'
     order by serial
  loop
    v_token := encode(extensions.gen_random_bytes(32), 'hex');
    update pinka_finance.tickets
       set qr_token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'),
           qr_token_once = v_token,
           updated_at = now()
     where id = v_ticket.id;
    v_rotated := v_rotated + 1;
  end loop;

  if v_rotated = 0 then
    -- sve ulaznice su iskorištene ili poništene — nema što isporučiti
    return jsonb_build_object('status', 'nothing_to_rotate');
  end if;

  insert into pinka_finance.contribution_events (contribution_id, campaign_id, event_type, payload)
  values (p_order_id, v_order.campaign_id, 'ticket.token_rotated',
          jsonb_build_object('rotated', v_rotated, 'rotations_24h', v_recent + 1));

  select jsonb_build_object(
    'status', 'rotated',
    'order_id', p_order_id,
    'state', v_order.state::text,
    'rotated', v_rotated,
    'tickets', coalesce(jsonb_agg(jsonb_build_object(
      'serial', t.serial,
      'holder_name', t.holder_name,
      'holder_email', t.holder_email,
      'state', t.state::text,
      -- ⚠️ plaintext izlazi iz baze SAMO ovdje i samo u ovom odgovoru
      'qr_token', t.qr_token_once
    ) order by t.serial), '[]'::jsonb)
  ) into v_result
  from pinka_finance.tickets t
  where t.contribution_id = p_order_id;

  -- Isti ugovor kao deliver_ticket_orders: plaintext se briše odmah nakon što
  -- je pročitan u odgovor. Ako dostava padne, sljedeća rotacija radi novi token.
  update pinka_finance.tickets
     set qr_token_once = null, updated_at = now()
   where contribution_id = p_order_id
     and qr_token_once is not null;

  return v_result;
end;
$$;

comment on function pinka_finance.rotate_ticket_tokens(uuid) is
  'Izda NOVE QR tokene za neiskorištene ulaznice plaćene narudžbe i vrati ih '
  'jednokratno (stari QR prestaje vrijediti). Za kupca koji je izgubio e-mail. '
  'service_role only — pozivatelj mora prije toga dokazati posjedovanje '
  'order_id. Tvrdi limit 5/24 h po narudžbi; poslovni ishodi su status jsonb.';

revoke execute on function pinka_finance.rotate_ticket_tokens(uuid) from public, anon, authenticated;
grant execute on function pinka_finance.rotate_ticket_tokens(uuid) to service_role;

-- Limit iz gornje funkcije čita contribution_events po (narudžba, tip, vrijeme).
create index if not exists ix_contribution_events_rotate
  on pinka_finance.contribution_events (contribution_id, event_type, created_at desc);
