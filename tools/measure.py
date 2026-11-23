#!/usr/bin/env python3
"""Measure horizontal / vertical feature runs in a 2x window screenshot.

All input and output coordinates are in points (the image is treated as 2x).

    tools/measure.py row  <image> <y_pt> [x0_pt] [x1_pt] [threshold]
    tools/measure.py col  <image> <x_pt> [y0_pt] [y1_pt] [threshold]
    tools/measure.py rows <image> [x0_pt] [x1_pt] [threshold]

`row`/`col` print the runs that differ from the local background; `rows` prints
the text bands of a region (used to compare the now-playing panel line rhythm).
"""
import sys
from PIL import Image

SCALE = 2


def load(path):
    im = Image.open(path).convert("RGB")
    return im


def luma(px):
    return 0.299 * px[0] + 0.587 * px[1] + 0.114 * px[2]


def runs(values, thr, min_len=1):
    out, start = [], None
    for i, v in enumerate(values):
        if v >= thr and start is None:
            start = i
        elif v < thr and start is not None:
            if i - start >= min_len:
                out.append((start, i))
            start = None
    if start is not None:
        out.append((start, len(values)))
    return out


def main():
    mode = sys.argv[1]
    im = load(sys.argv[2])
    W, H = im.size
    if mode in ("row", "rows"):
        y = float(sys.argv[3]) if mode == "row" else None
        if mode == "row":
            x0 = float(sys.argv[4]) if len(sys.argv) > 4 else 0
            x1 = float(sys.argv[5]) if len(sys.argv) > 5 else W / SCALE
            thr = float(sys.argv[6]) if len(sys.argv) > 6 else 90
            row = [im.getpixel((x, int(y * SCALE))) for x in range(int(x0 * SCALE), int(x1 * SCALE))]
            vals = [luma(p) for p in row]
            for a, b in runs(vals, thr):
                print(f"x {x0 + a / SCALE:7.1f} .. {x0 + b / SCALE:7.1f}  (w {(b - a) / SCALE:6.1f})")
        else:
            x0 = float(sys.argv[3]) if len(sys.argv) > 3 else 0
            x1 = float(sys.argv[4]) if len(sys.argv) > 4 else W / SCALE
            thr = float(sys.argv[5]) if len(sys.argv) > 5 else 100
            prof = []
            for yy in range(H):
                px = [im.getpixel((x, yy)) for x in range(int(x0 * SCALE), int(x1 * SCALE), 2)]
                prof.append(max(luma(p) for p in px))
            for a, b in runs(prof, thr, min_len=4):
                print(f"y {a / SCALE:7.1f} .. {b / SCALE:7.1f}  (h {(b - a) / SCALE:6.1f})")
    else:
        x = float(sys.argv[3])
        y0 = float(sys.argv[4]) if len(sys.argv) > 4 else 0
        y1 = float(sys.argv[5]) if len(sys.argv) > 5 else H / SCALE
        thr = float(sys.argv[6]) if len(sys.argv) > 6 else 90
        col = [im.getpixel((int(x * SCALE), y)) for y in range(int(y0 * SCALE), int(y1 * SCALE))]
        vals = [luma(p) for p in col]
        for a, b in runs(vals, thr):
            print(f"y {y0 + a / SCALE:7.1f} .. {y0 + b / SCALE:7.1f}  (h {(b - a) / SCALE:6.1f})")


if __name__ == "__main__":
    main()
