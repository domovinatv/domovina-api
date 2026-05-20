#!/usr/bin/env bash
# healthcheck.sh — runs as root via cron every 5 min.
# Layer 2 monitoring (fallback ako Uptime Kuma padne).
#
# Što provjerava:
#   - /auth/v1/health (Kong → GoTrue, traži "GoTrue" u body)
#   - /rest/v1/        (Kong → PostgREST, traži "swagger" ili 200)
#   - Postgres direktan (pg_isready u containeru)
#   - Disk usage > 85%
#
# Alerts (ako /etc/domovina-alert.env definira TG_BOT_TOKEN + TG_CHAT_ID):
#   - 🔴 na first failure
#   - 🟢 na recovery
#   - Idempotent: jedna alert poruka po stanju (ne spam svakih 5 min)
#
# Bez alert configa: samo logira u /var/log/domovina-healthcheck.log.

set -euo pipefail

LOG=/var/log/domovina-healthcheck.log
STATE_DIR=/var/lib/domovina-healthcheck
mkdir -p "$STATE_DIR"

# Load alert config if present
if [ -f /etc/domovina-alert.env ]; then
  # shellcheck source=/dev/null
  source /etc/domovina-alert.env
fi

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" >> "$LOG"
}

notify() {
  local msg=$1
  log "$msg"
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -s -m 10 -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      --data-urlencode "chat_id=$TG_CHAT_ID" \
      --data-urlencode "text=$msg" \
      --data-urlencode "parse_mode=Markdown" > /dev/null || true
  fi
}

# ----- ANON_KEY iz REST containera -----
ANON=$(docker inspect "$(docker ps --format '{{.Names}}' | grep '^supabase-rest-' | head -1)" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | grep ^ANON_KEY= | sed 's/^ANON_KEY=//' || echo "")

# ----- Check functions -----
check_auth() {
  local body
  body=$(curl -s -m 10 -H "apikey: $ANON" "https://api.domovina.ai/auth/v1/health" 2>/dev/null || echo "")
  echo "$body" | grep -q "GoTrue" && return 0 || return 1
}

check_rest() {
  local code
  code=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -H "apikey: $ANON" "https://api.domovina.ai/rest/v1/" 2>/dev/null)
  [ "$code" = "200" ] && return 0 || return 1
}

check_db() {
  local container
  container=$(docker ps --format '{{.Names}}' | grep '^supabase-db-' | head -1)
  [ -n "$container" ] && docker exec "$container" pg_isready -U postgres -q && return 0 || return 1
}

check_disk() {
  local pct
  pct=$(df / | awk 'NR==2 {gsub("%",""); print $5}')
  [ "$pct" -lt 85 ] && return 0 || return 1
}

# ----- Run checks -----
ISSUES=()
check_auth || ISSUES+=("auth")
check_rest || ISSUES+=("rest")
check_db   || ISSUES+=("db")
check_disk || ISSUES+=("disk-over-85%")

# ----- State + alert dedup -----
STATE_FILE="$STATE_DIR/state"
PREV_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "ok")
CUR_STATE="ok"
[ ${#ISSUES[@]} -gt 0 ] && CUR_STATE="fail:$(IFS=,; echo "${ISSUES[*]}")"

if [ "$CUR_STATE" != "$PREV_STATE" ]; then
  if [ "$CUR_STATE" = "ok" ]; then
    notify "🟢 *Domovina API* recovered (prev: $PREV_STATE)"
  else
    notify "🔴 *Domovina API* DOWN: ${ISSUES[*]}"
  fi
  echo "$CUR_STATE" > "$STATE_FILE"
fi

log "$CUR_STATE"
