"""Exercise the production world-event relay, Lua registration, and session cleanup."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, declaration, definition


def build_runner(work: Path, source: str) -> Path:
    # Keep the relay, parsing, and queueing code together. Only their engine boundaries are stubbed.
    types = [definition(source, signature) + ";" for signature in ("struct Incoming", "struct Stats")]
    types.append(declaration(source, "constexpr u64 kLogBurst"))
    methods = (definition(source, signature) for signature in (
        "bool valid_name(", "void write_event(", "void deliver_later(",
        "void host_relay(", "bool read_event(", "void server_on_script_event(",
        "int l_reserve_world_event(", "void on_session_end(",
    ))
    (work / "world_events_types.inc").write_text("\n".join(types), encoding="utf-8")
    (work / "world_events_methods.inc").write_text("\n".join(methods), encoding="utf-8")

    fixture = Path(__file__).with_name("fixtures") / "world_events_slice.cpp"
    engine = ROOT / "engine/src"
    return build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture, engine / "xrCoop/coop_wire.cpp"],
                 work / "world_events_slice.exe", includes=[work, engine])


@pytest.fixture(scope="module")
def world_events_runner(module_work):
    source = ROOT / "engine/src/xrGame/coop/coop_script.cpp"
    return build_runner(module_work, source.read_text(encoding="utf-8-sig"))


@pytest.mark.parametrize("scenario", [
    "reserved-broadcast", "reserved-player", "reserved-world", "ordinary-bridge",
    "coop-guest", "coop-host", "lua-registration", "session-end", "session-end-after-refusal",
])
def test_world_events_slice(world_events_runner, scenario):
    result = subprocess.run([str(world_events_runner), scenario], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{scenario} exited {result.returncode}\n{result.stdout}{result.stderr}"
