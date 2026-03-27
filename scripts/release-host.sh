#!/usr/bin/env bash
# release-host.sh — Build, sign, notarize, and release GoVibe Host locally
#
# Usage: ./scripts/release-host.sh <version>
#   e.g. ./scripts/release-host.sh 0.2.0
#
# Prerequisites:
#   - Developer ID certificate in keychain
#   - "GoVibe Host" provisioning profile installed
#   - gcloud authenticated (gcloud auth login)
#   - firebase CLI authenticated (firebase login)
#   - gh CLI authenticated (gh auth login)
#   - create-dmg installed (brew install create-dmg)
#   - App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8

set -euo pipefail

# ── Load .env if present ────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_ROOT/.env" ]]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# ── Config ──────────────────────────────────────────────────────────────────
VERSION="${1:?Usage: $0 <version>}"
PROJECT="$REPO_ROOT/ios/GoVibe.xcodeproj"
SCHEME="GoVibeHost"
BUILD_DIR="$(mktemp -d)"
ARCHIVE_PATH="$BUILD_DIR/GoVibeHost.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_NAME="GoVibeHost-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
GCS_BUCKET="gs://govibe-host-releases"
TAG="host/v${VERSION}"

trap 'rm -rf "$BUILD_DIR"' EXIT

# ── ASC API key (for notarization) ──────────────────────────────────────────
ASC_KEY_ID="${ASC_KEY_ID:-}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-}"
ASC_KEY_PATH="${ASC_KEY_PATH:-}"

if [[ -z "$ASC_KEY_ID" ]]; then
    # Auto-detect from ~/.appstoreconnect/private_keys/
    KEY_FILE="$(find ~/.appstoreconnect/private_keys -name 'AuthKey_*.p8' 2>/dev/null | head -1)"
    if [[ -n "$KEY_FILE" ]]; then
        ASC_KEY_ID="$(basename "$KEY_FILE" | sed 's/AuthKey_//;s/\.p8//')"
        ASC_KEY_PATH="$KEY_FILE"
        echo "==> Auto-detected ASC key: $ASC_KEY_ID"
    else
        echo "Error: Set ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH or place key in ~/.appstoreconnect/private_keys/" >&2
        exit 1
    fi
fi

if [[ -z "$ASC_ISSUER_ID" ]]; then
    echo "Error: ASC_ISSUER_ID must be set" >&2
    exit 1
fi

if [[ -z "$ASC_KEY_PATH" ]]; then
    ASC_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
fi

if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "Error: ASC key not found at $ASC_KEY_PATH" >&2
    exit 1
fi

echo "==> Releasing GoVibe Host v${VERSION}"
echo "    Build dir: $BUILD_DIR"

# ── Stamp version in xcconfig ──────────────────────────────────────────────
XCCONFIG_LOCAL="$REPO_ROOT/ios/Config/Shared.xcconfig.local"
CURRENT_PROJECT_VERSION="$(date +%Y%m%d%H%M)"

if [[ -f "$XCCONFIG_LOCAL" ]]; then
    if grep -q "^MARKETING_VERSION" "$XCCONFIG_LOCAL"; then
        sed -i '' "s/^MARKETING_VERSION.*/MARKETING_VERSION = ${VERSION}/" "$XCCONFIG_LOCAL"
    else
        echo "MARKETING_VERSION = ${VERSION}" >> "$XCCONFIG_LOCAL"
    fi
    if grep -q "^CURRENT_PROJECT_VERSION" "$XCCONFIG_LOCAL"; then
        sed -i '' "s/^CURRENT_PROJECT_VERSION.*/CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}/" "$XCCONFIG_LOCAL"
    else
        echo "CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}" >> "$XCCONFIG_LOCAL"
    fi
else
    echo "Error: $XCCONFIG_LOCAL not found — create it with your local config" >&2
    exit 1
fi

# Also update HostRelease.xcconfig and Shared.xcconfig so checked-in values stay current
XCCONFIG_RELEASE="$REPO_ROOT/ios/Config/HostRelease.xcconfig"
sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${VERSION}/" "$XCCONFIG_RELEASE"
sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}/" "$XCCONFIG_RELEASE"

XCCONFIG_SHARED="$REPO_ROOT/ios/Config/Shared.xcconfig"
sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${VERSION}/" "$XCCONFIG_SHARED"
sed -i '' "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}/" "$XCCONFIG_SHARED"

echo "==> Stamped MARKETING_VERSION = ${VERSION}, CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}"

# ── Archive ─────────────────────────────────────────────────────────────────
echo "==> Archiving..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    | tail -5

# ── Export ──────────────────────────────────────────────────────────────────
echo "==> Exporting Developer ID app..."
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$REPO_ROOT/ios/ExportOptions.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    | tail -5

APP_PATH="$(find "$EXPORT_PATH" -name '*.app' | head -1)"
echo "    App: $APP_PATH"

# ── DMG ─────────────────────────────────────────────────────────────────────
echo "==> Building DMG..."
"$REPO_ROOT/scripts/make-dmg.sh" "$APP_PATH" "$DMG_PATH"

# ── Notarize ────────────────────────────────────────────────────────────────
echo "==> Notarizing..."
OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
    --key "$ASC_KEY_PATH" \
    --key-id "$ASC_KEY_ID" \
    --issuer "$ASC_ISSUER_ID" \
    --wait 2>&1) || true
