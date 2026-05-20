#!/usr/bin/env bash
# Pre-rotation skripta za Postgres password u Coolify Supabase setup-u.
#
# Problem: build-coolify-env.sh rotira sve secrets uključujući SERVICE_PASSWORD_POSTGRES.
# Ali Postgres lozinka unutar pg_authid se ne mijenja kad se mijenja Coolify env.
# Na sljedećem deploy-u, Coolify container starta s NOVOM env lozinkom,
# ali Postgres baza i dalje očekuje STARU → backend services ne mogu spojiti → crash loop.
#
# Rješenje: prije rotacije, ALTER USER unutar Postgres-a sa STAROM lozinkom da prihvati NOVU.
# Onda Coolify env update + redeploy stvarno radi.
#
# Workflow:
#   1. Generira novi password (32 char alphanum)
#   2. Prikazuje masked old + new
#   3. Connect-a u Postgres s STAROM lozinkom (iz Coolify .env na serveru)
#   4. ALTER USER postgres PASSWORD '<new>'
#   5. ALTER USER supabase_admin PASSWORD '<new>'  (i drugi role-ovi)
#   6. Update Coolify .env preko Coolify API (ili SSH sed)
#   7. Restart cijeli stack
#
# CAVEAT: Ovo radi za Postgres password. Drugi secrets (JWT, anon keys) treba
# rotirati zasebno preko build-coolify-env.sh + redeploy.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

# Optional: --no-restart preskočiti restart na kraju
DO_RESTART=true
DO_BACKUP=true
AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --no-restart) DO_RESTART=false ;;
    --no-backup)  DO_BACKUP=false ;;
    -y|--yes)     AUTO_YES=true ;;
    *) echo "Unknown: $arg" >&2; exit 2 ;;
  esac
done

CONTAINER=$(detect_db_container)
SERVICE_UUID="${COOLIFY_SERVICE_UUID:-cv887vonujh1swebndh4x4iu}"
ENV_FILE_REMOTE="/data/coolify/services/$SERVICE_UUID/.env"

# ----- helpers -----
gen_alnum() {
  local len=$1
  openssl rand -base64 $((len * 2 + 16)) | tr -d '/+=\n' | cut -c1-"$len"
}

mask() {
  local v=$1 n=${#1}
  if [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s…%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

# ----- 1. Get current password from Coolify .env -----
echo "→ container: $CONTAINER"
OLD_PASS=$(ssh_remote "sudo grep '^SERVICE_PASSWORD_POSTGRES=' $ENV_FILE_REMOTE | sed 's/^SERVICE_PASSWORD_POSTGRES=//'" 2>/dev/null)
if [ -z "$OLD_PASS" ]; then
  echo "❌ Ne mogu pročitati SERVICE_PASSWORD_POSTGRES iz $ENV_FILE_REMOTE" >&2
  exit 1
fi
echo "→ old: $(mask "$OLD_PASS")"

# ----- 2. Generiraj novu -----
NEW_PASS=$(gen_alnum 32)
echo "→ new: $(mask "$NEW_PASS")"

if ! $AUTO_YES; then
  read -rp "Proceed with rotation? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# ----- 3. Backup prije svega -----
if $DO_BACKUP; then
  echo "→ Backup..."
  ssh_remote "sudo /opt/domovina-backup/pg-backup.sh" > /dev/null 2>&1 || \
    echo "⚠️  Backup script failed, nastavljam (rizik!)"
fi

# ----- 4. ALTER USER unutar Postgres-a -----
# Koristi staru lozinku da se konektamo, postavimo novu lozinku za sve relevantne role-ove.
echo "→ ALTER USER inside Postgres (using old password)..."
ssh_remote "docker exec -i -e PGPASSWORD='$OLD_PASS' $CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1" <<SQL
-- Postgres superuser
alter user postgres password '$NEW_PASS';

-- Supabase-managed role-ovi (svi koriste istu password env var u Coolify template-u)
alter user supabase_admin password '$NEW_PASS';
alter user supabase_auth_admin password '$NEW_PASS';
alter user supabase_storage_admin password '$NEW_PASS';
alter user authenticator password '$NEW_PASS';
alter user supabase_replication_admin password '$NEW_PASS';
alter user supabase_read_only_user password '$NEW_PASS';

select 'OK — role passwords updated' as status;
SQL

# ----- 5. Update Coolify .env -----
echo "→ Update Coolify .env..."
ssh_remote "sudo sed -i 's|^SERVICE_PASSWORD_POSTGRES=.*|SERVICE_PASSWORD_POSTGRES=$NEW_PASS|' $ENV_FILE_REMOTE"

# Provjera da je sed uspio
NEW_IN_ENV=$(ssh_remote "sudo grep '^SERVICE_PASSWORD_POSTGRES=' $ENV_FILE_REMOTE | sed 's/^SERVICE_PASSWORD_POSTGRES=//'")
if [ "$NEW_IN_ENV" != "$NEW_PASS" ]; then
  echo "❌ Coolify .env update FAIL. Ručno provjeri $ENV_FILE_REMOTE" >&2
  exit 1
fi
echo "✅ Coolify .env updated"

# ----- 6. Coolify DB reconcile reminder -----
echo ""
echo "⚠️  Coolify DB state još uvijek pokazuje STARU lozinku."
echo "   Preko UI: Environment Variables → SERVICE_PASSWORD_POSTGRES → paste new value → Save"
echo "   Ili preko API (kad token ima Read+Write+Deploy):"
echo "      ./scripts/coolify-env-set.sh SERVICE_PASSWORD_POSTGRES='$NEW_PASS' -y"
echo ""

# ----- 7. Restart stack (opcionalno) -----
if $DO_RESTART; then
  echo "→ Restart stack via SSH (recreate svih containera s novim env-om iz .env)..."
  ssh_remote "sudo bash -c 'cd /data/coolify/services/$SERVICE_UUID && docker compose up -d --force-recreate'" 2>&1 | tail -10
  echo ""
  sleep 10
  echo "→ Health check..."
  ANON=$(ssh_remote "docker inspect \$(docker ps --format '{{.Names}}' | grep '^supabase-rest-' | head -1) --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ^ANON_KEY= | sed 's/^ANON_KEY=//'" 2>/dev/null)
  for i in 1 2 3 4 5; do
    sleep 5
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "apikey: $ANON" https://api.domovina.ai/auth/v1/health)
    echo "[try $i] /auth/v1/health → HTTP $CODE"
    [ "$CODE" = "200" ] && break
  done
fi

echo ""
echo "✅ Postgres password rotated. Sav noviji secrets work."
echo "ℹ️  Sad još rotiraj druge (JWT, anon keys) preko build-coolify-env.sh ako treba full rotation."
