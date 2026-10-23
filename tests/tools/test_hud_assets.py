"""HUD v2 assets (docs/HUD_V2.md, Ассеты): the atlas DDS is uncompressed BGRA8 without mips, its textures_descr parses and
every id lies inside the image, and every texture id the HUD XML / scripts use is described."""
import re
import struct
import xml.etree.ElementTree as ET

from conftest import ROOT

GAMEDATA = ROOT / "gamedata"
DDS = GAMEDATA / "textures" / "ui" / "coop" / "ui_coop_hud.dds"
DESCR = GAMEDATA / "configs" / "ui" / "textures_descr" / "ui_coop_hud.xml"
LAYOUTS = [GAMEDATA / "configs" / "ui" / n for n in ("ui_coop_compass.xml", "ui_coop_compass_16.xml", "ui_coop_core.xml")]
SCRIPTS = GAMEDATA / "scripts"


def dds_header(path):
    raw = path.read_bytes()
    magic, size, flags, height, width, pitch, _depth, mips = struct.unpack_from("<4s7I", raw, 0)
    pf_size, pf_flags, fourcc, bits, rmask, gmask, bmask, amask = struct.unpack_from("<2I4s5I", raw, 76)
    return {"magic": magic, "size": size, "flags": flags, "w": width, "h": height, "pitch": pitch, "mips": mips,
            "pf_flags": pf_flags, "fourcc": fourcc, "bits": bits, "masks": (rmask, gmask, bmask, amask), "len": len(raw)}


def described():
    root = ET.fromstring(DESCR.read_bytes())
    files = root.findall("file")
    assert len(files) == 1 and files[0].get("name") == r"ui\coop\ui_coop_hud"
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
    assert len(ids) >= 23
    for tid, t in ids.items():
        x, y, w, hh = (int(t.get(k)) for k in ("x", "y", "width", "height"))
        assert tid.startswith("coop_hud_"), tid
        assert 0 <= x and 0 <= y and w > 0 and hh > 0 and x + w <= h["w"] and y + hh <= h["h"], tid


def test_hud_texture_ids_are_described():
    ids = set(described())
    used = set()
    for path in LAYOUTS:
        ET.fromstring(path.read_bytes())  # parses
        used |= set(re.findall(r">\s*(coop_hud_[a-z0-9_]+)\s*<", path.read_text(encoding="cp1251")))
    for path in SCRIPTS.glob("coop_*.script"):
        used |= set(re.findall(r'"(coop_hud_[a-z0-9_]+)"', path.read_text(encoding="cp1251", errors="replace")))
    used = {u for u in used if not u.startswith(("coop_hud_ally", "coop_hud_ping"))}  # Tactical Compass spot names
    used -= {p.stem for p in SCRIPTS.glob("*.script")}  # module names (rawget(_G, "coop_hud_compass"))
    assert used, "no coop_hud_* texture ids found"
    assert sorted(used - ids) == []


def test_compass_layouts_match():
    """The _16 file is what the engine loads on a wide screen: same nodes as the 4:3 one (the script does the geometry)."""
    a = ET.fromstring(LAYOUTS[0].read_bytes())
    b = ET.fromstring(LAYOUTS[1].read_bytes())
    assert [e.tag for e in a.iter()] == [e.tag for e in b.iter()]
