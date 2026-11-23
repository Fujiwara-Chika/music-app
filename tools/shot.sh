#!/bin/bash
# Launches the built app and captures its window to a PNG.
#
# usage: tools/shot.sh [output.png]
#
# The window is only trustworthy once AppKit has applied the saved frame: right
# after launch the window list reports a ~114x113 transitional surface, and
# capturing then yields a small/blank image. So we wait for the settled
# 1148x737 frame and re-capture until the PNG matches it at 2x.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/Assets/shot.png}"
APP="$ROOT/build/音乐.app"
EXPECT_W=1148
EXPECT_H=737

if [ ! -x "$ROOT/tools/winid" ]; then
    echo "▸ compiling winid"
    swiftc -O "$ROOT/tools/winid.swift" -o "$ROOT/tools/winid" || exit 1
fi

# The app window, as "<id> <width> <height>", once it has the settled frame.
find_window() {
    "$ROOT/tools/winid" 音乐 2>/dev/null | awk -v w=$EXPECT_W -v h=$EXPECT_H '
        $2 > w - 6 && $2 < w + 6 && $3 > h - 6 && $3 < h + 6 { print $1 " " $2 " " $3; exit }'
}

# Wake the display first: an idle display makes WindowServer report a shrunken
# placeholder surface, and capturing that yields a 114x113 or 534x450 image.
caffeinate -u -t 8 &
CAFFEINATE=$!

pkill -f "MacOS/Music" 2>/dev/null
sleep 0.6
ARGS=()
if [ -n "${MUSIC_IMPORT:-}" ]; then
    ARGS+=(--import "$MUSIC_IMPORT")
fi
if [ -n "${MUSIC_AUTOPLAY:-}" ]; then
    ARGS+=(--autoplay "$MUSIC_AUTOPLAY")
fi
if [ ${#ARGS[@]} -gt 0 ]; then
    ARGS=(--args "${ARGS[@]}")
fi
open "$APP" ${ARGS[@]+"${ARGS[@]}"} || exit 1

WID=""
for _ in $(seq 1 60); do
    read -r WID _ <<<"$(find_window)"
    [ -n "${WID:-}" ] && break
    sleep 0.25
done
[ -z "${WID:-}" ] && { echo "window never reached ${EXPECT_W}x${EXPECT_H}"; exit 1; }

# Give --autoplay time to start the demo track (and seek) before capturing, and
# --import time to finish scanning a large folder (MUSIC_WAIT overrides).
if [ -n "${MUSIC_WAIT:-}" ]; then
    sleep "$MUSIC_WAIT"
elif [ -n "${MUSIC_AUTOPLAY:-}" ]; then
    sleep 4
fi

# The PNG must be the whole window: 2296x1474 on a 2x display, 1148x737 when the
# display is running a 1x mode. Prefer 2x but settle for 1x after a few tries.
for attempt in $(seq 1 10); do
    sleep 0.5
    screencapture -x -o -l "$WID" "$OUT" 2>/dev/null
    size=$(sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w" "h}')
    if [ "$size" = "$((EXPECT_W * 2)) $((EXPECT_H * 2))" ]; then
        kill $CAFFEINATE 2>/dev/null
        echo "✓ $OUT (window $WID, ${size} px, 2x)"
        exit 0
    fi
    if [ "$size" = "$EXPECT_W $EXPECT_H" ] && [ "$attempt" -ge 5 ]; then
        kill $CAFFEINATE 2>/dev/null
        echo "✓ $OUT (window $WID, ${size} px, 1x display)"
        exit 0
    fi
    # Re-activate the app: an occluded window is captured from a stale surface.
    open "$APP" >/dev/null 2>&1
done

kill $CAFFEINATE 2>/dev/null
echo "capture mismatch (got ${size:-nothing}, want $((EXPECT_W * 2))x$((EXPECT_H * 2)) or ${EXPECT_W}x${EXPECT_H})"
exit 1
