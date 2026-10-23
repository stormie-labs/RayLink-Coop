"""Build 10, death UX (.superpowers/sdd/2026-10-23-hud-v2/death-ux-brief.md, part B): the "nothing is lost" mode (keep)
and the share multiplier (coop_death_share) on the new game screen of a host and on the Options > Co-op page.
The layout of the new game block exists twice (4:3 and 16:9) and must keep the same elements; the strings exist in both
languages. Game settings patch (GS T5): the four lists of the block became the tabs of "Game settings" (keep and the share
are rows of the catalog now, strings st_coop_game_*), so the layout checks follow the block's new elements and the strings
checked here are the block's own (the tabs, the hint, the 'other' text)."""
import xml.etree.ElementTree as ET

import pytest

from conftest import ROOT

UI = ROOT / "gamedata" / "configs" / "ui"
TEXT = ROOT / "gamedata" / "configs" / "text"
FRAME_HEIGHT = 160  # main_dialog:scroll_options of the stock screen: what is visible without scrolling
LAYOUTS = {"ui_coop_newgame.xml": 880, "ui_coop_newgame_16.xml": 704}  # file -> width of the options frame
# top to bottom: the header, the strip of tabs, the scroll view of the open tab, the hint (the row nodes are relative to a row)
BLOCK = ["cap_gs_header", "btn_gs_tab_1", "scroll_gs", "text_gs_hint"]
RELATIVE = {"gs_row", "cap_gs_row", "list_gs_row", "gs_line", "text_gs_line"}

NEW_IDS = {
    "st_coop_newgame.xml": [
        "st_coop_newgame_header",
        "st_coop_newgame_hint",
        "st_coop_newgame_tab_death",
        "st_coop_newgame_tab_party",
        "st_coop_newgame_tab_world",
        "st_coop_newgame_tab_saves",
        "st_coop_newgame_tab_other",
        "st_coop_newgame_other",
        "st_coop_newgame_saves_note",
    ],
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
def test_block_is_inside_the_frame_in_order(name):
    """The block fits the visible frame of the stock options scroll view and is ordered header, tabs, rows, hint."""
    els = {e.tag: box(e) for e in elements(name)}
    for tag, (x, y, w, h) in els.items():
        if tag in RELATIVE:
            continue
        assert x >= 0 and x + w <= LAYOUTS[name] and y >= 0 and y + h <= FRAME_HEIGHT, f"{name}: {tag} {x, y, w, h}"
    header, tabs, scroll, hint = (els[t] for t in BLOCK)
    assert header[1] + header[3] <= tabs[1], f"{name}: the header is not above the tabs"
    assert tabs[1] + tabs[3] <= scroll[1], f"{name}: the tabs are not above the rows"
    assert scroll[1] + scroll[3] <= hint[1], f"{name}: the hint is not under the rows"
    row, cap, combo = els["gs_row"], els["cap_gs_row"], els["list_gs_row"]
    assert cap[0] + cap[2] <= combo[0] and combo[0] + combo[2] <= row[2], f"{name}: caption and combo do not fit the row"
    assert row[2] + 16 <= scroll[2], f"{name}: no room for the scroll bar next to a row"


@pytest.mark.parametrize("lang", ["eng", "rus"])
@pytest.mark.parametrize("file", sorted(NEW_IDS))
def test_new_strings(lang, file):
    ids = {s.get("id"): s.findtext("text") for s in ET.fromstring((TEXT / lang / file).read_bytes()).iter("string")}
    missing = [i for i in NEW_IDS[file] if not ids.get(i)]
    assert missing == []
