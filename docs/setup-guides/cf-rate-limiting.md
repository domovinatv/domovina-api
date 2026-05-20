# Cloudflare Rate Limiting — /auth/v1/signup i /auth/v1/token

**Cilj:** spriječiti spam/bruteforce na auth endpointima sad kad je anonymous signup javan.

**Status:** trenutno nema rate limita. Free plan dopušta **1 rate limiting rule** (per zone).

---

## Što štitimo

| Endpoint | Napad | Rate |
|---|---|---|
| `POST /auth/v1/signup` | Spam stvaranje korisnika (anonymous, email) | 10/min po IP |
| `POST /auth/v1/token` | Brute force credentials, OTP | 20/min po IP |
| `POST /auth/v1/otp` | Spam OTP slanja (skupo kroz Resend) | 5/min po IP |
| `POST /auth/v1/recover` | Spam password reset | 5/min po IP |

Free plan ima **1 rule** — koristimo kombinirani filter za sva 4.

---

## Korak 1 — Cloudflare Dashboard

Otvori (zone-level, ne account):
```
https://dash.cloudflare.com/7dc7167b7e2e00923bfa7cd697df14e4/domovina.ai/security/security-rules
```

Tab **Rate limiting rules** → **Create rule**.

## Korak 2 — Rule definicija

**Rule name:** `Auth endpoint rate limit`

**If incoming requests match** (klikni "Edit expression" za raw):

```
(http.host eq "api.domovina.ai") and (
  http.request.uri.path eq "/auth/v1/signup"
  or http.request.uri.path eq "/auth/v1/token"
  or http.request.uri.path eq "/auth/v1/otp"
  or http.request.uri.path eq "/auth/v1/recover"
)
```

**With the same characteristics:**
- ☑ IP address

**When rate exceeds:**
- **20 requests** per **1 minute**

**Then take action:**
- **Managed Challenge** *(preporuka — bot dobije captcha, human prolazi)*
- Alternativa: **Block** — agresivnije, ali ako legitimni korisnik nešto retrya zaredom može ga uhvatiti

**Duration:** `10 seconds` (kratko — nakon 10s može ponovo, ali brzo blokira spam burst)

**Place at:** First (najveća prioriteta)

**Save and deploy.**

## Korak 3 — Test

Iz incognito browsera:
```bash
for i in {1..30}; do
  curl -s -o /dev/null -w "%{http_code} " \
    -X POST "https://api.domovina.ai/auth/v1/signup" \
    -H "apikey: <ANON>" -H "Content-Type: application/json" -d '{}'
done
echo
```

Očekivano: prvih ~20 requesta vraćaju `200`, daljnji `429` (Too Many Requests) ili challenge page.

Provjeri u Cloudflare dashboard → **Security → Analytics** → vidi rule hits.

## Caveats

- **CF Tunnel preskakanje**: ako je netko na istom Cloudflare accountu, requesti kroz tunel mogu zaobići rate limit. Naš tunel je za egress (od cloudflared na server), ne ingress, pa nije problem.
- **Legitimni client retry**: ako Flutter klijent ima aggressive auto-retry na 401, može potrošiti 20 req/min brzo. Managed Challenge je bolja akcija od Block jer dopušta legitimnu retry kroz captcha.
- **Free plan 1 rule limit**: ako budemo trebali finije pravilo, treba upgrade na Pro ($25/mj) za 10 rules.

## Sljedeći korak

Nakon Resend domain verify (`resend-domain.md`), dodati i:
- `POST /auth/v1/invite` (admin endpoint, već zaštićen JWT, ali extra layer ne škodi)

To bi tražilo drugi rate limit rule → Pro plan upgrade ili kreiraj precizniji compound filter.
