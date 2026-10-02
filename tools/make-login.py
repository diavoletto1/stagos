#!/usr/bin/env python3
"""Render the StagOS boot login screen assets (plymouth theme, 2560x1440 design).

The disk-unlock prompt is styled as the login page: STAG OS wordmark, HUD
corners, avatar, username, password box. Dots and messages are separate
images so the plymouth script never needs a font at boot.

Writes to assets/plymouth/stagos/: bg.png panel.png dot.png hint.png err.png signin.png bar.png track.png
Usage: python3 tools/make-login.py [username]
       python3 tools/make-login.py --progress   only the progress bar pieces (no fonts needed)
"""
import importlib.util
import os
import sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("walls", os.path.join(HERE, "make-walls.py"))
walls = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walls)

W, H, SS = walls.W, walls.H, walls.SS
BG, RED, WHITE = walls.BG, walls.RED, walls.WHITE
GREY = (119, 119, 119)
SILVER = (168, 168, 168)
OUT = os.path.join(walls.ROOT, "assets", "plymouth", "stagos")
USER = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "jack"

# panel layout (design px); the plymouth script mirrors BOX_CY / MSG_Y / DOT_STEP
PW, PH = 720, 400
AV_CY, AV_R = 110, 92
NAME_Y = 240
BOX = (80, 292, 640, 360)     # x0, y0, x1, y1
BOX_CY = (BOX[1] + BOX[3]) // 2
DOT_R = 8


def save(img, name):
    img.save(os.path.join(OUT, name), optimize=True)


def down(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def background():
    s = SS
    img = Image.new("RGB", (W * s, H * s), BG)
    d = ImageDraw.Draw(img, "RGBA")
    walls.corners(d, s)
    f, track = walls.font(44 * s, "Bold"), 14 * s
    text = "STAG OS"
    tw = walls.text_width(d, text, f, track)
    x0, y0 = (W * s - tw) // 2, 150 * s
    walls.tracked(d, (x0, y0), text, f, WHITE, track)
    cap = f.getbbox("S")
    uy = y0 + cap[3] + 18 * s
    d.rectangle((x0, uy, x0 + tw, uy + 3 * s), fill=WHITE)
    save(down(img, W, H), "bg.png")


def panel():
    s = SS
    img = Image.new("RGBA", (PW * s, PH * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img, "RGBA")
    cx = PW * s // 2
    # avatar: dark disc, red ring, initial
    r = AV_R * s
    d.ellipse((cx - r, AV_CY * s - r, cx + r, AV_CY * s + r), fill=(20, 20, 20, 255), outline=RED, width=5 * s)
    f = walls.font(96 * s, "Bold")
    ch = USER[:1].upper()
    bb = d.textbbox((0, 0), ch, font=f)
    d.text((cx - (bb[0] + bb[2]) // 2, AV_CY * s - (bb[1] + bb[3]) // 2), ch, font=f, fill=WHITE)
    # username
    f = walls.font(40 * s, "Medium")
    bb = d.textbbox((0, 0), USER, font=f)
    d.text((cx - (bb[0] + bb[2]) // 2, NAME_Y * s - (bb[1] + bb[3]) // 2), USER, font=f, fill=WHITE)
    # password box: dark fill, grey border, red left accent
    x0, y0, x1, y1 = (v * s for v in BOX)
    d.rectangle((x0, y0, x1, y1), fill=(16, 16, 16, 255), outline=(58, 58, 58, 255), width=2 * s)
    d.rectangle((x0, y0, x0 + 5 * s, y1), fill=RED)
    save(down(img, PW, PH), "panel.png")


def dot():
    s = 4
    n = DOT_R * 2
    img = Image.new("RGBA", (n * s, n * s), (0, 0, 0, 0))
    ImageDraw.Draw(img).ellipse((0, 0, n * s - 1, n * s - 1), fill=WHITE)
    save(down(img, n, n), "dot.png")


def progress():
    """1x1 solid pieces; the plymouth script scales them to the bar size."""
    save(Image.new("RGBA", (1, 1), RED + (255,)), "bar.png")
    save(Image.new("RGBA", (1, 1), (58, 58, 58, 255)), "track.png")


def label(text, color, name, size=24, weight="Regular"):
    s = SS
    f = walls.font(size * s, weight)
    track = 3 * s
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    tw = int(walls.text_width(probe, text, f, track))
    bb = f.getbbox("Ag")
    h = bb[3] + 6 * s
    img = Image.new("RGBA", (tw + 4 * s, h), (0, 0, 0, 0))
    walls.tracked(ImageDraw.Draw(img), (2 * s, 0), text, f, color, track)
    save(down(img, img.width // s, img.height // s), name)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    if sys.argv[1:] == ["--progress"]:
        progress()
        sys.exit(0)
    progress()
    background()
    panel()
    dot()
    label("PRESS ENTER TO SIGN IN", GREY, "hint.png")
    label("INCORRECT PASSWORD", RED, "err.png", weight="Bold")
    label("SIGNING IN", SILVER, "signin.png")
    print("wrote", ", ".join(["bg.png", "panel.png", "dot.png", "hint.png", "err.png", "signin.png", "bar.png", "track.png"]))
