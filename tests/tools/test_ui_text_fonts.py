"""Every <text> node in our UI XML names a font. CUIXmlInit::InitText (engine src/xrGame/ui/UIXmlInit.cpp) runs for the
`text` child of any node handed to InitStatic / InitTextWnd / InitCheck ... and R_ASSERTs the font: a `text` child without
`font=` is a FATAL «pTmpFont» the moment the script builds that window (build 9: team_row's child window was named `text`)."""
import xml.etree.ElementTree as ET

from conftest import ROOT

UI = ROOT / "gamedata" / "configs" / "ui"


def ui_files():
    files = sorted(p for p in UI.rglob("*.xml") if "textures_descr" not in p.parts)
    assert files
    return files


def test_every_text_node_names_a_font():
    missing = []
    for path in ui_files():
        root = ET.fromstring(path.read_bytes())
        for node in root.iter("text"):
            if not node.get("font"):
                missing.append(f"{path.relative_to(ROOT)}: <text {node.attrib}>")
    assert not missing, "text nodes without font= (engine FATAL pTmpFont):\n" + "\n".join(missing)
