#!/bin/bash
# Build the FauxCam app icon (FauxCam.icns) from the artwork Icons/appicon.png.
# The same appicon.png is used directly (in color) as the menu-bar item image,
# so no separate template glyph is generated.
#
# Requires: iconutil + sips (Xcode Command Line Tools).
# Outputs into Icons/: FauxCam.icns. sign-app.sh copies it (and appicon.png)
# into the app bundle's Resources.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONS="$ROOT/Icons"
APP_PNG="$ICONS/faux_logo.png"

command -v iconutil >/dev/null || { echo "ERROR: iconutil missing (install Xcode Command Line Tools)"; exit 1; }
command -v sips >/dev/null || { echo "ERROR: sips missing (install Xcode Command Line Tools)"; exit 1; }
[ -f "$APP_PNG" ] || { echo "ERROR: $APP_PNG missing (faux_logo.png, the app artwork)"; exit 1; }

echo "==> Building FauxCam.icns from faux_logo.png"
ICONSET="$ICONS/FauxCam.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$APP_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$APP_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICONS/FauxCam.icns"
rm -rf "$ICONSET"

echo "==> Done: $ICONS/FauxCam.icns"
