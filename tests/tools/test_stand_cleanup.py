"""A scenario's cleanup stops every process of its run before the files go, never throws over the scenario's own verdict,
and can never end the stand run (tools\\stand_common.ps1 Remove-StandTree, Invoke-Scenario, Invoke-Stand;
tools\\stand\\ms_crash_server.ps1 Stop-S7Clients, Stop-S7Run, Save-S7Logs, Assert-S7Logs; tools\\stand\\run_guarded.ps1).

A client that did not stop in 15 s made Stop-S7Clients throw before the next client was killed; that client still mapped
its exe when the run's folder was removed, the removal threw, the guard's own cleanup threw onto stderr, and the caller of
the runner, which redirects its streams under $ErrorActionPreference Stop, ended at that line: five scenarios never ran.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POWERSHELL = shutil.which("powershell")
pytestmark = pytest.mark.skipif(POWERSHELL is None, reason="Windows PowerShell required")
S7 = ". .\\tools\\stand\\ms_crash_server.ps1 -DefinitionsOnly; "


def run_ps(script: str, timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run([POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], cwd=ROOT, text=True,
                          capture_output=True, timeout=timeout, check=False)


def ps_literal(path: Path) -> str:
    return "'" + str(path).replace("'", "''") + "'"


STUCK = (
    "$stuck = New-Object PSObject -Property @{ Id = 999999 }; "
    "$stuck | Add-Member ScriptProperty HasExited { $false }; "
    "$stuck | Add-Member ScriptMethod Kill { }; "
    "$stuck | Add-Member ScriptMethod WaitForExit { param($ms) $false }; "
    "$stuck | Add-Member ScriptMethod Dispose { }; "
    "$real = Start-Process -FilePath $env:ComSpec -ArgumentList '/c','ping -n 60 127.0.0.1 >nul' -WindowStyle Hidden -PassThru; "
    "$null = $real.Handle; $other = $real.Id; "
    "$ctx = @{ Clients = [ordered]@{ s7stay = $stuck; s7move = $real }; World = $null; Leaf = 'zz_s7_000000000000'; "
    "Stand = $stand }; "
)


def test_a_client_that_does_not_stop_leaves_no_other_running(tmp_path):
    script = ("$ErrorActionPreference = 'Stop'; " + S7 + f"$stand = {ps_literal(tmp_path)}; " + STUCK +
              "try { Stop-S7Clients $ctx; Write-Output 'no throw' } catch { Write-Output \"threw: $_\" }; "
              "$gone = -not (Get-Process -Id $other -ErrorAction SilentlyContinue); "
              "if (-not $gone) { Stop-Process -Id $other -Force }; Write-Output \"other stopped: $gone\"")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "other stopped: True" in done.stdout, done.stdout
    assert "threw: client 999999 did not stop in 15 s" in done.stdout, done.stdout


def test_the_end_of_a_run_returns_its_problems_and_throws_none(tmp_path):
    script = ("$ErrorActionPreference = 'Stop'; " + S7 + f"$stand = {ps_literal(tmp_path)}; " + STUCK +
              "$p = @(Stop-S7Run $ctx); Write-Output \"problems: $($p.Count) [$($p -join ' | ')]\"; "
              "$gone = -not (Get-Process -Id $other -ErrorAction SilentlyContinue); "
              "if (-not $gone) { Stop-Process -Id $other -Force }; Write-Output \"other stopped: $gone\"")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "problems: 1 [client 999999 did not stop in 15 s]" in done.stdout, done.stdout
    assert "other stopped: True" in done.stdout, done.stdout


def test_an_unreadable_process_path_does_not_skip_the_next_process(tmp_path):
    script = "$ErrorActionPreference = 'Stop'; " + S7 + f"$stand = {ps_literal(tmp_path)}\n" + r"""
