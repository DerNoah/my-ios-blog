#!/bin/bash
# Render every article asset with the REAL swift-visual-effect library, on an iOS Simulator.
#   - content-applied assets  -> ImageRenderer PNGs pulled from the app container
#   - the edge GIF            -> live-backdrop frames captured on-screen via simctl screenshot
# Then hand the PNG frames to assemble.py (Pillow) to write the final assets.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARTICLE_DIR="$(cd "$HERE/../.." && pwd)"          # articles/visualeffect
STAGE="$HERE/build/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"
BID="com.noahmilan.visualeffect.hostapp"
DEVICE_NAME="${DEVICE:-iPhone 16}"
EDGE_FRAMES="${EDGE_FRAMES:-40}"                  # total frames for the ping-pong edge scroll (more = smoother)

UDID=$(xcrun simctl list devices available | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$UDID" ] || { echo "error: no available simulator named '$DEVICE_NAME'"; exit 1; }
echo "Simulator: $DEVICE_NAME ($UDID)"

xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$UDID" override --time "9:41" \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 >/dev/null 2>&1 || true

bash "$HERE/build_app.sh" "$HERE/build"
xcrun simctl install "$UDID" "$HERE/build/HostApp.app"

# ---- content-applied assets (ImageRenderer) -------------------------------------------------
echo "Rendering content-applied assets via ImageRenderer ..."
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
SIMCTL_CHILD_MODE=imagerender xcrun simctl launch "$UDID" "$BID" >/dev/null
CONT=$(xcrun simctl get_app_container "$UDID" "$BID" data)
for i in $(seq 1 60); do [ -f "$CONT/Documents/_DONE" ] && break; sleep 0.5; done
[ -f "$CONT/Documents/_DONE" ] || { echo "error: ImageRenderer pass did not finish"; exit 1; }
cp "$CONT/Documents/"*.png "$STAGE/"
echo "  pulled $(ls "$CONT/Documents/"*.png | wc -l | tr -d ' ') PNGs"

# ---- live-backdrop edge GIF (on-screen capture, frame-stepped) ------------------------------
echo "Capturing the live-backdrop edge demo ($EDGE_FRAMES frames) ..."
for f in $(seq 0 $((EDGE_FRAMES - 1))); do
    SIMCTL_CHILD_MODE=edge SIMCTL_CHILD_FRAME=$f SIMCTL_CHILD_TOTAL=$EDGE_FRAMES \
        xcrun simctl launch --terminate-running-process "$UDID" "$BID" >/dev/null
    sleep 1.4
    xcrun simctl io "$UDID" screenshot "$STAGE/edge-$(printf '%03d' "$f").png" >/dev/null 2>&1
done
xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true

python3 "$HERE/assemble.py" "$STAGE" "$ARTICLE_DIR"

rm -rf "$HERE/build"                              # drop the built app + staging frames
echo "Done. Assets written to $ARTICLE_DIR"
