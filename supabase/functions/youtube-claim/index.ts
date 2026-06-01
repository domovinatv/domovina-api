// youtube-claim — dokaz vlasništva nad YouTube kanalom (UC…) preko vlastitog
// Google OAuth flowa (NE GoTrue Google provider — Princip D iz plana).
//
// Tri sub-rute (klijent zove youtube-claim/<sub>):
//   start    → generira PKCE+state, vrati Google consent authUrl
//   callback → server-side code→token exchange + channels.list?mine=true +
//              UC… match + upsert verified claim
//   reverify → D4: ponovi provjeru ako je claim stariji od 90 dana
//
// PRINCIP A: channel ID s klijenta NIJE dokaz. Jedini izvor istine je
// channels.list?mine=true koji OVDJE pozovemo s tokenom dobivenim server-side
// exchange-om. Access token NIKAD ne ide klijentu.
//
// Plan: domovina.ai/docs/channel-ownership-and-safe-payout-plan.md §6
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
// Feature-scoped naming (YOUTUBE_CLAIM_*) — u Coolify dijeljenom env poolu jasno
// odvojeno od GoTrue Google login clienta (GOTRUE_EXTERNAL_GOOGLE_*). Dedicirani
// client, Princip D iz plana.
const GOOGLE_CLIENT_ID = Deno.env.get("YOUTUBE_CLAIM_GOOGLE_CLIENT_ID")!;
const GOOGLE_CLIENT_SECRET = Deno.env.get("YOUTUBE_CLAIM_GOOGLE_CLIENT_SECRET")!;
const REDIRECT_URI = Deno.env.get("YOUTUBE_CLAIM_REDIRECT_URI") ??
  "https://domovina.ai/youtube-claim/callback";

const UC_RE = /^UC[0-9A-Za-z_-]{22}$/;
const STATE_TTL_MIN = 10;
const REVERIFY_DAYS = 90;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Sub-ruta iz path suffixa (…/youtube-claim/<sub>).
  const path = new URL(req.url).pathname;
  const sub = path.split("/").filter(Boolean).pop();

  try {
    if (sub === "start") return await handleStart(req);
    if (sub === "callback") return await handleCallback(req);
    if (sub === "reverify") return await handleReverify(req);
    if (sub === "revoke") return await handleRevoke(req);
    return json({ error: "unknown_route" }, 404);
  } catch (e) {
    console.error("youtube-claim error", sub, e);
    return json({ error: String((e as Error)?.message ?? e) }, 400);
  }
});

// Resolve prijavljenog (ne-anon) usera iz Authorization headera.
async function getUser(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(URL_, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  return user;
}

// ── start ───────────────────────────────────────────────────────────────────
async function handleStart(req: Request) {
  const user = await getUser(req);
  if (!user || user.is_anonymous) return json({ error: "not_signed_in" }, 401);

  const { channelId } = await req.json().catch(() => ({}));
  if (!channelId || !UC_RE.test(channelId)) {
    return json({ error: "invalid_channel_id" }, 400);
  }

  // PKCE: code_verifier (random) + code_challenge = base64url(SHA256(verifier)).
  const verifier = randomToken(64);
  const challenge = await s256(verifier);
  const state = randomToken(32);

  const { error } = await admin.schema("domovina_ai").from("oauth_states").insert({
    state,
    account_id: user.id,
    youtube_channel_id: channelId,
    code_verifier: verifier,
    purpose: "youtube_claim",
    expires_at: new Date(Date.now() + STATE_TTL_MIN * 60_000).toISOString(),
  });
  if (error) return json({ error: "state_store_failed", detail: error.message }, 500);

  const authUrl = "https://accounts.google.com/o/oauth2/v2/auth?" +
    new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      response_type: "code",
      scope: "openid https://www.googleapis.com/auth/youtube.readonly",
      access_type: "offline",
      include_granted_scopes: "true",
      state,
      code_challenge: challenge,
      code_challenge_method: "S256",
      prompt: "consent",
    }).toString();

  return json({ authUrl }, 200);
}

// ── callback ──────────────────────────────────────────────────────────────────
async function handleCallback(req: Request) {
  const { code, state } = await req.json().catch(() => ({}));
  if (!code || !state) return json({ ok: false, error: "missing_params" }, 400);

  // 1. Dohvati + obriši state (jednokratan), provjeri TTL.
  const { data: st } = await admin.schema("domovina_ai").from("oauth_states")
    .select().eq("state", state).maybeSingle();
  if (st) {
    await admin.schema("domovina_ai").from("oauth_states").delete().eq("state", state);
  }
  if (!st || new Date(st.expires_at).getTime() < Date.now()) {
    return json({ ok: false, error: "invalid_state" }, 400);
  }

  // 2. Server-side code→token exchange (PKCE verifier).
  const token = await exchangeCode(code, st.code_verifier);
  if (!token?.access_token) return json({ ok: false, error: "token_exchange_failed" }, 400);

  // 3. channels.list?mine=true — jedini izvor istine za vlasništvo.
  const mine = await listMyChannels(token.access_token);
  if (!mine.length) return json({ ok: false, error: "no_channel" }, 200);

  // 4. UC… match prema ciljanom kanalu iz state-a.
  const target = mine.find((c) => c.id === st.youtube_channel_id);
  if (!target) return json({ ok: false, error: "channel_mismatch" }, 200);

  // 5. Role: ako već postoji verified primary drugog accounta → collaborator.
  const googleSub = await googleSubFromIdToken(token.id_token);
  const claim = await upsertVerifiedClaim({
    accountId: st.account_id,
    channelId: target.id,
    channelTitle: target.title,
    googleSub,
  });
  return json({ ok: true, claim }, 200);
}