$ctx = @{ Stand = $stand; Leaf = 'zz_s7_0123456789ab' }
$first = [pscustomobject]@{ Id = 1 }
$first | Add-Member ScriptProperty Path { throw 'path is unreadable' }
$first | Add-Member ScriptMethod get_MainModule { throw 'path is unreadable' }
$first | Add-Member ScriptMethod Dispose { Write-Host 'disposed first' }
$second = [pscustomobject]@{ Id = 2; Path = (Join-Path $stand 'Anomaly.exe'); HasExited = $false }
$second | Add-Member ScriptMethod get_MainModule { [pscustomobject]@{ FileName = $this.Path } }
$second | Add-Member ScriptMethod Kill { $this.HasExited = $true }
$second | Add-Member ScriptMethod WaitForExit { param($ms) $this.HasExited }
$second | Add-Member ScriptMethod Dispose { }
function Get-CimInstance {
    foreach ($id in 1, 2) { [pscustomobject]@{ ProcessId = $id; CommandLine = '-fsltx zz_s7_0123456789ab\world.ltx' } }
}
function Get-Process { param($Id) if ($Id -eq 1) { $first } else { $second } }
try { Stop-S7RunProcesses $ctx } catch { Write-Output "reported: $_" }
Write-Output "second stopped: $($second.HasExited)"
"""
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "second stopped: True" in done.stdout, done.stdout
    assert "disposed first" in done.stdout, done.stdout
    assert any(line.startswith("reported:") and "path is unreadable" in line
               for line in done.stdout.splitlines()), done.stdout


@pytest.mark.parametrize("failing_cleanup", ["Save-S7Logs", "Remove-StandTree"])
def test_a_failed_run_keeps_its_error_when_cleanup_throws(tmp_path, failing_cleanup):
    source = (ROOT / "tools" / "stand" / "ms_crash_server.ps1").read_text(encoding="utf-8")
    run = source.split("function Invoke-S7Run(", 1)[1].split("\nfunction Invoke-S7Scenario(", 1)[0]
    verdict = run[run.index("    $finished = $false\n"):]
    script = "$ErrorActionPreference = 'Stop'\n" + f"$run = {ps_literal(tmp_path)}\n" + r"""
