#!/bin/bash
# Render every article asset with the REAL swift-visual-effect library, on an iOS Simulator.
#   - stills (01, 03-10)        -> ImageRenderer PNGs, flattened by assemble.py
#   - content anims (11/12/13)  -> ImageRenderer PNG frames -> H.264 .mp4 (encode_frames.swift)
#   - the edge demo (02)        -> live-backdrop continuous scroll, recordVideo -> .mp4 (export_mp4.swift)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARTICLE_DIR="$(cd "$HERE/../.." && pwd)"          # articles/visualeffect
STAGE="$HERE/build/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
BID="com.noahmilan.visualeffect.hostapp"
DEVICE_NAME="${DEVICE:-iPhone 16}"

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "error: no available simulator named '$DEVICE_NAME'"; exit 1; }
echo "Simulator: $DEVICE_NAME ($UDID)"

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override --time "9:41" \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true

bash "$HERE/build_app.sh" "$HERE/build"
xcrun simctl uninstall "$UDID" "$BID" 2>/dev/null || true   # clear the data container (stale _DONE/frames)
xcrun simctl install "$UDID" "$HERE/build/HostApp.app"

# ---- content-applied assets (ImageRenderer) -------------------------------------------------
echo "Rendering content-applied assets via ImageRenderer ..."
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
SIMCTL_CHILD_MODE=imagerender xcrun simctl launch "$UDID" "$BID" >/dev/null
CONT=$(xcrun simctl get_app_container "$UDID" "$BID" data)
for i in $(seq 1 90); do [ -f "$CONT/Documents/_DONE" ] && break; sleep 0.5; done
[ -f "$CONT/Documents/_DONE" ] || { echo "error: ImageRenderer pass did not finish"; exit 1; }
cp "$CONT/Documents/"*.png "$STAGE/"
echo "  pulled $(ls "$CONT/Documents/"*.png | wc -l | tr -d ' ') PNGs"

python3 "$HERE/assemble.py" "$STAGE" "$ARTICLE_DIR"        # flatten/copy the stills

echo "Encoding content animations to mp4 ..."
xcrun swift "$HERE/encode_frames.swift" "$ARTICLE_DIR/11-blurin.mp4"  60 0 "$STAGE"/11-blurin-*.png
xcrun swift "$HERE/encode_frames.swift" "$ARTICLE_DIR/12-scrub.mp4"   60 0 "$STAGE"/12-scrub-*.png
xcrun swift "$HERE/encode_frames.swift" "$ARTICLE_DIR/13-fadeout.mp4" 60 0 "$STAGE"/13-fadeout-*.png

# ---- live-backdrop edge demo: continuous auto-scroll, recorded at 60 fps -----------------------
echo "Recording the live-backdrop edge demo ..."
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
SIMCTL_CHILD_MODE=edge SIMCTL_CHILD_FRAME=0 SIMCTL_CHILD_TOTAL=0 xcrun simctl launch "$UDID" "$BID" >/dev/null
sleep 1.5
xcrun simctl io "$UDID" recordVideo --codec h264 --force "$STAGE/edge.mov" >/dev/null 2>&1 &
RPID=$!; sleep 7                                          # capture one 6 s ping-pong period (+ settle margin)
kill -INT "$RPID" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
xcrun swift "$HERE/export_mp4.swift" "$STAGE/edge.mov" "$ARTICLE_DIR/02-edgescroll.mp4" 540 0.5 6.0 full

rm -rf "$HERE/build"                                       # drop the built app + staging frames
echo "Done. Assets written to $ARTICLE_DIR"
