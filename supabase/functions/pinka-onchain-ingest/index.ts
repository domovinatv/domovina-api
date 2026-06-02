import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// pinka-onchain-ingest — bridges the pay.domovina.ai on-chain indexer to the
// pinka_finance domain.
//
//   GET  → public watchlist: active/funded public campaigns' Safe addresses, so
//          the indexer knows which `to` addresses to filter EURe Transfers on.
//          (destination_address is already public; no secret needed.)
//   POST → ingest a batch of detected EURe transfers (HMAC-signed by the indexer
//          with INTENT_WEBHOOK_SECRET, same svix scheme as pinka-webhook).
//          Resolves campaign by destination_address, converts wei→cents, and
//          calls the idempotent record_onchain_contribution RPC.
//
// verify_jwt = false (server-to-server; HMAC is the auth on POST).

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("INTENT_WEBHOOK_SECRET") ?? "";
const TOLERANCE_SECONDS = 300;

// EURe has 18 decimals; 1 cent = 1e16 wei.
const WEI_PER_CENT = 10n ** 16n;

function admin() {
  return createClient(URL, SERVICE, { auth: { persistSession: false } });
}

Deno.serve(async (req) => {
  if (req.method === "GET") {
    const { data, error } = await admin()
      .schema("pinka_finance")
      .from("campaigns")
      .select("id, destination_address")
      .eq("visibility", "public")
      .in("state", ["active", "funded"])
      .not("destination_address", "is", null);
    if (error) return json({ error: error.message }, 500);
    const watchlist = (data ?? [])
      .filter((c) => c.destination_address)
      .map((c) => ({ campaign_id: c.id, address: (c.destination_address as string).toLowerCase() }));
    return json({ watchlist }, 200);
  }

  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!SECRET) return json({ error: "secret_not_configured" }, 500);

  const raw = await req.text();
  const id = req.headers.get("webhook-id");
  const ts = req.headers.get("webhook-timestamp");
  const sig = req.headers.get("webhook-signature");
  if (!id || !ts || !sig) return json({ error: "missing_webhook_headers" }, 400);
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(ts)) > TOLERANCE_SECONDS) {
    return json({ error: "timestamp_out_of_tolerance" }, 400);
  }
  if (!(await verify(SECRET, `${id}.${ts}.${raw}`, sig))) {
    return json({ error: "bad_signature" }, 401);
  }

  let body: { transfers?: Transfer[] };
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const transfers = Array.isArray(body.transfers) ? body.transfers : [];
  const sb = admin();

  // Resolve campaign_id from destination_address authoritatively (don't trust
  // the indexer's mapping). One lookup of the small active-campaign set.
  const { data: camps } = await sb
    .schema("pinka_finance")
    .from("campaigns")
    .select("id, destination_address")
    .not("destination_address", "is", null);
  const byAddr = new Map<string, string>();
  for (const c of camps ?? []) {
    if (c.destination_address) byAddr.set((c.destination_address as string).toLowerCase(), c.id as string);
  }

  const results: Array<Record<string, unknown>> = [];
  for (const t of transfers) {
    try {
      const to = (t.to ?? "").toLowerCase();
      const campaignId = byAddr.get(to);
      if (!campaignId) {
        results.push({ tx: t.tx_hash, log: t.log_index, status: "no_campaign" });
        continue;
      }
      const cents = Number(BigInt(t.amount_wei) / WEI_PER_CENT);
      if (!Number.isFinite(cents) || cents <= 0) {
        results.push({ tx: t.tx_hash, log: t.log_index, status: "dust" });
        continue;
      }
      const { data, error } = await sb
        .schema("pinka_finance")
        .rpc("record_onchain_contribution", {
          p_campaign_id: campaignId,
          p_tx_hash: t.tx_hash,
          p_log_index: t.log_index,
          p_from: (t.from ?? "").toLowerCase() || null,
          p_amount_cents: cents,
        });
      if (error) {
        results.push({ tx: t.tx_hash, log: t.log_index, status: "error", error: error.message });
        continue;
      }
      const row = Array.isArray(data) ? data[0] : data;
      results.push({
        tx: t.tx_hash,
        log: t.log_index,
        status: row?.created ? "created" : "exists",
        contribution_id: row?.contribution_id,
      });
    } catch (e) {
      results.push({ tx: t.tx_hash, log: t.log_index, status: "error", error: String(e) });
    }
  }
  const created = results.filter((r) => r.status === "created").length;
  return json({ ok: true, created, total: results.length, results }, 200);
});

type Transfer = {
  to: string;
  from?: string;
  tx_hash: string;
  log_index: number;
  amount_wei: string; // decimal string
  block?: number;
};

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// --- svix / Standard Webhooks HMAC (same scheme as pinka-webhook) ------------
async function verify(secret: string, signedPayload: string, sigHeader: string): Promise<boolean> {
  const keyBytes = decodeSecret(secret);
  if (!keyBytes) return false;
  const expected = await hmacBase64(keyBytes, signedPayload);
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
  const out = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(data) as BufferSource);
  const bytes = new Uint8Array(out);
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
