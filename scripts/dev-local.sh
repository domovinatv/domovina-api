#!/usr/bin/env bash
# scripts/dev-local.sh
#
# Wrapper oko `supabase` CLI za LOKALNI dev stack (Kong 55321 / DB 55322).
# Exporta GOTRUE_EXTERNAL_* iz .local-secrets.env u procesni env PRIJE poziva,
# jer config.toml `[auth.external.google]` koristi `env(GOTRUE_EXTERNAL_GOOGLE_*)`
# interpolaciju koju CLI rješava iz procesnog env-a (godotenv) pri `supabase start`.
# Edge-fn secreti (youtube-claim, certilia, KYC) NE idu ovuda — CLI ih auto-učitava
# iz supabase/functions/.env u edge container.
#
# Uporaba:
#   scripts/dev-local.sh restart      # supabase stop && supabase start (default)
#   scripts/dev-local.sh start
#   scripts/dev-local.sh stop
#   scripts/dev-local.sh <bilo koja supabase podnaredba>
#
# Napomena: config.toml / nove funkcije / verify_jwt izmjene pokupi SAMO pun
# stop+start (docker restart je no-op za registry/config). Zato je `restart` default.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/.local-secrets.env}"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "❌ $SECRETS_FILE ne postoji. Kopiraj iz .local-secrets.env.example i popuni." >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
. "$SECRETS_FILE"
set +a

: "${GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID:?Treba GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID u .local-secrets.env}"
: "${GOTRUE_EXTERNAL_GOOGLE_SECRET:?Treba GOTRUE_EXTERNAL_GOOGLE_SECRET u .local-secrets.env}"

cd "$REPO_ROOT"

cmd="${1:-restart}"
case "$cmd" in
  restart)
    echo "▶ supabase stop && supabase start (pun restart — pokupi config.toml + registry)"
    supabase stop || true
    exec supabase start
    ;;
  *)
    exec supabase "$@"
    ;;
esac
