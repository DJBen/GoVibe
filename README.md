# GoVibe

GoVibe is an open-source remote terminal app that lets you control a Mac terminal session from an iPhone or iPad in real time.

```
iOS App ──WebSocket──▶ Cloud Run Relay ◀──WebSocket── Mac CLI (GoVibeMacCli)
                              │
                    Firebase Auth + Functions
                          (control plane)
```

The iOS app connects to a WebSocket relay hosted on Google Cloud Run. The Mac CLI connects to the same relay room. Firebase provides anonymous auth and a lightweight session-management API. No credentials are stored in the repo.

---

## Repository Layout

```
GoVibe/
├── ios/
│   ├── GoVibe.xcworkspace         # Open this in Xcode
│   ├── GoVibe/                    # iOS app target (thin wrapper)
│   ├── GoVibeFeaturePackage/      # All shared Swift feature code
│   ├── GoVibeMacCli/              # macOS CLI target (Swift executable)
│   └── Config/
│       ├── GoogleService-Info.plist.template   # Fill in & rename (gitignored)
│       ├── Debug.xcconfig
│       └── Release.xcconfig
├── backend/
│   └── functions/                 # Firebase Functions (Node.js / TypeScript)
├── infra/
│   └── cloud-run-relay/           # WebSocket relay service (Node.js)
├── shared/
│   └── protocol/                  # Canonical message schemas
├── firestore.rules
└── firebase.json
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| Xcode | 16+ |
| Swift | 5.9+ |
| Node.js | 22+ |
| Firebase CLI | `npm install -g firebase-tools` |
| Google Cloud CLI | [install guide](https://cloud.google.com/sdk/docs/install) |

---

## Quick Start — Local Dev (Firebase Emulator)

This path lets you run everything locally without a live Google Cloud account.

### 1. Start Firebase Emulators

```bash
cd backend/functions
npm install
npm run build
cd ../..
firebase emulators:start --only functions,firestore
```

The Functions emulator starts on `http://127.0.0.1:5001` and Firestore on port `8080`.

### 2. Start the Relay

```bash
cd infra/cloud-run-relay
npm install
node index.js
# Relay listens on ws://localhost:8080 by default; check index.js for the PORT env var
```

### 3. Run the Mac CLI

```bash
cd ios/GoVibeMacCli
export GOVIBE_API_BASE="http://127.0.0.1:5001/<your-project-id>/us-central1/api"
export GOVIBE_RELAY_WS_BASE="ws://localhost:8080/relay"
export GOVIBE_MAC_DEVICE_ID="my-mac"
swift run GoVibeMacCli
```

### 4. Run the iOS App

1. Copy the Firebase emulator config plist:
   ```bash
   cp ios/Config/GoogleService-Info.plist.template ios/Config/GoogleService-Info.plist
   # Edit the file and fill in your values (see "Self-Hosting" below)
   # Or point it at the local emulator — the emulator bypasses API key validation
   ```
2. Open `ios/GoVibe.xcworkspace` in Xcode.
3. Edit `ios/Config/Shared.xcconfig` and set:
   - `GOVIBE_GCP_REGION = us-central1`
   - `GOVIBE_GCP_PROJECT_ID = <project-id>`
   - `GOVIBE_GCP_RELAY_HOST = localhost:8080`
4. Run on Simulator. Available Mac sessions are discovered automatically from the relay.

---

## Self-Hosting (Production)

### Step 1: Create a Firebase Project

