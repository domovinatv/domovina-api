import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-feed — javni discovery feed za wallet katalog (backend source uz
// config fallback u appu; E2 handoff: "može i direktan PostgREST select po
// RLS-u, odluka u sesiji" → edge fn, da app ne treba anon key ni PostgREST
// query jezik, nego jedan GET na isti functions base kao ostale events rute).
//
// Vraća SAMO javne podatke: aktivne public kampanje type='tickets' + events
// detalji + ticket tieri (bez holdera, bez narudžbi). verify_jwt=false.
//
// Paginacija/filtriranje (E4): ?grad=<venue_city> (case-insensitive substring),
// ?from=<ISO>/&to=<ISO> (events.starts_at prozor), ?limit=<1..100> (default 50),
// ?offset=<n>. Bez parametara ponašanje je identično E2 (prvih 50).

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const DEFAULT_LIMIT = 50;
const MAX_LIMIT = 100;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET") return json({ error: "method_not_allowed" }, 405);

  const params = new URL2(req.url).searchParams;
  const grad = (params.get("grad") ?? "").trim();
  const from = parseIso(params.get("from"));
  const to = parseIso(params.get("to"));
  const limit = clampInt(params.get("limit"), 1, MAX_LIMIT, DEFAULT_LIMIT);
  const offset = clampInt(params.get("offset"), 0, 100000, 0);

  const sb = createClient(URL, SERVICE, { auth: { persistSession: false } });
  let query = sb
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
    .is("deleted_at", null);

  // filtri na embedded events (inner join → filtriraju i parent redove)
  if (grad !== "") query = query.ilike("events.venue_city", `%${escapeLike(grad)}%`);
  if (from !== null) query = query.gte("events.starts_at", from);
  if (to !== null) query = query.lte("events.starts_at", to);

  const { data, error } = await query
    .order("created_at", { ascending: false })
    .range(offset, offset + limit - 1);
  if (error) return json({ error: error.message }, 500);

  type CampaignRow = {
    id: string;
    slug: string;
    title: string;
    state: string;
    destination_address: string | null;
    events: Record<string, unknown> | Record<string, unknown>[] | null;
    campaign_tiers: Array<Record<string, unknown> & { kind: string; sort: number }> | null;
  };

  const events = ((data ?? []) as unknown as CampaignRow[]).map((row) => {
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

  return json({ events, limit, offset }, 200);
});

const URL2 = globalThis.URL;

function parseIso(v: string | null): string | null {
  if (v === null || v.trim() === "") return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function clampInt(v: string | null, min: number, max: number, fallback: number): number {
  const n = Number(v);
  if (!Number.isInteger(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

// PostgREST like pattern: escapeaj %, _ i \ u korisničkom unosu
function escapeLike(v: string): string {
  return v.replace(/[\\%_]/g, (m) => `\\${m}`);
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