echo "$OUTPUT"

SUBMISSION_ID=$(echo "$OUTPUT" | grep 'id:' | head -1 | awk '{print $2}')

if echo "$OUTPUT" | grep -q "status: Invalid"; then
    echo "--- Notarization rejected. Fetching log ---"
    xcrun notarytool log "$SUBMISSION_ID" \
        --key "$ASC_KEY_PATH" \
        --key-id "$ASC_KEY_ID" \
        --issuer "$ASC_ISSUER_ID" || true
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "status: Accepted"; then
    echo "Unexpected notarization status"
    exit 1
fi

# ── Staple ──────────────────────────────────────────────────────────────────
echo "==> Stapling..."
for i in 1 2 3 4 5; do
    if xcrun stapler staple "$DMG_PATH"; then
        xcrun stapler validate "$DMG_PATH"
        break
    fi
    echo "    Attempt $i failed, retrying in 15s..."
    sleep 15
    if [[ $i -eq 5 ]]; then
        echo "Stapling failed after 5 attempts"
        exit 1
    fi
done

# ── Checksum ────────────────────────────────────────────────────────────────
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "==> SHA-256: $SHA256"

# ── Sparkle EdDSA signature ────────────────────────────────────────────────
echo "==> Signing DMG for Sparkle..."
SIGN_UPDATE="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)"
if [[ -z "$SIGN_UPDATE" ]]; then
    SIGN_UPDATE="$(find "$REPO_ROOT/ios/.build/checkouts" \
        -path "*/Sparkle/bin/sign_update" -type f 2>/dev/null | head -1)"
fi
if [[ -z "$SIGN_UPDATE" ]]; then
    echo "Error: Sparkle sign_update not found. Build the project first to resolve Sparkle SPM." >&2
    exit 1
fi

SPARKLE_SIG=$("$SIGN_UPDATE" "$DMG_PATH")
ED_SIGNATURE=$(echo "$SPARKLE_SIG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
ED_LENGTH=$(echo "$SPARKLE_SIG" | sed -n 's/.*length="\([^"]*\)".*/\1/p')
echo "    EdDSA signature obtained"

# ── Upload to GCS ───────────────────────────────────────────────────────────
echo "==> Uploading DMG to GCS..."
gsutil cp "$DMG_PATH" "${GCS_BUCKET}/${DMG_NAME}"

RELEASE_DATE="$(date -u +%Y-%m-%d)"
DMG_URL="https://storage.googleapis.com/govibe-host-releases/${DMG_NAME}"

cat > "$BUILD_DIR/latest.json" <<EOF
{
  "version": "${VERSION}",
  "dmgUrl": "${DMG_URL}",
  "sha256": "${SHA256}",
  "releaseDate": "${RELEASE_DATE}",
  "minMacOS": "15.0"
}
EOF

gsutil -h "Cache-Control:no-cache, no-store" \
    cp "$BUILD_DIR/latest.json" "${GCS_BUCKET}/latest.json"

# ── Sparkle appcast ────────────────────────────────────────────────────────
echo "==> Generating appcast.xml..."
cat > "$BUILD_DIR/appcast.xml" <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>GoVibe Host Updates</title>
    <language>en</language>
    <item>
      <title>GoVibe Host v${VERSION}</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>${CURRENT_PROJECT_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <enclosure url="${DMG_URL}"
                 type="application/octet-stream"
                 sparkle:edSignature="${ED_SIGNATURE}"
                 length="${ED_LENGTH}" />
    </item>
  </channel>
</rss>
APPCAST_EOF

gsutil -h "Cache-Control:no-cache, no-store" \
    cp "$BUILD_DIR/appcast.xml" "${GCS_BUCKET}/appcast.xml"

echo "==> Uploaded to GCS"

# ── Firebase Hosting ────────────────────────────────────────────────────────
echo "==> Deploying web to Firebase Hosting..."
(cd "$REPO_ROOT" && firebase deploy --only hosting)

# ── Git tag + GitHub Release ────────────────────────────────────────────────
echo "==> Creating git tag ${TAG}..."
# Delete existing tag if re-releasing same version
git tag -d "$TAG" 2>/dev/null || true
git push origin ":refs/tags/$TAG" 2>/dev/null || true
git tag "$TAG"
git push origin "$TAG"

echo "==> Creating GitHub Release..."
# Copy DMG to a non-temp location for gh release (temp dir cleaned on exit)
RELEASE_DMG="/tmp/$DMG_NAME"
cp "$DMG_PATH" "$RELEASE_DMG"

# Delete existing release if re-releasing
gh release delete "$TAG" --yes 2>/dev/null || true

gh release create "$TAG" "$RELEASE_DMG" \
    --title "GoVibe Host v${VERSION}" \
    --notes "$(cat <<EOF
## GoVibe Host v${VERSION}

**SHA-256:** \`${SHA256}\`

### Requirements
- macOS 15.0 Sequoia or later
- Apple Silicon or Intel Mac

Download and drag **GoVibe Host.app** to your Applications folder.
EOF
)"

rm -f "$RELEASE_DMG"

echo ""
echo "==> Release complete!"
echo "    Version:  ${VERSION}"
echo "    Tag:      ${TAG}"
echo "    DMG:      ${DMG_URL}"
echo "    SHA-256:  ${SHA256}"
