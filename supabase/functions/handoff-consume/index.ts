import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(URL, ANON, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user } } = await userClient.auth.getUser();
  if (!user) return json({ error: "not_authenticated" }, 401);

  const { code, device } = await req.json().catch(() => ({}));
  if (!/^\d{6}$/.test(code ?? "")) return json({ error: "invalid_code_format" }, 400);

  const admin = createClient(URL, SERVICE, { auth: { persistSession: false } });

  const { data, error } = await admin
    .schema("domovina_ai")
    .rpc("consume_handoff_token", { p_code: code, p_device: device ?? null });
  if (error) return json({ error: error.message }, 400);

  const targetUserId = (data as any).user_id as string;
  const { data: { user: target } } = await admin.auth.admin.getUserById(targetUserId);

  const { data: link } = await admin.auth.admin.generateLink({
    type: "magiclink",
    email: target?.email ?? "",
    options: { redirectTo: "ai.domovina://auth/callback" },
  });

  await admin.from("activity_events").insert({
    actor_user_id: user.id,
    event_type: "handoff.consumed",
    payload: { code_user: targetUserId, device },
  });

  return json({ action_link: link?.properties?.action_link, user_id: targetUserId }, 200);

  function json(body: unknown, status: number) {
    return new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
