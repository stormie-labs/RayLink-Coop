"""Run the actual weapon HUD-info methods across inventory detachment and return."""
import os
from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]


def definition(path, signature):
    source = path.read_text(encoding="utf-8-sig")
    start = source.index(signature)
    depth = 0
    tokens = r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]'
    for match in re.finditer(tokens, source[start:], re.DOTALL):
        token = match.group()
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise ValueError(f"Unclosed definition {signature}")


@pytest.fixture
def brief_info_runner(work):
    engine = ROOT / "engine/src"
    info = definition(engine / "xrServerEntities/inventory_space.h", "struct II_BriefInfo")
    (work / "brief_info_type.inc").write_text(info + ";\n", encoding="utf-8")
    methods = [
        definition(engine / "xrGame/WeaponMagazined.cpp", "bool CWeaponMagazined::GetBriefInfo("),
        definition(engine / "xrGame/WeaponMagazinedWGrenade.cpp", "bool CWeaponMagazinedWGrenade::GetBriefInfo("),
    ]
    (work / "brief_info_methods.inc").write_text("\n".join(methods), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/weapon_brief_info.cpp"
    runner = work / ("brief_info.exe" if os.name == "nt" else "brief_info")
    if os.name == "nt":
        vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
        if not vcvars.exists():
            pytest.skip("MSVC Build Tools are required for the native regression")
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 /I"{work}" "{fixture}" /Fe"{runner}"\n'
            'exit /b %ERRORLEVEL%\n', encoding="utf-8")
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        if not compiler:
            pytest.skip("A C++17 compiler is required for the native regression")
        build = [compiler, "-std=c++17", "-O0", f"-I{work}", str(fixture), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", ["magazine", "launcher-bullets", "launcher-grenades"])
def test_detached_weapon_clears_hud_and_rebuilds_after_return(brief_info_runner, mode):
    result = subprocess.run([str(brief_info_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, f"{mode} exited {result.returncode:#x}\n{result.stdout}\n{result.stderr}"
