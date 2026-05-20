#!/usr/bin/env bash
# Dohvati env vars iz Coolify service-a.
#
# Usage:
#   ./scripts/coolify-env-get.sh              # sve env (KEY=value linije, secrets masked)
#   ./scripts/coolify-env-get.sh KEY          # samo specifični KEY
#   ./scripts/coolify-env-get.sh --json       # raw JSON output
#   ./scripts/coolify-env-get.sh --no-mask    # bez maskiranja (OPREZ — secrets u stdout)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/coolify-api.sh
. "$SCRIPT_DIR/lib/coolify-api.sh"

JSON=false
NO_MASK=false
KEY=""
for arg in "$@"; do
  case "$arg" in
    --json)    JSON=true ;;
    --no-mask) NO_MASK=true ;;
    --*)       echo "Unknown flag: $arg" >&2; exit 2 ;;
    *)         KEY="$arg" ;;
  esac
done

ENVS=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/tmp/_code)
CODE=$(cat /tmp/_code); rm -f /tmp/_code
if [ "$CODE" != "200" ]; then
  echo "❌ HTTP $CODE" >&2
  echo "$ENVS" | head -10 >&2
  exit 1
fi

mask() {
  local v=$1 n=${#1}
  if [ -z "$v" ]; then printf '<empty>'
  elif [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s…%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

if $JSON; then
  if [ -n "$KEY" ]; then
    echo "$ENVS" | jq --arg k "$KEY" '.[] | select(.key == $k)'
  else
    echo "$ENVS" | jq .
  fi
  exit 0
fi

# Plain key=value output (masked by default)
if [ -n "$KEY" ]; then
  VAL=$(echo "$ENVS" | jq -r --arg k "$KEY" '.[] | select(.key == $k) | .value // ""')
  if [ -z "$VAL" ] && ! echo "$ENVS" | jq -e --arg k "$KEY" 'any(.key == $k)' >/dev/null; then
    echo "❌ KEY '$KEY' ne postoji" >&2
    exit 1
  fi
  if $NO_MASK; then echo "$KEY=$VAL"
  else echo "$KEY=$(mask "$VAL")"
  fi
else
  # All envs
  echo "$ENVS" | jq -r '.[] | [.key, .value // ""] | @tsv' \
    | while IFS=$'\t' read -r k v; do
      if $NO_MASK; then echo "$k=$v"
      else echo "$k=$(mask "$v")"
      fi
    done | sort
fi
