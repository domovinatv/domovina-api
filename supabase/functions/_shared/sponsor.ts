// Sponzorski trenuci — račun (domovina-fiskal) i e-pošta vlasniku kanala.
// Zovu ga pinka-webhook (odmah nakon uplate) i sponsor-cron (retry).
//
// Ugovor: docs/sponzorski-trenuci-ugovor.md. Shema: 20261007120000.
//
// DVAPUT IZDAN RAČUN JE STVARNA ŠTETA. Dvije brave:
//   1. Idempotency-Key = contribution id → fiskal za isti ključ vraća postojeći
//      dokument (Idempotent-Replay), ne izdaje novi.
//   2. sponsor_invoice_lease → u svakom trenutku samo jedan pozivatelj radi
//      korake za isti doprinos, pa se /posalji-eracun ne zove paralelno.
// Neuspjeh fiskala NIKAD ne ruši webhook: ide u invoice_state, retry je cron.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { hmacHex } from "./ulaznice-hmac.ts";

const FISKAL_URL = (Deno.env.get("FISKAL_URL") ?? "https://fiskal-test.domovina.ai").replace(/\/+$/, "");
const FISKAL_API_KEY = Deno.env.get("FISKAL_API_KEY") ?? "";
const FISKAL_PP = Deno.env.get("FISKAL_POSLOVNI_PROSTOR") ?? "";
const FISKAL_NU = Deno.env.get("FISKAL_NAPLATNI_UREDAJ") ?? "";
// MVP krug: samo fiskal-test (ili lokalni mock). Produkcijski fiskal traži
// izričito uključenje — pogrešan URL u env-u ne smije izdati pravi račun.
const FISKAL_ALLOW_PROD = Deno.env.get("FISKAL_ALLOW_PROD") === "1";
const FISKAL_IS_TEST = /^https:\/\/fiskal-test\.|^http:\/\/(localhost|127\.0\.0\.1|host\.docker\.internal)[:/]/
  .test(FISKAL_URL);

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? Deno.env.get("SMTP_PASS") ?? "";
const RESEND_API_URL = Deno.env.get("RESEND_API_URL") ?? "https://api.resend.com/emails"; // mock u E2E testu
const MAIL_FROM = Deno.env.get("DOMOVINA_MAIL_FROM") ?? "DOMOVINA <noreply@domovina.ai>";
const OWNER_EMAIL = Deno.env.get("SPONSOR_OWNER_EMAIL") ?? "";
const MODERATION_SECRET = Deno.env.get("SPONSOR_MODERATION_SECRET") ?? "";
const FUNCTIONS_URL = (Deno.env.get("PUBLIC_FUNCTIONS_URL") ?? "https://api.domovina.ai/functions/v1")
  .replace(/\/+$/, "");

const KPD = "73.12.13"; // prodaja oglasnog prostora
const PDV_STOPA = 25;

type Contribution = {
  id: string;
  campaign_id: string;
  state: string;
  amount_cents: number;
  amount_received_cents: number | null;
  paid_at: string | null;
  display_name: string | null;
  message: string | null;
  link_url: string | null;
  logo_path: string | null;
  buyer_company: string | null;
  buyer_oib: string | null;
  buyer_vat_id: string | null;
  buyer_email: string | null;
  buyer_address: { street?: string; city?: string; postal_code?: string; country?: string } | null;
  buyer_reference: string | null;
  desired_slot_keys: string[] | null;
  sold_slots: Slot[] | null;
  slot_unassigned: boolean;
  underpaid: boolean;
  invoice_state: string | null;
  invoice_racun_id: number | null;
};

// Snapshot iz contributions.sold_slots (trg_slots_live), ne živi red iz
// slots — istek zakupa briše slots.contribution_id, a retry računa i obavijest
// mogu doći nakon isteka.
type Slot = {
  slot_key: string;
  youtube_id: string | null;
  start_sec: number | null;
  end_sec: number | null;
  label: string | null;
  price_cents: number;
  live_from: string | null;
  live_until: string | null;
};

// ─── račun ──────────────────────────────────────────────────────────────────

export type InvoiceOutcome =
  | { done: false; reason: string }
  | { done: true; state: string; racunId?: number; number?: string | null; error?: string };

