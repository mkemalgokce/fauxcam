#!/bin/bash
# Build the FauxCam app icon (FauxCam.icns) from the artwork Icons/appicon.png
# and the menu-bar template glyph (MenuBarIcon.pdf) from make_icon.py.
#
# Requires: iconutil + sips (Xcode CLT) for the app icon;
#           rsvg-convert (brew install librsvg) for the menu-bar template pdf.
# Outputs into Icons/: FauxCam.icns, MenuBarIcon.pdf. sign-app.sh copies these
# into the app bundle's Resources.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONS="$ROOT/Icons"
APP_PNG="$ICONS/appicon.png"

command -v iconutil >/dev/null || { echo "ERROR: iconutil missing (install Xcode Command Line Tools)"; exit 1; }
command -v sips >/dev/null || { echo "ERROR: sips missing (install Xcode Command Line Tools)"; exit 1; }
command -v rsvg-convert >/dev/null || { echo "ERROR: rsvg-convert missing (brew install librsvg)"; exit 1; }
[ -f "$APP_PNG" ] || { echo "ERROR: $APP_PNG missing (the 1024x1024 app artwork)"; exit 1; }

echo "==> Building FauxCam.icns from appicon.png"
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

echo "==> Building MenuBarIcon.pdf (vector template)"
TEMPLATE_SVG="$ICONS/menubar-template.svg"
python3 "$ICONS/make_icon.py" --kind template > "$TEMPLATE_SVG"
rsvg-convert -f pdf "$TEMPLATE_SVG" -o "$ICONS/MenuBarIcon.pdf"

echo "==> Done: $ICONS/FauxCam.icns, $ICONS/MenuBarIcon.pdf"
