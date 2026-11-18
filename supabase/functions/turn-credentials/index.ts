// MacTalk: short-lived STUN/TURN credentials for WebRTC.
// TURN secrets live only in Edge Function secrets, never in the Mac app.
//
// Configure ONE of:
//   Cloudflare Realtime TURN:  CLOUDFLARE_TURN_KEY_ID + CLOUDFLARE_TURN_API_TOKEN
//   coturn (REST auth secret):  TURN_URLS (comma separated) + TURN_SHARED_SECRET
//   Static credentials:         TURN_URLS + TURN_USERNAME + TURN_CREDENTIAL
// With nothing configured only public STUN is returned (works on most home networks,
// fails behind symmetric NAT / strict corporate firewalls).
import { createClient } from "npm:@supabase/supabase-js@2";

type IceServer = { urls: string | string[]; username?: string; credential?: string };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const STUN: IceServer[] = [{ urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] }];

async function cloudflare(keyId: string, token: string): Promise<IceServer[]> {
  const res = await fetch(`https://rtc.live.cloudflare.com/v1/turn/keys/${keyId}/credentials/generate-ice-servers`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ ttl: 3600 }),
  });
  if (!res.ok) throw new Error(`cloudflare ${res.status}`);
  const body = await res.json();
  const servers = Array.isArray(body.iceServers) ? body.iceServers : [body.iceServers];
  return servers as IceServer[];
}

async function coturn(urls: string[], secret: string, userId: string): Promise<IceServer[]> {
  const username = `${Math.floor(Date.now() / 1000) + 3600}:${userId}`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(username));
  const credential = btoa(String.fromCharCode(...new Uint8Array(sig)));
  return [{ urls, username, credential }];
}

Deno.serve(async (req) => {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "not_authenticated" }, 401);
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } });
  const { data: { user } } = await client.auth.getUser();
  if (!user || !user.email_confirmed_at) return json({ error: "not_authenticated" }, 401);

  const urls = (Deno.env.get("TURN_URLS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  try {
    let turn: IceServer[] = [];
    const cfKey = Deno.env.get("CLOUDFLARE_TURN_KEY_ID");
    const cfToken = Deno.env.get("CLOUDFLARE_TURN_API_TOKEN");
    if (cfKey && cfToken) turn = await cloudflare(cfKey, cfToken);
    else if (urls.length && Deno.env.get("TURN_SHARED_SECRET")) turn = await coturn(urls, Deno.env.get("TURN_SHARED_SECRET")!, user.id);
    else if (urls.length && Deno.env.get("TURN_USERNAME")) {
      turn = [{ urls, username: Deno.env.get("TURN_USERNAME"), credential: Deno.env.get("TURN_CREDENTIAL") }];
    }
    return json({ iceServers: [...STUN, ...turn], turn: turn.length > 0 });
  } catch (e) {
    console.error("turn-credentials", e);
    return json({ iceServers: STUN, turn: false });
  }
});
