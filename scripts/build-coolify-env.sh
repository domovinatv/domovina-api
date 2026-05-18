#!/usr/bin/env bash
# build-coolify-env.sh
#
# Workflow:
#   1) Napravi fresh Supabase service u Coolifyju (Coolify auto-generira sve env vars).
#   2) U Environment Variables → Developer view → kopiraj sve → spremi u
#      .coolify-defaults.env (lokalno u repo root-u, gitignored).
#   3) U .local-secrets.env (kopiraj iz .local-secrets.env.example) stavi
#      SMTP_PASS (Resend API key) i ostale vanjske secrete.
#   4) Pokreni ovu skriptu — generira sve secrets fresh, applya overrides,
#      mergea s Coolify defaultima, kopira finalni env u clipboard.
#   5) U Coolifyju → Bulk edit → Cmd+A → Paste → Save → Deploy.
#
# Što skripta radi (redoslijed merge-a, kasniji prepisuju ranije):
#   layer 1: .coolify-defaults.env       — Coolify-generated structure
#   layer 2: HARDCODED config overrides  — api.domovina.ai, SSO, Studio brand, ...
#   layer 3: FRESH generated secrets     — sve SERVICE_PASSWORD_*, JWTs, SECRET_KEY_BASE
#   layer 4: .local-secrets.env          — SMTP_PASS, OPENAI_API_KEY, ...
#
# Output:
#   - Clipboard (pbcopy / xclip / wl-copy)
#   - Masked preview na stdout (nikad pun secret)
#   - Nikad ne piše secrets na disk osim u memtemp koji se odmah briše
#
# Usage:
#   ./scripts/build-coolify-env.sh
#   ./scripts/build-coolify-env.sh --defaults=path/to/coolify.env
#   ./scripts/build-coolify-env.sh --secrets=path/to/secrets.env
#   ./scripts/build-coolify-env.sh --no-copy --preview     # samo stdout
#
# Requirements: bash 3.2+, openssl, awk, pbcopy/xclip/wl-copy.

set -euo pipefail

# ---- args -------------------------------------------------------------------
DEFAULTS_FILE=".coolify-defaults.env"
SECRETS_FILE=".local-secrets.env"
COPY=true
PREVIEW=false

for arg in "$@"; do
  case "$arg" in
    --defaults=*) DEFAULTS_FILE="${arg#*=}" ;;
    --secrets=*)  SECRETS_FILE="${arg#*=}" ;;
    --no-copy)    COPY=false ;;
    --preview)    PREVIEW=true ;;
    -h|--help)    sed -n '2,38p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- preflight --------------------------------------------------------------
if [ ! -f "$DEFAULTS_FILE" ]; then
  cat >&2 <<EOF
❌ '$DEFAULTS_FILE' ne postoji.

Korak: u Coolifyju otvori (svježe kreiran) Supabase service → Environment
Variables → Developer view → kopiraj sve KEY=VALUE redove i spremi ovdje:

  $(pwd)/$DEFAULTS_FILE

(File je gitignored — neće završiti u repo-u.)
EOF
  exit 1
fi

if [ ! -f "$SECRETS_FILE" ]; then
  cat >&2 <<EOF
⚠️  '$SECRETS_FILE' ne postoji. Kreiram s placeholderom — nastavit ću,
ali SMTP_PASS će ostati prazan u clipboardu (GoTrue mail neće slati).

Kopiraj template:  cp .local-secrets.env.example $SECRETS_FILE
Popuni SMTP_PASS (Resend API key) i ponovo pokreni skriptu.
EOF
  SECRETS_FILE="/dev/null"
fi

