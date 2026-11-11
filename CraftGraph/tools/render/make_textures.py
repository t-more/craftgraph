#!/usr/bin/env python3
"""Draws CraftGraph's window textures from code: dark stone, a faint arcane
circle for the graph, gold frame pieces, the title plaque, buttons and icon
frames. Nothing is taken from the game's art.

    python3 tools/render/make_textures.py        (from the addon folder)

Writes Media/<name>.tga for the game (32-bit, power-of-two sizes) and
tools/render/icons/<name>.b64 (PNG) for the picture renderer, plus
tools/render/icons/sizes.lua with each texture's size. Needs Pillow, numpy
and scipy. The output is committed, so players never need this.
"""
import base64
import io
import math
import random
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy.ndimage import gaussian_filter

HERE = Path(__file__).resolve().parent
ADDON = HERE.parent.parent
MEDIA = ADDON / "Media"
ICONS = HERE / "icons"
SS = 4                                     # supersampling for smooth edges

GOLD_HI = (255, 236, 170)
GOLD = (214, 172, 82)
GOLD_LO = (120, 84, 30)
GOLD_DEEP = (58, 38, 12)
INK = (10, 8, 6)

sizes = {}


def save(name, img):
    assert img.width & (img.width - 1) == 0 and img.height & (img.height - 1) == 0, name
    img = img.convert("RGBA")
    MEDIA.mkdir(exist_ok=True)
    img.save(MEDIA / (name + ".tga"))
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    (ICONS / (name + ".b64")).write_text(base64.b64encode(buf.getvalue()).decode())
    sizes[name] = img.size


