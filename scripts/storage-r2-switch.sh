#!/usr/bin/env bash
# Prebaci Supabase storage backend s lokalnog MinIO na Cloudflare R2.
#
#   ./scripts/storage-r2-switch.sh --dry-run                      # pokaži diff, ništa ne diraj
#   ./scripts/storage-r2-switch.sh <R2_ACCESS_KEY> <R2_SECRET>    # primijeni + restart storagea
#
# Što radi:
#   1. živo: prepravi supabase-storage environment u generiranom
#      /data/coolify/services/<UUID>/docker-compose.yml na serveru pa
#      `docker compose up -d supabase-storage` (recreira SAMO storage container)
#   2. trajno: isti patch u coolify DB (services.docker_compose_raw) — preživi
#      buduće Coolify redeploye cijelog stacka
#   3. verifikacija: javni objekt (pinka-covers) mora vratiti 200 image/png
#
# R2: bucket domovina-storage (account D.O.M. 7dc7167b…, custom domena
# s.domovina.ai), endpoint account-level S3. Postojeći objekti su migrirani
# wranglerom (key layout: storage-single-tenant/<bucket>/<name>/<version>).
# Rollback: backup composea ostaje u backups/ — vrati ga i ponovi korake 1–2.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

SERVICE_UUID_PATH="cv887vonujh1swebndh4x4iu"
COMPOSE_PATH="/data/coolify/services/$SERVICE_UUID_PATH/docker-compose.yml"
R2_ENDPOINT="https://7dc7167b7e2e00923bfa7cd697df14e4.r2.cloudflarestorage.com"
R2_BUCKET="domovina-storage"
VERIFY_URL="https://api.domovina.ai/storage/v1/object/public/pinka-covers/13e991a8-b762-43ff-8f49-160ea4da1556/28a69cc0-9238-4506-88c8-0a8850ffeca2.png"

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=true
  R2_KEY="DRY_RUN_KEY"
  R2_SECRET="DRY_RUN_SECRET"
else
  R2_KEY="${1:?usage: storage-r2-switch.sh <R2_ACCESS_KEY> <R2_SECRET> | --dry-run}"
  R2_SECRET="${2:?usage: storage-r2-switch.sh <R2_ACCESS_KEY> <R2_SECRET> | --dry-run}"
fi

# Python edit: mijenja SAMO services.supabase-storage.environment ključeve;
# radi i nad generiranim composeom i nad raw templateom iz coolify DB-a.
# (python skripta u temp fajlu — heredoc bi pojeo yaml sa stdina)
PATCH_PY="$(mktemp /tmp/patch-compose-XXXXXX.py)"
trap 'rm -f "$PATCH_PY"' EXIT
cat > "$PATCH_PY" <<'PYEOF'
import sys, yaml

path, endpoint, bucket, key, secret = sys.argv[1:6]
with open(path) as f:
    doc = yaml.safe_load(f)
env = doc["services"]["supabase-storage"]["environment"]
changes = {
    "STORAGE_S3_ENDPOINT": endpoint,
    "STORAGE_S3_BUCKET": bucket,
    "STORAGE_S3_REGION": "auto",
    "AWS_ACCESS_KEY_ID": key,
    "AWS_SECRET_ACCESS_KEY": secret,
}
if isinstance(env, dict):
    env.update(changes)
elif isinstance(env, list):  # raw template: '- KEY=value' forma
    keys = set(changes)
    env = [e for e in env if str(e).split("=", 1)[0] not in keys]
    env += [f"{k}={v}" for k, v in changes.items()]
    doc["services"]["supabase-storage"]["environment"] = env
else:
    raise SystemExit(f"neočekivan tip environmenta: {type(env)}")
# default_style=None čuva ${VAR} stringove kakvi jesu (compose ih interpolira)
yaml.safe_dump(doc, sys.stdout, default_flow_style=False, sort_keys=False, width=4096)
PYEOF
patch_compose() { # $1: yaml path, stdout: patched yaml
  python3 "$PATCH_PY" "$1" "$R2_ENDPOINT" "$R2_BUCKET" "$R2_KEY" "$R2_SECRET"
}

TS=$(date +%Y%m%d%H%M%S)
mkdir -p "$REPO_ROOT/backups"

echo "→ dohvaćam živi compose sa servera" >&2
ssh_remote "sudo cat $COMPOSE_PATH 2>/dev/null || cat $COMPOSE_PATH" > "/tmp/compose-live-$TS.yml"
cp "/tmp/compose-live-$TS.yml" "$REPO_ROOT/backups/compose-live-pre-r2-$TS.yml"

echo "→ dohvaćam docker_compose_raw iz coolify DB" >&2
ssh_remote "docker exec coolify-db psql -U coolify -d coolify -tA -c \"select encode(convert_to(docker_compose_raw,'UTF8'),'base64') from services where uuid='$SERVICE_UUID_PATH'\"" \
  | tr -d '\n' | base64 -d > "/tmp/compose-raw-$TS.yml"
cp "/tmp/compose-raw-$TS.yml" "$REPO_ROOT/backups/compose-raw-pre-r2-$TS.yml"

patch_compose "/tmp/compose-live-$TS.yml" > "/tmp/compose-live-patched-$TS.yml"
patch_compose "/tmp/compose-raw-$TS.yml"  > "/tmp/compose-raw-patched-$TS.yml"

echo "→ diff (živi compose, samo storage env):" >&2
diff <(grep -A40 "supabase-storage:" "/tmp/compose-live-$TS.yml" | grep -E "STORAGE_S3|AWS_") \
     <(grep -A60 "supabase-storage:" "/tmp/compose-live-patched-$TS.yml" | grep -E "STORAGE_S3|AWS_") \
  | sed -E 's/(KEY.*[:=] ).{6}.*/\1<skriveno>/' || true

if $DRY_RUN; then
  echo "(dry-run, ništa nije primijenjeno)" >&2
  exit 0
fi

echo "→ upload patched composea + recreate samo supabase-storage" >&2
B64_LIVE=$(base64 < "/tmp/compose-live-patched-$TS.yml" | tr -d '\n')
# --project-directory: ssh user ne smije cd-ati u root-owned dir; compose tako
# svejedno pokupi .env iz service dira i ostane u istom compose projektu
ssh_remote "echo $B64_LIVE | base64 -d | sudo tee $COMPOSE_PATH >/dev/null && sudo docker compose --project-directory /data/coolify/services/$SERVICE_UUID_PATH -f $COMPOSE_PATH up -d supabase-storage"

echo "→ trajni patch u coolify DB" >&2
B64_RAW=$(base64 < "/tmp/compose-raw-patched-$TS.yml" | tr -d '\n')
ssh_remote "docker exec coolify-db psql -U coolify -d coolify -c \"update services set docker_compose_raw = convert_from(decode('$B64_RAW','base64'),'UTF8') where uuid='$SERVICE_UUID_PATH'\""

echo "→ čekam health storagea pa verificiram javni objekt" >&2
sleep 8
for i in 1 2 3 4 5; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$VERIFY_URL")
  [ "$CODE" = "200" ] && break
  sleep 5
done
echo "verify: HTTP $CODE ($VERIFY_URL)"
[ "$CODE" = "200" ] && echo "✅ storage servira s R2 backenda" || {
  echo "❌ objekt nije dostupan — rollback: vrati backups/compose-live-pre-r2-$TS.yml pa docker compose up -d supabase-storage"
  exit 1
}
