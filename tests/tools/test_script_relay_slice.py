"""B-REV F7 (FIX-NIMBLE): the world server's production relay of script events, coop_script.cpp server_on_script_event.

A map server's event to everybody (target -1) reaches the players only (each his own copy, as its own flush_outbox sends
them), never another map server, which would take the copy (origin 0) as the world's word (mods.nim_held). The function is
compiled from the engine's source with its helpers; only the session and the transport are stubbed
(tests/tools/fixtures/script_relay_slice.cpp).
"""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, declaration, definition

SOURCE = ROOT / "engine/src/xrGame/coop/coop_script.cpp"
TYPES = ("struct Incoming", "struct Stats")
METHODS = (
    "bool valid_name(", "void write_event(", "void deliver_later(",
    "void host_relay(", "bool read_event(", "void server_on_script_event(",
)
SCENARIOS = (
    "bridge-broadcast", "bridge-broadcast-no-players", "bridge-reserved-broadcast", "bridge-to-player",
    "bridge-to-world", "bridge-to-bridge", "player-broadcast", "coop-host-broadcast", "coop-guest-broadcast",
)


def build_runner(work: Path, source: str) -> Path:
    """Compiles the fixture with the relay functions taken from `source` (the text of coop_script.cpp)."""
    types = [definition(source, signature) + ";" for signature in TYPES]
    types.append(declaration(source, "constexpr u64 kLogBurst"))
    (work / "script_relay_types.inc").write_text(
        "\n".join(types), encoding="utf-8")
    (work / "script_relay_methods.inc").write_text(
        "\n".join(definition(source, signature) for signature in METHODS), encoding="utf-8")
    fixture = Path(__file__).with_name("fixtures") / "script_relay_slice.cpp"
    engine = ROOT / "engine/src"
    return build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture, engine / "xrCoop/coop_wire.cpp"],
                 work / "script_relay_slice.exe", includes=[work, engine])


@pytest.fixture(scope="module")
def relay_runner(module_work):
    return build_runner(module_work, SOURCE.read_text(encoding="utf-8-sig"))


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_script_relay_slice(relay_runner, scenario):
    result = subprocess.run([str(relay_runner), scenario], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{scenario} exited {result.returncode}\n{result.stdout}{result.stderr}"
