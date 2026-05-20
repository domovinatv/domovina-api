#!/usr/bin/env bash
# install-cron.sh — pokreće se LOKALNO; deployira pg-backup.sh na server i setira cron.
#
# Što radi:
#   1. scp pg-backup.sh → /opt/domovina-backup/pg-backup.sh (root-owned, 0700)
#   2. dodaje root cron: dnevno u 03:15 UTC
#   3. tests s jednim manualnim runom
#
# Idempotent: ponovni run zamijeni file + osvježi cron (deduplicira liniju).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/db-env.sh
. "$SCRIPT_DIR/../lib/db-env.sh"

REMOTE_DIR=/opt/domovina-backup
REMOTE_SCRIPT=$REMOTE_DIR/pg-backup.sh
CRON_LINE='15 3 * * * /opt/domovina-backup/pg-backup.sh >> /var/log/domovina-pg-backup.log 2>&1'

echo "→ Server: $COOLIFY_SSH_HOST"
echo ""

echo "=== 1. mkdir + scp pg-backup.sh ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo mkdir -p $REMOTE_DIR && sudo chown root:root $REMOTE_DIR && sudo chmod 0755 $REMOTE_DIR"

# Cat script to remote (avoids scp permission dance)
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo tee $REMOTE_SCRIPT >/dev/null" < "$SCRIPT_DIR/pg-backup.sh"
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo chmod 0750 $REMOTE_SCRIPT && sudo chown root:root $REMOTE_SCRIPT"

echo "✅ Deployed: $REMOTE_SCRIPT"
echo ""

echo "=== 2. Update root crontab ==="
# Strategija: read existing root crontab, ukloni postojeću domovina liniju, dodaj svježu
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo bash -c '
  current=\$(crontab -l 2>/dev/null | grep -v pg-backup.sh || true)
  echo \"\$current\" > /tmp/_crontab
  echo \"$CRON_LINE\" >> /tmp/_crontab
  crontab /tmp/_crontab
  rm /tmp/_crontab
  echo \"--- new root crontab ---\"
  crontab -l
'"
echo ""

echo "=== 3. Test run (manual) ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo $REMOTE_SCRIPT"
echo ""

echo "=== 4. Verify backup file ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo ls -lh /data/coolify/backups/domovina-api/ | head -10"
echo ""
echo "✅ Cron-based backup installed. Daily run at 03:15 UTC."
echo "   Logs: /var/log/domovina-pg-backup.log  + /data/coolify/backups/domovina-api/_backup.log"
