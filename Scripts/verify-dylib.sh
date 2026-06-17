#!/usr/bin/env bash
set -euo pipefail
LIB="${1:-dist/libFaux.dylib}"

echo "== lipo -info (expect: contains x86_64 arm64) =="
xcrun lipo -info "$LIB"
for REQUIRED_ARCH in arm64 x86_64; do
    xcrun lipo -info "$LIB" | grep -qw "$REQUIRED_ARCH" || { echo "FAIL: missing $REQUIRED_ARCH slice"; exit 1; }
done

for ARCH in arm64 x86_64; do
    echo "== $ARCH LC_BUILD_VERSION (expect platform 7) =="
    PLAT=$(xcrun otool -arch "$ARCH" -l "$LIB" | awk '/LC_BUILD_VERSION/{f=1} f&&/ platform /{print $2; exit}')
    echo "platform=$PLAT"
    [ "$PLAT" = "7" ] || { echo "FAIL: $ARCH platform is $PLAT, expected 7 (PLATFORM_IOSSIMULATOR)"; exit 1; }
done

echo "== signature (expect adhoc + valid) =="
xcrun codesign -dvvv "$LIB" 2>&1 | grep -i 'Signature=adhoc' || { echo "FAIL: not ad-hoc signed"; exit 1; }
xcrun codesign --verify --strict "$LIB" || { echo "FAIL: signature invalid"; exit 1; }

echo "ALL CHECKS PASSED"
