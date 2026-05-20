# Resend domain verification (email magic link auth)

**Cilj:** GoTrue može slati confirmation/recovery/magic-link emailove preko Resend SMTP-a iz adrese `noreply@domovina.ai`.

**Status:** SMTP credentials su postavljene u Coolify env-u, ali domena `domovina.ai` nije verified u Resendu → mail neće biti dostavljen.

---

## Korak 1 — Resend dashboard

1. <https://resend.com/domains>
2. **Add Domain** → `domovina.ai` → Region: **EU (eu-west-1)** (bliže Hrvatskoj)
3. Resend pokazuje 3 DNS zapisa koja treba dodati:
   - **SPF** (TXT) — npr. `v=spf1 include:amazonses.com ~all`
   - **DKIM** (TXT × 2) — selectori `resend._domainkey` i (možda) `resend2._domainkey`
   - **MX** — `feedback-smtp.eu-west-1.amazonses.com` (priority 10)

   **Ne klikni Verify još** — prvo dodaj DNS.

## Korak 2 — Cloudflare DNS

Cloudflare → `domovina.ai` zone → **DNS → Records → Add record**.

Za svaki redak iz Resenda:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| TXT | `domovina.ai` ili `@` | `v=spf1 include:amazonses.com ~all` | **DNS only** (sivi oblak) |
| TXT | `resend._domainkey` | `<dug DKIM string iz Resenda>` | **DNS only** |
| MX | `send` (ili kako Resend kaže) | `feedback-smtp.eu-west-1.amazonses.com` (priority 10) | (MX nema proxy) |

> ⚠️ **Bitno**: sve mail-related zapise drži u **DNS only** mode (sivi oblak). Cloudflare proxy ne radi za SMTP i razbija mail delivery.

## Korak 3 — Verify

Vrati se u Resend → **Verify DNS Records**. Treba 1-2 min, ponekad do 30 min.

Provjeri sa servera:
```bash
dig +short TXT domovina.ai | grep spf
dig +short TXT resend._domainkey.domovina.ai
dig +short MX domovina.ai
```

Sve treba vratiti Resend vrijednosti.

## Korak 4 — End-to-end test

Studio → **Authentication → Users → Invite user** → unesi `ms@domovina.tv` (ili neki drugi email).

GoTrue šalje invitation email kroz Resend. Provjeri:
- Resend dashboard → **Emails** → pokazuje delivery log
- Inbox dobije mail s "You have been invited to ..."

Ako mail ne stigne:
- Spam folder
- Resend log za bounce/reject reason
- `SMTP_PASS` u Coolify env-u valid (možda je rotated)

## Korak 5 — Magic link flow

Kad domena verified, magic link signup radi:

```dart
// Flutter:
await Supabase.instance.client.auth.signInWithOtp(
  email: 'user@example.com',
  shouldCreateUser: false,  // već je anonymous, samo link
);
```

Korisnik dobije email s 6-znamenkastim kodom (5 min validity). U Flutter app-u unese kod → `verifyOTP(...)` → session.

## Postojeći env varovi u Coolifyju

Već postavljeno (preko `scripts/build-coolify-env.sh`):
```
SMTP_HOST=smtp.resend.com
SMTP_PORT=465
SMTP_USER=resend
SMTP_PASS=<resend API key>
SMTP_ADMIN_EMAIL=noreply@domovina.ai
SMTP_SENDER_NAME=Domovina
GOTRUE_MAILER_OTP_LENGTH=6
GOTRUE_MAILER_OTP_EXP=300
```

**Nema potrebe ništa mijenjati** — samo verify Resend domain pa kreni testirati.

## Troubleshooting

- **Resend "Domain not verified"**: ne stigli DNS zapisi — provjeri Cloudflare DNS, makni proxy ako je proxied.
- **GoTrue log shows "550 sender verification failed"**: `SMTP_ADMIN_EMAIL=noreply@domovina.ai` ali `domovina.ai` nije verified u Resendu.
- **Mail u spam**: Resend dolazi s `notify.cloudflareaccess.com` ali ako se mail šalje iz `noreply@domovina.ai` (preko Resend SMTP-a), reputation za novu domenu može privući spam filter. Postavi i **DMARC** zapis u Cloudflare DNS (preporuka Resenda): `_dmarc.domovina.ai TXT "v=DMARC1; p=quarantine; rua=mailto:ms@domovina.tv"`
