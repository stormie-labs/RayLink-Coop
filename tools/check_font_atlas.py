"""Anomaly Coop: checks the font atlases made by tools/make_font_atlas.mjs (and any CGameFont atlas in the same format).

For every <name>.ini with a [symbol_coords] section (default: gamedata/textures/ui/ui_font_menu_*.ini) it checks, against the
<name>.dds beside it:
  the file      the ini has all 256 codes 000..255 and a `height`; the DDS is A8R8G8B8 with one level and the size of
                [atlas] width x height (when the ini says it) and of its own header and file length
  the cells     inside the atlas, each as high as the line `height`, none overlapping another, ink-free gutters around them
                (a glyph that overran its cell shows as ink in the gutter; the engine would then cut or smear it)
  the glyphs    every printable cp1251 code has a cell with ink, every width is sane for the line height (a letter is neither
                a sliver nor wider than twice the line; a space is narrow and empty), controls 0-31, 127 and 152 (0x98, which
                cp1251 leaves undefined) are 0,0,0,0, the space and the no-break space are the same width, and the ten digits
                are one width when the ini says tabular_digits = 1
  the family    the tiers <name>_h<N> of one font agree: the same glyphs, a line height that follows N, widths that do too
Prints every problem and "N problem(s)"; exit code 0 = none, 1 = problems, 2 = nothing to check.

Usage: python -I tools/check_font_atlas.py [--dir DIR] [FILE.ini ...]
Std lib only.
"""
import argparse
import re
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DIR = ROOT / "gamedata" / "textures" / "ui"
DEFAULT_GLOB = "ui_font_menu_*.ini"
EMPTY_CODES = set(range(0, 32)) | {127, 152}
SPACES = {32, 160}
GUTTER = 1  # the generator leaves 2 px between cells; the first of them must be free of ink
TIER = re.compile(r"^(?P<family>.+)_h(?P<tier>\d+)$")


def parse_ini(path):
    """{section: {key: value}} of an ini (';' comments, 'key = value')."""
    out, cur = {}, None
    for raw in path.read_text(encoding="latin-1").splitlines():
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = out.setdefault(line[1:-1].strip(), {})
        elif "=" in line and cur is not None:
            k, v = line.split("=", 1)
            cur[k.strip()] = v.strip()
    return out


def read_dds(path):
    b = path.read_bytes()
    if len(b) < 128 or b[:4] != b"DDS ":
        raise ValueError("not a DDS")
    size, flags, h, w, pitch, depth, mips = struct.unpack("<7I", b[4:32])
    pf_size, pf_flags, fourcc, bits, rm, gm, bm, am = struct.unpack("<II4sIIIII", b[76:108])
    if size != 124 or pf_size != 32:
        raise ValueError("bad DDS header sizes")
    if (pf_flags & 0x41) != 0x41 or fourcc != b"\0\0\0\0" or bits != 32 or (rm, gm, bm, am) != (0xFF0000, 0xFF00, 0xFF, 0xFF000000):
        raise ValueError("not A8R8G8B8")
    if mips > 1:
        raise ValueError("has mip levels (%d)" % mips)
    if len(b) != 128 + w * h * 4:
        raise ValueError("file length %d is not 128 + %d*%d*4" % (len(b), w, h))
    return w, h, b[128 + 3 :: 4]  # the alpha plane, row by row (b[128:] is BGRA)


def ink_in(alpha, w, x1, y1, x2, y2, threshold=1):
    for y in range(y1, y2):
        row = alpha[y * w + x1 : y * w + x2]
        if any(v >= threshold for v in row):
            return True
    return False


def ink_count(alpha, w, x1, y1, x2, y2):
    n = 0
    for y in range(y1, y2):
        n += sum(1 for v in alpha[y * w + x1 : y * w + x2] if v >= 48)
    return n


