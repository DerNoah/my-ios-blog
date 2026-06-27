#!/bin/bash
# Build HostApp.app for the iOS Simulator by compiling the host sources together with the
# REAL swift-sphere-view source file (in-module, so internal setRotationOffset is callable).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"
LIB="$HERE/../../../../../swift-sphere-view/Sources/SphereView/SphereElementView.swift"
TARGET="arm64-apple-ios16.0-simulator"

[ -f "$LIB" ] || { echo "error: library source not found at $LIB"; exit 1; }

APP="$OUT/HostApp.app"
rm -rf "$APP"; mkdir -p "$APP"
cp "$HERE/Info.plist" "$APP/Info.plist"

echo "Compiling SphereHost + the real SphereElementView for $TARGET ..."
xcrun -sdk iphonesimulator swiftc -O -target "$TARGET" \
    "$HERE/SphereHost.swift" "$LIB" -o "$APP/HostApp"

echo "Built $APP"
