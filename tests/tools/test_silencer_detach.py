"""Run the native detach method: a client's addon must survive until host acceptance."""
import os
from pathlib import Path
import subprocess

import pytest
from test_weapon_brief_info import ROOT, definition


@pytest.fixture(scope="module")
def detach_runner():
    work = ROOT / "temp/silencer_detach"
    work.mkdir(parents=True, exist_ok=True)
    (work / "detach.inc").write_text(definition(
        ROOT / "engine/src/xrGame/WeaponMagazined.cpp", "bool CWeaponMagazined::Detach("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/silencer_detach.cpp"
    runner = work / "detach.exe"
    vcvars = os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
    command = work / "compile.cmd"
    command.write_text(f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /utf-8 /I"{work}" "{fixture}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
        capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", ["client", "host", "accepted", "already-detached"])
def test_native_silencer_detach(detach_runner, mode):
    run = subprocess.run([str(detach_runner), mode], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr


@pytest.fixture(scope="module")
def host_runner():
    work = ROOT / "temp/silencer_detach"
    work.mkdir(parents=True, exist_ok=True)
    source = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
    parts = [definition(source, "struct SilencerReceipt") + ";",
        "xr_map<PeerId, xr_deque<SilencerReceipt>> g_silencer_receipts; u32 g_silencer_world = 0;",
        definition(source, "Reason host_detach_silencer("),
        definition(source, "void host_on_silencer_detach(")]
    parts += ["struct ItemData { bool has_addons = true; u8 addons = 0; };",
        "struct CSE_ALifeItemWeapon { enum { eWeaponAddonSilencer = 2 }; };",
        "xr_map<u16, PeerId> g_detached_silencers;",
        definition(ROOT / "engine/src/xrGame/coop/coop_items.cpp", "void filter_detached_silencer(")]
    (work / "silencer_host.inc").write_text("\n".join(parts), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/silencer_host.cpp"
    runner = work / "host.exe"
    vcvars = os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat")
    wire = ROOT / "engine/src/xrCoop"
    command = work / "compile-host.cmd"
    command.write_text(f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /utf-8 /I"{work}" /I"{wire}" "{fixture}" "{wire / "coop_wire.cpp"}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
        capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", ["success", "repeat", "foreign", "offline", "destroying", "permanent",
    "wrong-section", "missing-section", "bad-config", "build-failure", "spawn-failure",
    "missing-result", "wrong-parent", "detach-failure", "rate-limited", "over-budget", "denied",
    "nan-condition", "truncated", "unpaid", "stale-snapshot"])
def test_host_silencer_transaction(host_runner, mode):
    run = subprocess.run([str(host_runner), mode], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
