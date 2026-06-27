#!/bin/bash
# Build, sign and package the `faux` CLI for distribution.
#
# This script handles the CLI ONLY. The menu-bar app is packaged separately by
# Scripts/sign-app.sh.
#
# Usage: ./Scripts/package-cli.sh [signing-identity]
#   signing-identity defaults to "-" (ad-hoc, local use only).
#   For distribution pass a Developer ID, e.g.:
#     ./Scripts/package-cli.sh "Developer ID Application: Your Name (TEAMID)"
#
# Outputs:
#   dist/faux        the signed CLI binary
#   dist/faux.zip    a ditto archive of the CLI (the published artifact)
#
# Notarization runs only when NOTARIZE_PROFILE names a stored notarytool keychain
# profile AND a Developer ID identity is used. A bare CLI binary cannot be
# stapled, so it is notarized for the online Gatekeeper check only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENTITY="${1:--}"
BUILD_CONFIG="release"
CLI_BINARY="$ROOT/dist/faux"
CLI_ZIP="$ROOT/dist/faux.zip"
ENTITLEMENTS="$ROOT/dist/faux.entitlements"

echo "==> Building faux CLI ($BUILD_CONFIG)"
swift build -c "$BUILD_CONFIG" --product faux --package-path "$ROOT"
BUILT_BINARY="$(swift build -c "$BUILD_CONFIG" --product faux --package-path "$ROOT" --show-bin-path)/faux"

mkdir -p "$ROOT/dist"
cp "$BUILT_BINARY" "$CLI_BINARY"

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
xattr -cr "$CLI_BINARY"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$CLI_BINARY"
codesign --verify --strict "$CLI_BINARY"
echo "==> Signed faux CLI at $CLI_BINARY (hardened runtime + camera entitlement)"

rm -f "$CLI_ZIP"
ditto -c -k "$CLI_BINARY" "$CLI_ZIP"
echo "==> CLI zip at $CLI_ZIP"

if [[ "$IDENTITY" == "-" ]]; then
  cat <<'NOTE'

NOTE: ad-hoc signed (local use only — Gatekeeper will block it on other Macs).
For distribution, pass a Developer ID and set NOTARIZE_PROFILE to notarize:
  NOTARIZE_PROFILE=fauxcam-notary ./Scripts/package-cli.sh \
    "Developer ID Application: Your Name (TEAMID)"
NOTE
elif [[ -n "${NOTARIZE_PROFILE:-}" ]]; then
  echo "==> Submitting faux.zip for notarization (contacts Apple and waits)"
  xcrun notarytool submit "$CLI_ZIP" --keychain-profile "$NOTARIZE_PROFILE" --wait
  echo "==> Notarized faux CLI (bare binaries cannot be stapled; verified online by Gatekeeper)"
else
  echo "NOTE: Developer ID signed but NOT notarized. Set NOTARIZE_PROFILE=<profile> to notarize."
fi