def big(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def shrink(img, w, h):
    return img.resize((w, h), Image.LANCZOS)


def periodic_noise(n, sigma, seed):
    rng = np.random.default_rng(seed)
    a = gaussian_filter(rng.standard_normal((n, n)), sigma, mode="wrap")
    return (a - a.mean()) / (a.std() + 1e-9)


def lerp(a, b, t):
    return tuple(int(round(x + (y - x) * t)) for x, y in zip(a, b))


def gold_at(t):
    """A metal ramp: t=0 dark, 0.5 gold, 1 highlight."""
    if t < 0.5:
        return lerp(GOLD_DEEP, GOLD, t / 0.5)
    return lerp(GOLD, GOLD_HI, (t - 0.5) / 0.5)


# --------------------------------------------------------------------------
# Stone: a tileable dark slate with soft blotches and fine grain.
# --------------------------------------------------------------------------
def stone():
    n = 256
    v = (0.55 * periodic_noise(n, 22, 1) + 0.3 * periodic_noise(n, 7, 2)
         + 0.15 * periodic_noise(n, 1.2, 3))
    # Faint veins: ridges of another noise.
    ridge = 1 - np.abs(periodic_noise(n, 10, 4))
    v += 0.35 * np.clip(ridge - 0.85, 0, 1) * 6
    v = (v - v.min()) / (v.max() - v.min())
    dark, light = np.array([17, 18, 21]), np.array([46, 45, 46])
    rgb = dark + (light - dark) * v[..., None] ** 1.3
    img = Image.fromarray(rgb.astype(np.uint8), "RGB").convert("RGBA")
    save("cg-stone", img)


# --------------------------------------------------------------------------
# Sigil: a faint arcane circle and blueprint lines, white on clear. The game
# tints it pale blue and keeps it faint behind the graph.
# --------------------------------------------------------------------------
def rune(draw, cx, cy, s, rng, width):
    """A made-up glyph of three or four strokes."""
    pts = [(cx + dx * s, cy + dy * s) for dx, dy in
           [(-1, -1), (0, -1), (1, -1), (-1, 0), (0, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]]
    spine = rng.choice([(1, 7), (0, 6), (2, 8)])
    draw.line([pts[spine[0]], pts[spine[1]]], fill=255, width=width)
    for _ in range(rng.randint(2, 3)):
        a, b = rng.sample(range(9), 2)
        draw.line([pts[a], pts[b]], fill=255, width=width)


def sigil():
    n = 512
    S = n * SS
    a = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(a)
    c = S / 2
    w = 2 * SS
    rng = random.Random(7)

    def circle(r, width=w):
        d.ellipse([c - r, c - r, c + r, c + r], outline=255, width=width)

    for r, k in [(0.47, 1.4), (0.445, 0.8), (0.34, 1), (0.235, 0.8), (0.12, 1)]:
        circle(r * S, int(w * k))
    # Two squares, one turned, make an eight-pointed star between the
    # middle rings; a small square sits turned inside the inner ring.
    for turn in (0, math.pi / 4):
        pts = [(c + 0.34 * S * math.cos(turn + i * math.pi / 2), c + 0.34 * S * math.sin(turn + i * math.pi / 2))
               for i in range(4)]
        d.polygon(pts, outline=255, width=w)
    pts = [(c + 0.12 * S * math.cos(math.pi / 4 + i * math.pi / 2), c + 0.12 * S * math.sin(math.pi / 4 + i * math.pi / 2))
           for i in range(4)]
    d.polygon(pts, outline=255, width=w)
    # Glyphs in the outer band, and ticks around it.
    for i in range(28):
        ang = i * 2 * math.pi / 28
        r = 0.392 * S
        rune(d, c + r * math.cos(ang), c + r * math.sin(ang), 0.012 * S, rng, w)
    for i in range(96):
        ang = i * 2 * math.pi / 96
        r1, r2 = 0.445 * S, (0.462 if i % 4 == 0 else 0.453) * S
        d.line([(c + r1 * math.cos(ang), c + r1 * math.sin(ang)),
                (c + r2 * math.cos(ang), c + r2 * math.sin(ang))], fill=255, width=w)
    # Blueprint: a cross through the middle with measuring ticks, and arcs.
    for i in range(-20, 21):
        t = c + i * S * 0.024
        k = 0.012 if i % 5 == 0 else 0.006
        d.line([(t, c - k * S), (t, c + k * S)], fill=255, width=w // 2)
        d.line([(c - k * S, t), (c + k * S, t)], fill=255, width=w // 2)
    d.line([(0.02 * S, c), (0.98 * S, c)], fill=255, width=w // 2)
    d.line([(c, 0.02 * S), (c, 0.98 * S)], fill=255, width=w // 2)
    for r in (0.30, 0.40):
        d.arc([c - r * S * 1.6, c - r * S, c + r * S * 1.6, c + r * S], 200, 340, fill=255, width=w // 2)
    a = a.resize((n, n), Image.LANCZOS)
    # Fade out towards the edge so no square shows.
    yy, xx = np.mgrid[0:n, 0:n]
    rr = np.hypot(xx - n / 2 + 0.5, yy - n / 2 + 0.5) / (n / 2)
    fade = np.clip((1.0 - rr) / 0.12, 0, 1)
    alpha = (np.asarray(a, dtype=np.float32) * fade).astype(np.uint8)
    img = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    img.putalpha(Image.fromarray(alpha, "L"))
    save("cg-sigil", img)


# --------------------------------------------------------------------------
# Frame: a gold band for the window's edges (stretched along its length),
# and a corner piece with a scroll and a socket for a gem.
# --------------------------------------------------------------------------
def band_profile(h):
    """Colour rows across the band, outside (row 0) to inside."""
    rows = []
    for y in range(h):
        t = y / (h - 1)
        if t < 0.08 or t > 0.92:
            rows.append(INK + (255,))
        elif t < 0.55:
            k = (t - 0.08) / 0.47
            rows.append(gold_at(0.95 - 0.75 * k) + (255,))      # bevel: light to dark
        elif t < 0.64:
            rows.append((22, 15, 6, 255))                        # groove
        elif t < 0.80:
            rows.append(gold_at(0.62 - 0.3 * (t - 0.64) / 0.16) + (255,))
        else:
            rows.append((30, 22, 10, 230))
    return rows


def frame_band():
    w, h = 256, 32
    rows = band_profile(h)
    arr = np.zeros((h, w, 4), np.uint8)
    for y, c in enumerate(rows):
        arr[y, :, :] = c
    # A little wear along the length.
    grain = periodic_noise(w, 3, 9)[0]
    arr[..., :3] = np.clip(arr[..., :3].astype(np.float32) * (1 + 0.06 * grain[None, :, None]), 0, 255)
    img = Image.fromarray(arr, "RGBA")
    save("cg-frame-h", img)
    save("cg-frame-v", img.transpose(Image.ROTATE_90).transpose(Image.FLIP_TOP_BOTTOM))


def scroll(d, cx, cy, r, turns, width, fill):
    pts = []
    steps = 80
    for i in range(steps + 1):
        t = i / steps
        ang = t * turns * 2 * math.pi
        rad = r * (1 - 0.8 * t)
        pts.append((cx + rad * math.cos(ang), cy + rad * math.sin(ang)))
    d.line(pts, fill=fill, width=width, joint="curve")


def metal(mask, light_from=(-1, -1)):
    """Gives a white mask a gold bevel: light on one side, dark on the other."""
    m = np.asarray(mask, dtype=np.float32) / 255
    blur = gaussian_filter(m, 3)
    gy, gx = np.gradient(blur)
    shade = -(gx * light_from[0] + gy * light_from[1])
    shade = shade / (np.abs(shade).max() + 1e-9)
    t = np.clip(0.55 + 0.6 * shade, 0, 1)
    lo, mid, hi = np.array(GOLD_DEEP), np.array(GOLD), np.array(GOLD_HI)
    rgb = np.where(t[..., None] < 0.5, lo + (mid - lo) * (t[..., None] / 0.5),
                   mid + (hi - mid) * ((t[..., None] - 0.5) / 0.5))
    out = np.zeros(m.shape + (4,), np.uint8)
    out[..., :3] = rgb.astype(np.uint8)
    out[..., 3] = (m * 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def outline(img, width):
    """A dark outline under a shape, so it reads on any background."""
    a = img.split()[3].filter(ImageFilter.MaxFilter(width * 2 + 1))
    under = Image.new("RGBA", img.size, INK + (255,))
    under.putalpha(a)
    return Image.alpha_composite(under, img)


def corner():
    n = 128
    S = n * SS
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    u = SS
    # An L of two bars along the outer edges, thicker at the corner.
    d.rectangle([4 * u, 4 * u, 124 * u, 18 * u], fill=255)
    d.rectangle([4 * u, 4 * u, 18 * u, 124 * u], fill=255)
    d.polygon([(4 * u, 4 * u), (58 * u, 4 * u), (4 * u, 58 * u)], fill=255)
    # Scrolls curling inwards along each bar.
    scroll(d, 74 * u, 30 * u, 14 * u, 1.3, 4 * u, 255)
    scroll(d, 30 * u, 74 * u, 14 * u, -1.3, 4 * u, 255)
    d.line([(18 * u, 22 * u), (100 * u, 22 * u)], fill=255, width=3 * u)
    d.line([(22 * u, 18 * u), (22 * u, 100 * u)], fill=255, width=3 * u)
    # The gem's socket.
    d.ellipse([12 * u, 12 * u, 52 * u, 52 * u], fill=255)
    img = metal(m)
    # Hollow of the socket, dark, for the gem to sit in.
    hole = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hole).ellipse([17 * u, 17 * u, 47 * u, 47 * u], fill=255)
    dark = Image.new("RGBA", (S, S), (14, 9, 4, 255))
    img.paste(dark, (0, 0), hole)
    img = outline(shrink(img, n, n), 1)
    save("cg-corner", img)


def gem():
    n = 32
    S = n * SS
    yy, xx = np.mgrid[0:S, 0:S] / S
    r = np.hypot(xx - 0.5, yy - 0.5) / 0.5
    body = np.clip(1 - r, 0, 1) > 0
    light = np.clip(1 - np.hypot(xx - 0.38, yy - 0.36) / 0.55, 0, 1)
    v = 0.35 + 0.65 * light
    arr = np.zeros((S, S, 4), np.float32)
    arr[..., :3] = (v * 255)[..., None]
    # A sharp white glint.
    glint = np.clip(1 - np.hypot(xx - 0.36, yy - 0.32) / 0.12, 0, 1) ** 2
    arr[..., :3] = np.clip(arr[..., :3] + glint[..., None] * 255, 0, 255)
    arr[..., 3] = body * 255
    img = shrink(Image.fromarray(arr.astype(np.uint8), "RGBA"), n, n)
    save("cg-gem", img)


# --------------------------------------------------------------------------
# Title plaque: a dark plate in a double gold frame with pointed ends and
# wings.
# --------------------------------------------------------------------------
def plaque():
    w, h = 512, 128
    S = SS
    m = Image.new("L", (w * S, h * S), 0)
    d = ImageDraw.Draw(m)

    def plate(x0, y0, x1, y1, point):
        cy = (y0 + y1) / 2
        return [(x0 + point, y0), (x1 - point, y0), (x1, cy), (x1 - point, y1), (x0 + point, y1), (x0, cy)]

    outer = [(x * S, y * S) for x, y in plate(96, 22, 416, 106, 22)]
    d.polygon(outer, fill=255)
    # Wings: swept scrolls on both sides.
    for side in (-1, 1):
        cx = 256 + side * 178
        scroll(d, cx * S, 64 * S, 26 * S, 1.15 * side, 6 * S, 255)
        d.line([((256 + side * 150) * S, 40 * S), ((256 + side * 236) * S, 22 * S)], fill=255, width=5 * S)
        d.line([((256 + side * 150) * S, 88 * S), ((256 + side * 226) * S, 104 * S)], fill=255, width=4 * S)
        # A crest on top of the plate.
    d.polygon([(232 * S, 24 * S), (256 * S, 4 * S), (280 * S, 24 * S)], fill=255)
    img = metal(m, (-0.4, -1))
    # The dark face, inside a second thin gold line.
    face = Image.new("L", (w * S, h * S), 0)
    ImageDraw.Draw(face).polygon([(x * S, y * S) for x, y in plate(106, 32, 406, 96, 16)], fill=255)
    inner = Image.new("L", (w * S, h * S), 0)
    ImageDraw.Draw(inner).polygon([(x * S, y * S) for x, y in plate(110, 36, 402, 92, 14)], fill=255)
    yy = np.linspace(0, 1, h * S)[:, None]
    shade = np.repeat((22 + 26 * (1 - yy)), w * S, axis=1)
    facecol = np.zeros((h * S, w * S, 4), np.uint8)
    facecol[..., 0] = np.clip(shade * 1.05, 0, 255)
    facecol[..., 1] = np.clip(shade * 0.92, 0, 255)
    facecol[..., 2] = np.clip(shade * 0.75, 0, 255)
    facecol[..., 3] = 255
    face_img = Image.fromarray(facecol, "RGBA")
    ring = Image.new("RGBA", (w * S, h * S), GOLD_LO + (255,))
    img.paste(ring, (0, 0), face)
    img.paste(face_img, (0, 0), inner)
    img = outline(shrink(img, w, h), 1)
    save("cg-plaque", img)


# --------------------------------------------------------------------------
# Buttons: a gold-rimmed dark plate (three slices: caps and a middle that
# stretches), a lit gold one for the page in view, and a glow for hover.
# --------------------------------------------------------------------------
def button(name, top, bottom, rim_light=0.9):
    w, h = 256, 64
    S = SS
    m = Image.new("L", (w * S, h * S), 0)
    ImageDraw.Draw(m).rounded_rectangle([2 * S, 3 * S, 253 * S, 60 * S], radius=12 * S, fill=255)
    img = metal(m, (-0.3, -1))
    inner = Image.new("L", (w * S, h * S), 0)
    ImageDraw.Draw(inner).rounded_rectangle([9 * S, 10 * S, 246 * S, 53 * S], radius=8 * S, fill=255)
    yy = np.linspace(0, 1, h * S)[:, None, None]
    face = np.array(top)[None, None, :] * (1 - yy) + np.array(bottom)[None, None, :] * yy
    face = np.repeat(face, w * S, axis=1)
    arr = np.zeros((h * S, w * S, 4), np.uint8)
    arr[..., :3] = np.clip(face, 0, 255)
    arr[..., 3] = 255
    face_img = Image.fromarray(arr, "RGBA")
    img.paste(face_img, (0, 0), inner)
    # A soft shine on the upper half of the face.
    shine = Image.new("L", (w * S, h * S), 0)
    ImageDraw.Draw(shine).rounded_rectangle([12 * S, 12 * S, 243 * S, 30 * S], radius=6 * S, fill=int(38 * rim_light))
    shine = shine.filter(ImageFilter.GaussianBlur(3 * S))
    white = Image.new("RGBA", (w * S, h * S), (255, 240, 210, 255))
    white.putalpha(shine)
    img = Image.alpha_composite(img, white)
    save(name, outline(shrink(img, w, h), 1))


def button_glow():
    w, h = 256, 64
    a = Image.new("L", (w, h), 0)
    ImageDraw.Draw(a).rounded_rectangle([12, 12, 243, 51], radius=8, fill=150)
    a = a.filter(ImageFilter.GaussianBlur(6))
    img = Image.new("RGBA", (w, h), (255, 220, 140, 0))
    img.putalpha(a)
    save("cg-button-hl", img)


# --------------------------------------------------------------------------
# Icon frame: a bevelled square ring with a diamond above and below, drawn
# light grey so the game tints it with the item's quality colour.
# --------------------------------------------------------------------------
def iconframe():
    n = 64
    S = n * SS
    u = SS
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([7 * u, 7 * u, 57 * u, 57 * u], radius=4 * u, fill=255)
    d.polygon([(32 * u, 0), (39 * u, 7 * u), (32 * u, 14 * u), (25 * u, 7 * u)], fill=255)
    d.polygon([(32 * u, 64 * u), (39 * u, 57 * u), (32 * u, 50 * u), (25 * u, 57 * u)], fill=255)
    hole = Image.new("L", (S, S), 0)
    ImageDraw.Draw(hole).rectangle([11 * u, 11 * u, 53 * u, 53 * u], fill=255)
    arr = np.asarray(m, dtype=np.float32) - np.asarray(hole, dtype=np.float32)
    mask = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "L")
    blur = gaussian_filter(np.asarray(mask, dtype=np.float32) / 255, 2.5 * u / 4)
    gy, gx = np.gradient(blur)
    shade = np.clip(0.75 + 4 * (-gx - gy), 0.35, 1)
    out = np.zeros((S, S, 4), np.uint8)
    out[..., :3] = (shade * 255)[..., None]
    out[..., 3] = np.asarray(mask)
    img = outline(shrink(Image.fromarray(out, "RGBA"), n, n), 1)
    save("cg-iconframe", img)


def glow():
    w, h = 256, 128
    a = Image.new("L", (w, h), 0)
    ImageDraw.Draw(a).rounded_rectangle([28, 28, 227, 99], radius=10, outline=255, width=10)
    a = a.filter(ImageFilter.GaussianBlur(9))
    arr = np.asarray(a, dtype=np.float32)
    arr = (arr / max(arr.max(), 1) * 255).astype(np.uint8)
    img = Image.new("RGBA", (w, h), (255, 255, 255, 0))
    img.putalpha(Image.fromarray(arr, "L"))
    save("cg-glow", img)


def emblem():
    """The round medallion at the top left: a gold ring around a hole for
    the addon's coin icon."""
    n = 128
    S = n * SS
    u = SS
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.ellipse([6 * u, 6 * u, 122 * u, 122 * u], fill=255)
    d.ellipse([22 * u, 22 * u, 106 * u, 106 * u], fill=0)
    for i in range(8):
        ang = i * math.pi / 4
        cx, cy = 64 + 58 * math.cos(ang), 64 + 58 * math.sin(ang)
        d.ellipse([(cx - 5) * u, (cy - 5) * u, (cx + 5) * u, (cy + 5) * u], fill=255)
    img = metal(m)
    img = outline(shrink(img, n, n), 1)
    save("cg-emblem", img)


def main():
    ICONS.mkdir(exist_ok=True)
    stone()
    sigil()
    frame_band()
    corner()
    gem()
    plaque()
    button("cg-button", (52, 40, 24), (18, 13, 8))
    button("cg-button-lit", (176, 124, 38), (96, 58, 14), 1.4)
    button_glow()
    iconframe()
    glow()
    emblem()
    lines = ["-- Written by make_textures.py: the pixel size of each texture.", "return {"]
    for name in sorted(sizes):
        lines.append('  ["%s"] = { %d, %d },' % (name, *sizes[name]))
    lines.append("}")
    (ICONS / "sizes.lua").write_text("\n".join(lines) + "\n")
    print("wrote", len(sizes), "textures to", MEDIA)


if __name__ == "__main__":
    main()
