-- =============================================================================
-- Događaji (E2) — P2P event ticketing: schema
-- Reference: safe-wallet-monorepo/docs/whitelabel-wallet/11-dogadjaji-p2p-ticketing.md
--            (§3.2 mapiranje na pinka_finance), handoffs/dogadjaji-2-backend.md
--
-- Postojeće pokriva ~80 %: campaigns (type='tickets', destination_address =
-- organizatorov Safe), campaign_tiers (kind='ticket', price_cents, inventory),
-- contributions (= narudžbe: tier_id, quantity, state machine, onchain
-- idempotencija). Ova migracija dodaje ono što nedostaje:
--
--   1. pinka_finance.events        — 1:1 detalji eventa uz campaign
--   2. campaign_tiers polja        — imenska (holder po komadu), sale window
--   3. contributions polja         — holders payload, rezervacija s TTL-om,
--                                    deklarirani payer Safe (ručno sparivanje)
--   4. pinka_finance.tickets       — ulaznica-komad: serial, holder, QR hash,
--                                    check-in state (redeem = faza E3)
--
-- QR dizajn = Tier 0 iz docs/pinka-onchain-receipts-tokenization-plan.md:
-- opaque random token; u bazi trajno SAMO hash. Plaintext (qr_token_once)
-- postoji isključivo tranzijentno od izdavanja do prve autorizirane dostave
-- kupcu (events-tickets) i tada se briše — svjesna iznimka radi crash-recovery
-- slučaja (uplata prošla, app umro prije nego je token stigao do uređaja).
--
-- GDPR / retencija (imenske ulaznice = osobni podaci holdera):
--   - holder_name/holder_email čitaju SAMO kupac (kontributor) i org admin
--     (RLS u _rls migraciji); nikad u javnim viewovima.
--   - POLICY: nakon završetka eventa (events.ends_at) + 90 dana roka za
--     reklamacije, holder polja se anonimiziraju (update ... set holder_name =
--     null, holder_email = null). Automatizacija ide uz E4 (organizator
--     self-service); do tada je ovo dokumentirana ručna obveza operatera.
-- =============================================================================

-- ----- enums (idempotent via do blocks) --------------------------------------
do $$ begin
  create type pinka_finance.ticket_state as enum ('issued','checked_in','void');
exception when duplicate_object then null;
end $$;

-- ----- events (1:1 detalji uz campaigns type='tickets') -----------------------
create table if not exists pinka_finance.events (
  campaign_id uuid primary key references pinka_finance.campaigns(id) on delete cascade,
  event_type text not null default 'ostalo',            -- konferencija|koncert|meetup|kamp|ostalo
  venue_name text not null,
  venue_address text,
  venue_city text not null,
  starts_at timestamptz,                                 -- null = najavljen bez termina
  ends_at timestamptz,
  timezone text not null default 'Europe/Zagreb',
  description_hr text,
  description_en text,
  cover_image_url text,
  organizer_name text not null,
  organizer_email text,
  organizer_web text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_type_format check (event_type ~ '^[a-z0-9_]{1,40}$'),
  constraint events_venue_name_len check (char_length(venue_name) between 1 and 160),
  constraint events_venue_address_len check (venue_address is null or char_length(venue_address) <= 200),
  constraint events_venue_city_len check (char_length(venue_city) between 1 and 80),
  constraint events_timezone_len check (char_length(timezone) between 1 and 64),
  constraint events_description_hr_len check (description_hr is null or char_length(description_hr) <= 20000),
  constraint events_description_en_len check (description_en is null or char_length(description_en) <= 20000),
  constraint events_cover_url_format check (
    cover_image_url is null
    or (char_length(cover_image_url) <= 1000 and cover_image_url ~* '^https://')
  ),
  constraint events_organizer_name_len check (char_length(organizer_name) between 1 and 160),
  constraint events_organizer_email_len check (organizer_email is null or char_length(organizer_email) <= 200),
  constraint events_organizer_web_len check (organizer_web is null or char_length(organizer_web) <= 200),
  constraint events_dates_order check (starts_at is null or ends_at is null or ends_at > starts_at)
);

drop trigger if exists trg_events_updated on pinka_finance.events;
create trigger trg_events_updated
  before update on pinka_finance.events
  for each row execute function public.touch_updated_at();

