# GoVibe v1 Technical Plan (Firebase + Google Cloud)

## Summary
Implement the Mac-to-iPhone terminal remoting product using Firebase for app/backend primitives and Google Cloud for media relay + compute.
Core approach remains terminal-structured streaming (PTY diffs), with Cloud Run WebSocket relay as the v1 primary transport. WebRTC remains a future optimization path.

## PTY-Native Migration Status (Implemented)
1. Mac runtime now uses native `forkpty` (replaced `Process` + `Pipe`).
2. Relay transport now uses byte-safe base64 payloads:
- `terminal_output`: `{ type, encoding: "base64", data }`
- `terminal_input`: `{ type, encoding: "base64", data }`
- `terminal_resize`: `{ type, cols, rows }`
3. iOS terminal surface now uses `SwiftTerm` for ANSI/VT rendering and input handling.
4. Transitional compatibility remains enabled for legacy text envelopes during migration.

## Current Implementation Decision Update
1. Selected intermediary: Option 2 (`Cloud Run WebSocket relay as primary transport`).
2. Firebase/Firestore are the control plane (auth/session lifecycle), while terminal I/O uses relay WebSocket data plane.
3. Relay room model for demo: iOS and Mac agent join `room=<macDeviceId>`.
4. WebRTC negotiation is deferred; signaling schema remains for future migration.

## Platform Choices (Locked)
1. Identity and app trust bootstrap: Firebase Authentication (anonymous for demo, upgrade path to Sign in with Apple + Firebase custom claims).
2. Session signaling/state: Cloud Firestore + Firebase Cloud Functions (2nd gen).
3. Device pairing and tokens: Firestore + Cloud KMS-backed signing in Cloud Functions.
4. Connectivity: Cloud Run relay WebSocket primary for v1; WebRTC/STUN/TURN deferred to v1.1.
5. Observability: Cloud Logging + Cloud Monitoring + Error Reporting.
6. Push/resume notifications: Firebase Cloud Messaging (FCM).
7. iOS app distribution for demo: TestFlight; backend secrets in Secret Manager.

## Architecture (Firebase/GCP)

1. `govibe-mac-agent` (macOS local daemon/app)
- Opens/manages PTY (`zsh`/`bash`/`tmux`).
- Parses ANSI/VT and emits `TerminalDiff` / `TerminalSnapshot`.
- Connects to backend via HTTPS for control plane.
- Connects to Cloud Run relay WebSocket room and streams terminal output/input.
- Caches short replay buffer locally for resume.

2. `govibe-ios` (Swift)
- Uses Firebase SDK (Auth, Firestore, FCM).
- Native terminal renderer (grid/cell model).
- Keyboard + modifiers + touch cursor + paste/scrollback.
- Connects to Cloud Run relay WebSocket room for live terminal I/O.
- Handles foreground/background resume with session token refresh.

3. Firebase/GCP backend
- Firestore collections for pairings, sessions, candidates, heartbeats.
- Cloud Functions endpoints for pairing/session lifecycle/token minting.
- TURN credentials minted ephemerally by Cloud Function.
- Optional Cloud Run “relay-tunnel” fallback for WebSocket tunneling when WebRTC fails.

## Data Model (Firestore)

1. `devices/{deviceId}`
- `platform` (`mac`|`ios`)
- `pubKey`
- `pairedWith[]`
- `createdAt`, `lastSeenAt`

2. `pairings/{pairId}`
- `macDeviceId`, `iosDeviceId`
- `codeHash`, `expiresAt`
- `status` (`pending`|`confirmed`)

3. `sessions/{sessionId}`
- `ownerDeviceId`, `peerDeviceId`
- `state` (`creating`|`active`|`grace`|`closed`)
- `createdAt`, `graceUntil`, `lastHeartbeat`
- `icePolicy`, `relayRequired`

4. `sessions/{sessionId}/signal/{msgId}`
- `type` (`offer`|`answer`|`ice`)
- `fromDeviceId`
- `payload`
- `createdAt`

## Cloud Functions API (Public Interfaces)

