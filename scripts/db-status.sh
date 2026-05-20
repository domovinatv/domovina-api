#!/usr/bin/env bash
# Pokaži applied vs pending migracije.
#
# Migracija je "applied" ako ima red u supabase_migrations.schema_migrations
# s odgovarajućim version stringom (timestamp prefix iz filename-a).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

CONTAINER=$(detect_db_container)
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"

# Osiguraj da tracking tablica postoji (idempotent)
ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -v ON_ERROR_STOP=1" <<'SQL' >/dev/null
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  name text,
  statements text[],
  inserted_at timestamptz default now()
);
SQL

APPLIED=$(ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -t -A -F'|' -c 'select version, name from supabase_migrations.schema_migrations order by version;'")

printf "%-22s %-30s %s\n" "VERSION" "NAME" "STATUS"
printf "%-22s %-30s %s\n" "----------------------" "------------------------------" "-------"

# All applied versions kao set
declare -A APPLIED_MAP
while IFS='|' read -r version name; do
  [ -z "$version" ] && continue
  APPLIED_MAP[$version]=1
  printf "%-22s %-30s %s\n" "$version" "${name:-}" "✅ applied"
done <<< "$APPLIED"

# Pending iz file-a
if [ -d "$MIGRATIONS_DIR" ]; then
  for f in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
    base=$(basename "$f" .sql)
    version="${base%%_*}"
    name="${base#*_}"
    if [ -z "${APPLIED_MAP[$version]:-}" ]; then
      printf "%-22s %-30s %s\n" "$version" "$name" "⏳ pending"
    fi
  done
fi
