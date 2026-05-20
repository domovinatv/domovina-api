#!/usr/bin/env bash
# scripts/lib/coolify-api.sh
#
# Source-ano iz coolify-*.sh skripti. Coolify v4 REST API (Bearer auth).
#
# Required env (iz .local-secrets.env):
#   COOLIFY_API_URL        — npr. https://app.domovina.link (bez trailing /)
#   COOLIFY_API_TOKEN      — Bearer token (Keys & Tokens → API Tokens)
#   COOLIFY_SERVICE_UUID   — UUID Supabase service-a (iz URL-a)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/.local-secrets.env}"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "❌ $SECRETS_FILE ne postoji. cp .local-secrets.env.example .local-secrets.env i popuni." >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
. "$SECRETS_FILE"
set +a

: "${COOLIFY_API_URL:?Treba COOLIFY_API_URL u .local-secrets.env}"
: "${COOLIFY_API_TOKEN:?Treba COOLIFY_API_TOKEN u .local-secrets.env}"
: "${COOLIFY_SERVICE_UUID:?Treba COOLIFY_SERVICE_UUID u .local-secrets.env}"

# Trim trailing slash s URL-a
COOLIFY_API_URL="${COOLIFY_API_URL%/}"
COOLIFY_API_BASE="$COOLIFY_API_URL/api/v1"

if ! command -v jq >/dev/null; then
  echo "❌ jq nije instaliran. brew install jq" >&2
  exit 1
fi

# ----- helpers ---------------------------------------------------------------

# Wrapper za curl: setira Bearer auth + Accept JSON, vraća (HTTP_CODE, body)
# Usage: coolify_curl GET /services/uuid
#        coolify_curl PATCH /services/uuid/envs/FOO --data '{...}'
coolify_curl() {
  local method=$1 path=$2; shift 2
  local url="$COOLIFY_API_BASE$path"
  local tmp
  tmp=$(mktemp)
  local code
  code=$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X "$method" \
    -H "Authorization: Bearer $COOLIFY_API_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    "$@" \
    "$url" || echo "000")
  # output: HTTP code na stderr, body na stdout
  echo "$code" >&2
  cat "$tmp"
  rm -f "$tmp"
}

# Check da API odgovara (jednom u status skripti)
coolify_health() {
  local code body
  body=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID" 2>/tmp/_coolify_code) || true
  code=$(cat /tmp/_coolify_code)
  rm -f /tmp/_coolify_code
  if [ "$code" = "200" ]; then
    return 0
  elif [ "$code" = "401" ]; then
    echo "❌ 401 Unauthorized — token nije validan ili nema permissions" >&2
    return 1
  elif [ "$code" = "404" ]; then
    echo "❌ 404 Not Found — service UUID '$COOLIFY_SERVICE_UUID' ne postoji" >&2
    return 1
  else
    echo "❌ HTTP $code — neočekivan response:" >&2
    echo "$body" | head -20 >&2
    return 1
  fi
}

export REPO_ROOT COOLIFY_API_BASE
export -f coolify_curl coolify_health
