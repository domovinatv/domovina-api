# Secret rotation — runbook & incident log

> **Princip:** svaka plaintext izloženost secreta (chat/LLM transkript, log, screenshot,
> commit, CI output) = taj secret je **kompromitiran** i mora se rotirati. Nije bitno
> koliko "privatan" se kanal čini — transkripti se spremaju, backupaju i mogu se dijeliti.

Tijekom developmenta leakovi su realni (brže je zalijepiti pravu vrijednost nego
placeholder). Ovaj dokument drži **rotation queue** (što je iscurilo i čeka rotaciju)
i **postupke** po tipu secreta. Cilj: nijedan leak ne ostane "zaboravljen".

---

## 1. Kada rotirati (triggeri)

- Secret se pojavio u Claude Code / LLM chatu (čak i kao dio env dumpa).
- Secret commitan u repo (čak i ako je poslije obrisan — ostaje u git history).
- Secret u screenshotu / Loom / Slack / emailu.
- Sumnja na curenje (npr. alat ispisao env, vidi incident 2026-05-29).

Ako nisi siguran je li nešto secret → tretiraj kao da jest.

---

## 2. Rotation queue (živa lista)

Dodaj redak kad nešto iscuri; makni (→ "Done") kad je rotirano i propagirano.

| Datum leaka | Secret(i) | Izvor leaka | Status |
|---|---|---|---|
| 2026-05-29 | `SERVICE_PASSWORD_JWT`, `SERVICE_SUPABASESERVICE_KEY`, `SERVICE_SUPABASEANON_KEY`, `SERVICE_PASSWORD_POSTGRES`, `SMTP_PASS` (Resend), `GOTRUE_EXTERNAL_GOOGLE_SECRET`, `SERVICE_PASSWORD_{MINIO,LOGFLARE,LOGFLAREPRIVATE,SUPAVISORSECRET,VAULTENC,PGMETACRYPTO,ADMIN}`, `SECRET_PASSWORD_REALTIME` | `coolify-env-merge.sh` bug ispisao live env u chat (fix `8211733`) | ⏳ **OTVORENO** — odgođeno na maintenance window (rotacija JWT-a ruši frontende dok ne dobiju novi anon key) |

> Napomena: imena ključeva NISU tajna — vrijednosti jesu. U ovoj tablici drži samo imena.

---

## 3. Postupci po tipu secreta

### 3a. Interni Supabase secreti (JWT secret, anon/service key, postgres, minio, logflare, supavisor, vaultenc, pgmetacrypto, admin, realtime)

Sve ih generira `scripts/build-coolify-env.sh` (bootstrap flow):

```bash
# 1. osvježi .coolify-defaults.env (Coolify Developer view → copy) i .local-secrets.env
# 2. regeneriraj sve fresh + merge:
./scripts/build-coolify-env.sh          # fresh secreti → clipboard (+ masked preview)
# 3. Coolify → Bulk edit → Paste → Save → Deploy
```

⚠️ **Disrupcija:** novi `SERVICE_PASSWORD_JWT` mijenja `ANON_KEY` i `SERVICE_ROLE_KEY`
(deriviraju se iz njega). Posljedica:
- sve postojeće korisničke sesije postaju nevažeće (re-login),
- **svaki frontend (`domovina.ai` Flutter itd.) prestaje raditi dok ne dobije novi anon key** —
  treba koordinirati s frontend timom/sesijom prije rotacije.

Zato JWT rotacija ide u **najavljeni maintenance window**, ne usput.

### 3b. Resend (`SMTP_PASS`)

1. https://resend.com → API Keys → revoke stari `re_*`, kreiraj novi.
2. Stavi novi u Coolify env (`SMTP_PASS`) preko [coolify-env-merge.sh](../scripts/coolify-env-merge.sh)
   workflow ili Coolify UI → redeploy auth.
3. Niska disrupcija (samo mail slanje).

### 3c. Google OAuth (`GOTRUE_EXTERNAL_GOOGLE_SECRET`)

1. Google Cloud Console → APIs & Services → Credentials → OAuth client → **Reset secret**.
2. Novi secret u Coolify (`GOTRUE_EXTERNAL_GOOGLE_SECRET`) → redeploy auth.
3. `GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID` ostaje isti (nije tajna, ali ako se mijenja → i frontend).

### 3d. Postgres (`SERVICE_PASSWORD_POSTGRES`)

`scripts/db-rotate-postgres-password.sh` (ALTER USER sa starom → nova). DB nije javno
izložen (samo preko SSH/internal) → niži rizik, ali rotiraj svejedno ako je iscurio.

---

## 4. Alati MORAJU maskirati po defaultu

Pouka iz incidenta 2026-05-29: alat koji dira env mora **whitelistati što se prikazuje**
(npr. samo ne-tajni config ključevi), a **sve ostalo maskirati** — nikad blacklist
secreta. `coolify-env-merge.sh` sad radi tako (vidi `safeflag`/`CSV_UNION_KEYS`).
Isti princip primijeni na svaki budući env/secret alat.

---

## 5. Gdje secreti žive (i NE žive)

- **Žive:** Coolify env (service), `.local-secrets.env` (gitignored), `.coolify-extra.env` (gitignored).
- **NE žive:** repo (osim `.env.example` / `*.example` placeholderi), memory fileovi, chat.
- Gitignored env fileovi: `.coolify-current.env`, `.coolify-merged.env`, `.coolify-extra.env`,
  `.coolify-defaults.env`, `.local-secrets.env`. Briši `.coolify-{current,merged}.env` nakon korištenja.
