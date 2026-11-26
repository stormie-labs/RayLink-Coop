"""Execute native clone/capture methods with both WGL magazines populated."""
import os
from pathlib import Path
import subprocess

import pytest

import check_gates
from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def clone_runner(module_work):
    work = module_work
    game = ROOT / "engine/src/xrGame"
    items = game / "coop/coop_items.cpp"
    declarations = definition(items, "struct ItemData") + ";"
    # Declarations below permit the same call order as the real translation unit.
    ordered = ("CInventoryItem* find_item(", "void set_current(", "void set_other(", "void apply_object(",
               "void capture_object(", "bool capture_entity(", "void put(", "void write_data(",
               "bool read_data(", "void apply_entity(", "bool capture_spawn_state(",
               "bool host_validate_kind(", "bool host_validate_counts(", "bool host_apply_spawn_state(", "bool replacement_state(", "void stage_spawn_state(",
               "void discard_spawn_state(", "void forget_item(", "void prepare_clone_state(", "void drain_forgotten(",
               "void restore_item_state(", "void restore_spawn_state(")
    methods = "\n".join(definition(items, signature) for signature in ordered)
    clone_path = game / "coop/coop_requests_clone.cpp"
    requests = "\n".join(definition(clone_path, signature) for signature in (
        "lua_State* clone_function(", "bool clone_return(", "bool clone_export(", "bool clone_stage(",
        "bool clone_activate(", "bool clone_finish(", "bool write_clone_initial(", "bool prepare_local_clone(",
        "bool before_clone_register(", "bool after_clone_register(", "bool cancel_unregistered_clone(", "bool clone_state(",
        "Reason host_replace(", "bool clone_committed(", "bool read_clone_initial(", "bool stage_clone_initial(",
    ))
    fixture = Path(__file__).parent / "fixtures/weapon_clone_wgl.cpp"
    source = fixture.read_text(encoding="utf-8")
    source = source.replace("// ITEM_DATA", declarations)
    source = source.replace("// PROXY_ITEMS", definition(items, "struct ProxyItems") + ";")
    source = source.replace("// ITEM_METHODS", methods)
    source = source.replace("// CLONE_METHOD", requests + "\n" + definition(game / "coop/coop_requests_lua.cpp", "CSE_Abstract* lua_clone("))
    source = source.replace("// RELEASE_HOOK", definition(game / "coop/coop_entities.cpp", "void host_on_entity_released("))
    # the writer gate's target kinds (pure coop_writer_gate.h) and the script gate's own helpers before the gated methods.
    calls_path = ROOT / "engine/src/xrCoop/coop_writer_gate.h"
    source = source.replace("// CALL_TARGETS", "\n".join(definition(calls_path, signature) + ";" for signature in (
        "enum class Target : uint8_t", "struct WriteTarget",
    )))
    gate_path = game / "alife_simulator_script.cpp"
    source = source.replace("// GATE_METHODS", "\n".join(definition(gate_path, signature) for signature in (
        "static bool coop_writer_refuses(const char* call, coop::writer::WriteOp op, ALife::_OBJECT_ID id,",
        "static bool coop_writer_refuses(const char* call, coop::writer::WriteOp op, ALife::_OBJECT_ID parent,",
        "static coop::calls::Target coop_new_root_kind(", "static GameGraph::_GRAPH_ID coop_vertex_of(",
        "static bool coop_create_refused(", "static coop::calls::Gate coop_create_gate(", "static void coop_discard(",
        "CSE_Abstract* reprocess_spawn(", "CSE_Abstract* try_to_clone_object(",
    )))
    (work / "weapon_clone_wgl.cpp").write_text(source, encoding="utf-8")
    include = ROOT / "engine/src/xrCoop"
    lua_lib = check_gates.lua51_lib(ROOT)
    assert lua_lib.is_file(), f"the engine's lua51.lib is required (LUA51_LIB): {lua_lib}"
    return build(work, "cl /nologo /MD /EHsc /std:c++17 /W4 /Od /utf-8",
                 [work / "weapon_clone_wgl.cpp", include / "coop_wire.cpp"], work / "weapon_clone_wgl.exe",
                 includes=[include, ROOT / "engine/src/3rd party/luajit-2/src"], libs=[lua_lib])


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
    # the Lua it runs reads the real G.A.M.M.A. item_parts.script (tests/lua/support/clone_parts_evaluate.lua)
    scripts = check_gates.gamma_scripts()
    assert scripts, "the G.A.M.M.A. scripts are required (GAMMA_SCRIPTS)"
    result = subprocess.run([str(clone_runner), mode], capture_output=True, text=True, timeout=10,
                            env=dict(os.environ, GAMMA_SCRIPTS=str(scripts)))
    assert result.returncode == 0, result.stdout + result.stderr
