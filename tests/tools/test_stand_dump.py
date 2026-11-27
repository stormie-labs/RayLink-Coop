"""A stand process that hangs is dumped before the kill (tools\\stand\\stand_dump.ps1, Stop-S7World).

A world server that stopped answering and did not quit in 150 s was killed with nothing left to tell which thread held what:
its log file had stopped 47 s before the process went silent. Stop-S7World now writes a minidump of it first; this test proves
the helper writes a real dump of a live process, says a dead one has none, and that Stop-S7World calls it before the kill.
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell")
pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="Windows PowerShell required")


def run_ps(script: str) -> subprocess.CompletedProcess:
    return subprocess.run([POWERSHELL, "-NoProfile", "-Command", script], cwd=ROOT, text=True, capture_output=True,
                          timeout=120, check=False)


def test_dump_of_a_live_process(tmp_path):
    dump = tmp_path / "live.dmp"
    script = (
        "$ErrorActionPreference = 'Stop'; . .\\tools\\stand\\stand_dump.ps1; "
        "$p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c','ping -n 30 127.0.0.1 >nul' -WindowStyle Hidden -PassThru; "
        "try { $ok = Save-StandDump -Process $p -Path '" + str(dump) + "' } finally { $p.Kill(); $null = $p.WaitForExit(10000) }; "
        "Write-Output \"result=$ok\""
    )
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "result=True" in done.stdout, done.stdout
    data = dump.read_bytes()
    assert data[:4] == b"MDMP"
    assert len(data) > 4096


def test_no_dump_of_an_exited_process(tmp_path):
    dump = tmp_path / "gone.dmp"
    script = (
        "$ErrorActionPreference = 'Stop'; . .\\tools\\stand\\stand_dump.ps1; "
        "$p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c','exit 0' -WindowStyle Hidden -PassThru; "
        "$null = $p.WaitForExit(10000); "
        "$ok = Save-StandDump -Process $p -Path '" + str(dump) + "'; Write-Output \"result=$ok\""
    )
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "result=False" in done.stdout, done.stdout
    assert not dump.exists()


def test_log_age_names_the_last_write(tmp_path):
    log = tmp_path / "x.log"
    log.write_text("line\n")
    done = run_ps(". .\\tools\\stand\\stand_dump.ps1; Write-Output (Get-StandLogAge '" + str(log) + "')")
    assert done.returncode == 0, done.stderr
    assert re.search(r"log last written \d\d:\d\d:\d\d\.\d{3}, [\d.,]+ s ago", done.stdout), done.stdout


def test_stop_world_dumps_before_the_kill():
    text = (ROOT / "tools" / "stand" / "ms_crash_server.ps1").read_text(encoding="utf-8")
    assert re.search(r"^\. \(Join-Path \$PSScriptRoot 'stand_dump\.ps1'\)", text, re.M)
    body = text[text.index("function Stop-S7World"):text.index("function Read-S7Player")]
    finally_part = body[body.index("} finally {"):]
    assert finally_part.index("Save-StandDump") < finally_part.index("$world.Kill()")
