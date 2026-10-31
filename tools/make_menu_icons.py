"""Anomaly Coop co-op window (gamedata\\scripts\\coop_menu.script, ui_coop_chronicle.xml): the procedural atlas.

One 512x256 atlas, written as an uncompressed DDS A8R8G8B8 (BGRA bytes) without mips, the same layout as
tools\\make_hud_atlas.py (HUD v2) and the stock UI DDS, plus its textures_descr ids. Everything is white, tinted by the
script out of the theme; the shape is here, the colour never.
  row 0: 32x32 glyphs (no outline: they sit on flat dark surfaces)
      coop_menu_ico_play    a right-pointing triangle  (Play)
      coop_menu_ico_history a clock with a turning arrow (the saves of a game)
      coop_menu_ico_gear    a gear                     (settings of a game)
      coop_menu_dot         a disc                     (status, the bullets of the timeline)
      coop_menu_diamond / _f  a stop of the route: the outline and the fill
      coop_menu_notch       a triangle: the cut corner of a button
      coop_menu_chevron     a small arrow down         (the recent addresses)
  row 1: 8x8 flat cells, the id is the middle 4x4 so bilinear filtering never reaches a neighbour
      coop_menu_white       solid white: every flat rectangle of the window is this cell stretched and tinted
      coop_menu_hit_e / _d  fully transparent: a button at rest / disabled (the 3-state button reads _e _d _t _h)
      coop_menu_hit_h       white at 9 % alpha: the cursor is over the button
      coop_menu_hit_t       white at 18 % alpha: the button is pressed
      coop_menu_none_e/_d/_t/_h  fully transparent in every state: a button that only stops clicks
  below: coop_menu_route_dot (a dot of the route with a soft dark halo: the halo stays dark under any tint),
      coop_menu_box (a dashed square), coop_menu_ring (a thin ring)
  strips: the gradients of the prototype's shades as alpha over white (X-Ray has no gradient), stretched over the screen
      coop_menu_shade_base_h / _v, coop_menu_shade_open_h / _v, coop_menu_strip_cap, coop_menu_strip_line
Every glyph is drawn at 4x and box-downsampled with premultiplied alpha (no dark or light fringes).

Usage: python tools/make_menu_icons.py [--gamedata DIR] [--preview PNG]
  writes DIR/textures/ui/coop/ui_coop_menu.dds and DIR/configs/ui/textures_descr/ui_coop_menu.xml
  (default DIR: gamedata next to tools), and a 3x preview on a dark checker when --preview is given.
No external generators, no network: Pillow only.
"""
import argparse
import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

SS = 4  # supersampling
CELL = 32  # glyph cell, px
ATLAS_W, ATLAS_H = 512, 256
FLAT = 8  # flat cell, px
STRIP = 8  # thickness of a gradient strip, px; the id is its middle 4
ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- masks in -1..1 space (y down), drawn at CELL * SS
def canvas(n=CELL):
    return Image.new("L", (n * SS, n * SS), 0)


def to_px(n, x, y):
    c = n * SS / 2
    return (c + x * c, c + y * c)


def poly(pts, n=CELL):
    m = canvas(n)
    ImageDraw.Draw(m).polygon([to_px(n, x, y) for x, y in pts], fill=255)
    return m


def disc(cx, cy, r, n=CELL):
    m = canvas(n)
    x0, y0 = to_px(n, cx - r, cy - r)
    x1, y1 = to_px(n, cx + r, cy + r)
    ImageDraw.Draw(m).ellipse([x0, y0, x1, y1], fill=255)
    return m


def rect(x0, y0, x1, y1, n=CELL, radius=0.0):
    m = canvas(n)
    a, b = to_px(n, x0, y0), to_px(n, x1, y1)
    if radius > 0:
        ImageDraw.Draw(m).rounded_rectangle([a, b], radius=radius * n * SS / 2, fill=255)
    else:
        ImageDraw.Draw(m).rectangle([a, b], fill=255)
    return m


