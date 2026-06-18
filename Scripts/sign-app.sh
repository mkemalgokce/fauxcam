#!/bin/bash
# Build and code-sign the FauxCam menubar app for distribution.
#
# Usage: ./Scripts/sign-app.sh [signing-identity]
#   signing-identity defaults to "-" (ad-hoc, local use only).
#   For distribution pass a Developer ID, e.g.:
#     ./Scripts/sign-app.sh "Developer ID Application: Your Name (TEAMID)"
#
# Notarization (requires a Developer ID + an App Store Connect API key or
# app-specific password) is documented at the end of this script; it is not
# performed automatically because it needs network access and credentials.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:--}"
BUILD_CONFIG="release"
APP_NAME="FauxCam.app"
STAGE="$ROOT/dist/$APP_NAME"

echo "==> Building app icon + menubar glyph"
"$ROOT/Scripts/build-icons.sh"

echo "==> Building guest dylib"
"$ROOT/Scripts/build-dylib.sh"

echo "==> Building FauxCamApp ($BUILD_CONFIG)"
swift build -c "$BUILD_CONFIG" --product FauxCamApp --package-path "$ROOT"
BINARY="$(swift build -c "$BUILD_CONFIG" --product FauxCamApp --package-path "$ROOT" --show-bin-path)/FauxCamApp"

echo "==> Assembling $APP_NAME bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/FauxCam"
cp "$ROOT/dist/libFaux.dylib" "$STAGE/Contents/Resources/libFaux.dylib"
cp "$ROOT/Icons/FauxCam.icns" "$STAGE/Contents/Resources/FauxCam.icns"
cp "$ROOT/Icons/appicon.png" "$STAGE/Contents/Resources/appicon.png"
cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FauxCam</string>
  <key>CFBundleDisplayName</key><string>FauxCam</string>
  <key>CFBundleIdentifier</key><string>com.fauxcam.app</string>
  <key>CFBundleExecutable</key><string>FauxCam</string>
  <key>CFBundleIconFile</key><string>FauxCam</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>FauxCam previews your camera and streams it as a fake camera into the iOS Simulator.</string>
</dict>
</plist>
PLIST

cat > "$ROOT/dist/FauxCam.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
ENT

echo "==> Code-signing with identity: $IDENTITY"
xattr -cr "$STAGE"
codesign --force --options runtime --sign "$IDENTITY" "$STAGE/Contents/Resources/libFaux.dylib"
codesign --force --options runtime --entitlements "$ROOT/dist/FauxCam.entitlements" --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"
codesign -d --entitlements - "$STAGE" 2>&1 | grep -q "device.camera" || { echo "ERROR: camera entitlement missing"; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$STAGE/Contents/Info.plist" >/dev/null
echo "==> Signed bundle at $STAGE (hardened runtime + camera entitlement)"

if [[ "$IDENTITY" == "-" ]]; then
  cat <<'NOTE'

NOTE: ad-hoc signed (local use only). To notarize for distribution, re-run with a
Developer ID, then:

  ditto -c -k --keepParent dist/FauxCam.app dist/FauxCam.zip
  xcrun notarytool submit dist/FauxCam.zip --keychain-profile <profile> --wait
  xcrun stapler staple dist/FauxCam.app
NOTE
fi
