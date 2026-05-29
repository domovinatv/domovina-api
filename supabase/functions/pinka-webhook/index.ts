import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// pinka-webhook — prima OUTBOUND "intent.paid" webhook s pay.domovina.ai rail-a
// (src/intents/outbound.ts) i oznacava doprinos placenim. Idempotentno: trigeri
// u bazi rade stats / funded-flip / token_position.
//
// Potpis = svix / Standard Webhooks (isti scheme kao inbound Monerium):
//   headers: webhook-id, webhook-timestamp, webhook-signature: `v1,<base64>`
//   signed payload: `${id}.${timestamp}.${rawBody}`
//   key: base64-decode(secret bez opcionalnog `whsec_` prefiksa)
//
// verify_jwt = false (server-to-server); autentikacija je HMAC potpis, ne JWT.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("INTENT_WEBHOOK_SECRET") ?? "";
const TOLERANCE_SECONDS = 300; // 5 min replay window

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SECRET) return json({ error: "secret_not_configured" }, 500);

  const raw = await req.text();
  const id = req.headers.get("webhook-id");
  const ts = req.headers.get("webhook-timestamp");
  const sigHeader = req.headers.get("webhook-signature");
  if (!id || !ts || !sigHeader) return json({ error: "missing_webhook_headers" }, 400);

  // replay zastita
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - Number(ts)) > TOLERANCE_SECONDS) {
    return json({ error: "timestamp_out_of_tolerance" }, 400);
  }

  const ok = await verify(SECRET, `${id}.${ts}.${raw}`, sigHeader);
  if (!ok) return json({ error: "bad_signature" }, 401);

  const event = JSON.parse(raw);
  if (event.type !== "intent.paid") {
    return json({ ok: true, ignored: event.type }, 200);
  }
  if (!event.sid) return json({ error: "missing_sid" }, 400);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const { data: marked, error } = await admin
    .schema("pinka_finance")
    .rpc("mark_contribution_paid", {
      p_sid: event.sid,
      p_tx_hash: event.forward_tx_hash ?? null,
      p_amount_received_cents: event.amount_received_cents ?? null,
    });
  if (error) return json({ error: error.message }, 500);

  // marked=false → vec placeno (idempotentno) ili nepoznat sid; oba su 200.
  return json({ ok: true, marked: marked === true }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

async function verify(secret: string, signedPayload: string, sigHeader: string): Promise<boolean> {
  const keyBytes = decodeSecret(secret);
  if (!keyBytes) return false;
  const expected = await hmacBase64(keyBytes, signedPayload);
  for (const token of sigHeader.split(/\s+/).filter(Boolean)) {
    const [version, sig] = token.split(",", 2);
    if (version === "v1" && sig && timingSafeEqual(sig, expected)) return true;
  }
  return false;
}

function decodeSecret(secret: string): Uint8Array | null {
  const stripped = secret.startsWith("whsec_") ? secret.slice("whsec_".length) : secret;
  try {
    const bin = atob(stripped);
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
  const sig = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(data) as BufferSource,
  );
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
