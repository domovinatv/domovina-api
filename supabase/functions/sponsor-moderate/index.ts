import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { esc, moderationConfigured, moderationToken } from "../_shared/sponsor.ts";
import { timingSafeEqual } from "../_shared/ulaznice-hmac.ts";

// sponsor-moderate — povlačenje kreative sponzorskog trenutka iz linka u e-pošti
// vlasniku kanala (_shared/sponsor.ts notifyOwnerOfSale).
//
//   GET  ?c=<contribution_id>&t=<token>   → stranica s gumbom (NE mijenja ništa)
//   POST c, t, hidden=1|0 (form)          → message_hidden + stranica s ishodom
//
// GET namjerno ne mijenja stanje: skeneri linkova u e-pošti (Outlook Safe
// Links, Gmail) otvaraju svaki link i inače bi povlačili svaki oglas.
// Token = HMAC-SHA256(SPONSOR_MODERATION_SECRET, "sponsor-moderate:<id>").
// verify_jwt = false — autentikacija je token.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

Deno.serve(async (req) => {
  if (!moderationConfigured()) return page("Povlačenje nije konfigurirano.", 503);

  let c = "", t = "", hidden: boolean | null = null;
  if (req.method === "GET") {
    const u = new URL_(req.url);
    c = u.searchParams.get("c") ?? "";
    t = u.searchParams.get("t") ?? "";
  } else if (req.method === "POST") {
    const f = await req.formData().catch(() => null);
    c = String(f?.get("c") ?? "");
    t = String(f?.get("t") ?? "");
    hidden = f?.get("hidden") === "1" ? true : f?.get("hidden") === "0" ? false : null;
    if (hidden === null) return page("Neispravan zahtjev.", 400);
  } else {
    return page("Metoda nije dopuštena.", 405);
  }

  if (!UUID.test(c) || !(await tokenOk(c, t))) return page("Link nije valjan.", 403);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const pf = admin.schema("pinka_finance");

  if (hidden !== null) {
    const { data, error } = await pf.rpc("sponsor_set_hidden", { p_contribution_id: c, p_hidden: hidden });
    if (error || data !== true) return page("Promjena nije uspjela.", 500);
  }

  const { data: row } = await pf.from("contributions")
    .select("display_name, message, link_url, message_hidden, is_sponsor")
    .eq("id", c).maybeSingle();
  const r = row as { display_name: string; message: string | null; link_url: string | null; message_hidden: boolean; is_sponsor: boolean } | null;
  if (!r?.is_sponsor) return page("Narudžba ne postoji.", 404);

  const status = r.message_hidden
    ? "<p><b>Kreativa je povučena</b> — ne prikazuje se nigdje.</p>"
    : "<p><b>Kreativa je uživo.</b></p>";
  const next = r.message_hidden ? "0" : "1";
  const label = r.message_hidden ? "Vrati kreativu" : "Povuci kreativu";
  return page(`
    ${hidden === null ? "" : "<p>Spremljeno.</p>"}
    ${status}
    <p>Brand: ${esc(r.display_name)}<br>Rečenica: ${esc(r.message)}<br>Poveznica: ${esc(r.link_url)}</p>
    <form method="post">
      <input type="hidden" name="c" value="${esc(c)}">
      <input type="hidden" name="t" value="${esc(t)}">
      <input type="hidden" name="hidden" value="${next}">
      <button type="submit">${label}</button>
    </form>`, 200);
});

// `URL` je zauzet za SUPABASE_URL (konvencija ostalih funkcija u repou).
const URL_ = globalThis.URL;

async function tokenOk(c: string, t: string): Promise<boolean> {
  return timingSafeEqual(t, await moderationToken(c));
}

function page(body: string, status: number): Response {
  return new Response(
    `<!doctype html><html lang="hr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Sponzorski trenutak</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:560px;margin:40px auto;padding:0 16px}
button{font-size:16px;padding:10px 18px;cursor:pointer}</style></head>
<body><h1>Sponzorski trenutak</h1>${body}</body></html>`,
    { status, headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } },
  );
}
