#!/usr/bin/env bash
# Sanity check: hit Coolify API, dohvati service info.
# Usage: ./scripts/coolify-status.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/coolify-api.sh
. "$SCRIPT_DIR/lib/coolify-api.sh"

echo "→ API:     $COOLIFY_API_BASE"
echo "→ Service: $COOLIFY_SERVICE_UUID"
echo ""

# 1. Service detail
SVC=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID" 2>/tmp/_code)
CODE=$(cat /tmp/_code); rm -f /tmp/_code

if [ "$CODE" != "200" ]; then
  echo "❌ HTTP $CODE" >&2
  echo "$SVC" | head -10 >&2
  echo ""
  echo "Provjeri:" >&2
  echo "  1. COOLIFY_API_TOKEN je validan (regeneriraj na $COOLIFY_API_URL/security/api-tokens)" >&2
  echo "  2. Token ima Read+Write permissions" >&2
  echo "  3. COOLIFY_SERVICE_UUID je iz /service/<UUID> dijela URL-a" >&2
  exit 1
fi

echo "✅ Connected. Service:"
echo "$SVC" | jq -r '
  "  name:        " + (.name // "?"),
  "  status:      " + (.status // "?"),
  "  fqdn:        " + (.fqdn // "n/a"),
  "  project:     " + (.project.name // .project_uuid // "?"),
  "  environment: " + (.environment.name // .environment_uuid // "?"),
  "  destination: " + (.destination.name // "?")
' 2>/dev/null || {
  # Fallback ako su polja drugačija
  echo "$SVC" | jq -r 'keys | "  fields: " + join(", ")'
}

echo ""

# 2. Env vars count
ENVS=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/tmp/_code)
CODE=$(cat /tmp/_code); rm -f /tmp/_code

if [ "$CODE" = "200" ]; then
  COUNT=$(echo "$ENVS" | jq 'length // 0')
  echo "→ Env vars: $COUNT entries"
elif [ "$CODE" = "404" ]; then
  echo "ℹ️  /envs endpoint vraća 404 — možda druga path struktura. Pokušaj coolify-env-get.sh za debug."
else
  echo "⚠️  HTTP $CODE za /envs"
fi
