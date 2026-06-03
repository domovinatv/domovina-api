#!/usr/bin/env bash
# deploy-journal.sh — zapiši jedan deploy kao NEOVISAN, immutable milestone.
#
# Zašto: u slučaju problema uvijek imamo regresijski dnevnik — što je točno bilo
# deployano i u kakvom je stanju backend bio u tom trenutku. Svaki deploy je
# zasebna datoteka pod deploys/ (PUN snapshot, ne delta) → dva milestonea se
# `git diff`-aju da se vidi točno koja se migracija/funkcija/image promijenio.
#
# Snima (sve NE-tajno):
#   • git:        short+full SHA, grana, subject, pushan na origin?, dirty count
#   • migracije:  live supabase_migrations.schema_migrations (count + head + puna lista)
#   • funkcije:   supabase/functions/ (deployani edge set iz repo-a)
#   • containeri: live `docker ps` supabase-* (name|image|status)
#   • ops-verify: PASS/FAIL (preko --verify ili proslijeđen --ops-result)
#   • operator:   git user.name <email>  + opcionalni --note
#
# Live podaci (migracije/containeri) su best-effort: ako SSH padne, upiše se
# "unavailable" i milestone se svejedno zapiše (journaling NIKAD ne blokira deploy).
#
# Usage:
#   ./scripts/deploy-journal.sh                          # snimi milestone (bez ops-verify)
#   ./scripts/deploy-journal.sh --verify                 # + pokreni ops-verify i ugradi rezultat
#   ./scripts/deploy-journal.sh --ops-result PASS        # ugradi već poznat rezultat (iz deploy.sh)
#   ./scripts/deploy-journal.sh --note "migration-only"  # slobodna bilješka
#   ./scripts/deploy-journal.sh --commit                 # git add + commit milestone (+INDEX)
#   ./scripts/deploy-journal.sh --dry-run                # ispiši milestone na stdout, ne piši ništa

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/db-env.sh
. "$SCRIPT_DIR/lib/db-env.sh"   # ssh_remote, detect_db_container, REPO_ROOT, COOLIFY_DB_*

NOTE=""
OPS_RESULT=""      # "", PASS, FAIL — ako prazno i --verify, pokreni; inače "skipped"
DO_VERIFY=false
DO_COMMIT=false
DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    --note)        NOTE="${2:-}"; shift 2 ;;
    --ops-result)  OPS_RESULT="${2:-}"; shift 2 ;;
    --verify)      DO_VERIFY=true; shift ;;
    --commit)      DO_COMMIT=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)     sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"
DEPLOYS_DIR="$REPO_ROOT/deploys"

# ----- git fakti -------------------------------------------------------------
SHA=$(git rev-parse HEAD)
SHORT=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
SUBJECT=$(git log -1 --pretty=%s)
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
OPERATOR="$(git config user.name 2>/dev/null || echo unknown) <$(git config user.email 2>/dev/null || echo '')>"
NOW=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
TS_COMPACT=$(date -u +'%Y%m%dT%H%M%SZ')

