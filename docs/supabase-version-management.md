# Supabase version management — lokal (CLI) ↔ prod (Coolify)

Kako su Supabase verzije pinane, kako se PROD update-a sigurno, i zašto lokal i
prod mogu (i smiju) privremeno divergirati. Trajni zapis odluka — vidi i
[`supabase-versions.md`](supabase-versions.md) za živi snapshot tagova.

> TL;DR
> - **Coolify NE auto-update-a Supabase.** Compose živi u Coolifyju, tagovi su pinani.
> - **"Pull Latest Images & Restart" ≠ upgrade.** Uz pinane tagove samo re-pulla iste
>   digeste i recreatea kontejnere — verzije ostaju iste. Zato je nisko-rizično.
> - **Pravi upgrade = namjerno mijenjanje image tagova** u Coolify compose-u → Redeploy.
> - **Lokal (CLI) = canary.** Smije biti ispred prod-a; služi za testiranje sljedećeg
>   prod bumpa. Nikad ne dopusti da app ovisi o feature-u kojeg prod još nema.

---

## 1. Dva orkestratora, iste komponente

| | Lokal | Prod |
|---|---|---|
| Orkestrator | Supabase **CLI** (vlastiti bundlani compose) | **Coolify** (Supabase one-click service) |
| Compose | generira CLI po svojoj verziji | živi u Coolifyju (`/data/coolify/services/<uuid>/`), **ne u gitu** |
| Verzije fiksira | `supabase` binary (brew) | image tagovi u Coolify compose-u |
| Ingress | Kong direktno na :55321 | Cloudflare Tunnel → Traefik → Kong |
| Storage backend | CLI interni | MinIO |
| Pooler | (CLI) | Supavisor |
| Gateway image | `supabase/kong` | `kong/kong` |

Iste logičke komponente (Postgres, GoTrue, PostgREST, Realtime, Storage, Edge,
Studio, …), ali **različit compose i različite slike za neke servise**. Zato
lokal nikad neće biti byte-identičan prod-u — cilj je **funkcionalna parnost**
(iste major verzije app-facing servisa + identičan schema/RLS/edge code).

**Schema i edge funkcije SU jedini izvor istine i identične su na oba mjesta**
(`supabase/migrations/`, `supabase/functions/`). Divergira samo orkestracija i
verzije runtime slika.

## 2. Coolify update model (što se zapravo događa)

Prod compose je **snapshot** koji je Coolify spremio pri kreiranju servisa.
Coolify **ne prati** `supabase/supabase` GitHub repo i **ne auto-bumpa** verzije.

Akcije u Coolifyju i što stvarno rade:

| Akcija | Što radi | Mijenja verziju? |
|---|---|---|
| **Restart** | restart kontejnera, iste slike | ❌ |
| **Redeploy** | recreate kontejnera iz postojećeg compose-a | ❌ (isti tagovi) |
| **Advanced → Pull Latest Images & Restart** | re-pulla digeste **trenutnih (pinanih) tagova** + recreate | ❌ uz pinane tagove* |
| **Edit compose → bump image tagova → Redeploy** | povuče NOVE verzije | ✅ **ovo je upgrade** |

\* Da su tagovi `:latest`/moving, "Pull Latest" bi povukao novije — zato se
tagovi DRŽE pinani (npr. `gotrue:v2.186.0`, ne `gotrue:latest`).

**⚠️ NE update-aj ručnim `docker` komandama preko SSH-a.** Coolify managea taj
compose i prepisat će ručne izmjene na sljedećem deployu. SSH koristi samo za
**inspekciju** (`docker ps`, logovi) i **backup**. Sve izmjene idu **kroz Coolify UI**.

## 3. Lokal kao canary (zašto je lokal ispred prod-a OK)

`brew upgrade supabase` uvijek daje najnoviji CLI → najnovije bundlane slike →
lokal pretekne prod. To je **namjerno**: lokal je staging za sljedeći prod bump.

Pravila:
1. **App E2E mora proći lokalno** (na novim verzijama) prije nego bumpaš prod.
2. **Nikad ne shipaj app kod koji ovisi o feature-u kojeg prod još nema.** App
   cilja prod paritet; lokal smije biti ispred samo radi testiranja.
3. Ako želiš striktno "lokal ≤ prod" umjesto canary-modela: `brew pin supabase`
   na verziju čiji bundle matcha prod (žrtvuješ fleksibilnost).

