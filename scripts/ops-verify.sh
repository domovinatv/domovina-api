#!/usr/bin/env bash
# ops-verify.sh
#
# One-shot "je li sve živo" provjera nakon env/restart/deploy promjene.
# Čisto read-only. Ne treba Coolify API token — radi preko SSH + javnih
# HTTP probe-ova. (Coolify service status posebno: ./scripts/coolify-status.sh.)
#
# Provjere:
#   1. supabase-* containeri svi "Up"
#   2. GoTrue health         GET  /auth/v1/health                 → 200
#   3. PostgREST domovina_ai GET  /rest/v1/watch_progress         → 200 (ne PGRST106)
#   4. edge handoff-consume  POST /functions/v1/handoff-consume   → 401 (deployed+gated)
#   5. edge certilia         POST /functions/v1/certilia          → 400 (missing_id_token)
#   6. edge passkey          OPTIONS /functions/v1/passkey        → 200 (deployed)
#
# Anon key se čita iz containera NA HOSTU (curl se izvršava remote) → ključ se
# nikad ne ispisuje lokalno. Output su samo HTTP statusi.
#
# Exit: 0 ako sve PASS, 1 ako bilo što FAIL.
#
# Usage:
#   ./scripts/ops-verify.sh
#   OPS_BASE_URL=https://api.domovina.ai ./scripts/ops-verify.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

BASE="${OPS_BASE_URL:-https://api.domovina.ai}"

echo "→ Target: $BASE"
echo "→ Host:   $COOLIFY_SSH_HOST"
echo ""

# Sve probe-ove izvrši u jednoj remote sesiji (anon key ostaje na hostu).
RAW=$(ssh_remote "bash -s" <<REMOTE
set -euo pipefail
EDGE=\$(docker ps --format '{{.Names}}' | grep '^supabase-edge-functions-' | head -1)
ANON=\$(docker exec "\$EDGE" printenv ANON_KEY 2>/dev/null || true)
code(){ curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "\$@" 2>/dev/null || echo 000; }

UP=\$(docker ps --filter name=supabase- --format '{{.Status}}' | grep -c '^Up' || true)
TOTAL=\$(docker ps -a --filter name=supabase- --format '{{.Names}}' | wc -l | tr -d ' ')
echo "CONTAINERS|\$UP/\$TOTAL"

echo "AUTH_HEALTH|\$(code -H "apikey: \$ANON" '$BASE/auth/v1/health')"
echo "REST_domovina_ai|\$(code -H 'Accept-Profile: domovina_ai' -H "apikey: \$ANON" -H "Authorization: Bearer \$ANON" '$BASE/rest/v1/watch_progress?limit=1')"
echo "EDGE_handoff_consume|\$(code -X POST -H "apikey: \$ANON" -H "Authorization: Bearer \$ANON" -H 'Content-Type: application/json' -d '{}' '$BASE/functions/v1/handoff-consume')"
echo "EDGE_certilia|\$(code -X POST -H "apikey: \$ANON" -H "Authorization: Bearer \$ANON" -H 'Content-Type: application/json' -d '{}' '$BASE/functions/v1/certilia')"
echo "EDGE_passkey|\$(code -X OPTIONS -H "apikey: \$ANON" '$BASE/functions/v1/passkey')"
REMOTE
)

# ----- evaluacija ------------------------------------------------------------
fail=0
get() { echo "$RAW" | awk -F'|' -v k="$1" '$1==k{print $2}'; }

row() { # name  expected  actual  pass?
  local name=$1 exp=$2 act=$3 ok=$4
  printf "  %-22s expect=%-8s got=%-8s %s\n" "$name" "$exp" "$act" "$ok"
}

echo "Rezultat:"

# 1. containers
CON=$(get CONTAINERS)
up=${CON%%/*}; tot=${CON##*/}
if [ -n "$tot" ] && [ "$up" = "$tot" ] && [ "$tot" != "0" ]; then
  row "containers Up" "all" "$CON" "✅"
else
  row "containers Up" "all" "$CON" "❌"; fail=$((fail+1))
fi

check() { # name expected actual
  local n=$1 e=$2 a=$3
  if [ "$a" = "$e" ]; then row "$n" "$e" "$a" "✅"; else row "$n" "$e" "$a" "❌"; fail=$((fail+1)); fi
}

check "auth/v1/health"        200 "$(get AUTH_HEALTH)"
check "rest domovina_ai"      200 "$(get REST_domovina_ai)"
check "edge handoff-consume"  401 "$(get EDGE_handoff_consume)"
check "edge certilia"         400 "$(get EDGE_certilia)"
check "edge passkey"          200 "$(get EDGE_passkey)"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "✅ Sve PASS."
else
  echo "❌ $fail provjera nije prošlo."
  echo "   (certilia 400 = OK/deployed; 500/000 = env fali ili nije deployano —"
  echo "    vidi CERTILIA_CLIENT_ID/KYC_ENCRYPTION_KEY u docs/secret-rotation.md / TODO.)"
  exit 1
fi
