# Uptime monitoring — Uptime Kuma + cron healthcheck

**Cilj:** Alert kad `api.domovina.ai/auth/v1/health` padne ili response time skoči. Uptime Kuma već vrti na serveru (`uptime-kuma-*` container), iskorištavamo postojeću instancu.

---

## Strategija — dva sloja

**Layer 1: Uptime Kuma (HTTP monitor)** — vizualni dashboard, history, alerts.
**Layer 2: Cron healthcheck script** — backup ako Kuma sam padne (rare ali events).

---

## Layer 1 — Uptime Kuma setup

### 1. Open Kuma UI

Server-side Kuma već radi (vidio sam u `docker ps`: `uptime-kuma-jbmse51v8m8od4g61vkmuqsv9a570e50e5b1`). Pristupi preko Coolify deploy URL-a ili kroz SSH tunnel:

```bash
# SSH tunnel ako nema public URL:
ssh -L 3001:localhost:3001 -i ~/.ssh/dom-001-oracle-ssh-key-2026-04-20.key ubuntu@89.168.100.120
# Onda u browseru: http://localhost:3001
```

Ili tvoj postojeći Kuma URL (ako je exposao kroz Coolify FQDN).

### 2. Add Monitor — `/auth/v1/health`

Klikni **Add New Monitor**:

| Field | Value |
|---|---|
| Monitor Type | `HTTP(s) - Keyword` |
| Friendly Name | `Domovina API — auth health` |
| URL | `https://api.domovina.ai/auth/v1/health` |
| Heartbeat Interval | `60 seconds` |
| Retries | `2` |
| Heartbeat Retry Interval | `30 seconds` |
| Request Timeout | `10 seconds` |
| Method | `GET` |
| Body Encoding | `Header` |
| HTTP Headers (JSON) | `{"apikey": "<ANON_KEY>"}` |
| Keyword | `GoTrue` |
| Invert Keyword | OFF |
| Accept Status Codes | `200-299` |

**Save**.

Kuma sad pinga endpoint svakih 60s. Ako 2× zaredom fail (auth padne ili keyword "GoTrue" nestane) → alert.

### 3. Dodati još monitorova

| Monitor | URL | Keyword |
|---|---|---|
| REST root | `https://api.domovina.ai/rest/v1/?apikey=<ANON>` | `domovina_ai.watch_progress` |
| Studio | `https://studio.domovina.ai/` | (302 status check — koristi `HTTP(s)` ne keyword) |
| Cloudflare Tunnel ingress | `https://api.domovina.ai/auth/v1/health` (drugi region) | `GoTrue` |

### 4. Notification channels

Kuma → **Settings → Notifications → Setup notification**:

| Type | Config |
|---|---|
| **Email** | SMTP smtp.resend.com:465, user `resend`, pass `<SMTP_PASS>`, from `noreply@domovina.ai`, to `ms@domovina.tv` |
| **Telegram** (preporuka, instant) | Bot via `@BotFather`, chat ID kroz `@getidsbot` |
| **Slack webhook** (ako imaš Slack) | URL iz Slack app config |

Telegram je najbrži za 24/7 alerting. Setup 5 min:
1. Telegram → `@BotFather` → `/newbot` → ime `domovina_uptime_bot` → kopiraj token
2. Pošalji bot-u bilo koju poruku
3. `curl https://api.telegram.org/bot<TOKEN>/getUpdates` → kopiraj `chat.id`
4. U Kuma: Telegram → Token + Chat ID → Test → Save

Za svaki monitor → **Edit → Notifications tab** → uključi Telegram (ili koji god channel).

---

## Layer 2 — Cron healthcheck script (backup)

Kad Kuma sam padne, ostajemo slijepi. Cron na server koji svakih 5 min pinga + javlja na fail.

### Skripta

`scripts/server/healthcheck.sh` (deploy preko `install-cron.sh`):

```bash
#!/usr/bin/env bash
set -euo pipefail

ANON=$(docker inspect "$(docker ps --format '{{.Names}}' | grep '^supabase-rest-' | head -1)" \
  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep ^ANON_KEY= | sed 's/^ANON_KEY=//')

STATE_FILE=/var/lib/domovina-healthcheck.state

check_endpoint() {
  local name=$1 url=$2 keyword=$3
  local body
  body=$(curl -s -m 10 -H "apikey: $ANON" "$url" 2>/dev/null || echo "")
  if echo "$body" | grep -q "$keyword"; then
    echo "ok"
  else
    echo "fail"
  fi
}

result_auth=$(check_endpoint "auth" "https://api.domovina.ai/auth/v1/health" "GoTrue")
result_rest=$(check_endpoint "rest" "https://api.domovina.ai/rest/v1/" "swagger")

if [ "$result_auth" = "fail" ] || [ "$result_rest" = "fail" ]; then
  # Send Telegram alert (config in /etc/domovina-alert.env)
  source /etc/domovina-alert.env 2>/dev/null || true
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d "chat_id=$TG_CHAT_ID" \
      -d "text=🔴 Domovina API DOWN: auth=$result_auth rest=$result_rest"
  fi
  date > "$STATE_FILE.fail"
fi

# Recovery alert
if [ "$result_auth" = "ok" ] && [ "$result_rest" = "ok" ] && [ -f "$STATE_FILE.fail" ]; then
  rm -f "$STATE_FILE.fail"
  if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot$TG_BOT_TOKEN/sendMessage" \
      -d "chat_id=$TG_CHAT_ID" \
      -d "text=🟢 Domovina API recovered"
  fi
fi
```

### Cron

```
*/5 * * * * /opt/domovina-backup/healthcheck.sh
```

**Status:** treba implementirati kao zaseban task kada Kuma layer ne bude dovoljan.

---

## Tek za kasnije

- **Cloudflare Health Checks** (Pro plan): off-server monitoring, automatski origin failover
- **Per-service SLO dashboard** — Grafana + Loki + Prometheus stack, on top of Logflare koji već imamo u Supabase stack-u
- **Anomaly detection** — Logflare ima built-in, samo treba konfigurirati alert rules