Provjera drifta u bilo kojem trenutku:
```bash
scripts/supabase-versions.sh           # ispiši prod vs lokal usporedbu
scripts/supabase-versions.sh --write    # + osvježi docs/supabase-versions.md
```

## 4. Siguran PROD upgrade — postupak

Supabaseov self-host guideline: povuci najnoviji `docker-compose.yml` +
`.env.example` s [`github.com/supabase/supabase/tree/master/docker`](https://github.com/supabase/supabase/tree/master/docker),
**reconciliraj nove/preimenovane env varijable**, pa `docker compose pull && up -d`.
Na Coolifyju to radiš kroz compose editor servisa.

> Napomena: **supabase.com** (managed, tisuće tenanta) NE radi compose-bump —
> imaju upravljanu platformu s rolling per-service upgradeom, eksplicitnim
> Postgres upgrade flowom (pause → `pg_upgrade` → resume) i read-replicama.
> Self-host tu automatiku NE dobiva → radimo ručno, po pravilima ispod.

### Checklist (po rastućem riziku)
1. **Testiraj na lokalu prvo** — `brew upgrade supabase` → `scripts/dev-local.sh restart`
   → migracije + app E2E zeleno.
2. **Backup prod DB** — `scripts/db-dump.sh --data` + provjeri Coolify backup.
3. **Bumpaj po grupama, ne sve odjednom:**
   - **Stateless prvo:** kong, studio, meta, vector, imgproxy (lako rollback).
   - **App-facing:** gotrue, postgrest, storage, realtime — backward-compat
     **unutar istog major-a** je siguran; **major skok** (npr. postgrest v12→v14)
     traži čitanje breaking changes + lokalni test.
   - **Postgres ZADNJI i najopreznije.**
4. **Reconciliraj env** — usporedi s aktualnim `.env.example` iz supabase/docker
   repo-a kroz `scripts/build-coolify-env.sh` (nove verzije znaju dodati/preimenovati
   varijable); paste u Coolify.
5. **Edit compose tagove u Coolifyju → Redeploy.**
6. **Verificiraj** — `scripts/supabase-versions.sh --write` (potvrdi poravnanje) +
   smoke test (`api.domovina.ai/auth/v1/health`, login flow) + commit doc.

### Postgres major upgrade (poseban slučaj)
Major (npr. 15 → 16/17) NIJE in-place. Put: `pg_dump` → nova major slika → restore
(ili Supabaseov `pg_upgrade` alat). Coolify to **ne automatizira**. Trenutno su
lokal i prod oba **15.x** (samo patch razlika) → bezopasno; major odgodi dok ne
odradiš dump/restore rehearsal.

## 5. Staging environment — preporuka

**Da, preporučljiv je zaseban Coolify staging Supabase service** za upgrade
rehearsale, jer lokalni CLI canary NE pokriva Coolify-specifične rizike:
različit compose (`kong/kong`, supavisor, minio), env reconciliaciju, Traefik/CF
Tunnel ingress, te stvarni prod image-set.

Model:
```
lokal CLI (canary)         → uhvati schema/RLS/fn/API regresije
  ↓ zeleno
Coolify STAGING service    → uhvati compose/env/ingress regresije na PRAVOJ orkestraciji
  (api-staging.domovina.ai, zasebna DB, reprezentativni podaci)
  ↓ zeleno
Coolify PROD service       → bumpaj iste tagove, redeploy
```

Trade-offi za solo-dev (Oracle VM dom-001):
- **+** Hvata baš ono što lokal ne može; rehearsal za rizične bumpove (Postgres
  major, gateway major) i za env renaming.
- **−** Drugi pun ~14-container stack troši resurse iste VM-e; dvostruki env/DB.
- **Pragmatično:** ne mora raditi 24/7 — **podigni staging samo za upgrade
  rehearsal**, sruši nakon. Za rutinske same-major patcheve lokal canary + backup
  + grupni bump često je dovoljno; staging čuvaj za major/rizične skokove.

## Povezano
- [`supabase-versions.md`](supabase-versions.md) — živi snapshot tagova (auto-gen)
- [`deployment-runbook.md`](deployment-runbook.md) — deploy stage
- `scripts/supabase-versions.sh` — fetch/usporedba verzija
- `scripts/dev-local.sh` — lokalni stack restart s ispravnim env-om
- `scripts/build-coolify-env.sh` — env merge za Coolify
- `scripts/db-dump.sh` / `db-migrate.sh` — backup + migracije (SSH)
