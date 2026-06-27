#!/bin/bash
# Build, sign and package the FauxCam menu-bar app for distribution.
#
# This script handles the menu-bar app ONLY. The `faux` CLI is packaged
# separately by Scripts/package-cli.sh.
#
# Usage: ./Scripts/sign-app.sh [signing-identity]
#   signing-identity defaults to "-" (ad-hoc, local use only).
#   For distribution pass a Developer ID, e.g.:
#     ./Scripts/sign-app.sh "Developer ID Application: Your Name (TEAMID)"
#
# Outputs:
#   dist/FauxCam.app   the assembled, signed app bundle
#   dist/FauxCam.dmg   a modern disk image (app + Applications drop-link)
#   dist/FauxCam.zip   an app zip (ad-hoc path only, for convenience)
#
# Notarization runs only when NOTARIZE_PROFILE names a stored notarytool
# keychain profile AND a Developer ID identity is used. The app is notarized and
# stapled BEFORE the DMG is built, so the copy inside the DMG carries its ticket,
# then the DMG is notarized and stapled too.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:--}"
BUILD_CONFIG="release"
APP_NAME="FauxCam.app"
STAGE="$ROOT/dist/$APP_NAME"
DMG="$ROOT/dist/FauxCam.dmg"
APP_ZIP="$ROOT/dist/FauxCam.zip"
ENTITLEMENTS="$ROOT/dist/FauxCam.entitlements"
DMG_BACKGROUND="$ROOT/Assets/dmg/background.png"
VOLUME_NAME="FauxCam"

build_disk_image() {
  local dmg_path="$1"
  rm -f "$dmg_path"
  if command -v create-dmg >/dev/null 2>&1; then
    local source_dir="$ROOT/dist/.dmg-src"
    rm -rf "$source_dir"; mkdir -p "$source_dir"
    cp -R "$STAGE" "$source_dir/$APP_NAME"
    create-dmg \
      --volname "$VOLUME_NAME" \
      --background "$DMG_BACKGROUND" \
      --window-pos 200 120 \
      --window-size 540 380 \
      --icon-size 120 \
      --icon "$APP_NAME" 140 230 \
      --hide-extension "$APP_NAME" \
      --app-drop-link 400 230 \
      "$dmg_path" \
      "$source_dir" || true
    rm -rf "$source_dir"
    [ -f "$dmg_path" ] || { echo "ERROR: create-dmg did not produce $dmg_path"; exit 1; }
  else
    echo "NOTE: create-dmg not installed (brew install create-dmg) — using a plain hdiutil DMG."
    local stage_dir="$ROOT/dist/.dmg-stage"
    rm -rf "$stage_dir"; mkdir -p "$stage_dir"
    cp -R "$STAGE" "$stage_dir/$APP_NAME"
    ln -s /Applications "$stage_dir/Applications"
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$stage_dir" -ov -format UDZO "$dmg_path" >/dev/null
    rm -rf "$stage_dir"
  fi
  echo "==> DMG at $dmg_path"
}

notarize_and_staple() {
  local target="$1"
  echo "==> Submitting $(basename "$target") for notarization (contacts Apple and waits)"
  if [[ "$target" == *.app ]]; then
    local upload_zip="$ROOT/dist/.notarize-upload.zip"
    ditto -c -k --sequesterRsrc --keepParent "$target" "$upload_zip"
    xcrun notarytool submit "$upload_zip" --keychain-profile "$NOTARIZE_PROFILE" --wait
    rm -f "$upload_zip"
  else
    xcrun notarytool submit "$target" --keychain-profile "$NOTARIZE_PROFILE" --wait
  fi
  xcrun stapler staple "$target"
  xcrun stapler validate "$target"
}

echo "==> Building app icon + menubar glyph"
"$ROOT/Scripts/build-icons.sh"

echo "==> Building guest dylib"
"$ROOT/Scripts/build-dylib.sh"

if [ ! -s "$DMG_BACKGROUND" ]; then
  echo "==> Generating DMG background"
  swift "$ROOT/Scripts/make-dmg-background.swift"
fi

echo "==> Building FauxCamApp ($BUILD_CONFIG)"
swift build -c "$BUILD_CONFIG" --product FauxCamApp --package-path "$ROOT"
BINARY="$(swift build -c "$BUILD_CONFIG" --product FauxCamApp --package-path "$ROOT" --show-bin-path)/FauxCamApp"

echo "==> Assembling $APP_NAME bundle"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BINARY" "$STAGE/Contents/MacOS/FauxCam"
cp "$ROOT/dist/libFaux.dylib" "$STAGE/Contents/Resources/libFaux.dylib"
cp "$ROOT/dist/FauxCam.icns" "$STAGE/Contents/Resources/FauxCam.icns"
# Brand art (faux_logo + menubar glyph). Copy the PNGs DIRECTLY into Contents/Resources so the app
# loads them via Bundle.main (Brand resolves there first) — robust to how the building toolchain
# structures the SwiftPM resource bundle. Also copy the resource bundle itself for completeness.
cp "$ROOT/Modules/Presentation/Presentation/Resources/"*.png "$STAGE/Contents/Resources/"
BIN_DIR="$(dirname "$BINARY")"
cp -R "$BIN_DIR/FauxCam_Presentation.bundle" "$STAGE/Contents/Resources/FauxCam_Presentation.bundle"
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

cat > "$ENTITLEMENTS" <<'ENT'
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
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$STAGE"
codesign --verify --deep --strict "$STAGE"
codesign -d --entitlements - "$STAGE" 2>&1 | grep -q "device.camera" || { echo "ERROR: camera entitlement missing"; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$STAGE/Contents/Info.plist" >/dev/null
echo "==> Signed bundle at $STAGE (hardened runtime + camera entitlement)"

if [[ "$IDENTITY" == "-" ]]; then
  build_disk_image "$DMG"
  rm -f "$APP_ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$APP_ZIP"
  echo "==> App zip at $APP_ZIP"
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
  if [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
    notarize_and_staple "$STAGE"
    build_disk_image "$DMG"
    notarize_and_staple "$DMG"
    echo "==> Notarized + stapled (app, DMG)"
  else
    build_disk_image "$DMG"
    echo "NOTE: Developer ID signed but NOT notarized. Set NOTARIZE_PROFILE=<profile> to notarize."
  fi
fi
