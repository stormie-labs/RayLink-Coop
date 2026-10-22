"""Packaging of the three MO2 mods: fomod\\ModuleConfig.xml, packaging\\readme_*.txt, tools\\package.ps1.

Run from the repo root: python -m pytest tests/tools/test_packaging.py -q
"""
import shutil
import subprocess
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FOMOD = ROOT / "fomod" / "ModuleConfig.xml"
INFO = ROOT / "fomod" / "info.xml"
README_RUS = ROOT / "packaging" / "readme_rus.txt"
README_ENG = ROOT / "packaging" / "readme_eng.txt"
README_GAMMA = ROOT / "packaging" / "readme_gamma.txt"
REGISTRY = ROOT / "docs" / "MOD_REPLACEMENTS.md"
PACKAGE_PS1 = ROOT / "tools" / "package.ps1"
BUILT_EXE = ROOT / "engine-ci" / "_build" / "_game" / "bin_dbg" / "AnomalyDX11AVX.exe"

ENGINE = "Anomaly Coop - Engine"
CORE = "Anomaly Coop - Core"
GAMMA = "Anomaly Coop - GAMMA"
UKRAINIAN_LETTERS = set("іїєґІЇЄҐ")


def fomod_root() -> ET.Element:
    return ET.parse(FOMOD).getroot()


def fomod_text() -> str:
    """Every attribute value and text node of ModuleConfig.xml (XML entities already resolved)."""
    parts: list[str] = []
    for node in fomod_root().iter():
        parts.extend(node.attrib.values())
        if node.text:
            parts.append(node.text)
    return "\n".join(parts)


def mods_to_disable() -> list[str]:
    """First column of docs/MOD_REPLACEMENTS.md for rows 'выключить...' that come from GAMMA."""
    names: list[str] = []
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 5:
            continue
        name, source, action = cells[0].strip("`"), cells[1], cells[2]
        if action.lower().startswith("выключить") and source.startswith("GAMMA"):
            names.append(name)
    return names


def test_fomod_xml_parses() -> None:
    root = fomod_root()
    assert root.tag == "config"
    assert ET.parse(INFO).getroot().tag == "fomod"
    # XSD 5.0 order; the three folders are installed conditionally, so no requiredInstallFiles.
    assert [c.tag for c in root] == ["moduleName", "installSteps", "conditionalFileInstalls"]


def test_fomod_installs_three_mod_folders() -> None:
    root = fomod_root()
    patterns = root.findall("./conditionalFileInstalls/patterns/pattern")
    assert len(patterns) == 3
    installed: dict[str, tuple[str, str]] = {}
    folders = 0
    for pattern in patterns:
        flags = pattern.findall("./dependencies/flagDependency")
        assert len(flags) == 1 and flags[0].get("flag") == "part"
        found = pattern.findall("./files/folder")
        assert len(found) == 1
        folders += 1
        installed[flags[0].get("value")] = (found[0].get("source"), found[0].get("destination"))
    assert folders == 3
    assert installed == {
        "engine": (ENGINE, ""),
        "core": (CORE, ""),
        "gamma": (GAMMA, ""),
    }


def test_fomod_flags_are_set_somewhere() -> None:
    root = fomod_root()
    set_flags = {(f.get("name"), (f.text or "").strip()) for f in root.iter("flag")}
    used = {(d.get("flag"), d.get("value")) for d in root.iter("flagDependency")}
    assert used, "no flagDependency at all"
    assert used <= set_flags, f"flags used but never set: {sorted(used - set_flags)}"


def test_fomod_part_choice_matches_installs() -> None:
    """The 'part' flag values a player can pick are exactly the ones conditionalFileInstalls reacts to."""
    root = fomod_root()
    picked = {
        (f.text or "").strip()
        for f in root.iter("flag")
        if f.get("name") == "part"
    }
    assert picked == {"engine", "core", "gamma"}


