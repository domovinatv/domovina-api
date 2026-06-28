import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { decide } from "./logic.ts";

// revenuecat-webhook — RevenueCat → domovina_ai.subscriptions entitlement mirror.
//
// The ONLY writer of entitlement state. The Flutter app (web/iOS/Android/macOS/TV)
// only ever READS its own row (RLS select-own); this function writes it with the
// service role (bypasses RLS). See domovina.ai docs/payments/architecture.md.
//
// Lives as a Supabase Edge Function (not the Cloudflare Pages worker) because it
// WRITES to the api.domovina.ai Postgres DB for a logged-in user — per the
// backend-placement rule in docs/backend-architecture.md. The service-role key
// stays on Coolify; nothing sensitive is copied to Cloudflare.
//
// verify_jwt = false (server-to-server). RevenueCat sends a static shared secret
// in the Authorization header (configured in the RC webhook), NOT a GoTrue JWT —
// we check it ourselves. Same shape as pinka-webhook. Decision logic is in
// logic.ts (pure, unit-tested by logic_test.ts).

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_AUTH = Deno.env.get("REVENUECAT_WEBHOOK_AUTH") ?? "";
const REQUIRE_PRODUCTION = Deno.env.get("REVENUECAT_REQUIRE_PRODUCTION") === "true";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Bearer auth — exact match against the configured shared secret.
  if (!WEBHOOK_AUTH || req.headers.get("Authorization") !== WEBHOOK_AUTH) {
    return json({ error: "unauthorized" }, 401);
  }
  if (!SERVICE) return json({ error: "service_role_not_configured" }, 500);

  let payload: { event?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const decision = decide(payload?.event as Record<string, unknown> | undefined, {
    requireProduction: REQUIRE_PRODUCTION,
    nowIso: new Date().toISOString(),
  });

  if (decision.kind === "reject") {
    return json({ error: decision.error }, decision.status);
  }
  if (decision.kind === "ignore") {
    return json({ ok: true, ignored: decision.reason }, 200);
  }

  // Service-role upsert (bypasses RLS), idempotent on user_id.
  const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });
  const { error } = await admin
    .schema("domovina_ai")
    .from("subscriptions")
    .upsert(decision.row, { onConflict: "user_id" });
  if (error) {
    console.error(`[revenuecat-webhook] upsert failed: ${error.message}`);
    return json({ error: "upsert_failed" }, 500);
  }

  return json({ ok: true, applied: `${decision.row.rc_event_type}->${decision.row.status}` }, 200);
});
