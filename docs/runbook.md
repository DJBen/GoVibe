# Local Runbook

## 1) Start backend (control plane)

```bash
cd backend/functions
npm install
npm run build
npm run serve
```

## 2) Start relay (data plane)

```bash
cd infra/cloud-run-relay
npm install
npm start
```

The relay listens on `ws://localhost:8080/relay` by default (set `PORT` env var to change).

For local-only mode (no Redis), simply omit `REDIS_URL`. To test with Redis backplane locally:

```bash
redis-server --port 6399 --daemonize yes
REDIS_URL=redis://localhost:6399 npm start
```

## 3) Start macOS host app

1. Open `ios/GoVibe.xcworkspace` in Xcode.
2. Build and run the `GoVibeHost` macOS target.
3. In the host onboarding flow:
   - Sign in with your Google account
   - Set the relay WebSocket URL to `ws://localhost:8080/relay`
   - Grant Accessibility and Screen Recording permissions
4. Create terminal/simulator sessions from the host dashboard.

## 4) Launch iOS app

1. Copy `ios/GoVibe/GoogleService-Info.plist.template` to `ios/GoVibe/GoogleService-Info.plist` and replace with real Firebase config.
2. Set `GOVIBE_GCP_RELAY_HOST = localhost:8080` in `ios/Config/Shared.xcconfig`.
3. Build/run `GoVibe` in Xcode.
4. Sign in with the same Google account as the host app.
5. Your Mac host and its sessions appear automatically via Firestore discovery.

## Relay Room Protocol

- Control rooms: `{hostId}-ctl` — session lifecycle commands
- Session rooms: `{hostId}-{sessionId}` — terminal I/O, input events

Message types:
- iOS -> Mac: `{ "type": "terminal_input", "text": "ls -la" }`
- Mac -> iOS: `{ "type": "terminal_output", "text": "..." }`
- Mac -> relay: `{ "type": "push_notify", "event": "claude_approval_required", "sessionName": "..." }` (triggers FCM)
