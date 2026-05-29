# Apple "Sign in with Apple" — automatska rotacija client secreta (launchd)

## Zašto

Apple client secret nije statičan — to je **ES256 JWT koji Apple capa na ~6
mjeseci**. Ne može biti trajan, a self-hosted GoTrue ga **ne refresha sam**
(hosted Supabase to skriva; self-hostom to gubiš). Kad istekne, "Login with
Apple" puca s `invalid_client`.

Umjesto ručne rotacije svakih ~6 mjeseci, lokalni **launchd** agent mjesečno
provjeri istek i rotira **samo kad treba**.

## Zašto lokalno (a ne na serveru / remote routine)

Rotacija treba **`.p8` privatni ključ**, koji namjerno živi **samo na ovom
Macu** (`~/secrets/AuthKey_ZWZVB2GTN5.p8`, chmod 600). Stavljanje `.p8` na
server ili u remote agent povećalo bi attack surface. Zato automatizaciju vrti
launchd na Macu — on ima pristup ključu, a `.p8` nikad ne napušta stroj.
(Remote /schedule podsjetnik postoji kao backup notifikacija, ali ne može sam
rotirati — nema ključ.)

## Komponente

| Datoteka | Uloga |
|---|---|
| `scripts/gen-apple-secret.mjs` | Generira ES256 JWT iz `.p8` (no deps). |
| `scripts/rotate-apple-secret.sh` | Provjeri istek → (ako < threshold) generiraj → upiši u `.local-secrets.env` → push na Coolify → re-deploy → smoke test. |
| `scripts/launchd/ai.domovina.apple-secret-rotate.plist` | launchd template (1. u mjesecu, 04:00 lokalno). |
| `.local-secrets.env` | `APPLE_P8_PATH`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `GOTRUE_EXTERNAL_APPLE_SECRET` + `COOLIFY_*`. Gitignored. |
| `logs/apple-secret-rotate.log` | launchd stdout/stderr. Gitignored. |

## Kako skripta odlučuje (idempotentno)

```bash
./scripts/rotate-apple-secret.sh --check   # samo ispiši preostale dane, ništa ne mijenjaj
./scripts/rotate-apple-secret.sh           # rotiraj SAMO ako istječe za < THRESHOLD_DAYS (def 30)
./scripts/rotate-apple-secret.sh --force   # rotiraj odmah bez obzira na istek
```

Mjesečni launchd poziva default mode. Dok je secret > 30 dana od isteka, izađe
bez ikakve promjene (nema nepotrebnog re-deploya). Prvi mjesečni run unutar
30-dnevnog prozora odradi punu rotaciju → novi secret vrijedi ~180 dana →
sljedeća rotacija ~5 mjeseci kasnije. Potpuno samoodrživo.

⚠️ Puna rotacija radi **full-stack re-deploy** (`coolify-restart.sh`) →
~2-3 min downtime cijelog Supabase stacka. Zato je zakazana za **04:00**.

## Instalacija

```bash
cp scripts/launchd/ai.domovina.apple-secret-rotate.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.domovina.apple-secret-rotate.plist
launchctl enable gui/$(id -u)/ai.domovina.apple-secret-rotate
```

Provjera da je učitan:

```bash
launchctl print gui/$(id -u)/ai.domovina.apple-secret-rotate | grep -E 'state|runs'
```

Ručni test (okine job odmah, neovisno o rasporedu):

```bash
launchctl kickstart -k gui/$(id -u)/ai.domovina.apple-secret-rotate
tail -f logs/apple-secret-rotate.log
```

## Uninstall / pauza

```bash
launchctl bootout gui/$(id -u)/ai.domovina.apple-secret-rotate
rm ~/Library/LaunchAgents/ai.domovina.apple-secret-rotate.plist
```

## Gotchas

- **NODE_BIN je pinned** na trenutni nvm node u plistu (launchd nema tvoj
  shell PATH). Ako nadogradiš node (`nvm install/use`), ažuriraj `NODE_BIN` u
  `~/Library/LaunchAgents/...plist` (i u repo templateu) pa reload.
- **Mac mora biti upaljen** ~04:00 1. u mjesecu. Ako je uspavan/ugašen,
  launchd pokrene job pri sljedećem buđenju (missed-run catch-up). Sigurnosna
  margina (30 dana) pokriva i propušteni mjesec.
- **Secret-redaction u nekim shell/agent okruženjima**: skripta zapisuje JWT
  preko shell varijable + `printf` (ne `grep`→redirect), da preživi redakciju.
- Po rotaciji `git status` neće pokazati ništa novo — `.local-secrets.env` i
  `logs/` su gitignored.

## Manualna rotacija (ako launchd nije opcija)

```bash
node scripts/gen-apple-secret.mjs   # čita APPLE_* iz .local-secrets.env
# → zamijeni GOTRUE_EXTERNAL_APPLE_SECRET u .local-secrets.env
# → push (coolify-env-apply.sh --file=...) + coolify-restart.sh
```

Ili jednostavno: `./scripts/rotate-apple-secret.sh --force`.

Vezano: `docs/setup-guides/apple-oauth.md` (inicijalni setup), `docs/secret-rotation.md`.
