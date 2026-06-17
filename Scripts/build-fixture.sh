#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT/Fixture"
DEPLOY_MIN="17.0"
EXEC_NAME="FauxFixture"
APP_DIR="$FIXTURE_DIR/$EXEC_NAME.app"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"

rm -rf "$FIXTURE_DIR/build" "$APP_DIR"
mkdir -p "$FIXTURE_DIR/build"

for ARCH in arm64 x86_64; do
    swiftc -parse-as-library -O \
        -sdk "$SDK" \
        -target "$ARCH-apple-ios$DEPLOY_MIN-simulator" \
        -o "$FIXTURE_DIR/build/$EXEC_NAME-$ARCH" \
        "$FIXTURE_DIR/FixtureApp.swift"
done

lipo -create "$FIXTURE_DIR/build/$EXEC_NAME-arm64" "$FIXTURE_DIR/build/$EXEC_NAME-x86_64" \
    -output "$FIXTURE_DIR/build/$EXEC_NAME"

mkdir -p "$APP_DIR"
cp "$FIXTURE_DIR/build/$EXEC_NAME" "$APP_DIR/$EXEC_NAME"
cp "$FIXTURE_DIR/Info.plist" "$APP_DIR/Info.plist"

plutil -lint "$APP_DIR/Info.plist"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"
lipo -info "$APP_DIR/$EXEC_NAME"
echo "built $APP_DIR"
