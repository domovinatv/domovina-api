// passkey — custom WebAuthn ceremony (register/login start+finish)
//
// GoTrue nema first-class passwordless passkey login (v2.186) → gradimo ceremoniju
// ovdje. 4 grane po URL pathname-u. verify_jwt=false u config.toml (kao handoff);
// auth se interno provjerava samo gdje treba (register-add-to-existing).
//
// Session bridge: nakon uspješne registracije/logina mintamo GoTrue magiclink
// preko admin.generateLink (isti pattern kao handoff-consume) → vraćamo action_link
// koji klijent otvori da dobije pravu sesiju s refresh tokenom.
//
// Library: @simplewebauthn/server v13 (esm.sh). Pohrana: public.user_passkeys +
// public.webauthn_challenges (service_role; RLS zatvoren za klijente).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "https://esm.sh/@simplewebauthn/server@13";
import { isoBase64URL } from "https://esm.sh/@simplewebauthn/server@13/helpers";
import { corsHeaders } from "../_shared/cors.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const RP_NAME = "DOMOVINA.ai";

// Dopušteni RP ID-evi i origini. Web prod + localhost dev. Native (iOS/Android)
// koristi origin formate koje @simplewebauthn prepoznaje preko AASA/assetlinks.
const KNOWN_RP_IDS = new Set(["domovina.ai", "localhost"]);
const EXTRA_ORIGINS = [
  "https://domovina.ai",
  "https://www.domovina.ai",
  "http://localhost:5173",
  "http://localhost:3000",
  // Android Credential Manager origin (apk-key-hash) i iOS app origin dopušteni
  // su preko AASA/assetlinks; @simplewebauthn ih validira preko expectedRPID.
];

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const path = new URL(req.url).pathname.replace(/.*\/passkey/, "");
  try {
    switch (path) {
      case "/register/start":
        return await registerStart(req);
      case "/register/finish":
        return await registerFinish(req);
      case "/login/start":
        return await loginStart(req);
      case "/login/finish":
        return await loginFinish(req);
      case "/list":
        return await listPasskeys(req);
      case "/delete":
        return await deletePasskey(req);
      default:
        return json({ error: "not_found", path }, 404);
    }
  } catch (e) {
    console.error("passkey error", path, e);
    return json({ error: String((e as Error)?.message ?? e) }, 400);
  }
});

// --- helpers ----------------------------------------------------------------

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// rpID iz Origin headera (web). Default na prod. Native klijent eksplicitno
// šalje rpId u tijelu pa to ima prednost.
function resolveRpId(req: Request, bodyRpId?: string): string {
  if (bodyRpId && KNOWN_RP_IDS.has(bodyRpId)) return bodyRpId;
  const origin = req.headers.get("Origin") ?? "";
  try {
    const host = new URL(origin).hostname;
    if (host === "localhost" || host === "127.0.0.1") return "localhost";
    if (host.endsWith("domovina.ai")) return "domovina.ai";
  } catch (_) { /* ignore */ }
  return "domovina.ai";
}

function expectedOrigins(req: Request): string[] {
  const origin = req.headers.get("Origin");
  const set = new Set(EXTRA_ORIGINS);
  if (origin) set.add(origin);
  return [...set];
}

// Vrati PERMANENT (non-anon) signed-in usera za "add passkey to existing account".
// App uvijek nosi anon JWT (signInAnonymously na startu) — anon user NIJE
// signed-in u ovom smislu, tretira se kao new-signup. Vraćamo null za njega.
async function maybeUser(req: Request) {
  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader) return null;
  const userClient = createClient(URL_, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user || user.is_anonymous) return null;
  return user;
}

// Mint GoTrue magiclink. Vraćamo i email_otp (6-zn. kod) i action_link.
// Klijent PRIMARNO koristi email_otp preko verifyOTP (direktan session, bez
// redirecta) — redirect/PKCE flow se na webu ne uhvati jer je link server-
// generiran (nema PKCE verifier na klijentu). action_link ostaje kao fallback.
async function mintSession(email: string, redirectTo: string) {
  const { data, error } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email,
    options: { redirectTo },
  });
  if (error) throw error;
  return {
    email_otp: data?.properties?.email_otp as string | undefined,
    action_link: data?.properties?.action_link as string | undefined,
  };
}

