# Pinka destination model — non-custodial, odredište je vlasnikova adresa

Status: **ODLUKA (2026-07-20, Matija)** — zamjenjuje platform-custody model iz
[`pinka-payout-execution.md`](./pinka-payout-execution.md) (sad superseded).

## Odluka

> `campaigns.destination_address` je **uvijek adresa koju kontrolira vlasnik
> kampanje** — njegov postojeći Safe, novi Safe deriviran iz njegovih ključeva,
> ili EOA (Safe preporučen). **Platforma nikad ne drži ključ** nad sredstvima
> kampanje. "Isplata" kao platformska operacija ne postoji: novac je vlasnikov
> onog trenutka kad je transfer miniran.

Motivacija: platform-custody model (1-of-1 ekosustavni signer nad svim campaign
Safe-ovima) je single point of failure — krađa jednog hot ključa značila bi
mogućnost pražnjenja SVIH kampanja kumulativno. To je nedopustivo pri skaliranju
(500 kampanja × pozamašni saldi). Umjesto slojeva mitigacije (cold multisig,
destination registry, scoped moduli) — maknuli smo custody u potpunosti.

## Što platforma JEST

| Uloga | Mehanizam |
|---|---|
| **Rail** | SEPA (Monerium mint → MPT rail forward), EIP-681 QR, in-app wallet — svi šalju izravno na `destination_address` |
| **Knjigovodstvo** | indexer/confirm kreditiraju `contributions` čitanjem on-chain transfera; zid podrške, stats — čisto čitanje |
| **Gateovi integriteta** | Certilia KYC za kreiranje kampanje, YouTube claim za channel-anchored kampanje, **destination lock** nakon prve uplate (DB trigger) |
| **Olakšavanje Safe-a** | pinka.io derivira Safe iz VLASNIKOVIH ključeva ("account" = wallet-native named account; "derive" = 1/1 iz spojenog signera) ili se ručno upiše postojeća adresa |

## Što platforma NIJE

- Ne drži ključeve odredišta, ne potpisuje isplate, ne izvršava payoute.
- `payouts` / `request_payout` / `mark_payout_*` / off-chain izvršitelj — **van
  opsega**; tablica i RPC ostaju u shemi kao legacy (nisu na putu novca).
- Yield keeper — vlasnik po želji sam u svom Safeu (van platforme).

## Preostala (omeđena) custody točka

SEPA rail: minute između Monerium minta na MPT rail Safe i forwarda na
odredište. In-flight iznosi, ne salda kampanja. Uklonjivo per-vlasnik ako
vlasnik poveže vlastiti Monerium račun. Prihvaćen rizik.

## Blast-radius (nakon ove odluke)

| Kompromitirano | Napadač dobiva |
|---|---|
| Bilo koji platformin hot ključ | Ništa od sredstava kampanja |
| MPT rail Safe ključ | Samo in-flight SEPA sredstva (minute) |
| Postgres / domovina-api | Prljanje knjigovodstva; on-chain sredstva netaknuta |
| Vlasnikov Safe | Samo ta jedna kampanja (vlasnikova odgovornost; zato Safe ≥ 2-of-3) |

## Referentna implementacija (MVP 2026-07-20)

Kampanja `podrzi-domovina-podcast` (`4c3c532b-0023-4207-91bd-93f3aff300b7`):
subject `podcast_channel`/`domovina_tv` (+ UC id) + 6 epizoda kroz
`campaign_subjects`; `destination_address` = **DOMOVINA Safe 2-od-3**
`0x6693a7D19486Dc45e9F90Fd2D515d972bBA2d65e` (isti kao donate.domovina.ai,
Monerium-linked). Napomena: direktni Monerium mintovi (donate.domovina.ai EPC
memo put) na taj Safe dolaze kao Transfer s `0x0` → indexer ih kreditira kao
anonimne donacije na zidu — namjerno, to i jesu donacije.

## Smjernice za buduće iteracije

1. Novi campaign-create putevi MORAJU izvor destinacije imati u vlasnikovim
   ključevima (derive/manual). Nikad platformin signer kao owner odredišta.
2. Ako se ikad vrati platformska automatika nad sredstvima (yield, split),
   ide isključivo kroz **scoped module** (Zodiac Roles: fiksiran primatelj =
   sam Safe) — nikad puni owner ključ.
3. Graduation path: vlasnik može svoj Safe širiti/mijenjati ownere sam —
   platforma se ne pita.
