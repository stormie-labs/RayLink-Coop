"""Anomaly Coop HUD v2 part 2 (docs/HUD_V2.md, "Поднятие союзника"): the procedural atlas of the revive rings.

The Lua UI cannot draw an arc, so a ring is a track (a plain ring texture, dim) under many small arc pieces (one
texture, rotated by the engine's static heading, 6 deg of ring each, drawn 7 deg wide so that neighbours overlap and never
leave a seam; more overlap makes the antialiased edges of the ring beady) that the script shows as the hold fills; the colours are the script's (a white texture tinted). Also here:
a soft dark shadow ring under each (legible over a bright sky and over foliage), the running dot, the plus of the downed
player's ring, a medkit and a stimpack badge, and the red vignette (white, an alpha ramp: the script tints it red).
Flat, no glow. One 256x256 atlas, an uncompressed DDS A8R8G8B8 (BGRA bytes) without mips, the layout of the stock UI
DDS of the stand and of ui_coop_hud.dds (tools\\make_hud_atlas.py), plus its textures_descr ids.

Ring geometry the script relies on (keep in step with scripts\\coop_hud_revive.script, RING_FRAC):
  the ring of every texture ends at RING_FRAC = 57/64 of the half-box (the rest is room for the shadow), so a ring of
  radius R is drawn in a box of 2 * R / RING_FRAC. Thick: 8 px of 128 (6.25 % of the box), thin: 5 px of 128.
  An arc texture is the piece at 12 o'clock, 7 deg wide (-3.5 .. +3.5); heading = -(clockwise angle of its middle).
  track3 has gaps of 6 deg at 0, 120 and 240 deg (the three seconds of the revive ring).

Usage: python tools/make_revive_atlas.py [--gamedata DIR] [--preview PNG]
  writes DIR/textures/ui/coop/ui_coop_revive.dds and DIR/configs/ui/textures_descr/ui_coop_revive.xml
  (default DIR: gamedata next to tools), and a preview on a grey checker when --preview is given.
No external generators, no network: Pillow only.
"""
import argparse
import math
import struct
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # supersampling
ATLAS = 256
OUTLINE_RGB = (16, 17, 14)
OUTLINE_ALPHA = 235
SHADOW_ALPHA = 120
RING_OUT = 57  # of 64: the ring's outer radius in a 128 px piece cell (and 28.5 of 32 in a 64 px track cell)
THICK = 8  # px of 128
THIN = 5
PIECE_SPAN = 7.0  # deg, the arc piece (the script puts them 6 deg apart: half a degree of overlap at each end)
GAP_DEG = 6.0  # the gaps of track3

ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- masks, in pixels of the final cell
def canvas(w, h=None):
    h = w if h is None else h
    return Image.new("L", (w * SS, h * SS), 0)


def sector(w, cx, cy, r_out, r_in, a0, a1, h=None):
    """Annular sector, angles clockwise from 12 o'clock in degrees."""
    m = canvas(w, h)
    steps = max(2, int(abs(a1 - a0) * 2) + 1)

    def pt(r, a):
        rad = math.radians(a)
        return ((cx + r * math.sin(rad)) * SS, (cy - r * math.cos(rad)) * SS)

    outer = [pt(r_out, a0 + (a1 - a0) * i / (steps - 1)) for i in range(steps)]
    inner = [pt(r_in, a1 + (a0 - a1) * i / (steps - 1)) for i in range(steps)]
    ImageDraw.Draw(m).polygon(outer + inner, fill=255)
    return m


def disc(w, cx, cy, r, h=None):
    m = canvas(w, h)
    ImageDraw.Draw(m).ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=255)
    return m


def ring(w, r_out, r_in):
    c = w / 2
    return ImageChops.subtract(disc(w, c, c, r_out), disc(w, c, c, r_in))


def rrect(w, h, x0, y0, x1, y1, radius):
    m = canvas(w, h)
    ImageDraw.Draw(m).rounded_rectangle([x0 * SS, y0 * SS, x1 * SS, y1 * SS], radius=radius * SS, fill=255)
    return m


def rect(w, h, x0, y0, x1, y1):
    m = canvas(w, h)
    ImageDraw.Draw(m).rectangle([x0 * SS, y0 * SS, x1 * SS, y1 * SS], fill=255)
    return m


def poly(w, h, pts):
    m = canvas(w, h)
    ImageDraw.Draw(m).polygon([(x * SS, y * SS) for x, y in pts], fill=255)
    return m


