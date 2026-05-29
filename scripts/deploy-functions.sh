#!/usr/bin/env bash
# deploy-functions.sh
#
# Deploya repo `supabase/functions/` u live Supabase edge-runtime container
# (Coolify self-hosted). Funkcije žive u bind-mount volumeu na hostu; ova skripta
# ih čini reproducibilnima iz gita umjesto ručnog docker exec-a.
#
# Workflow:
#   1. detektira supabase-edge-functions-* container preko SSH
#   2. za svaki file u supabase/functions/ kopira ga u /home/deno/functions/<rel>
#      (preko `docker exec -i sh -c "cat > ..."` — piše u bind-mount → host volume)
#   3. NE dira hello/main (Coolify template defaults)
#   4. (opcionalno) restart edge containera da pokupi promjene
#
# Pisanje ide kroz `docker exec` jer je host volume root-owned, a ubuntu SSH user
# je u docker grupi (isti pattern kao db-migrate.sh za psql).
#
# Usage:
#   ./scripts/deploy-functions.sh                 # deploy + prompt za restart
#   ./scripts/deploy-functions.sh --dry-run       # pokaži što bi se deployalo
#   ./scripts/deploy-functions.sh --restart -y    # deploy + restart bez prompta
#   ./scripts/deploy-functions.sh --only=certilia # samo jedna funkcija (+ _shared)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

FUNCTIONS_DIR="$REPO_ROOT/supabase/functions"
DRY_RUN=false
RESTART=false
AUTO_YES=false
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --restart) RESTART=true; shift ;;
    -y|--yes)  AUTO_YES=true; shift ;;
    --only=*)  ONLY="${1#*=}"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$FUNCTIONS_DIR" ]; then
  echo "❌ $FUNCTIONS_DIR ne postoji." >&2
  exit 1
fi

# Detect edge container
EDGE=$(ssh_remote "docker ps --format '{{.Names}}' | grep '^supabase-edge-functions-' | head -1")
if [ -z "$EDGE" ]; then
  echo "❌ Nije pronađen supabase-edge-functions-* container." >&2
  exit 1
fi
echo "→ edge container: $EDGE" >&2

# Collect files (relativno na FUNCTIONS_DIR). _shared se uvijek uključuje.
collect() {
  if [ -n "$ONLY" ]; then
    ( cd "$FUNCTIONS_DIR" && find "$ONLY" _shared -type f 2>/dev/null )
  else
    ( cd "$FUNCTIONS_DIR" && find . -type f | sed 's|^\./||' )
  fi
}

FILES=$(collect | sort)
if [ -z "$FILES" ]; then
  echo "❌ Nema fileova za deploy (provjeri --only)." >&2
  exit 1
fi

echo "→ funkcije za deploy:" >&2
echo "$FILES" | sed 's|/.*||' | sort -u | sed 's/^/    /' >&2
echo "→ (hello/main se NE diraju)" >&2

if $DRY_RUN; then
  echo ""
  echo "(dry-run) fileovi:"
  echo "$FILES" | sed 's/^/    /'
  exit 0
fi

if ! $AUTO_YES; then
  read -rp "Deploy na $EDGE? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# Copy each file via docker exec (writes through bind-mount to host volume)
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  dir="/home/deno/functions/$(dirname "$rel")"
  ssh_remote "docker exec $EDGE mkdir -p '$dir'"
  ssh_remote "docker exec -i $EDGE sh -c 'cat > /home/deno/functions/$rel'" < "$FUNCTIONS_DIR/$rel"
  echo "   ✓ $rel"
done <<< "$FILES"

echo "✅ Deploy gotov."

if $RESTART; then
  echo "→ restart $EDGE ..."
  ssh_remote "docker restart $EDGE" >/dev/null
  echo "✅ restartan."
else
  echo "ℹ️  Restart preporučen da se promjene sigurno pokupe:"
  echo "    ./scripts/deploy-functions.sh --restart -y   (ili: ssh ... docker restart $EDGE)"
fi
