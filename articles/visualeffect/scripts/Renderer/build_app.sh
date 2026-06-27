#!/bin/bash
# Build HostApp.app for the iOS Simulator by compiling the host sources together with the
# REAL swift-visual-effect source file. No Xcode project / signing needed for the simulator.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE/build}"                                   # where HostApp.app is assembled
LIB="$HERE/../../../../../swift-visual-effect/Sources/VisualEffect/VisualEffectView.swift"
PHOTO_SRC="$HERE/../../../blurhash/blurhash_example.jpg"  # the sister article's photo
TARGET="arm64-apple-ios17.0-simulator"

[ -f "$LIB" ] || { echo "error: library source not found at $LIB"; exit 1; }

APP="$OUT/HostApp.app"
rm -rf "$APP"; mkdir -p "$APP"
cp "$HERE/Info.plist" "$APP/Info.plist"

# Bundle the source photo, downscaled to the article's 320x480 canvas.
python3 - "$PHOTO_SRC" "$APP/photo.jpg" <<'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).convert("RGB").resize((320, 480), Image.LANCZOS).save(sys.argv[2], quality=92)
PY

echo "Compiling HostApp + the real VisualEffect source for $TARGET ..."
xcrun -sdk iphonesimulator swiftc -O -target "$TARGET" \
    "$HERE/HostApp.swift" "$LIB" -o "$APP/HostApp"

echo "Built $APP"
