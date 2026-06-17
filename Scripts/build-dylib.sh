#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Guest/Bootstrap.m"
OUTPUT_DIR="$ROOT/dist"
OUTPUT="$OUTPUT_DIR/libFaux.dylib"
DEPLOYMENT_TARGET="15.0"
ARCHITECTURES=(arm64 x86_64)

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
mkdir -p "$OUTPUT_DIR"

SLICES=()
for ARCH in "${ARCHITECTURES[@]}"; do
    SLICE="$OUTPUT_DIR/libFaux-$ARCH.dylib"
    clang -arch "$ARCH" \
        -dynamiclib \
        -isysroot "$SDK_PATH" \
        -target "$ARCH-apple-ios$DEPLOYMENT_TARGET-simulator" \
        -fobjc-arc \
        -install_name "@rpath/libFaux.dylib" \
        -framework Foundation \
        -o "$SLICE" \
        "$SOURCE"
    SLICES+=("$SLICE")
done

lipo -create "${SLICES[@]}" -output "$OUTPUT"
rm -f "${SLICES[@]}"

codesign --force --sign - --timestamp=none "$OUTPUT"

echo "built $OUTPUT"
lipo -info "$OUTPUT"
