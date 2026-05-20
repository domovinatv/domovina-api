#!/usr/bin/env bash
# pg_dump live baze u lokalni backups/ folder (gitignored).
# Default: schema-only za public i domovina_ai. Flag --data za full dump.
#
# Usage:
#   ./scripts/db-dump.sh                        # schema-only public + domovina_ai
#   ./scripts/db-dump.sh --data                 # full dump (schema + data)
#   ./scripts/db-dump.sh --schemas public,auth  # specific schemas

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

CONTAINER=$(detect_db_container)
TS=$(date -u +'%Y%m%d-%H%M%S')
SCHEMAS="public,domovina_ai"
SCHEMA_ONLY=true

while [ $# -gt 0 ]; do
  case "$1" in
    --data) SCHEMA_ONLY=false; shift ;;
    --schemas) SCHEMAS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$REPO_ROOT/backups"

OUT="$REPO_ROOT/backups/${TS}-$(echo "$SCHEMAS" | tr ',' '_')"
if $SCHEMA_ONLY; then OUT="${OUT}-schema.sql"; else OUT="${OUT}-full.sql"; fi

SCHEMA_FLAGS=""
for s in ${SCHEMAS//,/ }; do
  SCHEMA_FLAGS="$SCHEMA_FLAGS --schema=$s"
done

SCHEMA_ONLY_FLAG=""
if $SCHEMA_ONLY; then SCHEMA_ONLY_FLAG="--schema-only"; fi

echo "→ pg_dump $SCHEMA_FLAGS $SCHEMA_ONLY_FLAG → $OUT" >&2
remote_pg_dump "$CONTAINER" "$SCHEMA_FLAGS $SCHEMA_ONLY_FLAG" > "$OUT"

LINES=$(wc -l < "$OUT" | tr -d ' ')
SIZE=$(du -h "$OUT" | awk '{print $1}')
echo "✅ $LINES linija, $SIZE → backups/$(basename "$OUT")"