def rot_rect(w, h, cx, cy, length, width, angle_deg):
    a = math.radians(angle_deg)
    ux, uy = math.cos(a), math.sin(a)
    vx, vy = -uy, ux
    hl, hw = length / 2, width / 2
    pts = [(cx + ux * hl * sx + vx * hw * sy, cy + uy * hl * sx + vy * hw * sy) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    return poly(w, h, pts)


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


# ---------------------------------------------------------------- compose and downsample
def layer(big, mask, rgb, alpha=255):
    lay = Image.new("RGBA", big.size, rgb + (0,))
    lay.putalpha(mask.point(lambda v: v * alpha // 255))
    return Image.alpha_composite(big, lay)


def downsample(big):
    """premultiply -> box average SS x SS -> unpremultiply (no dark or light fringes)."""
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


def white_shape(mask):
    big = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    return downsample(layer(big, mask, (255, 255, 255)))


def dark_shape(mask, alpha):
    big = Image.new("RGBA", mask.size, (0, 0, 0, 0))
    return downsample(layer(big, mask, OUTLINE_RGB, alpha))


def outlined(mask, w, h, outline_px=1.4, inner=None):
    """White `mask` over a dark outline; `inner` (a mask inside it) is painted dark on top."""
    big = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    big = layer(big, dilate(mask, outline_px), OUTLINE_RGB, OUTLINE_ALPHA)
    big = layer(big, mask, (255, 255, 255))
    if inner is not None:
        big = layer(big, inner, OUTLINE_RGB, OUTLINE_ALPHA)
    return downsample(big)


# ---------------------------------------------------------------- the cells
def arc_piece(thickness):
    n = 128
    return white_shape(sector(n, n / 2, n / 2, RING_OUT, RING_OUT - thickness, -PIECE_SPAN / 2, PIECE_SPAN / 2))


def track(thickness_128, gaps=False):
    n = 64
    r_out = RING_OUT / 2
    r_in = r_out - thickness_128 / 2
    m = ring(n, r_out, r_in)
    if gaps:
        for centre in (0, 120, 240):
            m = cut(m, sector(n, n / 2, n / 2, n, 0, centre - GAP_DEG / 2, centre + GAP_DEG / 2))
    return white_shape(m)


def shadow(thickness_128):
    n = 64
    r_out = RING_OUT / 2
    r_in = r_out - thickness_128 / 2
    return dark_shape(dilate(ring(n, r_out, r_in), 1.5), SHADOW_ALPHA)


def dot():
    n = 32
    return outlined(disc(n, n / 2, n / 2, 11), n, n, outline_px=1.8)


def cross():
    n = 32
    plus = union(rect(n, n, 5, 13, 27, 19), rect(n, n, 13, 5, 19, 27))
    return outlined(plus, n, n, outline_px=1.8)


def vignette():
    n = 32
    img = Image.new("RGBA", (n, n), (255, 255, 255, 0))
    px = img.load()
    for y in range(n):
        for x in range(n):
            dx, dy = (x + 0.5 - n / 2) / (n / 2), (y + 0.5 - n / 2) / (n / 2)
            r = math.hypot(dx, dy)  # 1.0 at the middle of an edge, 1.41 in a corner
            t = max(0.0, min(1.0, (r - 0.45) / (1.3 - 0.45)))
            px[x, y] = (255, 255, 255, int(round(255 * t ** 1.7)))
    return img


def badge(kind):
    w, h = 48, 32
    plate = rrect(w, h, 2.5, 2.5, 45.5, 29.5, 5)
    red = (216, 53, 42)
    big = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    big = layer(big, dilate(plate, 1.2), OUTLINE_RGB, OUTLINE_ALPHA)
    big = layer(big, plate, (236, 232, 220))
    if kind == "medkit":
        glyph = union(rect(w, h, 17.5, 13, 30.5, 19), rect(w, h, 21, 9, 27, 23))
        big = layer(big, glyph, red)
    else:  # stimpack: a syringe lying at -35 deg, needle down-left, plunger and thumb plate up-right
        a = -35
        cx, cy = 23.5, 18
        ux, uy = math.cos(math.radians(a)), math.sin(math.radians(a))

        def at(t):
            return cx + ux * t, cy + uy * t

        barrel = rot_rect(w, h, *at(0), 18, 8, a)
        needle = rot_rect(w, h, *at(-12.5), 7, 1.6, a)
        collar = rot_rect(w, h, *at(-9), 2.2, 11, a)
        rod = rot_rect(w, h, *at(12), 6, 2.4, a)
        thumb = rot_rect(w, h, *at(15.5), 2.6, 9, a)
        big = layer(big, union(barrel, needle, collar, rod, thumb), red)
        window = rot_rect(w, h, *at(0), 11, 3, a)
        big = layer(big, window, (236, 232, 220))
    return downsample(big)


def solid(n=8):
    return Image.new("RGBA", (n, n), (255, 255, 255, 255))


# (id, maker, x, y, w, h); a solid cell is added by build() with its middle 4x4 as the id
CELLS = [
    ("coop_rev_arc", lambda: arc_piece(THICK), 0, 0, 128, 128),
    ("coop_rev_arc_thin", lambda: arc_piece(THIN), 128, 0, 128, 128),
    ("coop_rev_track", lambda: track(THICK), 0, 128, 64, 64),
    ("coop_rev_track3", lambda: track(THICK, gaps=True), 64, 128, 64, 64),
    ("coop_rev_track_thin", lambda: track(THIN), 128, 128, 64, 64),
    ("coop_rev_shadow", lambda: shadow(THICK), 192, 128, 64, 64),
    ("coop_rev_shadow_thin", lambda: shadow(THIN), 0, 192, 64, 64),
    ("coop_rev_vignette", vignette, 64, 192, 32, 32),
    ("coop_rev_cross", cross, 96, 192, 32, 32),
    ("coop_rev_medkit", lambda: badge("medkit"), 128, 192, 48, 32),
    ("coop_rev_stimpack", lambda: badge("stimpack"), 176, 192, 48, 32),
    ("coop_rev_dot", dot, 224, 192, 32, 32),
]


def build():
    atlas = Image.new("RGBA", (ATLAS, ATLAS), (0, 0, 0, 0))
    ids = []
    for tid, maker, x, y, w, h in CELLS:
        img = maker()
        assert img.size == (w, h), (tid, img.size)
        atlas.paste(img, (x, y))
        ids.append((tid, x, y, w, h))
    # solid white: an 8x8 cell, the id is its middle 4x4 (bilinear never reaches the neighbours)
    atlas.paste(solid(8), (64, 224))
    ids.append(("coop_rev_white", 66, 226, 4, 4))
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
        "<!-- Anomaly Coop HUD v2 part 2 (docs\\HUD_V2.md, Поднятие союзника): atlas textures\\ui\\coop\\ui_coop_revive.dds, 256x256",
        "     A8R8G8B8, no mips. Generated by tools\\make_revive_atlas.py (procedural, Pillow). White shapes tinted by",
        "     scripts\\coop_hud_revive.script: coop_rev_arc / _arc_thin are 7 deg pieces of a ring (the engine turns them),",
        "     coop_rev_track* the dim ring under them (track3: three segments), coop_rev_shadow* a soft dark ring, the vignette is",
        "     an alpha ramp, the badges keep their own colours. coop_rev_white is a solid white cell. -->",
        "<w>",
        '\t<file name="ui\\coop\\ui_coop_revive">',
    ]
    for tid, x, y, w, h in ids:
        lines.append('\t\t<texture id="%s" x="%d" y="%d" width="%d" height="%d"/>' % (tid, x, y, w, h))
    lines += ["\t</file>", "</w>"]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode("cp1251"))


def write_preview(atlas, path, scale=3):
    w, h = atlas.size
    bg = Image.new("RGBA", (w, h), (70, 72, 68, 255))
    d = ImageDraw.Draw(bg)
    for y in range(0, h, 8):
        for x in range(0, w, 8):
            if (x // 8 + y // 8) % 2:
                d.rectangle([x, y, x + 7, y + 7], fill=(96, 98, 92, 255))
    out = Image.alpha_composite(bg, atlas).resize((w * scale, h * scale), Image.NEAREST)
    path.parent.mkdir(parents=True, exist_ok=True)
    out.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--gamedata", type=Path, default=ROOT / "gamedata")
    ap.add_argument("--preview", type=Path, default=None)
    args = ap.parse_args()
    atlas, ids = build()
    dds = args.gamedata / "textures" / "ui" / "coop" / "ui_coop_revive.dds"
    descr = args.gamedata / "configs" / "ui" / "textures_descr" / "ui_coop_revive.xml"
    write_dds_argb(atlas, dds)
    write_descr(ids, descr)
    if args.preview:
        write_preview(atlas, args.preview)
    print("%s (%d bytes), %s (%d ids)" % (dds, dds.stat().st_size, descr, len(ids)))


if __name__ == "__main__":
    main()