1. `POST /pair/start`
- Input: `macDeviceId`
- Output: short-lived `pairCode`, `pairId`, expiry.

2. `POST /pair/confirm`
- Input: `pairId`, `pairCode`, `iosDeviceId`, device proof.
- Output: pairing confirmation + trusted device binding.

3. `POST /session/create`
- Input: requester device proof.
- Output: `sessionId`, signaling refs, ICE config, ephemeral TURN creds.

4. `POST /session/resume`
- Input: `sessionId`, device proof.
- Output: resume authorization if `now <= graceUntil`.

5. `POST /session/close`
- Input: `sessionId`
- Output: closed ack + cleanup trigger.

## Realtime Signaling Flow
1. iOS calls `session/create`.
2. Both peers watch `sessions/{id}/signal`.
3. Exchange SDP offer/answer + ICE candidates through Firestore docs.
4. iOS and Mac join relay room `room=<macDeviceId>`.
5. iOS sends `terminal_input` messages; Mac sends `terminal_output` messages.

## Security Model (Firebase-native)
1. Firebase Auth required for all clients (anonymous in demo).
2. Firestore Security Rules enforce:
- Device can only access sessions where it is participant.
- Write constraints on signaling message types/ownership.
3. Pairing code hashed at rest; TTL enforced by Function + Firestore TTL.
4. Session and TURN credentials are short-lived signed tokens.
5. Secrets managed by Secret Manager; signing keys in Cloud KMS.

## iOS Background/Resume
1. On background, app sends `session state=grace`.
2. Backend sets `graceUntil = now + 3m` (default).
3. Agent keeps PTY alive and local buffer.
4. FCM data message prompts quick resume path if network changes.
5. On resume, iOS requests `session/resume`; agent sends compact snapshot + tail replay.

## Performance Targets
1. Input-to-echo p50 < 120ms on LTE/Wi-Fi.
2. Typical active bandwidth < 80 KB/s.
3. Reconnect success in grace window > 95%.
4. Signaling setup median < 1.5s.

## Deployment Plan (GCP)
1. Firebase project + iOS app registration.
2. Firestore Native mode + TTL indexes.
3. Cloud Functions (2nd gen, region `us-west1` default).
4. Cloud Run relay service (min instances 0 for demo, scale-to-zero).
5. TURN deployment:
- v1 demo: single-zone GCE Coturn + static IP.
- v1.1: multi-zone managed deployment + autoscaling.
6. Monitoring dashboards + alerting (error rate, session failures, TURN auth failures).

## Test Cases and Scenarios

1. Pairing
- Valid code success, expired code rejection, replay attempt rejection.

2. Session bring-up
- Session create success via backend.
- iOS and Mac successfully join same relay room and exchange terminal I/O.

3. Terminal correctness
- Shell commands, Claude Code interaction, resize/orientation change.
- Alternate buffer apps (`vim`, `htop`, `less`).
- Unicode width/combining character cases.

4. Resilience
- iOS background for 2 minutes then resume.
- Wi-Fi -> cellular handoff during active session.
- Firestore transient error recovery.

5. Security
- Unauthorized device read/write blocked by Rules.
- Expired session token denied.
- TURN creds cannot be reused after expiry.

## Public API / Interface Changes
1. New backend endpoints under `api.govibe.dev`:
- `/pair/start`, `/pair/confirm`, `/session/create`, `/session/resume`, `/session/close`.
2. Firestore collections added:
- `devices`, `pairings`, `sessions`, nested `signal`.
3. Client protocol envelopes standardized:
- `TerminalDiff`, `TerminalSnapshot`, `InputEvent`, `SessionEvent`.

## Assumptions and Defaults
1. Demo targets one Mac + one iPhone.
2. Firebase anonymous auth is acceptable for v1 demo.
3. Default GCP region: `us-west1`.
4. Keepalive grace window default: 3 minutes.
5. Terminal-native-only scope; no arbitrary GUI window remoting in v1.
6. Relay room default: `mac-demo-01` until dynamic room negotiation is added.
