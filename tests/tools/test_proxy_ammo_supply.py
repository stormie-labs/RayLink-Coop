"""Player avatars must not inherit the NPC supply of replacement ammunition."""
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from test_weapon_brief_info import ROOT, definition


@pytest.fixture
def ammo_supply_runner(work):
    source = ROOT / "engine/src/xrGame/object_handler.cpp"
    methods = [definition(source, signature) for signature in (
        "BOOL CObjectHandler::net_Spawn(", "void CObjectHandler::OnItemDrop(")]
    (work / "ammo_supply_methods.inc").write_text("\n".join(methods), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/proxy_ammo_supply.cpp"
    runner = work / ("ammo_supply.exe" if os.name == "nt" else "ammo_supply")
    if os.name == "nt":
        vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
        assert vcvars.exists(), "MSVC Build Tools are required"
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" "{fixture}" /Fe"{runner}"\n'
            'exit /b %ERRORLEVEL%\n', encoding="utf-8")
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        assert compiler, "A C++17 compiler is required"
        build = [compiler, "-std=c++17", "-O0", f"-I{work}", str(fixture), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", [
    "player", "parked-player", "npc", "npc-disabled", "npc-dead", "full-box", "partial-box",
])
def test_empty_box_destruction_keeps_player_supply_finite(ammo_supply_runner, mode):
    result = subprocess.run([str(ammo_supply_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
