// HMAC gate za Stripe rail funkcije (events-stripe-intent, events-stripe-confirm).
//
// Zašto uopće postoji: na onchain putu "verifikacija JE autorizacija" — dokaz
// uplate je sam blockchain i events-confirm ga sam provjeri. Kod Stripea takvog
// dokaza nema: jedini dokaz je Stripe webhook potpis, a njega verificira naš
// Cloudflare Worker (domovina-ulaznice). Backend zato mora znati da poziv
// dolazi baš od tog Workera — inače bi bilo tko mogao "potvrditi" plaćanje koje
// se nije dogodilo i dobiti besplatne ulaznice.
//
// Shema (namjerno minimalna, da je Worker strana trivijalno točna):
//   header  x-ulaznice-signature: sha256=<hex(hmac_sha256(secret, rawBody))>
//   potpis  ide nad SIROVIM tijelom zahtjeva (byte-for-byte ono što se parsira)
//   usporedba konstantnog vremena
//
// Replay: namjerno se NE brani timestampom. Ponovljeni identičan zahtjev je
// no-op jer je idempotencija u bazi (unique (payment_rail, external_payment_ref)
// → already_paid, bez novih ulaznica). Manje pomičnih dijelova = manje šansi da
// pozivatelj pogriješi potpis.
//
// Tajna: EVENTS_STRIPE_CONFIRM_SECRET (32+ bajta). Bez nje funkcija vraća 503 —
// NIKAD "prolazi jer tajne nema".

export const SIGNATURE_HEADER = "x-ulaznice-signature";

export type GateResult =
  | { ok: true }
  | { ok: false; status: number; error: string };

/** Provjeri x-ulaznice-signature nad sirovim tijelom. */
export async function verifyUlazniceSignature(
  secret: string,
  rawBody: string,
  header: string | null,
): Promise<GateResult> {
  if (!secret) return { ok: false, status: 503, error: "secret_not_configured" };
  if (!header) return { ok: false, status: 401, error: "missing_signature" };

  const provided = header.trim();
  if (!provided.startsWith("sha256=")) {
    return { ok: false, status: 401, error: "bad_signature" };
  }
  const expected = await hmacHex(secret, rawBody);
  if (!timingSafeEqual(provided.slice("sha256=".length).toLowerCase(), expected)) {
    return { ok: false, status: 401, error: "bad_signature" };
  }
  return { ok: true };
}

export async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret) as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data) as BufferSource);
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
