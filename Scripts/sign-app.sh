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
cp "$ROOT/Icons/faux_logo.png" "$STAGE/Contents/Resources/faux_logo.png"
cp "$ROOT/Icons/menubar.png" "$STAGE/Contents/Resources/menubar.png"
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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
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

echo "==> Building faux CLI ($BUILD_CONFIG)"
swift build -c "$BUILD_CONFIG" --product faux --package-path "$ROOT"
FAUX_BINARY="$(swift build -c "$BUILD_CONFIG" --product faux --package-path "$ROOT" --show-bin-path)/faux"
FAUX_CLI="$ROOT/dist/faux"
cp "$FAUX_BINARY" "$FAUX_CLI"
codesign --force --options runtime --entitlements "$ROOT/dist/FauxCam.entitlements" --sign "$IDENTITY" "$FAUX_CLI"
codesign --verify --strict "$FAUX_CLI"
echo "==> Signed faux CLI at $FAUX_CLI (hardened runtime + camera entitlement)"

if [[ "$IDENTITY" == "-" ]]; then
  cat <<'NOTE'

NOTE: ad-hoc signed (local use only — Gatekeeper will block it on other Macs).
To ship to production:
  1. Get a "Developer ID Application" certificate (paid Apple Developer account).
  2. Store notarization credentials once (app-specific password from appleid.apple.com):
       xcrun notarytool store-credentials fauxcam-notary \
         --apple-id you@example.com --team-id TEAMID --password app-specific-password
  3. Build + notarize + make a DMG in one shot:
       NOTARIZE_PROFILE=fauxcam-notary ./Scripts/sign-app.sh \
         "Developer ID Application: Your Name (TEAMID)"
NOTE
else
  echo "==> Distribution build with Developer ID"

  echo "==> Building DMG (app + faux CLI)"
  DMG="$ROOT/dist/FauxCam.dmg"
  DMG_STAGE="$ROOT/dist/.dmg-stage"
  rm -f "$DMG"; rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
  cp -R "$STAGE" "$DMG_STAGE/$APP_NAME"
  cp "$FAUX_CLI" "$DMG_STAGE/faux"
  ln -s /Applications "$DMG_STAGE/Applications"
  hdiutil create -volname "FauxCam" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$DMG_STAGE"
  echo "==> DMG at $DMG"

  if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
    # Notarize the DMG itself: notarytool inspects every nested Mach-O (the app,
    # its bundled libFaux.dylib, and the standalone faux CLI), so one submission
    # covers all distributed code. Staple both the DMG and the app so first launch
    # works offline.
    echo "==> Submitting the DMG for notarization (this contacts Apple and waits)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARIZE_PROFILE" --wait
    xcrun stapler staple "$STAGE"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$STAGE"
    xcrun stapler validate "$DMG"
    echo "==> Notarized + stapled (app, faux CLI, DMG)"
  else
    echo "NOTE: Developer ID signed but NOT notarized. Set NOTARIZE_PROFILE=<profile> to notarize the DMG."
  fi
fi
