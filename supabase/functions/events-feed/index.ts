import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-feed — javni discovery feed za wallet katalog (backend source uz
// config fallback u appu; E2 handoff: "može i direktan PostgREST select po
// RLS-u, odluka u sesiji" → edge fn, da app ne treba anon key ni PostgREST
// query jezik, nego jedan GET na isti functions base kao ostale events rute).
//
// Vraća SAMO javne podatke: aktivne public kampanje type='tickets' + events
// detalji + ticket tieri (bez holdera, bez narudžbi). verify_jwt=false.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return json({ error: "method_not_allowed" }, 405);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const { data, error } = await sb
    .schema("pinka_finance")
    .from("campaigns")
    .select(
      "id, slug, title, description, destination_address, state, " +
        "events!inner(event_type, venue_name, venue_address, venue_city, starts_at, ends_at, " +
        "timezone, description_hr, description_en, cover_image_url, organizer_name, organizer_email, organizer_web), " +
        "campaign_tiers(id, title, description, kind, price_cents, inventory_total, inventory_claimed, " +
        "imenska, sale_start, sale_end, sort)",
    )
    .eq("type", "tickets")
    .eq("visibility", "public")
    .in("state", ["active", "funded"])
    .is("deleted_at", null)
    .order("created_at", { ascending: false });
  if (error) return json({ error: error.message }, 500);

  const events = (data ?? []).map((row) => {
    const ev = Array.isArray(row.events) ? row.events[0] : row.events;
    const tiers = (row.campaign_tiers ?? [])
      .filter((t: { kind: string }) => t.kind === "ticket")
      .sort((a: { sort: number }, b: { sort: number }) => a.sort - b.sort)
      .map((t: Record<string, unknown>) => ({
        id: t.id,
        title: t.title,
        description: t.description,
        price_cents: t.price_cents,
        inventory_total: t.inventory_total,
        inventory_claimed: t.inventory_claimed,
        imenska: t.imenska,
        sale_start: t.sale_start,
        sale_end: t.sale_end,
      }));
    return {
      campaign_id: row.id,
      slug: row.slug,
      title: row.title,
      state: row.state,
      destination_address: row.destination_address,
      event: ev,
      tiers,
    };
  });

  return json({ events }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
