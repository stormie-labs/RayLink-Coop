"""GAMMA minimap overrides (gamedata_gamma/configs/ui/zone_map.xml and zone_map_21.xml): GAMMA moved the minimap to the
bottom-right only in zone_map_16.xml; its zone_map.xml (aspect up to 1.343) and zone_map_21.xml (aspect over 1.8) keep the
stock top-left frame, over the co-op party panel. Our copies of GAMMA's 16:9 file place the frame at the same right and
bottom margins as on 16:9.

Coordinates (engine UIZoneMap.cpp CUIZoneMap::Init, default ratio_mode): the frame centre is (x, y) * 768 in the 1024x768
UI units (alignment "c"), stretched to the screen: px = x * 768 * W / 1024 = 0.75 * x * W, py = y * 768 * H / 768 = y * H.
The round map has a diameter of height * H (CUIMiniMap::Draw scales its x by kx), the background a side of 0.38 * H:
everything that is seen scales with the screen height, so the frame centre must keep its margins in screen heights.
"""
import xml.etree.ElementTree as ET
from pathlib import Path

from conftest import ROOT

UI = ROOT / "gamedata_gamma" / "configs" / "ui"
GAMMA_16 = Path(r"E:\RayLink2\gamma-dev\gamedata\configs\ui\zone_map_16.xml")  # read-only reference stand, if present

REF_X, REF_Y = 1.242, 0.8673  # GAMMA's zone_map_16.xml level_frame
REF_ASPECT = 16 / 9
MAP_RADIUS = 0.152 / 2  # the round map, in screen heights


def right_margin(x, aspect):
    """Distance from the frame centre to the right edge, in screen heights."""
    return (1.0 - 0.75 * x) * aspect


REF_MARGIN = right_margin(REF_X, REF_ASPECT)  # 0.1218 H


def parse(raw):
    """The element tree without comments and layout whitespace."""
    root = ET.fromstring(raw)
    for el in root.iter():
        el.text = (el.text or "").strip()
        el.tail = (el.tail or "").strip()
    return root


def frame(name):
    root = parse((UI / name).read_bytes())
    node = root.find("minimap/level_frame")
    return root, float(node.get("x")), float(node.get("y"))


def test_reference_margins():
    assert abs(REF_MARGIN - 0.12178) < 1e-4
    assert abs((1.0 - REF_Y) - 0.1327) < 1e-4


def test_4_3_file_matches_16_9_margins():
    _, x, y = frame("zone_map.xml")
    assert y == REF_Y
    for aspect in (4 / 3,):
        assert abs(right_margin(x, aspect) - REF_MARGIN) < 0.001
    # 5:4 (1280x1024) loads the same file: still bottom-right, the map fully on screen
    assert 0.10 < right_margin(x, 1280 / 1024) < REF_MARGIN
    assert right_margin(x, 1280 / 1024) > MAP_RADIUS


def test_21_9_file_matches_16_9_margins():
    _, x, y = frame("zone_map_21.xml")
    assert y == REF_Y
    for aspect in (2560 / 1080, 3440 / 1440, 21 / 9):
        assert abs(right_margin(x, aspect) - REF_MARGIN) < 0.003, aspect  # 0.003 H: 3 px at 1080
    # 32:9 (5120x1440) and a 16:9 window's client area (1904x1041, aspect 1.829) load it too: bottom-right, map on screen
    for aspect in (5120 / 1440, 1904 / 1041, 1264 / 681):
        m = right_margin(x, aspect)
        assert MAP_RADIUS < m < 0.19, aspect
        assert 0.75 * x > 0.9, aspect  # the centre is in the right tenth of the UI width


def test_overrides_are_gammas_16_file_but_x():
    a, _, _ = frame("zone_map.xml")
    b, _, _ = frame("zone_map_21.xml")
    for root in (a, b):
        root.find("minimap/level_frame").set("x", "X")
    assert ET.tostring(a) == ET.tostring(b)
    if GAMMA_16.exists():  # the reference stand of this machine; CI has no GAMMA
        g = parse(GAMMA_16.read_bytes())
        assert float(g.find("minimap/level_frame").get("x")) == REF_X
        assert float(g.find("minimap/level_frame").get("y")) == REF_Y
        g.find("minimap/level_frame").set("x", "X")
        assert ET.tostring(g) == ET.tostring(a)


def test_overrides_keep_crlf_and_ascii():
    for name in ("zone_map.xml", "zone_map_21.xml"):
        raw = (UI / name).read_bytes()
        raw.decode("ascii")
        assert b"\n" not in raw.replace(b"\r\n", b"")
        assert b"--" not in raw.split(b"<!--", 1)[1].split(b"-->", 1)[0]  # a comment must not hold "--"
