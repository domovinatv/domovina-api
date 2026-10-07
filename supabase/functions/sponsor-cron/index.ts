import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { notifyOwnerOfSale, processSponsorInvoice } from "../_shared/sponsor.ts";
import { timingSafeEqual } from "../_shared/ulaznice-hmac.ts";

// sponsor-cron — higijena i retry za sponzorske trenutke. Poziva ga pg_cron
// (pg_net) ili vanjski scheduler, npr. svakih 10 min:
//
//   POST /functions/v1/sponsor-cron   header  x-cron-secret: <SPONSOR_CRON_SECRET>
//
//   1. expire_live_slots()  — istekli zakupi u 'free' (ispravnost ne ovisi o
//                             ovome: view gleda live_until, checkout žanje sam)
//   2. računi koji nisu poslani (fiskal pao, timeout) — backoff u bazi; max 5
//      po pozivu (do 3 × 10 s fiskala svaki) da poziv ostane u wall-clock
//      limitu edge funkcije; ostatak ide u sljedeći krug
//   3. obavijesti vlasniku koje nisu otišle (max 5 pokušaja po doprinosu)
//
// verify_jwt = false — autentikacija je x-cron-secret.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("SPONSOR_CRON_SECRET") ?? "";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (SECRET.length < 16) return json({ error: "secret_not_configured" }, 500);
  if (!timingSafeEqual(req.headers.get("x-cron-secret") ?? "", SECRET)) {
    return json({ error: "unauthorized" }, 401);
  }

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const pf = admin.schema("pinka_finance");

  const { data: expired, error: expErr } = await pf.rpc("expire_live_slots");
  if (expErr) console.error(`[sponsor-cron] expire_live_slots: ${expErr.message}`);

  const { data: due } = await pf.rpc("sponsor_invoices_due", { p_limit: 5 });
  const invoices: unknown[] = [];
  for (const id of (due ?? []) as string[]) {
    invoices.push({ id, ...(await processSponsorInvoice(admin, id)) });
  }

  const { data: unnotified } = await pf.from("contributions")
    .select("id")
    .eq("is_sponsor", true).eq("state", "paid").is("owner_notified_at", null)
    .lt("owner_notify_attempts", 5)
    .order("paid_at", { ascending: true })
    .limit(10);
  for (const r of (unnotified ?? []) as { id: string }[]) await notifyOwnerOfSale(admin, r.id);

  return json({
    ok: true,
    expired: expired ?? null,
    invoices,
    notified: (unnotified ?? []).length,
  }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
}
