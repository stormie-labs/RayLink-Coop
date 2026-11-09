"""Run actual FireEnd/UpdateCL methods against the real firing-loop predicate."""
import os
from pathlib import Path
import re
import subprocess
import uuid

import pytest

from test_weapon_clone_wgl import definition

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def pending_fire_runner():
    work = ROOT / "temp/clone-placement-2026-11-09/pending-fire" / uuid.uuid4().hex[:8]
    work.mkdir(parents=True)
    game = ROOT / "engine/src/xrGame"
    methods = "\n".join((
        definition(game / "ShootingObject.cpp", "void CShootingObject::FireEnd("),
        definition(game / "WeaponFire.cpp", "void CWeapon::FireEnd("),
        definition(game / "WeaponMagazined.cpp", "void CWeaponMagazined::FireEnd("),
        definition(game / "WeaponMagazined.cpp", "void CWeaponMagazined::UpdateCL("),
    ))
    firing = definition(game / "WeaponMagazined.cpp", "void CWeaponMagazined::state_Fire(")
    predicate = re.search(r"while\s*\((.+?)\)\s*\{", firing, re.DOTALL)
    assert predicate, "The production firing-loop predicate must be present"
    source = (Path(__file__).parent / "fixtures/clone_pending_fire.cpp").read_text(encoding="utf-8")
    source = source.replace("// ACTUAL_METHODS", methods).replace("ACTUAL_FIRE_PREDICATE", predicate.group(1))
    (work / "clone_pending_fire.cpp").write_text(source, encoding="utf-8")
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.is_file(), "MSVC Build Tools required"
    runner = work / "clone_pending_fire.exe"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /W4 /Od /utf-8 "{work / "clone_pending_fire.cpp"}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", ["latches", "queued-state", "custom-handler", "ordinary"])
def test_pending_clone_stops_latched_and_queued_fire(pending_fire_runner, mode):
    result = subprocess.run([str(pending_fire_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
