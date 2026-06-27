#!/bin/bash
# Render the sphere-view article media with the REAL library on an iOS Simulator:
#   - per-mode videos via `simctl io recordVideo --codec h264`, exported to looped .mp4
#   - per-step stills via `simctl io screenshot`
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARTICLE_DIR="$(cd "$HERE/../.." && pwd)"          # articles/sphereview
STAGE="$HERE/build/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
BID="com.noahmilan.sphereview.hostapp"
DEVICE_NAME="${DEVICE:-iPhone 16}"
W="${VIDEO_WIDTH:-600}"

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "error: no simulator named '$DEVICE_NAME'"; exit 1; }
echo "Simulator: $DEVICE_NAME ($UDID)"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

bash "$HERE/build_app.sh" "$HERE/build"
xcrun simctl install "$UDID" "$HERE/build/HostApp.app"

launch() { # mode
    xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
    SIMCTL_CHILD_MODE="$1" xcrun simctl launch "$UDID" "$BID" >/dev/null
}

still() { # name mode wait
    launch "$2"; sleep "$3"
    xcrun simctl io "$UDID" screenshot "$STAGE/$1.png" >/dev/null 2>&1
    echo "  shot $1.png"
}

video() { # mode record_seconds loop_start loop_dur
    launch "$1"; sleep 1.5                          # let the animation settle
    xcrun simctl io "$UDID" recordVideo --codec h264 --force "$STAGE/$1.mov" >/dev/null 2>&1 &
    local rpid=$!
    sleep "$2"
    kill -INT "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
    xcrun swift "$HERE/export_mp4.swift" "$STAGE/$1.mov" "$ARTICLE_DIR/$1.mp4" "$W" "$3" "$4"
}

# ---- videos (mode, record_seconds, loop_start, loop_dur) ----
video spin     6.0 0.5 5.0
video rotate   4.0 0.5 2.83
video momentum 6.5 0.5 4.2
video zoom     5.5 0.5 4.0
video focus    6.0 0.5 5.0

# ---- stills (name, mode, settle) ----
still 01-intro      spin     2.0
still 02-distribute rotate   2.0
still 03-depth      still    0.8
still 04-rotate     rotate   3.2
still 05-momentum   momentum 1.2
still 06-zoom       zoom     1.0
still 07-focus      focus    2.0
# Crop the full-screen stills to centered 600×600 squares (to match the square videos).
python3 - "$STAGE" "$ARTICLE_DIR" <<'PY'
import sys, glob, os
from PIL import Image
stage, out = sys.argv[1], sys.argv[2]
for p in sorted(glob.glob(os.path.join(stage, "0*.png"))):
    im = Image.open(p).convert("RGB"); w, h = im.size; top = (h - w) // 2
    im.crop((0, top, w, top + w)).resize((600, 600), Image.LANCZOS).save(os.path.join(out, os.path.basename(p)))
PY

xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
rm -rf "$HERE/build"
echo "Done. Assets written to $ARTICLE_DIR"
