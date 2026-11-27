"""Execute the start of the OpenAL sound core (engine/src/xrSound/SoundRender_CoreA.cpp) with and without a sound device.

Server stand, third run of 2026-11-27, carry_server: the client's log stops at "SOUND: OpenAL: system  default SndDevice
name is Default Device" with no device listed (a remote desktop session had just taken the PC's audio endpoints: the
scenarios before it list five devices, the ones after it "Remote Audio"), and the process ends with exit code 1. Stage 0 of
CSoundRender_CoreA::_initialize quit through CHECK_OR_EXIT "OpenAL: Can't create sound device.", so the client never
connected. Now a game without a device plays on with the silent core a map server already uses. CSoundRender_CoreA::
_initialize and run_silent are cut out and compiled with fixtures/sound_core_start.cpp over stand-ins for OpenAL, the device
list and the stock core. Every game process with sound runs this function, whatever its mode (Core: a stock file).

  COOP_SOUND_CORE_CPP=<file>  cut the functions out of this copy instead (mutation checks)
"""
import os
from pathlib import Path
import re
import subprocess

import pytest

from native_slice import ROOT, build, definition

SOURCE = ROOT / "engine/src/xrSound/SoundRender_CoreA.cpp"
SCENARIOS = ["device", "no-device", "open-fails", "context-fails", "silent-asked"]


@pytest.fixture(scope="module")
def sound_runner(module_work):
    source = Path(os.environ.get("COOP_SOUND_CORE_CPP") or SOURCE).read_text(encoding="utf-8-sig")
    initialize = definition(source, "void CSoundRender_CoreA::_initialize(int stage)")
    cut = definition(source, "void CSoundRender_CoreA::run_silent(LPCSTR why)") + "\n" + initialize
    procs = re.findall(r"LOAD_PROC\((\w+), (\w+)\);", initialize)
    assert len(procs) > 20, "the EFX procedures are no longer loaded in _initialize: look at the cut"
    (module_work / "sound_core_procs.inc").write_text(
        "".join(f"using {kind} = void*;\nvoid* {name} = nullptr;\n" for kind, name in procs), encoding="utf-8")
    (module_work / "sound_core_start.inc").write_text(cut + "\n", encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/sound_core_start.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8 /W3 /D_CRT_SECURE_NO_WARNINGS", [fixture],
                 module_work / "sound_core_start.exe", includes=[module_work])


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_a_game_without_a_sound_device_plays_on_silent(sound_runner, scenario):
    run = subprocess.run([str(sound_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, f"{scenario} exited {run.returncode:#x}\n{run.stdout}\n{run.stderr}"
