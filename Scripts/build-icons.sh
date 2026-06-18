#!/bin/bash
# Generate the FauxCam app icon (FauxCam.icns) and the menubar template glyph
# (MenuBarIcon.pdf) from the SVG generator in Icons/.
#
# Requires: rsvg-convert (brew install librsvg), iconutil (Xcode CLT).
# Outputs into Icons/: FauxCam.icns, MenuBarIcon.pdf. sign-app.sh copies these
# into the app bundle's Resources.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONS="$ROOT/Icons"
GENERATOR="$ICONS/make_icon.py"

command -v rsvg-convert >/dev/null || { echo "ERROR: rsvg-convert missing (brew install librsvg)"; exit 1; }
command -v iconutil >/dev/null || { echo "ERROR: iconutil missing (install Xcode Command Line Tools)"; exit 1; }

APP_SVG="$ICONS/appicon.svg"
TEMPLATE_SVG="$ICONS/menubar-template.svg"
python3 "$GENERATOR" --kind app > "$APP_SVG"
python3 "$GENERATOR" --kind template > "$TEMPLATE_SVG"

echo "==> Building FauxCam.icns"
ICONSET="$ICONS/FauxCam.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$APP_SVG" -o "$ICONSET/icon_${size}x${size}.png"
  double=$((size * 2))
  rsvg-convert -w "$double" -h "$double" "$APP_SVG" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$ICONS/FauxCam.icns"
rm -rf "$ICONSET"

echo "==> Building MenuBarIcon.pdf (vector template)"
rsvg-convert -f pdf "$TEMPLATE_SVG" -o "$ICONS/MenuBarIcon.pdf"

echo "==> Done: $ICONS/FauxCam.icns, $ICONS/MenuBarIcon.pdf"