# ---- helpers ----------------------------------------------------------------
gen_alnum() {
  local len=$1
  openssl rand -base64 $(( len * 2 + 16 )) | tr -d '/+=\n' | cut -c1-"$len"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

make_jwt() {
  local role=$1 secret=$2 now exp h p s
  now=$(date +%s)
  exp=$(( now + 100 * 365 * 86400 ))
  h=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  p=$(printf '%s' "{\"iss\":\"supabase\",\"iat\":${now},\"exp\":${exp},\"role\":\"${role}\"}" | b64url)
  s=$(printf '%s' "${h}.${p}" \
      | openssl dgst -sha256 -mac HMAC -macopt "key:${secret}" -binary \
      | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

mask() {
  local v=$1 n=${#1}
  if [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s****%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

# ---- temp workspace ---------------------------------------------------------
WORK=$(mktemp -d -t domovina-env.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# ---- generate fresh secrets -------------------------------------------------
JWT_SECRET=$(gen_alnum 32)
PG_PASS=$(gen_alnum 32)
PGMETA=$(gen_alnum 32)
LOGFLARE=$(gen_alnum 32)
LOGFLARE_PRIV=$(gen_alnum 32)
MINIO_PASS=$(gen_alnum 32)
SUPAVISOR=$(gen_alnum 64)        # SECRET_KEY_BASE za Supavisor (Phoenix) traži ≥64 chars
REALTIME_SECRET=$(gen_alnum 64)  # SECRET_KEY_BASE za Realtime (Phoenix) traži ≥64 chars
VAULT_ENC=$(gen_alnum 32)
ADMIN_PASS=$(gen_alnum 32)
ADMIN_USER=$(gen_alnum 16)
MINIO_USER=$(gen_alnum 16)
ANON_JWT=$(make_jwt anon "$JWT_SECRET")
SERVICE_JWT=$(make_jwt service_role "$JWT_SECRET")

# ---- layer 2: hardcoded config + layer 3: fresh secrets ---------------------
cat > "$WORK/overrides.env" <<EOF
# --- public endpoints ---
SERVICE_FQDN_SUPABASEKONG=api.domovina.ai
SERVICE_FQDN_SUPABASEKONG_8000=api.domovina.ai
SERVICE_URL_SUPABASEKONG=https://api.domovina.ai
SERVICE_URL_SUPABASEKONG_8000=https://api.domovina.ai
SUPABASE_PUBLIC_URL=https://api.domovina.ai
API_EXTERNAL_URL=https://api.domovina.ai
STORAGE_PUBLIC_URL=https://api.domovina.ai
NEXT_PUBLIC_SUPABASE_URL=https://api.domovina.ai

# --- GoTrue SSO ---
GOTRUE_SITE_URL=https://domovina.ai
ADDITIONAL_REDIRECT_URLS=https://domovina.ai/**,https://www.domovina.ai/**,https://domovina.energy/**,https://www.domovina.energy/**,https://domovina.tv/**,https://www.domovina.tv/**,http://localhost:3000/**,http://localhost:5173/**
JWT_EXPIRY=3600
DISABLE_SIGNUP=false
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# --- Studio brand ---
STUDIO_DEFAULT_ORGANIZATION=Domovina
STUDIO_DEFAULT_PROJECT=domovina-api
POOLER_TENANT_ID=domovina

# --- SMTP defaults (SMTP_PASS dolazi iz .local-secrets.env) ---
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_ADMIN_EMAIL=noreply@domovina.ai
SMTP_SENDER_NAME=Domovina

# --- FRESH SECRETS (rotated $(date -u +'%Y-%m-%dT%H:%M:%SZ')) ---
SERVICE_PASSWORD_JWT=${JWT_SECRET}
SERVICE_PASSWORD_POSTGRES=${PG_PASS}
SERVICE_PASSWORD_PGMETACRYPTO=${PGMETA}
SERVICE_PASSWORD_LOGFLARE=${LOGFLARE}
SERVICE_PASSWORD_LOGFLAREPRIVATE=${LOGFLARE_PRIV}
SERVICE_PASSWORD_MINIO=${MINIO_PASS}
SERVICE_PASSWORD_SUPAVISORSECRET=${SUPAVISOR}
SERVICE_PASSWORD_VAULTENC=${VAULT_ENC}
SERVICE_PASSWORD_ADMIN=${ADMIN_PASS}
SERVICE_USER_ADMIN=${ADMIN_USER}
SERVICE_USER_MINIO=${MINIO_USER}
SERVICE_SUPABASEANON_KEY=${ANON_JWT}
SERVICE_SUPABASESERVICE_KEY=${SERVICE_JWT}
SECRET_PASSWORD_REALTIME=${REALTIME_SECRET}
EOF

# ---- merge: defaults → overrides → secrets (later wins) ---------------------
# awk: za svaki KEY=VAL red, držimo zadnju vrijednost; redoslijed = prvi
# put gdje smo vidjeli ključ.
awk -F= '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    sub(/\r$/, "")
    key = $1
    val = substr($0, length(key) + 2)
    if (!(key in seen)) { order[++n] = key; seen[key] = 1 }
    map[key] = val
  }
  END {
    for (i = 1; i <= n; i++) {
      if (map[order[i]] != "") print order[i] "=" map[order[i]]
      else print order[i] "="
    }
  }
' "$DEFAULTS_FILE" "$WORK/overrides.env" "$SECRETS_FILE" > "$WORK/final.env"

# ---- prepend header ---------------------------------------------------------
{
  cat <<HEADER
# =============================================================================
# DOMOVINA-API — Coolify Supabase ENV (built $(date -u +'%Y-%m-%dT%H:%M:%SZ'))
# Generated by scripts/build-coolify-env.sh — NEVER edit in Coolify by hand,
# always rebuild from defaults + local secrets.
# =============================================================================
HEADER
  cat "$WORK/final.env"
} > "$WORK/final-with-header.env"
mv "$WORK/final-with-header.env" "$WORK/final.env"

LINES=$(wc -l < "$WORK/final.env" | tr -d ' ')
BYTES=$(wc -c < "$WORK/final.env" | tr -d ' ')

# ---- output -----------------------------------------------------------------
if $COPY; then
  if   command -v pbcopy  >/dev/null; then pbcopy   < "$WORK/final.env"; CB="pbcopy"
  elif command -v xclip   >/dev/null; then xclip -selection clipboard < "$WORK/final.env"; CB="xclip"
  elif command -v wl-copy >/dev/null; then wl-copy  < "$WORK/final.env"; CB="wl-copy"
  else echo "⚠️  No clipboard utility (pbcopy/xclip/wl-copy)"; COPY=false
  fi
fi

if $COPY; then
  echo "✅ Copied to clipboard via $CB"
fi
echo "   sources: $DEFAULTS_FILE + overrides + $SECRETS_FILE"
echo "   output:  $LINES linija, $BYTES bytes"
echo
echo "Masked preview (fresh secrets only):"
echo "  JWT_SECRET           = $(mask "$JWT_SECRET")"
echo "  POSTGRES_PASSWORD    = $(mask "$PG_PASS")"
echo "  ANON_KEY             = $(mask "$ANON_JWT")"
echo "  SERVICE_ROLE_KEY     = $(mask "$SERVICE_JWT")"
echo "  SUPAVISOR_SECRET     = $(mask "$SUPAVISOR")"
echo "  REALTIME_SECRET      = $(mask "$REALTIME_SECRET")"
echo "  ADMIN_USER / PASS    = $(mask "$ADMIN_USER") / $(mask "$ADMIN_PASS")"
echo "  MINIO_USER / PASS    = $(mask "$MINIO_USER") / $(mask "$MINIO_PASS")"

# SMTP_PASS warning
SMTP_VAL=$(awk -F= '/^SMTP_PASS=/{val=substr($0,11); print val}' "$WORK/final.env")
if [ -z "$SMTP_VAL" ]; then
  echo
  echo "⚠️  SMTP_PASS je prazan — GoTrue mail neće slati."
  echo "    Popuni '$SECRETS_FILE' i pokreni skriptu ponovno."
else
  echo "  SMTP_PASS            = $(mask "$SMTP_VAL")"
fi

echo
echo "Next steps:"
echo "  1. Coolify → Environment Variables → Developer view → Cmd+A → Paste → Save"
echo "  2. Deploy"

if $PREVIEW; then
  echo
  echo "--- Full env (NOT for redistribution) ---"
  cat "$WORK/final.env"
fi
