// Pure decision logic for the RevenueCat webhook — no I/O, no Deno APIs, so it
// is unit-testable (logic_test.ts) and reusable. index.ts does auth + the
// service-role upsert around this.

export const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Production store product ids (pricing-and-tiers.md) + TestStore identifiers.
export const PRODUCT_ALLOWLIST = new Set<string>([
  "domovina_plus_monthly", "domovina_plus_annual", "domovina_plus_lifetime",
  "monthly", "yearly", "annual", "lifetime",
]);

// event.type → entitlement state. CANCELLATION keeps access until expiry.
export const ACTIVE_EVENTS = new Set<string>([
  "INITIAL_PURCHASE", "RENEWAL", "UNCANCELLATION", "NON_RENEWING_PURCHASE",
  "PRODUCT_CHANGE", "SUBSCRIPTION_EXTENDED", "TEMPORARY_ENTITLEMENT_GRANT",
  "CANCELLATION",
]);
export const EXPIRE_EVENTS = new Set<string>([
  "EXPIRATION", "BILLING_ISSUE", "SUBSCRIPTION_PAUSED", "REFUND",
]);

export function storeSlug(store: unknown): string | null {
  switch (store) {
    case "APP_STORE":
    case "MAC_APP_STORE":
      return "app_store";
    case "PLAY_STORE":
    case "AMAZON":
      return "play_store";
    case "STRIPE":
    case "RC_BILLING":
    case "PADDLE":
      return "rc_billing";
    default:
      return store ? String(store).toLowerCase() : null;
  }
}

// deno-lint-ignore no-explicit-any
export type RcEvent = Record<string, any>;

export interface SubscriptionRow {
  user_id: string;
  rc_app_user_id: string;
  status: string;
  entitlement: string | null;
  product_id: string | null;
  store: string | null;
  period_type: string | null;
  current_period_end: string | null;
  rc_event_type: string;
  environment: string | null;
  updated_at: string;
}

export type Decision =
  | { kind: "reject"; status: number; error: string }
  | { kind: "ignore"; reason: string }
  | { kind: "write"; row: SubscriptionRow };

/**
 * Decide what to do with a RevenueCat event. Pure: caller handles bearer-auth
 * (before this) and the DB upsert (for kind === "write").
 *
 * @param nowIso pass `new Date().toISOString()` from the caller (kept out of
 *               here so tests are deterministic).
 */
export function decide(
  event: RcEvent | undefined | null,
  opts: { requireProduction: boolean; nowIso: string },
): Decision {
  if (!event || typeof event !== "object") {
    return { kind: "reject", status: 400, error: "no_event" };
  }

  const appUserId = event.app_user_id;
  // UUID gate BEFORE anything else — crafted/anonymous ids never reach the DB.
  if (typeof appUserId !== "string" || !UUID_RE.test(appUserId)) {
    return { kind: "reject", status: 400, error: "invalid_app_user_id" };
  }

  const environment: string | undefined = event.environment;
  if (opts.requireProduction && environment !== "PRODUCTION") {
    return { kind: "ignore", reason: "non_production" };
  }

  const entitlementIds: string[] = Array.isArray(event.entitlement_ids)
    ? event.entitlement_ids
    : (event.entitlement_id ? [event.entitlement_id] : []);
  if (entitlementIds.length > 0 && !entitlementIds.includes("domovina_plus")) {
    return { kind: "ignore", reason: "other_entitlement" };
  }

  const productId: string | undefined = event.product_id;
  if (productId && !PRODUCT_ALLOWLIST.has(productId)) {
    return { kind: "ignore", reason: "product_not_allowlisted" };
  }

  const type: string = event.type;
  let status: string;
  if (ACTIVE_EVENTS.has(type)) status = "active";
  else if (EXPIRE_EVENTS.has(type)) status = "expired";
  else return { kind: "ignore", reason: `event_${type}` };

  const isActive = status === "active";
  const expirationMs = event.expiration_at_ms;

  return {
    kind: "write",
    row: {
      user_id: appUserId,
      rc_app_user_id: appUserId,
      status,
      entitlement: isActive ? "domovina_plus" : null,
      product_id: productId ?? null,
      store: storeSlug(event.store),
      period_type: event.period_type
        ? String(event.period_type).toLowerCase()
        : null,
      current_period_end: typeof expirationMs === "number"
        ? new Date(expirationMs).toISOString()
        : null,
      rc_event_type: type,
      environment: environment ?? null,
      updated_at: opts.nowIso,
    },
  };
}
