-- =============================================================================
-- Seed: kampanja + timeline karta sponzorskih trenutaka kanala domovina_tv
--
-- Ugovor: docs/sponzorski-trenuci-ugovor.md (O1, O2). Shema: 20261007120000.
--
-- Trenuci: `node scripts/propose-ad-slots.mjs <ytId> --json` u domovina.ai
-- (7.10.2026.), epizode iz https://cdn.domovina.ai/channels/data/domovina_tv.json.
-- Nijedna epizoda nije isključena (plan §3). Granica trenutka nikad ne siječe
-- sekciju članka; naslov trenutka = naslov prve sekcije.
--
-- Vlasnik i Safe se KOPIRAJU s donacijske kampanje podrzi-domovina-podcast
-- (isti kanal, isti DOMOVINA Safe). Ako ta kampanja ne postoji (prazna lokalna
-- baza), seed se preskače uz NOTICE — test ga pokreće nakon fixture-a.
--
-- Uključenje je reverzibilno:
--   update pinka_finance.campaigns set state = 'paused' where id = '7e5a0f3e-…';
-- =============================================================================
do $seed$
declare
  v_campaign constant uuid := '7e5a0f3e-2f1d-4c9b-9a51-0d0b1a5e7101';
  v_ref      pinka_finance.campaigns;
