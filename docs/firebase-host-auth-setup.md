# Firebase Host Auth Setup

This migration introduces the backend and iOS-side scaffolding for authenticated host discovery. Full Google sign-in still requires console setup plus app-side sign-in flows for both iOS and macOS.

## What You Need To Set Up

### 1. Firebase Project

In the Firebase console:

- Create or reuse a Firebase project.
- Enable Authentication.
- Enable Google as a sign-in provider.
- Enable Firestore.
- Enable Functions.

### 2. Google Sign-In App Registration

For iOS:

- Add an iOS app in Firebase for the `GoVibe` bundle identifier.
- Download `GoogleService-Info.plist`.
- Copy `ios/GoVibe/GoogleService-Info.plist.template` to `ios/GoVibe/GoogleService-Info.plist`.
- Place it at `ios/GoVibe/GoogleService-Info.plist`.
- Replace the copied template with the real Firebase file contents.

For macOS:

- Add a macOS or Apple-platform app in Firebase for the `GoVibeHost` bundle identifier.
- If you use a separate bundle ID from iOS, register it separately in Firebase.
- Download the matching config plist.
- Copy `ios/GoVibeHostApp/GoogleService-Info.plist.template` to `ios/GoVibeHostApp/GoogleService-Info.plist`.
- Place it at `ios/GoVibeHostApp/GoogleService-Info.plist`.
- Replace the copied template with the real Firebase file contents.

In Google Cloud console:

- Verify the OAuth consent screen is configured.
- Ensure the project has an OAuth client for the Apple platform app(s).

### 3. Xcode Project Configuration

You still need to add the app-side Google sign-in SDKs and URL handling:

- iOS app target:
  - Add Google Sign-In package/dependency.
  - Add URL types if required by the SDK version you choose.
  - Wire sign-in from the app shell instead of anonymous Firebase auth.

- macOS host target:
  - Add Firebase Auth and Google Sign-In dependencies to the host app.
  - Add a host-side auth controller.
  - Register the host device after sign-in using `POST /device/register`.

### 4. Backend Secrets And Deployment

The backend still requires the existing function secrets:

- `SESSION_TOKEN_SECRET`
- `TURN_SECRET`
- `RELAY_TOKEN_SECRET`

Deploy after updating functions:

```bash
cd backend/functions
npm install
npm run build
cd ../..
firebase deploy --only functions,firestore
```

The Cloud Run relay must receive the same `RELAY_TOKEN_SECRET` value as Functions.

### 5. Relay Security Follow-Up

Host discovery and relay token enforcement are both now expected parts of the production setup.

## What This Branch Already Adds

- `POST /device/register`
- `POST /device/heartbeat`
- `POST /hosts/discover`
- Firestore device schema support for host metadata
- iOS client models and store merging for discovered hosts

## Recommended Next Implementation Steps

1. Replace iOS anonymous auth with Google sign-in.
2. Add macOS Google/Firebase sign-in.
3. Register the macOS host on sign-in and heartbeat periodically.
4. Update the iOS host picker UI to prefer discovered hosts over manual host entry.
5. Lock down the relay with signed join tokens.
