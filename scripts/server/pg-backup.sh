#!/usr/bin/env bash
# pg-backup.sh — deployed na Coolify host kao /opt/domovina-backup/pg-backup.sh
#
# pg_dump-a supabase-db-* container svaki dan, gzipa, briše files starije od retention dana.
# Pokreće se kao root preko cron (vidi instalaciju u scripts/server/install-cron.sh).
#
# Backup target:
#   /data/coolify/backups/domovina-api/pg-YYYY-MM-DD-HHMMSS.sql.gz
#
# Schemas backed up: javne (public, auth, domovina_ai, storage, _supabase, _realtime).
# (NE backup-amo: pg_catalog, information_schema — auto-managed.)

set -euo pipefail

BACKUP_DIR="/data/coolify/backups/domovina-api"
RETENTION_DAYS=14
LOG_FILE="$BACKUP_DIR/_backup.log"

mkdir -p "$BACKUP_DIR"

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

trap 'log "❌ FAIL: $BASH_COMMAND (line $LINENO)"' ERR

log "=== pg-backup start ==="

# Find supabase-db container
DB_CONTAINER=$(docker ps --format '{{.Names}}' | grep '^supabase-db-' | head -1)
if [ -z "$DB_CONTAINER" ]; then
  log "❌ Nije pronađen supabase-db container"
  exit 1
fi
log "container: $DB_CONTAINER"

# Filename
TS=$(date -u +'%Y%m%d-%H%M%S')
OUT="$BACKUP_DIR/pg-${TS}.sql.gz"

# pg_dump (full database — sve sheme osim pg_catalog/info_schema)
# --clean --if-exists → restore radi nakon DROP existing
# --no-owner --no-privileges → portability između environmentima
docker exec "$DB_CONTAINER" pg_dump \
  -U postgres -d postgres \
  --clean --if-exists --no-owner --no-privileges \
  | gzip -9 > "$OUT"

SIZE=$(du -h "$OUT" | awk '{print $1}')
log "✅ created: $(basename "$OUT") ($SIZE)"

# Retention — delete files older than RETENTION_DAYS days
DELETED=$(find "$BACKUP_DIR" -name 'pg-*.sql.gz' -type f -mtime "+$RETENTION_DAYS" -delete -print | wc -l)
log "🗑  cleaned: $DELETED file(s) older than ${RETENTION_DAYS}d"

# Summary: count + total size
COUNT=$(find "$BACKUP_DIR" -name 'pg-*.sql.gz' -type f | wc -l)
TOTAL=$(du -sh "$BACKUP_DIR" | awk '{print $1}')
log "📊 total: $COUNT backups, $TOTAL on disk"

log "=== pg-backup done ==="