export async function processSponsorInvoice(admin: SupabaseClient, contributionId: string): Promise<InvoiceOutcome> {
  const pf = admin.schema("pinka_finance");
  const { data: leased, error: leaseErr } = await pf.rpc("sponsor_invoice_lease", {
    p_contribution_id: contributionId,
    p_lease_seconds: 120,
  });
  if (leaseErr) return { done: false, reason: `lease: ${leaseErr.message}` };
  const c = (Array.isArray(leased) ? leased[0] : leased) as Contribution | undefined;
  // Netko drugi radi na njemu, već je poslano, ili nije plaćen sponzorski doprinos.
  if (!c) return { done: false, reason: "not_leased" };

  const record = async (state: string, racunId?: number, number?: string | null, error?: string) => {
    await pf.rpc("sponsor_invoice_record", {
      p_contribution_id: c.id,
      p_state: state,
      p_racun_id: racunId ?? null,
      p_number: number ?? null,
      p_error: error ?? null,
    });
    return { done: true as const, state, racunId, number, error };
  };

  // Novac je stigao, ali trenutak nije isporučen (kasna uplata, prodan
  // drugome) → povrat ručno, račun se ne izdaje.
  if (c.slot_unassigned) return record("skipped", undefined, null, "slot_unassigned");

  if (!FISKAL_API_KEY || !FISKAL_PP || !FISKAL_NU) {
    return record("failed", undefined, null, "fiskal_not_configured");
  }
  if (!FISKAL_ALLOW_PROD && !FISKAL_IS_TEST) {
    return record("failed", undefined, null, "fiskal_prod_blocked");
  }

  const tip = c.buyer_oib ? "ERACUN_B2B" : "RACUN";
  let racunId = c.invoice_racun_id ?? undefined;
  let broj: string | null = null;

  // 1) izdavanje (preskače se ako je ranije uspjelo, a palo je tek slanje)
  if (!racunId) {
    const sold = c.sold_slots ?? [];
    if (sold.length === 0) return record("skipped", undefined, null, "no_sold_slots");

    const body = buildRacun(c, sold, tip);
    let res: Response;
    try {
      res = await fiskal("/api/v1/racun", body, c.id);
    } catch (e) {
      return record("failed", undefined, null, `racun: ${e}`);
    }
    const out = await res.json().catch(() => ({})) as Record<string, unknown>;
    if (!res.ok) {
      return record("failed", undefined, null, `racun ${res.status}: ${JSON.stringify(out).slice(0, 600)}`);
    }
    racunId = Number(out.id);
    broj = (out.brojRacuna as string | null) ?? null;
    if (!Number.isInteger(racunId) || racunId <= 0) {
      return record("failed", undefined, null, `racun: neočekivan odgovor ${JSON.stringify(out).slice(0, 300)}`);
    }
  }

  // 2) slanje kupcu. eRačun ide preko doku; ako primatelj nije u eDelivery
  //    (AMS), šalje se i PDF e-poštom da kupac ipak dobije račun.
  try {
    if (tip === "ERACUN_B2B") {
      const res = await fiskal(`/api/v1/racun/${racunId}/posalji-eracun`, {});
      const out = await res.json().catch(() => ({})) as Record<string, unknown>;
      if (!res.ok || out.ok === false) {
        return record("issued", racunId, broj, `posalji-eracun ${res.status}: ${JSON.stringify(out).slice(0, 600)}`);
      }
      if (out.deliveryBlock === "AMS") {
        const r2 = await fiskal(`/api/v1/racun/${racunId}/posalji`, { na: c.buyer_email });
        if (!r2.ok) return record("issued", racunId, broj, `posalji (AMS) ${r2.status}: ${(await r2.text()).slice(0, 600)}`);
      }
    } else {
      const res = await fiskal(`/api/v1/racun/${racunId}/posalji`, { na: c.buyer_email });
      if (!res.ok) return record("issued", racunId, broj, `posalji ${res.status}: ${(await res.text()).slice(0, 600)}`);
    }
  } catch (e) {
    return record("issued", racunId, broj, `slanje: ${e}`);
  }
  return record("sent", racunId, broj);
}

function fiskal(path: string, body: unknown, idempotencyKey?: string): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    Authorization: `Bearer ${FISKAL_API_KEY}`,
  };
  if (idempotencyKey) headers["Idempotency-Key"] = idempotencyKey;
  return fetch(`${FISKAL_URL}${path}`, {
    method: "POST",
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(10_000),
  });
}

