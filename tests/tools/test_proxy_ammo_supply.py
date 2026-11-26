"""Player avatars must not inherit the NPC supply of replacement ammunition."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def ammo_supply_runner(module_work):
    source = ROOT / "engine/src/xrGame/object_handler.cpp"
    methods = [definition(source, signature) for signature in (
        "BOOL CObjectHandler::net_Spawn(", "void CObjectHandler::OnItemDrop(")]
    (module_work / "ammo_supply_methods.inc").write_text("\n".join(methods), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/proxy_ammo_supply.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture], module_work / "ammo_supply.exe",
                 includes=[module_work])


@pytest.mark.parametrize("mode", [
    "player", "parked-player", "npc", "npc-disabled", "npc-dead", "full-box", "partial-box",
])
def test_empty_box_destruction_keeps_player_supply_finite(ammo_supply_runner, mode):
    result = subprocess.run([str(ammo_supply_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