1. Go to [console.firebase.google.com](https://console.firebase.google.com) and create a new project.
2. Enable **Authentication** → Anonymous sign-in.
3. Enable **Firestore** in production mode.
4. Enable **Functions** (requires Blaze pay-as-you-go plan).

### Step 2: Configure the iOS App

1. In the Firebase Console, add an iOS app. Use whatever bundle ID you like.
2. Download `GoogleService-Info.plist` and place it at:
   ```
   ios/Config/GoogleService-Info.plist
   ```
   This file is gitignored — never commit it. See `ios/Config/GoogleService-Info.plist.template` for the expected shape.

### Step 3: Set Firebase Functions Secrets

```bash
firebase functions:secrets:set SESSION_TOKEN_SECRET
firebase functions:secrets:set TURN_SECRET
```

### Step 4: Deploy Firebase

```bash
firebase use <your-project-id>
firebase deploy --only functions,firestore
```

You'll need the Firebase project ID and region for iOS config (`GOVIBE_GCP_PROJECT_ID`, `GOVIBE_GCP_REGION`).

### Step 5: Deploy the Cloud Run Relay

```bash
cd infra/cloud-run-relay
gcloud run deploy govibe-relay \
  --source . \
  --region us-west1 \
  --allow-unauthenticated \
  --project <your-project-id>
```

Note the service URL printed at the end, then copy only its host into `GOVIBE_GCP_RELAY_HOST` (for example, from `https://abc-uw.a.run.app`, use `abc-uw.a.run.app`).

### Step 6: Run the Mac CLI

```bash
export GOVIBE_API_BASE="https://<region>-<project>.cloudfunctions.net/api"
export GOVIBE_RELAY_WS_BASE="wss://<service>.<region>.run.app/relay"
export GOVIBE_MAC_DEVICE_ID="my-mac"      # unique ID for this Mac
export GOVIBE_SHELL="/bin/zsh"            # optional; defaults to $SHELL
swift run --package-path ios/GoVibeMacCli GoVibeMacCli
```

### Step 7: Run the iOS App

Set these in `ios/Config/Shared.xcconfig`, then build and run on device:
- `GOVIBE_GCP_REGION = <region>` (for example, `us-west1`)
- `GOVIBE_GCP_PROJECT_ID = <your-project-id>`
- `GOVIBE_GCP_RELAY_HOST = <your-cloud-run-host>` (no scheme, no path)

The app assembles:
- API base: `https://<region>-<project>.cloudfunctions.net/api`
- Relay WS base: `wss://<relay-host>/relay`

The app discovers available Mac sessions automatically — no device ID needed.

---

## Configuration Reference

| Variable | Used by | Description |
|----------|---------|-------------|
| `GOVIBE_GCP_REGION` | iOS app | GCP region used to assemble Functions URL, e.g. `us-west1`. |
| `GOVIBE_GCP_PROJECT_ID` | iOS app | Firebase/GCP project ID used to assemble Functions URL. |
| `GOVIBE_GCP_RELAY_HOST` | iOS app | Cloud Run host only (no scheme/path), e.g. `govibe-relay-xxxxx-uw.a.run.app`. |
| `GOVIBE_MAC_DEVICE_ID` | Mac CLI only | Unique identifier for this Mac (used as the relay room name). iOS discovers available rooms automatically via the API. |
| `GOVIBE_SHELL` | Mac CLI only | Shell to launch inside the PTY (default: `$SHELL`) |
| `GOVIBE_API_BASE` | Mac CLI | Full API URL, e.g. `https://us-west1-<project>.cloudfunctions.net/api`. |
| `GOVIBE_RELAY_WS_BASE` | Mac CLI | Full Relay WS URL, e.g. `wss://<service>.<region>.run.app/relay`. |

For iOS, config comes from `ios/Config/Shared.xcconfig` and is embedded into the app Info.plist at build time. For Mac CLI, variables are shell environment variables.

In `.xcconfig`, avoid literal values like `https://...` because `//` starts a comment. Use the provided `$(GOVIBE_SCHEME_SEPARATOR)` helper.

The iOS app intentionally crashes at startup with a descriptive error if either value is empty or still set to its default `DUMMY_*` placeholder.

---

## API Endpoints

All endpoints are served from the Firebase Functions HTTPS app (`api` export).

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/session/create` | Create a new terminal session |
| `POST` | `/session/discover` | Discover active sessions for a device |
| `POST` | `/session/resume` | Resume an existing session |
| `POST` | `/session/close` | Close a session |

---

## Contributing

1. Fork the repo and create a branch.
2. Follow the local dev setup above.
3. Open a pull request with a clear description of the change.
4. Never commit `ios/Config/GoogleService-Info.plist` or any file containing API keys.
