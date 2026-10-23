"""Co-op window assets (scripts/coop_menu.script, configs/ui/ui_coop_menu.xml): the icon atlas DDS is uncompressed BGRA8 without
mips, its textures_descr parses and every id lies inside the image, every texture id the layout uses is described, the
committed files are what tools/make_menu_icons.py and tools/make_menu_layout_16.py write."""
import re
import struct
import xml.etree.ElementTree as ET

import make_menu_icons as icons
import make_menu_layout_16 as layout16
from conftest import ROOT

GAMEDATA = ROOT / "gamedata"
DDS = GAMEDATA / "textures" / "ui" / "coop" / "ui_coop_menu.dds"
DESCR = GAMEDATA / "configs" / "ui" / "textures_descr" / "ui_coop_menu.xml"
LAYOUT = GAMEDATA / "configs" / "ui" / "ui_coop_menu.xml"
LAYOUT_16 = GAMEDATA / "configs" / "ui" / "ui_coop_menu_16.xml"


def dds_header(path):
    raw = path.read_bytes()
    magic, size, flags, height, width, pitch, _depth, mips = struct.unpack_from("<4s7I", raw, 0)
    pf_size, pf_flags, fourcc, bits, rmask, gmask, bmask, amask = struct.unpack_from("<2I4s5I", raw, 76)
    return {"magic": magic, "size": size, "w": width, "h": height, "pitch": pitch, "mips": mips, "pf_flags": pf_flags,
            "fourcc": fourcc, "bits": bits, "masks": (rmask, gmask, bmask, amask), "len": len(raw), "raw": raw}


def described():
    root = ET.fromstring(DESCR.read_bytes())
    files = root.findall("file")
    assert len(files) == 1 and files[0].get("name") == r"ui\coop\ui_coop_menu"
    return {t.get("id"): t for t in files[0].iter("texture")}


def test_atlas_is_uncompressed_bgra8_without_mips():
    h = dds_header(DDS)
    assert h["magic"] == b"DDS " and h["size"] == 124
    assert h["pf_flags"] == 0x41 and h["bits"] == 32 and h["fourcc"] == b"\0\0\0\0"
    assert h["masks"] == (0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000)
    assert h["mips"] in (0, 1) and h["pitch"] == h["w"] * 4
    assert h["len"] == 128 + h["w"] * h["h"] * 4


def test_atlas_ids_inside_the_image():
    h = dds_header(DDS)
    ids = described()
    assert len(ids) == 9
    for tid, t in ids.items():
        x, y, w, hh = (int(t.get(k)) for k in ("x", "y", "width", "height"))
        assert tid.startswith("coop_menu_"), tid
        assert 0 <= x and 0 <= y and w > 0 and hh > 0 and x + w <= h["w"] and y + hh <= h["h"], tid


def pixel(h, x, y):
    """(r, g, b, a) of an atlas pixel (the file holds BGRA)."""
    off = 128 + (y * h["w"] + x) * 4
    b, g, r, a = h["raw"][off:off + 4]
    return r, g, b, a


def test_flat_cells():
    h = dds_header(DDS)
    ids = described()

    def cell(tid):
        t = ids[tid]
        x, y, w, hh = (int(t.get(k)) for k in ("x", "y", "width", "height"))
        return {pixel(h, i, j) for i in range(x, x + w) for j in range(y, y + hh)}

    assert cell("coop_menu_white") == {(255, 255, 255, 255)}
    assert {p[3] for p in cell("coop_menu_hit_e")} == {0}  # at rest: transparent
    assert cell("coop_menu_hit_d") == cell("coop_menu_hit_e")  # disabled: the same cell
    over, pressed = cell("coop_menu_hit_h"), cell("coop_menu_hit_t")
    assert len(over) == 1 and len(pressed) == 1
    assert 0 < next(iter(over))[3] < next(iter(pressed))[3] < 128  # a veil: stronger when pressed, never opaque


def test_layout_texture_ids_are_described():
    ids = set(described())
    text = LAYOUT.read_text(encoding="cp1251")
    ET.fromstring(LAYOUT.read_bytes())  # parses
    used = set(re.findall(r">\s*(coop_menu_[a-z0-9_]+)\s*<", text))
    assert used, "no coop_menu_* texture ids found"
    for tid in used:
        assert tid in ids or all(tid + s in ids for s in ("_e", "_d", "_t", "_h")), tid  # a 3-state button has the four


def test_description_is_what_the_tool_writes(work):
    """The atlas is deterministic where it matters: the same ids and rectangles, the same flat cells and header."""
    atlas, ids = icons.build()
    out = work / "descr.xml"
    icons.write_descr(ids, out)
    assert out.read_bytes() == DESCR.read_bytes()
    dds = work / "atlas.dds"
    icons.write_dds_argb(atlas, dds)
    fresh, committed = dds.read_bytes(), DDS.read_bytes()
    assert fresh[:128] == committed[:128] and len(fresh) == len(committed)
    # the flat cells (row 32..39) are exact; the glyphs (rows 0..31) are antialiased by Pillow and may differ in the last bit
    row = 128 + 32 * 128 * 4
    assert fresh[row:row + 8 * 128 * 4] == committed[row:row + 8 * 128 * 4]


def test_wide_layout_is_up_to_date():
    """ui_coop_menu_16.xml is made from the 4:3 file: run tools/make_menu_layout_16.py after editing it."""
    want = layout16.build(LAYOUT.read_text(encoding="utf-8", newline=""))
    assert LAYOUT_16.read_text(encoding="utf-8", newline="") == want
    a, b = ET.fromstring(LAYOUT.read_bytes()), ET.fromstring(LAYOUT_16.read_bytes())
    assert [e.tag for e in a.iter()] == [e.tag for e in b.iter()]
