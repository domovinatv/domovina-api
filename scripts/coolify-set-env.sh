#!/usr/bin/env bash
# scripts/coolify-set-env.sh
#
# NE-ROTIRAJUĆE dodavanje/izmjena POJEDINAČNIH env varijabli na Coolify Supabase
# servisu preko v4 API-ja. Za razliku od build-coolify-env.sh (koji RE-GENERIRA
# sve secrete → rotacija anon/service/postgres ključeva), ova dira ISKLJUČIVO
# ključeve koje joj zadaš. Ostatak env-a ostaje netaknut.
#
# Default (bez argumenata): upsert 3 youtube-claim varijable (channel ownership).
#   client_id/secret se čitaju iz .local-secrets.env (NE preko argv → ne cure u ps),
#   prod redirect je hardkodiran (https://domovina.ai/youtube-claim/callback).
#
# Uporaba:
#   scripts/coolify-set-env.sh                 # upsert youtube-claim 3 varijable
#   scripts/coolify-set-env.sh KEY=VAL [KEY=VAL ...]   # upsert proizvoljne
#   scripts/coolify-set-env.sh --deploy [...]   # nakon upserta okini Redeploy
#
# Napomena: env izmjene zahtijevaju REDEPLOY (ne restart) da se primijene —
# vidi memory feedback-coolify-ops. Pokreni s --deploy ili ručno u Coolify UI.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/coolify-api.sh"

DEPLOY=false
PAIRS=()
for arg in "$@"; do
  case "$arg" in
    --deploy) DEPLOY=true ;;
    *=*) PAIRS+=("$arg") ;;
    *) echo "Nepoznat argument: $arg" >&2; exit 2 ;;
  esac
done

# Default preset: youtube-claim (vrijednosti iz .local-secrets.env; redirect = PROD)
if [ ${#PAIRS[@]} -eq 0 ]; then
  : "${YOUTUBE_CLAIM_GOOGLE_CLIENT_ID:?Treba YOUTUBE_CLAIM_GOOGLE_CLIENT_ID u .local-secrets.env}"
  : "${YOUTUBE_CLAIM_GOOGLE_CLIENT_SECRET:?Treba YOUTUBE_CLAIM_GOOGLE_CLIENT_SECRET u .local-secrets.env}"
  PAIRS=(
    "YOUTUBE_CLAIM_GOOGLE_CLIENT_ID=$YOUTUBE_CLAIM_GOOGLE_CLIENT_ID"
    "YOUTUBE_CLAIM_GOOGLE_CLIENT_SECRET=$YOUTUBE_CLAIM_GOOGLE_CLIENT_SECRET"
    "YOUTUBE_CLAIM_REDIRECT_URI=https://domovina.ai/youtube-claim/callback"
  )
fi

# Snimi postojeće ključeve da odlučimo POST (novi) vs PATCH (update).
EXISTING=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/tmp/_cc_code | jq -r '.[].key')
CODE=$(cat /tmp/_cc_code); rm -f /tmp/_cc_code
if [ "$CODE" != "200" ]; then echo "❌ GET envs HTTP $CODE — prekidam." >&2; exit 1; fi

mask() { local v=$1 n=${#1}; if [ "$n" -le 8 ]; then printf '****'; else printf '%s****%s' "${v:0:4}" "${v: -4}"; fi; }

for pair in "${PAIRS[@]}"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  # JSON-safe value preko jq (escape navodnika, backslasheva, itd.)
  body=$(jq -nc --arg k "$key" --arg v "$val" '{key:$k, value:$v, is_preview:false}')
  if echo "$EXISTING" | grep -qx "$key"; then
    method=PATCH; path="/services/$COOLIFY_SERVICE_UUID/envs"; action="PATCH (postoji)"
  else
    method=POST; path="/services/$COOLIFY_SERVICE_UUID/envs"; action="POST  (novi) "
  fi
  resp=$(coolify_curl "$method" "$path" --data "$body" 2>/tmp/_cc_code)
  code=$(cat /tmp/_cc_code); rm -f /tmp/_cc_code
  if [ "$code" = "200" ] || [ "$code" = "201" ]; then
    echo "✅ $action $key = $(mask "$val")  (HTTP $code)"
  else
    echo "❌ $action $key  (HTTP $code): $(echo "$resp" | head -c 200)"
  fi
done

if $DEPLOY; then
  echo ""
  echo "--- Redeploy (da env izmjene stupe na snagu) ---"
  resp=$(coolify_curl GET "/deploy?uuid=$COOLIFY_SERVICE_UUID" 2>/tmp/_cc_code)
  code=$(cat /tmp/_cc_code); rm -f /tmp/_cc_code
  echo "deploy trigger HTTP $code: $(echo "$resp" | head -c 200)"
else
  echo ""
  echo "ℹ️  Env postavljen. Za primjenu pokreni Redeploy (--deploy ili Coolify UI)."
fi
