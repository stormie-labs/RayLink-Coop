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


def _installs() -> dict[frozenset, list[tuple[str, str, str]]]:
    """conditionalFileInstalls: {frozenset of (flag, value)}: [(tag, source, destination)]."""
    result = {}
    for pattern in fomod_root().findall("./conditionalFileInstalls/patterns/pattern"):
        flags = frozenset((d.get("flag"), d.get("value")) for d in pattern.iter("flagDependency"))
        result[flags] = [(f.tag, f.get("source"), f.get("destination")) for f in pattern.find("files")]
    return result


def test_fomod_installs_three_mod_folders() -> None:
    installs = _installs()
    assert installs[frozenset({("part", "core")})] == [("folder", CORE, "")]
    assert installs[frozenset({("part", "gamma")})] == [("folder", GAMMA, "")]
    assert installs[frozenset({("part", "engine"), ("exe", "mod")})] == [("folder", ENGINE, "")]
    assert len(installs) == 4


def test_copy_way_keeps_the_exe_out_of_the_mods_bin() -> None:
    """Way 2 copies the exe into <Anomaly>/bin; an exe left in the mod's bin/ would win in MO2's VFS and run from
    mods/.../bin instead (no ReShade, the copy pointless). So that pattern installs the exe elsewhere."""
    files = _installs()[frozenset({("part", "engine"), ("exe", "copy")})]
    exe = [f for f in files if f[1].replace("/", "\\").lower().endswith("anomalycoopdx11avx.exe")]
    assert len(exe) == 1 and exe[0][0] == "file"
    assert not exe[0][2].replace("/", "\\").lower().startswith("bin\\")
    assert ("folder", ENGINE + "\\gamedata", "gamedata") in files


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
             "-Version", version, "-Force", "-EngineBuild", "any"],
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
        # every folder and file the installer copies must exist in the archive
        for folder in fomod_root().iter("folder"):
            prefix = folder.get("source").replace("\\", "/") + "/"
            assert any(n.startswith(prefix) for n in names), f"installer source not in archive: {prefix}"
        for file in fomod_root().iter("file"):
            assert file.get("source").replace("\\", "/") in names, f"installer source not in archive: {file.get('source')}"
        assert f"<Version>{version}</Version>" in info_xml
        for part in (ENGINE, CORE, GAMMA):
            assert part in release_txt
        assert "engine        RayLink Engine" in release_txt
    finally:
        if zip_path.exists():
            zip_path.unlink()


# --- the engine build of a package (tools/package.ps1 + engine/src/xrCore/raylink_version.h): the exe says
# "RayLink Engine bN" (a zero-terminated literal), the package version 0.N.0 must agree. Fake exes: no engine build needed.
needs_powershell = pytest.mark.skipif(shutil.which("powershell") is None, reason="needs Windows PowerShell")


def _fake_exe(folder: Path, *stamps: bytes) -> Path:
    exe = folder / "AnomalyDX11AVX.exe"
    body = b"MZ" + b"\0" * 510
    for stamp in stamps:
        body += b"RayLink Engine " + stamp + b"\0" + b"\0" * 64
    # a longer text that starts with the same words is not a stamp (crash dialog title)
    body += b"RayLink Engine b99 - Fatal Error\0"
    exe.write_bytes(body + b"\0" * 512)
    return exe


def _package(version: str, exe: Path, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(PACKAGE_PS1),
         "-Version", version, "-BuiltExe", str(exe), "-Force", *extra],
        cwd=ROOT, capture_output=True, text=True, timeout=600,
    )


def _release_text(version: str) -> str:
    zip_path = ROOT / "releases" / f"anomaly-coop-{version}.zip"
    try:
        with zipfile.ZipFile(zip_path) as archive:
            return archive.read("anomaly-coop-release.txt").decode("utf-8")
    finally:
        zip_path.unlink()


@needs_powershell
def test_package_refuses_an_exe_of_another_build(work: Path) -> None:
    run = _package("0.8.0-pytest", _fake_exe(work, b"b7"))
    out = run.stdout + run.stderr
    assert run.returncode != 0
    assert "RayLink Engine b7" in out and "RayLink Engine b8" in out and "ci_sync.py --build 8" in out
    assert not (ROOT / "releases" / "anomaly-coop-0.8.0-pytest.zip").exists()


@needs_powershell
def test_package_refuses_unstamped_and_ambiguous_exes(work: Path) -> None:
    unstamped = _package("0.8.0-pytest", _fake_exe(work))
    assert unstamped.returncode != 0 and "no RayLink Engine build stamp" in unstamped.stdout + unstamped.stderr
    dev = _package("0.8.0-pytest", _fake_exe(work), "-EngineBuild", "dev")
    assert dev.returncode != 0
    two = _package("0.8.0-pytest", _fake_exe(work, b"b8", b"dev"))
    assert two.returncode != 0 and "more than one" in two.stdout + two.stderr
    bad = _package("0.8.0-pytest", _fake_exe(work, b"b8"), "-EngineBuild", "eight")
    assert bad.returncode != 0 and "-EngineBuild must be" in bad.stdout + bad.stderr
    assert not (ROOT / "releases" / "anomaly-coop-0.8.0-pytest.zip").exists()


@needs_powershell
def test_package_records_the_engine_build(work: Path) -> None:
    # the normal case: package 0.7.0 of an exe built with ci_sync.py --build 7
    run = _package("0.7.0-pytest", _fake_exe(work, b"b7"))
    assert run.returncode == 0, run.stdout + run.stderr
    assert "engine        RayLink Engine b7, commit " in _release_text("0.7.0-pytest")


@needs_powershell
def test_package_scripts_only_build_names_the_older_engine(work: Path) -> None:
    # a scripts-only build: package 0.8.0 with the b7 exe, said on purpose
    run = _package("0.8.0-pytest", _fake_exe(work, b"b7"), "-EngineBuild", "7")
    assert run.returncode == 0, run.stdout + run.stderr
    assert "engine        RayLink Engine b7, commit " in _release_text("0.8.0-pytest")
