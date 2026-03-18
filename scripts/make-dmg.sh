#!/usr/bin/env bash
# make-dmg.sh — Package a .app bundle into a compressed DMG with an Applications symlink
# Usage: ./scripts/make-dmg.sh path/to/App.app output.dmg

set -euo pipefail

APP_PATH="${1:?Usage: $0 <App.app> <output.dmg>}"
OUTPUT_DMG="${2:?Usage: $0 <App.app> <output.dmg>}"

APP_NAME="$(basename "$APP_PATH" .app)"
STAGING_DIR="$(mktemp -d)/dmg-staging"
TEMP_DMG="${OUTPUT_DMG%.dmg}-temp.dmg"

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
    -volname "$APP_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,b=16" \
    -format UDRW \
    -size "$VOLUME_SIZE" \
    "$TEMP_DMG"

echo "==> Converting to compressed UDZO DMG"
rm -f "$OUTPUT_DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT_DMG"

echo "==> Cleaning up"
rm -f "$TEMP_DMG"
rm -rf "$(dirname "$STAGING_DIR")"

echo "==> Done: $OUTPUT_DMG"