// ── reverify (D4) ─────────────────────────────────────────────────────────────
async function handleReverify(req: Request) {
  const user = await getUser(req);
  if (!user || user.is_anonymous) return json({ error: "not_signed_in" }, 401);

  const { claimId } = await req.json().catch(() => ({}));
  if (!claimId) return json({ ok: false, error: "missing_params" }, 400);

  const { data: claim } = await admin.schema("domovina_ai").from("channel_claims")
    .select().eq("id", claimId).eq("account_id", user.id).maybeSingle();
  if (!claim) return json({ ok: false, error: "not_found" }, 404);

  // Reverify zahtijeva svjež OAuth consent (nemamo pohranjen refresh token u
  // ovoj verziji) — vrati reason koji klijent mapira na "pokreni start ponovo".
  // Status ostaje verified dok se ne dokaže suprotno; klijent inicira /start.
  return json({ ok: false, error: "reverify_requires_consent", claim }, 200);
}

// ── revoke ────────────────────────────────────────────────────────────────────
// Vlasnik otkvači (odriče se) vlastitog claima. Soft-revoke: status='revoked'
// (čuva audit; oslobađa one_primary_per_channel partial unique → kanal opet
// claimable). account_id check = dokaz vlasništva nad redom.
async function handleRevoke(req: Request) {
  const user = await getUser(req);
  if (!user || user.is_anonymous) return json({ error: "not_signed_in" }, 401);

  const { claimId } = await req.json().catch(() => ({}));
  if (!claimId) return json({ ok: false, error: "missing_params" }, 400);

  const { data: claim, error } = await admin.schema("domovina_ai")
    .from("channel_claims")
    .update({ status: "revoked" })
    .eq("id", claimId)
    .eq("account_id", user.id)
    .neq("status", "revoked")
    .select()
    .maybeSingle();
  if (error) return json({ ok: false, error: "revoke_failed", detail: error.message }, 500);
  if (!claim) return json({ ok: false, error: "not_found" }, 404);
  return json({ ok: true, claim }, 200);
}

// ── Google OAuth helpers ──────────────────────────────────────────────────────
async function exchangeCode(code: string, verifier: string) {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      redirect_uri: REDIRECT_URI,
      grant_type: "authorization_code",
      code_verifier: verifier,
    }),
  });
  if (!res.ok) {
    console.error("token exchange failed", res.status, await res.text());
    return null;
  }
  return await res.json();
}

async function listMyChannels(
  accessToken: string,
): Promise<Array<{ id: string; title: string | null }>> {
  const res = await fetch(
    "https://www.googleapis.com/youtube/v3/channels?part=id,snippet&mine=true",
    { headers: { Authorization: `Bearer ${accessToken}` } },
  );
  if (!res.ok) {
    console.error("channels.list failed", res.status, await res.text());
    return [];
  }
  const data = await res.json();
  return (data.items ?? []).map((it: Record<string, unknown>) => ({
    id: it.id as string,
    title: (it.snippet as Record<string, unknown> | undefined)?.title as string ?? null,
  }));
}

async function googleSubFromIdToken(idToken?: string): Promise<string> {
  if (!idToken) return "";
  try {
    const payload = JSON.parse(atob(idToken.split(".")[1]));
    return (payload.sub as string) ?? "";
  } catch {
    return "";
  }
}

// Upsert verified claim (service-role). D2: jedan verified primary po kanalu.
async function upsertVerifiedClaim(p: {
  accountId: string;
  channelId: string;
  channelTitle: string | null;
  googleSub: string;
}) {
  // Postoji li verified primary DRUGOG accounta? → ovaj postaje collaborator.
  const { data: existingPrimary } = await admin.schema("domovina_ai")
    .from("channel_claims").select("account_id")
    .eq("youtube_channel_id", p.channelId)
    .eq("role", "primary").eq("status", "verified").maybeSingle();
  const role = existingPrimary && existingPrimary.account_id !== p.accountId
    ? "collaborator"
    : "primary";

  const now = new Date().toISOString();
  const { data, error } = await admin.schema("domovina_ai").from("channel_claims")
    .upsert({
      account_id: p.accountId,
      youtube_channel_id: p.channelId,
      channel_title: p.channelTitle,
      google_sub: p.googleSub,
      role,
      status: "verified",
      method: "youtube_oauth",
      verified_at: now,
      last_checked_at: now,
    }, { onConflict: "account_id,youtube_channel_id" })
    .select().single();
  if (error) throw new Error(`claim_upsert_failed: ${error.message}`);
  return data;
}

// ── crypto / util ─────────────────────────────────────────────────────────────
function randomToken(bytes: number): string {
  const arr = new Uint8Array(bytes);
  crypto.getRandomValues(arr);
  return b64url(arr);
}

async function s256(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return b64url(new Uint8Array(digest));
}

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Unused-suppression marker for REVERIFY_DAYS (referenced in plan/docs, kept for
// future refresh-token reverify implementation).
void REVERIFY_DAYS;
