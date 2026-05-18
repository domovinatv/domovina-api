#!/usr/bin/env bash
# generate-coolify-secrets.sh
#
# Offline generira sve secrets za domovina-api (Coolify Supabase deployment)
# i kopira ih u clipboard za direktan paste u Coolify Environment Variables.
#
# NIKAD ne piše secrets na disk niti ih echo-a na stdout (osim maskiranih
# preview-a). Sve ide kroz memorijski temp file koji se brise nakon pbcopy.
#
# Usage:
#   ./scripts/generate-coolify-secrets.sh                 # full rotate, sve nove
#   ./scripts/generate-coolify-secrets.sh --preview       # stdout maskiran preview
#   ./scripts/generate-coolify-secrets.sh --no-copy       # ne stavlja u clipboard
#
# Što generira:
#   - SERVICE_PASSWORD_JWT          (32 char alphanumeric)
#   - SERVICE_PASSWORD_POSTGRES     (32 char alphanumeric)
#   - SERVICE_PASSWORD_PGMETACRYPTO (32 char alphanumeric)
#   - SERVICE_PASSWORD_LOGFLARE     (32 char alphanumeric)
#   - SERVICE_PASSWORD_LOGFLAREPRIVATE (32 char alphanumeric)
#   - SERVICE_PASSWORD_MINIO        (32 char alphanumeric)
#   - SERVICE_PASSWORD_SUPAVISORSECRET (32 char alphanumeric)
#   - SERVICE_PASSWORD_VAULTENC     (32 char alphanumeric)
#   - SERVICE_PASSWORD_ADMIN        (32 char alphanumeric)
#   - SERVICE_USER_ADMIN            (16 char alphanumeric)
#   - SERVICE_USER_MINIO            (16 char alphanumeric)
#   - SERVICE_SUPABASEANON_KEY      (HS256 JWT, role=anon, iss=supabase, 100y exp)
#   - SERVICE_SUPABASESERVICE_KEY   (HS256 JWT, role=service_role, iss=supabase, 100y exp)
#   - SECRET_KEY_BASE               (64 hex chars za Supavisor Phoenix)
#
# Što NE generira (postavi rucno u Coolify):
#   - SMTP_PASS (Resend API key — regenerate u Resend dashboardu)
#   - OPENAI_API_KEY (ako koristis)
#
# Requirements: bash, openssl, base64, head, tr; pbcopy (macOS) / xclip (Linux)

set -euo pipefail

PREVIEW=false
NO_COPY=false
for arg in "$@"; do
  case "$arg" in
    --preview) PREVIEW=true ;;
    --no-copy) NO_COPY=true ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- helpers ----------------------------------------------------------------

# alphanumeric password generator (no special chars — Coolify env friendly)
# Avoids SIGPIPE from `head -c` under `set -o pipefail` by using openssl directly.
gen_alnum() {
  local len=$1
  # base64 produces ~4 chars per 3 bytes; ask for ~2x len bytes to be safe after
  # stripping non-alnum. Then cut to exact length with `cut -c` (no SIGPIPE).
  openssl rand -base64 $(( len * 2 + 16 )) | tr -d '/+=\n' | cut -c1-"$len"
}

# base64url (no padding, +/ -> -_)
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# HS256 JWT given role and secret
make_jwt() {
  local role=$1 secret=$2
  local now exp header payload sig
  now=$(date +%s)
  exp=$(( now + 100 * 365 * 86400 ))   # 100 godina
  header=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  payload=$(printf '%s' "{\"iss\":\"supabase\",\"iat\":${now},\"exp\":${exp},\"role\":\"${role}\"}" | b64url)
  sig=$(printf '%s' "${header}.${payload}" \
        | openssl dgst -sha256 -mac HMAC -macopt "key:${secret}" -binary \
        | b64url)
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}