def check_one(ini_path, problems):
    name = ini_path.stem

    def bad(msg):
        problems.append("%s: %s" % (name, msg))

    ini = parse_ini(ini_path)
    sym = ini.get("symbol_coords")
    if sym is None:
        bad("no [symbol_coords]")
        return None
    try:
        cell = int(float(sym["height"]))
    except (KeyError, ValueError):
        bad("no usable height in [symbol_coords]")
        return None

    dds_path = ini_path.with_suffix(".dds")
    if not dds_path.exists():
        bad("no %s" % dds_path.name)
        return None
    try:
        aw, ah, alpha = read_dds(dds_path)
    except ValueError as e:
        bad("%s: %s" % (dds_path.name, e))
        return None
    meta = ini.get("atlas", {})
    if meta and (int(meta.get("width", aw)) != aw or int(meta.get("height", ah)) != ah):
        bad("[atlas] says %sx%s, the DDS is %dx%d" % (meta.get("width"), meta.get("height"), aw, ah))

    cells = {}
    for code in range(256):
        key = "%03d" % code
        if key not in sym:
            bad("code %s is missing" % key)
            continue
        parts = [p.strip() for p in sym[key].split(",")]
        try:
            x1, y1, x2, y2 = (int(float(p)) for p in parts[:4])
        except ValueError:
            bad("code %s: not four numbers: %r" % (key, sym[key]))
            continue
        cells[code] = (x1, y1, x2, y2)
    extra = [k for k in sym if k != "height" and not (k.isdigit() and 0 <= int(k) < 256)]
    if extra:
        bad("unknown keys in [symbol_coords]: %s" % ", ".join(extra[:5]))
    if len(cells) != 256:
        return None

    widths = {}
    live = []
    for code, (x1, y1, x2, y2) in cells.items():
        w = x2 - x1
        widths[code] = w
        if code in EMPTY_CODES:
            if (x1, y1, x2, y2) != (0, 0, 0, 0):
                bad("code %03d must be 0,0,0,0 (a control or undefined code), is %s" % (code, sym["%03d" % code]))
            continue
        if w <= 0:
            bad("code %03d (%s) has no width" % (code, bytes([code]).decode("cp1251", "replace")))
            continue
        if y2 - y1 != cell:
            bad("code %03d is %d px high, the line is %d" % (code, y2 - y1, cell))
        if x1 < 0 or y1 < 0 or x2 > aw or y2 > ah:
            bad("code %03d (%d,%d,%d,%d) is outside the %dx%d atlas" % (code, x1, y1, x2, y2, aw, ah))
            continue
        live.append((code, x1, y1, x2, y2))

    # overlaps
    live.sort(key=lambda c: (c[2], c[1]))
    for i, a in enumerate(live):
        for b in live[i + 1 :]:
            if b[2] >= a[4]:
                if b[2] >= a[4] + cell:
                    break
                continue
            if a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4]:
                bad("cells of codes %03d and %03d overlap" % (a[0], b[0]))

    # the glyphs: ink where there should be, none in the gutter
    for code, x1, y1, x2, y2 in live:
        ch = bytes([code]).decode("cp1251", "replace")
        w = x2 - x1
        if code in SPACES:
            if ink_in(alpha, aw, x1, y1, x2, y2):
                bad("code %03d (space) has ink" % code)
            if not (0.06 * cell <= w <= 0.8 * cell):
                bad("code %03d (space) is %d px wide for a %d px line" % (code, w, cell))
            continue
        if ink_count(alpha, aw, x1, y1, x2, y2) < 3:
            bad("code %03d (%s) has no ink in its cell" % (code, ch))
        if w < max(2, 0.08 * cell):
            bad("code %03d (%s) is only %d px wide for a %d px line" % (code, ch, w, cell))
        if w > 2.0 * cell:
            bad("code %03d (%s) is %d px wide for a %d px line" % (code, ch, w, cell))
        # the first pixel column / row around the cell belongs to the gutter unless another cell is there
        for gx1, gy1, gx2, gy2 in (
            (x2, y1, min(aw, x2 + GUTTER), y2),
            (max(0, x1 - GUTTER), y1, x1, y2),
            (x1, y2, x2, min(ah, y2 + GUTTER)),
            (x1, max(0, y1 - GUTTER), x2, y1),
        ):
            if gx2 <= gx1 or gy2 <= gy1:
                continue
            if any(o[1] < gx2 and gx1 < o[3] and o[2] < gy2 and gy1 < o[4] for o in live if o[0] != code):
                continue
            if ink_in(alpha, aw, gx1, gy1, gx2, gy2):
                bad("code %03d (%s) has ink outside its cell (the glyph is wider or taller than its cell)" % (code, ch))
                break
    if 32 in widths and 160 in widths and widths[32] != widths[160]:
        bad("space (%d) and no-break space (%d) differ in width" % (widths[32], widths[160]))
    digits = {widths[c] for c in range(ord("0"), ord("9") + 1)}
    if meta.get("tabular_digits") == "1" and len(digits) != 1:
        bad("tabular_digits is set but the digits have %d different widths: %s" % (len(digits), sorted(digits)))
    return {"cell": cell, "widths": widths, "atlas": (aw, ah)}


def check_family(infos, problems):
    fam = {}
    for name, info in infos.items():
        m = TIER.match(name)
        if m and info:
            fam.setdefault(m.group("family"), []).append((int(m.group("tier")), name, info))
    for family, tiers in sorted(fam.items()):
        tiers.sort()
        if len(tiers) < 2:
            continue
        ref = next((t for t in tiers if t[0] == 1080), tiers[len(tiers) // 2])
        for n, name, info in tiers:
            want = ref[2]["cell"] * n / ref[0]
            if abs(info["cell"] - want) > 0.12 * want + 1:
                problems.append("%s: line height %d does not follow the tier %d (the %d tier has %d)" % (name, info["cell"], n, ref[0], ref[2]["cell"]))
            for code in (65, 77, 87, 192, 223, 48):  # A M W А ... 0: widths scale with the line
                w, wr = info["widths"][code], ref[2]["widths"][code]
                if wr and abs(w - wr * n / ref[0]) > 0.15 * wr * n / ref[0] + 2:
                    problems.append("%s: code %03d is %d px wide, the %d tier says %d" % (name, code, w, ref[0], round(wr * n / ref[0])))
            same = {c for c, w in info["widths"].items() if w > 0}
            same_ref = {c for c, w in ref[2]["widths"].items() if w > 0}
            if same != same_ref:
                problems.append("%s: not the same glyphs as the %d tier: %s" % (name, ref[0], sorted(same ^ same_ref)[:8]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=str(DEFAULT_DIR))
    ap.add_argument("files", nargs="*")
    a = ap.parse_args()
    files = [Path(f) for f in a.files] or sorted(Path(a.dir).glob(DEFAULT_GLOB))
    if not files:
        print("no atlas to check in %s (%s)" % (a.dir, DEFAULT_GLOB))
        return 2
    problems, infos = [], {}
    for f in files:
        infos[f.stem] = check_one(f, problems)
        print("%-34s %s" % (f.name, "checked" if infos[f.stem] else "NOT checked"))
    check_family(infos, problems)
    for p in problems:
        print("PROBLEM", p)
    print("%d problem(s) in %d atlas(es)" % (len(problems), len(files)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
