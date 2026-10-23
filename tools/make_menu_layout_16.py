"""Anomaly Coop co-op window: the 16:9 layout configs\\ui\\ui_coop_menu_16.xml from the 4:3 one, configs\\ui\\ui_coop_menu.xml.

The engine loads <name>_16.xml instead of <name>.xml on a wide screen when it exists (ui_core::get_xml_name; 21:9 falls back to
_16, then to the plain file) and maps the 1024x768 UI space onto the screen with a different scale per axis. A layout drawn for
4:3 is therefore 4/3 too wide on 16:9 while the glyphs keep their shape (the dot and the icons would be wide ellipses, the
window 2.1:1 instead of 1.6:1). The stock *_16.xml files compress x and width by 0.75; this does the same for everything inside
the window: x and width of every node (and of the <text x="..."> offsets) times 0.75, the window itself centred; y and height
stay. coop_shade (the full-screen dimming) is left as it is.

Usage: python tools/make_menu_layout_16.py [--check]
  writes gamedata/configs/ui/ui_coop_menu_16.xml (LF, windows-1251 header like the 4:3 file); --check only compares.
The Lua test (tests\\lua\\test_menu.lua) fails when the two files drift apart: edit the 4:3 file, then run this.
"""
import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "gamedata" / "configs" / "ui" / "ui_coop_menu.xml"
WIDE = ROOT / "gamedata" / "configs" / "ui" / "ui_coop_menu_16.xml"
K = 0.75  # (1024 / 768) / (16 / 9)
UI_WIDTH = 1024.0

NOTE = (
    "<!-- 16:9 version of ui_coop_menu.xml, made by tools\\make_menu_layout_16.py (do not edit by hand: edit the 4:3 file and run\n"
    "     the tool). The engine loads it instead of the 4:3 file on a wide screen. x and width of everything inside the window\n"
    "     are those of the 4:3 file times 0.75 (the stock *_16.xml way), the window is centred; y and height are the same. -->\n"
)


def num(v):
    v = round(v, 2)
    return str(int(v)) if v == int(v) else ("%.2f" % v).rstrip("0")


def scale_tag(tag, container):
    def sub(attr):
        def f(m):
            return '%s="%s"' % (attr, num(float(m.group(1)) * K))

        return f

    out = re.sub(r'(?<![\w])x="(-?[\d.]+)"', sub("x"), tag)
    out = re.sub(r'(?<![\w])width="(-?[\d.]+)"', sub("width"), out)
    if container:
        width = float(re.search(r'width="([\d.]+)"', out).group(1))
        out = re.sub(r'(?<![\w])x="[-\d.]+"', 'x="%s"' % num((UI_WIDTH - width) / 2), out, count=1)
    return out


def build(src):
    head, sep, body = src.partition("<coop_menu ")
    assert sep, "no <coop_menu> in the 4:3 layout"
    body = sep + body
    out, pos = [], 0
    for m in re.finditer(r"<!--.*?-->|<[A-Za-z_][^>]*>", body, re.S):
        out.append(body[pos:m.start()])
        tag = m.group(0)
        out.append(tag if tag.startswith("<!--") else scale_tag(tag, container=tag.startswith("<coop_menu ")))
        pos = m.end()
    out.append(body[pos:])
    text = head + "".join(out)
    first_comment_end = text.index("-->") + 4  # after "-->\n": the file's own header comment
    return text[:first_comment_end] + NOTE + text[first_comment_end:]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 when the 16:9 file is not what the tool would write")
    args = ap.parse_args()
    text = build(BASE.read_text(encoding="utf-8", newline=""))
    if args.check:
        same = WIDE.exists() and WIDE.read_text(encoding="utf-8", newline="") == text
        print("ui_coop_menu_16.xml is %s" % ("up to date" if same else "OUT OF DATE (run tools/make_menu_layout_16.py)"))
        return 0 if same else 1
    WIDE.write_text(text, encoding="utf-8", newline="")
    print("%s (%d bytes)" % (WIDE, WIDE.stat().st_size))
    return 0


if __name__ == "__main__":
    sys.exit(main())
