#!/usr/bin/env python3
"""Rebuild Resources/AppIcon.icns from a square artwork PNG.

The supplied art is a glossy squircle rendered on white, so it has to be
(knocked out / re-fitted) before it can be a macOS icon:

* the white surround and the artwork's own outer glow are dropped — the
  system draws the icon's shadow, and an opaque white square shows up on any
  non-white surface;
* the squircle is re-fitted to Apple's icon grid: ~84% of the canvas with the
  rest transparent, which is what /System/Applications icons do (measured
  0.836–0.844 of the canvas on Music.app).

usage: tools/make-appicon.py [source.png] [--out Resources/AppIcon.icns]
"""
import sys
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Assets" / "appicon-source.png"
OUT = ROOT / "Resources" / "AppIcon.icns"
MASTER = 1024
# Apple's macOS icon grid: the drawable rounded square ends up at ~83% of the
# canvas (/System/Applications/Music.app measures 0.828), the rest transparent.
CONTENT_RATIO = 0.83
# Saturation (relative to the brightest channel) that marks the solid edge of
# the artwork, ignoring the soft glow the artwork was rendered with.
CLIP_SATURATION = 0.22


def body_mask(rgb: np.ndarray) -> np.ndarray:
    """Pixels that belong to the artwork rather than the white surround."""
    a = rgb.astype(np.float32) / 255.0
    mx, mn = a.max(axis=2), a.min(axis=2)
    saturation = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    return (saturation > 0.10) & (mx > 0.25)


def fill_holes(mask: np.ndarray) -> np.ndarray:
    """The cat's white face is low-saturation, so close every interior hole.

    Flood the surround from the corners; a pixel that was background and got
    painted is outside the artwork, everything else (body plus enclosed holes)
    is inside.
    """
    from PIL import ImageDraw

    h, w = mask.shape
    canvas = Image.fromarray((mask * 255).astype(np.uint8), "L")
    flood = canvas.copy()
    for xy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        ImageDraw.floodfill(flood, xy, 255, thresh=0)
    outside = (np.asarray(flood) == 255) & (np.asarray(canvas) == 0)
    return ~outside


def squircle_mask(size: tuple[int, int], n: float = 5.2, samples: int = 2048) -> np.ndarray:
    """A macOS-style continuous-curvature rounded square (superellipse)."""
    w, h = size
    t = np.linspace(0, 2 * np.pi, samples, endpoint=False)
    ct, st = np.cos(t), np.sin(t)
    xs = np.sign(ct) * np.abs(ct) ** (2 / n)
    ys = np.sign(st) * np.abs(st) ** (2 / n)
    img = Image.new("L", (w, h), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(img).polygon(
        list(zip((xs * 0.5 + 0.5) * w, (ys * 0.5 + 0.5) * h)), fill=255)
    return np.asarray(img) > 0


def build(source: Path, crop: tuple[int, int, int] | None = None) -> Image.Image:
    """`crop` is (x, y, side) for artwork that is already a rounded square (for
    example lifted out of a mockup), instead of a square image on white."""
    src = Image.open(source).convert("RGB")
    if crop:
        x, y, side = crop
        art = src.crop((x, y, x + side, y + side)).convert("RGBA")
        mask = Image.fromarray(
            (squircle_mask((side, side)) * 255).astype(np.uint8), "L")
        # Keep the mask one pixel inside the artwork's own edge so no sliver of
        # the surrounding page survives at the corners.
        mask = mask.filter(ImageFilter.MinFilter(3))
        art.putalpha(mask.filter(ImageFilter.GaussianBlur(0.8)))
        return fit(art)
    rgb = np.asarray(src)
    mask = fill_holes(body_mask(rgb))
    ys, xs = np.where(mask)
    box = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
    # The silhouette fades out into a soft glow, so the *solid* edge is well
    # inside the sat>0.10 bounding box. Fit the squircle to that solid edge.
    solid = np.where(
        (rgb.max(axis=2).astype(np.float32) > 0)
        & (rgb.max(axis=2).astype(np.int32) - rgb.min(axis=2).astype(np.int32)
           > CLIP_SATURATION * rgb.max(axis=2)), 1, 0)
    sys_y, sys_x = np.where(solid.astype(bool))
    shape = (sys_x.min(), sys_y.min(), sys_x.max() + 1, sys_y.max() + 1)
    # The artwork carries a baked-in outer glow; the system draws its own
    # shadow, so clip to the squircle instead of keeping that halo.
    inner = np.zeros_like(mask)
    inner[shape[1]:shape[3], shape[0]:shape[2]] = squircle_mask(
        (shape[2] - shape[0], shape[3] - shape[1]))
    mask &= inner
    # Drop one-pixel specks of glow that sit just inside the squircle.
    mask = Image.fromarray((mask * 255).astype(np.uint8), "L")
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))

    alpha = mask.crop(box)
    alpha = alpha.filter(ImageFilter.GaussianBlur(1.2))
    art = src.crop(box).convert("RGBA")
    art.putalpha(alpha)

    return fit(art)


def fit(art: Image.Image) -> Image.Image:
    """Fit and centre on the *visible* shape, not on the crop box: the artwork's
    silhouette is not perfectly symmetric, and an off-centre icon reads as
    "the wrong size" next to system icons."""
    art = art.crop(art.getchannel("A").getbbox())
    target = round(MASTER * CONTENT_RATIO)
    scale = target / max(art.size)
    art = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)

    master = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    master.alpha_composite(art, ((MASTER - art.width) // 2, (MASTER - art.height) // 2))
    return master


def icns(master: Image.Image, out: Path) -> None:
    sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size, scale in sizes:
            px = size * scale
            suffix = "@2x" if scale == 2 else ""
            # Downscale in premultiplied space, otherwise transparent pixels
            # drag their (white) colour into the edge and every small size gets
            # a pale halo.
            master.convert("RGBa").resize((px, px), Image.LANCZOS).convert("RGBA").save(
                iconset / f"icon_{size}x{size}{suffix}.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(out)], check=True)


def main() -> None:
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    src = Path(argv[0]) if argv else SOURCE
    out = OUT
    if "--out" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--out") + 1])
    crop = None
    if "--crop" in sys.argv:
        x, y, side = (int(v) for v in sys.argv[sys.argv.index("--crop") + 1].split(","))
        crop = (x, y, side)
    master = build(src, crop)
    master.save(ROOT / "Assets" / "appicon-master.png")
    icns(master, out)
    print(f"wrote {out} ({out.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
