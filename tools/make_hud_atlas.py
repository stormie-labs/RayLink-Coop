"""Anomaly Coop HUD v2 (docs/HUD_V2.md, Ассеты): the procedural icon atlas of the compass bar, the team cards and the ping.

Every glyph is drawn at 4x (SS) as a white shape with a dark outline (OUTLINE_PX of the cell, ~1 screen pixel at the
sizes the HUD draws them), flat, no glow, and box-downsampled with premultiplied alpha (no dark or light fringes). The
HUD tints the white with the marker's colour; the outline stays dark. Two horizontal gradients (the bar's background
and its lines) carry the fade of the last 16 % of the width at each end; a solid white cell serves plates, ticks and
bars. One 256x256 atlas, written as an uncompressed DDS A8R8G8B8 (BGRA bytes) without mips, the layout of the stock UI
DDS of the stand and of W6's ui_coop_allies.dds, plus its textures_descr ids.

Usage: python tools/make_hud_atlas.py [--gamedata DIR] [--preview PNG]
  writes DIR/textures/ui/coop/ui_coop_hud.dds and DIR/configs/ui/textures_descr/ui_coop_hud.xml
  (default DIR: gamedata next to tools), and a 4x preview on a grey checker when --preview is given.
No external generators, no network: Pillow only.
"""
import argparse
import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # supersampling
CELL = 32  # glyph cell, px
OUTLINE_PX = 1.8  # of a 32 px cell: ~1 px at the 14-20 px the HUD draws a glyph
OUTLINE_RGB = (16, 17, 14)
OUTLINE_ALPHA = 235
ATLAS = 256
FADE_PART = 0.16  # the bar fades out over the last 16 % of its width at each end

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


def ellipse(cx, cy, rx, ry, n=CELL):
    m = canvas(n)
    x0, y0 = to_px(n, cx - rx, cy - ry)
    x1, y1 = to_px(n, cx + rx, cy + ry)
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