// --- register ---------------------------------------------------------------

async function registerStart(req: Request) {
  const { email, rpId } = await req.json().catch(() => ({}));
  const user = await maybeUser(req);
  const rpID = resolveRpId(req, rpId);

  // Email: signed-in koristi svoj; new-signup mora dostaviti.
  const accountEmail: string | undefined = user?.email ?? email;
  if (!accountEmail || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(accountEmail)) {
    return json({ error: "email_required" }, 400);
  }

  // excludeCredentials: spriječi duplu registraciju na istom autentifikatoru.
  let excludeCredentials: { id: string; transports?: string[] }[] = [];
  if (user) {
    const { data: existing } = await admin
      .from("user_passkeys")
      .select("credential_id, transports")
      .eq("user_id", user.id);
    excludeCredentials = (existing ?? []).map((r) => ({
      id: r.credential_id as string,
      transports: (r.transports as string[]) ?? undefined,
    }));
  }

  // userID handle: stabilan za postojećeg usera, random za new-signup.
  const userID = user
    ? isoBase64URL.toBuffer(isoBase64URL.fromUTF8String(user.id))
    : crypto.getRandomValues(new Uint8Array(32));

  const options = await generateRegistrationOptions({
    rpName: RP_NAME,
    rpID,
    userName: accountEmail,
    userID,
    attestationType: "none",
    excludeCredentials,
    authenticatorSelection: {
      residentKey: "required",        // discoverable → passwordless returning login
      userVerification: "preferred",
    },
  });

  await admin.from("webauthn_challenges").insert({
    challenge: options.challenge,
    kind: "register",
    user_id: user?.id ?? null,
    email: user ? null : accountEmail,
  });

  return json({ options, rpId: rpID }, 200);
}

async function registerFinish(req: Request) {
  const { challenge, credential, deviceName, anonId, rpId } = await req.json()
    .catch(() => ({}));
  if (!challenge || !credential) return json({ error: "missing_params" }, 400);
  const rpID = resolveRpId(req, rpId);

  const ch = await loadChallenge(challenge, "register");
  if (!ch) return json({ error: "challenge_not_found_or_expired" }, 400);

  const verification = await verifyRegistrationResponse({
    response: credential,
    expectedChallenge: challenge,
    expectedOrigin: expectedOrigins(req),
    expectedRPID: rpID,
    requireUserVerification: false,
  });
  if (!verification.verified || !verification.registrationInfo) {
    return json({ error: "verification_failed" }, 400);
  }

  const info = verification.registrationInfo.credential;

  // Odredi ciljnog usera: postojeći (add-to-existing) ili kreiraj novog (signup).
  let userId = ch.user_id as string | null;
  let email = ch.email as string | null;
  if (!userId) {
    if (!email) return json({ error: "challenge_missing_email" }, 400);
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email,
      email_confirm: true,   // passkey je dokaz posjedovanja; action_link potvrđuje email
    });
    if (cErr || !created?.user) {
      // Email već postoji → uputi usera na login passkeyom umjesto registracije.
      return json({ error: "user_create_failed", detail: cErr?.message }, 400);
    }
    userId = created.user.id;
  } else {
    const { data: u } = await admin.auth.admin.getUserById(userId);
    email = u?.user?.email ?? null;
  }

  await admin.from("user_passkeys").insert({
    user_id: userId,
    credential_id: info.id,
    public_key: isoBase64URL.fromBuffer(info.publicKey),
    sign_count: info.counter ?? 0,
    transports: info.transports ?? null,
    device_name: deviceName ?? null,
  });

  await admin.from("webauthn_challenges").delete().eq("id", ch.id);

  if (!email) return json({ error: "no_email_for_session" }, 400);
  const session = await mintSession(email, deepLinkRedirect(req));

  return json({ ...session, email, user_id: userId, anon_id: anonId ?? null }, 200);
}

// --- login -------------------------------------------------------------------

