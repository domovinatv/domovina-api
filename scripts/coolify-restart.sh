#!/usr/bin/env bash
# Restart Supabase service na Coolifyju.
#
# Usage:
#   ./scripts/coolify-restart.sh                   # restart cijeli stack (Coolify API)
#   ./scripts/coolify-restart.sh supabase-rest     # restart samo jedan subservice (docker via SSH)
#   ./scripts/coolify-restart.sh -y                # bez confirmation
#
# Stack restart kroz Coolify API → preserva state, izvršava se serijski po subservice-u.
# Subservice restart kroz docker (via SSH) → samo bounce jednog containera, ne mijenja config.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTO_YES=false
SUBSERVICE=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=true ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *) SUBSERVICE="$arg" ;;
  esac
done

if [ -n "$SUBSERVICE" ]; then
  # ----- Subservice restart kroz SSH + docker ----------------------------
  # shellcheck source=lib/db-env.sh
  . "$SCRIPT_DIR/lib/db-env.sh"

  # Pronađi container koji počinje sa $SUBSERVICE-
  CONTAINER=$(ssh_remote "docker ps --format '{{.Names}}' | grep '^${SUBSERVICE}-' | head -1")
  if [ -z "$CONTAINER" ]; then
    # Probaj točan match
    CONTAINER=$(ssh_remote "docker ps --format '{{.Names}}' | grep -E '^${SUBSERVICE}(-|$)' | head -1")
  fi
  if [ -z "$CONTAINER" ]; then
    echo "❌ Container ne postoji: ${SUBSERVICE}-*" >&2
    echo "Lista subservices na serveru:" >&2
    ssh_remote "docker ps --format '{{.Names}}' | grep -E 'supabase-|realtime-' | sort" >&2
    exit 1
  fi

  echo "→ Restart subservice: $CONTAINER"
  if ! $AUTO_YES; then
    read -rp "Confirm? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
  fi

  ssh_remote "docker restart $CONTAINER"
  echo "✅ $CONTAINER restarted"
else
  # ----- Full stack restart kroz Coolify API -----------------------------
  # shellcheck source=lib/coolify-api.sh
  . "$SCRIPT_DIR/lib/coolify-api.sh"

  echo "→ Service: $COOLIFY_SERVICE_UUID"
  echo "→ Action:  Full stack restart"

  if ! $AUTO_YES; then
    read -rp "Confirm? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
  fi

  RESP=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/restart" 2>/tmp/_code)
  CODE=$(cat /tmp/_code); rm -f /tmp/_code

  case "$CODE" in
    200|201|202|204) echo "✅ Restart triggered. Coolify radi serijski po containerima (~2 min)." ;;
    *)
      echo "❌ HTTP $CODE" >&2
      echo "$RESP" | head -10 >&2
      exit 1
      ;;
  esac
fi
