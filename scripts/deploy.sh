#!/usr/bin/env bash
# deploy.sh — orkestrira cijeli deploy krug (jedan ulaz).
#
# Krug:
#   1. preflight: working tree čist? HEAD pushan? (upozori)
#   2. stamp-deploy.sh     — upiše DEPLOY_GIT_* u Coolify env (koji commit se deploya)
#   3. deploy-functions.sh — sinkronizira supabase/functions/ → edge volume (+ restart edge)
#   4. [--full-redeploy]   — coolify-restart.sh (restart cijelog stacka; treba ako su se
#                            mijenjale app-env vrijednosti da dođu do containera)
#   5. ops-verify.sh       — health (containeri + auth/rest/edge probe-ovi)
#   6. deploy-journal.sh   — zapiše neovisan deploy milestone (deploys/) + commit
#
# Guardrail: confirm na početku (osim -y). Edge restart je par sekundi; --full-redeploy
# ruši cijeli stack nakratko (potvrdi zasebno).
#
# Usage:
#   ./scripts/deploy.sh                 # cijeli krug (confirm)
#   ./scripts/deploy.sh -y              # bez prompta
#   ./scripts/deploy.sh --dry-run       # ništa live; pokaži plan + ops-verify
#   ./scripts/deploy.sh --full-redeploy # + restart cijelog stacka
#   ./scripts/deploy.sh --skip-functions
#   ./scripts/deploy.sh --no-journal    # preskoči zapis milestone-a

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AUTO_YES=false
DRY_RUN=false
FULL_REDEPLOY=false
SKIP_FUNCTIONS=false
NO_JOURNAL=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes)          AUTO_YES=true ;;
    --dry-run)         DRY_RUN=true ;;
    --full-redeploy)   FULL_REDEPLOY=true ;;
    --skip-functions)  SKIP_FUNCTIONS=true ;;
    --no-journal)      NO_JOURNAL=true ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

echo "═══ deploy krug ═══"
# 1. preflight
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
SHORT=$(git rev-parse --short HEAD)
[ "$DIRTY" != "0" ] && echo "⚠️  working tree ima $DIRTY necommitanih promjena (deploy ide po HEAD-u $SHORT)."
if git branch -r --contains HEAD 2>/dev/null | grep -q 'origin/'; then
  echo "→ HEAD $SHORT je na origin ✓"
else
  echo "⚠️  HEAD $SHORT NIJE pushan — GitHub commit URL se neće resolvati."
fi

if $DRY_RUN; then
  echo "── dry-run ──"
  "$SCRIPT_DIR/stamp-deploy.sh" --dry-run --allow-unpushed || true
  $SKIP_FUNCTIONS || "$SCRIPT_DIR/deploy-functions.sh" --dry-run || true
  echo "── ops-verify (trenutno stanje) ──"
  "$SCRIPT_DIR/ops-verify.sh" || true
  exit 0
fi

if ! $AUTO_YES; then
  echo ""
  read -rp "Pokrenuti deploy krug na live? [y/N] " ans
  [[ "$ans" == [yY]* ]] || { echo "Cancelled."; exit 0; }
fi

# 2. stamp
echo ""; echo "── [1/4] stamp-deploy ──"
"$SCRIPT_DIR/stamp-deploy.sh" -y

# 3. functions
if ! $SKIP_FUNCTIONS; then
  echo ""; echo "── [2/4] deploy-functions (+restart edge) ──"
  "$SCRIPT_DIR/deploy-functions.sh" --restart -y
fi

# 4. full redeploy (opcionalno)
if $FULL_REDEPLOY; then
  echo ""; echo "── [3/4] full stack restart ──"
  "$SCRIPT_DIR/coolify-restart.sh" -y
  # Stack se vraća ~2-3 min — čekaj da core containeri budu Up prije verify-a
  # (inače ops-verify lažno padne). Poll do 5 min.
  # shellcheck source=lib/db-env.sh
  . "$SCRIPT_DIR/lib/db-env.sh"
  echo "→ čekam povratak stacka (core: kong/rest/auth/db, max ~5 min)..."
  for _ in $(seq 1 30); do
    sleep 10
    UP=$(ssh_remote "docker ps --format '{{.Names}} {{.Status}}' | grep -E '^supabase-(kong|rest|auth|db)-' | grep -c Up" 2>/dev/null || true); UP=${UP:-0}
    if [ "$UP" = "4" ]; then echo "   core up (4/4)"; sleep 5; break; fi
    echo "   ... ($UP/4 core up)"
  done
else
  echo ""; echo "── [3/4] full stack restart preskočen (--full-redeploy za to) ──"
fi

# 5. verify (uhvati rezultat — NE aborta-j, da se i neuspješan deploy zapiše)
echo ""; echo "── [4/5] ops-verify ──"
if "$SCRIPT_DIR/ops-verify.sh"; then OPS_RESULT=PASS; else OPS_RESULT=FAIL; fi

# 6. journal — neovisan deploy milestone za regresiju
if ! $NO_JOURNAL; then
  echo ""; echo "── [5/5] deploy-journal ──"
  "$SCRIPT_DIR/deploy-journal.sh" --ops-result "$OPS_RESULT" --commit || \
    echo "⚠️  journaling nije uspio (deploy sam je OK; zapiši ručno: ./scripts/deploy-journal.sh)."
else
  echo ""; echo "── [5/5] deploy-journal preskočen (--no-journal) ──"
fi

echo ""
if [ "$OPS_RESULT" = PASS ]; then
  echo "✅ deploy krug gotov (commit $SHORT, ops:PASS)."
else
  echo "⚠️  deploy krug gotov ALI ops-verify=FAIL (commit $SHORT) — vidi milestone u deploys/."
  exit 1
fi
