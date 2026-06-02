#!/usr/bin/env bash
# Postavi (create or update) env var u Coolify service-u.
#
# Usage:
#   ./scripts/coolify-env-set.sh KEY=VALUE
#   ./scripts/coolify-env-set.sh KEY=VALUE -y          # bez confirmation prompta
#   ./scripts/coolify-env-set.sh KEY=VALUE --restart   # auto-restart full stack nakon
#   ./scripts/coolify-env-set.sh GOTRUE_X=Y --recreate-service=supabase-auth
#                                                      # recreate SAMO tog servisa (preporučeno za
#                                                      # single-service env, npr. GOTRUE_*) → ~5s,
#                                                      # ne ruši cijeli stack
#
# Napomena: nakon promjene env-a, Coolify NE restart-a containere automatski.
# `--restart` = full-stack (sve gore ~2-3 min); `--recreate-service` = samo jedan
# container pokupi novi env (~5s). Koristi --restart samo kad promjena dira više
# servisa; inače --recreate-service.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/coolify-api.sh
. "$SCRIPT_DIR/lib/coolify-api.sh"

AUTO_YES=false
RESTART_AFTER=false
RECREATE_SERVICE=""
KV=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=true ;;
    --restart) RESTART_AFTER=true ;;
    --recreate-service=*) RECREATE_SERVICE="${arg#*=}" ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *) KV="$arg" ;;
  esac
done

if [ -z "$KV" ] || [[ "$KV" != *=* ]]; then
  echo "Usage: $0 KEY=VALUE [-y] [--restart | --recreate-service=<svc>]" >&2
  exit 2
fi

if $RESTART_AFTER && [ -n "$RECREATE_SERVICE" ]; then
  echo "❌ Koristi ili --restart (full stack) ili --recreate-service=<svc>, ne oboje." >&2
  exit 2
fi

KEY="${KV%%=*}"
VALUE="${KV#*=}"

if [ -z "$KEY" ]; then
  echo "❌ KEY je prazan" >&2; exit 2
fi

# 1. Provjeri postoji li već
ENVS=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/tmp/_code)
CODE=$(cat /tmp/_code); rm -f /tmp/_code
if [ "$CODE" != "200" ]; then
  echo "❌ GET /envs failed: HTTP $CODE" >&2
  echo "$ENVS" | head -5 >&2
  exit 1
fi

CUR=$(echo "$ENVS" | jq -r --arg k "$KEY" '.[] | select(.key == $k) | .value // ""')
EXISTS=$(echo "$ENVS" | jq --arg k "$KEY" 'any(.[]; .key == $k)')

mask() {
  local v=$1 n=${#1}
  if [ -z "$v" ]; then printf '<empty>'
  elif [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s…%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

echo "→ Service: $COOLIFY_SERVICE_UUID"
echo "→ KEY:     $KEY"
if [ "$EXISTS" = "true" ]; then
  echo "→ Action:  UPDATE  ($(mask "$CUR")  →  $(mask "$VALUE"))"
else
  echo "→ Action:  CREATE  ($(mask "$VALUE"))"
fi

if ! $AUTO_YES; then
  read -rp "Confirm? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# 2. Apply
PAYLOAD=$(jq -nc --arg k "$KEY" --arg v "$VALUE" '{key: $k, value: $v}')

if [ "$EXISTS" = "true" ]; then
  # PATCH (update); ako endpoint ne podržava PATCH s body, fallback POST
  RESP=$(coolify_curl PATCH "/services/$COOLIFY_SERVICE_UUID/envs" --data "$PAYLOAD" 2>/tmp/_code)
  CODE=$(cat /tmp/_code); rm -f /tmp/_code
  if [ "$CODE" = "405" ] || [ "$CODE" = "404" ]; then
    # fallback: POST (Coolify upsert)
    RESP=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/envs" --data "$PAYLOAD" 2>/tmp/_code)
    CODE=$(cat /tmp/_code); rm -f /tmp/_code
  fi
else
  RESP=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/envs" --data "$PAYLOAD" 2>/tmp/_code)
  CODE=$(cat /tmp/_code); rm -f /tmp/_code
fi

case "$CODE" in
  200|201|204) echo "✅ $KEY postavljeno." ;;
  *)
    echo "❌ HTTP $CODE" >&2
    echo "$RESP" | head -10 >&2
    exit 1
    ;;
esac

if [ -n "$RECREATE_SERVICE" ]; then
  echo ""
  echo "→ Recreate service $RECREATE_SERVICE (pokupi novi env, bez rušenja stacka)..."
  exec "$SCRIPT_DIR/coolify-restart.sh" "$RECREATE_SERVICE" --recreate -y
fi

if $RESTART_AFTER; then
  echo ""
  echo "→ Restart stack..."
  exec "$SCRIPT_DIR/coolify-restart.sh" -y
fi
