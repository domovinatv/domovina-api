#!/usr/bin/env bash
# scripts/supabase-versions.sh
#
# Snima image tagove Supabase servisa na PROD-u (Coolify host, preko SSH) i
# LOKALNO (Supabase CLI stack), te zapisuje as-code snapshot u
# docs/supabase-versions.md. Zatvara IaC gap: prod verzije inače žive samo u
# Coolifyju, nigdje u gitu.
#
# Coolify NE auto-update-a Supabase (snapshotira compose pri deployu; redeploy =
# isti pinani tagovi). Update verzije = ručno u Coolifyju. Lokalni CLI verzije
# fiksira `supabase` binary — sync preko `brew upgrade supabase` + stop/start.
#
# Uporaba:
#   scripts/supabase-versions.sh           # ispiši usporedbu na stdout
#   scripts/supabase-versions.sh --write    # + prepiši docs/supabase-versions.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_FILE="${SECRETS_FILE:-$REPO_ROOT/.local-secrets.env}"
DOC="$REPO_ROOT/docs/supabase-versions.md"

[ -f "$SECRETS_FILE" ] || { echo "❌ $SECRETS_FILE ne postoji." >&2; exit 1; }
# shellcheck source=/dev/null
set -a; . "$SECRETS_FILE"; set +a
: "${COOLIFY_SSH_HOST:?Treba COOLIFY_SSH_HOST}"
: "${COOLIFY_SSH_KEY:?Treba COOLIFY_SSH_KEY}"
: "${COOLIFY_SERVICE_UUID:?Treba COOLIFY_SERVICE_UUID}"
KEY="${COOLIFY_SSH_KEY/#\~/$HOME}"

# PROD: docker ps na Coolify hostu → linije servisa s našim service UUID-om,
# strip "supabase-" prefiks i "-$UUID" sufiks → "servis<TAB>image:tag".
prod_rows() {
  ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "$COOLIFY_SSH_HOST" "docker ps --format '{{.Names}}\t{{.Image}}'" \
    | grep -F "$COOLIFY_SERVICE_UUID" \
    | sed -E "s/-${COOLIFY_SERVICE_UUID}\t/\t/; s/^supabase-//" \
    | sort
}

# LOKAL: samo domovina-api projekt (NE zef mdpshg…), strip "supabase_" prefiks i
# "_domovina-api" sufiks.
local_rows() {
  docker ps --format '{{.Names}}\t{{.Image}}' \
    | grep -E '_domovina-api\b' \
    | grep -E '^supabase_' \
    | sed -E 's/_domovina-api\t/\t/; s/^supabase_//' \
    | sort
}

cli_ver() { supabase --version 2>/dev/null | head -1; }
table() { awk -F'\t' 'BEGIN{print "| servis | image:tag |"; print "|---|---|"} {printf "| %s | `%s` |\n",$1,$2}'; }

PROD="$(prod_rows)"
LOCAL="$(local_rows)"
CLI="$(cli_ver)"
TS="$(date -u +'%Y-%m-%d %H:%MZ')"

render() {
  cat <<EOF
# Supabase verzije — prod (Coolify) vs lokal (CLI)

> Auto-generirano: \`scripts/supabase-versions.sh --write\` · snapshot $TS
>
> **Coolify NE auto-update-a Supabase.** Pri deployu snapshotira docker-compose;
> redeploy povlači iste pinane tagove. Update = ručno u Coolifyju (bumpaj template /
> image tagove → redeploy). Lokalni CLI verzije fiksira \`supabase\` binary; sync
> preko \`brew upgrade supabase\` + \`scripts/dev-local.sh restart\`. Cilj: lokal NE
> smije biti viša verzija od prod-a (testiraj na ≤ prod, idealno ≈ prod).

## PROD — api.domovina.ai (Coolify service \`$COOLIFY_SERVICE_UUID\`)

$(printf '%s\n' "$PROD" | table)

## LOKAL — Supabase CLI \`$CLI\`

$(printf '%s\n' "$LOCAL" | table)

## Refresh

\`\`\`bash
scripts/supabase-versions.sh --write   # re-fetch prod + lokal, prepiši ovaj doc
git add docs/supabase-versions.md && git commit -m "chore: snapshot supabase verzija"
\`\`\`
EOF
}

if [ "${1:-}" = "--write" ]; then
  render > "$DOC"
  echo "✅ Zapisano: $DOC"
else
  render
fi
