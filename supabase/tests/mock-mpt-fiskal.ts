// Lokalni mock za MPT (pay.domovina.ai /api/intents) i domovina-fiskal
// (/api/v1/racun…) za E2E test sponzorskih trenutaka.
//
// Tijelo računa se validira PRAVOM zod shemom fiskala (racunModelShema iz
// domovina-fiskal/backend/src/validacija.ts) — mock time dokazuje da je ono
// što pinka-webhook šalje prihvatljivo fiskalu, bez diranja fiskal-testa.
// Idempotency-Key se ponaša kao na fiskalu: isti ključ → isti dokument, 200 +
// Idempotent-Replay.
//
// Pokreće se IZ domovina-fiskal/backend (zod iz njegovog node_modules):
//   cd ../domovina-fiskal/backend && FISKAL_REPO=.. deno run -A \
//     --unstable-sloppy-imports --node-modules-dir=manual \
//     ../../domovina-api/supabase/tests/mock-mpt-fiskal.ts 54999
//
// GET /_calls vraća zapisnik svih poziva; POST /_reset ga briše.

const repo = Deno.env.get("FISKAL_REPO") ?? new URL("../../../domovina-fiskal", import.meta.url).pathname;
const { racunModelShema, formatirajGreske } = await import(`${repo}/backend/src/validacija.ts`);

const port = Number(Deno.args[0] ?? 54999);
type Call = { method: string; path: string; idempotencyKey: string | null; body: unknown; status: number };
let calls: Call[] = [];
const byKey = new Map<string, number>();
let nextId = 100;

Deno.serve({ port, hostname: "0.0.0.0" }, async (req) => {
  const url = new URL(req.url);
  const path = url.pathname;
  const body = req.method === "POST" ? await req.json().catch(() => null) : null;
  const idem = req.headers.get("Idempotency-Key");
  const reply = (status: number, b: unknown, headers: Record<string, string> = {}) => {
    if (!path.startsWith("/_")) calls.push({ method: req.method, path, idempotencyKey: idem, body, status });
    return new Response(JSON.stringify(b), { status, headers: { "content-type": "application/json", ...headers } });
  };

  if (path === "/_calls") return new Response(JSON.stringify(calls), { headers: { "content-type": "application/json" } });
  if (path === "/_reset") {
    calls = [];
    byKey.clear();
    nextId = 100;
    return new Response("{}");
  }

  // ── MPT ──
  if (path === "/api/intents" && req.method === "POST") {
    const b = body as { amount_eur: number; metadata?: { contribution_id?: string } };
    const sid = `sid_e2e_${crypto.randomUUID().slice(0, 8)}`;
    return reply(200, {
      sid,
      state: "pending",
      amount_eur: b.amount_eur,
      amount_cents: Math.round(b.amount_eur * 100),
      currency: "EUR",
      memo: `mpt:0x0?sid=${sid}`,
      iban: "HR0000000000000000000",
      beneficiary_name: "Mock",
      bic: "MOCKHR22",
      epc_qr_data: "BCD\n002\n1\nSCT",
      checkout_url: `http://mock/c/${sid}`,
      status_url: `http://mock/s/${sid}`,
      expires_at: new Date(Date.now() + 86_400_000).toISOString(),
    });
  }

  // ── Resend ──
  if (path === "/emails" && req.method === "POST") return reply(200, { id: `mail_${calls.length}` });

  // ── fiskal ──
  if (!req.headers.get("authorization")?.startsWith("Bearer dfk_")) {
    return reply(401, { greska: "Nedostaje API ključ" });
  }
  if (path === "/api/v1/racun" && req.method === "POST") {
    const parsed = racunModelShema.safeParse(body);
    if (!parsed.success) return reply(400, { greska: "Validacija nije prošla", detalji: formatirajGreske(parsed.error) });
    if (idem && byKey.has(idem)) {
      const id = byKey.get(idem)!;
      return reply(200, { id, brojRacuna: `${id}/OGL/1`, vanjskaReferenca: idem }, { "Idempotent-Replay": "true" });
    }
    const id = nextId++;
    if (idem) byKey.set(idem, id);
    return reply(201, { id, brojRacuna: `${id}/OGL/1`, vanjskaReferenca: idem, tip: parsed.data.tip });
  }
  if (/^\/api\/v1\/racun\/\d+\/posalji-eracun$/.test(path)) {
    return reply(200, { ok: true, dokuId: "doku-mock", eracunStatus: "SENT" });
  }
  if (/^\/api\/v1\/racun\/\d+\/posalji$/.test(path)) {
    return reply(200, { ok: true, poslanoNa: (body as { na?: string })?.na, kanal: "mock" });
  }
  return reply(404, { greska: `mock: ${req.method} ${path}` });
});
