import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SIGNATURE_HEADER, verifyUlazniceSignature } from "../_shared/ulaznice-hmac.ts";

// events-stripe-confirm — kreditiranje narudžbe ulaznica Stripe uplatom.
//
// ⚠️ NAJOSJETLJIVIJA TOČKA CIJELOG DIZAJNA. Za razliku od events-confirm (gdje
// je dokaz uplate sam blockchain i funkcija ga sama provjeri na Gnosisu), ovdje
// backend NEMA nikakav vlastiti dokaz da je uplata stvarno naplaćena — jedini
// dokaz je Stripe webhook potpis koji verificira naš Cloudflare Worker. Zato:
//
//   * poziv MORA nositi x-ulaznice-signature (HMAC-SHA256 nad sirovim tijelom,
//     tajna EVENTS_STRIPE_CONFIRM_SECRET) — bez toga 401 i baza se NE dira,
//   * bez postavljene tajne funkcija vraća 503, nikad "prolazi jer tajne nema".
//
// Idempotencija NIJE ovdje nego u bazi: unique (payment_rail,
// external_payment_ref). Ponovljena dostava istog webhooka → already_paid, bez
// ijedne nove ulaznice.
//
// QR tokeni: nakon uspješnog kreditiranja povlačimo ih kroz postojeći
// deliver_ticket_orders (jednokratna dostava — u bazi ostaje samo sha256 hash).
// Namjerno se poziva i na already_paid: ako je prvi confirm prošao, a odgovor
// nije stigao do Workera, retry webhooka i dalje isporuči tokene (crash
// recovery). Nakon prve uspješne dostave qr_token je zauvijek null.
//
// verify_jwt=false — autentikacija je HMAC, ne JWT.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("EVENTS_STRIPE_CONFIRM_SECRET") ?? "";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EXTERNAL_REF_RE = /^[A-Za-z0-9_-]{6,255}$/;

// statusi nakon kojih ulaznice postoje i tokene treba isporučiti
const DELIVERABLE = new Set(["paid", "already_paid"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // sirovo tijelo PRIJE parsiranja — potpis ide nad bajtovima koje potpisao Worker
  const raw = await req.text();
  const gate = await verifyUlazniceSignature(SECRET, raw, req.headers.get(SIGNATURE_HEADER));
  if (!gate.ok) return json({ error: gate.error }, gate.status);

  let body: {
    order_id?: string;
    external_ref?: string;
    amount_cents?: number;
    payer_email?: string;
  };
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const orderId = body.order_id ?? "";
  const externalRef = body.external_ref ?? "";
  const amountCents = Number(body.amount_cents);
  if (!UUID_RE.test(orderId)) return json({ error: "invalid_order_id" }, 400);
  if (!EXTERNAL_REF_RE.test(externalRef)) return json({ error: "invalid_external_ref" }, 400);
  if (!Number.isInteger(amountCents) || amountCents < 0) {
    return json({ error: "invalid_amount_cents" }, 400);
  }
  const payerEmail = (body.payer_email ?? "").trim();
  if (payerEmail.length > 200) return json({ error: "invalid_payer_email" }, 400);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });

  const { data, error } = await sb
    .schema("pinka_finance")
    .rpc("confirm_ticket_order_offchain", {
      p_order_id: orderId,
      p_rail: "stripe",
      p_external_ref: externalRef,
      p_amount_cents: amountCents,
      p_payer_email: payerEmail || null,
    });
  if (error) {
    // strojni kodovi iz RPC-a (order_not_found, not_a_ticket_order, order_not_payable…)
    return json({ error: normalizeDbError(error.message) }, 400);
  }

  const result = (data ?? {}) as Record<string, unknown>;
  const status = String(result.status ?? "");

  // poslovni ne-uspjeh (amount_insufficient, expired_sold_out, tx_already_credited,
  // duplicate_payment) → 200 sa statusom; Worker na njega radi refund / alarm
  if (!DELIVERABLE.has(status)) return json({ ok: true, ...result }, 200);

  const { data: delivered, error: dErr } = await sb
    .schema("pinka_finance")
    .rpc("deliver_ticket_orders", { p_order_ids: [orderId] });
  if (dErr) {
    // narudžba JE plaćena i ulaznice postoje — javi to, dostava se može ponoviti
    return json({ ok: true, ...result, tickets: [], delivery_error: dErr.message }, 200);
  }

  const order = (Array.isArray(delivered) ? delivered[0] : null) as
    | { tickets?: Array<Record<string, unknown>> }
    | null;
  const tickets = (order?.tickets ?? []).map((t) => ({
    serial: t.serial,
    holder_name: t.holder_name,
    holder_email: t.holder_email,
    state: t.state,
    qr_token: t.qr_token, // null ako su tokeni već jednom isporučeni
  }));

  return json({ ok: true, ...result, tickets }, 200);
});

// PostgREST prefiksira poruku exceptiona; zadrži samo strojni kod kad je čist.
function normalizeDbError(message: string): string {
  const code = message.trim().split(/\s/)[0];
  return /^[a-z_]+$/.test(code) ? code : message;
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
