import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-tickets — "Moje ulaznice": dostava narudžbi + izdanih ulaznica u app.
//
// Autorizacija = posjedovanje order UUID-ova (client-generated random UUID,
// bearer capability — isti presedan kao pinka contribution_status). Wallet
// šalje id-eve svojih narudžbi iz lokalnog MMKV zapisa; tuđe narudžbe se ne
// mogu pogoditi (128-bit random).
//
// QR token po ulaznici isporučuje se JEDNOKRATNO: RPC deliver_ticket_orders
// vraća qr_token samo dok tranzijentni plaintext postoji i odmah ga briše —
// u bazi trajno ostaje samo sha256 hash (Tier 0 iz receipts plana).
// verify_jwt=false (wallet nema GoTrue sesiju).

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { order_ids?: string[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const orderIds = Array.isArray(body.order_ids) ? body.order_ids : [];
  if (orderIds.length === 0) return json({ orders: [] }, 200);
  if (orderIds.length > 50) return json({ error: "too_many_orders" }, 400);
  if (!orderIds.every((id) => UUID_RE.test(id))) return json({ error: "invalid_order_id" }, 400);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const { data, error } = await sb
    .schema("pinka_finance")
    .rpc("deliver_ticket_orders", { p_order_ids: orderIds });
  if (error) return json({ error: error.message }, 500);

  return json({ orders: data ?? [] }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
