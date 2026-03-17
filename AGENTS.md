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

Notes:
- Use `GoVibeHost` for the macOS host target.
- Use `GoVibe` for the iOS app target.
- Avoid raw `xcodebuild` unless `xcodebuildmcp` is unavailable.
- A currently available simulator in this workspace was `iPhone Air` with UDID `447AD785-B30D-4A47-8F57-B0E6FC5AEA70` on March 17, 2026, but prefer `xcodebuildmcp simulator list` instead of hardcoding it.