def union(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = ImageChops.lighter(out, m)
    return out


def cut(a, b):
    return ImageChops.subtract(a, b)


def ring(cx, cy, r_out, r_in, n=CELL):
    return cut(disc(cx, cy, r_out, n), disc(cx, cy, r_in, n))


def polar(angle_deg, r):
    a = math.radians(angle_deg)
    return (r * math.cos(a), r * math.sin(a))


# ---------------------------------------------------------------- white glyph -> RGBA, box-downsampled
def white_glyph(shape):
    big = Image.new("RGBA", shape.size, (255, 255, 255, 0))
    big.putalpha(shape)
    r, g, b, a = big.split()
    pre = [ImageChops.multiply(c, a) for c in (r, g, b)] + [a]
    small = [c.reduce(SS) for c in pre]
    w, h = small[3].size
    out = Image.new("RGBA", (w, h))
    px = out.load()
    R, G, B, A = (c.load() for c in small)
    for y in range(h):
        for x in range(w):
            al = A[x, y]
            if al == 0:
                px[x, y] = (0, 0, 0, 0)
            else:
                px[x, y] = tuple(min(255, int(round(c[x, y] * 255 / al))) for c in (R, G, B)) + (al,)
    return out


# ---------------------------------------------------------------- the glyphs
def play():  # a right-pointing triangle, a touch left of centre so its centre of mass sits in the middle
    return white_glyph(poly([(-0.58, -0.82), (0.84, 0.0), (-0.58, 0.82)]))


def grid_px(n, x, y):
    """A point of the prototype's 24-unit icon grid at the supersampled cell."""
    k = n * SS / 24.0
    return (x * k, y * k)


def history():  # the prototype's icon: an arc with an arrow head at its start, the hands of a clock
    m = canvas()
    d = ImageDraw.Draw(m)
    w = int(round(1.7 * CELL * SS / 24.0))
    x0, y0 = grid_px(CELL, 3.5, 3.5)
    x1, y1 = grid_px(CELL, 20.5, 20.5)
    d.arc([x0, y0, x1, y1], 225, 540, fill=255, width=w)
    for line in ([(3, 4.5), (3, 8.7), (7.2, 8.7)], [(12, 7.5), (12, 12), (15, 14)]):
        d.line([grid_px(CELL, x, y) for x, y in line], fill=255, width=w, joint="curve")
    return white_glyph(m)


def gear():  # eight teeth in outline around a small ring
    m = canvas()
    d = ImageDraw.Draw(m)
    w = int(round(1.7 * CELL * SS / 24.0))
    pts = []
    teeth = 8
    for i in range(teeth):
        a = i * 360.0 / teeth
        for da, r in ((-15, 0.66), (-9, 0.92), (9, 0.92), (15, 0.66)):
            x, y = polar(a + da, r)
            pts.append(to_px(CELL, x, y))
    d.line(pts + pts[:2], fill=255, width=w, joint="curve")
    return white_glyph(union(m, ring(0, 0, 0.36, 0.36 - 1.7 * 2 / 24.0)))


def dot():
    return white_glyph(disc(0, 0, 0.92))


def diamond():  # the outline of a square turned by 45 degrees, its corners touch the cell
    outer = poly([(0, -0.98), (0.98, 0), (0, 0.98), (-0.98, 0)])
    inner = poly([(0, -0.74), (0.74, 0), (0, 0.74), (-0.74, 0)])
    return white_glyph(cut(outer, inner))


def diamond_fill():
    return white_glyph(poly([(0, -0.8), (0.8, 0), (0, 0.8), (-0.8, 0)]))


def notch():  # the upper left half of the cell: a button's cut corner at its lower right
    return white_glyph(poly([(-1, -1), (1, -1), (-1, 1)]))


def chevron():
    m = canvas()
    d = ImageDraw.Draw(m)
    d.line([to_px(CELL, -0.6, -0.25), to_px(CELL, 0, 0.35), to_px(CELL, 0.6, -0.25)], fill=255, width=int(0.2 * CELL * SS / 2), joint="curve")
    return white_glyph(m)


def box(n=64):  # a dashed square, one line of about 1.3 px at the size it is drawn
    m = canvas(n)
    d = ImageDraw.Draw(m)
    s = n * SS
    w = int(1.6 * SS)
    dash, gap = 5 * SS, 4 * SS
    for a in range(0, s, dash + gap):
        for x0, y0, x1, y1 in ((a, 0, a + dash, w), (a, s - w, a + dash, s), (0, a, w, a + dash), (s - w, a, s, a + dash)):
            d.rectangle([x0, y0, x1, y1], fill=255)
    return white_glyph(m)


def ring_glyph(n=96):
    m = canvas(n)
    d = ImageDraw.Draw(m)
    d.ellipse([SS, SS, n * SS - SS, n * SS - SS], outline=255, width=int(1.6 * SS))
    return white_glyph(m)


def route_dot(n=32):
    """A white core and a soft black halo in one cell: the tint colours the core, black stays black."""
    img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = img.load()
    c = (n - 1) / 2.0
    core, halo = n * 3.0 / 32.0, n * 0.48
    for y in range(n):
        for x in range(n):
            r = math.hypot(x - c, y - c)
            a_core = max(0.0, min(1.0, core + 0.5 - r))
            a_halo = max(0.0, 1.0 - r / halo) ** 1.6 * 0.95
            a = a_core + a_halo * (1.0 - a_core)
            v = int(round(255 * a_core / a)) if a > 0 else 0
            px[x, y] = (v, v, v, int(round(255 * a)))
    return img


def soft(n=32):
    """A white disc that fades to nothing: a spark and its glow, tinted by the theme."""
    img = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    px = img.load()
    c = (n - 1) / 2.0
    for y in range(n):
        for x in range(n):
            r = math.hypot(x - c, y - c) / (n * 0.5)
            a = max(0.0, 1.0 - r) ** 2.2
            px[x, y] = (255, 255, 255, int(round(255 * a)))
    return img


def gradient(stops, n=256):
    """Alpha 0..255 of a list of (position 0..1, alpha 0..1), piecewise linear like a css gradient."""
    out = []
    for i in range(n):
        t = i / (n - 1.0)
        a = stops[-1][1]
        for (p0, a0), (p1, a1) in zip(stops, stops[1:]):
            if t <= p1:
                a = a0 + (a1 - a0) * (t - p0) / max(p1 - p0, 1e-9)
                break
        out.append(int(round(a * 255)))
    return out


def flat(alpha, n=FLAT):
    return Image.new("RGBA", (n, n), (255, 255, 255, alpha))


# id: (image maker, x, y): the id is the whole cell
GLYPHS = [
    ("coop_menu_ico_play", play, 0, 0),
    ("coop_menu_ico_history", history, 32, 0),
    ("coop_menu_ico_gear", gear, 64, 0),
    ("coop_menu_dot", dot, 96, 0),
    ("coop_menu_diamond", diamond, 128, 0),
    ("coop_menu_diamond_f", diamond_fill, 160, 0),
    ("coop_menu_notch", notch, 192, 0),
    ("coop_menu_chevron", chevron, 224, 0),
    ("coop_menu_route_dot", route_dot, 0, 48),
    ("coop_menu_box", box, 32, 48),
    ("coop_menu_ring", ring_glyph, 96, 48),
    ("coop_menu_soft", soft, 192, 48),
]
# flat cells: id, alpha, x, y; the id is the middle 4x4 of the 8x8 cell
FLATS = [
    ("coop_menu_white", 255, 0, 32),
    ("coop_menu_hit_e", 0, 8, 32),
    ("coop_menu_hit_h", 23, 16, 32),
    ("coop_menu_hit_t", 46, 24, 32),
]
# the disabled state shares the transparent cell of the rest state; the invisible button is that cell in all four states
ALIASES = [("coop_menu_hit_d", "coop_menu_hit_e"), ("coop_menu_none_e", "coop_menu_hit_e"), ("coop_menu_none_d", "coop_menu_hit_e"),
           ("coop_menu_none_t", "coop_menu_hit_e"), ("coop_menu_none_h", "coop_menu_hit_e")]
# the prototype's gradients (d.css): (position, alpha)
BASE_H = [(0, .97), (.22, .9), (.46, .28), (.62, 0), (1, 0)]
BASE_V = [(0, .22), (.46, 0), (.82, .8), (1, .97)]
OPEN_H = [(0, .98), (.21, .94), (.29, .08), (.63, 0), (.695, .92), (1, .98)]
OPEN_V = [(0, .3), (.14, 0), (.6, 0), (.84, .9), (1, .98)]
CAP_V = [(0, 0), (1, .94)]
LINE_V = [(0, 1), (.45, .55), (1, .14)]
# the main menu (menu.css, concept 1) and the ramps a picture is feathered with
MM_H = [(0, .96), (.24, .84), (.52, .18), (.7, 0), (1, 0)]
MM_V = [(0, .3), (.34, 0), (1, .55)]
RAMP_A = [(0, 1), (1, 0)]
RAMP_B = [(0, 0), (1, 1)]
# horizontal strips, 256 wide, in the lower left of the atlas: id, stops, y
STRIPS_H = [("coop_menu_shade_base_h", BASE_H, 144), ("coop_menu_shade_open_h", OPEN_H, 152), ("coop_menu_shade_mm_h", MM_H, 160),
            ("coop_menu_ramp_l", RAMP_A, 168), ("coop_menu_ramp_r", RAMP_B, 176)]
# vertical strips, 256 tall, in the right half of the atlas: id, stops, x
STRIPS_V = [("coop_menu_shade_base_v", BASE_V, 256), ("coop_menu_shade_open_v", OPEN_V, 264), ("coop_menu_strip_cap", CAP_V, 272),
            ("coop_menu_strip_line", LINE_V, 280), ("coop_menu_shade_mm_v", MM_V, 288), ("coop_menu_ramp_t", RAMP_A, 296),
            ("coop_menu_ramp_b", RAMP_B, 304)]


def build():
    atlas = Image.new("RGBA", (ATLAS_W, ATLAS_H), (0, 0, 0, 0))
    ids = []
    for tid, maker, x, y in GLYPHS:
        img = maker()
        atlas.paste(img, (x, y))
        ids.append((tid, x, y) + img.size)
    cells = {}
    for tid, alpha, x, y in FLATS:
        atlas.paste(flat(alpha), (x, y))
        cells[tid] = (x + 2, y + 2, 4, 4)
        ids.append((tid,) + cells[tid])
    for tid, same in ALIASES:
        ids.append((tid,) + cells[same])
    px = atlas.load()
    for tid, stops, y in STRIPS_H:
        for x, a in enumerate(gradient(stops)):
            for j in range(STRIP):
                px[x, y + j] = (255, 255, 255, a)
        ids.append((tid, 0, y + 2, 256, 4))
    for tid, stops, x in STRIPS_V:
        for y, a in enumerate(gradient(stops)):
            for j in range(STRIP):
                px[x + j, y] = (255, 255, 255, a)
        ids.append((tid, x + 2, 0, 4, 256))
    return atlas, ids


def write_dds_argb(img, path):
    """DDS A8R8G8B8 (masks R 0xFF0000 / G 0xFF00 / B 0xFF / A 0xFF000000), one level: BGRA bytes."""
    w, h = img.size
    hdr = struct.pack("<4s7I", b"DDS ", 124, 0x100F, h, w, w * 4, 0, 1)
    hdr += b"\0" * 44
    hdr += struct.pack("<2I4s5I", 32, 0x41, b"\0\0\0\0", 32, 0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    hdr += struct.pack("<4I", 0x1000, 0, 0, 0) + b"\0" * 4
    assert len(hdr) == 128
    r, g, b, a = img.split()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(hdr + Image.merge("RGBA", (b, g, r, a)).tobytes())


def write_descr(ids, path):
    lines = [
        '<?xml version="1.0" encoding="windows-1251"?>',
        "<!-- Anomaly Coop: atlas textures\\ui\\coop\\ui_coop_menu.dds, 512x256 A8R8G8B8, no mips, of the co-op window",
        "     (scripts\\coop_menu.script, configs\\ui\\ui_coop_chronicle.xml). Generated by tools\\make_menu_icons.py (procedural,",
        "     Pillow). White shapes, tinted by the script out of the theme; coop_menu_white is a solid white cell that every flat",
        "     rectangle of the window stretches; coop_menu_hit_e/_d/_h/_t are the four states of the transparent hit buttons",
        "     (CUI3tButton reads _e _d _t _h: _h is the cursor over, _t is pressed), coop_menu_none_* a button never seen;",
        "     coop_menu_shade_* and coop_menu_strip_* are gradients as alpha, stretched over the screen. -->",
        "<w>",
        '\t<file name="ui\\coop\\ui_coop_menu">',
    ]
    for tid, x, y, w, h in ids:
        lines.append('\t\t<texture id="%s" x="%d" y="%d" width="%d" height="%d"/>' % (tid, x, y, w, h))
    lines += ["\t</file>", "</w>"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("cp1251"))


def write_preview(atlas, path, scale=3):
    w, h = atlas.size
    bg = Image.new("RGBA", (w, h), (24, 24, 23, 255))
    d = ImageDraw.Draw(bg)
    for y in range(0, h, 8):
        for x in range(0, w, 8):
            if (x // 8 + y // 8) % 2:
                d.rectangle([x, y, x + 7, y + 7], fill=(38, 38, 36, 255))
    sand = (217, 177, 96)  # the colour of the window's accent, to see the glyphs as they are used
    a = atlas.split()[3]
    tinted = Image.merge("RGBA", (*(Image.new("L", (w, h), c) for c in sand), a))
    out = Image.alpha_composite(bg, tinted).resize((w * scale, h * scale), Image.NEAREST)
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--gamedata", type=Path, default=ROOT / "gamedata")
    ap.add_argument("--preview", type=Path, default=None)
    args = ap.parse_args()
    atlas, ids = build()
    dds = args.gamedata / "textures" / "ui" / "coop" / "ui_coop_menu.dds"
    descr = args.gamedata / "configs" / "ui" / "textures_descr" / "ui_coop_menu.xml"
    write_dds_argb(atlas, dds)
    write_descr(ids, descr)
    if args.preview:
        write_preview(atlas, args.preview)
    print("%s (%d bytes), %s (%d ids)" % (dds, dds.stat().st_size, descr, len(ids)))


if __name__ == "__main__":
    main()