// Cijena je BRUTO (ugovor O3); neto = bruto / 1,25. Seed jamči djeljivost s
// 5 centi pa je neto cijeli cent i račun zbraja točno na plaćeni iznos.
export function buildRacun(c: Contribution, slots: Slot[], tip: string) {
  const paidDay = zagrebDay(c.paid_at ?? new Date().toISOString());
  const a = c.buyer_address ?? {};
  const napomena = [
    `Plaćeno SEPA uplatom ${paidDay}.`,
    c.buyer_reference ? `Vaša referenca: ${c.buyer_reference}.` : null,
    `Oglašivač: ${c.display_name ?? ""}.`,
  ].filter(Boolean).join(" ");

  return {
    tip,
    poslovniProstor: FISKAL_PP,
    naplatniUredaj: FISKAL_NU,
    nacinPlacanja: "TRANSAKCIJSKI",
    valuta: "EUR",
    datumIsporuke: paidDay,
    napomena,
    kupac: {
      naziv: c.buyer_company ?? "",
      ...(c.buyer_oib ? { oib: c.buyer_oib } : {}),
      ...(c.buyer_vat_id ? { vatNumber: c.buyer_vat_id } : {}),
      ...(c.buyer_email ? { email: c.buyer_email } : {}),
      ...(a.street || a.city
        ? { adresa: { ulica: a.street, grad: a.city, postanskiBroj: a.postal_code, drzava: a.country ?? "HR" } }
        : {}),
      tip: "pravna",
    },
    stavke: slots.map((s) => ({
      naziv: "Sponzorski trenutak u podcast epizodi",
      opis: [
        `youtu.be/${s.youtube_id} ${mmss(s.start_sec)}–${mmss(s.end_sec)}`,
        s.label ? `„${s.label.slice(0, 200)}"` : null,
        s.live_from && s.live_until ? `prikaz ${zagrebDay(s.live_from)} – ${zagrebDay(s.live_until)}` : null,
      ].filter(Boolean).join(", "),
      kolicina: 1,
      jedinicaMjere: "C62",
      netoCijena: (s.price_cents * 100 / (100 + PDV_STOPA) / 100).toFixed(2),
      pdvStopa: PDV_STOPA,
      pdvKategorija: "S",
      kpd: KPD,
    })),
  };
}

// Datum na računu je lokalni (HR): uplata u 01:30 8.10. je 8.10., ne 7.10. po
// UTC-u — inače zadnji dan u mjesecu ode u krivo PDV razdoblje.
export function zagrebDay(iso: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Europe/Zagreb", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date(iso));
}

