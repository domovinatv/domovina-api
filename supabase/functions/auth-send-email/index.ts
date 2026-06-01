// GoTrue "Send Email" hook — per-frontend branded auth emails.
//
// GoTrue calls this (instead of its built-in SMTP mailer) for every auth email
// (magic link, recovery, …). We pick the brand from `redirect_to` (the frontend
// that requested the login) and send a matching email via Resend. So a login
// started on pinka.io gets a pinka-branded mail; domovina.ai gets DOMOVINA.
//
// Auth: Standard Webhooks HMAC (GOTRUE_HOOK_SEND_EMAIL_SECRET, `v1,whsec_…`).
// verify_jwt = false (GoTrue is the caller; HMAC is the auth).
//
// Env (edge container / Coolify):
//   SEND_EMAIL_HOOK_SECRET   — the whsec_… secret (also in GOTRUE_HOOK_SEND_EMAIL_SECRETS)
//   RESEND_API_KEY           — Resend API key (= SMTP_PASS)
//   AUTH_PUBLIC_URL          — public auth base, default https://api.domovina.ai
//   PINKA_MAIL_FROM / DOMOVINA_MAIL_FROM — optional From overrides

const HOOK_SECRET = Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "";
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? Deno.env.get("SMTP_PASS") ?? "";
const AUTH_PUBLIC_URL = Deno.env.get("AUTH_PUBLIC_URL") ?? "https://api.domovina.ai";

interface Brand {
  key: string;
  name: string;
  from: string;
  accent: string;
  subject: (action: string) => string;
}

const DOMOVINA: Brand = {
  key: "domovina",
  name: "DOMOVINA",
  from: Deno.env.get("DOMOVINA_MAIL_FROM") ?? "DOMOVINA <noreply@domovina.ai>",
  accent: "#002F6C",
  subject: () => "Prijava — DOMOVINA",
};

const PINKA: Brand = {
  key: "pinka",
  name: "pinka",
  // pinka.io / pinka.finance moraju biti verificirana domena u Resendu da bi
  // From radio; do tada postavi PINKA_MAIL_FROM na verificiranu adresu.
  from: Deno.env.get("PINKA_MAIL_FROM") ?? "pinka <noreply@pinka.io>",
  accent: "#E85D5D",
  subject: () => "Tvoja poveznica za prijavu — pinka",
};

function pickBrand(redirectTo: string): Brand {
  let host = "";
  try {
    host = new URL(redirectTo).hostname;
  } catch {
    /* ignore */
  }
  if (/(^|\.)pinka\.(io|finance)$/.test(host) || host.includes("pinka")) return PINKA;
  return DOMOVINA;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: { message: "method_not_allowed" } }, 405);
  if (!HOOK_SECRET || !RESEND_API_KEY) {
    return json({ error: { message: "hook_not_configured" } }, 500);
  }

  const raw = await req.text();
  const okSig = await verify(HOOK_SECRET, raw, req.headers);
  if (!okSig) return json({ error: { message: "bad_signature" } }, 401);

  let payload: {
    user?: { email?: string };
    email_data?: {
      token_hash?: string;
      email_action_type?: string;
      redirect_to?: string;
    };
  };
  try {
    payload = JSON.parse(raw);
  } catch {
    return json({ error: { message: "bad_json" } }, 400);
  }

  const to = payload.user?.email;
  const ed = payload.email_data ?? {};
  const redirectTo = ed.redirect_to ?? "";
  const action = ed.email_action_type ?? "magiclink";
  if (!to || !ed.token_hash) return json({ error: { message: "missing_fields" } }, 400);

  const brand = pickBrand(redirectTo);
  const link = `${AUTH_PUBLIC_URL}/auth/v1/verify?token=${ed.token_hash}` +
    `&type=${encodeURIComponent(action)}` +
    (redirectTo ? `&redirect_to=${encodeURIComponent(redirectTo)}` : "");

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: brand.from,
      to,
      subject: brand.subject(action),
      html: renderEmail(brand, link),
    }),
  });

  if (!res.ok) {
    const detail = await res.text();
    console.error(`[auth-send-email] resend ${res.status}: ${detail.slice(0, 300)}`);
    return json({ error: { message: "send_failed" } }, 502);
  }
  return json({}, 200);
});

function renderEmail(brand: Brand, link: string): string {
  return `<!doctype html><html><body style="margin:0;background:#FBF8F3;font-family:Inter,Segoe UI,Arial,sans-serif;color:#1A1A1A">
  <div style="max-width:480px;margin:0 auto;padding:40px 24px">
    <p style="font-size:24px;font-weight:700;margin:0 0 8px;color:${brand.accent}">${brand.name}</p>
    <h1 style="font-size:20px;margin:24px 0 8px">Prijava jednim klikom</h1>
    <p style="color:#6B6B6B;line-height:1.6;margin:0 0 24px">Klikni gumb da se prijaviš. Poveznica vrijedi kratko i može se iskoristiti jednom.</p>
    <a href="${link}" style="display:inline-block;background:${brand.accent};color:#fff;text-decoration:none;padding:14px 28px;border-radius:9999px;font-weight:600">Prijavi se</a>
    <p style="color:#9b9b9b;font-size:12px;line-height:1.6;margin:28px 0 0">Ako gumb ne radi, kopiraj ovu poveznicu:<br><span style="word-break:break-all">${link}</span></p>
    <p style="color:#bdbdbd;font-size:12px;margin:24px 0 0">Ako nisi ti zatražio/la prijavu, slobodno zanemari ovaj mail.</p>
  </div></body></html>`;
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// --- Standard Webhooks (svix) HMAC verify — same scheme as pinka-webhook ---
async function verify(secret: string, raw: string, headers: Headers): Promise<boolean> {
  const id = headers.get("webhook-id");
  const ts = headers.get("webhook-timestamp");
  const sigHeader = headers.get("webhook-signature");
  if (!id || !ts || !sigHeader) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(ts)) > 300) return false;
  const keyBytes = decodeSecret(secret);
  if (!keyBytes) return false;
  const expected = await hmacBase64(keyBytes, `${id}.${ts}.${raw}`);
  for (const token of sigHeader.split(/\s+/).filter(Boolean)) {
    const [v, s] = token.split(",", 2);
    if (v === "v1" && s && timingSafeEqual(s, expected)) return true;
  }
  return false;
}

function decodeSecret(secret: string): Uint8Array | null {
  const stripped = secret.startsWith("v1,") ? secret.slice(3) : secret;
  const base = stripped.startsWith("whsec_") ? stripped.slice("whsec_".length) : stripped;
  try {
    const bin = atob(base);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

async function hmacBase64(key: Uint8Array, data: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(data) as BufferSource);
  const bytes = new Uint8Array(sig);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
