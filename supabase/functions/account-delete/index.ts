// account-delete — trajno brisanje računa (App Store Guideline 5.1.1(v) + GDPR)
//
// Flutter zove client.functions.invoke('account-delete') s JWT-om trenutne
// sesije. Grana ručno verificira JWT (getUser) i briše auth.users red preko
// admin API-ja — FK-ovi s ON DELETE CASCADE čiste platform tablice
// (profiles → domovina_ai.*, user_passkeys, identity_verifications s enc OIB).
//
// Iznimka: domovina_ai.safe_actions.account_id referencira auth.users BEZ
// cascade-a (audit trail) → prije deleteUser nuliramo link da FK ne blokira
// brisanje, a audit redovi ostaju (anonimizirani).
//
// Spec: domovina.ai docs/backend-prompts/10-account-management.md.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    if (!authHeader) return json({ error: "unauthorized" }, 401);

    const userClient = createClient(URL_, ANON, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user } } = await userClient.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);
    // Anon račune ne brišemo ovuda — GC ih čisti; spriječi i slučajan poziv.
    if (user.is_anonymous) return json({ error: "anonymous" }, 400);

    console.log("account-delete: user", user.id, user.email);

    // 1. Odveži audit redove bez cascade-a (vidi header).
    const { error: safeErr } = await admin
      .schema("domovina_ai")
      .from("safe_actions")
      .update({ account_id: null })
      .eq("account_id", user.id);
    if (safeErr) {
      // Tablica možda ne postoji u ovom environmentu — logiraj i nastavi;
      // deleteUser će svejedno pasti ako FK stvarno blokira.
      console.warn("account-delete: safe_actions unlink:", safeErr.message);
    }

    // 2. Channel ownership / Safe payout follow-up: on-chain Safe multisig ne
    //    ovisi o auth.users redu, ali vlasništvo se gubi — logiraj za ručni
    //    follow-up prije nego cascade obriše redove.
    const { data: claims } = await admin
      .schema("domovina_ai")
      .from("channel_claims")
      .select("youtube_channel_id, status")
      .eq("account_id", user.id);
    if (claims?.length) {
      console.warn(
        "account-delete: user had channel claims:",
        user.id,
        claims.map((c) => `${c.youtube_channel_id}:${c.status}`).join(","),
      );
    }

    // 3. Obriši auth.users red — cascade čisti profiles, domovina_ai.*,
    //    user_passkeys i identity_verifications (GDPR: enkriptirani OIB).
    const { error: delErr } = await admin.auth.admin.deleteUser(user.id);
    if (delErr) {
      console.error("account-delete: deleteUser failed:", delErr.message);
      return json({ error: "delete_failed", detail: delErr.message }, 500);
    }

    return json({ ok: true }, 200);
  } catch (e) {
    console.error("account-delete error", e);
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
