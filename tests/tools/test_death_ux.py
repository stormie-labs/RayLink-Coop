"""Build 10, death UX (.superpowers/sdd/2026-10-23-hud-v2/death-ux-brief.md, part B): the "nothing is lost" mode (keep)
and the share multiplier (coop_death_share) on the new game screen of a host and on the Options > Co-op page.
The layout of the new game block exists twice (4:3 and 16:9) and must keep the same rows; the strings exist in both
languages."""
import xml.etree.ElementTree as ET

import pytest

from conftest import ROOT

UI = ROOT / "gamedata" / "configs" / "ui"
TEXT = ROOT / "gamedata" / "configs" / "text"
FRAME_HEIGHT = 160  # main_dialog:scroll_options of the stock screen: what is visible without scrolling
LAYOUTS = {"ui_coop_newgame.xml": 880, "ui_coop_newgame_16.xml": 704}  # file -> width of the options frame
ROWS = ["list_coop_death_mode", "list_coop_death_drop", "list_coop_death_share", "list_coop_autosave"]

NEW_IDS = {
    "st_coop_newgame.xml": ["st_coop_newgame_drop_keep", "st_coop_newgame_share", "st_coop_newgame_share_normal"],
    "st_coop_death.xml": [
        "st_coop_opt_drop_keep",
        "ui_mm_coop_coop_session_death_share",
        "ui_mm_coop_coop_session_death_share_desc",
        "st_coop_opt_share_50",
        "st_coop_opt_share_100",
        "st_coop_opt_share_150",
        "st_coop_opt_share_200",
    ],
}


def elements(name: str) -> list[ET.Element]:
    options = ET.fromstring((UI / name).read_bytes()).find("main_dialog/options")
    assert options is not None, name
    return list(options)


def box(e: ET.Element) -> tuple[int, int, int, int]:
    return int(e.get("x")), int(e.get("y")), int(e.get("width")), int(e.get("height"))


def test_wide_layout_has_the_same_rows():
    """The 16:9 file has the elements of the 4:3 one, in the same order and at the same heights (only x and widths
    differ)."""
    a, b = elements("ui_coop_newgame.xml"), elements("ui_coop_newgame_16.xml")
    assert [e.tag for e in a] == [e.tag for e in b]
    assert [(box(e)[1], box(e)[3]) for e in a] == [(box(e)[1], box(e)[3]) for e in b]


@pytest.mark.parametrize("name", sorted(LAYOUTS))
def test_block_has_four_rows_inside_the_frame(name):
    els = {e.tag: box(e) for e in elements(name)}
    for tag, (x, y, w, h) in els.items():
        assert x >= 0 and x + w <= LAYOUTS[name] and y >= 0 and y + h <= FRAME_HEIGHT, f"{name}: {tag} {x, y, w, h}"
    rows = [els[r] for r in ROWS]
    for upper, lower in zip(rows, rows[1:]):
        assert upper[1] + upper[3] <= lower[1], f"{name}: rows overlap"
    for r in ROWS:
        cx, cy, cw, ch = els["cap_" + r]
        lx, ly, lw, lh = els[r]
        assert cx + cw <= lx and ly <= cy and cy + ch <= ly + lh, f"{name}: caption of {r} is not left of its list"
    header, hint = els["cap_coop_header"], els["text_coop_hint"]
    assert header[1] + header[3] <= rows[0][1], f"{name}: the header is not above the rows"
    assert hint[1] >= rows[-1][1] + rows[-1][3], f"{name}: the hint is not under the rows"


@pytest.mark.parametrize("lang", ["eng", "rus"])
@pytest.mark.parametrize("file", sorted(NEW_IDS))
def test_new_strings(lang, file):
    ids = {s.get("id"): s.findtext("text") for s in ET.fromstring((TEXT / lang / file).read_bytes()).iter("string")}
    missing = [i for i in NEW_IDS[file] if not ids.get(i)]
    assert missing == []
