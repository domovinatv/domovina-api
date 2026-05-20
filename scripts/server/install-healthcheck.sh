#!/usr/bin/env bash
# Deploy healthcheck.sh to server + setup cron + verify.
# Idempotent.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/db-env.sh
. "$SCRIPT_DIR/../lib/db-env.sh"

REMOTE_SCRIPT=/opt/domovina-backup/healthcheck.sh
CRON_LINE='*/5 * * * * /opt/domovina-backup/healthcheck.sh >> /var/log/domovina-healthcheck.log 2>&1'

echo "=== Deploy healthcheck.sh ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo tee $REMOTE_SCRIPT >/dev/null" < "$SCRIPT_DIR/healthcheck.sh"
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo chmod 0750 $REMOTE_SCRIPT && sudo chown root:root $REMOTE_SCRIPT"
echo "✅ Deployed: $REMOTE_SCRIPT"

echo ""
echo "=== Update cron ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo bash -c '
  current=\$(crontab -l 2>/dev/null | grep -v healthcheck.sh || true)
  echo \"\$current\" > /tmp/_crontab
  echo \"$CRON_LINE\" >> /tmp/_crontab
  crontab /tmp/_crontab
  rm /tmp/_crontab
  echo \"--- root crontab ---\"
  crontab -l
'"

echo ""
echo "=== Test run ==="
ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "sudo $REMOTE_SCRIPT && echo '---log tail---' && sudo tail -5 /var/log/domovina-healthcheck.log"

echo ""
echo "ℹ️  Telegram alerts: kreiraj /etc/domovina-alert.env s TG_BOT_TOKEN + TG_CHAT_ID."
echo "    Bez tih env varova, samo logira u /var/log/domovina-healthcheck.log."
