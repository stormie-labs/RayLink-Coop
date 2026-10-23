"""Anomaly Coop co-op window (gamedata\\scripts\\coop_menu.script, ui_coop_menu.xml): the procedural icon atlas.

One 128x128 atlas, written as an uncompressed DDS A8R8G8B8 (BGRA bytes) without mips, the same layout as
tools\\make_hud_atlas.py (HUD v2) and the stock UI DDS, plus its textures_descr ids:
  row 0: four 32x32 white glyphs, tinted by the layout / the script (no outline: they sit on flat dark tiles)
      coop_menu_ico_play    a right-pointing triangle  (tile "New game")
      coop_menu_ico_again   a circular arrow           (tile "Continue")
      coop_menu_ico_folder  an open folder outline     (tile "Load...")
      coop_menu_dot         a disc                     (status indicator)
  row 1: four 8x8 flat cells, the id is the middle 4x4 so bilinear filtering never reaches a neighbour
      coop_menu_white       solid white: every flat rectangle of the window is this cell stretched and tinted
      coop_menu_hit_e / _d  fully transparent: a button at rest / disabled (the 3-state button reads _e _d _t _h)
      coop_menu_hit_h       white at 9 % alpha: the cursor is over the button
      coop_menu_hit_t       white at 18 % alpha: the button is pressed
Every glyph is drawn at 4x and box-downsampled with premultiplied alpha (no dark or light fringes).

Usage: python tools/make_menu_icons.py [--gamedata DIR] [--preview PNG]
  writes DIR/textures/ui/coop/ui_coop_menu.dds and DIR/configs/ui/textures_descr/ui_coop_menu.xml
  (default DIR: gamedata next to tools), and a 6x preview on a dark checker when --preview is given.
No external generators, no network: Pillow only.
"""
import argparse
import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

SS = 4  # supersampling
CELL = 32  # glyph cell, px
ATLAS = 128
FLAT = 8  # flat cell, px
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


def again():  # a circular arrow, clockwise, open at the upper right
    r_mid, thick = 0.54, 0.27
    r_out, r_in = r_mid + thick / 2, r_mid - thick / 2
    gap_from, gap_to = -62.0, 18.0  # the gap, degrees, y down: -90 is the top, 0 the right, 90 the bottom
    body = ring(0, 0, r_out, r_in)
    wedge = poly([(0, 0), polar(gap_from, 2.0), polar((gap_from + gap_to) / 2, 2.0), polar(gap_to, 2.0)])
    body = cut(body, wedge)
    # the arrow head: its base across the ring where the arc ends (upper right), its tip further on, inside the gap
    base = gap_from - 2
    head = poly([polar(base, r_mid + 0.40), polar(base, r_mid - 0.40), polar(gap_from + 44, r_mid + 0.04)])
    return white_glyph(union(body, head))


def folder():  # an open folder: outline with a tab at the top left
    t = 0.17
    x0, x1, y0, y1 = -0.90, 0.90, -0.36, 0.70
    tab = rect(x0, -0.66, -0.12, y0 + 0.02, radius=0.06)
    outer = union(rect(x0, y0, x1, y1, radius=0.08), tab)
    inner = rect(x0 + t, y0 + t, x1 - t, y1 - t)
    return white_glyph(cut(outer, inner))


def dot():
    return white_glyph(disc(0, 0, 0.92))


def flat(alpha, n=FLAT):
    return Image.new("RGBA", (n, n), (255, 255, 255, alpha))


# id: (image maker, x, y, id rect inside the cell: (dx, dy, w, h))
GLYPHS = [
    ("coop_menu_ico_play", play, 0, 0),
    ("coop_menu_ico_again", again, 32, 0),
    ("coop_menu_ico_folder", folder, 64, 0),
    ("coop_menu_dot", dot, 96, 0),
]
# flat cells: id, alpha, x, y; the id is the middle 4x4 of the 8x8 cell
FLATS = [
    ("coop_menu_white", 255, 0, 32),
    ("coop_menu_hit_e", 0, 8, 32),
    ("coop_menu_hit_h", 23, 16, 32),
    ("coop_menu_hit_t", 46, 24, 32),
]
# the disabled state shares the transparent cell of the rest state
ALIASES = [("coop_menu_hit_d", "coop_menu_hit_e")]


def build():
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    ids = []
    for tid, maker, x, y in GLYPHS:
        img = maker()
        assert img.size == (CELL, CELL), tid
        atlas.paste(img, (x, y))
        ids.append((tid, x, y, CELL, CELL))
    cells = {}
    for tid, alpha, x, y in FLATS:
        atlas.paste(flat(alpha), (x, y))
        cells[tid] = (x + 2, y + 2, 4, 4)
        ids.append((tid,) + cells[tid])
    for tid, same in ALIASES:
        ids.append((tid,) + cells[same])
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
        "<!-- Anomaly Coop: icon atlas textures\\ui\\coop\\ui_coop_menu.dds, 128x128 A8R8G8B8, no mips, of the co-op window",
        "     (scripts\\coop_menu.script, configs\\ui\\ui_coop_menu.xml). Generated by tools\\make_menu_icons.py (procedural,",
        "     Pillow). White glyphs, tinted by the layout and the script; coop_menu_white is a solid white cell that every flat",
        "     rectangle of the window stretches; coop_menu_hit_e/_d/_h/_t are the four states of the transparent hit buttons",
        "     (CUI3tButton reads _e _d _t _h: _h is the cursor over, _t is pressed). -->",
        "<w>",
        '\t<file name="ui\\coop\\ui_coop_menu">',
    ]
    for tid, x, y, w, h in ids:
        lines.append('\t\t<texture id="%s" x="%d" y="%d" width="%d" height="%d"/>' % (tid, x, y, w, h))
    lines += ["\t</file>", "</w>"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("cp1251"))


def write_preview(atlas, path, scale=6):
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
