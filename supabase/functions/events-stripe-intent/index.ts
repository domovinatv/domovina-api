import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SIGNATURE_HEADER, verifyUlazniceSignature } from "../_shared/ulaznice-hmac.ts";

// events-stripe-intent — sve što Worker treba da otvori Stripe Checkout za
// postojeću pending narudžbu ulaznica.
//
// Backend NIKAD ne razgovara sa Stripeom i ne zna njegov ključ — ovdje se samo
// čita stanje: iznos narudžbe (autoritativan, iz baze — nikad iz klijenta),
// snapshot tiera/eventa za line item i organizatorov acct_… uz charges_enabled.
//
// Invariant preuzet iz rodjendaonice/worker/bookable.ts: bez povezanog računa i
// bez charges_enabled kupnja se NE otvara — Checkout session se nikad ne kreira
// "u prazno". acct_… je jedini odgovor u cijelom sustavu koji ga uopće vraća;
// javni feed dobiva izvedeni boolean.
//
// verify_jwt=false + HMAC (isti gate kao events-stripe-confirm): poziva ga samo
// naš Worker. Bez HMAC-a bi svatko tko zna order_id (bearer capability kupca)
// mogao izvući acct_… organizatora.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("EVENTS_STRIPE_CONFIRM_SECRET") ?? "";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const raw = await req.text();
  const gate = await verifyUlazniceSignature(SECRET, raw, req.headers.get(SIGNATURE_HEADER));
  if (!gate.ok) return json({ error: gate.error }, gate.status);

  let body: { order_id?: string };
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const orderId = body.order_id ?? "";
  if (!UUID_RE.test(orderId)) return json({ error: "invalid_order_id" }, 400);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });

  // oportunistički housekeeping (isti obrazac kao create_ticket_order):
  // istekle rezervacije se oslobode prije nego provjerimo stanje narudžbe
  await sb.schema("pinka_finance").rpc("expire_stale_ticket_orders");

  const { data: order, error: oErr } = await sb
    .schema("pinka_finance")
    .from("contributions")
    .select(
      "id, campaign_id, tier_id, state, amount_cents, currency, quantity, reserved, reserve_expires_at, holders, buyer_email",
    )
    .eq("id", orderId)
    .maybeSingle();
  if (oErr) return json({ error: oErr.message }, 500);
  if (!order || !order.tier_id || !order.reserved) return json({ error: "order_not_found" }, 404);
  if (order.state !== "pending") {
    return json({ error: "order_not_pending", state: order.state }, 400);
  }
  if (order.reserve_expires_at && new Date(order.reserve_expires_at as string).getTime() <= Date.now()) {
    return json({ error: "order_expired" }, 400);
  }

  const [{ data: tier }, { data: campaign }, { data: event }] = await Promise.all([
    sb.schema("pinka_finance").from("campaign_tiers")
      .select("id, title, price_cents, imenska").eq("id", order.tier_id).maybeSingle(),
    sb.schema("pinka_finance").from("campaigns")
      .select("id, account_id, title, slug").eq("id", order.campaign_id).maybeSingle(),
    sb.schema("pinka_finance").from("events")
      .select("starts_at, ends_at, timezone, venue_name, venue_city").eq("campaign_id", order.campaign_id).maybeSingle(),
  ]);
  if (!tier || !campaign) return json({ error: "order_not_found" }, 404);

  const { data: rail } = await sb
    .schema("pinka_finance")
    .from("organizer_payment_rails")
    .select("stripe_account_id, stripe_charges_enabled, invoice_provider")
    .eq("account_id", campaign.account_id)
    .maybeSingle();

  if (!rail?.stripe_account_id) return json({ error: "organizer_not_connected" }, 400);
  if (!rail.stripe_charges_enabled) return json({ error: "organizer_charges_disabled" }, 400);

  return json({
    order_id: order.id,
    amount_cents: Number(order.amount_cents),
    currency: order.currency,
    quantity: order.quantity,
    expires_at: order.reserve_expires_at,
    buyer_email: order.buyer_email,
    tier: { id: tier.id, title: tier.title, price_cents: tier.price_cents, imenska: tier.imenska },
    event: {
      campaign_id: campaign.id,
      title: campaign.title,
      slug: campaign.slug,
      starts_at: event?.starts_at ?? null,
      ends_at: event?.ends_at ?? null,
      timezone: event?.timezone ?? null,
      venue_name: event?.venue_name ?? null,
      venue_city: event?.venue_city ?? null,
    },
    stripe_account_id: rail.stripe_account_id,
    charges_enabled: rail.stripe_charges_enabled,
    invoice_provider: rail.invoice_provider,
  }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
