// Gost = zahtjev bez Supabase sesije (anonimne prijave su ugašene). Kočnice:
// limit po IP-u (pinka_finance.guest_rate_hit, dijeljen kroz instance) i
// Cloudflare Turnstile kad je TURNSTILE_SECRET_KEY postavljen.
//
// IP se nikad ne sprema: ključ je HMAC(IP) sa service ključem kao tajnom.
//
// Turnstile token je JEDNOKRATAN: troši se pri provjeri, pa klijent nakon
// svakog odgovora (i 409/400) resetira widget prije ponovnog pokušaja.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET_KEY") ?? "";
const TURNSTILE_VERIFY_URL = Deno.env.get("TURNSTILE_VERIFY_URL") ??
  "https://challenges.cloudflare.com/turnstile/v0/siteverify";

// Promet ide Cloudflare → tunnel → traefik → Kong → edge, a origin nije
// dostupan mimo Cloudflarea (provjereno 7.10.2026.: 80/443/8000/8443 zatvoreni
// na IP-u servera). Cloudflare cf-connecting-ip uvijek PREPISUJE, pa mu se
// vjeruje; x-forwarded-for / x-real-ip klijent može podmetnuti i NE koriste se.
// Bez zaglavlja (lokalno) svi gosti dijele jedan ključ — strože, nikad blaže.
export function clientIp(req: Request): string {
  return req.headers.get("cf-connecting-ip") ?? "unknown";
}

let ipKey: Promise<CryptoKey> | null = null;

export async function guestKey(req: Request, scope: string): Promise<string> {
  ipKey ??= crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(SERVICE) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "HMAC",
    await ipKey,
    new TextEncoder().encode(`guest-ip:${clientIp(req)}`) as BufferSource,
  );
  const hex = Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${scope}:${hex.slice(0, 32)}`;
}

// Gost = nema sesije: bez Authorization zaglavlja ili s anon ključem (to
// supabase klijent šalje kad nema prijave). Bilo koji DRUGI bearer je pokušaj
// prijavljenog korisnika — ako ne prođe, to je 401, ne tihi prelazak u gosta
// (inače istekla sesija odvoji donaciju od accounta i KYC-a).
export function isGuestBearer(authHeader: string, anonKey: string): boolean {
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  return token === "" || token === anonKey;
}

// p_count=false: samo provjera (ne troši kvotu); p_count=true: upis pokušaja.
// Greška baze → propušta (kočnica, ne ugovor) uz log.
export async function guestAllowed(
  admin: SupabaseClient,
  key: string,
  limit: number,
  windowSeconds: number,
  count = true,
): Promise<boolean> {
  const { data, error } = await admin.schema("pinka_finance").rpc("guest_rate_hit", {
    p_key: key,
    p_limit: limit,
    p_window_seconds: windowSeconds,
    p_count: count,
  });
  if (error) {
    console.error(`[guest] rate limit nedostupan: ${error.message}`);
    return true;
  }
  return data === true;
}

export function turnstileRequired(): boolean {
  return TURNSTILE_SECRET.length > 0;
}

export async function turnstileOk(token: unknown, req: Request): Promise<boolean> {
  if (!turnstileRequired()) return true;
  if (typeof token !== "string" || token.length === 0 || token.length > 4096) return false;
  const form = new FormData();
  form.set("secret", TURNSTILE_SECRET);
  form.set("response", token);
  const ip = clientIp(req);
  if (ip !== "unknown") form.set("remoteip", ip);
  try {
    const res = await fetch(TURNSTILE_VERIFY_URL, {
      method: "POST",
      body: form,
      signal: AbortSignal.timeout(5_000),
    });
    const out = await res.json() as { success?: boolean };
    return out.success === true;
  } catch (e) {
    console.error(`[guest] turnstile verify pao: ${e}`);
    return false;
  }
}
