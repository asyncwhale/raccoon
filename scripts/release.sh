#!/usr/bin/env bash
# release.sh — Raccoon one-command Developer ID release pipeline
#
# Usage: ./scripts/release.sh [VERSION]
#   VERSION  Marketing version string, e.g. 0.1.0
#            Defaults to MARKETING_VERSION from project.yml if not supplied.
#
# Prerequisites (everything else is already wired up):
#   - A Developer ID Application cert installed in your login keychain.
#     Provide its identity + team via environment variables (see below) so no
#     personal name is hard-coded in this script:
#       export RACCOON_SIGNING_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)"
#       export RACCOON_TEAM_ID="TEAMID"
#       export RACCOON_NOTARY_PROFILE="your-notarytool-keychain-profile"
#     → Create the cert at https://developer.apple.com/account/resources/certificates/list
#       and store a notary profile with `xcrun notarytool store-credentials`.
#   - XcodeGen installed: brew install xcodegen
#   (DMG is created with hdiutil — no extra tooling required)
#
# Signing/notarization is OPTIONAL. If RACCOON_SIGNING_IDENTITY is unset, this
# script still builds an unsigned .app/.dmg you can run via right-click → Open.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Environment
# ---------------------------------------------------------------------------
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_IDENTITY="${RACCOON_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${RACCOON_NOTARY_PROFILE:-raccoon-notary}"
TEAM_ID="${RACCOON_TEAM_ID:-}"
SCHEME="Raccoon"
PROJECT="$REPO_ROOT/Raccoon.xcodeproj"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Raccoon.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
EXPORT_PLIST="$REPO_ROOT/scripts/ExportOptions.plist"

# ---------------------------------------------------------------------------
# 1. Resolve version
# ---------------------------------------------------------------------------
if [[ $# -ge 1 && -n "$1" ]]; then
    VERSION="$1"
else
    VERSION=$(grep 'MARKETING_VERSION' "$REPO_ROOT/project.yml" | head -1 | awk '{print $2}' | tr -d '"')
fi

if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not determine version. Pass it as an argument: $0 0.1.0" >&2
    exit 1
fi

DMG_NAME="Raccoon-${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/${DMG_NAME}"

echo "==> Raccoon release pipeline — version ${VERSION}"
echo ""

# ---------------------------------------------------------------------------
# 2. Pre-flight checks
# ---------------------------------------------------------------------------
echo "==> [Pre-flight] Checking signing identity..."
if ! security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    echo ""
    echo "ERROR: Signing identity not found in keychain:" >&2
    echo "  \"$SIGNING_IDENTITY\"" >&2
    echo "" >&2
    echo "To fix: create a Developer ID Application certificate at" >&2
    echo "  https://developer.apple.com/account/resources/certificates/list" >&2
    echo "then download and double-click it to install into your login keychain." >&2
    exit 1
fi
echo "       Found: $SIGNING_IDENTITY"

echo "==> [Pre-flight] Checking notary keychain profile..."
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    echo ""
    echo "ERROR: Notary keychain profile \"$NOTARY_PROFILE\" not found." >&2
    echo "" >&2
    echo "To fix, run:" >&2
    echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\" >&2
    echo "      --apple-id YOUR_APPLE_ID \\" >&2
    echo "      --team-id $TEAM_ID" >&2
    exit 1
fi
echo "       Profile \"$NOTARY_PROFILE\" OK"

echo ""

# ---------------------------------------------------------------------------
# 3. Clean build directory
# ---------------------------------------------------------------------------
echo "==> [1/8] Cleaning build/ ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 4. Generate Xcode project
# ---------------------------------------------------------------------------
echo "==> [2/8] Generating Xcode project (xcodegen) ..."
cd "$REPO_ROOT"
xcodegen generate

# ---------------------------------------------------------------------------
# 5. Build (Release, UNSIGNED). We sign manually below. Forcing Developer ID
#    signing during `xcodebuild archive` breaks SPM resource bundles
#    (KeyboardShortcuts_KeyboardShortcuts.bundle / GRDB_GRDB.bundle), so we
#    build unsigned and then codesign inner-out — Apple's recommended approach.
# ---------------------------------------------------------------------------
echo "==> [3/8] Building (Release, unsigned) ..."
cd "$REPO_ROOT"
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    build \
    CODE_SIGNING_ALLOWED=NO \
    | grep -E '^(==>|Build|error:|warning: )' || true

BUILT_APP="$BUILD_DIR/dd/Build/Products/Release/Raccoon.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "ERROR: build product not found at $BUILT_APP" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Sign with Developer ID (inner-out), hardened runtime, secure timestamp
# ---------------------------------------------------------------------------
echo "==> [4/8] Signing (Developer ID, hardened runtime) ..."
mkdir -p "$EXPORT_PATH"
rm -rf "$EXPORT_PATH/Raccoon.app"
cp -R "$BUILT_APP" "$EXPORT_PATH/Raccoon.app"
APP_PATH="$EXPORT_PATH/Raccoon.app"

# Sign nested code first (deepest-first via -depth), then the app bundle last.
while IFS= read -r item; do
    echo "       sign nested: ${item#"$APP_PATH"/}"
    codesign --force --options runtime --timestamp -s "$SIGNING_IDENTITY" "$item"
done < <(find "$APP_PATH/Contents" \( -name '*.bundle' -o -name '*.framework' -o -name '*.dylib' \) -depth 2>/dev/null)

codesign --force --options runtime --timestamp -s "$SIGNING_IDENTITY" "$APP_PATH"
echo "       Signed: $APP_PATH"

# ---------------------------------------------------------------------------
# 7. Verify signature
# ---------------------------------------------------------------------------
echo "==> [5/8] Verifying code signature ..."
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
/usr/bin/codesign -dvvv "$APP_PATH"
echo ""
echo "==> [5/8] Gatekeeper spctl check (will show 'rejected' until notarization — expected) ..."
spctl -a -vvv -t exec "$APP_PATH" || true   # non-fatal before staple
echo ""

# ---------------------------------------------------------------------------
# 8. Create DMG (headless hdiutil — no Finder/AppleScript dependency)
# ---------------------------------------------------------------------------
echo "==> [6/8] Creating DMG: $DMG_NAME ..."
STAGE="$BUILD_DIR/dmgstage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/Raccoon.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "Raccoon ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
echo "       DMG: $DMG_PATH"

# ---------------------------------------------------------------------------
# 9. Notarize + staple
# ---------------------------------------------------------------------------
echo "==> [7/8] Submitting to Apple notary service (this can take 1–5 minutes) ..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
echo "       Notarization complete."

echo "==> [7/8] Stapling notarization ticket ..."
xcrun stapler staple "$DMG_PATH"
echo "       Stapled."

# Verify notarization ticket is correctly stapled
echo "==> [7/8] Gatekeeper check after staple ..."
xcrun stapler validate "$DMG_PATH"
echo ""

# ---------------------------------------------------------------------------
# 10. Report
# ---------------------------------------------------------------------------
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> [8/8] Release artifact ready"
echo ""
echo "   DMG path : $DMG_PATH"
echo "   SHA-256  : $SHA256"
echo ""
echo "   Next steps:"
echo "   1. Upload $DMG_NAME to GitHub Releases as tag v${VERSION}"
echo "   2. Update Casks/raccoon.rb — replace PLACEHOLDER_SHA256 with:"
echo "      $SHA256"
echo "   3. Push the cask update to asyncwhale/homebrew-tap"
echo ""
echo "   Done. Ship it. 🦝"
