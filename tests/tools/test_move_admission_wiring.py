"""Execute the engine's admitted_move and player_move (R32 WP18 P4, section 8a A21 E-3).

The two functions are cut out of engine/src/xrGame/coop/coop_requests_moves.cpp (as test_trade_delivery.py cuts apply_move)
and compiled with fixtures/move_admission_wiring.cpp over the real pure header engine/src/xrCoop/coop_move_admission.h.
They run where a move is decided: the Coop host, and in the Server mode the map server of the player's level (and the
world server for its own script moves); the rule itself has no mode check.

  COOP_REQUESTS_CPP=<file> cut the functions out of this copy of coop_requests_moves.cpp instead (mutation checks)
"""
import os
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition

SCENARIOS = [
    "ground-from-box", "ground-from-player",
    "player-refuse-text", "player-refuse-default", "host-actor-refuse", "inside-player-refuse",
    "player-admit", "player-no-rule", "host-actor-no-rule", "player-failed", "player-apply-fails",
    "container-admit", "container-refuse-text", "container-refuse-default", "container-no-rule",
    "container-failed", "container-apply-fails",
]


@pytest.fixture(scope="module")
def wiring_runner(module_work):
    requests = Path(os.environ.get("COOP_REQUESTS_CPP") or ROOT / "engine/src/xrGame/coop/coop_requests_moves.cpp")
    source = requests.read_text(encoding="utf-8-sig")
    # player_move only when the source has it (an older admitted_move without it must still compile, and fail).
    signatures = [s for s in ("Reason player_move(", "Reason admitted_move(") if s in source]
    assert signatures[-1] == "Reason admitted_move(", "admitted_move not found in " + str(requests)
    (module_work / "admitted_move.inc").write_text("\n".join(definition(source, s) for s in signatures), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/move_admission_wiring.cpp"
    # C4715 (a path without a return) is an error: a dropped `return Reason::NotAllowed` must not pass as garbage.
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8 /W4 /we4715", [fixture],
                 module_work / "move_admission_wiring.exe", includes=[module_work, ROOT / "engine/src/xrCoop"])


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_admitted_move_asks_a_player_destination_without_the_book(wiring_runner, scenario):
    run = subprocess.run([str(wiring_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
