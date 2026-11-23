#!/usr/bin/env python3
"""Generates Resources/AppIcon.icns for the music app."""
import math
import os
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = 1024


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def make_icon():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Body: subtle vertical gradient in the app's slate-blue family.
    body = Image.new("RGB", (S, S), (0x14, 0x26, 0x39))
    d = ImageDraw.Draw(body)
    for y in range(S):
        t = y / S
        r = int(0x1B + (0x0E - 0x1B) * t)
        g = int(0x31 + (0x1D - 0x31) * t)
        b = int(0x4C + (0x2E - 0x4C) * t)
        d.line([(0, y), (S, y)], fill=(r, g, b))
    glow = Image.new("RGB", (S, S), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([S * 0.12, S * 0.05, S * 0.88, S * 0.72], fill=(0x2A, 0x53, 0x78))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.14))
    body = Image.blend(body, glow, 0.55)
    img.paste(body, (0, 0), rounded_mask(S, S * 0.205))

    d = ImageDraw.Draw(img)

    # Rim light
    d.rounded_rectangle([1, 1, S - 2, S - 2], radius=S * 0.205,
                        outline=(255, 255, 255, 40), width=4)

    # Vinyl disc
    cx, cy, r = S * 0.5, S * 0.47, S * 0.265
    for i in range(26):
        rr = r - i * (r / 30)
        c = 12 if i % 2 == 0 else 24
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=(c, c + 6, c + 12, 255), width=3)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=(255, 255, 255, 60), width=3)

    # Label + hole
    lr = r * 0.34
    d.ellipse([cx - lr, cy - lr, cx + lr, cy + lr], fill=(0xE9, 0xEE, 0xF4, 255))
    hr = lr * 0.22
    d.ellipse([cx - hr, cy - hr, cx + hr, cy + hr], fill=(0x16, 0x28, 0x3C, 255))

    # Play triangle on the label
    pr = lr * 0.42
    tri = [
        (cx - pr * 0.55, cy - pr),
        (cx - pr * 0.55, cy + pr),
        (cx + pr * 0.95, cy),
    ]
    d.polygon(tri, fill=(0x16, 0x28, 0x3C, 255))

    # Equalizer bars along the bottom
    bars = 7
    w = S * 0.036
    gap = S * 0.021
    total = bars * w + (bars - 1) * gap
    x0 = (S - total) / 2
    heights = [0.09, 0.16, 0.11, 0.22, 0.13, 0.18, 0.08]
    base = S * 0.845
    for i, h in enumerate(heights):
        x = x0 + i * (w + gap)
        y = base - h * S * 0.55
        d.rounded_rectangle([x, y, x + w, base], radius=w / 2,
                            fill=(0x6F, 0xC0, 0x9A, 255) if i % 2 else (0xE0, 0xC6, 0x4B, 255))

    return img


def main():
    icon = make_icon()
    iconset = tempfile.mkdtemp(suffix=".iconset")
    for size in (16, 32, 64, 128, 256, 512):
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
        icon.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
    out = os.path.join(ROOT, "Resources", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    preview = os.path.join(ROOT, "Assets", "appicon-preview.png")
    icon.resize((512, 512), Image.LANCZOS).save(preview)
    print("wrote", out)
    print("wrote", preview)


if __name__ == "__main__":
    main()
