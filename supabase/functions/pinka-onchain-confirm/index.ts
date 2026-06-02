import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// pinka-onchain-confirm — instant credit for an in-app DOMOVINA-wallet donation.
//
// The pinka frontend calls `Domovina.send({to: campaignSafe, amount})` (wallet
// SDK), gets a txHash, and posts {campaign_id, tx_hash} here. We VERIFY the tx
// on Gnosis (don't trust the client's amount): read the receipt, find EURe V2
// Transfer logs to the campaign's destination_address, and credit each via the
// idempotent record_onchain_contribution RPC. Same idempotency key as the cron
// indexer (tx_hash + log_index), so the two never double-credit.
//
// No HMAC/JWT: the on-chain verification IS the authorization — we only ever
// credit real EURe transfers that landed at the campaign Safe. verify_jwt=false.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RPC = Deno.env.get("GNOSIS_RPC_URL") ?? "https://rpc.gnosischain.com";
const EURE_V2 = (Deno.env.get("EURE_CONTRACT") ?? "0x420CA0f9B9b604cE0fd9C18EF134C705e5Fa3430").toLowerCase();
// MPT rail Safe — its forwards are the fiat path (already credited via webhook).
const RAIL_SAFE = (Deno.env.get("RAIL_SAFE_ADDRESS") ?? "0x449aBCEf4e29a7Dd8d98dB451AF2c463561BAf2e").toLowerCase();
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const WEI_PER_CENT = 10n ** 16n;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: { campaign_id?: string; tx_hash?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const campaignId = body.campaign_id;
  const txHash = (body.tx_hash ?? "").toLowerCase();
  if (!campaignId) return json({ error: "campaign_id_required" }, 400);
  if (!/^0x[0-9a-f]{64}$/.test(txHash)) return json({ error: "invalid_tx_hash" }, 400);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });

  // Resolve the campaign's destination Safe.
  const { data: camp, error: cErr } = await sb
    .schema("pinka_finance")
    .from("campaigns")
    .select("id, destination_address")
    .eq("id", campaignId)
    .maybeSingle();
  if (cErr) return json({ error: cErr.message }, 500);
  if (!camp?.destination_address) return json({ error: "unknown_campaign" }, 404);
  const dest = (camp.destination_address as string).toLowerCase();

  // Read the receipt from Gnosis. null = not mined yet → tell the client to retry.
  const receipt = await rpc("eth_getTransactionReceipt", [txHash]);
  if (!receipt) return json({ ok: true, mined: false, credited: 0 }, 200);
  if (receipt.status && receipt.status !== "0x1") {
    return json({ ok: true, mined: true, reverted: true, credited: 0 }, 200);
  }

  const block = receipt.blockNumber ? parseInt(receipt.blockNumber, 16) : null;
  const results: Array<Record<string, unknown>> = [];
  for (const lg of receipt.logs ?? []) {
    if ((lg.address ?? "").toLowerCase() !== EURE_V2) continue;
    if (!lg.topics || lg.topics[0]?.toLowerCase() !== TRANSFER_TOPIC) continue;
    const from = ("0x" + lg.topics[1].slice(26)).toLowerCase();
    const to = ("0x" + lg.topics[2].slice(26)).toLowerCase();
    if (to !== dest) continue;
    if (from === RAIL_SAFE) continue; // rail forward — fiat path already credited
    const cents = Number(BigInt(lg.data) / WEI_PER_CENT);
    if (!Number.isFinite(cents) || cents <= 0) continue;
    const logIndex = parseInt(lg.logIndex, 16);
    const { data, error } = await sb
      .schema("pinka_finance")
      .rpc("record_onchain_contribution", {
        p_campaign_id: campaignId,
        p_tx_hash: txHash,
        p_log_index: logIndex,
        p_from: from,
        p_amount_cents: cents,
      });
    if (error) {
      results.push({ log: logIndex, status: "error", error: error.message });
      continue;
    }
    const row = Array.isArray(data) ? data[0] : data;
    results.push({ log: logIndex, status: row?.created ? "created" : "exists", contribution_id: row?.contribution_id, cents });
  }

  const credited = results.filter((r) => r.status === "created" || r.status === "exists").length;
  return json({ ok: true, mined: true, block, credited, results }, 200);
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

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
}
