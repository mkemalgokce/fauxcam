#!/bin/bash
# Build the FauxCam app icon (dist/FauxCam.icns) from the brand artwork
# Modules/Presentation/Presentation/Resources/faux_logo.png — the single source of
# truth for FauxCam artwork (also shipped to the running app via Bundle.module).
#
# Requires: iconutil + sips (Xcode Command Line Tools).
# Output: dist/FauxCam.icns (a build artifact). sign-app.sh copies it into the
# app bundle's Resources and references it from Info.plist (CFBundleIconFile).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PNG="$ROOT/Modules/Presentation/Presentation/Resources/faux_logo.png"
DIST="$ROOT/dist"

command -v iconutil >/dev/null || { echo "ERROR: iconutil missing (install Xcode Command Line Tools)"; exit 1; }
command -v sips >/dev/null || { echo "ERROR: sips missing (install Xcode Command Line Tools)"; exit 1; }
[ -f "$APP_PNG" ] || { echo "ERROR: $APP_PNG missing (faux_logo.png, the app artwork)"; exit 1; }

echo "==> Building FauxCam.icns from faux_logo.png"
mkdir -p "$DIST"
ICONSET="$DIST/FauxCam.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$APP_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIST/FauxCam.icns"
rm -rf "$ICONSET"

echo "==> Done: $DIST/FauxCam.icns"
