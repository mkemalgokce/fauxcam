#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES=("$ROOT"/Guest/*.m)
OUTPUT_DIR="$ROOT/dist"
OUTPUT="$OUTPUT_DIR/libFaux.dylib"
DEPLOYMENT_TARGET="15.0"
ARCHITECTURES=(arm64 x86_64)

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUTPUT_DIR"

STAGING="$OUTPUT_DIR/.staging.$$"
mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT

SLICES=()
for ARCH in "${ARCHITECTURES[@]}"; do
    SLICE="$STAGING/libFaux-$ARCH.dylib"
    xcrun clang -arch "$ARCH" \
        -dynamiclib \
        -isysroot "$SDK_PATH" \
        -target "$ARCH-apple-ios$DEPLOYMENT_TARGET-simulator" \
        -fobjc-arc \
        -fmodules \
        -install_name "@rpath/libFaux.dylib" \
        -framework Foundation \
        -framework CoreMedia \
        -framework AVFoundation \
        -o "$SLICE" \
        "${SOURCES[@]}"
    SLICES+=("$SLICE")
done

STAGED_OUTPUT="$STAGING/libFaux.dylib"
xcrun lipo -create "${SLICES[@]}" -output "$STAGED_OUTPUT"
xcrun codesign --force --sign - --timestamp=none "$STAGED_OUTPUT"
mv -f "$STAGED_OUTPUT" "$OUTPUT"

"$ROOT/Scripts/verify-dylib.sh" "$OUTPUT"
echo "built $OUTPUT"
