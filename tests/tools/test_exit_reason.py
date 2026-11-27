"""Execute xrDebug::do_exit (engine/src/xrCore/xrDebugNew.cpp, the body of CHECK_OR_EXIT): the reason reaches the log.

Server stand, third run of 2026-11-27, carry_server: the client stopped at its sound start with exit code 1, and its log
ended in the console variables the crash handler dumps, without the reason ("OpenAL: Can't create sound device."): the
client is started without the launcher's key -silent_error_mode, and do_exit wrote the reason only on the no-dialog paths.
Now the log names it on the dialog path too (the stand's judge reads "FATAL ERROR"). do_exit is cut out and compiled with
fixtures/exit_reason.cpp over stand-ins for the log, the dialog and the process end. Every game process runs it, whatever
its mode (Core: a stock file).

  COOP_DEBUG_CPP=<file>  cut the function out of this copy instead (mutation checks)
"""
import os
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition

SOURCE = ROOT / "engine/src/xrCore/xrDebugNew.cpp"
SCENARIOS = ["dialog", "launcher-key", "map-server", "no-strings"]


@pytest.fixture(scope="module")
def exit_runner(module_work):
    source = Path(os.environ.get("COOP_DEBUG_CPP") or SOURCE).read_text(encoding="utf-8-sig")
    (module_work / "exit_reason.inc").write_text(
        definition(source, "void xrDebug::do_exit(const std::string& message)") + "\n", encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/exit_reason.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /Od /utf-8 /W3", [fixture], module_work / "exit_reason.exe",
                 includes=[module_work])


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_a_quit_names_its_reason_in_the_log(exit_runner, scenario):
    run = subprocess.run([str(exit_runner), scenario], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, f"{scenario} exited {run.returncode:#x}\n{run.stdout}\n{run.stderr}"
