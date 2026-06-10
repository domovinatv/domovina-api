-- =============================================================================
-- pinka_finance — opcionalna geo-lokacija kampanje (marker na karti)
--
-- Kampanja može imati konkretnu fizičku lokaciju (npr. obnova crkve, klub,
-- lokalna inicijativa). Koordinate + ljudski naziv mjesta omogućuju prostorni
-- prikaz svih javnih aktivnih kampanja na karti (gis.domovina.ai sloj
-- "Pinka kampanje") s linkom natrag na pinka.io/c/{slug} za donaciju.
--
-- Bez RLS promjena: kolone se voze na postojećim campaigns policyjima
-- (anon čita public/aktivne, piše samo vlasnik accounta).
-- =============================================================================

alter table pinka_finance.campaigns
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists location_name text;

-- lat/lng dolaze u paru (marker bez jedne osi je besmislen); name smije sam.
alter table pinka_finance.campaigns
  drop constraint if exists campaigns_latitude_range,
  drop constraint if exists campaigns_longitude_range,
  drop constraint if exists campaigns_location_pair;

alter table pinka_finance.campaigns
  add constraint campaigns_latitude_range
    check (latitude is null or (latitude >= -90 and latitude <= 90)),
  add constraint campaigns_longitude_range
    check (longitude is null or (longitude >= -180 and longitude <= 180)),
  add constraint campaigns_location_pair
    check ((latitude is null) = (longitude is null));

-- Karta dohvaća "javne aktivne s koordinatama" — partial index drži taj upit
-- jeftinim i kad tablica naraste.
create index if not exists campaigns_geo_idx
  on pinka_finance.campaigns (latitude, longitude)
  where latitude is not null and visibility = 'public';

select 'OK pinka_campaign_location' as status;
