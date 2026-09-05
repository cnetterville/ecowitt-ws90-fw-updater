#!/bin/bash
# Builds, signs, notarizes, and packages the app for distribution outside
# the Mac App Store (GPL-licensed dfu-util rules out the App Store).
#
# One-time setup:
#   1. Install a "Developer ID Application" certificate in your keychain:
#      Xcode > Settings > Accounts > Manage Certificates > + > Developer ID
#      Application. (Requires Apple Developer Program membership.)
#   2. Store notarization credentials, using an app-specific password
#      created at https://appleid.apple.com:
#        xcrun notarytool store-credentials AC_NOTARY \
#          --apple-id you@example.com --team-id 88WW82MVFX
#
# Usage:
#   scripts/make-release.sh
#
# Environment overrides:
#   SIGNING_IDENTITY  (default: "Developer ID Application")
#   NOTARY_PROFILE    (default: "AC_NOTARY")
#
# The result in build/release/ — the notarized app zip plus the dfu-util
# and libusb source tarballs — should be uploaded together to the release
# page to satisfy the GPL source-distribution requirement.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Ecowitt WS90 FW Updater.xcodeproj"
SCHEME="Ecowitt WS90 FW Updater"
APP_NAME="Ecowitt WS90 FW Updater"
IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
RELEASE_DIR="$BUILD_DIR/release"
APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
ZIP="$RELEASE_DIR/$APP_NAME.zip"

rm -rf "$BUILD_DIR"
mkdir -p "$RELEASE_DIR"

echo "==> Archiving release build"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    archive -archivePath "$ARCHIVE" -quiet

echo "==> Signing bundled command-line tools with '$IDENTITY'"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/Resources/dfu-util" \
    "$APP/Contents/Resources/libusb-1.0.0.bin"

echo "==> Re-signing the app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "==> Verifying signature"
codesign --verify --strict --deep --verbose=2 "$APP"

echo "==> Submitting for notarization (waits for Apple to respond)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling the notarization ticket"
xcrun stapler staple "$APP"

echo "==> Packaging"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
cp "ThirdPartySources/dfu-util-0.11.tar.gz" \
   "ThirdPartySources/libusb-1.0.30.tar.bz2" \
   "$RELEASE_DIR/"

echo "==> Gatekeeper check"
spctl --assess --type execute --verbose=2 "$APP" || true

echo "==> Done. Upload everything in $RELEASE_DIR to your release page:"
ls -l "$RELEASE_DIR"
