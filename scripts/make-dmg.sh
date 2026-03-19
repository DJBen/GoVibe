#!/usr/bin/env bash
# make-dmg.sh — Build a drag-to-install DMG using create-dmg
# Usage: ./scripts/make-dmg.sh path/to/App.app output.dmg
#
# Requires: create-dmg (brew install create-dmg)

set -euo pipefail

APP_PATH="${1:?Usage: $0 <App.app> <output.dmg>}"
OUTPUT_DMG="${2:?Usage: $0 <App.app> <output.dmg>}"

if ! command -v create-dmg &>/dev/null; then
    echo "Error: create-dmg not found. Install with: npm install --global create-dmg" >&2
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# create-dmg writes to a directory; capture the generated filename then rename
create-dmg "$APP_PATH" "$WORK_DIR"

GENERATED="$(find "$WORK_DIR" -name '*.dmg' | head -1)"
mv "$GENERATED" "$OUTPUT_DMG"
echo "==> Done: $OUTPUT_DMG"
