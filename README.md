# MacTalk

**[⬇ Download MacTalk for Mac (DMG)](https://github.com/tgopinath/MacTalk/releases/latest/download/MacTalk.dmg)** · macOS 14+ · Apple Silicon & Intel

A native macOS walkie-talkie that lives in the menu bar. Sign in with Google or an email code, then add friends by email. Once they accept, call them with one click or with **⌃1–⌃9**. They get a ringing alert in the bottom-right corner of their screen. When they accept, you talk over encrypted peer-to-peer audio.

- **App:** Swift 6, SwiftUI + AppKit, `MenuBarExtra`, AVFoundation, CoreAudio, UserNotifications, Carbon hotkeys
- **Audio:** WebRTC (Opus, DTLS-SRTP, echo cancellation, noise suppression, automatic gain control)
- **Backend:** Supabase Auth (Google sign-in + email OTP), Postgres with Row Level Security, Realtime, Storage, Edge Functions
- **NAT traversal:** public STUN, plus TURN from a provider you configure (Cloudflare, coturn, or static credentials)

---

## 1. Status: what works and what still needs your setup

| Area | State |
|---|---|
| Swift package builds (`swift build`), 28 unit tests pass (`swift test`) | ✅ Checked on macOS 26.7 / Xcode 26.1, Apple Silicon |
| `MacTalk.app` bundle builds, signs ad-hoc, and launches as a menu bar app | ✅ Checked |
| All screens render in light and dark mode (debug preview renderer) | ✅ Checked |
| Supabase schema, RLS, SQL functions, Edge Functions | ✅ Written. ⚠️ **Not run yet:** this machine has no Supabase project, so the migration and pgTAP tests haven't been run against a database. |
| Real sign-in, invitations, presence, calling, and audio | ⚠️ **Needs your Supabase project and two Macs.** These were not tested end to end. See §7. |

No API keys or credentials were invented. The app shows a **"configuration needed"** screen until you add your own (§3).

---

## 2. How it works

```
 Mac A (caller)                        Supabase                            Mac B (callee)
 ─────────────                         ────────                            ──────────────
 Call ▸ start_call(B) ───────────────▶ checks: verified, friends, not
                                       blocked, B online, not busy/DND,
                                       no active call, rate limit,
                                       race locks → INSERT calls(ringing)
                                                   │ Realtime (RLS-filtered)
                                                   └──────────────────────▶ ring + bottom-right alert
                                                                            (mic NOT opened)
                                       answer_call(accept) ◀─────────────── Accept
 Realtime: status=accepted ◀──────────
 WebRTC offer ──▶ call_signals ───────────────────────────────────────────▶ answer
 ICE candidates ◀──────────────────── call_signals ───────────────────────▶ ICE candidates
 ◀════════════════ encrypted audio (DTLS-SRTP), P2P or via TURN ══════════════▶
 End ▸ end_call ─────────────────────▶ status=ended ──────────────────────▶ window closes
```

**If a Realtime event is lost, three fallbacks catch it:**
1. The 25-second presence heartbeat returns any call ringing for you.
2. While a call is ringing or connecting, the client re-reads the call row and signals every 3 s.
3. After every Realtime resubscribe (wake, network change), the app refreshes everything.

### Source layout

```
Sources/MacTalkCore/        Pure logic, unit-tested: models, call state machine, presence
                            rules, speed-dial ordering, signaling inbox, error copy, config
Sources/MacTalk/
  App/            @main, AppDelegate (quit / reopen), AppModel (composition root), WindowManager
  MenuBar/        Menu bar icon states, popover
  Authentication/ Email OTP, profile setup, avatar upload / presets
  Friends/        Invite, accept/decline, cancel/resend, remove, block; Add/Manage windows
  Presence/       Heartbeat, sleep/wake, recovery
  Calling/        CallManager (lifecycle), incoming alert, active call window, ⌃1–⌃9 hotkeys
  WebRTC/         Peer connection, audio track, stats → connection quality
  Notifications/  UNUserNotificationCenter actions, ringtone
  Audio/          CoreAudio devices, mic permission, input level meter
  Settings/       Preferences store + Settings window
  Networking/     NWPathMonitor, Realtime channel hub
  Database/       Supabase client + error mapping
  Debug/          Preview renderer (debug builds only)
supabase/
  migrations/     Tables, indexes, RLS, SQL functions, Realtime publication, avatar bucket, pg_cron
  functions/      invite-friend, turn-credentials (Deno Edge Functions)
  tests/          pgTAP security tests
scripts/          build-app.sh, notarize.sh, make-icon.swift
Config/           <env>.env files (development / staging / production)
```

---

## 3. Setup

### 3.1 Supabase project

1. Create a project at [supabase.com](https://supabase.com).
2. Install the CLI (`brew install supabase/tap/supabase`), then link the project and push the schema:
   ```bash
   cd MacTalk
   supabase link --project-ref YOUR-PROJECT-REF
   supabase db push
   ```
   If you'd rather not use the CLI, paste `supabase/migrations/20261118000000_mactalk_schema.sql` into the SQL Editor and run it.
3. **Auth → Providers → Email:** turn on Email and "Confirm email". MacTalk signs in with a 6-digit code, so:
   **Auth → Email Templates → Magic Link** and **Confirm signup**: add the code to the body, for example:
   ```html
   <h2>Your MacTalk code</h2><p style="font-size:24px"><b>{{ .Token }}</b></p>
   ```
   **Invite user** template (this goes to friends who don't have an account yet):
   ```html
   <p>You've been invited to MacTalk. Install MacTalk, then sign in with this email address to accept.</p>
   ```
4. **Auth → Rate limits:** keep the defaults or tighten them. The database also rate-limits invitations (20/hour) and calls (12/minute).
5. **Google sign-in** (optional but recommended):
   1. In [Google Cloud Console](https://console.cloud.google.com/apis/credentials), create an **OAuth client ID** of type **Web application**.
   2. Under **Authorized redirect URIs**, add `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback`.
   3. In Supabase, go to **Auth → Providers → Google**, turn it on, and paste the client ID and secret.
   4. In Supabase, go to **Auth → URL Configuration → Redirect URLs** and add `mactalk://auth-callback`.

   The app opens Google in a system sign-in sheet that shares Safari's Google login. Google accounts arrive already verified, and the profile starts with their Google name and photo, which they can change.
6. Production: set up custom SMTP (Auth → SMTP). Supabase's built-in mailer only allows a few emails per hour.

### 3.2 Edge Functions and secrets

```bash
supabase functions deploy invite-friend
supabase functions deploy turn-credentials
```

TURN relays audio when two Macs can't connect directly (strict NAT, corporate Wi-Fi). Configure **one** of these:

```bash
# Cloudflare Realtime TURN (recommended; has a free tier)
supabase secrets set CLOUDFLARE_TURN_KEY_ID=... CLOUDFLARE_TURN_API_TOKEN=...
# or your own coturn with use-auth-secret
supabase secrets set TURN_URLS="turn:turn.example.com:3478,turns:turn.example.com:5349" TURN_SHARED_SECRET=...
# or static credentials (Metered, Twilio, …)
supabase secrets set TURN_URLS=... TURN_USERNAME=... TURN_CREDENTIAL=...
```

Optional: invitation emails to people who **already** have an account, sent through [Resend](https://resend.com):
```bash
supabase secrets set RESEND_API_KEY=... INVITE_FROM_EMAIL="MacTalk <invites@yourdomain.com>" MACTALK_DOWNLOAD_URL=https://...
```
Without Resend, people who already have an account still see the invitation instantly in MacTalk (popover and notification). People without an account always get Supabase's invite email.

All of these secrets stay on the server. The app only contains the public anon key.

### 3.3 Configure and build the app

```bash
cp Config/example.env Config/development.env
# edit SUPABASE_URL and SUPABASE_ANON_KEY (Project Settings → API)
scripts/build-app.sh development debug
open dist/MacTalk.app
```

`staging.env` and `production.env` work the same way: `scripts/build-app.sh production release`. Release builds are universal (Apple Silicon + Intel).

---

## 4. Using MacTalk

- **Menu bar icon**: green dot = online, red = busy / DND, grey = offline, orange + animated waves = incoming call, blue waveform = in a call.
- **Popover**: your status menu, invitations, friend search, friend list with presence and a call button, plus Add Friend / Manage / Settings / Quit.
- **Speed dial**: **⌃1 … ⌃9** call friends 1–9 from anywhere, even with the popover closed. Each friend's shortcut shows as a badge. Drag to reorder in **Manage Friends**.
  - Press the same shortcut again to hang up, or to **answer** when that friend is calling you.
  - Choose ⌃⌥ or ⌃⌘ in **Settings › Speed Dial** if ⌃1–⌃9 switch Desktops on your Mac (Mission Control shortcut).
- **Incoming call**: an alert slides in at the bottom right, above full-screen apps and on every Space. Press Return to accept or Esc to decline. In Settings › Notifications you can switch to a macOS notification banner with Accept/Decline actions, or use both.
- **In a call**: mute (M), speaker/microphone picker and volume, connection-quality bars, timer, End (Esc).

### Closing, quitting, and termination

| What happens | Effect |
|---|---|
| Close the popover or any window | Nothing changes. MacTalk keeps running and still rings. |
| **Quit MacTalk** | Ends or cancels any call, marks you offline right away, then exits. No calls can arrive until you open it again. |
| Mac sleeps | Goes offline (best effort, 1 s). On wake, reconnects Realtime and resumes the heartbeat. |
| Crash / force quit / power loss | The server marks you offline within 60 s once heartbeats stop. pg_cron ends abandoned calls. |
| App not running | **Can't receive calls.** macOS has no way to wake a non-running Mac app for VoIP. Friends see you as offline and can't ring you. Turn on **Launch at login** to keep MacTalk available. |

---

## 5. Security model

- **Every rule runs on the server.** Clients can't insert or update `calls`, `friend_requests`, `friendships`, or `blocked_users` directly (privileges are revoked). All changes go through `SECURITY DEFINER` SQL functions that check:
  - the email is verified (`email_confirmed_at`)
  - an **accepted, mutual friendship** exists, and neither side has blocked the other
  - the callee is online (heartbeat < 60 s), not DND or busy, and not already in a call
  - rate limits are respected
  - advisory locks block simultaneous duplicate or crossed calls
  - calls expire after 45 s
- **RLS:** you can read only your own profile and your accepted friends' profiles. Strangers can't see your email or presence.
- **Signaling:** `call_signals` rows can be inserted only by a participant, addressed to the other participant, and only after the call is **accepted**. No SDP means no media, so **audio can't flow before acceptance**. The client also never creates the microphone track until then.
- **Media:** WebRTC requires DTLS-SRTP. All signaling uses TLS (HTTPS / WSS).
- **Privacy:**
  - Inviting an address never reveals whether it has an account.
  - Blocked people get the same "sent" response and aren't told they're blocked.
  - Notification previews can hide the caller.
- **Session** is stored in the macOS Keychain (`KeychainLocalStorage`). The anon key is public by design. The service-role key and TURN secrets live only in Edge Function secrets.

---

## 6. Platform notes and limitations

- **CallKit isn't available to native macOS apps.** It's iOS / Mac Catalyst only. MacTalk uses its own call alert window plus `UNUserNotificationCenter` actions instead.
- **Audio device selection:** WebRTC's macOS audio module always uses the *system default* devices. During a call, MacTalk switches the default to the microphone/speaker you picked and restores your previous defaults when the call ends. Switching in the middle of a call depends on WebRTC noticing the default-device change; picking devices before the call is the most reliable.
- **Time-sensitive notifications** need the `com.apple.developer.usernotifications.time-sensitive` entitlement on a provisioned build. Without it, banners are ordinary priority. The bottom-right call alert is unaffected.
- **"Launch at login"** uses `SMAppService` and works best when MacTalk is in `/Applications`.
- **Global hotkeys** use Carbon `RegisterEventHotKey`, which doesn't need Accessibility permission. If another app already owns a shortcut, Settings › Speed Dial tells you which ones.

---

## 7. Testing

### Automated (done)
```bash
swift test          # 28 tests: call state machine, speed dial, presence, signaling inbox, errors, config, quality
```

### Database (run once your project is linked)
```bash
supabase test db    # supabase/tests/mactalk_security.test.sql: 24 checks for RLS, friendship-gated calling,
                    # offline / busy / crossed calls, signaling-before-accept, blocking
```

### Design previews (debug builds)
```bash
dist/MacTalk.app/Contents/MacOS/MacTalk --render-previews /tmp/mactalk-previews
```

### End to end (two Macs, or two macOS user accounts)
Build on both Macs with the same `Config/development.env`, then go through this list:

1. **Sign up**: A uses **Continue with Google** → profile prefilled with the Google name/photo. B enters an email → gets the code → creates a profile. Close MacTalk and reopen it: still signed in (Keychain).
2. **Invite**:
   - A adds B's email → B gets an invite email, signs up, and sees the invitation → Accept → both lists update live.
   - Also test Decline, Cancel, Resend, Remove, Block/Unblock.
3. **Presence**:
   - B quits → A sees B go offline right away.
   - B force-quits (`kill -9`) → A sees B offline within about 60 s.
   - Put B to sleep → offline. Wake B → online.
   - Set B to Busy or DND → A's call button is disabled and explains why.
4. **Calling**:
   - A clicks Call (or ⌃1) → B's alert rings in the bottom right with the ringtone → Accept → both hear each other.
   - Test mute, speaker/mic picker, End from either side, and Decline.
   - A cancels while ringing → B's ring stops immediately.
   - No answer for 45 s → "No answer" for A and "Missed call" for B.
   - B busy in another call → A sees "already in a call".
   - Both press Call at the same moment → they connect into one call.
5. **Network**:
   - Turn Wi-Fi off and on during a call → "Reconnecting…" → audio comes back (ICE restart), or the call ends cleanly after 20 s.
   - Test on two different networks (e.g. one Mac on a phone hotspot) to exercise TURN.
6. **Permissions**:
   - Deny the microphone → the alert explains and links to System Settings, and no audio session starts.
   - Deny notifications → calls still ring through the MacTalk alert.

---

## 8. Distribution

1. Set your Developer ID and bundle ID, then build:
   ```bash
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" BUNDLE_ID=com.yourco.MacTalk VERSION=1.0.0 \
     scripts/build-app.sh production release
   ```
   This signs with hardened runtime, secure timestamp, and the `com.apple.security.device.audio-input` entitlement.
2. Notarize and staple (one-time setup: `xcrun notarytool store-credentials mactalk --apple-id … --team-id …`):
   ```bash
   scripts/notarize.sh        # → dist/MacTalk.zip
   ```
3. Package the DMG: `scripts/make-dmg.sh` → `dist/MacTalk.dmg` (signed when `SIGN_IDENTITY` is set). Publish it as a GitHub Release asset:
   ```bash
   gh release upload v1.0.0 dist/MacTalk.dmg --clobber
   ```
4. **Install:** open the DMG, drag **MacTalk.app** to **Applications**, open it. Allow the microphone and notifications when asked, and turn on **Launch at login** in Settings.

**Current public DMG:** it's signed with an *Apple Development* certificate, not Developer ID, so Apple hasn't notarized it. The first time, macOS blocks it: Control-click **MacTalk** in Applications → **Open** → **Open**. On macOS 15 and later, go to **System Settings › Privacy & Security** and click **Open Anyway**. A Developer ID build plus `scripts/notarize.sh` removes this step.

Ad-hoc local builds (`SIGN_IDENTITY` unset) skip hardened runtime, because library validation needs a Team ID to load the bundled WebRTC framework. They run only on the Mac that built them.
