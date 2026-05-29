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
// Ključ za enkripciju OIB-a u public.identity_verifications (pgcrypto). NIKAD u bazi.
const KYC_ENCRYPTION_KEY = Deno.env.get("KYC_ENCRYPTION_KEY")!;
const DISCOVERY =
  `${CERTILIA_ISSUER}/oauth2/oidcdiscovery/.well-known/openid-configuration`;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

// JWKS remote set + kanonski issuer iz discovery dokumenta.
// CERTILIA_ISSUER je BAZA za discovery URL (npr. https://idp.certilia.com), ali
// stvarni `iss` u tokenu je ono što IDP deklarira u discovery.issuer
// (npr. https://idp.certilia.com/oauth2/token) — NE pretpostavljaj da su isti.
let _jwks: ReturnType<typeof jose.createRemoteJWKSet> | null = null;
let _issuer: string | null = null;
async function getOidc() {
  if (_jwks && _issuer) return { jwks: _jwks, issuer: _issuer };
  const disc = await fetch(DISCOVERY).then((r) => r.json());
  if (!disc?.jwks_uri || !disc?.issuer) {
    throw new Error("certilia_discovery_failed");
  }
  _jwks = jose.createRemoteJWKSet(new URL(disc.jwks_uri));
  _issuer = disc.issuer as string;
  return { jwks: _jwks, issuer: _issuer };
}

// Stabilan, ne-reverzibilan hex digest (HMAC-SHA256) — za email lokalni dio
// kad eID ne vrati pravi email (sub JE OIB, ne smije se koristiti direktno).
async function hmacHex(value: string, key: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(value));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
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
      const { jwks, issuer } = await getOidc();
      const res = await jose.jwtVerify(idToken, jwks, {
        issuer,
        audience: CERTILIA_CLIENT_ID,
      });
      payload = res.payload;
    } catch (e) {
      return json({ error: "invalid_token", detail: String((e as Error)?.message ?? e) }, 401);
    }

    // 2. Trusted claimovi — verificirani MINIMUM (čl. 5(1)(c) data minimization).
    // Hrvatska e-Osobna (Certilia): OIB stiže kao `sub` (11 znamenki), NE kao
    // `pin`. Certilia ne stavlja `pin` u id_token ni uz `claims` param, a
    // userinfo (gdje bi `pin` živio) traži token binding koji prod ne podržava.
    const oib = (payload.pin ?? payload.oib ?? payload.sub) as string | undefined;
    if (!oib) return json({ error: "no_oib_claim" }, 400);
    const firstName = (payload.given_name ?? payload.firstname) as string | undefined;
    const lastName = (payload.family_name ?? payload.lastname) as string | undefined;
    const dob = (payload.birthdate ?? payload.date_of_birth) as string | undefined;
    const country = (payload.country ??
      (payload.address as Record<string, unknown> | undefined)?.country) as
        | string
        | undefined;
    const realEmail = (payload.email as string | undefined) || undefined;
    const fullName =
      [firstName, lastName].filter(Boolean).join(" ") ||
      (payload.name as string | undefined) ||
      null;

    // OIB se NIKAD ne stavlja u auth.users.email (curenje plaintext PII-a).
    // Kako je `sub` ZAPRAVO OIB, ni njega ne koristimo direktno — bez pravog
    // emaila deriviramo stabilan, ne-reverzibilan lokalni dio iz HMAC(oib).
    const canonicalEmail = realEmail ??
      `certilia-${(await hmacHex(oib, KYC_ENCRYPTION_KEY)).slice(0, 32)}@users.domovina.ai`;
    // app_metadata drži samo ne-osjetljivo; OIB ide isključivo enkriptiran u
    // public.identity_verifications.
    const appMeta = {
      provider: "certilia",
      kyc_verified: true,
      full_name: fullName,
      real_email: realEmail ?? null,
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
    if (!userId) return json({ error: "no_user_id" }, 400);

    await admin.auth.admin.updateUserById(userId, { app_metadata: appMeta });

    // 5. KYC: spremi verificirani minimum (OIB enkriptiran pgcrypto-om).
    const { error: kErr } = await admin.rpc("upsert_identity_verification", {
      p_user_id: userId,
      p_oib: oib,
      p_first: firstName ?? null,
      p_last: lastName ?? null,
      p_dob: dob ?? null,
      p_country: country ?? null,
      p_key: KYC_ENCRYPTION_KEY,
      p_provider: "certilia",
      p_loa: (payload.acr as string | undefined) ?? null,
    });
    if (kErr) {
      console.error("upsert_identity_verification failed", kErr.message);
      return json({ error: "kyc_store_failed", detail: kErr.message }, 400);
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
