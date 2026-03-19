# GoVibe

GoVibe is an open-source remote control system that lets you connect from an iPhone or iPad to live terminal and iOS Simulator sessions running on a Mac host app.

![GoVibe demo](https://raw.githubusercontent.com/DJBen/GoVibe/codex/media-assets/assets/govibe-demo.gif)


## Features


| Claude, Codex and Gemini on the go | View and control Simulator on the go |
| --- | --- |
| <img width="630" height="1368" alt="Screenshot 2026-03-16 at 4 39 13 PM" src="https://github.com/user-attachments/assets/95955b91-2427-4bbf-b4cf-a5d6053e2347" /> | <img width="630" height="1368" alt="Screenshot 2026-03-16 at 4 41 23 PM" src="https://github.com/user-attachments/assets/a8893684-9cf9-4539-b9a2-d54d316a402a" /> |

```
iOS App ──WebSocket──▶ Cloud Run Relay ◀──WebSocket── macOS Host App (GoVibeHost)
                              │
                    Firebase Auth + Functions

                          (control plane)
```

The iOS app connects to a WebSocket relay hosted on Google Cloud Run. The macOS host app connects to the same relay service and exposes hosted terminal and simulator sessions. Firebase provides anonymous auth and a lightweight session-management API. No credentials are stored in the repo.

---

## Repository Layout

```
GoVibe/
├── ios/
│   ├── GoVibe.xcworkspace         # Open this in Xcode
│   ├── GoVibe/                    # iOS app target (thin wrapper)
│   ├── GoVibeFeaturePackage/      # All shared Swift feature code
│   ├── GoVibeHostApp/             # macOS host app target
│   ├── GoVibeHostCorePackage/     # Shared host/runtime code
│   ├── Config/
│       ├── Debug.xcconfig
│       └── Release.xcconfig
│   ├── GoVibe/
│   │   ├── GoogleService-Info.plist.template   # Copy to GoogleService-Info.plist locally
│   │   └── GoogleService-Info.plist            # iOS Firebase config (gitignored)
│   └── GoVibeHostApp/
│       ├── GoogleService-Info.plist.template   # Copy to GoogleService-Info.plist locally
│       └── GoogleService-Info.plist            # macOS Firebase config (gitignored)
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

### 3. Run the macOS Host App

1. Copy `ios/GoVibeHostApp/GoogleService-Info.plist.template` to `ios/GoVibeHostApp/GoogleService-Info.plist`, then replace it with the real Firebase file for the macOS host target.
2. Open `ios/GoVibe.xcodeproj` or `ios/GoVibe.xcworkspace` in Xcode.
3. Build and run the `GoVibeHost` macOS target.
4. In the host onboarding flow:
   - confirm the generated Host ID
   - set the relay WebSocket URL to `ws://localhost:8080/relay`
   - grant Accessibility and Screen Recording
   - keep the default shell path unless you need a custom shell
5. After onboarding, create or start the terminal/simulator sessions you want to expose from the host dashboard.

### 4. Run the iOS App

1. Open `ios/GoVibe.xcworkspace` in Xcode.
2. Edit `ios/Config/Shared.xcconfig` and set:
   - `GOVIBE_GCP_REGION = us-central1`
   - `GOVIBE_GCP_PROJECT_ID = <project-id>`
   - `GOVIBE_GCP_RELAY_HOST = localhost:8080`
3. Run the iOS app.
4. Add your Mac host in the app using the Host ID shown by `GoVibeHost`.
5. Refresh sessions if needed. Available sessions are discovered automatically from the host control channel.

---

## Self-Hosting (Production)

### Step 1: Create a Firebase Project

1. Go to [console.firebase.google.com](https://console.firebase.google.com) and create a new project.
2. Enable **Authentication** → Anonymous sign-in.
3. Enable **Firestore** in production mode.
4. Enable **Functions** (requires Blaze pay-as-you-go plan).

### Step 2: Configure the iOS App

1. In the Firebase Console, add an iOS app. Use whatever bundle ID you like.
2. Copy `ios/GoVibe/GoogleService-Info.plist.template` to `ios/GoVibe/GoogleService-Info.plist`, then replace it with the real iOS `GoogleService-Info.plist`:
   ```
   ios/GoVibe/GoogleService-Info.plist
   ```
   This file is gitignored — never commit it.
3. Copy `ios/GoVibeHostApp/GoogleService-Info.plist.template` to `ios/GoVibeHostApp/GoogleService-Info.plist`, then replace it with the real macOS host `GoogleService-Info.plist`:
   ```
   ios/GoVibeHostApp/GoogleService-Info.plist
   ```
   This file is gitignored — never commit it.

### Step 3: Set Firebase Functions Secrets

```bash
firebase functions:secrets:set SESSION_TOKEN_SECRET
firebase functions:secrets:set TURN_SECRET
firebase functions:secrets:set RELAY_TOKEN_SECRET
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
  --set-env-vars RELAY_TOKEN_SECRET=<same-secret-as-functions> \
  --project <your-project-id>
```

Note the service URL printed at the end, then copy only its host into `GOVIBE_GCP_RELAY_HOST` (for example, from `https://abc-uw.a.run.app`, use `abc-uw.a.run.app`).

### Step 6: Run the macOS Host App

1. Open `ios/GoVibe.xcodeproj` or `ios/GoVibe.xcworkspace` in Xcode.
2. Build and run the `GoVibeHost` macOS target.
3. In the onboarding flow:
   - keep the generated Host ID or copy it for later pairing
   - set Relay to `wss://<your-cloud-run-host>/relay`
   - grant Accessibility and Screen Recording
   - optionally change the default shell path
4. Create the hosted terminal and/or simulator sessions you want this Mac to serve.

### Step 7: Run the iOS App

Set these in `ios/Config/Shared.xcconfig`, then build and run on device:
- `GOVIBE_GCP_REGION = <region>` (for example, `us-west1`)
- `GOVIBE_GCP_PROJECT_ID = <your-project-id>`
- `GOVIBE_GCP_RELAY_HOST = <your-cloud-run-host>` (no scheme, no path)

The app assembles:
- API base: `https://<region>-<project>.cloudfunctions.net/api`
- Relay WS base: `wss://<relay-host>/relay`

After signing in, add your Mac host using the Host ID shown in the macOS host app, then the app discovers and syncs available sessions automatically.

---

## Configuration Reference

| Variable | Used by | Description |
|----------|---------|-------------|
| `GOVIBE_GCP_REGION` | iOS app | GCP region used to assemble Functions URL, e.g. `us-west1`. |
| `GOVIBE_GCP_PROJECT_ID` | iOS app | Firebase/GCP project ID used to assemble Functions URL. |
| `GOVIBE_GCP_RELAY_HOST` | iOS app | Cloud Run host only (no scheme/path), e.g. `govibe-relay-xxxxx-uw.a.run.app`. |
| Host ID | macOS Host app | Generated locally by `GoVibeHost`; used by the iOS app to pair with a specific Mac. |
| Relay URL | macOS Host app | Full relay WebSocket URL, e.g. `wss://<service>.<region>.run.app/relay`, configured in host onboarding. |
| Shell Path | macOS Host app | Default shell launched for new terminal sessions on the host. |

For iOS, config comes from `ios/Config/Shared.xcconfig` and is embedded into the app Info.plist at build time. For the macOS host app, relay URL and default shell are configured in-app and stored locally on that Mac.

The iOS app intentionally crashes at startup with a descriptive error if any required `GOVIBE_GCP_*` value is empty or still set to a `DUMMY_*` placeholder.

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
4. Never commit `ios/GoVibe/GoogleService-Info.plist`, `ios/GoVibeHostApp/GoogleService-Info.plist`, or any file containing API keys.