-- ----- campaign_tiers: imenska + prodajni prozor ------------------------------
alter table pinka_finance.campaign_tiers
  add column if not exists imenska boolean not null default false,  -- holder ime/prezime po komadu (MoMo model)
  add column if not exists sale_start timestamptz,                   -- null = prodaja otvorena
  add column if not exists sale_end timestamptz;                     -- null = bez roka

alter table pinka_finance.campaign_tiers
  drop constraint if exists tiers_sale_window_order;
alter table pinka_finance.campaign_tiers
  add constraint tiers_sale_window_order
    check (sale_start is null or sale_end is null or sale_end > sale_start) not valid;

-- ----- contributions: holders payload + rezervacija s TTL-om ------------------
-- Za razliku od donacija (inventory se broji tek na paid), ulaznice se
-- REZERVIRAJU pri narudžbi (create_ticket_order inkrementira inventory_claimed
-- odmah, uz oversell check u istoj naredbi). reserved=true označava da je
-- inventory već zauzet — tg_contribution_state tada NE inkrementira ponovno na
-- paid, a na expired rezervaciju vraća. TTL ~20 min (reserve_expires_at).
alter table pinka_finance.contributions
  add column if not exists holders jsonb,                        -- [{full_name, email?}] za imenske tiere
  add column if not exists reserved boolean not null default false,
  add column if not exists reserve_expires_at timestamptz,
  add column if not exists declared_payer_address text;          -- kupčev Safe (ručno sparivanje uplata, §8)

alter table pinka_finance.contributions
  drop constraint if exists contributions_declared_payer_format,
  drop constraint if exists contributions_holders_size;
alter table pinka_finance.contributions
  add constraint contributions_declared_payer_format
    check (declared_payer_address is null or declared_payer_address ~ '^0x[0-9a-fA-F]{40}$') not valid,
  add constraint contributions_holders_size
    check (holders is null or pg_column_size(holders) <= 16384) not valid;

-- istek rezervacija: partial index za expire_stale_ticket_orders()
create index if not exists ix_contributions_reservation_expiry
  on pinka_finance.contributions (reserve_expires_at)
  where state = 'pending' and reserved;

-- ----- tickets (jedan red = jedna ulaznica-komad) ------------------------------
create table if not exists pinka_finance.tickets (
  id uuid primary key default gen_random_uuid(),
  contribution_id uuid not null references pinka_finance.contributions(id) on delete cascade,
  campaign_id uuid not null references pinka_finance.campaigns(id) on delete cascade,
  tier_id uuid references pinka_finance.campaign_tiers(id) on delete set null,
  serial text not null,                                  -- npr. MON-000042 (unique per campaign)
  holder_name text,                                      -- PII — RLS: kupac + org admin; retencija gore
  holder_email text,                                     -- PII — isto
  qr_token_hash text not null unique,                    -- sha256 hex opaque tokena (trajni zapis)
  qr_token_once text,                                    -- ★ tranzijentni plaintext do prve dostave; briše se
  state pinka_finance.ticket_state not null default 'issued',
  checked_in_at timestamptz,                             -- redeem = faza E3
  checked_in_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tickets_serial_len check (char_length(serial) between 1 and 40),
  constraint tickets_holder_name_len check (holder_name is null or char_length(holder_name) <= 120),
  constraint tickets_holder_email_len check (holder_email is null or char_length(holder_email) <= 200),
  unique (campaign_id, serial)
);

create index if not exists ix_tickets_contribution on pinka_finance.tickets(contribution_id);
create index if not exists ix_tickets_campaign on pinka_finance.tickets(campaign_id, state);

drop trigger if exists trg_tickets_updated on pinka_finance.tickets;
create trigger trg_tickets_updated
  before update on pinka_finance.tickets
  for each row execute function public.touch_updated_at();

comment on table pinka_finance.tickets is
  'Ulaznica-komad (E2). QR = Tier 0 opaque token: trajno samo sha256 hash; '
  'qr_token_once je tranzijentni plaintext od izdavanja do prve autorizirane '
  'dostave kupcu, zatim null. Holder polja su PII — retencija: anonimizirati '
  'nakon events.ends_at + 90 dana.';

-- ----- enable RLS (policies u _rls migraciji) ---------------------------------
alter table pinka_finance.events  enable row level security;
alter table pinka_finance.tickets enable row level security;

select 'OK events_ticketing_schema' as status;
