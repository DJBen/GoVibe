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

## 3) Start mac agent

```bash
cd ios
# Open GoVibe.xcworkspace and run scheme GoVibeMacAgent.
```

In the Mac app:
1. Select terminal source (`Terminal.app` or `Embedded Shell`).
2. Click `Start Agent`.

Optional env vars:

- `GOVIBE_API_BASE`
- `GOVIBE_MAC_DEVICE_ID` (defaults to `mac-demo-01`)
- `GOVIBE_SHELL`
- `GOVIBE_ID_TOKEN`
- `GOVIBE_TERMINAL_SOURCE` (`terminalapp` or `pty`)

## 3b) Start mac CLI agent (recommended for robustness)

Run scheme `GoVibeMacCli` with arguments, for example:

```bash
--device-id mac-demo-01 --command "claude"
```

or:

```bash
--device-id mac-demo-01 --command "tmux new -As govibe"
```

Optional CLI flags:

- `--relay <wss-url>`
- `--shell </bin/zsh>`
- `--device-id <room-id>`
- `--command <startup-command>`

## 4) Launch iOS app

1. Add `GoogleService-Info.plist` to `ios/GoVibe` target.
2. Build/run `GoVibe` in Xcode.
3. Tap `Auth`, `Start Pair`, then `Create Session`.
4. Terminal I/O now uses relay room `room=<macDeviceId>`.

## Relay Message Protocol

- iOS -> Mac:
  - `{ "type": "terminal_input", "text": "ls -la" }`
- Mac -> iOS:
  - `{ "type": "terminal_output", "text": "..." }`

## Known Gaps

- Dynamic room/session negotiation is not fully wired; current demo room defaults to `mac-demo-01`.
- WebRTC transport remains deferred to v1.1.
