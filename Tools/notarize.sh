#!/bin/zsh
# Builds Markdown Reader signed with your Developer ID, notarizes it with
# Apple and staples the ticket, so it opens on any Mac without Gatekeeper
# warnings.
#
# One-time setup (needs an Apple Developer account):
#   1. Install your "Developer ID Application" certificate in the keychain.
#   2. Store notarization credentials in the keychain:
#        xcrun notarytool store-credentials MarkdownReaderNotary \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific password>
#
# Usage:
#   TEAM_ID=ABCDE12345 ./Tools/notarize.sh [Release|Release-Sandboxed]
#
# Optional environment variables:
#   SIGN_IDENTITY   default: "Developer ID Application"
#   NOTARY_PROFILE  default: MarkdownReaderNotary
#   BUNDLE_ID       default: com.local.MarkdownReader (use your own reverse-DNS id)
set -euo pipefail

CONFIGURATION="${1:-Release}"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-MarkdownReaderNotary}"
BUNDLE_ID="${BUNDLE_ID:-com.local.MarkdownReader}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/notarize"
APP="$BUILD/DerivedData/Build/Products/$CONFIGURATION/Markdown Reader.app"
ZIP="$BUILD/Markdown-Reader-$CONFIGURATION.zip"

echo "==> Building $CONFIGURATION signed with \"$SIGN_IDENTITY\" (team $TEAM_ID)"
xcodebuild -project "$ROOT/MarkdownReader.xcodeproj" -scheme MarkdownReader \
  -configuration "$CONFIGURATION" -derivedDataPath "$BUILD/DerivedData" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO clean build

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Submitting for notarization (this can take a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the ticket"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"
echo "Done: $APP"
echo "      $ZIP"
