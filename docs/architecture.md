# GoVibe Firebase/GCP Architecture

## Components

- iOS app (`ios/GoVibe`): Firebase Auth + session control + relay client.
- Mac agent (`ios/GoVibeMacAgent` target): shell session runtime + relay server connection.
- Firebase Functions (`backend/functions`): session lifecycle APIs.
- Firestore: `devices`, `sessions` for control plane.
- Cloud Run relay (`infra/cloud-run-relay`): primary terminal data plane (WebSocket room relay).

## v1 Transport

1. Control plane:
- Firebase Auth
- Functions session APIs
- Firestore metadata/state

2. Data plane:
- iOS and Mac connect to relay room (`room=<macDeviceId>`)
- iOS sends `terminal_input`
- Mac sends `terminal_output`

## Security

- Firestore direct write to session roots is disabled.
- Function endpoints require Firebase ID token.
- Session/TURN credentials are short-lived signed tokens (TURN/WebRTC reserved for v1.1).
