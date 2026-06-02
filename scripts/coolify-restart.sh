#!/usr/bin/env bash
# Restart Supabase service na Coolifyju.
#
# Usage:
#   ./scripts/coolify-restart.sh                   # restart cijeli stack (Coolify API)
#   ./scripts/coolify-restart.sh supabase-rest     # restart samo jedan subservice (docker via SSH)
#   ./scripts/coolify-restart.sh supabase-auth --recreate   # recreate jednog servisa (pokupi novi env!)
#   ./scripts/coolify-restart.sh -y                # bez confirmation
#
# Stack restart kroz Coolify API → preserva state, izvršava se serijski po subservice-u.
# Subservice restart kroz docker (via SSH) → samo bounce jednog containera.
#
# VAŽNO: `docker restart` ponovno koristi STARI env (env se injecta pri KREIRANJU
# containera). Za primjenu env-promjene na JEDNOM servisu (npr. GOTRUE_* za
# supabase-auth) koristi `--recreate`: force-recreate kroz docker compose ponovno
# pročita host .env (Coolify ga upiše odmah na env-set) → ~5s downtime samo tog
# servisa, ostatak stacka netaknut. Bez `--recreate`, full-stack restart je jedini
# način da Coolify re-injecta env svugdje (sporo, ruši sve).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTO_YES=false
RECREATE=false
SUBSERVICE=""
for arg in "$@"; do
  case "$arg" in
    -y|--yes) AUTO_YES=true ;;
    --recreate) RECREATE=true ;;
    --*) echo "Unknown flag: $arg" >&2; exit 2 ;;
    *) SUBSERVICE="$arg" ;;
  esac
done

if $RECREATE && [ -z "$SUBSERVICE" ]; then
  echo "❌ --recreate zahtijeva ime subservice-a (npr. supabase-auth)." >&2
  exit 2
fi

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

  if $RECREATE; then
    # Force-recreate ONLY this compose service so it re-reads the host .env
    # (Coolify writes env changes there immediately). Derives the compose
    # project / config file / service from the running container's labels —
    # no hardcoded UUID. Needs sudo: the compose file + .env are root-owned.
    LABELS=$(ssh_remote "docker inspect $CONTAINER --format '{{index .Config.Labels \"com.docker.compose.project\"}}|{{index .Config.Labels \"com.docker.compose.project.config_files\"}}|{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}|{{index .Config.Labels \"com.docker.compose.service\"}}'")
    PROJECT=$(echo "$LABELS" | cut -d'|' -f1)
    CONFIG=$(echo "$LABELS"  | cut -d'|' -f2)
    WORKDIR=$(echo "$LABELS" | cut -d'|' -f3)
    SERVICE=$(echo "$LABELS" | cut -d'|' -f4)
    if [ -z "$PROJECT" ] || [ -z "$CONFIG" ] || [ -z "$SERVICE" ]; then
      echo "❌ Ne mogu pročitati compose labele s $CONTAINER (project/config/service)." >&2
      exit 1
    fi
    echo "→ Recreate compose service: $SERVICE (project $PROJECT)"
    echo "  ↳ picks up new env from $WORKDIR/.env; --no-deps ne dira db/ovisnosti"
    if ! $AUTO_YES; then
      read -rp "Confirm? [y/N] " ans
      [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
    fi
    ssh_remote "sudo docker compose -p '$PROJECT' -f '$CONFIG' --project-directory '$WORKDIR' up -d --no-deps --force-recreate '$SERVICE'"
    echo "✅ $SERVICE recreated (new env applied)"
  else
    echo "→ Restart subservice: $CONTAINER"
    echo "  ⚠️  plain restart NE primjenjuje env-promjene — za to koristi --recreate"
    if ! $AUTO_YES; then
      read -rp "Confirm? [y/N] " ans
      [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
    fi
    ssh_remote "docker restart $CONTAINER"
    echo "✅ $CONTAINER restarted"
  fi
else
  # ----- Full stack restart kroz Coolify API -----------------------------
  # shellcheck source=lib/coolify-api.sh
  . "$SCRIPT_DIR/lib/coolify-api.sh"

  echo "→ Service: $COOLIFY_SERVICE_UUID"
  echo "→ Action:  Stop → Start (re-deploy s aktuelnim env-om iz Coolify DB)"
  echo "ℹ️  Coolify v4 /restart endpoint samo STOPa containere; treba /start za redeploy."

  if ! $AUTO_YES; then
    read -rp "Confirm? [y/N] " ans
    [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
  fi

  # 1. Stop
  echo "→ POST /restart (stop) ..."
  RESP=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/restart" 2>/tmp/_code)
  CODE=$(cat /tmp/_code); rm -f /tmp/_code
  case "$CODE" in
    200|201|202|204) echo "   queued" ;;
    *)
      echo "❌ stop failed: HTTP $CODE" >&2
      echo "$RESP" | head -5 >&2
      exit 1
      ;;
  esac

  # 2. Wait for containers to actually stop (max 45s)
  echo "→ Waiting for stop to complete..."
  for i in $(seq 1 9); do
    sleep 5
    LIVE=$(ssh_remote "docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^supabase-(kong|rest|auth|db)-' | wc -l" 2>/dev/null || echo 4)
    if [ "$LIVE" = "0" ]; then break; fi
  done

  # 3. Start (re-deploy s novim env)
  echo "→ POST /start (re-deploy) ..."
  RESP=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/start" 2>/tmp/_code)
  CODE=$(cat /tmp/_code); rm -f /tmp/_code
  case "$CODE" in
    200|201|202|204) echo "✅ Re-deploy queued (~2-3 min)." ;;
    *)
      echo "❌ start failed: HTTP $CODE" >&2
      echo "$RESP" | head -5 >&2
      exit 1
      ;;
  esac
fi
