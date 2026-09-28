#!/usr/bin/env python3
"""Render StagOS wallpapers (2560x1440, stag-control palette).

  desktop/wall/stag-wall.png  home: "STAG OS" wordmark, white underline, red HUD corners
  desktop/wall/stag-lock.png  lock: the orb, scaled up (source: desktop/wall/stag-orb.png)

Needs Pillow + Orbitron (OFL). Font is fetched to tools/.cache on first run.
Usage: python3 tools/make-walls.py
"""
import os
import urllib.request
from PIL import Image, ImageDraw, ImageFont, ImageFilter

W, H = 2560, 1440
SS = 2  # supersample
BG = (10, 10, 10)
RED = (200, 16, 46)
WHITE = (240, 240, 240)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WALL = os.path.join(ROOT, "desktop", "wall")
FONT_URL = "https://raw.githubusercontent.com/google/fonts/main/ofl/orbitron/Orbitron%5Bwght%5D.ttf"
FONT = os.path.join(ROOT, "tools", ".cache", "Orbitron.ttf")
BAR = 51  # waybar height in physical px (34 logical @ 1.5x)
ORB_ZOOM = 1.4


def font(size, weight="Bold"):
    if not os.path.exists(FONT):
        os.makedirs(os.path.dirname(FONT), exist_ok=True)
        urllib.request.urlretrieve(FONT_URL, FONT)
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(weight)
    return f


def tracked(draw, xy, text, f, fill, track):
    """Draw text with extra letter spacing; returns total width."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + track
    return x - track - xy[0]


def text_width(draw, text, f, track):
    return sum(draw.textlength(c, font=f) for c in text) + track * (len(text) - 1)


def corners(d, s):
    """Red HUD brackets in each corner: heavy L + thin inner L + tick."""
    inset, arm, t = 96 * s, 150 * s, 5 * s
    inset2, arm2, t2 = inset + 22 * s, 60 * s, 2 * s
    for sx in (1, -1):
        for sy in (1, -1):
            ox = inset if sx == 1 else W * s - inset
            oy = inset if sy == 1 else H * s - inset
            # heavy L
            d.rectangle(_r(ox, oy, ox + sx * arm, oy + sy * t), fill=RED)
            d.rectangle(_r(ox, oy, ox + sx * t, oy + sy * arm), fill=RED)
            # thin inner L
            ix = inset2 if sx == 1 else W * s - inset2
            iy = inset2 if sy == 1 else H * s - inset2
            d.rectangle(_r(ix, iy, ix + sx * arm2, iy + sy * t2), fill=RED + (150,))
            d.rectangle(_r(ix, iy, ix + sx * t2, iy + sy * arm2), fill=RED + (150,))
            # tick marks along the long arm
            for k in (1, 2, 3):
                tx = ox + sx * (arm + 14 * s * k)
                d.rectangle(_r(tx, oy, tx + sx * 6 * s, oy + sy * t), fill=RED + (200 - 50 * k,))


def _r(x0, y0, x1, y1):
    return (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))


def home():
    s = SS
    img = Image.new("RGBA", (W * s, H * s), BG + (255,))
    d = ImageDraw.Draw(img, "RGBA")
    corners(d, s)

    text, f, track = "STAG OS", font(170 * s, "Bold"), 38 * s
    tw = text_width(d, text, f, track)
    asc = f.getbbox("S")  # cap box for vertical centering
    cap_h = asc[3] - asc[1]
    cy = (H * s + BAR * s) // 2 - 30 * s
    x0 = (W * s - tw) // 2
    y0 = cy - cap_h // 2 - asc[1]

    # soft glow under the wordmark
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    tracked(ImageDraw.Draw(glow), (x0, y0), text, f, WHITE + (70,), track)
    img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(18 * s)))
    d = ImageDraw.Draw(img, "RGBA")
    tracked(d, (x0, y0), text, f, WHITE, track)

    # white underline, full wordmark width
    uy = cy + cap_h // 2 + 56 * s
    d.rectangle((x0, uy, x0 + tw, uy + 4 * s), fill=WHITE)

    img.convert("RGB").resize((W, H), Image.LANCZOS).save(os.path.join(WALL, "stag-wall.png"), optimize=True)


def lock():
    src = Image.open(os.path.join(WALL, "stag-orb.png")).convert("RGB")
    cw, ch = round(W / ORB_ZOOM), round(H / ORB_ZOOM)
    box = ((W - cw) // 2, (H - ch) // 2, (W - cw) // 2 + cw, (H - ch) // 2 + ch)
    src.crop(box).resize((W, H), Image.LANCZOS).save(os.path.join(WALL, "stag-lock.png"), optimize=True)


if __name__ == "__main__":
    home()
    lock()
    print("wrote desktop/wall/stag-wall.png, desktop/wall/stag-lock.png")
