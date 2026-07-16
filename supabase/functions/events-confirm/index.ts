import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-confirm — vezanje EURe uplate uz KONKRETNU narudžbu ulaznica.
//
// Obrazac = pinka-onchain-confirm (klijent javi tx hash, mi VERIFICIRAMO
// receipt na Gnosisu — klijentu se ne vjeruje ništa), pooštren za ulaznice:
//   * {order_id, tx_hash} — tx se veže uz narudžbu, ne samo uz kampanju
//   * primatelj MORA biti organizatorov Safe te narudžbe (destination snapshot)
//   * iznos MORA pokriti narudžbu (provjera i ovdje i u RPC-u)
//   * idempotencija po (tx_hash, log_index) — dijeli ključ s cron indexerom,
//     pa ponovljeni confirm / retroaktivni confirm nikad ne duplicira
// Na verificiranu uplatu confirm_ticket_order izda N ulaznica; QR tokeni se
// dostavljaju ISKLJUČIVO kroz events-tickets (jednokratno).
//
// No HMAC/JWT: onchain verifikacija JE autorizacija. verify_jwt=false.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RPC = Deno.env.get("GNOSIS_RPC_URL") ?? "https://rpc.gnosischain.com";
const EURE_V2 = (Deno.env.get("EURE_CONTRACT") ?? "0x420CA0f9B9b604cE0fd9C18EF134C705e5Fa3430").toLowerCase();
// MPT rail Safe — njegovi forwardi su fiat put (kreditiran webhookom), ne P2P kupnja.
const RAIL_SAFE = (Deno.env.get("RAIL_SAFE_ADDRESS") ?? "0x449aBCEf4e29a7Dd8d98dB451AF2c463561BAf2e").toLowerCase();
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const WEI_PER_CENT = 10n ** 16n;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { order_id?: string; tx_hash?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const orderId = body.order_id ?? "";
  const txHash = (body.tx_hash ?? "").toLowerCase();
  if (!UUID_RE.test(orderId)) return json({ error: "invalid_order_id" }, 400);
  if (!/^0x[0-9a-f]{64}$/.test(txHash)) return json({ error: "invalid_tx_hash" }, 400);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });

  // Narudžba + očekivani iznos i odredišni Safe (snapshot na narudžbi).
  const { data: order, error: oErr } = await sb
    .schema("pinka_finance")
    .from("contributions")
    .select("id, state, amount_cents, destination_address, tier_id, reserved, forward_tx_hash, onchain_log_index")
    .eq("id", orderId)
    .maybeSingle();
  if (oErr) return json({ error: oErr.message }, 500);
  if (!order || !order.tier_id || !order.reserved) return json({ error: "order_not_found" }, 404);
  const dest = (order.destination_address as string).toLowerCase();
  const expectedCents = Number(order.amount_cents);

  // idempotentni fast-path: narudžba već potvrđena ovim tx-om
  if (order.state === "paid" && (order.forward_tx_hash ?? "").toLowerCase() === txHash) {
    return json({ ok: true, mined: true, status: "already_paid", order_id: orderId }, 200);
  }

  // Receipt s Gnosisa. null = još nije minan → klijent neka retry-a.
  const receipt = await rpc("eth_getTransactionReceipt", [txHash]);
  if (!receipt) return json({ ok: true, mined: false, status: "not_mined" }, 200);
  if (receipt.status && receipt.status !== "0x1") {
    return json({ ok: true, mined: true, status: "reverted" }, 200);
  }

  // EURe Transfer log na odredišni Safe narudžbe koji POKRIVA iznos narudžbe.
  const block = receipt.blockNumber ? parseInt(receipt.blockNumber, 16) : null;
  let match: { logIndex: number; from: string; cents: number } | null = null;
  for (const lg of receipt.logs ?? []) {
    if ((lg.address ?? "").toLowerCase() !== EURE_V2) continue;
    if (!lg.topics || lg.topics[0]?.toLowerCase() !== TRANSFER_TOPIC) continue;
    const from = ("0x" + lg.topics[1].slice(26)).toLowerCase();
    const to = ("0x" + lg.topics[2].slice(26)).toLowerCase();
    if (to !== dest) continue;
    if (from === RAIL_SAFE) continue;
    const cents = Number(BigInt(lg.data) / WEI_PER_CENT);
    if (!Number.isFinite(cents) || cents < expectedCents) continue;
    match = { logIndex: parseInt(lg.logIndex, 16), from, cents };
    break;
  }
  if (!match) {
    return json({ ok: true, mined: true, block, status: "no_matching_transfer" }, 200);
  }

  const { data, error } = await sb
    .schema("pinka_finance")
    .rpc("confirm_ticket_order", {
      p_order_id: orderId,
      p_tx_hash: txHash,
      p_log_index: match.logIndex,
      p_from: match.from,
      p_amount_cents: match.cents,
    });
  if (error) {
    return json({ error: normalizeDbError(error.message) }, 400);
  }

  return json({ ok: true, mined: true, block, ...((data ?? {}) as Record<string, unknown>) }, 200);
});

async function rpc(method: string, params: unknown[]): Promise<any> {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!res.ok) throw new Error(`rpc ${method} ${res.status}`);
  const j = await res.json();
  if (j.error) throw new Error(`rpc ${method}: ${j.error.message}`);
  return j.result;
}

function normalizeDbError(message: string): string {
  const code = message.trim().split(/\s/)[0];
  return /^[a-z_]+$/.test(code) ? code : message;
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