begin
  select * into v_ref from pinka_finance.campaigns
   where slug = 'podrzi-domovina-podcast' and deleted_at is null;
  if not found then
    raise notice 'seed sponzorskih trenutaka preskočen: nema kampanje podrzi-domovina-podcast';
    return;
  end if;

  insert into pinka_finance.campaigns (
    id, account_id, slug, type, title, description, subject_type, subject_ref,
    min_contribution_cents, currency, destination_address, chain, safe_deployed_at,
    state, visibility, youtube_channel_id, metadata
  ) values (
    v_campaign, v_ref.account_id, 'domovina-tv-sponzorski-trenuci', 'crowdfund',
    'Sponzorski trenuci — DOMOVINA TV',
    'Samoposlužna prodaja sponzorskih trenutaka u epizodama kanala domovina_tv.',
    'podcast_channel', 'domovina_tv',
    100, v_ref.currency, v_ref.destination_address, v_ref.chain, v_ref.safe_deployed_at,
    'active', 'unlisted', v_ref.youtube_channel_id,
    '{"kind":"sponsor_moments"}'::jsonb
  ) on conflict (id) do nothing;

  -- ┌──────────────────────────────────────────────────────────────────────┐
  -- │ PLACEHOLDER — cijene i run_days NISU odlučeni (plan §5 P5).          │
  -- │ Bruto (PDV 25 % uključen), djeljivo s 5 centi. Prvi cjenik je        │
  -- │ pogađanje: nisko i kratko = brže otkrivanje cijene. Promjena je      │
  -- │ ponovni poziv seed_timeline_map (upsert po zone_index); prodani      │
  -- │ trenuci zadržavaju plaćenu cijenu (slots.price_cents je snapshot).   │
  -- └──────────────────────────────────────────────────────────────────────┘
  perform pinka_finance.seed_timeline_map(v_campaign, $z$[
    {"index":0, "price_cents":3000, "run_days":30, "label_key":"sponsorZoneZatvaranje"},
    {"index":1, "price_cents":5000, "run_days":30, "label_key":"sponsorZoneTijelo"},
    {"index":2, "price_cents":8000, "run_days":30, "label_key":"sponsorZoneOtvaranje"}
  ]$z$::jsonb);


  -- oxq1U0xypu8: 12 trenutaka, trajanje 6226 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'oxq1U0xypu8', 0::smallint, $m$[
    {"start": 15, "end": 255, "zone": 2, "title": "Uvod u Misiju Udruge 'Prilika za Susret'"},
    {"start": 255, "end": 780, "zone": 1, "title": "Kalendar Događanja: Prilike za Susret Tijekom Cijele Godine"},
    {"start": 780, "end": 1260, "zone": 1, "title": "Snaga Volontera i Temelji Braka: Nesebično Davanje i Kompromisi"},
    {"start": 1260, "end": 1840, "zone": 1, "title": "Sakrament Braka: Odgovornost, Blagoslovi i Psihosocijalna Priprema"},
    {"start": 1840, "end": 2400, "zone": 1, "title": "Kritika Nedostatka Pripreme za Brak i Roditeljstvo u Obrazovanju"},
    {"start": 2400, "end": 2820, "zone": 1, "title": "Prevladavanje Straha i Poticanje Sudjelovanja: Svaki Susret je Nova Prilika"},
    {"start": 2820, "end": 3435, "zone": 1, "title": "Izazovi Bračne Komunikacije i Postavljanje Granica s Roditeljima"},
    {"start": 3435, "end": 3765, "zone": 1, "title": "Širenje misije: Suradnja i dugoročni planovi udruge 'Prilika za susret'"},
    {"start": 3765, "end": 4250, "zone": 1, "title": "Potraga za smislom: Logoterapija i hagioterapija u katoličkom kontekstu"},
    {"start": 4250, "end": 4610, "zone": 1, "title": "Služenje kao put do braka i preporučena literatura za osobni rast"},
    {"start": 4610, "end": 5220, "zone": 1, "title": "Preuzimanje odgovornosti: Od navigacije do organizacije udruge"},
    {"start": 5220, "end": 6226, "zone": 0, "title": "Neočekivani blagoslovi: Međunarodni kamp na Badiji i snaga zajedništva"}
  ]$m$::jsonb);

  -- b-nls1ck8EE: 12 trenutaka, trajanje 9645 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'b-nls1ck8EE', 1::smallint, $m$[
    {"start": 11, "end": 200, "zone": 2, "title": "Goran Jeras i 12 godina ZEF-a: Od vizije do maratona etičnog bankarstva"},
    {"start": 200, "end": 1245, "zone": 1, "title": "Fizičar u svijetu financija: Kritički pogled na neodrživost bankarskog sustava"},
    {"start": 1245, "end": 2188, "zone": 1, "title": "Javne banke i HPB: Potreba za bankarstvom kao javnom uslugom"},
    {"start": 2188, "end": 3258, "zone": 1, "title": "Ulaganje u Vrijednost i Kontrola Rizika: Temelji Etičnog Bankarstva"},
    {"start": 3258, "end": 3780, "zone": 1, "title": "EBA kao 'Bank as a Service' i Decentralizirani Model Bankarstva"},
    {"start": 3780, "end": 4419, "zone": 1, "title": "ZEF-ov Tranzicijski Fond za Ribare: Premošćivanje Financijskih Prepreka"},
    {"start": 4419, "end": 5040, "zone": 1, "title": "Stanje Zadrugarstva u Hrvatskoj: Izazovi i Perspektive"},
    {"start": 5040, "end": 5820, "zone": 1, "title": "Inovativni Zadružni Modeli za Priuštivo Stanovanje: Od Križevaca do Pule"},
    {"start": 5820, "end": 6780, "zone": 1, "title": "Od Domaće Blokade do Europske Vizije: Preporod ZEF-a"},
    {"start": 6780, "end": 7765, "zone": 1, "title": "Od Franjine Ekonomije do 'Steward Ownershipa': Novi Pogled na Vlasništvo i Poslovanje"},
    {"start": 7765, "end": 8643, "zone": 1, "title": "Financijski Perpetuum Mobile i Neodrživost Mirovinskih Sustava"},
    {"start": 8643, "end": 9645, "zone": 0, "title": "HNB-ova Politika i Izazovi Malih Hrvatskih Banaka"}
  ]$m$::jsonb);

  -- AoXN-3Mkmew: 12 trenutaka, trajanje 8227 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'AoXN-3Mkmew', 2::smallint, $m$[
    {"start": 10, "end": 190, "zone": 2, "title": "Dan svetog Josipa: Povijesni uvod u podcast"},
    {"start": 190, "end": 1010, "zone": 1, "title": "Revolucionarna transparentnost: Librland blockchain kao model državne administracije"},
    {"start": 1010, "end": 1620, "zone": 1, "title": "Librlandova tehnička evolucija: Migracija na Ethereum za naprednu privatnost"},
    {"start": 1620, "end": 2220, "zone": 1, "title": "Od carstava do nacija: Povijesna evolucija državnih ustrojstava"},
    {"start": 2220, "end": 3110, "zone": 1, "title": "AI revolucija i resursi: Političke barijere razvoju unatoč tehničkim rješenjima"},
    {"start": 3110, "end": 3920, "zone": 1, "title": "Trumpov Koncept 'Freedom Cities' i Tehnološki Razvoj"},
    {"start": 3920, "end": 4630, "zone": 1, "title": "Etika Genetskog Inženjeringa i Neutralnost Tehnologije"},
    {"start": 4630, "end": 5520, "zone": 1, "title": "Hrvatska Ekonomska Povijest i Problemi Bankarskog Sustava"},
    {"start": 5520, "end": 6330, "zone": 1, "title": "Budućnost softverskog inženjeringa: AI preuzima kodiranje, ljudi održavaju sustave"},
    {"start": 6330, "end": 6990, "zone": 1, "title": "Dorianov ambiciozni projekt: Slanje hrvatskog grba na Mjesec"},
    {"start": 6990, "end": 7740, "zone": 1, "title": "Hrvatski e-građani i potencijal Solbond tokena za blockchain glasanje"},
    {"start": 7740, "end": 8227, "zone": 0, "title": "Likvidna Demokracija i Blockchain: Direktno upravljanje narodnim glasom"}
  ]$m$::jsonb);

  -- fO7iltytw0I: 10 trenutaka, trajanje 3918 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'fO7iltytw0I', 3::smallint, $m$[
    {"start": 44, "end": 180, "zone": 2, "title": "Inženjer računalnih mreža koji je zamijenio kabele za stranačku logistiku"},
    {"start": 180, "end": 650, "zone": 1, "title": "Mreža ureda po Hrvatskoj: od Metkovića do Osijeka, a uskoro i Rijeka"},
    {"start": 650, "end": 1020, "zone": 1, "title": "Jedna izborna jedinica, tri posto praga i dva preferencijalna glasa – recept za demokratičniju Hrvatsku"},
    {"start": 1020, "end": 1440, "zone": 1, "title": "Matematički krimen: kako jedna stranka s 5,001 posto može pokupiti svih 14 mandata"},
    {"start": 1440, "end": 1900, "zone": 1, "title": "'Most nije dvaput doveo HDZ na vlast': Zdravko Marić, Todorić i dva izlaska iz Vlade"},
    {"start": 1900, "end": 2265, "zone": 1, "title": "Podravska i Splitska banka: sjećanje na vrijeme kad je Hrvatska imala svoje banke"},
    {"start": 2265, "end": 2690, "zone": 1, "title": "Niske strasti i prazna obećanja: kako se mladi konzervativci razočaravaju u desnicu"},
    {"start": 2690, "end": 3165, "zone": 1, "title": "1,7 milijuna glasova za većinu, a 1,39 milijuna ljudi kod kuće"},
    {"start": 3165, "end": 3560, "zone": 1, "title": "Kampanja koja počinje dan poslije izbora i statistika saborske aktivnosti"},
    {"start": 3560, "end": 3918, "zone": 0, "title": "Zadruge, zadružna banka i država koja je maćeha, a ne majka"}
  ]$m$::jsonb);

  -- WRE248YCIeI: 11 trenutaka, trajanje 6247 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'WRE248YCIeI', 4::smallint, $m$[
    {"start": 33, "end": 220, "zone": 2, "title": "Iz volonterskog entuzijazma u 'sobe u kojima se odlučuje': kako je nastao CroStartup"},
    {"start": 220, "end": 890, "zone": 1, "title": "Kako je EU Inc uopće nastao: europski osnivači, Draghijev izvještaj i nepostojeće jedinstveno tržište"},
    {"start": 890, "end": 1475, "zone": 1, "title": "Ugovor od dvjesto stranica ili od dvije: 'život se dogodi Ž'"},
    {"start": 1475, "end": 2100, "zone": 1, "title": "Kako mali poduzetnik u Hrvatskoj skuplja kapital? 'Tako da pita frenda ili mamu'"},
    {"start": 2100, "end": 2770, "zone": 1, "title": "Firmu možete osnovati online – i tada počinju klasične početničke greške"},
    {"start": 2770, "end": 3280, "zone": 1, "title": "Dvostruki model glasovanja i zašto se izborno pravo ne dira olako"},
    {"start": 3280, "end": 3880, "zone": 1, "title": "Pravo koje gotovo nitko ne koristi: svaki zastupnik dužan vas je primiti"},
    {"start": 3880, "end": 4580, "zone": 1, "title": "Tko bi trebao učiti građane demokraciji – i tko ih zapravo prima"},
    {"start": 4580, "end": 5220, "zone": 1, "title": "„Nikad nismo živjeli bolje\": tri generacije, osjećaj socijalne nepravde i znanje udaljeno jedan klik"},
    {"start": 5220, "end": 5780, "zone": 1, "title": "Rokovi za EU Inc: rujan na Europskom vijeću, primjena od siječnja"},
    {"start": 5780, "end": 6247, "zone": 0, "title": "Kritična masa i europske vrijednosti: ekonomijom se širi kultura"}
  ]$m$::jsonb);

  -- KvIhy5SESYs: 12 trenutaka, trajanje 6226 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'KvIhy5SESYs', 5::smallint, $m$[
    {"start": 45, "end": 390, "zone": 2, "title": "Dobrodošlica u Domovina TV studio: Početak razgovora s Matijom"},
    {"start": 390, "end": 1005, "zone": 1, "title": "Bogati kalendar događanja: Prilike za susret tijekom cijele godine"},
    {"start": 1005, "end": 1620, "zone": 1, "title": "Brak kao nesebično davanje: Izlazak iz zone komfora"},
    {"start": 1620, "end": 2317, "zone": 1, "title": "Rad na sebi i suočavanje s povredama: Put prema cjelovitosti"},
    {"start": 2317, "end": 2851, "zone": 1, "title": "Prevladavanje Straha i Otvorenost za Susrete"},
    {"start": 2851, "end": 3395, "zone": 1, "title": "Granice u Braku: Uloga Roditelja i Samostalnost Mladih Parova"},
    {"start": 3395, "end": 4067, "zone": 1, "title": "Sustavna Podrška Bračnim Parovima i Suradnja sa Zajednicama"},
    {"start": 4067, "end": 4640, "zone": 1, "title": "Inspirativni Primjeri Služenja i Preporučena Literatura"},
    {"start": 4640, "end": 4896, "zone": 1, "title": "Organizacijski Izazovi i Očekivanja Korisnika: 'Sve na Dva Klika'"},
    {"start": 4896, "end": 5404, "zone": 1, "title": "Vrijednost Susreta Uživo: Od Badije do Europskih Prijateljstava"},
    {"start": 5404, "end": 6085, "zone": 1, "title": "Snaga Nesebičnog Davanja: Kako je Nastala Suradnja Domovina TV-a i Udruge"},
    {"start": 6085, "end": 6226, "zone": 0, "title": "Budućnost Udruge: AI, Blockchain i Završni Poziv na Djelovanje"}
  ]$m$::jsonb);

  -- MGLq9v3AtvE: 10 trenutaka, trajanje 7899 s
  perform pinka_finance.seed_timeline_episode(v_campaign, 'MGLq9v3AtvE', 6::smallint, $m$[
    {"start": 10, "end": 310, "zone": 2, "title": "Interaktivni Uvod u AI-Asistirano Kodiranje: Rušenje Granica i Poticanje Suradnje"},
    {"start": 310, "end": 1035, "zone": 1, "title": "Fleksibilno Trajanje i Ambiciozni Ciljevi AI Kodiranja"},
    {"start": 1035, "end": 1820, "zone": 1, "title": "AI u Praksi: Izazovi i Prednosti Generiranja Složenih Aplikacija i Autentifikacijskih Tokova"},
    {"start": 1820, "end": 2461, "zone": 1, "title": "Dileme Reviewa AI Koda: Brzina, Kvaliteta i Uloga Ljudskog Faktora"},
    {"start": 2461, "end": 2845, "zone": 1, "title": "AI kao arhitekt projekta: Od specifikacija do vizualizacije"},
    {"start": 2845, "end": 4635, "zone": 1, "title": "Izazovi i troškovi AI modela: Claudeov limit i usporedba performansi"},
    {"start": 4635, "end": 5450, "zone": 1, "title": "AI u praksi: Od prototipova do dokumentacije i konzistentnosti koda"},
    {"start": 5450, "end": 6300, "zone": 1, "title": "Brzina AI kodiranja: Od prototipa do produkcije"},
    {"start": 6300, "end": 7116, "zone": 1, "title": "GitHub sinkronizacija i Cloudflare integracija: Izazovi automatizacije DNS-a"},
    {"start": 7116, "end": 7899, "zone": 0, "title": "Flutter Web i grafika: Fluidnost i 'lude grafike' uz WebAssembly"}
  ]$m$::jsonb);

  raise notice 'seed sponzorskih trenutaka: % trenutaka', (
    select count(*) from pinka_finance.slots s
      join pinka_finance.slot_maps m on m.id = s.map_id
     where m.campaign_id = v_campaign);
end
$seed$;

-- očekivano: 79 trenutaka u 7 epizoda
select 'OK sponzorski_trenuci_seed' as status;

