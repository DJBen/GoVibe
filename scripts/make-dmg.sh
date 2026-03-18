#!/usr/bin/env bash
# make-dmg.sh — Package a .app bundle into a polished DMG with drag-to-install layout
# Usage: ./scripts/make-dmg.sh path/to/App.app output.dmg

set -euo pipefail

APP_PATH="${1:?Usage: $0 <App.app> <output.dmg>}"
OUTPUT_DMG="${2:?Usage: $0 <App.app> <output.dmg>}"

APP_NAME="$(basename "$APP_PATH" .app)"
STAGING_DIR="$(mktemp -d)/dmg-staging"
TEMP_DMG="${OUTPUT_DMG%.dmg}-temp.dmg"
VOLUME_NAME="$APP_NAME"

# Window layout constants
WIN_W=660
WIN_H=380
ICON_SIZE=128
APP_X=175
APP_Y=185
LINK_X=485
LINK_Y=185

echo "==> Staging: $STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "==> Copying $APP_PATH"
cp -R "$APP_PATH" "$STAGING_DIR/"

echo "==> Adding /Applications symlink"
ln -s /Applications "$STAGING_DIR/Applications"

VOLUME_SIZE="$(du -sm "$STAGING_DIR" | awk '{print $1 + 20}')m"

echo "==> Creating writable DMG (${VOLUME_SIZE})"
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size "$VOLUME_SIZE" \
    "$TEMP_DMG"

echo "==> Mounting DMG to configure layout"
MOUNT_OUTPUT="$(hdiutil attach -readwrite -noverify "$TEMP_DMG")"
MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/.*' | head -1)"

echo "==> Configuring Finder window via AppleScript"
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {400, 200, ${WIN_W} + 400, ${WIN_H} + 200}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to $ICON_SIZE
        set position of item "${APP_NAME}.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$LINK_X, $LINK_Y}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

echo "==> Detaching DMG"
hdiutil detach "$MOUNT_POINT" -quiet

echo "==> Converting to compressed UDZO DMG"
rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

echo "==> Cleaning up"
rm -f "$TEMP_DMG"
rm -rf "$(dirname "$STAGING_DIR")"

echo "==> Done: $OUTPUT_DMG"
