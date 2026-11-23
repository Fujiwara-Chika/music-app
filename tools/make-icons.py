#!/usr/bin/env python3
"""App icon generator (Pillow only, drawn at 2x and downsampled).

The cat-head mark is a redraw of foobar2000's badge: its silhouette was traced
from the 256px icon embedded in foobar2000.exe (PE resources -> RT_ICON 5),
resampled to 110 points and smoothed, so it stays crisp as a vector-ish path at
any size. Eyes and mouth use the measured proportions of that icon.

    python3 tools/make-icons.py            # writes Assets/icons/*.png
"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SS = 2                      # supersampling factor
N = 1024 * SS               # working canvas
WHITE = (255, 255, 255)
BODY = 1024 * SS * 0.80     # squircle edge length inside the 1024 canvas

NAVY_TOP = (34, 56, 79)
NAVY_BOTTOM = (14, 22, 33)
LED_STOPS = [(0.00, (46, 140, 135)), (0.42, (87, 163, 94)), (0.78, (166, 168, 62)),
             (1.00, (219, 176, 51))]


def squircle_mask(size, inset=0, n=5.0, steps=720):
    """Superellipse approximation of Apple's rounded-square silhouette."""
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    c = size / 2
    r = c - inset
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = r * math.copysign(abs(ct) ** (2 / n), ct)
        y = r * math.copysign(abs(st) ** (2 / n), st)
        pts.append((c + x, c + y))
    d.polygon(pts, fill=255)
    return m


