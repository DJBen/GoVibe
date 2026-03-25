# GoVibe Firebase/GCP Architecture

## Components

- iOS app (`ios/GoVibe`): Firebase Auth (Google sign-in) + session control + relay client.
- macOS host app (`ios/GoVibeHostApp` target): shell/simulator session runtime + relay connection.
- Firebase Functions (`backend/functions`): session lifecycle APIs, device registration, relay token issuance.
- Firestore: `devices`, `devices/{id}/hostedSessions`, `sessions`, `relay_rooms` for control plane.
- Cloud Run relay (`infra/cloud-run-relay`): terminal/control data plane (WebSocket room relay with Redis pub/sub backplane).
- Cloud Memorystore (Redis): pub/sub backplane enabling horizontal scaling of relay instances.

## Discovery

Host and session discovery is Firestore-based (no relay involvement):

1. macOS host registers in Firestore (`/devices/{hostId}`) and sends periodic heartbeats.
2. macOS host writes session metadata to `/devices/{hostId}/hostedSessions/{sessionId}`.
3. iOS listens to Firestore in real-time, filtered by `ownerUid`, to discover hosts and sessions.

## Transport

1. Control plane:
- Firebase Auth (Google sign-in)
- Functions session APIs (`/device/register`, `/device/heartbeat`, `/relay/token`, etc.)
- Firestore metadata/state

2. Data plane:
- Control rooms: `room={hostId}-ctl` — session create/delete commands
- Session rooms: `room={hostId}-{sessionId}` — terminal I/O, input events
- Redis pub/sub backplane enables cross-instance message routing when Cloud Run auto-scales
- Simulator/window sessions planned for WebRTC peer-to-peer delivery

## Security

- Firestore rules enforce `ownerUid` on all device and session documents.
- Function endpoints require Firebase ID token.
- Relay connections require HMAC-signed tokens scoped to a specific room and role.
- Relay tokens are short-lived (300s) and issued by the backend after device ownership validation.