def rot_rect(cx, cy, length, width, angle_deg, n=CELL):
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), math.sin(a)
    vx, vy = -uy, ux
    hl, hw = length / 2, width / 2
    pts = [(cx + ux * hl * sx + vx * hw * sy, cy + uy * hl * sx + vy * hw * sy) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    return poly(pts, n)


def union(*ms):
    out = ms[0]
    for m in ms[1:]:
        out = ImageChops.lighter(out, m)
    return out


def cut(a, b):
    return ImageChops.subtract(a, b)


def dilate(m, px):
    r = int(round(px * SS))
    return m.filter(ImageFilter.MaxFilter(2 * r + 1)) if r > 0 else m


def ring(cx, cy, r_out, r_in, n=CELL):
    return cut(disc(cx, cy, r_out, n), disc(cx, cy, r_in, n))


# ---------------------------------------------------------------- compose and downsample
def layer(big, mask, rgb, alpha=255):
    lay = Image.new("RGBA", big.size, rgb + (0,))
    lay.putalpha(mask.point(lambda v: v * alpha // 255))
    return Image.alpha_composite(big, lay)


def glyph(shape, dark=None, outline=True, n=CELL):
    """White `shape` over a dark outline; `dark` (a mask inside the shape) is painted in the outline colour on top."""
    big = Image.new("RGBA", (n * SS, n * SS), (0, 0, 0, 0))
    if outline:
        big = layer(big, dilate(shape, OUTLINE_PX), OUTLINE_RGB, OUTLINE_ALPHA)
    big = layer(big, shape, (255, 255, 255))
    if dark is not None:
        big = layer(big, dark, OUTLINE_RGB, OUTLINE_ALPHA)
    return downsample(big)


def downsample(big):
    """premultiply -> box average SS x SS -> unpremultiply."""
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
def chevron():  # ally: a chevron pointing down (the mockup's triangle)
    return glyph(poly([(-0.80, -0.52), (0.80, -0.52), (0.0, 0.64)]))


def down():  # downed ally: ring with a cross
    cross = union(rect(-0.13, -0.42, 0.13, 0.42), rect(-0.42, -0.13, 0.42, 0.13))
    return glyph(union(ring(0, 0, 0.84, 0.60), cross))


def diamond():
    return glyph(poly([(0, -0.84), (0.84, 0), (0, 0.84), (-0.84, 0)]))


def diamond_hollow():
    outer = poly([(0, -0.84), (0.84, 0), (0, 0.84), (-0.84, 0)])
    inner = poly([(0, -0.50), (0.50, 0), (0, 0.50), (-0.50, 0)])
    return glyph(cut(outer, inner))


def skull():
    head = union(disc(0, -0.16, 0.66), rect(-0.40, 0.10, 0.40, 0.62, radius=0.10))
    teeth = union(rect(-0.30, 0.44, -0.20, 0.66), rect(-0.05, 0.44, 0.05, 0.66), rect(0.20, 0.44, 0.30, 0.66))
    shape = union(cut(head, union(rect(-0.40, 0.40, 0.40, 0.70))), teeth)
    eyes = union(disc(-0.26, -0.10, 0.17), disc(0.26, -0.10, 0.17))
    nose = poly([(0, 0.08), (0.09, 0.26), (-0.09, 0.26)])
    return glyph(shape, dark=union(eyes, nose))


def bag():  # a stash: backpack
    body = rect(-0.56, -0.36, 0.56, 0.80, radius=0.22)
    handle = ring(0, -0.40, 0.30, 0.15)
    handle = cut(handle, rect(-0.6, -0.36, 0.6, 0.2))
    flap = rect(-0.56, -0.36, 0.56, 0.06, radius=0.18)
    pocket = rect(-0.30, 0.30, 0.30, 0.62, radius=0.08)
    shape = union(body, handle, flap)
    seam = cut(rect(-0.56, 0.04, 0.56, 0.12), canvas())
    return glyph(shape, dark=union(seam, cut(dilate(pocket, 0.6), pocket)))


def tent():
    shape = poly([(0, -0.78), (0.86, 0.66), (-0.86, 0.66)])
    door = poly([(0, -0.10), (0.24, 0.66), (-0.24, 0.66)])
    return glyph(shape, dark=door)


def fire():  # campfire: a flame over two crossed logs
    flame = union(poly([(0.0, -0.86), (0.42, -0.06), (0.30, 0.30), (-0.30, 0.30), (-0.42, -0.06)]), disc(0, 0.04, 0.38))
    tongue = union(poly([(0.06, -0.30), (0.20, 0.10), (-0.10, 0.16)]), disc(0.02, 0.14, 0.15))
    logs = union(rot_rect(0, 0.58, 1.6, 0.22, 18), rot_rect(0, 0.58, 1.6, 0.22, -18))
    return glyph(union(flame, logs), dark=tongue)


def ping_ring():
    return glyph(ring(0, 0, 0.86, 0.60))


def dot():
    return glyph(disc(0, 0, 0.78))


def star():
    pts = []
    for k in range(10):
        r = 0.86 if k % 2 == 0 else 0.36
        a = math.radians(-90 + k * 36)
        pts.append((r * math.cos(a), r * math.sin(a) + 0.06))
    return glyph(poly(pts))


def arrow():  # team card: points up (forward); the card turns it
    return glyph(poly([(0, -0.84), (0.66, 0.74), (0, 0.38), (-0.66, 0.74)]))


def zzz():
    z = poly([(-0.56, -0.66), (0.56, -0.66), (0.56, -0.40), (-0.14, 0.40), (0.56, 0.40), (0.56, 0.66),
              (-0.56, 0.66), (-0.56, 0.40), (0.14, -0.40), (-0.56, -0.40)])
    return glyph(z)


def eye():
    lens = ImageChops.multiply(ellipse(0, -0.55, 1.15, 1.05), ellipse(0, 0.55, 1.15, 1.05))
    almond = cut(lens, canvas())
    pupil = union(disc(0, 0, 0.26))
    iris_ring = ring(0, 0, 0.40, 0.28)
    return glyph(almond, dark=union(pupil, iris_ring))


def warn():
    bar = poly([(-0.20, -0.84), (0.20, -0.84), (0.13, 0.30), (-0.13, 0.30)])
    return glyph(union(bar, disc(0, 0.62, 0.19)))


def notch():  # the centre mark of the bar: white, under the line, pointing up at it; plain, no outline
    return glyph(poly([(-1, 1), (1, 1), (0, -1)]), outline=False)


def tri(direction):
    base = {"up": [(0, -0.62), (0.70, 0.52), (-0.70, 0.52)],
            "down": [(0, 0.62), (0.70, -0.52), (-0.70, -0.52)],
            "left": [(-0.62, 0), (0.52, -0.70), (0.52, 0.70)],
            "right": [(0.62, 0), (-0.52, -0.70), (-0.52, 0.70)]}[direction]
    return glyph(poly(base))


def cross():  # the downed player's row: a plus inside the melting ring
    return glyph(union(rect(-0.15, -0.50, 0.15, 0.50), rect(-0.50, -0.15, 0.50, 0.15)))


def arc8():  # one eighth (45 deg) of the ring around the cross, at the top; the row turns 8 of them
    m = ring(0, 0, 0.92, 0.70)
    keep = poly([(0, 0), (-0.374 * 1.2, -1.2), (0.374 * 1.2, -1.2)])  # +-20.5 deg: a thin gap to the next arc
    return glyph(ImageChops.multiply(m, keep))


# ---------------------------------------------------------------- v2.1: PDA marks on the compass (docs/HUD_V2.md, v2.1)
def waypoint():  # the player's own waypoint (Personal Adjustable Waypoint task, a PDA mark): a map pin, tip down
    head = disc(0, -0.30, 0.58)
    tip = poly([(-0.50, -0.06), (0.50, -0.06), (0, 0.90)])
    return glyph(union(head, tip), dark=disc(0, -0.30, 0.22))


def flag():  # a PDA pin of the player (PAW pins): a pennant on a pole
    pole = rect(-0.64, -0.86, -0.42, 0.88)
    cloth = poly([(-0.44, -0.86), (0.80, -0.48), (-0.44, -0.08)])
    return glyph(union(pole, cloth))


def stash():  # a stash: a crate, its lid band and a lock (the death drop is the backpack)
    box = rect(-0.74, -0.40, 0.74, 0.76, radius=0.08)
    lid = rect(-0.84, -0.72, 0.84, -0.30, radius=0.08)
    seam = rect(-0.74, -0.30, 0.74, -0.16)
    lock = rect(-0.16, -0.16, 0.16, 0.22)
    return glyph(union(box, lid), dark=union(seam, lock))


def trader():  # trader: a stack of coins (three flat bars, the top one lying)
    bars = union(rect(-0.66, 0.42, 0.62, 0.78, radius=0.14), rect(-0.56, 0.00, 0.72, 0.36, radius=0.14),
                 rect(-0.70, -0.42, 0.58, -0.06, radius=0.14))
    top = ellipse(-0.06, -0.58, 0.64, 0.26)
    return glyph(union(bars, top))


def mechanic():  # mechanic: a wrench, the open jaw at the top right
    handle = union(rot_rect(-0.16, 0.16, 1.24, 0.32, -45), disc(-0.60, 0.60, 0.17))
    head = disc(0.36, -0.36, 0.48)
    slot = rot_rect(0.62, -0.62, 0.86, 0.34, -45)  # along the handle: the jaw opens away from it
    return glyph(cut(union(handle, head), slot))


def medic():  # medic: a rounded square with a plus cut in (not the downed ally's ring and cross)
    box = rect(-0.74, -0.74, 0.74, 0.74, radius=0.24)
    plus = union(rect(-0.15, -0.48, 0.15, 0.48), rect(-0.48, -0.15, 0.48, 0.15))
    return glyph(box, dark=plus)


def npc():  # any other person of the PDA (barman, scout, quest giver, companion): head and shoulders
    head = disc(0, -0.40, 0.34)
    shoulders = ImageChops.multiply(ellipse(0, 0.74, 0.78, 0.70), rect(-1, -0.02, 1, 0.86))
    return glyph(union(head, shoulders))


def sleep():  # a sleeping place: a crescent moon
    return glyph(cut(disc(-0.06, 0.02, 0.78), disc(0.34, -0.24, 0.62)))


def transition():  # a level changer: a gate with an arrow through it
    arch = union(rect(-0.66, -0.26, 0.66, 0.84), disc(0, -0.26, 0.66))
    arrow = union(poly([(0, -0.64), (0.38, -0.12), (-0.38, -0.12)]), rect(-0.13, -0.14, 0.13, 0.62))
    return glyph(arch, dark=arrow)


def white(n=8):
    return Image.new("RGBA", (n, n), (255, 255, 255, 255))


def fade_strip(w=ATLAS, h=8):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    zone = w * FADE_PART
    for x in range(w):
        t = min(x + 0.5, w - x - 0.5) / zone
        a = int(round(255 * max(0.0, min(1.0, t))))
        for y in range(h):
            px[x, y] = (255, 255, 255, a)
    return img


# id: (image maker, x, y, id inset) - the id's rect is the cell minus the inset on every side
GLYPHS = [
    ("coop_hud_chevron", chevron, 0, 0),
    ("coop_hud_down", down, 32, 0),
    ("coop_hud_diamond", diamond, 64, 0),
    ("coop_hud_diamond_hollow", diamond_hollow, 96, 0),
    ("coop_hud_skull", skull, 128, 0),
    ("coop_hud_bag", bag, 160, 0),
    ("coop_hud_tent", tent, 192, 0),
    ("coop_hud_fire", fire, 224, 0),
    ("coop_hud_ring", ping_ring, 0, 32),
    ("coop_hud_dot", dot, 32, 32),
    ("coop_hud_star", star, 64, 32),
    ("coop_hud_arrow", arrow, 96, 32),
    ("coop_hud_z", zzz, 128, 32),
    ("coop_hud_eye", eye, 160, 32),
    ("coop_hud_warn", warn, 192, 32),
    ("coop_hud_notch", notch, 224, 32),
    ("coop_hud_tri_left", lambda: tri("left"), 0, 64),
    ("coop_hud_tri_right", lambda: tri("right"), 32, 64),
    ("coop_hud_tri_up", lambda: tri("up"), 64, 64),
    ("coop_hud_tri_down", lambda: tri("down"), 96, 64),
    ("coop_hud_cross", cross, 160, 64),
    ("coop_hud_arc8", arc8, 192, 64),
    # v2.1: PDA marks (the compass shows what Tactical Compass showed)
    ("coop_hud_waypoint", waypoint, 0, 128),
    ("coop_hud_flag", flag, 32, 128),
    ("coop_hud_stash", stash, 64, 128),
    ("coop_hud_trader", trader, 96, 128),
    ("coop_hud_mechanic", mechanic, 128, 128),
    ("coop_hud_medic", medic, 160, 128),
    ("coop_hud_npc", npc, 192, 128),
    ("coop_hud_sleep", sleep, 224, 128),
    ("coop_hud_transition", transition, 0, 160),
]


def build():
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    ids = []
    for tid, maker, x, y in GLYPHS:
        img = maker()
        assert img.size == (CELL, CELL), tid
        atlas.paste(img, (x, y))
        ids.append((tid, x, y, CELL, CELL))
    # solid white: an 8x8 cell, the id is its middle 4x4 (bilinear never reaches the neighbours)
    atlas.paste(white(8), (128, 64))
    ids.append(("coop_hud_white", 130, 66, 4, 4))
    # bar gradients: 8 rows each, the id is the middle 4 rows
    atlas.paste(fade_strip(), (0, 96))
    ids.append(("coop_hud_bar_bg", 0, 98, ATLAS, 4))
    atlas.paste(fade_strip(), (0, 112))
    ids.append(("coop_hud_bar_line", 0, 114, ATLAS, 4))
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
        "<!-- Anomaly Coop HUD v2 (docs\\HUD_V2.md): icon atlas textures\\ui\\coop\\ui_coop_hud.dds, 256x256 A8R8G8B8, no mips.",
        "     Generated by tools\\make_hud_atlas.py (procedural, Pillow). White glyphs with a dark 1 px outline, tinted by the",
        "     scripts (coop_hud_compass, coop_hud_ping, coop_core_hud); coop_hud_bar_bg / coop_hud_bar_line fade out on the last",
        "     16 % of the width at each end; coop_hud_white is a solid white cell. -->",
        "<w>",
        '\t<file name="ui\\coop\\ui_coop_hud">',
    ]
    for tid, x, y, w, h in ids:
        lines.append('\t\t<texture id="%s" x="%d" y="%d" width="%d" height="%d"/>' % (tid, x, y, w, h))
    lines += ["\t</file>", "</w>"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("cp1251"))


def write_preview(atlas, path, scale=4):
    w, h = atlas.size
    bg = Image.new("RGBA", (w, h), (90, 92, 88, 255))
    d = ImageDraw.Draw(bg)
    for y in range(0, h, 8):
        for x in range(0, w, 8):
            if (x // 8 + y // 8) % 2:
                d.rectangle([x, y, x + 7, y + 7], fill=(110, 112, 106, 255))
    out = Image.alpha_composite(bg, atlas).resize((w * scale, h * scale), Image.NEAREST)
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--gamedata", type=Path, default=ROOT / "gamedata")
    ap.add_argument("--preview", type=Path, default=None)
    args = ap.parse_args()
    atlas, ids = build()
    dds = args.gamedata / "textures" / "ui" / "coop" / "ui_coop_hud.dds"
    descr = args.gamedata / "configs" / "ui" / "textures_descr" / "ui_coop_hud.xml"
    write_dds_argb(atlas, dds)
    write_descr(ids, descr)
    if args.preview:
        write_preview(atlas, args.preview)
    print("%s (%d bytes), %s (%d ids)" % (dds, dds.stat().st_size, descr, len(ids)))


if __name__ == "__main__":
    main()