mask() {
  local v=$1 n=${#1}
  if [ "$n" -le 8 ]; then printf '%*s' "$n" '' | tr ' ' '*'
  else printf '%s****%s (len=%d)' "${v:0:4}" "${v: -4}" "$n"
  fi
}

# ---- generate ---------------------------------------------------------------

JWT_SECRET=$(gen_alnum 32)
PG_PASS=$(gen_alnum 32)
PGMETA_KEY=$(gen_alnum 32)
LOGFLARE_KEY=$(gen_alnum 32)
LOGFLARE_PRIV=$(gen_alnum 32)
MINIO_PASS=$(gen_alnum 32)
SUPAVISOR_SECRET=$(gen_alnum 32)
VAULT_ENC=$(gen_alnum 32)
ADMIN_PASS=$(gen_alnum 32)
ADMIN_USER=$(gen_alnum 16)
MINIO_USER=$(gen_alnum 16)
SECRET_KEY_BASE=$(openssl rand -hex 32)

ANON_JWT=$(make_jwt anon "$JWT_SECRET")
SERVICE_JWT=$(make_jwt service_role "$JWT_SECRET")

# ---- compose output ---------------------------------------------------------

TMP=$(mktemp -t domovina-coolify-env.XXXXXX)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<EOF
# =============================================================================
# DOMOVINA-API — Coolify Supabase ENV (rotated $(date -u +'%Y-%m-%dT%H:%M:%SZ'))
# Paste preko Bulk edit / Developer view i klikni Save.
# =============================================================================

# === Public endpoints (Cloudflare Tunnel → Traefik → kong) ===
SERVICE_FQDN_SUPABASEKONG=api.domovina.ai
SERVICE_FQDN_SUPABASEKONG_8000=api.domovina.ai
SERVICE_URL_SUPABASEKONG=https://api.domovina.ai
SERVICE_URL_SUPABASEKONG_8000=https://api.domovina.ai
SUPABASE_PUBLIC_URL=https://api.domovina.ai
API_EXTERNAL_URL=https://api.domovina.ai
STORAGE_PUBLIC_URL=https://api.domovina.ai
NEXT_PUBLIC_SUPABASE_URL=https://api.domovina.ai

# === SECRETS (fresh, rotated) ===
SERVICE_PASSWORD_JWT=${JWT_SECRET}
SERVICE_PASSWORD_POSTGRES=${PG_PASS}
SERVICE_PASSWORD_PGMETACRYPTO=${PGMETA_KEY}
SERVICE_PASSWORD_LOGFLARE=${LOGFLARE_KEY}
SERVICE_PASSWORD_LOGFLAREPRIVATE=${LOGFLARE_PRIV}
SERVICE_PASSWORD_MINIO=${MINIO_PASS}
SERVICE_PASSWORD_SUPAVISORSECRET=${SUPAVISOR_SECRET}
SERVICE_PASSWORD_VAULTENC=${VAULT_ENC}
SERVICE_PASSWORD_ADMIN=${ADMIN_PASS}
SERVICE_USER_ADMIN=${ADMIN_USER}
SERVICE_USER_MINIO=${MINIO_USER}
SERVICE_SUPABASEANON_KEY=${ANON_JWT}
SERVICE_SUPABASESERVICE_KEY=${SERVICE_JWT}

# === Postgres ===
POSTGRES_PASSWORD=\${SERVICE_PASSWORD_POSTGRES}
POSTGRES_HOST=supabase-db
POSTGRES_HOSTNAME=supabase-db
POSTGRES_PORT=5432
POSTGRES_DB=postgres
PGPASSWORD=\${SERVICE_PASSWORD_POSTGRES}
DB_PASSWORD=\${SERVICE_PASSWORD_POSTGRES}

# === PostgREST ===
PGRST_DB_SCHEMAS=public,storage,graphql_public
PGRST_DB_MAX_ROWS=1000
PGRST_DB_EXTRA_SEARCH_PATH=public
PGRST_JWT_SECRET=\${SERVICE_PASSWORD_JWT}
PGRST_APP_SETTINGS_JWT_SECRET=\${SERVICE_PASSWORD_JWT}

# === GoTrue (Auth) — SSO multi-app ===
GOTRUE_SITE_URL=https://domovina.ai
ADDITIONAL_REDIRECT_URLS=https://domovina.ai/**,https://www.domovina.ai/**,https://domovina.energy/**,https://www.domovina.energy/**,https://domovina.tv/**,https://www.domovina.tv/**,http://localhost:3000/**,http://localhost:5173/**
GOTRUE_JWT_SECRET=\${SERVICE_PASSWORD_JWT}
AUTH_JWT_SECRET=\${SERVICE_PASSWORD_JWT}
API_JWT_SECRET=\${SERVICE_PASSWORD_JWT}
METRICS_JWT_SECRET=\${SERVICE_PASSWORD_JWT}
JWT_SECRET=\${SERVICE_PASSWORD_JWT}
JWT_EXPIRY=3600

DISABLE_SIGNUP=false
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# === Anon / Service Role keys (aliases) ===
ANON_KEY=\${SERVICE_SUPABASEANON_KEY}
SERVICE_KEY=\${SERVICE_SUPABASESERVICE_KEY}
SUPABASE_ANON_KEY=\${SERVICE_SUPABASEANON_KEY}
SUPABASE_SERVICE_KEY=\${SERVICE_SUPABASESERVICE_KEY}
SUPABASE_SERVICE_ROLE_KEY=\${SERVICE_SUPABASESERVICE_KEY}
NEXT_PUBLIC_SUPABASE_ANON_KEY=\${SERVICE_SUPABASEANON_KEY}
SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SECRET_KEY=
ANON_KEY_ASYMMETRIC=
SERVICE_ROLE_KEY_ASYMMETRIC=

# === Studio ===
STUDIO_DEFAULT_ORGANIZATION=Domovina
STUDIO_DEFAULT_PROJECT=domovina-api
DASHBOARD_USERNAME=\${SERVICE_USER_ADMIN}
DASHBOARD_PASSWORD=\${SERVICE_PASSWORD_ADMIN}

# === pg-meta ===
PG_META_CRYPTO_KEY=\${SERVICE_PASSWORD_PGMETACRYPTO}
PG_META_DB_PASSWORD=\${SERVICE_PASSWORD_POSTGRES}
CRYPTO_KEY=\${SERVICE_PASSWORD_PGMETACRYPTO}

# === Logflare / Analytics ===
LOGFLARE_API_KEY=\${SERVICE_PASSWORD_LOGFLARE}
LOGFLARE_PUBLIC_ACCESS_TOKEN=\${SERVICE_PASSWORD_LOGFLARE}
LOGFLARE_PRIVATE_ACCESS_TOKEN=\${SERVICE_PASSWORD_LOGFLAREPRIVATE}

# === Storage / MinIO ===
MINIO_ROOT_USER=\${SERVICE_USER_MINIO}
MINIO_ROOT_PASSWORD=\${SERVICE_PASSWORD_MINIO}
AWS_ACCESS_KEY_ID=\${SERVICE_USER_MINIO}
AWS_SECRET_ACCESS_KEY=\${SERVICE_PASSWORD_MINIO}
STORAGE_TENANT_ID=storage-single-tenant
IMGPROXY_AUTO_WEBP=true

# === Supavisor pooler ===
POOLER_TENANT_ID=domovina
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_DB_POOL_SIZE=5
SECRET_KEY_BASE=${SECRET_KEY_BASE}
VAULT_ENC_KEY=\${SERVICE_PASSWORD_VAULTENC}

# === Edge Functions ===
FUNCTIONS_VERIFY_JWT=false

# === Kong storage tunables ===
KONG_STORAGE_CONNECT_TIMEOUT=60
KONG_STORAGE_WRITE_TIMEOUT=3600
KONG_STORAGE_READ_TIMEOUT=3600
KONG_STORAGE_REQUEST_BUFFERING=false
KONG_STORAGE_RESPONSE_BUFFERING=false

# === SMTP (Resend EU) — SMTP_PASS rotate-aj rucno u Resend dashboardu ===
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASS=<PASTE_RESEND_API_KEY_HERE>
SMTP_ADMIN_EMAIL=noreply@domovina.ai
SMTP_SENDER_NAME=Domovina

# Mailer paths
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify
MAILER_TEMPLATES_INVITE=
MAILER_TEMPLATES_CONFIRMATION=
MAILER_TEMPLATES_RECOVERY=
MAILER_TEMPLATES_MAGIC_LINK=
MAILER_TEMPLATES_EMAIL_CHANGE=
MAILER_SUBJECTS_CONFIRMATION=
MAILER_SUBJECTS_RECOVERY=
MAILER_SUBJECTS_MAGIC_LINK=
MAILER_SUBJECTS_EMAIL_CHANGE=
MAILER_SUBJECTS_INVITE=

# Realtime
SECRET_PASSWORD_REALTIME=

# Opcionalno
OPENAI_API_KEY=
EOF

# ---- output -----------------------------------------------------------------

LINES=$(wc -l < "$TMP" | tr -d ' ')
BYTES=$(wc -c < "$TMP" | tr -d ' ')

if ! $NO_COPY; then
  if command -v pbcopy >/dev/null; then
    pbcopy < "$TMP"
    echo "✅ Copied to clipboard via pbcopy (macOS)"
  elif command -v xclip >/dev/null; then
    xclip -selection clipboard < "$TMP"
    echo "✅ Copied to clipboard via xclip (Linux)"
  elif command -v wl-copy >/dev/null; then
    wl-copy < "$TMP"
    echo "✅ Copied to clipboard via wl-copy (Wayland)"
  else
    echo "⚠️  No clipboard utility found (pbcopy/xclip/wl-copy). Use --preview."
    NO_COPY=true
  fi
fi

echo "   $LINES linija, $BYTES bytes"
echo
echo "Masked preview:"
echo "  JWT_SECRET           = $(mask "$JWT_SECRET")"
echo "  POSTGRES_PASSWORD    = $(mask "$PG_PASS")"
echo "  ANON_KEY             = $(mask "$ANON_JWT")"
echo "  SERVICE_ROLE_KEY     = $(mask "$SERVICE_JWT")"
echo "  SECRET_KEY_BASE      = $(mask "$SECRET_KEY_BASE")"
echo "  ADMIN_USER / PASS    = $(mask "$ADMIN_USER") / $(mask "$ADMIN_PASS")"
echo "  MINIO_USER / PASS    = $(mask "$MINIO_USER") / $(mask "$MINIO_PASS")"
echo
echo "⚠️  ROTATE manually:"
echo "   - Resend API key (Settings → API Keys → revoke old, create new) → paste u SMTP_PASS"
echo "   - OPENAI_API_KEY (ako koristis)"
echo
if $PREVIEW; then
  echo "--- Full env (preview, NOT for copy) ---"
  cat "$TMP"
fi
