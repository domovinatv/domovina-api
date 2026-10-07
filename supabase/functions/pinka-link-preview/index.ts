import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";
import { isPublicHttpsUrl, storeOgImage } from "../_shared/og-image-cache.ts";
import { guestAllowed, guestKey, isGuestBearer } from "../_shared/guest.ts";

// pinka-link-preview — OG preview poveznice DOK donator tipka obrazac podrške
// (živi pregled kartice zida prije plaćanja).
//
// Zašto preko servera: preglednik ne smije sam dohvatiti tuđi URL (odao bi IP
// posjetitelja, a CORS ionako blokira). Metapodatke vadi pay-worker
// (`/api/og-preview`, Cloudflare Worker = SSRF-izoliran), a sliku spremamo u
// `pinka-og-cache` pod ISTIM ključem (sha256 URL-a) koji kasnije koristi
// pinka-webhook — preview i kartica na zidu dijele jedan objekt.
//
// Zloupotreba: bez plaćanja bi ovo bio javni image-proxy, pa je ograničen po
// korisniku (in-memory, po instanci — korisnik je poznat), a GOST (bez sesije;
// anonimne prijave se gase) po HMAC(IP) kroz pinka_finance.guest_rate_hit,
// dijeljeno kroz sve instance — inače bi ovo bio javni image-proxy u R2.
//
// POST { url } → { preview: { url, title, description, siteName,
//                             image_cached?, image_width?, image_height? } | null }

const URL_ = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const OG_KEY = Deno.env.get("INTENT_WEBHOOK_SECRET") ?? "";
const OG_PREVIEW_URL = Deno.env.get("OG_PREVIEW_URL") ?? "https://mpt.domovina.ai/api/og-preview";

const WINDOW_MS = 60_000;
const MAX_PER_WINDOW = 20;
const hits = new Map<string, number[]>();

function rateLimited(key: string): boolean {
  const now = Date.now();
  const recent = (hits.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  recent.push(now);
  hits.set(key, recent);
  if (hits.size > 5000) hits.clear(); // grubo čišćenje; limit je kočnica, ne ugovor
  return recent.length > MAX_PER_WINDOW;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const userClient = createClient(URL_, ANON, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const authHeader = req.headers.get("Authorization") ?? "";
  const guest = isGuestBearer(authHeader, ANON);
  const user = guest ? null : (await userClient.auth.getUser()).data.user;
  if (!guest && !user) return json({ error: "not_authenticated" }, 401);
  if (user && rateLimited(user.id)) return json({ error: "rate_limited" }, 429);
  if (guest) {
    const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
    // 30 / 10 min po IP-u: obrazac se tipka, preview se traži nakon debouncea
    if (!(await guestAllowed(admin, await guestKey(req, "link-preview"), 30, 600))) {
      return json({ error: "rate_limited" }, 429);
    }
  }

  const body = await req.json().catch(() => ({}));
  let target: URL;
  try {
    target = new URL(String(body.url ?? ""));
  } catch {
    return json({ preview: null }, 200);
  }
  if (target.toString().length > 500 || !(await isPublicHttpsUrl(target))) {
    return json({ preview: null }, 200);
  }

  const res = await fetch(OG_PREVIEW_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-og-key": OG_KEY },
    body: JSON.stringify({ url: target.toString() }),
  }).catch(() => null);
  if (!res?.ok) return json({ preview: null }, 200);
  const { preview } = (await res.json().catch(() => ({}))) as {
    preview?: { url: string; title?: string; description?: string; siteName?: string; image?: string | null };
  };
  if (!preview) return json({ preview: null }, 200);

  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const stored = await storeOgImage(admin, preview.image);
  // Tuđi `image` URL se NE vraća: klijent smije crtati samo našu kopiju.
  return json({
    preview: {
      url: preview.url,
      title: preview.title ?? null,
      description: preview.description ?? null,
      siteName: preview.siteName ?? null,
      ...(stored
        ? { image_cached: stored.url, image_width: stored.width, image_height: stored.height }
        : {}),
    },
  }, 200);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
