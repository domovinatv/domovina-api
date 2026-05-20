#!/usr/bin/env bash
# Apply pending migracije iz supabase/migrations/ na live DB.
#
# Workflow:
#   1. detect supabase-db container na serveru preko SSH
#   2. ensure supabase_migrations.schema_migrations tracking tablica
#   3. (opcionalno) pg_dump backup u backups/pre-<ts>.sql
#   4. iteriraj migrations/*.sql sortiranim po imenu
#   5. preskoči one čiji je version u tracking tablici
#   6. apply pending u TRANSAKCIJI, na error rollback i exit
#   7. insert red u tracking tablicu nakon uspjeha
#
# Usage:
#   ./scripts/db-migrate.sh                  # backup + apply pending
#   ./scripts/db-migrate.sh --no-backup      # skip pg_dump (brže za dev iteracije)
#   ./scripts/db-migrate.sh --dry-run        # pokaži što bi se primijenilo, ne radi ništa

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"

DO_BACKUP=true
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-backup) DO_BACKUP=false; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

CONTAINER=$(detect_db_container)
MIGRATIONS_DIR="$REPO_ROOT/supabase/migrations"

echo "→ container: $CONTAINER" >&2

# 1. Ensure tracking tablica
if ! $DRY_RUN; then
  ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -v ON_ERROR_STOP=1" <<'SQL' >/dev/null
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  name text,
  statements text[],
  inserted_at timestamptz default now()
);
SQL
fi

# 2. Find pending
APPLIED=$(ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -t -A -c 'select version from supabase_migrations.schema_migrations;'" 2>/dev/null || true)
declare -A APPLIED_SET
while IFS= read -r v; do
  [ -n "$v" ] && APPLIED_SET[$v]=1
done <<< "$APPLIED"

PENDING=()
for f in $(ls "$MIGRATIONS_DIR"/*.sql 2>/dev/null | sort); do
  base=$(basename "$f" .sql)
  version="${base%%_*}"
  if [ -z "${APPLIED_SET[$version]:-}" ]; then
    PENDING+=("$f")
  fi
done

if [ ${#PENDING[@]} -eq 0 ]; then
  echo "✅ Sve migracije već primijenjene."
  exit 0
fi

echo "→ Pending (${#PENDING[@]}):" >&2
for f in "${PENDING[@]}"; do
  echo "    $(basename "$f")" >&2
done

if $DRY_RUN; then
  echo "(dry-run, ništa ne radim)"
  exit 0
fi

# 3. Backup
if $DO_BACKUP; then
  TS=$(date -u +'%Y%m%d-%H%M%S')
  BACKUP="$REPO_ROOT/backups/pre-migrate-${TS}.sql"
  mkdir -p "$REPO_ROOT/backups"
  echo "→ pg_dump --schema-only --schema=public --schema=domovina_ai → backups/pre-migrate-${TS}.sql" >&2
  remote_pg_dump "$CONTAINER" "--schema-only --schema=public --schema=domovina_ai" > "$BACKUP" || {
    echo "⚠️  Backup failed (možda nema domovina_ai schemu još) — pokušavam samo public"
    remote_pg_dump "$CONTAINER" "--schema-only --schema=public" > "$BACKUP"
  }
  SIZE=$(du -h "$BACKUP" | awk '{print $1}')
  echo "   $SIZE saved." >&2
fi

# 4. Apply pending
for f in "${PENDING[@]}"; do
  base=$(basename "$f" .sql)
  version="${base%%_*}"
  name="${base#*_}"
  echo ""
  echo "→ Applying $base ..." >&2

  # Wrap in transaction + track u istoj transakciji
  {
    echo "begin;"
    cat "$f"
    echo ""
    echo "insert into supabase_migrations.schema_migrations (version, name)"
    echo "  values ('$version', '$name')"
    echo "  on conflict (version) do nothing;"
    echo "commit;"
  } | ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -v ON_ERROR_STOP=1" || {
    echo "❌ Migration $base failed. Transaction rolled back." >&2
    echo "   Restore from backup ako treba: backups/pre-migrate-${TS}.sql" >&2
    exit 1
  }
  echo "   ✅ $base applied"
done

echo ""
echo "✅ Sve migracije primijenjene."
echo ""
echo "Status:"
"$SCRIPT_DIR/db-status.sh"
