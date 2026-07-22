import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// pinka-contribute — kreira pending doprinos i pripadajuci payment intent na
// pay.domovina.ai rail-u, te vraca EPC QR podatke koje klijent (domovina.ai
// Flutter / pinka.finance) renderira i pokazuje korisniku za SEPA placanje.
//
// Tok:
//   1. verificiraj korisnika (anon Supabase sesija je OK — ima JWT)
//   2. create_contribution preko USER klijenta → auth.uid() rezolvira account
//      (+ atomarno rezervira odabrana mjesta ako su poslana slot_keys)
//   3. POST pay-worker /api/intents (javni, target = campaign Safe)
//   4. attach_intent (service_role) → sprema sid + produzuje hold na vijek intenta
//   5. vrati EPC/QR + sid klijentu
//
// Mjesta (slots): grid kvadratic ili numerirano sjedalo. Rezervacija zivi u
// istoj transakciji kao doprinos — inace bi postojao prozor u kojem doprinos
// postoji bez mjesta. Vidi migraciju 20260722120000_pinka_slots.sql.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const INTENTS_URL = Deno.env.get("PINKA_INTENTS_URL") ??
  "https://mpt.domovina.ai/api/intents";

// Rail default je 900 s (pay.domovina.ai backend/src/intents/api.ts:36), hard
// cap 86400. Kasna uplata na istekli intent NIKAD ne postane placena
// (markIntentPaid trazi state='pending'; confirm.ts:228 to izrijekom kaze) i
// merchant webhook se ne emitira — sto znaci da SEPA nalog koji sjedne
// prekonoc tiho propada. Trazimo maksimum koji rail dopusta.
const INTENT_TTL_SECONDS = 86_400;

// Greske rezervacije mjesta nisu "los zahtjev" nego "netko te pretekao" —
// klijent na 409 osvjezava mapu i ponovno bira, na 400 samo prikaze gresku.
const SLOT_CONFLICT = ["slot_taken", "too_many_holds", "amount_below_slot_price"];

// Rail moze vratiti expires_at kao ISO string (HTTP API) ili UNIX broj
// (sekunde). Normaliziramo na ISO string; null kad je odsutan/neispravan.
function parseExpiresAt(raw: unknown): string | null {
  if (typeof raw === "number" && Number.isFinite(raw)) {
    return new Date(raw * 1000).toISOString();
  }
  if (typeof raw === "string" && raw.length > 0) {
    const ms = Date.parse(raw);
    return Number.isNaN(ms) ? null : new Date(ms).toISOString();
  }
  return null;
}

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

  // Odabrana mjesta (grid kvadratici / numerirana sjedala). Jeftino odbijanje
  // smeca prije DB-a; kanonski oblik i dostupnost validira reserve_slots.
  const rawSlots = body.slot_keys;
  let slotKeys: string[] | null = null;
  if (rawSlots !== undefined && rawSlots !== null) {
    if (!Array.isArray(rawSlots) || rawSlots.length === 0) {
      return json({ error: "invalid_slot_keys" }, 400);
    }
    if (rawSlots.length > 50) return json({ error: "too_many_slots" }, 400);
    if (!rawSlots.every((k) => typeof k === "string" && k.length > 0 && k.length <= 40)) {
      return json({ error: "invalid_slot_keys" }, 400);
    }
    slotKeys = rawSlots as string[];
  }

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

  // Higijena, ne ispravnost: istekli hold je vec nevidljiv u viewu i
  // preuzimljiv u reserve_slots. Ne cekamo rezultat.
  if (slotKeys) {
    admin.schema("pinka_finance").rpc("expire_stale_slot_holds").then(
      () => {},
      () => {},
    );
  }

  // 2) kreiraj pending doprinos (RPC validira kampanju/tier/iznos + rezervira
  //    mjesta u ISTOJ transakciji — ako mjesto padne, doprinos ne nastane)
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
      p_slot_keys: slotKeys,
    });
  if (createErr) {
    const msg = createErr.message ?? "";
    const conflict = SLOT_CONFLICT.some((c) => msg.includes(c));
    return json({ error: msg }, conflict ? 409 : 400);
  }
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
      expires_in_seconds: INTENT_TTL_SECONDS,
      metadata: { campaign_id: campaignId, contribution_id: row.contribution_id },
    }),
  });
  if (!intentRes.ok) {
    // Doprinos je nastao, intent nije — mjesta bi inace visjela drzana do
    // isteka provizornog TTL-a bez ikakvog nacina da se plate.
    if (slotKeys) {
      await admin.schema("pinka_finance").rpc("release_slot_holds", {
        p_contribution_id: row.contribution_id,
      }).then(() => {}, () => {});
    }
    return json({ error: "intent_create_failed", status: intentRes.status }, 502);
  }
  const intent = await intentRes.json();

  // 4) zalijepi sid na doprinos + produzi hold na stvarni vijek intenta.
  //    Hold i intent time umiru istovremeno PO KONSTRUKCIJI — nema prozora u
  //    kojem je intent ziv a mjesto vec oslobodeno.
  //    Rail HTTP API serijalizira expires_at kao ISO string
  //    ("2026-07-23T05:32:51.000Z"), NE kao UNIX broj (db.ts drzi broj interno,
  //    ali JSON odgovor je string) — pa prihvacamo oba oblika. Bez ovoga check
  //    padne na null i hold ostane na provizornih 10 min umjesto vijeka intenta
  //    (24 h): slot se oslobodi dok SEPA nalog jos putuje.
  const holdExpiresAt = parseExpiresAt(intent.expires_at);
  const { error: attachErr } = await admin
    .schema("pinka_finance")
    .rpc("attach_intent", {
      p_contribution_id: row.contribution_id,
      p_sid: intent.sid,
      p_monerium_order_id: null,
      p_hold_expires_at: holdExpiresAt,
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
    slot_keys: row.slot_keys ?? null,
    hold_expires_at: holdExpiresAt ?? row.hold_expires_at ?? null,
  }, 200);

  function json(b: unknown, status: number) {
    return new Response(JSON.stringify(b), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
