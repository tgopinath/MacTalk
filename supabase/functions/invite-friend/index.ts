// MacTalk: invite a friend by email, or re-send a pending invitation.
//
// POST { "action": "invite", "email": "friend@example.com" }
// POST { "action": "resend", "request_id": "<uuid>" }
//
// All authorization (verified sender, blocking, rate limits, duplicate requests) is
// enforced by SQL functions that run as the signed-in user. The service-role key is
// only used to send Supabase's invite email to people who don't have an account yet.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");          // optional
const INVITE_FROM = Deno.env.get("INVITE_FROM_EMAIL") ?? "MacTalk <invites@example.com>";
const DOWNLOAD_URL = Deno.env.get("MACTALK_DOWNLOAD_URL") ?? "";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function sendNoticeEmail(to: string, senderName: string): Promise<boolean> {
  if (!RESEND_API_KEY) return false;
  const download = DOWNLOAD_URL ? `<p><a href="${DOWNLOAD_URL}">Get MacTalk for Mac</a></p>` : "";
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: INVITE_FROM,
      to,
      subject: `${senderName} wants to talk on MacTalk`,
      html: `<p><strong>${senderName}</strong> invited you to be friends on MacTalk.</p>
             <p>Open MacTalk from your menu bar and accept the invitation to start talking.</p>${download}`,
    }),
  });
  return res.ok;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "not_authenticated" }, 401);

  const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: authHeader } } });
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: { user }, error: userError } = await asUser.auth.getUser();
  if (userError || !user) return json({ error: "not_authenticated" }, 401);

  let body: { action?: string; email?: string; request_id?: string };
  try { body = await req.json(); } catch { return json({ error: "invalid_request" }, 400); }

  const { data: me } = await asUser.from("users").select("display_name, email").eq("id", user.id).single();
  const senderName = me?.display_name || me?.email || "A friend";

  if (body.action === "invite") {
    const email = (body.email ?? "").trim().toLowerCase();
    let { data, error } = await asUser.rpc("request_friend", { p_email: email });
    if (error) return json({ error: error.message }, 400);

    let emailDelivered = false;
    if (data.outcome === "no_account") {
      // Creates an unconfirmed account and emails the Supabase "Invite user" template.
      const invite = await admin.auth.admin.inviteUserByEmail(email, {
        data: { invited_by: user.id },
      });
      if (invite.error) return json({ error: "invite_failed" }, 502);
      emailDelivered = true;
      ({ data, error } = await asUser.rpc("request_friend", { p_email: email }));
      if (error) return json({ error: error.message }, 400);
    } else if (data.outcome === "sent") {
      emailDelivered = await sendNoticeEmail(email, senderName);
    }
    if (emailDelivered && data.request_id) {
      await asUser.rpc("mark_request_emailed", { p_request_id: data.request_id });
    }
    // Never reveal whether the address already had an account.
    return json({ outcome: data.outcome === "no_account" ? "sent" : data.outcome, email_delivered: emailDelivered });
  }

  if (body.action === "resend") {
    const { data, error } = await asUser.rpc("prepare_resend", { p_request_id: body.request_id });
    if (error) return json({ error: error.message }, 400);
    let delivered = false;
    if (!data.receiver_verified) {
      const invite = await admin.auth.admin.inviteUserByEmail(data.email);
      delivered = !invite.error;
      if (!delivered) delivered = await sendNoticeEmail(data.email, senderName);
    } else {
      delivered = await sendNoticeEmail(data.email, senderName);
    }
    return json({ outcome: "resent", email_delivered: delivered });
  }

  return json({ error: "invalid_request" }, 400);
});
