import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-checkin — skener ulaza (E3): redeem QR ulaznice na registracijskom pultu.
//
// Autorizacija je ISKLJUČIVO server-side: pozivatelj mora poslati GoTrue JWT
// (Authorization header); redeem_ticket RPC dodatno traži
// has_role_on_account(campaign.account_id, 'admin') — org admin eventa.
// Klijentski "organizator mod" u walletu je samo UI; bez valjanog JWT-a i
// admin role sken NE prolazi. RPC se zove USER klijentom (anon key + header)
// pa auth.uid() u security definer tijelu odgovara skeneru.
//
// Idempotencija: drugi sken iste ulaznice vraća podatke PRVOG ulaska sa
// statusom 'already_checked_in' (anti-double-entry). verify_jwt=false jer
// getUser radimo interno (isti obrazac kao handoff-consume).

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const TOKEN_RE = /^[0-9a-f]{64}$/;
const QR_PREFIX = "dgdj1:";

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

  let body: { qr_token?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  // App šalje goli token; defenzivno prihvati i cijeli QR payload s prefiksom.
  let token = (body.qr_token ?? "").trim().toLowerCase();
  if (token.startsWith(QR_PREFIX)) token = token.slice(QR_PREFIX.length);
  if (!TOKEN_RE.test(token)) return json({ error: "invalid_token" }, 400);

  const { data, error } = await userClient
    .schema("pinka_finance")
    .rpc("redeem_ticket", { p_qr_token: token });
  if (error) {
    const code = normalizeDbError(error.message);
    return json({ error: code }, code === "not_authorized" ? 403 : 400);
  }

  return json(data ?? { status: "not_found" }, 200);
});

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