function New-S7Fs { }
function Copy-StandFile { }
function Write-StandText { }
function Remove-StandFile { }
function Stop-S7Run { }
function Remove-StandTree { Write-Output 'tree cleaned' }
function Save-S7Logs { }
function Hide-Hex($line) { $line }
""" + f"function {failing_cleanup} {{ throw 'cleanup failed' }}\n" + r"""
function Invoke-TestRun {
    $Name = 'scenario'
    $ctx = @{ Fs = @{}; Clients = @{}; StageName = 'creator.ltx' }
    $PSScriptRoot = $run
    $Body = { throw 'run failed' }
""" + verdict + '\ntry { Invoke-TestRun } catch { Write-Output "reported: $_" }'
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    lines = done.stdout.splitlines()
    assert "reported: run failed" in lines, done.stdout
    assert "cleanup: cleanup failed" in lines, done.stdout
    if failing_cleanup == "Save-S7Logs":
        assert "tree cleaned" in lines, done.stdout


def test_an_empty_tree_is_removed_with_its_root(tmp_path):
    run = tmp_path / "zz_s7_0123456789ab"
    (run / "world" / "logs").mkdir(parents=True)
    done = run_ps("$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; "
                  f"Remove-StandTree -Dir {ps_literal(run)}")
    assert done.returncode == 0, done.stderr
    assert not run.exists()


def test_a_file_in_use_stays_and_the_others_go(tmp_path):
    run = tmp_path / "zz_s7_0123456789ab"
    (run / "bin_s7move").mkdir(parents=True)
    (run / "world" / "logs").mkdir(parents=True)
    held = run / "bin_s7move" / "held.exe"
    held.write_bytes(b"x")
    free = [run / "world" / "logs" / "a.log", run / "bin_s7move" / "b.dll", run / "c.txt"]
    for f in free:
        f.write_bytes(b"y")
    script = ("$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; "
              f"$h = [IO.File]::Open({ps_literal(held)}, 'Open', 'Read', 'Read'); "
              f"try {{ Remove-StandTree -Dir {ps_literal(run)}; Write-Output 'returned' }} finally {{ $h.Dispose() }}")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "returned" in done.stdout, done.stdout
    leftovers = [line for line in done.stdout.splitlines() if line.startswith("left for the next run's cleanup:")]
    assert len(leftovers) == 1 and "1 file(s) under" in leftovers[0] and str(held) in leftovers[0], done.stdout
    assert held.exists()
    assert list(run.iterdir()) == [held.parent]
    assert list(held.parent.iterdir()) == [held]


def test_a_guard_writing_to_stderr_fails_its_scenario_not_the_run(tmp_path):
    scenarios = tmp_path / "scenarios"
    out = tmp_path / "out"
    scenarios.mkdir()
    out.mkdir()
    (scenarios / "run_guarded.ps1").write_text(
        "param([string]$Script, [string]$Out, [string]$ScriptArgs, [string]$Stand, [string]$OutDir)\n"
        "[IO.File]::WriteAllText((Join-Path $OutDir $Out), \"x: PASS`r`n\")\n"
        "Write-Output 'run finished'\nWrite-Output 'scenario exit code: 0'\n"
        "[Console]::Error.WriteLine('the guard cleanup threw')\nexit 0\n", encoding="ascii")
    runner = tmp_path / "runner.ps1"
    runner.write_text(
        "$ErrorActionPreference = 'Stop'\n"
        f". (Join-Path {ps_literal(ROOT)} 'tools\\stand_common.ps1')\n"
        "function Invoke-HeadProfile { param([string]$Stand) }\n"
        f"$script:ScenarioDir = {ps_literal(scenarios)}\n$script:StandDir = {ps_literal(out)}\n"
        "$r = Invoke-Scenario -Scenario @{ Name = 'x'; Script = 'x.ps1'; Args = ''; Pass = @('x: PASS'); Bad = @() } "
        f"-Tag 't' -Stand {ps_literal(tmp_path)}\n"
        "Write-Output \"verdict ok=$($r.Ok) problems=$($r.Problems -join ' | ')\"\n"
        "Write-Output 'the runner went on'\n", encoding="ascii")
    log = tmp_path / "run.log"
    # The caller of a stand runner redirects its streams under $ErrorActionPreference Stop.
    outer = (f"$ErrorActionPreference = 'Stop'; try {{ & powershell -NoProfile -ExecutionPolicy Bypass -File {ps_literal(runner)} "
             f"*> {ps_literal(log)}; Write-Output 'outer went on' }} catch {{ Write-Output \"outer stopped: $_\" }}")
    done = run_ps(outer)
    assert done.returncode == 0, done.stderr
    assert "outer went on" in done.stdout, done.stdout
    text = log.read_text(encoding="utf-16")
    assert "the runner went on" in text, text
    assert "verdict ok=False" in text and "run_guarded.ps1 wrote to stderr: the guard cleanup threw" in text, text


def test_a_scenario_that_throws_in_the_runner_fails_alone(tmp_path):
    stand = tmp_path / "stand"
    (stand / "bin").mkdir(parents=True)
    (stand / "bin" / "AnomalyCoopDX11AVX.exe").write_bytes(b"x")
    script = ("$ErrorActionPreference = 'Stop'; . .\\tools\\stand_common.ps1; "
              f"$script:MarkDir = {ps_literal(tmp_path)}; "
              "function Invoke-HeadDeploy { param([string]$Stand) @{ exe_source = 'test' } }; "
              "function Invoke-Scenario { param([hashtable]$Scenario, [string]$Tag, [string]$Stand) "
              "if ($Scenario.Name -eq 'a') { throw 'cannot delete the exe' } "
              "[pscustomobject]@{ Name = $Scenario.Name; Ok = $true; Problems = @(); Out = $null } }; "
              f"$code = Invoke-Stand -Mode 'test' -Scenarios @(@{{ Name = 'a' }}, @{{ Name = 'b' }}) -Tag 't' -Stand {ps_literal(stand)} -NoMark; "
              "Write-Output \"code=$code\"")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert "the runner failed on it: cannot delete the exe" in done.stdout, done.stdout
    assert "code=1" in done.stdout, done.stdout
    lines = [line.split() for line in done.stdout.splitlines()]
    assert ["a", "FAIL"] in lines and ["b", "PASS"] in lines, done.stdout


@pytest.mark.parametrize(("events", "cause"), [
    ("[coop] map server 2: its process ended with code 3\n"
     "[coop] map server 1 left: disconnected\n"
     "[coop] levels: map server 2 leads no level now, 4 object(s) came home\n",
     "[coop] map server 2: its process ended with code 3"),
    ("[coop] map server 2 leads level 7\n"
     "[coop] host: map server 2 left: connection lost\n[coop] map server 2 left: connection lost\n"
     "[coop] map server 1 left: disconnected\n", "[coop] map server 2 left: connection lost"),
    ("[coop] map server 2 leads level 7\n[coop] map server 1 left: disconnected\n", "no line says how"),
], ids=["relinquished-level", "last-leader", "missing-cause"])
def test_an_unplanned_map_server_loss_says_how_it_was_lost(tmp_path, events, cause):
    log = tmp_path / "world.log"
    log.write_text(
        "[coop] map servers: 2 running of a cap of 3 (players 2 + 1), 2 started, 0 crashed; memory 763 MB free of 32635 MB, "
        "commit 6334 MB left: LOW, empty map servers do not linger\n" + events +
        "! [coop] map server of level 7 is gone: its objects are at their last confirmed state, 1 failure(s) in a row\n",
        encoding="ascii")
    script = ("$ErrorActionPreference = 'Stop'; " + S7 +
              f"$ctx = @{{ Logs = @{{ world = {ps_literal(log)} }}; ExpectedMapLoss = $null }}; "
              "try { Assert-S7Logs $ctx; Write-Output 'no throw' } catch { Write-Output \"threw: $_\" }")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert (f"threw: a map server the scenario did not kill was lost; {cause}; "
            "memory 763 MB free of 32635 MB") in done.stdout, done.stdout
    assert "is gone: its objects" in done.stdout


def test_the_log_of_a_process_started_before_is_kept(tmp_path):
    logs = tmp_path / "run" / "appdata_ms2" / "logs"
    (logs / "old").mkdir(parents=True)
    (logs / "xray_u.log").write_text("second\n", encoding="ascii")
    (logs / "old" / "xray_u_2026-01-01_10-00-00.log").write_text("first\n", encoding="ascii")
    out = tmp_path / "out"
    out.mkdir()
    script = ("$ErrorActionPreference = 'Stop'; " + S7 + f"$script:StandDir = {ps_literal(out)}; "
              f"$ctx = @{{ Tag = 't'; Name = 'n'; Logs = @{{ ms2 = {ps_literal(logs / 'xray_u.log')} }} }}; Save-S7Logs $ctx")
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert (out / "t_n_ms2.log").read_text(encoding="ascii") == "second\n"
    assert (out / "t_n_ms2_old1.log").read_text(encoding="ascii") == "first\n"


def test_the_guard_cleanup_is_a_guard_line_not_a_throw():
    source = (ROOT / "tools" / "stand" / "run_guarded.ps1").read_text(encoding="utf-8")
    marker = "} finally {\n    # The guard's own cleanup"
    cleanup = marker + source.split(marker, 1)[1].split("\nGet-Content", 1)[0]
    script = """
$ErrorActionPreference = 'Stop'
$job = [pscustomobject]@{}
$job | Add-Member ScriptMethod Stop { throw 'job stop failed' }
$job | Add-Member ScriptMethod Dispose { }
$run = [pscustomobject]@{ ExitCode = 0 }
$run | Add-Member ScriptMethod Dispose { }
$claim = $admit = $mutex = $null
$locked = $stopped = $false
$cleanup = ''
try {
""" + cleanup
    done = run_ps(script)
    assert done.returncode == 0, done.stderr
    assert any(line.startswith("GUARD: cleanup:") and "job stop failed" in line
               for line in done.stdout.splitlines()), done.stdout
