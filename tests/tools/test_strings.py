"""Every st_coop_* string the engine shows (hud_message / CStringTable().translate) exists in eng and rus."""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

from conftest import ROOT

ENGINE_SRC = ROOT / "engine" / "src"
TEXT = ROOT / "gamedata" / "configs" / "text"


def engine_ids() -> set[str]:
    ids = set()
    for path in ENGINE_SRC.rglob("*.cpp"):
        ids |= set(re.findall(r'"(st_coop_[A-Za-z0-9_]+)"', path.read_text(encoding="utf-8", errors="replace")))
    return ids


def table_ids(lang: str) -> set[str]:
    ids = set()
    for path in (TEXT / lang).glob("*.xml"):
        ids |= {s.get("id") for s in ET.fromstring(path.read_bytes()).iter("string")}
    return ids


@pytest.mark.skipif(not ENGINE_SRC.is_dir(), reason="engine sources are not checked out")
@pytest.mark.parametrize("lang", ["eng", "rus"])
def test_engine_strings_translated(lang):
    used = engine_ids()
    assert used, "no st_coop_* ids found in the engine sources"
    assert sorted(used - table_ids(lang)) == []


@pytest.mark.parametrize("lang", ["eng", "rus"])
def test_text_files_keep_their_format(lang):
    for path in (TEXT / lang).glob("*.xml"):
        raw = path.read_bytes()
        assert raw.startswith(b'<?xml version="1.0" encoding="windows-1251"?>'), path.name
        assert b"\n" not in raw.replace(b"\r\n", b""), f"{path.name}: line ends must be CRLF"
        raw.decode("cp1251")