REMOTE=$(git remote get-url origin 2>/dev/null || echo "")
SLUG=$(printf '%s' "$REMOTE" | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
COMMIT_URL=""
[ -n "$SLUG" ] && COMMIT_URL="https://github.com/$SLUG/commit/$SHA"

if git branch -r --contains "$SHA" 2>/dev/null | grep -q 'origin/'; then PUSHED=yes; else PUSHED=no; fi
[ "$DIRTY" = "0" ] && TREE="clean" || TREE="${DIRTY} dirty"

# ----- ops-verify (opcionalno) ----------------------------------------------
if [ -z "$OPS_RESULT" ]; then
  if $DO_VERIFY; then
    echo "→ ops-verify ..." >&2
    if "$SCRIPT_DIR/ops-verify.sh" >/tmp/_journal_ops 2>&1; then OPS_RESULT=PASS; else OPS_RESULT=FAIL; fi
    rm -f /tmp/_journal_ops
  else
    OPS_RESULT="skipped"
  fi
fi

# ----- live: migracije + containeri (best-effort) ----------------------------
MIG_LIST="unavailable"
MIG_COUNT="?"
MIG_HEAD="unavailable"
CONTAINERS="unavailable (SSH nedostupan)"
if CONTAINER=$(detect_db_container 2>/dev/null); then
  echo "→ čitam live migration head ($CONTAINER) ..." >&2
  if MIG_RAW=$(ssh_remote "docker exec -i $CONTAINER psql -U $COOLIFY_DB_USER -d $COOLIFY_DB_NAME -t -A -v ON_ERROR_STOP=1 -c \"select version || '  ' || coalesce(name,'') from supabase_migrations.schema_migrations order by version;\"" 2>/dev/null); then
    MIG_LIST=$(printf '%s\n' "$MIG_RAW" | sed '/^$/d')
    MIG_COUNT=$(printf '%s\n' "$MIG_LIST" | grep -c . || true)
    MIG_HEAD=$(printf '%s\n' "$MIG_LIST" | tail -1)
  fi
  echo "→ čitam live container images ..." >&2
  if CON_RAW=$(ssh_remote "docker ps --filter name=supabase- --format '{{.Names}}|{{.Image}}|{{.Status}}' | sort" 2>/dev/null); then
    [ -n "$CON_RAW" ] && CONTAINERS="$CON_RAW"
  fi
fi

# ----- edge funkcije iz repo-a ----------------------------------------------
FUNCS=$(ls -1 "$REPO_ROOT/supabase/functions" 2>/dev/null | sed 's/^/- /' || echo "(none)")

# ----- sastavi milestone -----------------------------------------------------
MILESTONE_FILE="$DEPLOYS_DIR/${TS_COMPACT}-${SHORT}.md"
render() {
  cat <<EOF
# Deploy $NOW · \`$SHORT\`

| polje | vrijednost |
|-------|------------|
| timestamp (UTC) | $NOW |
| commit | [\`$SHORT\`]($COMMIT_URL) — \`$SHA\` |
| branch | $BRANCH |
| subject | $SUBJECT |
| pushan na origin | $PUSHED |
| working tree | $TREE |
| operator | $OPERATOR |
| ops-verify | **$OPS_RESULT** |
| note | ${NOTE:-—} |

## Migracije (live \`supabase_migrations.schema_migrations\`)

count: **$MIG_COUNT** · head: \`$MIG_HEAD\`

\`\`\`
$MIG_LIST
\`\`\`

## Edge funkcije (\`supabase/functions/\`)

$FUNCS

## Containeri (live \`docker ps\` · supabase-*)

\`\`\`
$CONTAINERS
\`\`\`
EOF
}

if $DRY_RUN; then
  echo "── milestone (dry-run, ništa nije zapisano) → $MILESTONE_FILE ──"
  render
  exit 0
fi

mkdir -p "$DEPLOYS_DIR"
render > "$MILESTONE_FILE"
echo "✅ milestone: deploys/$(basename "$MILESTONE_FILE")" >&2

# ----- INDEX.md (append-only, najnoviji na vrhu) -----------------------------
INDEX="$DEPLOYS_DIR/INDEX.md"
LINE="- \`$NOW\` · [\`$SHORT\`]($(basename "$MILESTONE_FILE")) · $BRANCH · ops:**$OPS_RESULT** · $SUBJECT"
if [ ! -f "$INDEX" ]; then
  cat > "$INDEX" <<EOF
# Deploy journal — INDEX

Najnoviji deploy na vrhu. Svaki red linka na neovisan milestone (pun snapshot).
Regresija: \`git diff\` dva milestone fajla pokazuje delta migracija / image-a / funkcija.
Vidi [README.md](README.md).

$LINE
EOF
else
  # umetni novi red odmah ispod heading bloka (prvi red koji počinje s "- ")
  tmp=$(mktemp)
  inserted=false
  while IFS= read -r l; do
    if ! $inserted && [[ "$l" == "- "* ]]; then
      printf '%s\n%s\n' "$LINE" "$l" >> "$tmp"; inserted=true
    else
      printf '%s\n' "$l" >> "$tmp"
    fi
  done < "$INDEX"
  $inserted || printf '%s\n' "$LINE" >> "$tmp"   # fallback: nije bilo ranijih redaka
  mv "$tmp" "$INDEX"
fi
echo "✅ INDEX azuriran: deploys/INDEX.md" >&2

# ----- git commit (opcionalno) ----------------------------------------------
if $DO_COMMIT; then
  git add "$MILESTONE_FILE" "$INDEX"
  git commit -q -m "chore(deploy): journal milestone $SHORT ($NOW, ops:$OPS_RESULT)" \
    -m "Neovisan deploy snapshot za regresiju. Subject deploya: $SUBJECT" \
    && echo "✅ commitan milestone ($(git rev-parse --short HEAD))" >&2
fi
