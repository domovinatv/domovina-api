import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// pinka-contribute — kreira pending doprinos i pripadajuci payment intent na
// pay.domovina.ai rail-u, te vraca EPC QR podatke koje klijent (domovina.ai
// Flutter / pinka.finance) renderira i pokazuje korisniku za SEPA placanje.
//
// Tok:
//   1. verificiraj korisnika (anon Supabase sesija je OK — ima JWT)
//   2. create_contribution preko USER klijenta → auth.uid() rezolvira account
//   3. POST pay-worker /api/intents (javni, target = campaign Safe)
//   4. attach_intent (service_role) → sprema sid na doprinos
//   5. vrati EPC/QR + sid klijentu

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const INTENTS_URL = Deno.env.get("PINKA_INTENTS_URL") ??
  "https://mpt.domovina.ai/api/intents";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "not_authenticated" }, 401);

  const body = await req.json().catch(() => ({}));
  const campaignId = body.campaign_id as string | undefined;
  const amountCents = Number(body.amount_cents);
  if (!campaignId) return json({ error: "campaign_id_required" }, 400);
  if (!Number.isFinite(amountCents) || amountCents <= 0) {
    return json({ error: "invalid_amount_cents" }, 400);
  }

  // 2) kreiraj pending doprinos (RPC validira kampanju/tier/iznos)
  const { data: created, error: createErr } = await userClient
    .schema("pinka_finance")
    .rpc("create_contribution", {
      p_campaign_id: campaignId,
      p_amount_cents: amountCents,
      p_tier_id: body.tier_id ?? null,
      p_display_name: body.display_name ?? null,
      p_message: body.message ?? null,
      p_anonymous: body.anonymous ?? false,
      p_quantity: body.quantity ?? 1,
    });
  if (createErr) return json({ error: createErr.message }, 400);
  const row = Array.isArray(created) ? created[0] : created;
  if (!row?.contribution_id) return json({ error: "contribution_not_created" }, 500);

  // 3) kreiraj payment intent na rail-u (javni endpoint)
  const intentRes = await fetch(INTENTS_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      target_address: row.destination_address,
      amount_eur: row.amount_cents / 100,
      label: body.label ?? "pinka.finance",
      metadata: { campaign_id: campaignId, contribution_id: row.contribution_id },
    }),
  });
  if (!intentRes.ok) {
    return json({ error: "intent_create_failed", status: intentRes.status }, 502);
  }
  const intent = await intentRes.json();

  // 4) zalijepi sid na doprinos (service_role)
  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const { error: attachErr } = await admin
    .schema("pinka_finance")
    .rpc("attach_intent", {
      p_contribution_id: row.contribution_id,
      p_sid: intent.sid,
      p_monerium_order_id: null,
    });
  if (attachErr) return json({ error: attachErr.message }, 500);

  // 5) vrati klijentu sve potrebno za prikaz QR-a + polling
  return json({
    contribution_id: row.contribution_id,
    sid: intent.sid,
    state: intent.state,
    amount_eur: intent.amount_eur,
    amount_cents: intent.amount_cents,
    currency: intent.currency,
    memo: intent.memo,
    iban: intent.iban,
    beneficiary_name: intent.beneficiary_name,
    bic: intent.bic,
    epc_qr_data: intent.epc_qr_data,
    checkout_url: intent.checkout_url,
    status_url: intent.status_url,
    expires_at: intent.expires_at,
  }, 200);

  function json(b: unknown, status: number) {
    return new Response(JSON.stringify(b), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
