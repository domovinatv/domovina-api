#!/usr/bin/env bash
# Otvori interaktivni psql na live Postgres-u (kroz SSH + docker exec).
#
# Usage:
#   ./scripts/db-psql.sh                  # interactive prompt
#   ./scripts/db-psql.sh -c "select 1"    # one-shot query
#   echo "select 1;" | ./scripts/db-psql.sh --stdin
#
# Sve nakon flag-ova ide kao psql args.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

CONTAINER=$(detect_db_container)

STDIN_MODE=false
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --stdin) STDIN_MODE=true ;;
    *) ARGS+=("$arg") ;;
  esac
done

echo "→ container: $CONTAINER (user=$COOLIFY_DB_USER db=$COOLIFY_DB_NAME)" >&2

if $STDIN_MODE; then
  remote_psql_exec "$CONTAINER" "${ARGS[@]:-}"
elif [ "${#ARGS[@]}" -gt 0 ]; then
  # one-shot s args
  remote_psql_exec "$CONTAINER" "${ARGS[@]}"
else
  remote_psql_interactive "$CONTAINER"
fi
