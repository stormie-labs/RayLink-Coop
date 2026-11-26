"""Run the actual weapon HUD-info methods across inventory detachment and return."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def brief_info_runner(module_work):
    engine = ROOT / "engine/src"
    info = definition(engine / "xrServerEntities/inventory_space.h", "struct II_BriefInfo")
    (module_work / "brief_info_type.inc").write_text(info + ";\n", encoding="utf-8")
    methods = [
        definition(engine / "xrGame/WeaponMagazined.cpp", "bool CWeaponMagazined::GetBriefInfo("),
        definition(engine / "xrGame/WeaponMagazinedWGrenade.cpp", "bool CWeaponMagazinedWGrenade::GetBriefInfo("),
    ]
    (module_work / "brief_info_methods.inc").write_text("\n".join(methods), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/weapon_brief_info.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture], module_work / "brief_info.exe",
                 includes=[module_work])


@pytest.mark.parametrize("mode", ["magazine", "launcher-bullets", "launcher-grenades"])
def test_detached_weapon_clears_hud_and_rebuilds_after_return(brief_info_runner, mode):
    result = subprocess.run([str(brief_info_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{mode} exited {result.returncode:#x}\n{result.stdout}\n{result.stderr}"
