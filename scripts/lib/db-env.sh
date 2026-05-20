#!/usr/bin/env bash
# scripts/lib/db-env.sh
#
# Source-ano iz svih db-*.sh skripti. Ne pokreće se direktno.
# Učitava .local-secrets.env, auto-detect-a DB container ako nije postavljen,
# i izlaže helperice za remote psql / docker exec.
#
# Required env (iz .local-secrets.env):
#   COOLIFY_SSH_HOST       — ubuntu@host.ip
#   COOLIFY_SSH_KEY        — path do private SSH ključa
# Optional:
#   COOLIFY_DB_CONTAINER   — eksplicitan container name (auto-detect ako prazno)
#   COOLIFY_DB_USER        — default postgres
#   COOLIFY_DB_NAME        — default postgres

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/.local-secrets.env}"

if [ ! -f "$SECRETS_FILE" ]; then
  echo "❌ $SECRETS_FILE ne postoji. Kopiraj iz .local-secrets.env.example i popuni." >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
. "$SECRETS_FILE"
set +a

: "${COOLIFY_SSH_HOST:?Treba COOLIFY_SSH_HOST u .local-secrets.env}"
: "${COOLIFY_SSH_KEY:?Treba COOLIFY_SSH_KEY u .local-secrets.env}"
COOLIFY_DB_USER="${COOLIFY_DB_USER:-postgres}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-postgres}"

# expand ~/ → $HOME
COOLIFY_SSH_KEY="${COOLIFY_SSH_KEY/#\~/$HOME}"

if [ ! -f "$COOLIFY_SSH_KEY" ]; then
  echo "❌ SSH key ne postoji: $COOLIFY_SSH_KEY" >&2
  exit 1
fi

SSH_OPTS=(
  -i "$COOLIFY_SSH_KEY"
  -o ConnectTimeout=10
  -o ServerAliveInterval=30
  -o LogLevel=ERROR
)

# ----- helpers ---------------------------------------------------------------

ssh_remote() {
  ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" "$@"
}

# Auto-detect DB container ako nije eksplicitno setiran
detect_db_container() {
  if [ -n "${COOLIFY_DB_CONTAINER:-}" ]; then
    printf '%s' "$COOLIFY_DB_CONTAINER"
    return
  fi
  local name
  name=$(ssh_remote "docker ps --format '{{.Names}}' | grep '^supabase-db-' | head -1")
  if [ -z "$name" ]; then
    echo "❌ Nije pronađen pokrenut supabase-db-* container na $COOLIFY_SSH_HOST" >&2
    exit 1
  fi
  printf '%s' "$name"
}

# Run psql ne-interaktivno (stdin = SQL). Args nakon -- idu psql-u.
remote_psql_exec() {
  local container=$1; shift
  ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" \
    "docker exec -i $container psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -v ON_ERROR_STOP=1 $*"
}

# Run psql interaktivno (TTY)
remote_psql_interactive() {
  local container=$1; shift
  ssh -t "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" \
    "docker exec -it $container psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME $*"
}

# Run pg_dump ne-interaktivno (output na stdout)
remote_pg_dump() {
  local container=$1; shift
  ssh "${SSH_OPTS[@]}" "$COOLIFY_SSH_HOST" \
    "docker exec $container pg_dump -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME $*"
}

export REPO_ROOT
export -f ssh_remote detect_db_container remote_psql_exec remote_psql_interactive remote_pg_dump
