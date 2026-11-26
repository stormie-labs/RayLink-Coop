"""Run actual FireEnd/UpdateCL methods against the real firing-loop predicate."""
from pathlib import Path
import re
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def pending_fire_runner(module_work):
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
    fixture = module_work / "clone_pending_fire.cpp"
    fixture.write_text(source, encoding="utf-8")
    return build(module_work, "cl /nologo /EHsc /std:c++17 /W4 /Od /utf-8", [fixture],
                 module_work / "clone_pending_fire.exe")


@pytest.mark.parametrize("mode", ["latches", "queued-state", "custom-handler", "ordinary"])
def test_pending_clone_stops_latched_and_queued_fire(pending_fire_runner, mode):
    result = subprocess.run([str(pending_fire_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
