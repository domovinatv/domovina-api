-- =============================================================================
-- Događaji: koordinate mjesta i alt tekst naslovne slike
--
-- Izvor: domovina-ulaznice `web/docs/decisions.md` odluke 14 i 15 (Ivanov
-- prijedlog sheme, 2026-11-19), sesija S2b lanca `web/`.
--
--   venue_lat, venue_lon  numeric(9,6) — karta, link na Google/Apple Maps i
--                         `geo` u JSON-LD-u. Oba ili nijedno, u rasponu.
--   cover_image_alt       text ≤ 300 — pristupačnost i `og:image:alt`.
--
-- Sve je nullable, pa postojeći događaji i klijenti (mobilne aplikacije,
-- React SPA) rade nepromijenjeno; `events-feed` ih vraća aditivno.
--
-- RPC-ovi `create_event` / `update_event` se NE mijenjaju: novi parametri bi
-- značili novi potpis funkcije (drop + ponovni grant), a događaje danas unosi
-- agent kroz seed (editor je odgođen). Seedovi postavljaju polja izravnim
-- `update pinka_finance.events` nakon `create_event`.
--
-- Idempotentno: stupci s `if not exists`, ograničenja samo ako ne postoje.
-- Drugi run = no-op.
-- =============================================================================

alter table pinka_finance.events
  add column if not exists venue_lat numeric(9,6),
  add column if not exists venue_lon numeric(9,6),
  add column if not exists cover_image_alt text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'pinka_finance.events'::regclass and conname = 'events_venue_geo_pair'
  ) then
    alter table pinka_finance.events
      add constraint events_venue_geo_pair
        check ((venue_lat is null) = (venue_lon is null));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'pinka_finance.events'::regclass and conname = 'events_venue_geo_range'
  ) then
    alter table pinka_finance.events
      add constraint events_venue_geo_range
        check ((venue_lat is null or venue_lat between -90 and 90)
           and (venue_lon is null or venue_lon between -180 and 180));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'pinka_finance.events'::regclass and conname = 'events_cover_image_alt_len'
  ) then
    alter table pinka_finance.events
      add constraint events_cover_image_alt_len
        check (cover_image_alt is null or char_length(cover_image_alt) between 1 and 300);
  end if;
end;
$$;

comment on column pinka_finance.events.venue_lat is
  'Geografska širina mjesta (WGS84). Postavlja se zajedno s venue_lon.';
comment on column pinka_finance.events.venue_lon is
  'Geografska dužina mjesta (WGS84). Postavlja se zajedno s venue_lat.';
comment on column pinka_finance.events.cover_image_alt is
  'Alt tekst naslovne slike (cover_image_url), ≤ 300 znakova.';

notify pgrst, 'reload schema';

select 'OK events_venue_geo' as status;
