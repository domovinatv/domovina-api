// deno test supabase/functions/revenuecat-webhook/logic_test.ts
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { decide, type RcEvent } from "./logic.ts";

const UUID = "11111111-1111-1111-1111-111111111111";
const NOW = "2026-06-28T00:00:00.000Z";

function ev(over: Partial<RcEvent> = {}): RcEvent {
  return {
    type: "INITIAL_PURCHASE",
    app_user_id: UUID,
    environment: "SANDBOX",
    product_id: "domovina_plus_annual",
    entitlement_ids: ["domovina_plus"],
    period_type: "NORMAL",
    expiration_at_ms: 1893456000000,
    store: "APP_STORE",
    ...over,
  };
}
const base = { requireProduction: false, nowIso: NOW };

Deno.test("INITIAL_PURCHASE → write active domovina_plus, keyed by UUID", () => {
  const d = decide(ev(), base);
  assertEquals(d.kind, "write");
  if (d.kind !== "write") return;
  assertEquals(d.row.user_id, UUID);
  assertEquals(d.row.status, "active");
  assertEquals(d.row.entitlement, "domovina_plus");
  assertEquals(d.row.store, "app_store");
  assertEquals(d.row.period_type, "normal");
});

Deno.test("non-UUID app_user_id → reject 400, never writes", () => {
  const d = decide(ev({ app_user_id: "$RCAnonymousID:abc" }), base);
  assertEquals(d, { kind: "reject", status: 400, error: "invalid_app_user_id" });
});

Deno.test("missing event → reject 400", () => {
  assertEquals(decide(undefined, base).kind, "reject");
});

Deno.test("non-allowlisted product → ignore", () => {
  const d = decide(ev({ product_id: "evil" }), base);
  assertEquals(d, { kind: "ignore", reason: "product_not_allowlisted" });
});

Deno.test("other entitlement → ignore", () => {
  const d = decide(ev({ entitlement_ids: ["other"] }), base);
  assertEquals(d, { kind: "ignore", reason: "other_entitlement" });
});

Deno.test("EXPIRATION → expired + null entitlement", () => {
  const d = decide(ev({ type: "EXPIRATION" }), base);
  if (d.kind !== "write") throw new Error("expected write");
  assertEquals(d.row.status, "expired");
  assertEquals(d.row.entitlement, null);
});

Deno.test("CANCELLATION → stays active until expiry", () => {
  const d = decide(ev({ type: "CANCELLATION" }), base);
  if (d.kind !== "write") throw new Error("expected write");
  assertEquals(d.row.status, "active");
  assertEquals(d.row.entitlement, "domovina_plus");
});

Deno.test("unknown event type (TRANSFER) → ignore", () => {
  assertEquals(decide(ev({ type: "TRANSFER" }), base).kind, "ignore");
});

Deno.test("requireProduction=true + SANDBOX → ignore non_production", () => {
  const d = decide(ev(), { requireProduction: true, nowIso: NOW });
  assertEquals(d, { kind: "ignore", reason: "non_production" });
});

Deno.test("requireProduction=true + PRODUCTION → write", () => {
  const d = decide(ev({ environment: "PRODUCTION" }), {
    requireProduction: true,
    nowIso: NOW,
  });
  assertEquals(d.kind, "write");
});

Deno.test("TestStore product (yearly) → accepted, play store slug maps", () => {
  const d = decide(ev({ product_id: "yearly", store: "PLAY_STORE" }), base);
  if (d.kind !== "write") throw new Error("expected write");
  assertEquals(d.row.store, "play_store");
});

Deno.test("lifetime NON_RENEWING_PURCHASE → active, no expiry", () => {
  const d = decide(
    ev({ type: "NON_RENEWING_PURCHASE", product_id: "lifetime", expiration_at_ms: null }),
    base,
  );
  if (d.kind !== "write") throw new Error("expected write");
  assertEquals(d.row.status, "active");
  assertEquals(d.row.current_period_end, null);
});
