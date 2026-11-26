"""Run the native detach method: a client's addon must survive until host acceptance."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, definition


@pytest.fixture(scope="module")
def detach_runner(module_work):
    (module_work / "detach.inc").write_text(definition(
        ROOT / "engine/src/xrGame/WeaponMagazined.cpp", "bool CWeaponMagazined::Detach("), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/silencer_detach.cpp"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /utf-8", [fixture], module_work / "detach.exe",
                 includes=[module_work])


@pytest.mark.parametrize("mode", ["client", "host", "accepted", "already-detached"])
def test_native_silencer_detach(detach_runner, mode):
    run = subprocess.run([str(detach_runner), mode], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr


@pytest.fixture(scope="module")
def host_runner(module_work):
    game = ROOT / "engine/src/xrGame/coop"
    source = game / "coop_requests_item_events.cpp"
    world = """using CGameObject = CWeaponMagazined;
namespace coop::world {
CGameObject* object_here(u16 id) { return find_go(id); }
CSE_Abstract* server_entity(u16 id) { return events::find_entity(id); }
}"""
    parts = [world, definition(game / "coop_requests_impl.h", "struct SilencerReceipt") + ";",
        "xr_map<PeerId, xr_deque<SilencerReceipt>> g_silencer_receipts; u32 g_silencer_world = 0;",
        "namespace coop::requests {",
        definition(source, "Reason host_detach_silencer("),
        "}",
        "using coop::requests::host_detach_silencer;",
        definition(source, "void host_on_silencer_detach(")]
    parts += ["struct ItemData { bool has_addons = true; u8 addons = 0; };",
        "struct CSE_ALifeItemWeapon { enum { eWeaponAddonSilencer = 2 }; };",
        "xr_map<u16, PeerId> g_detached_silencers;",
        definition(game / "coop_items.cpp", "void filter_detached_silencer(")]
    (module_work / "silencer_host.inc").write_text("\n".join(parts), encoding="utf-8")
    fixture = Path(__file__).parent / "fixtures/silencer_host.cpp"
    wire = ROOT / "engine/src/xrCoop"
    return build(module_work, "cl /nologo /EHsc /std:c++17 /utf-8", [fixture, wire / "coop_wire.cpp"],
                 module_work / "host.exe", includes=[module_work, wire])


@pytest.mark.parametrize("mode", ["success", "repeat", "foreign", "offline", "destroying", "permanent",
    "wrong-section", "missing-section", "bad-config", "build-failure", "spawn-failure",
    "missing-result", "wrong-parent", "detach-failure", "rate-limited", "over-budget", "denied",
    "nan-condition", "truncated", "unpaid", "stale-snapshot"])
def test_host_silencer_transaction(host_runner, mode):
    run = subprocess.run([str(host_runner), mode], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
