#!/usr/bin/env bash
# rotate-apple-secret.sh — rotira Apple "Sign in with Apple" client secret (ES256 JWT)
# kad se približi isteku, pusha ga na Coolify i re-deploya Supabase stack.
#
# Zašto postoji: Apple capa secret na ~6 mjeseci (NE može biti trajan), a
# self-hosted GoTrue ga ne refresha sam. Ovo je LOKALNA automatizacija jer
# treba .p8 ključ koji živi samo na ovom Macu (~/secrets/) — namjerno NE na
# serveru. Pokreće je launchd mjesečno; vidi docs/apple-secret-rotation.md.
#
# Modovi:
#   (default)   rotiraj SAMO ako current secret istječe za < THRESHOLD_DAYS dana
#   --check     samo ispiši preostale dane do isteka, ništa ne mijenjaj
#   --force     rotiraj bez obzira na preostalo vrijeme
#
# Čita iz .local-secrets.env: APPLE_P8_PATH, APPLE_TEAM_ID, APPLE_KEY_ID,
#   APPLE_CLIENT_ID (Services ID), GOTRUE_EXTERNAL_APPLE_SECRET (trenutni),
#   COOLIFY_* (za apply + restart). Opcionalno: THRESHOLD_DAYS (def 30),
#   NODE_BIN (def: command -v node — launchd ga prosljeđuje eksplicitno).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="auto"
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    --force) MODE="force" ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $a" >&2; exit 2 ;;
  esac
done

SECRETS_FILE="$REPO_ROOT/.local-secrets.env"
[ -f "$SECRETS_FILE" ] || { echo "❌ $SECRETS_FILE ne postoji"; exit 1; }

set -a
# shellcheck source=/dev/null
. "$SECRETS_FILE"
set +a

THRESHOLD_DAYS="${THRESHOLD_DAYS:-30}"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { echo "❌ node nije nađen (postavi NODE_BIN u env/launchd)"; exit 1; }

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Preostali dani do isteka danog JWT-a (čita exp claim). Token ide kroz env (S=)
# da se ne pojavi u argv/ps.
jwt_remaining_days() {
  S="$1" "$NODE_BIN" -e '
    try {
      const seg = process.env.S.split(".")[1].replace(/-/g,"+").replace(/_/g,"/");
      const p = JSON.parse(Buffer.from(seg, "base64").toString());
      console.log(Math.floor((p.exp - Date.now()/1000) / 86400));
    } catch (e) { console.log(-1); }
  '
}

DAYS="$(jwt_remaining_days "${GOTRUE_EXTERNAL_APPLE_SECRET:-}")"
log "Apple client secret istječe za ${DAYS} dana (threshold ${THRESHOLD_DAYS}, mode ${MODE})"

[ "$MODE" = "check" ] && exit 0

if [ "$MODE" != "force" ] && [ "$DAYS" -gt "$THRESHOLD_DAYS" ]; then
  log "Iznad thresholda — ništa za rotirati. Izlazim."
  exit 0
fi

log "Generiram novi Apple client secret JWT (iz ${APPLE_P8_PATH})..."
NEW_JWT="$("$NODE_BIN" "$SCRIPT_DIR/gen-apple-secret.mjs" 2>/dev/null || true)"
[ -n "$NEW_JWT" ] || { log "❌ Generiranje JWT-a nije uspjelo (provjeri APPLE_* + .p8)"; exit 1; }

# Atomic zamjena GOTRUE_EXTERNAL_APPLE_SECRET linije u .local-secrets.env.
TMP="$(mktemp)"
grep -v '^GOTRUE_EXTERNAL_APPLE_SECRET=' "$SECRETS_FILE" > "$TMP"
printf 'GOTRUE_EXTERNAL_APPLE_SECRET=%s\n' "$NEW_JWT" >> "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$SECRETS_FILE"
log "Novi secret upisan u .local-secrets.env"

# Push samo SECRET ključa na Coolify (upsert) + full-stack re-deploy.
EXTRA="$REPO_ROOT/.coolify-extra.env"
printf 'GOTRUE_EXTERNAL_APPLE_SECRET=%s\n' "$NEW_JWT" > "$EXTRA"
chmod 600 "$EXTRA"
log "Apply na Coolify..."
"$SCRIPT_DIR/coolify-env-apply.sh" --file="$EXTRA" -y
rm -f "$EXTRA"
log "Re-deploy Supabase stacka (~2-3 min downtime)..."
"$SCRIPT_DIR/coolify-restart.sh" -y

log "Smoke test — čekam da auth oživi (authorize → 302)..."
ok=0
for i in $(seq 1 20); do
  sleep 12
  code="$(curl -s -o /dev/null -w '%{http_code}' 'https://api.domovina.ai/auth/v1/authorize?provider=apple' || echo 000)"
  if [ "$code" = "302" ]; then ok=1; log "✅ authorize → 302 nakon ~$((i*12))s"; break; fi
done
[ "$ok" = "1" ] || { log "⚠️ authorize nije vratio 302 — provjeri ručno: curl .../authorize?provider=apple"; exit 1; }

NEWDAYS="$(jwt_remaining_days "$NEW_JWT")"
log "✅ Rotacija gotova. Novi secret vrijedi još ${NEWDAYS} dana."
