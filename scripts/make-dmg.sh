#!/usr/bin/env bash
# make-dmg.sh — Package a .app bundle into a polished DMG with drag-to-install layout
# Usage: ./scripts/make-dmg.sh path/to/App.app output.dmg [path/to/background.png]

set -euo pipefail

APP_PATH="${1:?Usage: $0 <App.app> <output.dmg> [background.png]}"
OUTPUT_DMG="${2:?Usage: $0 <App.app> <output.dmg> [background.png]}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BG_IMAGE="${3:-$SCRIPT_DIR/../assets/dmg-background.png}"

APP_NAME="$(basename "$APP_PATH" .app)"
STAGING_DIR="$(mktemp -d)/dmg-staging"
TEMP_DMG="${OUTPUT_DMG%.dmg}-temp.dmg"
rm -f "$TEMP_DMG"

# Window layout — 660×380 matches background aspect ratio (2720×1568)
WIN_W=660
WIN_H=380
ICON_SIZE=128
APP_X=165
APP_Y=185
LINK_X=495
LINK_Y=185

echo "==> Staging: $STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo "==> Copying $APP_PATH"
cp -R "$APP_PATH" "$STAGING_DIR/"

HAS_BG=false
if [[ -f "$BG_IMAGE" ]]; then
    echo "==> Staging background image"
    mkdir -p "$STAGING_DIR/.background"
    cp "$BG_IMAGE" "$STAGING_DIR/.background/background.png"
    HAS_BG=true
else
    echo "==> Warning: background not found at $BG_IMAGE, skipping"
fi

VOLUME_SIZE="$(du -sm "$STAGING_DIR" | awk '{print $1 + 20}')m"

echo "==> Creating writable DMG (${VOLUME_SIZE})"
hdiutil create \
    -srcfolder "$STAGING_DIR" \
    -volname "$APP_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size "$VOLUME_SIZE" \
    "$TEMP_DMG"

echo "==> Mounting DMG"
MOUNT_OUTPUT="$(hdiutil attach -readwrite -noverify "$TEMP_DMG")"
MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | grep -o '/Volumes/.*' | head -1)"
DISK_NAME="$(basename "$MOUNT_POINT")"
echo "    Mounted at: $MOUNT_POINT (disk: $DISK_NAME)"

echo "==> Creating Finder alias to /Applications"
osascript -e \
    "tell application \"Finder\" to make alias file to POSIX file \"/Applications\" at POSIX file \"$MOUNT_POINT\""

echo "==> Configuring Finder window layout"
# Pass BG path as empty string when not used; AppleScript checks length
BG_PATH="$( [[ "$HAS_BG" == "true" ]] && echo "$MOUNT_POINT/.background/background.png" || echo "" )"

osascript - "$DISK_NAME" "$APP_NAME" "$BG_PATH" \
           "$WIN_W" "$WIN_H" "$ICON_SIZE" \
           "$APP_X" "$APP_Y" "$LINK_X" "$LINK_Y" <<'APPLESCRIPT'
on run argv
    set diskName to item 1 of argv
    set appName  to item 2 of argv
    set bgPath   to item 3 of argv
    set winW     to (item 4 of argv) as integer
    set winH     to (item 5 of argv) as integer
    set iconSz   to (item 6 of argv) as integer
    set appX     to (item 7 of argv) as integer
    set appY     to (item 8 of argv) as integer
    set linkX    to (item 9 of argv) as integer
    set linkY    to (item 10 of argv) as integer

    tell application "Finder"
        tell disk diskName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {400, 200, winW + 400, winH + 200}
            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to iconSz
            set text size of opts to 13
            set shows icon preview of opts to true
            if length of bgPath > 0 then
                set background picture of opts to POSIX file bgPath
            end if
            update without registering applications
            delay 1
            set position of item (appName & ".app") of container window to {appX, appY}
            set position of item "Applications" of container window to {linkX, linkY}
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

# Hide .background so it doesn't appear as an icon in the window
if [[ "$HAS_BG" == "true" ]]; then
    SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || \
        chflags hidden "$MOUNT_POINT/.background"
fi

echo "==> Detaching DMG"
hdiutil detach "$MOUNT_POINT" -quiet

echo "==> Converting to compressed UDZO DMG"
rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

echo "==> Cleaning up"
rm -f "$TEMP_DMG"
rm -rf "$(dirname "$STAGING_DIR")"

echo "==> Done: $OUTPUT_DMG"