async function loginStart(req: Request) {
  const { rpId } = await req.json().catch(() => ({}));
  const rpID = resolveRpId(req, rpId);

  const options = await generateAuthenticationOptions({
    rpID,
    userVerification: "preferred",
    allowCredentials: [],   // discoverable — autentifikator nudi resident credential
  });

  await admin.from("webauthn_challenges").insert({
    challenge: options.challenge,
    kind: "login",
  });

  return json({ options, rpId: rpID }, 200);
}

async function loginFinish(req: Request) {
  const { challenge, credential, rpId } = await req.json().catch(() => ({}));
  if (!challenge || !credential) return json({ error: "missing_params" }, 400);
  const rpID = resolveRpId(req, rpId);

  const ch = await loadChallenge(challenge, "login");
  if (!ch) return json({ error: "challenge_not_found_or_expired" }, 400);

  const credId: string = credential.id ?? credential.rawId;
  const { data: stored } = await admin
    .from("user_passkeys")
    .select("id, user_id, public_key, sign_count, transports")
    .eq("credential_id", credId)
    .maybeSingle();
  if (!stored) return json({ error: "unknown_credential" }, 400);

  const verification = await verifyAuthenticationResponse({
    response: credential,
    expectedChallenge: challenge,
    expectedOrigin: expectedOrigins(req),
    expectedRPID: rpID,
    requireUserVerification: false,
    credential: {
      id: credId,
      publicKey: isoBase64URL.toBuffer(stored.public_key as string),
      counter: Number(stored.sign_count ?? 0),
      transports: (stored.transports as string[]) ?? undefined,
    },
  });
  if (!verification.verified) return json({ error: "verification_failed" }, 400);

  await admin
    .from("user_passkeys")
    .update({
      sign_count: verification.authenticationInfo.newCounter,
      last_used_at: new Date().toISOString(),
    })
    .eq("id", stored.id);

  await admin.from("webauthn_challenges").delete().eq("id", ch.id);

  const { data: u } = await admin.auth.admin.getUserById(stored.user_id as string);
  const email = u?.user?.email;
  if (!email) return json({ error: "no_email_for_session" }, 400);

  const session = await mintSession(email, deepLinkRedirect(req));
  return json({ ...session, email, user_id: stored.user_id }, 200);
}

// --- account management (Moj račun) -------------------------------------------
// Spec: domovina.ai docs/backend-prompts/10-account-management.md.
// verify_jwt=false na funkciji (login grane) → ove grane ručno traže
// PERMANENT signed-in usera iz Authorization headera (maybeUser).

async function listPasskeys(req: Request) {
  const user = await maybeUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { data, error } = await admin
    .from("user_passkeys")
    .select("id, device_name, created_at, last_used_at")
    .eq("user_id", user.id)
    .order("created_at", { ascending: true });
  if (error) throw error;

  return json({ passkeys: data ?? [] }, 200);
}

async function deletePasskey(req: Request) {
  const user = await maybeUser(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { id } = await req.json().catch(() => ({}));
  if (!id) return json({ error: "missing_params" }, 400);

  // user_id guard: korisnik smije brisati SAMO svoje passkeyje. Namjerno ne
  // blokiramo brisanje zadnjeg — prijava magic linkom/OAuth-om uvijek ostaje.
  // Row-not-found je 400 (ne 404): klijent 404 tumači kao "grana ne postoji".
  const { data, error } = await admin
    .from("user_passkeys")
    .delete()
    .eq("id", id)
    .eq("user_id", user.id)
    .select("id");
  if (error) throw error;
  if (!data?.length) return json({ error: "not_found" }, 400);

  return json({ ok: true }, 200);
}

// --- shared ------------------------------------------------------------------

async function loadChallenge(challenge: string, kind: "register" | "login") {
  const { data } = await admin
    .from("webauthn_challenges")
    .select("id, user_id, email, kind, expires_at")
    .eq("challenge", challenge)
    .eq("kind", kind)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  return data ?? null;
}

// redirectTo za action_link: web ostaje na origin/auth/callback, native deep link.
function deepLinkRedirect(req: Request): string {
  const origin = req.headers.get("Origin");
  if (origin && /^https?:\/\/(localhost|127\.0\.0\.1|.*domovina\.ai)/.test(origin)) {
    return `${origin}/auth/callback`;
  }
  return "ai.domovina://auth/callback";
}
