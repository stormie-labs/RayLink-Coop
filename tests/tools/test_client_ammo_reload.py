"""Exercise engine reload and ItemState round trips with two local-server worlds."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[2]


def definition(source, signature):
    start = source.index(signature)
    depth = 0
    tokens = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]'
    for match in re.finditer(tokens, source[start:], re.DOTALL):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise ValueError(signature)


@pytest.fixture(scope="module")
def ammo_runner():
    # Native products and pytest's own cache stay on the project temp volume.
    work = ROOT / "temp/client_ammo_reload" / uuid.uuid4().hex[:8]
    work.mkdir(parents=True, exist_ok=True)
    game = ROOT / "engine/src/xrGame"
    source = (game / "coop/coop_items.cpp").read_text(encoding="utf-8-sig")
    types = "\n".join(definition(source, signature) + ";" for signature in (
        "struct ItemData", "struct TakeBase", "struct Owned", "struct Pending"))
    signatures = (
        "void put(", "void write_data(", "bool read_data(", "bool same_upgrades(",
        "u32 diverged_tags(", "void capture_object(", "void capture_blob(",
        "void set_current(", "void set_other(", "void apply_object(", "void apply_entity(",
        "void write_state(", "void send_state(", "u32 take_changes(", "u32 push_keeps(",
        "void scan_local(", "bool client_apply(", "void client_on_state(",
        "void process_pending(", "void host_on_state(", "void host_enforce(",
    )
    methods = "\n".join(definition(source, signature) for signature in signatures)
    methods += "\n" + definition((game / "WeaponAmmo.cpp").read_text(encoding="utf-8-sig"),
                                "bool CWeaponAmmo::Get(")
    methods += "\n" + definition((game / "WeaponMagazined.cpp").read_text(encoding="utf-8-sig"),
                                "void CWeaponMagazined::ReloadMagazine(")
    methods += "\n" + definition((game / "WeaponShotgun.cpp").read_text(encoding="utf-8-sig"),
                                "u8 CWeaponShotgun::AddCartridge(")
    owner_hooks = "\n".join(definition(source, signature) for signature in (
        "void client_before_take(", "void touch(", "bool client_keep_empty_box("))
    # Rendering, hits and ballistics are outside this regression. Execute the actual
    # post-shot ammunition block, including the count/vector consistency assertion.
    fire = definition((game / "WeaponFire.cpp").read_text(encoding="utf-8-sig"),
                      "void CWeapon::FireTrace(")
    shot = "void CWeapon::consume_shot() {\nCCartridge& l_cartridge = m_magazine.back();\n" + fire[fire.rindex("// Ammo"):]
    fixture = work / "client_ammo_reload.cpp"
    harness = (Path(__file__).parent / "fixtures/client_ammo_reload.cpp").read_text(encoding="utf-8")
    fixture.write_text(harness.replace("// ITEM_TYPES", types)
                       .replace("// ENGINE_METHODS", methods + "\n" + shot)
                       .replace("// OWNER_HOOKS", owner_hooks), encoding="utf-8")
    runner = work / ("client_ammo_reload.exe" if os.name == "nt" else "client_ammo_reload")
    wire = ROOT / "engine/src/xrCoop/coop_wire.cpp"
    include = ROOT / "engine/src/xrCoop"
    if os.name == "nt":
        vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
        assert vcvars.exists(), "MSVC Build Tools required"
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{include}" "{fixture}" "{wire}" /Fe"{runner}"\n'
            'exit /b %ERRORLEVEL%\n', encoding="utf-8")
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        assert compiler, "C++17 compiler required"
        build = [compiler, "-std=c++17", f"-I{include}", str(fixture), str(wire), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", [
    "spent-box", "empty-box", "mixed-types", "launcher-bullets", "launcher-grenades",
    "delayed-before-scan", "delayed-after-scan", "duplicate-push", "pending-push",
    "take-baseline", "take-changed", "world-item", "shotgun-empty",
    "offline-push", "two-boxes", "three-magazines", "mixed-magazine",
    "owner-relay", "ownership-return",
    "fallback-type", "partial-reload", "shot-only", "launcher-shot-only",
])
def test_client_ammo_round_trip(ammo_runner, mode):
    result = subprocess.run([str(ammo_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
