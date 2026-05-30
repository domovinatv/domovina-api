// safe-owner-add — dodaj vlasnikovu wallet adresu kao Safe co-signer (2-of-N).
//
// Eligibility (ownership ∧ KYC ∧ svježina <90d) se RE-PROVJERAVA OVDJE
// server-side (Princip B) — klijentski PayoutEligibility je samo UX, ne
// sigurnosna granica. On-chain dio (Safe Transaction Service, gas) je
// stubban; ovdje je interface + audit log + eligibility gate.
//
// Plan: domovina.ai/docs/channel-ownership-and-safe-payout-plan.md §8
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SAFE_TX_SERVICE_URL = Deno.env.get("SAFE_TX_SERVICE_URL") ?? "";
const REVERIFY_DAYS = 90;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    // 1. Resolve prijavljeni user.
    const authHeader = req.headers.get("Authorization") ?? "";
    const userClient = createClient(URL_, ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user || user.is_anonymous) return json({ error: "not_signed_in" }, 401);

    const { episodeId, address } = await req.json().catch(() => ({}));
    if (!episodeId || !address) return json({ ok: false, error: "missing_params" }, 400);

    // 2. Safe epizode.
    const { data: safe } = await admin.schema("domovina_ai").from("episode_safes")
      .select().eq("episode_id", episodeId).maybeSingle();
    if (!safe) return json({ ok: false, error: "no_safe" }, 200);
    if (safe.status === "frozen") return json({ ok: false, error: "safe_frozen" }, 200);

    // 3. Eligibility RE-CHECK (NE vjeruj klijentu).
    //    a) verified claim za kanal Safe-a, ovaj account
    const { data: claim } = await admin.schema("domovina_ai").from("channel_claims")
      .select().eq("youtube_channel_id", safe.youtube_channel_id)
      .eq("account_id", user.id).eq("status", "verified").maybeSingle();
    if (!claim) return json({ ok: false, error: "not_eligible" }, 200);

    //    b) D4 svježina
    if (claim.verified_at) {
      const ageDays = (Date.now() - new Date(claim.verified_at).getTime()) / 86_400_000;
      if (ageDays >= REVERIFY_DAYS) return json({ ok: false, error: "reverify_needed" }, 200);
    }

    //    c) KYC (app_metadata.kyc_verified)
    const kyc = (user.app_metadata as Record<string, unknown> | undefined)?.kyc_verified;
    if (kyc !== true) return json({ ok: false, error: "not_eligible" }, 200);

    //    d) adresa registrirana kod ovog usera
    const { data: wallet } = await admin.schema("domovina_ai").from("owner_wallets")
      .select("id").eq("account_id", user.id).eq("address", address).maybeSingle();
    if (!wallet) return json({ ok: false, error: "wallet_not_registered" }, 200);

    // 4. Predloži owner-add na Safe Transaction Service (stub ako URL nije set).
    const proposal = await proposeOwnerAdd(safe, address);

    // 5. Audit log.
    await admin.schema("domovina_ai").from("safe_actions").insert({
      episode_id: episodeId,
      account_id: user.id,
      action: proposal.executed ? "owner_add_executed" : "owner_add_proposed",
      safe_tx_hash: proposal.safeTxHash,
      payload: { address, chain_id: safe.chain_id, threshold: safe.threshold },
    });

    return json({ ok: true, safe_tx_hash: proposal.safeTxHash }, 200);
  } catch (e) {
    console.error("safe-owner-add error", e);
    return json({ error: String((e as Error)?.message ?? e) }, 400);
  }
});

// Safe Transaction Service owner-add proposal. Bez konfiguriranog SAFE_TX_
// SERVICE_URL vraćamo deterministic stub hash (lokalni/dev rad bez on-chaina).
async function proposeOwnerAdd(
  safe: Record<string, unknown>,
  address: string,
): Promise<{ safeTxHash: string; executed: boolean }> {
  if (!SAFE_TX_SERVICE_URL) {
    const stub = await sha256Hex(`${safe.safe_address}:${address}:${safe.chain_id}`);
    return { safeTxHash: `0xstub${stub.slice(0, 56)}`, executed: false };
  }
  // Realna integracija: addOwnerWithThreshold(address, safe.threshold) →
  // platforma potpiše svoj dio → exec kad threshold zadovoljen (2-of-N, D3).
  const res = await fetch(`${SAFE_TX_SERVICE_URL}/owner-add`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      safe: safe.safe_address,
      chainId: safe.chain_id,
      newOwner: address,
      threshold: safe.threshold,
    }),
  });
  if (!res.ok) throw new Error(`safe_tx_service_failed: ${res.status}`);
  const data = await res.json();
  return { safeTxHash: data.safeTxHash, executed: !!data.executed };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