function mmss(sec: number | null): string {
  const s = Math.max(0, sec ?? 0);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  const mm = String(m).padStart(2, "0"), ss = String(r).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

// ─── e-pošta vlasniku kanala ────────────────────────────────────────────────

export function moderationToken(contributionId: string): Promise<string> {
  return hmacHex(MODERATION_SECRET, `sponsor-moderate:${contributionId}`);
}

export function moderationConfigured(): boolean {
  return MODERATION_SECRET.length >= 16;
}

// Točno jednom po prodaji (sponsor_claim_owner_notify je atomaran). Ako slanje
// padne, oznaka se vraća pa cron pokuša ponovno.
export async function notifyOwnerOfSale(admin: SupabaseClient, contributionId: string): Promise<void> {
  if (!RESEND_API_KEY) {
    console.warn("[sponsor] RESEND_API_KEY nije postavljen — vlasnik nije obaviješten");
    return;
  }
  const pf = admin.schema("pinka_finance");
  const { data: claimed } = await pf.rpc("sponsor_claim_owner_notify", { p_contribution_id: contributionId });
  if (claimed !== true) return;

  try {
    const { c, slots, to } = await loadForMail(admin, contributionId);
    // Plaćeno, ali trenutak nije dodijeljen (kasna uplata, prodan drugome):
    // vlasniku NE javljamo "uživo", nego da treba ručni povrat.
    if (c.slot_unassigned || slots.length === 0) {
      await sendMail(to, `[ALARM] Plaćeno, trenutak nije dodijeljen — ${c.buyer_company ?? ""}`, `
        <p><b>Uplata je stigla, ali trenutak nije dodijeljen</b> (u međuvremenu je prodan drugome).
           Kreativa nije nigdje prikazana. Povrat je ručan; račun se ne izdaje.</p>
        <p><b>Primljeno:</b> ${eur(c.amount_received_cents ?? c.amount_cents)}<br>
           <b>Traženi trenuci:</b> ${esc((c.desired_slot_keys ?? []).join(", "))}</p>
        <p><b>Kupac:</b> ${esc(c.buyer_company)} · OIB ${esc(c.buyer_oib)} · ${esc(c.buyer_email)}</p>
        <p style="color:#888">contribution ${contributionId}</p>`);
      return;
    }
    const link = moderationConfigured()
      ? `${FUNCTIONS_URL}/sponsor-moderate?c=${contributionId}&t=${await moderationToken(contributionId)}`
      : null;
    const rows = slots.map((s) =>
      `<li>youtu.be/${esc(s.youtube_id)} ${mmss(s.start_sec)}–${mmss(s.end_sec)} — ${esc(s.label)}` +
      (s.live_until ? ` (do ${esc(zagrebDay(s.live_until))})` : "") + `</li>`
    ).join("");
    const html = `
      <p>Prodan je sponzorski trenutak. Kreativa je <b>već uživo</b>.</p>
      <ul>${rows}</ul>
      <p><b>Brand:</b> ${esc(c.display_name)}<br>
         <b>Rečenica:</b> ${esc(c.message)}<br>
         <b>Poveznica:</b> ${esc(c.link_url)}<br>
         <b>Logo:</b> ${esc(c.logo_path)}</p>
      <p><b>Kupac:</b> ${esc(c.buyer_company)} · OIB ${esc(c.buyer_oib)} · ${esc(c.buyer_email)}<br>
         <b>Iznos:</b> ${eur(c.amount_received_cents ?? c.amount_cents)}</p>
      ${link
        ? `<p>Ako kreativa krši uvjete oglašavanja: <a href="${esc(link)}">povuci kreativu</a> (otvara stranicu s gumbom za potvrdu).</p>`
        : `<p>Povlačenje: SPONSOR_MODERATION_SECRET nije postavljen — set_contribution_message_hidden('${contributionId}', true).</p>`}
      <p style="color:#888">contribution ${contributionId}</p>`;
    await sendMail(to, `Prodan sponzorski trenutak — ${c.display_name ?? ""}`, html);
  } catch (e) {
    console.error(`[sponsor] obavijest vlasniku pala (cron ponavlja, max 5×): ${e}`);
    await pf.from("contributions").update({ owner_notified_at: null }).eq("id", contributionId);
  }
}

// Alarm: uplata manja od cijene. Trenutak NIJE dodijeljen; povrat ručno.
export async function alertUnderpaid(admin: SupabaseClient, contributionId: string): Promise<void> {
  console.error(`[sponsor] UNDERPAID contribution=${contributionId}`);
  if (!RESEND_API_KEY) return;
  try {
    const { c, to } = await loadForMail(admin, contributionId);
    const html = `
      <p><b>Uplata je manja od cijene.</b> Trenutak NIJE dodijeljen i vraćen je u prodaju.
         Novac je na Safeu — povrat je ručan.</p>
      <p><b>Traženo:</b> ${eur(c.amount_cents)}<br>
         <b>Primljeno:</b> ${c.amount_received_cents == null ? "nepoznato" : eur(c.amount_received_cents)}<br>
         <b>Trenuci:</b> ${esc((c.desired_slot_keys ?? []).join(", "))}</p>
      <p><b>Kupac:</b> ${esc(c.buyer_company)} · OIB ${esc(c.buyer_oib)} · ${esc(c.buyer_email)}</p>
      <p style="color:#888">contribution ${contributionId}</p>`;
    await sendMail(to, `[ALARM] Uplata manja od cijene — ${c.buyer_company ?? ""}`, html);
  } catch (e) {
    console.error(`[sponsor] alarm za manjak pao: ${e}`);
  }
}

async function loadForMail(admin: SupabaseClient, contributionId: string) {
  const pf = admin.schema("pinka_finance");
  const { data: c, error } = await pf.from("contributions").select("*").eq("id", contributionId).single();
  if (error || !c) throw new Error(`contribution ${contributionId}: ${error?.message}`);
  const row = c as Contribution;
  return { c: row, slots: row.sold_slots ?? [], to: await ownerEmail(admin, row.campaign_id) };
}

// SPONSOR_OWNER_EMAIL ima prednost; inače e-pošta vlasnika accounta kampanje.
async function ownerEmail(admin: SupabaseClient, campaignId: string): Promise<string> {
  if (OWNER_EMAIL) return OWNER_EMAIL;
  const { data: camp } = await admin.schema("pinka_finance").from("campaigns")
    .select("account_id").eq("id", campaignId).single();
  const { data: acc } = await admin.from("accounts")
    .select("primary_owner_user_id").eq("id", (camp as { account_id: string }).account_id).single();
  const uid = (acc as { primary_owner_user_id: string } | null)?.primary_owner_user_id;
  if (!uid) throw new Error("vlasnik kampanje nema korisnika");
  const { data } = await admin.auth.admin.getUserById(uid);
  if (!data?.user?.email) throw new Error("vlasnik kampanje nema e-poštu");
  return data.user.email;
}

async function sendMail(to: string, subject: string, html: string): Promise<void> {
  const res = await fetch(RESEND_API_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${RESEND_API_KEY}` },
    body: JSON.stringify({ from: MAIL_FROM, to: [to], subject, html }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`resend ${res.status}: ${(await res.text()).slice(0, 300)}`);
}

export function esc(v: unknown): string {
  return String(v ?? "—").replace(/[&<>"']/g, (ch) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!
  );
}

function eur(cents: number): string {
  return `${(cents / 100).toFixed(2).replace(".", ",")} €`;
}
