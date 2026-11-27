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
//
// Galerija (2026-11-24, editor u domovina-ulaznice web/): create i update
// primaju `gallery` ([{url}], ≤ 20; alt tekst editor ne šalje). Od sheme
// `ulaznice` (S4) galerija i attendance_mode idu kroz parametre p_gallery i
// p_attendance_mode RPC-a update_event (DEFINER, admin računa; ista pravila i
// kodovi kao parseMedia), ne izravnim `update events`: kod update akcije je to
// jedan atomarni poziv, kod create drugi poziv odmah nakon create_event (koji
// te parametre nema). Oblik se i dalje provjerava PRIJE RPC-a, da loša
// galerija ne ostavi napola spremljen događaj.
//
// Uređivanje i brisanje skice (2026-11-24): update prima `remove_tier_ids`
// (vrste ulaznica koje je organizator maknuo u editoru); brišu se samo dok je
// događaj skica, korisnikovim klijentom (RLS `ticket_tiers_write`, admin
// računa; trigger `ticket_tiers_write_guard` i sam baca event_not_draft /
// tier_has_orders).
// `delete` zove `delete_event_draft` (DEFINER: admin, samo skica bez narudžbi).
//
// Besplatni i online (2026-11-25, migracija events_free_online): create i update
// primaju `attendance_mode` (physical | online; upisuje se uz galeriju) i
// `online_url` (https, ≤ 1000; `""` briše), koji ide u `event_access` (nije
// javan; RLS admin računa; jedini preostali izravni pis uz brisanje tierova). Online događaj bez upisanog mjesta/grada dobije
// „Online” jer su venue_name i venue_city NOT NULL. Besplatan događaj je samo
// tier s cijenom 0; ovdje za njega nema posebnog polja.
//
// Odobravanje (2026-11-25): `submit` (organizator), `review_queue`, `approve`,
// `reject` (admin platforme). Skica poslana na odobrenje ima submitted_at;
// odobrenje je postavi u active + public.
//
// Arhiva (2026-11-27): `archive` i `unarchive` (admin računa ili admin
// platforme) premještaju objavljeni događaj u kantu i natrag; `platform_events`
// (admin platforme) daje sve objavljene i arhivirane događaje svih organizatora.

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// p_destination_address ostaje u potpisu create_event (odluka 3), ali ga
// ulaznice.create_event odbacuje (onchain ukinut, odluka 110); placeholder
// ostaje da HTTP ugovor i poziv budu isti.
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
    userClient.schema("ulaznice").rpc(name, args);
  const db = userClient.schema("ulaznice");
  // Samo skica: objavljenom događaju kupci su kupovali pod tim vrstama.
  // Čitanje stanja ostaje: nevidljiv događaj daje campaign_not_found (brisanje
  // bi tiho obrisalo 0 redaka), a 409 dolazi prije ijednog pisa.
  const removeDraftTiers = async (eventId: string, ids: string[]): Promise<string | null> => {
    const { data: e } = await db.from("events").select("state").eq("id", eventId).maybeSingle();
    if (!e) return "campaign_not_found";
    if ((e as { state: string }).state !== "draft") return "event_not_draft";
    const { error } = await db.from("ticket_tiers").delete().eq("event_id", eventId).in("id", ids);
    return error ? normalizeDbError(error.message) : null;
  };
  // gallery / attendance_mode → parametri update_event (null = ne diraj)
  const mediaArgs = (media: Media) => ({
    p_gallery: media.gallery ?? null,
    p_attendance_mode: media.attendance_mode ?? null,
  });
  const hasEventMedia = (media: Media) => media.gallery !== undefined || media.attendance_mode !== undefined;
  const saveOnlineUrl = async (eventId: string, media: Media) => {
    if (media.online_url === undefined) return null;
    const { error } = await db
      .from("event_access")
      .upsert({ event_id: eventId, online_url: media.online_url, updated_at: new Date().toISOString() });
    return error;
  };
  const online = (media: Media) => media.attendance_mode === "online";

  switch (action) {
    case "overview": {
      const { data, error } = await rpc("organizer_overview", {});
      return respond(data, error);
    }

    case "create": {
      if (!UUID_RE.test(str(body.event_id))) return json({ error: "invalid_event_id" }, 400);
      if (!UUID_RE.test(str(body.account_id))) return json({ error: "invalid_account_id" }, 400);
      const media = parseMedia(body);
      if ("error" in media) return json(media, 400);
      const { data, error } = await rpc("create_event", {
        p_id: body.event_id,
        p_account_id: body.account_id,
        p_title: str(body.title),
        p_destination_address: str(body.destination_address).trim() || ZERO_ADDRESS,
        p_venue_name: str(body.venue_name).trim() || (online(media) ? ONLINE : ""),
        p_venue_city: str(body.venue_city).trim() || (online(media) ? ONLINE : ""),
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
      if (error) return respond(data, error);
      if (hasEventMedia(media)) {
        const { error: mErr } = await rpc("update_event", { p_campaign_id: body.event_id, ...mediaArgs(media) });
        if (mErr) return respond(null, mErr);
      }
      return respond(data, await saveOnlineUrl(str(body.event_id), media));
    }

    case "update": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const media = parseMedia(body);
      if ("error" in media) return json(media, 400);
      const remove = Array.isArray(body.remove_tier_ids) ? body.remove_tier_ids : [];
      if (remove.length > 50 || !remove.every((id) => UUID_RE.test(str(id)))) {
        return json({ error: "invalid_tier_id" }, 400);
      }
      if (remove.length > 0) {
        const removeError = await removeDraftTiers(str(body.campaign_id), remove as string[]);
        if (removeError) return json({ error: removeError }, removeError === "event_not_draft" ? 409 : 400);
      }
      const { data, error } = await rpc("update_event", {
        p_campaign_id: body.campaign_id,
        p_title: opt(body.title),
        p_destination_address: opt(body.destination_address),
        p_event_type: opt(body.event_type),
        p_venue_name: opt(body.venue_name) ?? (online(media) ? ONLINE : null),
        p_venue_address: nullable(body.venue_address),
        p_venue_city: opt(body.venue_city) ?? (online(media) ? ONLINE : null),
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
        ...mediaArgs(media),
      });
      if (error) return respond(data, error);
      return respond(data, await saveOnlineUrl(str(body.campaign_id), media));
    }

    case "delete": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const { data, error } = await rpc("delete_event_draft", { p_campaign_id: body.campaign_id });
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

    // Odobravanje (2026-11-25, migracija ulaznice_odobrenje): organizator šalje
    // skicu, admin platforme (ulaznice.platform_admins) je odobri ili vrati.
    // Ovlasti provjeravaju RPC-i (DEFINER), ne ova funkcija.
    case "submit": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const { data, error } = await rpc("submit_event_for_review", { p_campaign_id: body.campaign_id });
      return respond(data, error);
    }

    case "review_queue": {
      const { data, error } = await rpc("review_queue", {});
      return respond(data, error);
    }

    case "approve": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const { data, error } = await rpc("approve_event", { p_campaign_id: body.campaign_id });
      return respond(data, error);
    }

    case "reject": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const note = opt(body.note);
      if (note !== null && note.length > 1000) return json({ error: "invalid_review_note" }, 400);
      const { data, error } = await rpc("reject_event", { p_campaign_id: body.campaign_id, p_note: note });
      return respond(data, error);
    }

    case "archive":
    case "unarchive": {
      if (!UUID_RE.test(str(body.campaign_id))) return json({ error: "invalid_campaign_id" }, 400);
      const fn = action === "archive" ? "archive_event" : "unarchive_event";
      const { data, error } = await rpc(fn, { p_campaign_id: body.campaign_id });
      return respond(data, error);
    }

    case "platform_events": {
      const { data, error } = await rpc("platform_events", {});
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

// ── galerija, način održavanja, link ────────────────────────────────────────────────────────────────
// Ista pravila kao cover_image_url (https, ≤ 1000) i kao check u bazi (≤ 20
// stavki). Ključ koji nije poslan se ne dira; prazna lista briše.

type Media = {
  gallery?: Array<{ url: string }>;
  attendance_mode?: "physical" | "online";
  online_url?: string | null; // ide u event_access, ne u events
};

const ONLINE = "Online";

const MAX_GALLERY = 20;

function parseMedia(body: Json): Media | { error: string } {
  const media: Media = {};
  if ("gallery" in body && body.gallery !== null) {
    if (!Array.isArray(body.gallery) || body.gallery.length > MAX_GALLERY) return { error: "invalid_gallery" };
    const gallery: Array<{ url: string }> = [];
    for (const item of body.gallery) {
      const url = str((item && typeof item === "object" ? (item as Json) : {}).url).trim();
      if (!/^https:\/\/\S+$/i.test(url) || url.length > 1000) return { error: "invalid_gallery_url" };
      gallery.push({ url });
    }
    media.gallery = gallery;
  }
  if ("attendance_mode" in body && body.attendance_mode !== null) {
    if (body.attendance_mode !== "physical" && body.attendance_mode !== "online") {
      return { error: "invalid_attendance_mode" };
    }
    media.attendance_mode = body.attendance_mode;
  }
  if ("online_url" in body && body.online_url !== null) {
    const url = str(body.online_url).trim();
    if (url !== "" && (!/^https:\/\/\S+$/i.test(url) || url.length > 1000)) return { error: "invalid_online_url" };
    media.online_url = url === "" ? null : url;
  }
  return media;
}

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
// update put sanitizira server-side (ulaznice.sanitize_ugc; od S3b i create).
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