def test_mods_to_disable_listed() -> None:
    names = mods_to_disable()
    assert len(names) >= 4, f"registry parse found only {names}"
    xml_text = fomod_text()
    rus = README_RUS.read_text(encoding="utf-8-sig")
    eng = README_ENG.read_text(encoding="ascii")
    for name in names:
        assert name in xml_text, f"{name!r} missing in ModuleConfig.xml"
        assert name in rus, f"{name!r} missing in readme_rus.txt"
        assert name in eng, f"{name!r} missing in readme_eng.txt"


def test_readme_encodings_and_languages() -> None:
    for path, bom in ((README_RUS, True), (README_GAMMA, True), (README_ENG, False)):
        raw = path.read_bytes()
        assert raw.startswith(b"\xef\xbb\xbf") == bom, f"{path.name}: BOM expectation {bom}"
        body = raw[3:] if bom else raw
        assert b"\r\n" in raw, f"{path.name}: needs CRLF"
        assert b"\n" not in body.replace(b"\r\n", b""), f"{path.name}: bare LF"
        text = body.decode("utf-8")
        assert not (set(text) & UKRAINIAN_LETTERS), f"{path.name}: Ukrainian letters"
    README_ENG.read_bytes().decode("ascii")
    for text in (fomod_text(), README_GAMMA.read_text(encoding="utf-8-sig")):
        assert not (set(text) & UKRAINIAN_LETTERS)


def test_readmes_describe_three_parts() -> None:
    for path in (README_RUS, README_ENG):
        text = path.read_text(encoding="utf-8-sig")
        for name in (ENGINE, CORE, GAMMA):
            assert name in text, f"{path.name}: no {name!r}"
    gamma = README_GAMMA.read_text(encoding="utf-8-sig")
    assert GAMMA in gamma


@pytest.mark.skipif(not BUILT_EXE.exists(), reason="engine-ci build of AnomalyDX11AVX.exe is absent")
@pytest.mark.skipif(shutil.which("powershell") is None, reason="needs Windows PowerShell")
def test_package_archive_layout() -> None:
    version = "0.0.0-test"
    zip_path = ROOT / "releases" / f"anomaly-coop-{version}.zip"
    try:
        run = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(PACKAGE_PS1),
             "-Version", version, "-Force"],
            cwd=ROOT, capture_output=True, text=True, timeout=600,
        )
        assert run.returncode == 0, run.stdout + run.stderr
        assert zip_path.exists()
        with zipfile.ZipFile(zip_path) as archive:
            assert archive.testzip() is None
            names = archive.namelist()
            info_xml = archive.read("fomod/info.xml").decode("utf-8")
            release_txt = archive.read("anomaly-coop-release.txt").decode("utf-8")
        assert not [n for n in names if "\\" in n], "backslash in entry names"
        top = {n.split("/", 1)[0] for n in names}
        assert top == {
            "fomod", ENGINE, CORE, GAMMA,
            "anomaly-coop-release.txt", "readme_eng.txt", "readme_rus.txt",
        }
        for must in (
            "fomod/ModuleConfig.xml",
            "fomod/info.xml",
            f"{ENGINE}/bin/AnomalyCoopDX11AVX.exe",
            f"{CORE}/gamedata/scripts/coop_main.script",
            f"{GAMMA}/readme_gamma.txt",
            "anomaly-coop-release.txt",
            "readme_eng.txt",
            "readme_rus.txt",
        ):
            assert must in names, f"archive misses {must}"
        for folder in (f"{ENGINE}/gamedata/", f"{CORE}/gamedata/", f"{GAMMA}/gamedata/"):
            assert any(n.startswith(folder) for n in names), f"archive misses {folder}"
        # every folder the installer copies must exist in the archive
        for folder in fomod_root().iter("folder"):
            assert folder.get("source") in top, f"installer source not in archive: {folder.get('source')}"
        assert f"<Version>{version}</Version>" in info_xml
        for part in (ENGINE, CORE, GAMMA):
            assert part in release_txt
    finally:
        if zip_path.exists():
            zip_path.unlink()
