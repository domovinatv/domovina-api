// certilia — bridge Certilia/NIAS eID identitet → Supabase sesija.
//
// Klijent (flutter_certilia) odradi OIDC flow preko certilia.domovina.ai proxyja
// i dobije Certilia idToken. Ovdje ga VERIFICIRAMO protiv Certilia JWKS
// (issuer + audience), pročitamo trusted claimove (oib, email?, ime), upsertamo
// GoTrue usera keyed po OIB-derived emailu i vratimo email_otp — klijent ga
// verificira preko verifyOTP (isti session-bridge kao passkey).
//
// OIB je osjetljiv PII → ide u app_metadata (admin-only), NE user_metadata.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";
import { corsHeaders } from "../_shared/cors.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CERTILIA_ISSUER =
  Deno.env.get("CERTILIA_ISSUER") ?? "https://idp.certilia.com";
const CERTILIA_CLIENT_ID = Deno.env.get("CERTILIA_CLIENT_ID")!;
const DISCOVERY =
  `${CERTILIA_ISSUER}/oauth2/oidcdiscovery/.well-known/openid-configuration`;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

// JWKS remote set (interno cacheira ključeve s TTL-om).
let _jwks: ReturnType<typeof jose.createRemoteJWKSet> | null = null;
async function getJwks() {
  if (_jwks) return _jwks;
  const disc = await fetch(DISCOVERY).then((r) => r.json());
  if (!disc?.jwks_uri) throw new Error("certilia_discovery_failed");
  _jwks = jose.createRemoteJWKSet(new URL(disc.jwks_uri));
  return _jwks;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const { idToken, anonId } = await req.json().catch(() => ({}));
    if (!idToken) return json({ error: "missing_id_token" }, 400);

    // 1. Verificiraj idToken (potpis + iss + aud). NE vjeruj klijentu.
    let payload: jose.JWTPayload;
    try {
      const res = await jose.jwtVerify(idToken, await getJwks(), {
        issuer: CERTILIA_ISSUER,
        audience: CERTILIA_CLIENT_ID,
      });
      payload = res.payload;
    } catch (e) {
      return json({ error: "invalid_token", detail: String((e as Error)?.message ?? e) }, 401);
    }

    // 2. Trusted claimovi.
    const oib = (payload.oib ?? payload.pin) as string | undefined;
    if (!oib) return json({ error: "no_oib_claim" }, 400);
    const realEmail = (payload.email as string | undefined) || undefined;
    const fullName =
      [payload.given_name, payload.family_name].filter(Boolean).join(" ") ||
      (payload.name as string | undefined) ||
      null;

    // OIB-derived canonical email → ista osoba uvijek mapira na istog GoTrue
    // usera, neovisno o tome vrati li Certilia email.
    const canonicalEmail = realEmail ?? `certilia-${oib}@users.domovina.ai`;
    const appMeta = {
      oib,
      certilia_sub: payload.sub,
      full_name: fullName,
      real_email: realEmail ?? null,
      provider: "certilia",
    };

    // 3. Upsert GoTrue user keyed po canonicalEmail.
    let userId: string | undefined;
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email: canonicalEmail,
      email_confirm: true,
      app_metadata: appMeta,
    });
    if (created?.user) {
      userId = created.user.id;
    } else if (cErr && !/registered|exists/i.test(cErr.message)) {
      return json({ error: "user_create_failed", detail: cErr.message }, 400);
    }

    // 4. generateLink magiclink → email_otp (+ user.id za postojećeg usera).
    const { data: link, error: lErr } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email: canonicalEmail,
    });
    if (lErr) return json({ error: "link_failed", detail: lErr.message }, 400);
    userId ??= link?.user?.id;

    // Osvježi app_metadata za postojećeg usera (npr. promjena imena/emaila).
    if (userId) {
      await admin.auth.admin.updateUserById(userId, { app_metadata: appMeta });
    }

    return json({
      email_otp: link?.properties?.email_otp,
      email: canonicalEmail,
      user_id: userId,
      anon_id: anonId ?? null,
    }, 200);
  } catch (e) {
    console.error("certilia error", e);
    return json({ error: String((e as Error)?.message ?? e) }, 400);
  }

  function json(body: unknown, status: number) {
    return new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