def vertical_gradient(size, stops):
    img = Image.new("RGB", (1, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(1, size - 1)
        for i in range(len(stops) - 1):
            a, ca = stops[i]
            b, cb = stops[i + 1]
            if a <= t <= b:
                k = (t - a) / max(1e-6, b - a)
                col = tuple(int(ca[j] + (cb[j] - ca[j]) * k) for j in range(3))
                break
        else:
            col = stops[-1][1]
        d.point((0, y), fill=col)
    return img.resize((size, size), Image.BILINEAR)


def body_layer():
    """The navy squircle: gradient, top sheen, inner rim and a soft drop shadow."""
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    inset = (N - BODY) / 2
    mask = squircle_mask(N, inset)

    shadow = mask.filter(ImageFilter.GaussianBlur(28 * SS))
    shadow = shadow.point(lambda v: int(v * 0.55))
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    layer.putalpha(shadow)
    canvas.alpha_composite(layer, (0, int(12 * SS)))

    body = vertical_gradient(N, [(0.0, NAVY_TOP), (1.0, NAVY_BOTTOM)]).convert("RGBA")
    body.putalpha(mask)
    canvas.alpha_composite(body)

    sheen = Image.new("L", (N, N), 0)
    sd = ImageDraw.Draw(sheen)
    sd.ellipse([N * 0.10, -N * 0.55, N * 0.90, N * 0.42], fill=46)
    sheen = sheen.filter(ImageFilter.GaussianBlur(40 * SS))
    sheen = Image.composite(sheen, Image.new("L", (N, N), 0), mask)
    white = Image.new("RGBA", (N, N), (255, 255, 255, 255))
    white.putalpha(sheen)
    canvas.alpha_composite(white)

    outer = squircle_mask(N, inset + 1.5 * SS)
    inner = squircle_mask(N, inset + 3.0 * SS)
    rim = ImageChops.subtract(outer, inner)
    rim = rim.point(lambda v: int(v * 0.16))
    w2 = Image.new("RGBA", (N, N), (255, 255, 255, 255))
    w2.putalpha(rim)
    canvas.alpha_composite(w2)
    return canvas, mask


def gradient_fill(mask, span):
    top, bottom = span
    ramp = vertical_gradient(N, LED_STOPS)
    try:
        ramp = ramp.crop((0, top, N, bottom)).resize((N, N), Image.BILINEAR)
    except ValueError:
        pass
    layer = ramp.convert("RGBA")
    layer.putalpha(mask)
    return layer


# --------------------------------------------------------------- the cat head
CAT_HEAD: [(float, float)] = [
    (0.2467, 0.0000),
    (0.2675, 0.0036),
    (0.2891, 0.0185),
    (0.3106, 0.0387),
    (0.3318, 0.0602),
    (0.3528, 0.0820),
    (0.3737, 0.1037),
    (0.3950, 0.1245),
    (0.4179, 0.1416),
    (0.4437, 0.1523),
    (0.4725, 0.1566),
    (0.5030, 0.1573),
    (0.5332, 0.1563),
    (0.5613, 0.1513),
    (0.5864, 0.1396),
    (0.6087, 0.1218),
    (0.6298, 0.1008),
    (0.6509, 0.0792),
    (0.6724, 0.0576),
    (0.6941, 0.0366),
    (0.7158, 0.0172),
    (0.7374, 0.0041),
    (0.7583, 0.0026),
    (0.7781, 0.0137),
    (0.7967, 0.0335),
    (0.8144, 0.0564),
    (0.8317, 0.0800),
    (0.8485, 0.1039),
    (0.8648, 0.1281),
    (0.8804, 0.1526),
    (0.8956, 0.1772),
    (0.9103, 0.2021),
    (0.9247, 0.2272),
    (0.9385, 0.2526),
    (0.9516, 0.2784),
    (0.9637, 0.3046),
    (0.9749, 0.3313),
    (0.9847, 0.3587),
    (0.9925, 0.3870),
    (0.9977, 0.4163),
    (1.0000, 0.4461),
    (1.0000, 0.4760),
    (0.9976, 0.5058),
    (0.9920, 0.5349),
    (0.9830, 0.5626),
    (0.9709, 0.5888),
    (0.9562, 0.6137),
    (0.9393, 0.6376),
    (0.9210, 0.6607),
    (0.9022, 0.6835),
    (0.8826, 0.7061),
    (0.8624, 0.7282),
    (0.8418, 0.7502),
    (0.8208, 0.7718),
    (0.7988, 0.7931),
    (0.7762, 0.8141),
    (0.7532, 0.8347),
    (0.7298, 0.8553),
    (0.7055, 0.8754),
    (0.6807, 0.8951),
    (0.6554, 0.9141),
    (0.6298, 0.9323),
    (0.6040, 0.9500),
    (0.5779, 0.9669),
    (0.5517, 0.9828),
    (0.5252, 0.9951),
    (0.4985, 1.0000),
    (0.4720, 0.9948),
    (0.4455, 0.9822),
    (0.4194, 0.9661),
    (0.3935, 0.9487),
    (0.3679, 0.9303),
    (0.3426, 0.9112),
    (0.3175, 0.8916),
    (0.2926, 0.8718),
    (0.2683, 0.8517),
    (0.2446, 0.8313),
    (0.2212, 0.8108),
    (0.1987, 0.7898),
    (0.1768, 0.7685),
    (0.1558, 0.7467),
    (0.1354, 0.7247),
    (0.1154, 0.7024),
    (0.0960, 0.6799),
    (0.0769, 0.6572),
    (0.0588, 0.6341),
    (0.0420, 0.6101),
    (0.0278, 0.5849),
    (0.0167, 0.5581),
    (0.0086, 0.5300),
    (0.0030, 0.5005),
    (0.0000, 0.4704),
    (0.0001, 0.4400),
    (0.0036, 0.4099),
    (0.0101, 0.3809),
    (0.0188, 0.3530),
    (0.0290, 0.3258),
    (0.0404, 0.2991),
    (0.0528, 0.2731),
    (0.0660, 0.2474),
    (0.0799, 0.2221),
    (0.0941, 0.1969),
    (0.1090, 0.1720),
    (0.1242, 0.1474),
    (0.1400, 0.1229),
    (0.1564, 0.0988),
    (0.1736, 0.0752),
    (0.1914, 0.0518),
    (0.2093, 0.0290),
    (0.2275, 0.0098),
]

EYE = dict(len=0.242, wid=0.127, tilt=51.0, cx=0.240, cy=0.515)
MOUTH = dict(x0=0.352, x1=0.638, top=0.712, bottom=0.846, stroke=0.034)


def cat_geometry(width_ratio=0.560):
    w = width_ratio * N
    h = w * 1.310
    ox = (N - w) / 2
    oy = (N - h) / 2 - 0.008 * N
    return ox, oy, w, h


def eye_points(ox, oy, w, h, mirror=False):
    cx = ox + (1 - EYE["cx"] if mirror else EYE["cx"]) * w
    cy = oy + EYE["cy"] * h
    half_len = EYE["len"] * w
    half_wid = EYE["wid"] * w
    # Measured from the icon: the outer corner sits high, the inner corner low.
    a = math.radians(-EYE["tilt"] if mirror else EYE["tilt"])
    ca, sa = math.cos(a), math.sin(a)

    def rot(u, v):
        return (cx + u * ca - v * sa, cy + u * sa + v * ca)

    steps = 44
    pts = []
    for i in range(steps + 1):
        t = i / steps
        u = -half_len + 2 * half_len * t
        pts.append(rot(u, -half_wid * math.sin(math.pi * t) ** 0.74))
    for i in range(1, steps):
        t = 1 - i / steps
        u = -half_len + 2 * half_len * t
        pts.append(rot(u, half_wid * math.sin(math.pi * t) ** 0.74))
    return pts


def cat_features_mask(size, ox, oy, w, h):
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    d.polygon(eye_points(ox, oy, w, h), fill=255)
    d.polygon(eye_points(ox, oy, w, h, mirror=True), fill=255)
    stroke = max(1, int(MOUTH["stroke"] * h))
    apex = (ox + 0.495 * w, oy + MOUTH["top"] * h + stroke / 2)
    left = (ox + MOUTH["x0"] * w + stroke / 2, oy + MOUTH["bottom"] * h - stroke / 2)
    right = (ox + MOUTH["x1"] * w - stroke / 2, oy + MOUTH["bottom"] * h - stroke / 2)
    d.line([left, apex, right], fill=255, width=stroke, joint="curve")
    for pt in (apex, left, right):
        d.ellipse([pt[0] - stroke / 2, pt[1] - stroke / 2,
                   pt[0] + stroke / 2, pt[1] + stroke / 2], fill=255)
    return m


def cat_head_mask(size, ox, oy, w, h):
    outline = [(ox + x * w, oy + y * h) for x, y in CAT_HEAD]
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(outline, fill=255)
    return Image.composite(Image.new("L", (size, size), 0), m,
                           cat_features_mask(size, ox, oy, w, h))


def cat_shadow(ox, oy, w, h):
    sh = Image.new("L", (N, N), 0)
    ImageDraw.Draw(sh).polygon([(ox + x * w, oy + y * h) for x, y in CAT_HEAD], fill=110)
    sh = sh.filter(ImageFilter.GaussianBlur(26 * SS))
    sh = ImageChops.offset(sh, 0, int(14 * SS))
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    layer.putalpha(sh)
    return layer


def cat_layer(ox, oy, w, h, fill):
    layer = Image.new("RGBA", (N, N), fill)
    layer.putalpha(cat_head_mask(N, ox, oy, w, h))
    return layer


def icon_cat_white():
    canvas, _ = body_layer()
    ox, oy, w, h = cat_geometry()
    canvas.alpha_composite(cat_shadow(ox, oy, w, h))
    canvas.alpha_composite(cat_layer(ox, oy, w, h, WHITE + (255,)))
    return canvas


def icon_cat_gradient():
    canvas, _ = body_layer()
    ox, oy, w, h = cat_geometry()
    canvas.alpha_composite(cat_shadow(ox, oy, w, h))
    mask = cat_head_mask(N, ox, oy, w, h)
    canvas.alpha_composite(gradient_fill(mask, (int(oy + 0.08 * h), int(oy + 0.96 * h))))
    return canvas


def icon_cat_ring():
    canvas, _ = body_layer()
    c = N / 2
    R = 0.300 * N
    ring = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse([c - R, c - R, c + R, c + R], outline=WHITE,
                                 width=int(11 * SS))
    canvas.alpha_composite(ring)
    w = 1.14 * R
    h = w * 1.310
    ox, oy = c - w / 2, c - h / 2
    canvas.alpha_composite(cat_layer(ox, oy, w, h, WHITE + (255,)))
    return canvas


def icon_cat_inverted():
    """White card, dark head: the original's own polarity."""
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    inset = (N - BODY) / 2
    mask = squircle_mask(N, inset)
    shadow = mask.filter(ImageFilter.GaussianBlur(26 * SS)).point(lambda v: int(v * 0.30))
    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    layer.putalpha(shadow)
    canvas.alpha_composite(layer, (0, int(10 * SS)))
    card = Image.new("RGBA", (N, N), (250, 250, 252, 255))
    card.putalpha(mask)
    canvas.alpha_composite(card)
    ox, oy, w, h = cat_geometry(0.50)
    canvas.alpha_composite(cat_layer(ox, oy, w, h, (22, 32, 44, 255)))
    return canvas


CANDIDATES = {
    "cat-white": icon_cat_white,
    "cat-gradient": icon_cat_gradient,
    "cat-ring": icon_cat_ring,
    "cat-inverted": icon_cat_inverted,
}


def main():
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Assets", "icons")
    out_dir = os.path.normpath(out_dir)
    os.makedirs(out_dir, exist_ok=True)
    rendered = {}
    for name, fn in CANDIDATES.items():
        icon = fn().resize((1024, 1024), Image.LANCZOS)
        path = os.path.join(out_dir, name + ".png")
        icon.save(path)
        rendered[name] = icon
        print("rendered", name)

    # Contact sheet: every variant at 300px on the app's own background.
    cell, gap = 300, 26
    sheet = Image.new("RGB", (len(rendered) * (cell + gap) + gap, cell + 2 * gap),
                      (28, 46, 66))
    for i, (name, icon) in enumerate(rendered.items()):
        sheet.paste(icon.resize((cell, cell), Image.LANCZOS), (gap + i * (cell + gap), gap),
                    icon.resize((cell, cell), Image.LANCZOS))
    sheet.save(os.path.join(out_dir, "hero.png"))

    # Size ladder, which is where an icon actually has to survive.
    ladder = Image.new("RGB", (1400, 200), (242, 242, 245))
    x = 24
    for name, icon in rendered.items():
        for size in (128, 64, 32, 16):
            thumb = icon.resize((size, size), Image.LANCZOS)
            ladder.paste(thumb, (x, 50), thumb)
            x += size + 12
        x += 24
    ladder.save(os.path.join(out_dir, "size-ladder.png"))
    print("wrote hero.png and size-ladder.png")


if __name__ == "__main__":
    main()
