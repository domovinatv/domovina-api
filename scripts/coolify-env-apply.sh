#!/usr/bin/env bash
# coolify-env-apply.sh
#
# Primijeni env iz fajla u Coolify service PREKO API-ja (umjesto ručnog UI paste-a).
# Upsert po ključu (PATCH, fallback POST), idempotentno. Default izvor je
# .coolify-merged.env (output coolify-env-merge.sh-a).
#
# SECRET-SAFE: nikad ne ispisuje vrijednosti — samo imena ključeva + akciju
# (create/update/unchanged). Pouka iz leak incidenta 2026-05-29 (vidi
# docs/secret-rotation.md): env alati maskiraju po defaultu.
#
# Guardraili: preflight health → plan (masked) → confirm → apply → post-verify.
#
# Usage:
#   ./scripts/coolify-env-apply.sh                       # iz .coolify-merged.env, s confirmom
#   ./scripts/coolify-env-apply.sh --file=path.env
#   ./scripts/coolify-env-apply.sh --dry-run             # samo plan, ništa ne mijenja
#   ./scripts/coolify-env-apply.sh -y --restart          # bez prompta + restart na kraju

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/coolify-api.sh
. "$SCRIPT_DIR/lib/coolify-api.sh"

FILE="$REPO_ROOT/.coolify-merged.env"
DRY_RUN=false
AUTO_YES=false
RESTART_AFTER=false

for arg in "$@"; do
  case "$arg" in
    --file=*)  FILE="${arg#*=}" ;;
    --dry-run) DRY_RUN=true ;;
    -y|--yes)  AUTO_YES=true ;;
    --restart) RESTART_AFTER=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [ ! -f "$FILE" ]; then
  echo "❌ '$FILE' ne postoji. Pokreni prvo ./scripts/coolify-env-merge.sh." >&2
  exit 1
fi

# ----- preflight -------------------------------------------------------------
echo "→ Service: $COOLIFY_SERVICE_UUID"
echo "→ Izvor:   $FILE"
echo "→ Preflight health..."
if ! coolify_health; then
  echo "❌ Coolify API ne odgovara ispravno (token/perms?). Prekidam." >&2
  exit 1
fi

# Postojeći ključevi (vrijednosti Coolify API zna ne vraćati — koristimo samo imena).
ENVS=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/dev/null)
declare -A EXISTS
while IFS= read -r k; do [ -n "$k" ] && EXISTS[$k]=1; done < <(echo "$ENVS" | jq -r '.[].key')

# ----- parse fajl + plan -----------------------------------------------------
CREATE_KEYS=()
UPDATE_COUNT=0
TOTAL=0
while IFS= read -r line; do
  line="${line%$'\r'}"
  case "$line" in ''|\#*) continue ;; esac
  [[ "$line" == *=* ]] || continue
  key="${line%%=*}"
  key="${key// /}"
  [ -z "$key" ] && continue
  TOTAL=$((TOTAL+1))
  if [ -z "${EXISTS[$key]:-}" ]; then CREATE_KEYS+=("$key"); else UPDATE_COUNT=$((UPDATE_COUNT+1)); fi
done < "$FILE"

echo ""
echo "Plan (imena ključeva; vrijednosti se NE prikazuju):"
echo "  ukupno u fajlu: $TOTAL"
echo "  UPDATE (postojeći): $UPDATE_COUNT"
echo "  CREATE (novi): ${#CREATE_KEYS[@]}"
if [ ${#CREATE_KEYS[@]} -gt 0 ]; then
  printf '    + %s\n' "${CREATE_KEYS[@]}"
fi

if $DRY_RUN; then
  echo ""
  echo "(dry-run) ništa nije promijenjeno."
  exit 0
fi

if ! $AUTO_YES; then
  echo ""
  read -rp "Primijeni na live Coolify env? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# ----- apply (upsert po ključu) ----------------------------------------------
applied=0; failed=0
while IFS= read -r line; do
  line="${line%$'\r'}"
  case "$line" in ''|\#*) continue ;; esac
  [[ "$line" == *=* ]] || continue
  key="${line%%=*}"; key="${key// /}"
  val="${line#*=}"
  [ -z "$key" ] && continue
  payload=$(jq -nc --arg k "$key" --arg v "$val" '{key:$k, value:$v}')

  code=$(coolify_curl PATCH "/services/$COOLIFY_SERVICE_UUID/envs" --data "$payload" 2>/tmp/_c >/dev/null; cat /tmp/_c)
  if [ "$code" = "404" ] || [ "$code" = "405" ]; then
    code=$(coolify_curl POST "/services/$COOLIFY_SERVICE_UUID/envs" --data "$payload" 2>/tmp/_c >/dev/null; cat /tmp/_c)
  fi
  rm -f /tmp/_c
  case "$code" in
    200|201|204) applied=$((applied+1)) ;;
    *) failed=$((failed+1)); echo "  ❌ $key → HTTP $code" >&2 ;;
  esac
done < "$FILE"

echo ""
echo "→ applied: $applied, failed: $failed"
[ "$failed" -gt 0 ] && { echo "❌ Neki ključevi nisu primijenjeni." >&2; exit 1; }

# ----- post-verify (provjeri da svi ključevi sad postoje) --------------------
echo "→ Post-verify..."
ENVS2=$(coolify_curl GET "/services/$COOLIFY_SERVICE_UUID/envs" 2>/dev/null)
declare -A EXISTS2
while IFS= read -r k; do [ -n "$k" ] && EXISTS2[$k]=1; done < <(echo "$ENVS2" | jq -r '.[].key')
missing=0
while IFS= read -r line; do
  line="${line%$'\r'}"; case "$line" in ''|\#*) continue ;; esac
  [[ "$line" == *=* ]] || continue
  key="${line%%=*}"; key="${key// /}"; [ -z "$key" ] && continue
  [ -z "${EXISTS2[$key]:-}" ] && { echo "  ⚠️  $key NIJE prisutan nakon apply" >&2; missing=$((missing+1)); }
done < "$FILE"
if [ "$missing" -eq 0 ]; then echo "  ✅ svi ključevi prisutni."; else echo "  ❌ $missing ključeva fali." >&2; exit 1; fi

echo ""
echo "ℹ️  Env promjene se aktiviraju TEK nakon redeploya/restarta."
if $RESTART_AFTER; then
  echo "→ Restart..."
  exec "$SCRIPT_DIR/coolify-restart.sh" -y
else
  echo "    ./scripts/coolify-restart.sh        (ili Coolify UI → Redeploy)"
  echo "    pa: ./scripts/ops-verify.sh"
fi
