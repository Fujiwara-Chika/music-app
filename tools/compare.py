#!/usr/bin/env python3
"""Builds a side-by-side comparison of the reference screenshot and the latest run."""
import os
import sys
from PIL import Image, ImageDraw

# Resolve next to the repo so the tool works from any working directory.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, "Assets/reference-ui.png")
SHOT = os.path.join(ROOT, "Assets/shot.png")
OUT = os.path.join(ROOT, "Assets/compare.png")


def main():
    ref = Image.open(REF).convert("RGB")
    shot = Image.open(SHOT).convert("RGB")
    shot = shot.resize(ref.size, Image.LANCZOS)
    gap = 12
    canvas = Image.new("RGB", (ref.width, ref.height * 2 + gap), (10, 10, 12))
    canvas.paste(ref, (0, 0))
    canvas.paste(shot, (0, ref.height + gap))
    d = ImageDraw.Draw(canvas)
    d.text((14, ref.height + 2), "REFERENCE / CURRENT", fill=(255, 220, 120))
    canvas.save(OUT)

    # Region-level difference report in 0-255 mean channel error.
    regions = {
        "topbar": (0, 0, ref.width, 88),
        "sidebar": (0, 88, 320, ref.height - 134),
        "table": (320, 88, 1776, ref.height - 134),
        "panel": (1776, 88, ref.width, ref.height - 134),
        "transport": (0, ref.height - 134, ref.width, ref.height),
    }
    print(f"{'region':<10} {'meanErr':>8} {'maxErr':>7}")
    for name, box in regions.items():
        a = ref.crop(box)
        b = shot.crop(box)
        pa, pb = a.load(), b.load()
        total = 0
        count = 0
        mx = 0
        for y in range(0, a.height, 3):
            for x in range(0, a.width, 3):
                ca, cb = pa[x, y], pb[x, y]
                diff = sum(abs(ca[i] - cb[i]) for i in range(3)) / 3
                total += diff
                count += 1
                if diff > mx:
                    mx = diff
        print(f"{name:<10} {total / count:8.2f} {mx:7.0f}")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
