#!/usr/bin/env bash
# stamp-deploy.sh
#
# Upiše u Coolify env "deployment stamp" — koji git commit se deploya. Coolify
# briše komentare, ali vrijednosti env varijabli ostaju → trajni, verifikabilan
# zapis (GitHub commit URL) koji u UI-u uvijek pokazuje na čemu prod stoji.
#
# Postavlja (sve NE-tajno → smije se ispisati):
#   DEPLOY_GIT_COMMIT_SHA   full 40-char SHA
#   DEPLOY_GIT_COMMIT_URL   https://github.com/<owner>/<repo>/commit/<sha>
#   DEPLOY_GIT_BRANCH       grana
#   DEPLOY_STAMPED_AT       UTC timestamp
#
# Verificira da je HEAD na originu (inače GitHub URL ne resolvira) — osim s
# --allow-unpushed.
#
# Usage:
#   ./scripts/stamp-deploy.sh                 # stamp HEAD (confirm)
#   ./scripts/stamp-deploy.sh -y              # bez prompta
#   ./scripts/stamp-deploy.sh --dry-run       # samo pokaži vrijednosti
#   ./scripts/stamp-deploy.sh --allow-unpushed

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/coolify-api.sh
. "$SCRIPT_DIR/lib/coolify-api.sh"

AUTO_YES=false
DRY_RUN=false
ALLOW_UNPUSHED=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)          AUTO_YES=true ;;
    --dry-run)         DRY_RUN=true ;;
    --allow-unpushed)  ALLOW_UNPUSHED=true ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
SHA=$(git rev-parse HEAD)
SHORT=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# owner/repo iz remote URL-a (ssh ili https)
REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
SLUG=$(printf '%s' "$REMOTE" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
if [ -z "$SLUG" ]; then echo "❌ Ne mogu odrediti owner/repo iz origin remote-a." >&2; exit 1; fi
URL="https://github.com/$SLUG/commit/$SHA"

# je li HEAD na originu?
if git branch -r --contains "$SHA" 2>/dev/null | grep -q 'origin/'; then
  PUSHED=true
else
  PUSHED=false
fi

echo "→ Service: $COOLIFY_SERVICE_UUID"
echo "→ Stamp:"
echo "    DEPLOY_GIT_COMMIT_SHA = $SHA"
echo "    DEPLOY_GIT_COMMIT_URL = $URL"
echo "    DEPLOY_GIT_BRANCH     = $BRANCH"
echo "    DEPLOY_STAMPED_AT     = $NOW"
echo "    (HEAD $SHORT pushan na origin: $PUSHED)"

if ! $PUSHED && ! $ALLOW_UNPUSHED; then
  echo "❌ HEAD nije na origin → GitHub URL se neće resolvati. Pushaj prvo (ili --allow-unpushed)." >&2
  exit 1
fi

if $DRY_RUN; then echo "(dry-run) ništa nije postavljeno."; exit 0; fi

if ! $AUTO_YES; then
  read -rp "Upisati stamp u Coolify env? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# preflight
coolify_health || { echo "❌ Coolify API ne odgovara." >&2; exit 1; }

upsert() { # key value
  local key=$1 val=$2 payload code
  payload=$(jq -nc --arg k "$key" --arg v "$val" '{key:$k, value:$v}')
  code=$(coolify_curl PATCH "/services/$COOLIFY_SERVICE_UUID/envs" --data "$payload" 2>/tmp/_c >/dev/null; cat /tmp/_c)
  if [ "$code" = "404" ] || [ "$code" = "405" ]; then
    code=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/envs" --data "$payload" 2>/tmp/_c >/dev/null; cat /tmp/_c)
  fi
  rm -f /tmp/_c
  case "$code" in 200|201|204) echo "   ✓ $key" ;; *) echo "   ❌ $key → HTTP $code" >&2; return 1 ;; esac
}

upsert DEPLOY_GIT_COMMIT_SHA "$SHA"
upsert DEPLOY_GIT_COMMIT_URL "$URL"
upsert DEPLOY_GIT_BRANCH     "$BRANCH"
upsert DEPLOY_STAMPED_AT     "$NOW"

echo "✅ Stamp upisan. (Vidljiv u Coolify env odmah; u containerima nakon redeploya.)"
