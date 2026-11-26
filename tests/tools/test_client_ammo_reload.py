"""Exercise engine reload and ItemState round trips with two local-server worlds."""
from pathlib import Path
import subprocess

import pytest

from native_slice import ROOT, build, declaration, definition


# coop_items.cpp, in its own order: the item state the extracted methods keep (R32 W8: the decider's versions, the owner's
# applied versions, the uses history, the setter guard's counter), the types, then the methods. pelican_repair_native.py takes
# the same lists.
ITEM_STATE = (
    "constexpr u8 kFlagDecider", "int g_applying", "constexpr u8 kFactsDecider", "constexpr u8 kFactsOwner",
    "xr_map<u16, itemtags::FieldVersions> g_versions", "xr_map<u16, owner::CounterHistory> g_uses_history",
    "xr_map<u16, u8> g_staged_uses", "xr_map<u16, itemtags::FieldVersions> g_applied", "xr_map<u16, u8> g_facts_source",
)
ITEM_TYPES = (
    "struct ItemData", "enum class Reason : u8", "struct Stats", "struct TakeBase", "struct Owned", "struct Pending",
    "struct Applying", "enum class Access : u8",
)
ITEM_METHODS = (
    "void put(", "void write_data(", "bool read_data(", "bool same_upgrades(",
    "u32 carried_tags(", "u32 diverged_tags(", "void capture_object(", "void capture_blob(",
    "void attach_versions(", "itemtags::FieldVersions versions_in(", "owner::CounterHistory uses_history_in(",
    "u32 section_max_uses(", "int max_uses_here(", "void capture_report(",
    "void set_current(", "void set_other(", "void apply_object(", "void apply_entity(",
    "void write_state(", "void send_state(", "u32 take_changes(", "u32 push_keeps(",
    "void scan_local(", "bool client_apply(", "void client_on_state(",
    "void process_pending(", "void note_facts(", "void host_push_decider(",
    "void filter_detached_silencer(", "void host_on_state(", "void host_enforce(",
)


def item_types(source):
    """The // ITEM_TYPES part of fixtures/client_ammo_reload.cpp: production state declarations and types."""
    return "\n".join([declaration(source, signature) for signature in ITEM_STATE] +
                     [definition(source, signature) + ";" for signature in ITEM_TYPES])


def item_methods(source):
    """The production coop_items.cpp methods of the // ENGINE_METHODS part."""
    return "\n".join(definition(source, signature) for signature in ITEM_METHODS)


@pytest.fixture(scope="module")
def ammo_runner(module_work):
    work = module_work
    game = ROOT / "engine/src/xrGame"
    source = (game / "coop/coop_items.cpp").read_text(encoding="utf-8-sig")
    types = item_types(source)
    methods = item_methods(source)
    methods += "\n" + definition(game / "WeaponAmmo.cpp", "bool CWeaponAmmo::Get(")
    methods += "\n" + definition(game / "WeaponMagazined.cpp", "void CWeaponMagazined::ReloadMagazine(")
    methods += "\n" + definition(game / "WeaponShotgun.cpp", "u8 CWeaponShotgun::AddCartridge(")
    owner_hooks = "\n".join(definition(source, signature) for signature in (
        "void client_before_take(", "void touch(", "bool client_keep_empty_box("))
    # Rendering, hits and ballistics are outside this regression. Execute the actual
    # post-shot ammunition block, including the count/vector consistency assertion.
    fire = definition(game / "WeaponFire.cpp", "void CWeapon::FireTrace(")
    shot = "void CWeapon::consume_shot() {\nCCartridge& l_cartridge = m_magazine.back();\n" + fire[fire.rindex("// Ammo"):]
    fixture = work / "client_ammo_reload.cpp"
    harness = (Path(__file__).parent / "fixtures/client_ammo_reload.cpp").read_text(encoding="utf-8")
    fixture.write_text(harness.replace("// ITEM_TYPES", types)
                       .replace("// ENGINE_METHODS", methods + "\n" + shot)
                       .replace("// OWNER_HOOKS", owner_hooks), encoding="utf-8")
    include = ROOT / "engine/src/xrCoop"
    return build(work, "cl /nologo /EHsc /std:c++17 /Od /utf-8", [fixture, include / "coop_wire.cpp"],
                 work / "client_ammo_reload.exe", includes=[include])


@pytest.mark.parametrize("mode", [
    "spent-box", "empty-box", "mixed-types", "launcher-bullets", "launcher-grenades",
    "delayed-before-scan", "delayed-after-scan", "duplicate-push", "pending-push",
    "take-baseline", "take-changed", "world-item", "shotgun-empty",
    "offline-push", "two-boxes", "three-magazines", "mixed-magazine",
    "owner-relay", "ownership-return",
    "fallback-type", "partial-reload", "shot-only", "launcher-shot-only", "pending-reload", "pending-clone-push",
])
def test_client_ammo_round_trip(ammo_runner, mode):
    result = subprocess.run([str(ammo_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
