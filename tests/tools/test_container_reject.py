"""Execute the engine's own container functions on "taken out" of an item they do not hold (O1-container).

Crash reports of builds 56-57: CInventoryBox::OnEvent erased end() of its id list (RL-QHQ3-2TUG, RL-NHT6-8SZ3, RL-29NA-4ZS6),
CAI_Trader::OnEvent read a null item during net_Stop (RL-WKWE-CPCY); CLevel::cl_Process_Event told the holder of a
GE_DESTROY_REJECT whose child is no game object here; CInventoryItem::net_Destroy left a destroyed item in a live holder's
lists (plausible #1710-1712). The four functions are cut out of the stock engine files (as test_move_admission_wiring.py cuts
admitted_move) and compiled with fixtures/container_reject.cpp over the real pure header
engine/src/xrCoop/coop_container_rules.h. Both modes run them unchanged: a co-op client and a player's client of a map
server apply the decider's moves through their local server.

  COOP_ENGINE_SRC=<dir>  cut the functions out of this copy of engine/src instead (mutation checks)
"""
import os
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition

FUNCTIONS = [
    ("xrGame/Level.cpp", "void CLevel::cl_Process_Event("),
    ("xrGame/InventoryBox.cpp", "void CInventoryBox::OnEvent("),
    ("xrGame/ai/trader/ai_trader.cpp", "void CAI_Trader::OnEvent("),
    ("xrGame/inventory_item.cpp", "void CInventoryItem::net_Destroy()"),
]

SCENARIOS = [
    "level-reject-no-child", "level-reject-child", "level-other-event",
    "box-reject-unlisted", "box-reject-missing", "box-reject-stale", "box-reject-held", "box-reject-held-keep-shell",
    "box-sell-held", "box-reject-held-elsewhere", "box-take",
    "trader-reject-missing", "trader-reject-foreign", "trader-reject-own", "trader-sell-own",
    "item-destroy-ruck", "item-destroy-belt", "item-destroy-slot", "item-destroy-owner-gone", "item-destroy-let-go",
    "item-destroy-no-inventory",
]


@pytest.fixture(scope="module")
def reject_runner(module_work):
    engine = Path(os.environ.get("COOP_ENGINE_SRC") or ROOT / "engine/src")
    (module_work / "container_reject.inc").write_text(
        "\n".join(definition(engine / path, signature) for path, signature in FUNCTIONS), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/container_reject.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8 /W3", [fixture],
                 module_work / "container_reject.exe", includes=[module_work, ROOT / "engine/src/xrCoop"])


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_container_lets_go_only_of_what_it_holds(reject_runner, scenario):
    run = subprocess.run([str(reject_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, f"exit {run.returncode:#x}\n" + run.stdout + run.stderr
