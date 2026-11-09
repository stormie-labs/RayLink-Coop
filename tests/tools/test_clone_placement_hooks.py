"""Exercise the production teardown poll and slot restore with a live clone in the rucksack."""
import os
from pathlib import Path
import subprocess
import uuid

import pytest

from test_weapon_clone_wgl import definition

ROOT = Path(__file__).resolve().parents[2]


def test_clone_teardown_precedes_slot_restore():
    work = ROOT / "temp/clone-placement-2026-11-09/hooks" / uuid.uuid4().hex[:8]
    work.mkdir(parents=True)
    requests = ROOT / "engine/src/xrGame/coop/coop_requests.cpp"
    methods = definition(requests, "void clone_slots_frame(")
    poll = definition(requests, "for (auto it = g_give_back_wait.begin();")
    methods += "\nvoid poll_removals(u64 now) {\n" + poll + "\n}\n"
    fixture = Path(__file__).parent / "fixtures/clone_placement_hooks.cpp"
    source = fixture.read_text(encoding="utf-8").replace("// SLOT_METHODS", methods)
    (work / "clone_placement_hooks.cpp").write_text(source, encoding="utf-8")
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.exists(), "MSVC Build Tools required"
    runner = work / "clone_placement_hooks.exe"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /EHsc /std:c++17 /W4 /Od /utf-8 /I"{ROOT / "engine/src/xrCoop"}" '
        f'"{work / "clone_placement_hooks.cpp"}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    build = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                           capture_output=True, text=True, errors="replace", timeout=120)
    assert build.returncode == 0, build.stdout + build.stderr
    result = subprocess.run([str(runner)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
