"""Execute native clone/capture methods with both WGL magazines populated."""
import os
from pathlib import Path
import re
import subprocess
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[2]


def definition(path, signature):
    source = path.read_text(encoding="utf-8-sig")
    start = source.index(signature)
    depth = 0
    for match in re.finditer(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]', source[start:], re.DOTALL):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise ValueError(signature)


@pytest.fixture(scope="module")
def clone_runner():
    work = ROOT / "temp/clone-placement-2026-11-09/wgl" / uuid.uuid4().hex[:8]
    work.mkdir(parents=True)
    game = ROOT / "engine/src/xrGame"
    items = game / "coop/coop_items.cpp"
    declarations = definition(items, "struct ItemData") + ";"
    # Declarations below permit the same call order as the real translation unit.
    ordered = ("void set_current(", "void set_other(", "void apply_object(",
               "void capture_object(", "bool capture_entity(", "void put(", "void write_data(",
               "bool read_data(", "void apply_entity(", "bool capture_spawn_state(",
               "bool host_validate_kind(", "bool host_validate_counts(", "bool host_apply_spawn_state(", "bool replacement_state(", "void stage_spawn_state(",
               "void discard_spawn_state(", "void forget_item(", "void prepare_clone_state(", "void drain_forgotten(",
               "void restore_item_state(", "void restore_spawn_state(")
    methods = "\n".join(definition(items, signature) for signature in ordered)
    request_path = game / "coop/coop_requests.cpp"
    requests = "\n".join(definition(request_path, signature) for signature in (
        "lua_State* clone_function(", "bool clone_return(", "bool clone_export(", "bool clone_stage(",
        "bool clone_activate(", "bool clone_finish(", "bool write_clone_initial(", "bool prepare_local_clone(",
        "bool before_clone_register(", "bool after_clone_register(", "bool cancel_unregistered_clone(", "bool clone_state(",
        "Reason host_replace(", "bool clone_committed(", "bool read_clone_initial(", "bool stage_clone_initial(", "CSE_Abstract* lua_clone(",
    ))
    fixture = Path(__file__).parent / "fixtures/weapon_clone_wgl.cpp"
    source = fixture.read_text(encoding="utf-8")
    source = source.replace("// ITEM_DATA", declarations)
    source = source.replace("// ITEM_METHODS", methods)
    source = source.replace("// CLONE_METHOD", requests)
    source = source.replace("// RELEASE_HOOK", definition(game / "coop/coop_entities.cpp", "void host_on_entity_released("))
    gate_path = game / "alife_simulator_script.cpp"
    source = source.replace("// GATE_METHODS", "\n".join(definition(gate_path, signature) for signature in (
        "CSE_Abstract* reprocess_spawn(", "CSE_Abstract* try_to_clone_object(",
    )))
    (work / "weapon_clone_wgl.cpp").write_text(source, encoding="utf-8")
    runner = work / "weapon_clone_wgl.exe"
    vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
    assert vcvars.exists(), "MSVC Build Tools required"
    include = ROOT / "engine/src/xrCoop"
    luajit = ROOT / "engine/src/3rd party/luajit-2/src"
    lua_lib = Path(os.environ.get("LUA51_LIB", str(ROOT / "engine/_build/_game/bin_dbg/x64/Release-AVX/lua51.lib")))
    assert lua_lib.is_file(), "Set LUA51_LIB to the engine's built lua51.lib"
    command = work / "compile.cmd"
    command.write_text(
        f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
        f'cl /nologo /MD /EHsc /std:c++17 /W4 /Od /utf-8 /I"{include}" /I"{luajit}" '
        f'"{work / "weapon_clone_wgl.cpp"}" "{include / "coop_wire.cpp"}" "{lua_lib}" /Fe"{runner}"\n'
        'exit /b %ERRORLEVEL%\n', encoding="utf-8")
    result = subprocess.run(["cmd", "/d", "/c", str(command)], cwd=work,
                            capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", [
    "capture-rifle", "capture-grenade", "clone-rifle", "clone-grenade",
    "host-rifle", "host-grenade", "offline-rifle", "offline-grenade", "plain",
    "atomic-rifle", "atomic-grenade", "atomic-result-first", "atomic-rejoin", "spawn-failure", "activate-failure", "source-failure",
    "source-identity", "unsupported-metadata", "oversize-metadata", "uninitialized-parts",
    "mixed-bm16", "mixed-protecta", "invalid-cartridges",
    "gate-rifle", "gate-grenade", "gate-spawn-failure", "gate-unsupported", "gate-cancel", "singleplayer",
    "gate-mixed-bm16", "gate-mixed-protecta",
    "offline-mixed-bm16", "offline-mixed-protecta",
    "stale-cse-plain",
    "queued-unload",
    "envelope-oversize",
])
def test_wgl_clone_keeps_both_magazines(clone_runner, mode):
    result = subprocess.run([str(clone_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
