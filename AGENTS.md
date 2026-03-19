# GoVibe Agent Notes

## Canonical Builds

Use `xcodebuildmcp` for all app builds in this repository. Prefer the project at `ios/GoVibe.xcodeproj`.

### macOS host app

Build the macOS host app with the `GoVibeHost` scheme:

```bash
xcodebuildmcp macos build \
  --project-path ./ios/GoVibe.xcodeproj \
  --scheme GoVibeHost
```

Build and run the macOS host app:

```bash
xcodebuildmcp macos build-and-run \
  --project-path ./ios/GoVibe.xcodeproj \
  --scheme GoVibeHost
```

### iOS app

List available simulators first if needed:

```bash
xcodebuildmcp simulator list
```

Build the iOS app with the `GoVibe` scheme for a simulator:

```bash
xcodebuildmcp simulator build \
  --project-path ./ios/GoVibe.xcodeproj \
  --scheme GoVibe \
  --simulator-id <SIMULATOR_UDID>
```

Build and run the iOS app on a simulator:

```bash
xcodebuildmcp simulator build-and-run \
  --project-path ./ios/GoVibe.xcodeproj \
  --scheme GoVibe \
  --simulator-id <SIMULATOR_UDID>
```

## Releasing GoVibe Host (macOS)

Releases are triggered by pushing a tag matching `host/v*` to the `main` branch (or any branch). The GitHub Actions workflow at `.github/workflows/release-host.yml` will:

1. Build and archive the `GoVibeHost` scheme with Developer ID signing
2. Package it into a DMG via `scripts/make-dmg.sh` (uses `create-dmg`, installed via `npm install --global create-dmg`)
3. Notarize and staple the DMG with Apple's notary service
4. Upload the DMG to GCS bucket `govibe-host-releases` and update `latest.json`
5. Deploy the download landing page to Firebase Hosting
6. Create a GitHub Release with the DMG attached

### Bump version and trigger a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `ios/Config/HostRelease.xcconfig`
2. Commit and push the change
3. Tag and push:

```bash
git tag host/v<VERSION>
git push origin host/v<VERSION>
```

Example for `0.1.1`:

```bash
git tag host/v0.1.1
git push origin host/v0.1.1
```

Watch the pipeline: https://github.com/DJBen/GoVibe/actions

### Local DMG test

```bash
brew install npm  # if needed
npm install --global create-dmg
./scripts/make-dmg.sh /path/to/GoVibeHost.app ~/Desktop/GoVibeHost-test.dmg
```

---

Notes:
- Use `GoVibeHost` for the macOS host target.
- Use `GoVibe` for the iOS app target.
- Avoid raw `xcodebuild` unless `xcodebuildmcp` is unavailable.
- A currently available simulator in this workspace was `iPhone Air` with UDID `447AD785-B30D-4A47-8F57-B0E6FC5AEA70` on March 17, 2026, but prefer `xcodebuildmcp simulator list` instead of hardcoding it.
