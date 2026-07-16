import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-organizer — organizator self-service (E4): pregled, kreiranje,
// uređivanje i objava eventa + DAC7 zapis. Jedna funkcija s action routerom
// (jedan deploy unit; iste 4xx/5xx semantike kao ostale events rute).
//
// Autorizacija je ISKLJUČIVO server-side: SVAKA akcija traži GoTrue JWT
// (Authorization header; isti "pristupni token" obrazac kao events-checkin),
// a RPC-evi dodatno provjeravaju has_role_on_account(account, 'admin').
// create_event/update_event su security INVOKER (RLS admin + KYC vrijedi);
// publish_event je DEFINER s eksplicitnim admin + allowlist + Safe gatingom.
// verify_jwt=false jer getUser radimo interno (obrazac handoff-consume).

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Draft bez Safe-a: placeholder nulta adresa (create_campaign traži adresu);
// publish_event i campaigns_write_guard blokiraju aktivaciju dok je nulta.
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

type Json = Record<string, unknown>;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(URL, ANON, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "not_authenticated" }, 401);

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const action = typeof body.action === "string" ? body.action : "";
  const rpc = (name: string, args: Json) =>
    userClient.schema("pinka_finance").rpc(name, args);

  switch (action) {
    case "overview": {
      const { data, error } = await rpc("organizer_overview", {});
      return respond(data, error);
    }

    case "create": {
      if (!UUID_RE.test(str(body.event_id))) return json({ error: "invalid_event_id" }, 400);
      if (!UUID_RE.test(str(body.account_id))) return json({ error: "invalid_account_id" }, 400);
      const { data, error } = await rpc("create_event", {
        p_id: body.event_id,
        p_account_id: body.account_id,
        p_title: str(body.title),
        p_destination_address: str(body.destination_address).trim() || ZERO_ADDRESS,
        p_venue_name: str(body.venue_name),
        p_venue_city: str(body.venue_city),
        p_event_type: str(body.event_type) || "ostalo",
        p_venue_address: opt(body.venue_address),
        p_starts_at: opt(body.starts_at),
        p_ends_at: opt(body.ends_at),
        p_timezone: str(body.timezone) || "Europe/Zagreb",
        p_description_hr: sanitizeUgc(opt(body.description_hr)),
        p_description_en: sanitizeUgc(opt(body.description_en)),
        p_cover_image_url: opt(body.cover_image_url),
        p_organizer_name: opt(body.organizer_name),
        p_organizer_email: opt(body.organizer_email),
        p_organizer_web: opt(body.organizer_web),
        p_visibility: "private", // objava (visibility=public) ide isključivo kroz publish_event
        p_tiers: Array.isArray(body.tiers) ? body.tiers : [],
      });
      return respond(data, error);
    }

    case "update": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const { data, error } = await rpc("update_event", {
        p_campaign_id: body.campaign_id,
        p_title: opt(body.title),
        p_destination_address: opt(body.destination_address),
        p_event_type: opt(body.event_type),
        p_venue_name: opt(body.venue_name),
        p_venue_address: nullable(body.venue_address),
        p_venue_city: opt(body.venue_city),
        p_starts_at: opt(body.starts_at),
        p_ends_at: opt(body.ends_at),
        p_timezone: opt(body.timezone),
        p_description_hr: nullable(body.description_hr),
        p_description_en: nullable(body.description_en),
        p_cover_image_url: nullable(body.cover_image_url),
        p_organizer_name: opt(body.organizer_name),
        p_organizer_email: nullable(body.organizer_email),
        p_organizer_web: nullable(body.organizer_web),
        p_tiers: Array.isArray(body.tiers) ? body.tiers : null,
      });
      return respond(data, error);
    }

    case "publish": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const target = str(body.target_state) || "active";
      const { data, error } = await rpc("publish_event", {
        p_campaign_id: body.campaign_id,
        p_target_state: target,
      });
      return respond(data, error);
    }

    case "record_upsert": {
      if (!UUID_RE.test(str(body.account_id))) return json({ error: "invalid_account_id" }, 400);
      const { data, error } = await rpc("upsert_organizer_record", {
        p_account_id: body.account_id,
        p_legal_name: str(body.legal_name),
        p_oib: str(body.oib),
        p_address_line: str(body.address_line),
        p_city: str(body.city),
        p_postal_code: str(body.postal_code),
        p_country_code: str(body.country_code) || "HR",
        p_contact_email: opt(body.contact_email),
        p_financial_identifier_type: str(body.financial_identifier_type) || "safe_address",
        p_financial_identifier: str(body.financial_identifier) || null,
      });
      return respond(data, error);
    }

    default:
      return json({ error: "unknown_action" }, 400);
  }
});

function respond(data: unknown, error: { message: string } | null) {
  if (error) {
    const code = normalizeDbError(error.message);
    const status = code === "not_authorized" ? 403 : code === "not_authenticated" ? 401 : 400;
    return json({ error: code }, status);
  }
  return json(data ?? {}, 200);
}

function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}

// undefined/prazno → null (RPC default), string → string
function opt(v: unknown): string | null {
  const s = str(v).trim();
  return s === "" ? null : s;
}

// null = "ne diraj"; prazan string = eksplicitno brisanje polja (update_event)
function nullable(v: unknown): string | null {
  return typeof v === "string" ? v : null;
}

// UGC u javnom feedu: makni C0 kontrolne znakove (osim \n i \t) — create put;
// update put sanitizira server-side (pinka_finance.sanitize_ugc).
function sanitizeUgc(v: string | null): string | null {
  if (v === null) return null;
  // deno-lint-ignore no-control-regex
  const clean = v.replace(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/g, "").trim();
  return clean === "" ? null : clean;
}

// PostgREST prefiksira poruku exceptiona; zadrži samo strojni kod kad je čist.
function normalizeDbError(message: string): string {
  const code = message.trim().split(/\s/)[0];
  return /^[a-z_]+$/.test(code) ? code : message;
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
