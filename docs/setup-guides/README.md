# Setup guides

Step-by-step upute za vanjske servise i konfiguracije koje treba ručno postaviti (ne mogu se automatizirati iz repo-a).

| Guide | Status | Time | Why |
|---|---|---|---|
| [google-oauth.md](google-oauth.md) | ⏳ Google Cloud Console setup needed | 5-7 min | M2 onboarding moment — link anonymous → permanent identity |
| [resend-domain.md](resend-domain.md) | ⏳ DNS records needed | 5 min | Email magic link auth + invitations rade tek nakon Resend verify |
| [cf-rate-limiting.md](cf-rate-limiting.md) | ⏳ 1 CF custom rule needed | 5 min | Anti-spam za `/auth/v1/signup`, `/token`, `/otp`, `/recover` |
| [uptime-monitoring.md](uptime-monitoring.md) | ⏳ Uptime Kuma monitor + Telegram alerts | 10 min | Alerting kad auth padne ili response time skoči |

## Workflow

Svaki guide ima:
1. **Cilj** — što omogućuje kad bude gotovo
2. **Status** — gdje smo trenutno
3. **Steps** — eksplicitno što kliknuti gdje
4. **Smoke test** — kako verificirati da radi
5. **Troubleshooting** — česti problemi

Kreni redom kako se uklapa u tvoj raspored. Ništa nije kritično blocking osim Google OAuth (za M2 onboarding moment u Flutter app-u).
