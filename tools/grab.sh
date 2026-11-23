#!/bin/bash
# Captures the running app window, first making sure the display is awake and the
# window reports its real size (an idle/occluded window is reported shrunken).
# usage: tools/grab.sh out.png
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/grab.png}"
caffeinate -u -t 6 &

find_wid() {
    "$ROOT/tools/winid" 音乐 | awk '$2>1140 && $2<1160 && $3>730 && $3<745 {print $1; exit}'
}

for _ in $(seq 1 24); do
    WID="$(find_wid)"
    if [ -n "${WID:-}" ]; then
        screencapture -x -o -l "$WID" "$OUT" 2>/dev/null
        W=$(sips -g pixelWidth "$OUT" 2>/dev/null | awk '/pixelWidth/{print $2}')
        if [ "${W:-0}" -ge 2296 ]; then echo "✓ $OUT (${W}px)"; exit 0; fi
    fi
    open "$ROOT/build/音乐.app" >/dev/null 2>&1
    sleep 0.5
done
echo "failed"; exit 1
