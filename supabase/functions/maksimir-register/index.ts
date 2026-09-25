// maksimir-register — registrar glasanja na lancu (Stadion Maksimir, MaksimirGlasanjeV1).
//
//   POST { chainId, contract, commitment }   Authorization: Bearer <sesija nakon eOsobne>
//   → 200 { chainId, contract, commitment, deadline, signature, existing, transferSeq, transferred }
//   → 409 already_registered (+ commitment) | commitment_taken | voting_closed
//   → 403 not_verified | chain_terms_not_accepted;  401 not_signed_in;  503 registrar_*
//
// Ključ registrara po mreži: tajna MAKSIMIR_REGISTRAR_KEY_<chainId> (npr. _100, _10200).
// Logika i testovi: logic.ts, logic_test.ts. Pravila (jedan commitment po osobi, prijenos
// listića faze 1) provodi baza: migracija 20260926120000_maksimir_chain.sql.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { privateKeyToAccount } from "npm:viem@2/accounts";
import { corsHeaders } from "../_shared/cors.ts";
import { type Chain, type DbResult, type Deps, handle, type Signer } from "./logic.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
const registrarCache = new Map<string, { at: number; address: string }>();

const deps: Deps = {
  async userId(authorization) {
    const user = createClient(URL_, ANON, { global: { headers: { Authorization: authorization } }, auth: { persistSession: false } });
    const { data } = await user.auth.getUser();
    return data.user && !data.user.is_anonymous ? data.user.id : null;
  },
  async chain(chainId, contract) {
    const { data } = await admin.schema("domovina_ai").from("maksimir_chains")
      .select("chain_id, contract, rpc_url, counts").eq("chain_id", chainId).eq("contract", contract).maybeSingle();
    return data ? { chainId: Number(data.chain_id), contract: data.contract, rpcUrl: data.rpc_url, counts: data.counts } : null;
  },
  async registrarOf(chain: Chain) {
    const key = `${chain.chainId}:${chain.contract}`;
    const hit = registrarCache.get(key);
    if (hit && Date.now() - hit.at < 60_000) return hit.address;
    // registrar() = 0x2b20e397
    const res = await fetch(chain.rpcUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": "maksimir-register/1" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to: chain.contract, data: "0x2b20e397" }, "latest"] }),
    });
    const j = await res.json();
    if (!res.ok || j.error || typeof j.result !== "string") throw new Error(`rpc registrar(): ${j.error?.message ?? res.status}`);
    const address = `0x${j.result.slice(-40)}`;
    registrarCache.set(key, { at: Date.now(), address });
    return address;
  },
  async register(userId, chain, commitment) {
    const { data, error } = await admin.schema("domovina_ai").rpc("_maksimir_chain_register_for", {
      p_user_id: userId,
      p_chain_id: chain.chainId,
      p_contract: chain.contract,
      p_commitment: commitment,
    });
    if (error) throw new Error(error.message);
    return data as DbResult;
  },
  signer(chainId): Signer | null {
    const pk = Deno.env.get(`MAKSIMIR_REGISTRAR_KEY_${chainId}`);
    if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) return null;
    const account = privateKeyToAccount(pk as `0x${string}`);
    return { address: account.address, signTypedData: (td) => account.signTypedData(td) };
  },
  now: () => Date.now(),
};

const json = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const body = await req.json().catch(() => null);
    const r = await handle(req.headers.get("Authorization") ?? "", body, deps);
    return json(r.body, r.status);
  } catch (e) {
    console.error("maksimir-register", (e as Error).message);
    return json({ error: "server_error" }, 500);
  }
});
