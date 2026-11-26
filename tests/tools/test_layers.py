"""tools/check_layers.py: the border of the three layers (docs/MODES.md section 5).

Fixture trees: tests/tools/fixtures/layers/clean is a tiny tree with one file of every layer and two allow-listed
lines (ceiling 2); every other folder there is an overlay copied on top of it that breaks one rule. The rv_* overlays
are the adversarial reviewer's trees of 2026-11-18 (temp/modes_review/trees: only the files that differ from his clean
tree), each a way to put a mode check into Ядро that got through the first version of the checker. The n*_ and b6_
overlays are the second review's attacks (temp/modes_review2/new_attacks.py: N2-N10, N12) that got through the second.
Run: python -m pytest tests\\tools\\test_layers.py -q
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

import check_layers as check
from conftest import ROOT

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "layers"
SCRIPT = ROOT / "tools" / "check_layers.py"
LINE = re.compile(r"^(?P<path>[^\s:][^:]*):(?P<line>\d+): \[(?P<rule>L\d+C?)\] ")
MOD_NAMES = (
    "script drx_da_main fixture\n"
    "script z_3dss_silencer_condition fixture\n"
    "script arm fixture\n"
    "script larp fixture\n"
    "ignore larp\n"
    "name DAO\n"
)


def make(work: Path, *overlays: str) -> Path:
    root = work / "tree"
    shutil.copytree(FIXTURES / "clean", root)
    (root / "tools/mod_names.txt").write_text(MOD_NAMES, encoding="utf-8")
    for name in overlays:
        shutil.copytree(FIXTURES / name, root, dirs_exist_ok=True)
    return root


def run(root: Path, capsys: pytest.CaptureFixture[str], *extra: str) -> tuple[int, str]:
    code = check.main(["--root", str(root), *extra])
    return code, capsys.readouterr().out


def violations(out: str) -> list[tuple[str, int, str]]:
    found = []
    for line in out.splitlines():
        m = LINE.match(line)
        if m:
            found.append((m.group("path"), int(m.group("line")), m.group("rule")))
    return found


def rules(out: str) -> set[str]:
    return {rule for _, _, rule in violations(out)}


# --- the clean tree ---------------------------------------------------------------------------------------------------

def test_clean_tree_passes(work, capsys):
    code, out = run(make(work), capsys)
    assert code == 0, out
    assert violations(out) == []
    assert re.search(r"^check_layers: OK \(\d+ files, ceiling 2, used 2\)$", out, re.M), out


def test_strings_and_comments_are_not_code(work, capsys):
    # coop_net.cpp and coop_items.script name predicates only inside a string and a comment
    code, out = run(make(work), capsys)
    assert code == 0, out
    assert "coop_net.cpp:1" not in out and "coop_items.script" not in out


# --- one fixture per rule ---------------------------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("overlay", "rule", "path", "line"),
    [
        ("l1_cpp", "L1", "engine/src/xrGame/coop/coop_items.cpp", 7),
        ("l1_lua", "L1", "gamedata/scripts/coop_items.script", 12),
        ("l2", "L2", "engine/src/xrGame/coop/coop_items.cpp", 7),
        ("l3_cpp", "L3", "engine/src/xrGame/coop/coop_items.cpp", 3),
        ("l3_srv_hostplay", "L3", "engine/src/xrGame/coop/coop_mapserver.cpp", 4),
        ("l3_lua", "L3", "gamedata/scripts/coop_items.script", 12),
        ("l3_lua", "L3", "gamedata/scripts/coop_items.script", 13),
        ("l4", "L4", "engine/src/xrCoop/coop_roles.h", 9),
        ("l4", "L4", "engine/src/xrCoop/coop_roles.h", 12),
        ("l5", "L5", "engine/src/xrGame/Level.cpp", 4),
        ("l6", "L6", "engine/src/xrGame/coop/coop_items.cpp", 3),
        ("l7", "L7", "gamedata/scripts/coop_big.script", 192),
        ("l8", "L8", "gamedata/scripts/coop_items.script", 12),
        ("l9", "L9", "gamedata/scripts/coop_levels.script", 19),
        ("l10", "L10", "tools/persisted_keys.txt", 2),
    ],
)
def test_each_rule_fails_with_its_id(work, capsys, overlay, rule, path, line):
    code, out = run(make(work, overlay), capsys)
    assert code == 1, out
    assert (path, line, rule) in violations(out), out
    assert re.search(r"^check_layers: FAIL \(\d+\)$", out, re.M), out


def test_registration_inside_when_srv_passes_and_outside_fails(work, capsys):
    code, out = run(make(work, "l9"), capsys)
    found = [v for v in violations(out) if v[2] == "L9"]
    assert found == [("gamedata/scripts/coop_levels.script", 19, "L9")], out  # line 21 is inside when_srv


def test_srv_file_may_name_the_predicates(work, capsys):
    # coop_mapserver.cpp / coop_levels_far.cpp (srv) and coop_levels.script (srv) are full of them in the clean tree
    code, out = run(make(work), capsys)
    assert code == 0, out


def test_l4_ignores_defaults_without_a_mode_word(work, capsys):
    code, out = run(make(work, "l4"), capsys)
    l4 = sorted(line for path, line, rule in violations(out) if rule == "L4")
    assert l4 == [9, 12], out  # `mirror = false`, `seats{4}`, `limit = 8`, `HostLike = 1` (enum) pass


# --- taint: a wrapper of a mode check is a mode check (critique H3) ---------------------------------------------------

def test_cpp_wrapper_from_another_file_and_its_wrapper_are_tainted(work, capsys):
    code, out = run(make(work, "taint_cpp"), capsys)
    assert code == 1, out
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_death.cpp")}
    assert (6, "L1") in found, out  # return levels::leads_here(); (leads_here returns is_map_server() || dedicated::on())
    assert (11, "L1") in found, out  # if (ghost()): ghost returns leads_here()
    assert "leads_here" in out


def test_lua_local_wrapper_alias_and_chain_are_tainted(work, capsys):
    code, out = run(make(work, "taint_lua"), capsys)
    assert code == 1, out
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_death.script")}
    assert (5, "L1") in found, out  # the predicate itself
    assert (8, "L1") in found, out  # local split = coop.levels.split
    assert (11, "L1") in found, out  # return authority(): judge is a wrapper of a wrapper
    assert (15, "L1") in found, out  # if judge() then
    assert (18, "L1") in found, out  # if split() then (alias)


# --- the adversarial review: every tree that got through is caught (temp/modes_review, 2026-11-18) ---------------------

X = "engine/src/xrGame/coop/coop_x.cpp"
XS = "gamedata/scripts/coop_x.script"


@pytest.mark.parametrize(("overlay", "expected"), [
    # missing predicates (item 8)
    ("rv_l1e_split_levels", {(X, 6, "L1")}),                     # if (g_coop_split_levels)
    ("rv_l1f_world_server", {(X, 6, "L1")}),                     # if (g_coop_world_server != 0)
    ("rv_l1g_story_together", {(X, 6, "L1"), (X, 6, "L6")}),    # g_coop_story_together: the word boundary after "_"
    ("rv_l2a_has_role", {(X, 6, "L1")}),                         # has_role(ProcessRole::WorldServer)
    ("rv_l1i_command_line", {(X, 6, "L1")}),                     # strstr(Core.Params, "-coop_mapserver")
    # using namespace and namespace aliases (item 8)
    ("rv_l1b_namespace_alias", {(X, 7, "L1")}),                  # namespace lv = coop::levels; lv::remote2()
    ("rv_l1c_using_namespace", {(X, 7, "L1")}),                  # using namespace coop::levels; remote2()
    ("rv_l1h_using_dedicated", {(X, 6, "L1")}),                  # using namespace coop::dedicated; on()
    ("rv_l3c_entry_using", {(X, 7, "L3")}),                      # using namespace coop::levels; frame()
    # macros (item 8)
    ("rv_l1j_macro", {(X, 4, "L1"), (X, 7, "L1")}),              # #define ASK(p) coop::mapserver::p##_map_server()
    ("rv_l1k_srv_macro", {(X, 7, "L1")}),                        # COOP_REMOTE() of a srv header Ядро includes
    # Lua (item 8)
    ("rv_luaa_table_alias", {(XS, 3, "L1")}),                    # local L = coop.levels; L.split()
    ("rv_luab_indexed_field", {(XS, 2, "L1")}),                  # coop.levels["split"]()
    ("rv_luad_g_index", {(XS, 2, "L3")}),                        # _G["coop_levels"].key()
    # L9 (item 9)
    ("rv_l9a_register_alias", {("gamedata/scripts/coop_srv_x.script", 1, "L9"),
                               ("gamedata/scripts/coop_srv_x.script", 3, "L9")}),
    ("rv_l9b_register_indexed", {("gamedata/scripts/coop_srv_x.script", 1, "L9"),
                                 ("gamedata/scripts/coop_srv_x.script", 2, "L9")}),
    ("rv_luaf_monkeypatch", {("gamedata/scripts/coop_srv_y.script", 1, "L9")}),
    # a new file of ours outside the two Ядро folders is core, not stock (item 10)
    ("rv_layc_new_file", {("engine/src/xrGame/ui/UIRayPanel.cpp", 1, "L1")}),
    # the dying list is frozen: a row that calls an Ядро file dying is ignored
    ("rv_layb_dying_row", {(X, 6, "L1")}),
    # server functions reached from Ядро without srv_entry.txt
    ("rv_l1a_long_srv_wrapper", {(X, 6, "L3")}),                 # a long srv wrapper: Ядро calls a srv function
    ("rv_l3b_declared_srv_function", {(X, 7, "L3")}),            # declared in Ядро instead of included
    ("rv_l3d_entry_pointer", {(X, 6, "L3")}),                    # &coop::levels::online_at_server
    ("rv_l3a_include_macro", {(X, 3, "L3")}),                    # #include HDR
    ("rv_l4b_default_in_cpp", {(X, 4, "L4")}),                   # a bool mode default in a .cpp
])
def test_review_hole_is_caught(work, capsys, overlay, expected):
    code, out = run(make(work, overlay), capsys)
    assert code == 1, out
    assert expected <= set(violations(out)), out


def test_more_cpp_predicates(work, capsys):
    code, out = run(make(work, "l1_more_predicates"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path == X}
    assert found == {(6, "L1"), (8, "L1"), (10, "L1"), (12, "L2"), (16, "L1"), (20, "L1")}, out
    # 14: has_role(ProcessRole::Player) is is_player (one meaning in both modes); 18: "-coop_connect" is no mode key


def test_more_lua_references(work, capsys):
    code, out = run(make(work, "lua_more"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path == XS}
    assert found == {(5, "L3"), (6, "L3"), (7, "L1"), (8, "L1"), (9, "L1")}, out  # 10: the facade coop_mode passes


def test_l9_registrations_and_patches_outside_when_srv(work, capsys):
    code, out = run(make(work, "l9_more"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L9")
    assert found == [4, 5, 6, 7, 8], out  # 9-11 its own tables, 14-16 inside coop_mode.when_srv


# --- the second review: server code that runs in the co-op process although nothing names a mode (2026-11-18) -------

POLICY_SRV = "engine/src/xrGame/coop/srv/coop_far_policy_srv.cpp"


def test_srv_file_defining_a_member_of_a_core_class_is_l3(work, capsys):
    # B2 / N2: Ядро calls far_policy().keep_online(id) through an object; the body lives in a srv file
    code, out = run(make(work, "n2_member_of_core_class"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if path.startswith("engine/src/xrGame/coop/")}
    assert found == {(POLICY_SRV, 5, "L3")}, out  # coop_far_ledger.cpp defines its own Ledger (a homonym): not counted
    assert "FarPolicy" in out


def test_static_initializer_with_a_call_in_srv_is_l9c(work, capsys):
    # B3 / N3: `static const bool registered = (coop::hooks::set_skip(&far_skip), true);` runs in every process
    code, out = run(make(work, "n3_static_init"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_far_skip" in path}
    assert found == {("engine/src/xrGame/coop/srv/coop_far_skip.cpp", 9, "L9C")}, out
    # 10, 11: no call; 14: a class member; 18: a function-local static (runs when the function runs)
    assert code == 1


def test_core_extern_of_a_srv_global_is_l3(work, capsys):
    # B4 / N4: `extern bool g_far_world;` in Ядро, `bool g_far_world = false;` in a srv file
    code, out = run(make(work, "n4_extern"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_farread" in path or "srv_world" in path}
    assert found == {("engine/src/xrGame/coop/coop_farread.cpp", 2, "L3")}, out  # g_core_count is an Ядро global


def test_srv_script_patching_tables_not_its_own_is_l9(work, capsys):
    # B5 / N5 (sim_board, smart_terrain: stock scripts outside the repository) and N9 (db.coop_far_world)
    code, out = run(make(work, "n5_patch_foreign"), capsys)
    found = {(path.rsplit("/", 1)[-1], line) for path, line, rule in violations(out) if rule == "L9"}
    assert found == {("coop_srv_far_squads.script", 3), ("coop_srv_far_squads.script", 9),
                     ("coop_srv_world.script", 5)}, out  # a local table, its own global, inside when_srv: pass


def test_srv_script_calls_at_load_outside_when_srv_are_l9(work, capsys):
    # B6 / N6 (timers, per-frame calls), N7 (console), N8 (an Ядро setter), and a call at file level
    code, out = run(make(work, "n6_load_calls"), capsys)
    found = {(path.rsplit("/", 1)[-1], line) for path, line, rule in violations(out) if rule == "L9"}
    assert found == {("coop_srv_far_tick.script", 6), ("coop_srv_far_tick.script", 7), ("coop_srv_far_tick.script", 8),
                     ("coop_srv_far_console.script", 3), ("coop_srv_far_console.script", 4),
                     ("coop_srv_far_console.script", 5),
                     ("coop_srv_far_hud.script", 3), ("coop_srv_far_hud.script", 4),
                     ("coop_srv_far_file.script", 2)}, out  # file.script:3 calls only inside function bodies


def test_srv_script_pure_lookups_at_load_pass(work, capsys):
    # B6: rawget, string.*, math.*, tonumber, type, setmetatable, class, table.insert into a local, calls in bodies
    code, out = run(make(work, "b6_pure_lookups"), capsys)
    assert [v for v in violations(out) if "coop_srv_far_ok" in v[0]] == [], out
    assert code == 0, out


def test_core_cpp_naming_a_srv_script_in_a_string_is_l3(work, capsys):
    # B7 / N10: lua_getglobal(L, "coop_srv_far") (the precedent: coop_join.cpp `lua_getglobal(L, "coop_dedicated")`)
    code, out = run(make(work, "n10_cpp_string"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_farcall.cpp")}
    assert found == {(6, "L3"), (8, "L3")}, out  # 7: coop_items is an Ядро script


def test_stock_patch_scripts_are_scanned(work, capsys):
    # B9 / N12: engine/gamedata/scripts and gamedata_gamma/scripts are stock Lua: L3 for a srv script, L5 for a mode name
    code, out = run(make(work, "n12_stock_lua"), capsys)
    found = set(violations(out))
    assert {("engine/gamedata/scripts/axr_main.script", 3, "L3"), ("engine/gamedata/scripts/axr_main.script", 5, "L5"),
            ("gamedata_gamma/scripts/coop_menu_theme.script", 3, "L3")} <= found, out
    assert ("engine/gamedata/scripts/axr_main.script", 4, "L3") not in found, out  # coop_items is Ядро


def test_member_l4_in_a_cpp_counts_only_true(work, capsys):
    # the review's BaseSeen::here alarm: a false default on a data row of a .cpp is the safe value; headers keep the rule
    code, out = run(make(work, "l4_member_cpp"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L4" and path.endswith("coop_checkpoint_x.cpp"))
    assert found == [7, 10], out  # 6: here = false, 8: level_known{false}; 10: a parameter default stays


# --- the third review: what still ran in the co-op process (temp/modes_review3/review3.md, C1-C8) -----------------------

def l9_lines(out: str, name: str) -> list[int]:
    return sorted(line for path, line, rule in violations(out) if rule == "L9" and path.endswith(name))


def test_self_alias_of_a_foreign_table_is_not_own(work, capsys):
    # C1: `local db = db` made db "own", so `db.coop_far_world = true` in on_game_start passed
    code, out = run(make(work, "c1_self_alias"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_world_alias.script") == [7, 8], out  # 9, 10: its own table and a copy of it


def test_when_srv_given_the_result_of_a_call_is_l9(work, capsys):
    # C2: when_srv(hide_far_spots()) calls hide_far_spots at load; its body runs at load too
    code, out = run(make(work, "c2_when_srv_call"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_far_spots.script") == [3, 4, 8], out  # 9: a function, 10: an anonymous one
    assert "gets the result of a call" in out


def test_setmetatable_on_a_foreign_table_is_l9(work, capsys):
    # C3: setmetatable was a pure lookup; on db.storage it makes a shared table weak in every process
    code, out = run(make(work, "c3_setmetatable"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_memory.script") == [2, 7], out  # 3: a new table, 5: its own table
    assert "sets the metatable of db" in out


def test_function_assigned_to_on_game_start_and_its_callees_run_at_load(work, capsys):
    # C4: `on_game_start = start`; start calls arm(); both bodies run at load
    code, out = run(make(work, "c4_assigned_start"), capsys)
    assert code == 1, out
    assert l9_lines(out, "coop_srv_far_start.script") == [6, 9, 10], out  # 14: later() never runs at load


def test_core_script_naming_a_srv_script_in_a_plain_string_is_l3(work, capsys):
    # C6: a dispatch table of script names read through rawget(_G, name)
    code, out = run(make(work, "c6_dispatch_string"), capsys)
    found = {(line, rule) for path, line, rule in violations(out) if path.endswith("coop_price_hooks.script")}
    assert found == {(2, "L3")}, out  # coop_items is Ядро
    assert "coop_srv_far_prices" in out


def test_static_object_with_a_constructor_in_srv_is_l9c(work, capsys):
    # C7: `static Registrar s_registrar;` runs Registrar() (which registers a hook) in every process
    code, out = run(make(work, "c7_static_ctor"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L9C" and path.endswith("coop_far_reg.cpp"))
    assert found == [12, 13], out  # 18: Plain has no constructor; 19: a pointer; 20: a declaration
    assert "the constructor Registrar()" in out


def test_static_member_of_a_core_class_defined_in_srv_is_l3(work, capsys):
    # C8: `u32 FarLimits::squads_per_player = 4;` in a srv file; Ядро reads FarLimits::squads_per_player
    code, out = run(make(work, "c8_static_member"), capsys)
    found = {(path, line, rule) for path, line, rule in violations(out) if "coop_far_limits" in path}
    assert found == {("engine/src/xrGame/coop/srv/coop_far_limits_srv.cpp", 2, "L3")}, out
    assert "static member FarLimits::squads_per_player" in out


# --- false alarms of the review's replay (item 11) --------------------------------------------------------------------

def test_l4_counts_only_bool_defaults(work, capsys):
    code, out = run(make(work, "l4_bool_only"), capsys)
    found = sorted(line for path, line, rule in violations(out) if rule == "L4" and path.endswith("coop_route_rules.h"))
    assert found == [10, 13], out  # 9: uint16_t level = kNoLevel and 12: uint32_t host_peer = 0 are data


def test_l5_flags_server_hooks_not_core_hooks(work, capsys):
    code, out = run(make(work, "l5_hooks"), capsys)
    l5 = {(path, line) for path, line, rule in violations(out) if rule == "L5"}
    assert l5 == {("engine/src/xrGame/alife_x.cpp", 4),        # an entry point, in a file without "coop"
                  ("engine/src/xrGame/alife_y.cpp", 5),        # a srv function with a neutral name
                  ("engine/src/xrGame/actor_hook.cpp", 6)}, out  # a mode predicate
    # actor_hook.cpp:5 calls coop::items::may_pick, an Ядро function: a stock edit is an Ядро change for the gate anyway


def test_void_function_does_not_taint(work, capsys):
    code, out = run(make(work, "taint_void"), capsys)
    found = sorted(line for path, line, rule in violations(out) if path.endswith("coop_players.cpp"))
    assert found == [6, 11, 17], out  # 16: equip_loading_frame() is a command, not a question


# --- the layer of a file ----------------------------------------------------------------------------------------------

def test_default_layer_of_new_files():
    layers = check.parse_layers((FIXTURES / "clean/tools/layers.txt").read_text(encoding="utf-8"), FIXTURES / "clean")
    assert layers.layer_of("engine/src/xrGame/Level.cpp") == "stock"              # in the stock list
    assert layers.layer_of("engine/src/xrGame/ui/UIRayPanel.cpp") == "core"       # a new file of ours: core
    assert layers.layer_of("engine/src/xrEngine/raylink_version.h") == "core"
    assert layers.layer_of("gamedata/scripts/coop_new_area.script") == "core"
    assert layers.layer_of("gamedata/scripts/coop_srv_new_area.script") == "srv"  # by its prefix
    assert layers.layer_of("gamedata/scripts/coop_hostplay_menu.script") == "hostplay"
    assert layers.layer_of("engine/src/xrCoop/coop_soft_move.h") == "dying"
    real = check.parse_layers((ROOT / "tools/layers.txt").read_text(encoding="utf-8"), ROOT)
    assert real.layer_of("engine/src/xrGame/ui/UIRayPanel.cpp") == "core"
    assert real.layer_of("engine/src/xrGame/Level.cpp") == "stock"
    assert real.layer_of("engine/src/xrGame/coop/srv/coop_srv_new.cpp") == "srv"
    assert real.layer_of("engine/src/xrGame/coop/coop_new.cpp") == "core"


def test_stock_rows_need_the_stock_list(work, capsys):
    root = make(work)
    layers = root / "tools" / "layers.txt"
    layers.write_text(layers.read_text(encoding="utf-8").replace("stock-list tools/stock_files.txt\n", ""),
                      encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 2 and "stock-list" in out, out
    root2 = make(work / "b")
    (root2 / "tools" / "stock_files.txt").unlink()
    code, out = run(root2, capsys)
    assert code == 2 and "stock_files.txt" in out, out


# --- the ceiling: today's lines may stay, the count only goes down ----------------------------------------------------

def allow_text(root: Path) -> str:
    return (root / "tools" / "layers_allow.txt").read_text(encoding="utf-8")


def add_line(path: Path, after: str, line: str) -> None:
    text = path.read_text(encoding="utf-8")
    assert after in text
    path.write_text(text.replace(after, after + "\n" + line, 1), encoding="utf-8", newline="\n")


def test_allowed_line_may_stay_and_one_more_fails(work, capsys):
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    add_line(net, "\tif (mgr().is_host()) send_all();", "\tif (mgr().is_host()) send_all();")
    code, out = run(root, capsys)
    assert code == 1, out
    assert ("engine/src/xrGame/coop/coop_net.cpp", 10, "L2") in violations(out), out
    assert "2 found, 1 allowed" in out


def test_one_fewer_passes_and_write_allow_lowers_the_ceiling(work, capsys):
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    net.write_text(net.read_text(encoding="utf-8").replace("\tif (mgr().is_host()) send_all();", "\tsend_all();"),
                   encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 0, out
    assert "stale" in out and "ceiling 2, used 1" in out
    code, out = run(root, capsys, "--write-allow")
    assert code == 0, out
    text = allow_text(root)
    assert text.startswith("# ceiling: 1\n"), text
    assert "coop_net.cpp" not in text
    code, out = run(root, capsys)
    assert code == 0 and "ceiling 1, used 1" in out, out


def test_entries_above_the_ceiling_fail(work, capsys):
    root = make(work, "l2")
    allow = root / "tools" / "layers_allow.txt"
    allow.write_text(allow_text(root) + "L2|engine/src/xrGame/coop/coop_items.cpp|if (mgr().is_client()) return false;|1\n",
                     encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 1, out
    assert "above its ceiling" in out


def test_write_allow_refuses_to_raise_the_ceiling_without_reset(work, capsys):
    root = make(work, "l2")
    before = allow_text(root)
    code, out = run(root, capsys, "--write-allow")
    assert code == 1, out
    assert "--reset-ceiling" in out
    assert allow_text(root) == before
    code, out = run(root, capsys, "--write-allow", "--reset-ceiling")
    assert code == 0, out
    assert allow_text(root).startswith("# ceiling: 3\n")


def test_write_allow_does_not_trade_a_dropped_line_for_a_new_one(work, capsys):
    # the review's ALLOW-b: drop the allowed L2 line, add a new mode check; the sum stays under the ceiling
    root = make(work)
    net = root / "engine/src/xrGame/coop/coop_net.cpp"
    net.write_text(net.read_text(encoding="utf-8").replace("\tif (mgr().is_host()) send_all();", "\tsend_all();"),
                   encoding="utf-8", newline="\n")
    items = root / "engine/src/xrGame/coop/coop_items.cpp"
    items.write_text(items.read_text(encoding="utf-8").replace(
        "\treturn owner == 0 || owner == me;", "\tif (coop::mapserver::is_map_server()) return false;\n"
        "\treturn owner == 0 || owner == me;"), encoding="utf-8", newline="\n")
    before = allow_text(root)
    code, out = run(root, capsys, "--write-allow")
    assert code == 1 and "new or grown" in out and "is_map_server" in out, out
    assert allow_text(root) == before
    code, out = run(root, capsys)
    assert code == 1, out


def test_write_allow_is_deterministic(work, capsys):
    root = make(work, "taint_cpp", "l5")
    run(root, capsys, "--write-allow", "--reset-ceiling")
    first = allow_text(root)
    run(root, capsys, "--write-allow", "--reset-ceiling")
    assert allow_text(root) == first
    entries = [l for l in first.splitlines() if l and not l.startswith("#")]
    assert entries == sorted(entries)
    assert int(first.splitlines()[0].split(":")[1]) == sum(int(e.rsplit("|", 1)[1]) for e in entries)


# --- a file moved between layers --------------------------------------------------------------------------------------

def test_srv_file_moved_into_core_fails(work, capsys):
    root = make(work)
    src = root / "engine/src/xrGame/coop/coop_mapserver.cpp"
    src.rename(src.with_name("coop_mapserver_moved.cpp"))  # no srv row matches the new name: core
    code, out = run(root, capsys)
    assert code == 1, out
    assert ("engine/src/xrGame/coop/coop_mapserver_moved.cpp", 6, "L1") in violations(out), out
    assert ("engine/src/xrGame/coop/coop_mapserver_moved.cpp", 13, "L1") in violations(out), out


def test_core_file_moved_into_srv_leaves_a_stale_entry_only(work, capsys):
    root = make(work)
    layers = root / "tools" / "layers.txt"
    layers.write_text(layers.read_text(encoding="utf-8") + "srv engine/src/xrGame/coop/coop_net.cpp\n",
                      encoding="utf-8", newline="\n")
    code, out = run(root, capsys)
    assert code == 0, out
    assert "stale" in out


# --- inputs and the script ------------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["layers.txt", "layers_allow.txt", "srv_entry.txt", "persisted_keys.txt",
                                  "mod_names.txt"])
def test_missing_input_is_exit_2(work, capsys, name):
    root = make(work)
    (root / "tools" / name).unlink()
    code, out = run(root, capsys)
    assert code == 2, out
    assert name in out


def test_runs_isolated_as_a_script(work):
    root = make(work, "l1_cpp")
    done = subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root)], capture_output=True, text=True)
    assert done.returncode == 1, done.stdout + done.stderr
    assert "engine/src/xrGame/coop/coop_items.cpp:7: [L1] " in done.stdout


# --- the real tree ----------------------------------------------------------------------------------------------------

@pytest.mark.skipif(not (ROOT / "engine" / "src" / "xrCoop").is_dir(), reason="engine sources are not checked out")
def test_real_tree_is_within_its_ceiling():
    done = subprocess.run([sys.executable, "-I", str(SCRIPT)], capture_output=True, text=True, cwd=ROOT)
    assert done.returncode == 0, done.stdout[-4000:] + done.stderr
    assert done.stdout.strip().splitlines()[-1].startswith("check_layers: OK")


def test_real_allow_list_is_sorted_and_well_formed():
    path = ROOT / "tools" / "layers_allow.txt"
    lines = path.read_text(encoding="utf-8").splitlines()
    assert lines[0].startswith("# ceiling: ")
    entries = [l for l in lines if l and not l.startswith("#")]
    assert entries == sorted(entries)
    assert int(lines[0].split(":")[1]) >= sum(int(e.rsplit("|", 1)[1]) for e in entries)


# --- review 4, B7: the early warning's new holes (temp/modes_review4/new_attacks4*.py X2-X11) -------------------------
# The trees are written here, not under fixtures/: the repository's .gitignore line `engine/` would hide a new C++
# fixture folder (review 4, B6).

def tree(work: Path, files: dict) -> Path:
    root = make(work)
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8", newline="\n")
    return root


def found(out: str, name: str, rule: str = "L9") -> list[int]:
    return sorted(line for path, line, r in violations(out) if r == rule and path.endswith(name))


# --- P106: engine C++ cannot name a mod --------------------------------------------------------------------------------

@pytest.mark.parametrize(("source", "note"), [
    ("drx_da_main::tick();", "names the mod script 'drx_da_main' (tools/mod_names.txt:1, fixture)"),
    ('lua_getglobal(L,"drx_da_main");', "a string names the mod script 'drx_da_main'"),
    ('"drx_da_main.on_tick";', "a string names the mod script 'drx_da_main'"),
    (r'"\tdrx_da_main";', "a string names the mod script 'drx_da_main'"),
    ('"drx_da" "_main";', "a string names the mod script 'drx_da_main'"),
    ('R"(drx_da_main)";', "a string names the mod script 'drx_da_main'"),
    ('#include "drx_da_main.h"', "a string names the mod script 'drx_da_main'"),
    ('#include <drx_da_main.h>', "names the mod script 'drx_da_main'"),
    ('#if 0\ndrx_da_main::tick();\n#endif', "names the mod script 'drx_da_main'"),
    ('"// drx_da_main";', "a string names the mod script 'drx_da_main'"),
    ('R"(/* DAO */)";', "a string names the mod script 'DAO'"),
    ('R"tag(\ndrx_da_main\n)tag";', "a string names the mod script 'drx_da_main'"),
    ('lua_getglobal(L,"coop_mods_items");', "a string names the mods layer 'coop_mods_items'"),
    ('Msg("failed: coop_mods_x.%s", drx_da_main);', "a string names the mods layer 'coop_mods_x'"),
])
def test_l12_mod_names_in_code_and_literals(work, capsys, source, note):
    code, out = run(tree(work, {X: "\n" + source + "\n"}), capsys)
    assert code == 1, out
    assert found(out, X, "L12") == ([3] if source.startswith("#if") else [2]), out
    assert note in out


def test_l12_ignores_comments_and_nonmatching_tokens(work, capsys):
    root = tree(work, {X: """\
// drx_da_main
/* larp
drx_da_main DAO coop_mods_items */
'"' // drx_da_main
drx_da_main2; my_drx_da_main; "drx_da_mainx"; arm; larp; dao; coop_mods_count;
"""})
    code, out = run(root, capsys)
    assert code == 0, out
    assert violations(out) == []


def test_l12_scans_only_engine_cpp_under_src_outside_third_party(work, capsys):
    root = tree(work, {
        "engine/gamedata/scripts/mod.script": 'local name = "drx_da_main"\n',
        "gamedata/scripts/coop_mods_fixture.script": 'local name = "drx_da_main"\n',
        "engine/src/3rd party/mod.cpp": "drx_da_main::tick();\n",
        "tests/test_srv_mod.cpp": 'constexpr auto name = "drx_da_main";\n',
    })
    code, out = run(root, capsys)
    assert code == 0 and not violations(out), out


L12_STOCK = "engine/src/xrEngine/stock_mod.cpp"


def mark_stock(root: Path, path: str) -> None:
    with (root / "tools/stock_files.txt").open("a", encoding="utf-8") as stock:
        stock.write(f"\n{path}\n")


def test_l12_checks_every_cpp_layer(work, capsys):
    dying = "engine/src/xrCoop/coop_soft_move.h"
    paths = {
        X: "core",
        "engine/src/xrGame/coop/srv/mod.cpp": "srv",
        "engine/src/xrGame/coop/hostplay/mod.cpp": "hostplay",
        L12_STOCK: "stock",
        dying: "dying",
    }
    root = tree(work, {path: "drx_da_main::tick();\n" for path in paths})
    mark_stock(root, L12_STOCK)
    with (root / "tools/layers.txt").open("a", encoding="utf-8") as layers_file:
        layers_file.write(f"\ndying {dying}\n")
    layers = check.parse_layers((root / "tools/layers.txt").read_text(encoding="utf-8"), root)
    assert {path: layers.layer_of(path) for path in paths} == paths
    code, out = run(root, capsys)
    assert code == 1, out
    assert {v for v in violations(out) if v[2] == "L12"} == {(path, 1, "L12") for path in paths}, out


def test_l12_gate_model_checks_lazy_stock_without_mutating_it(work, capsys):
    root = tree(work, {L12_STOCK: "drx_da_main::tick();\n"})
    mark_stock(root, L12_STOCK)
    layers = check.parse_layers((root / "tools/layers.txt").read_text(encoding="utf-8"), root)
    entries = check.parse_names((root / "tools/srv_entry.txt").read_text(encoding="utf-8"))
    model = check.build(root, layers, entries)
    stock = model.by_path[L12_STOCK]
    assert stock.data and not stock.code
    assert check.main(["--root", str(root)], model=model) == 1
    out = capsys.readouterr().out
    assert found(out, L12_STOCK, "L12") == [1], out
    assert stock.data and not stock.raw and not stock.code and not stock.code_strings


@pytest.mark.parametrize("source", [
    '"drx_da" "_main";\n',
    '"drx_da" /* comment */ "_main";\n',
    r'"\tdrx_da_main";' + "\n",
])
def test_l12_stock_prefilter_accepts_names_only_visible_after_literal_processing(work, capsys, source):
    root = tree(work, {L12_STOCK: source})
    mark_stock(root, L12_STOCK)
    code, out = run(root, capsys)
    assert code == 1 and found(out, L12_STOCK, "L12") == [1], out


def test_l12_debt_uses_the_allow_counts_and_warns_when_moved(work, capsys):
    source = "zonepath::Path p;\n"
    root = tree(work, {X: source * 2, "tools/mod_names.txt": "debt R1 zonepath\nignore unused\n"})
    allow = allow_text(root).replace("# ceiling: 2", "# ceiling: 4") + f"L12|{X}|{source.strip()}|2\n"
    (root / "tools/layers_allow.txt").write_text(allow, encoding="utf-8")
    code, out = run(root, capsys)
    assert code == 0, out
    assert "warning: tools/mod_names.txt:2: ignore 'unused' covers no script row" in out
    (root / X).write_text(source * 3, encoding="utf-8")
    code, out = run(root, capsys)
    assert code == 1 and "3 found, 2 allowed" in out, out
    assert "P106 R1 debt 'zonepath' (tools/mod_names.txt:1)" in out
    (root / X).write_text("", encoding="utf-8")
    code, out = run(root, capsys)
    assert code == 0, out
    assert ("warning: tools/mod_names.txt:1: debt R1 'zonepath' names no line any more: "
            "the item is moved, delete the row") in out
    assert "warning: stale allow entry (allowed 2, found 0): L12|" in out


def test_l12_debt_path_scope_and_mod_names_override(work, capsys):
    root = tree(work, {
        X: 'const auto section = "script_zone";\n',
        "engine/src/xrCoop/coop_local_zones.h": 'const auto section = "script_zone";\n',
        "tools/scoped.txt": "debt R4 script_zone engine/src/xrCoop/coop_*_zones.h\n",
    })
    code, out = run(root, capsys, "--mod-names", str(root / "tools/scoped.txt"))
    assert code == 1, out
    assert [v for v in violations(out) if v[2] == "L12"] == [
        ("engine/src/xrCoop/coop_local_zones.h", 1, "L12"),
    ], out


def test_l12_write_allow_requires_a_ceiling_reset_for_new_entries(work, capsys):
    root = tree(work, {X: "drx_da_main::tick();\n"})
    code, out = run(root, capsys, "--write-allow")
    assert code == 1 and "refusing --write-allow" in out, out
    assert "L12|" not in allow_text(root)
    code, out = run(root, capsys, "--write-allow", "--reset-ceiling")
    assert code == 0 and "ceiling 3" in out, out
    assert f"L12|{X}|drx_da_main::tick();|1" in allow_text(root)


@pytest.mark.parametrize("row", [
    "script valid", "script some-name fixture", "name !DAO", "ignore", "debt R5 word",
    "debt R1 word path extra", "build gamma-b61 wrong-date E:/stand 10 3", "unknown word",
])
def test_l12_bad_input_reports_the_line(work, capsys, row):
    root = tree(work, {"tools/mod_names.txt": f"# test\nname DAO\n{row}\n"})
    code, out = run(root, capsys)
    assert code == 2 and "mod_names.txt line 3:" in out, out


# Remove entries and lower counts here as the P106 adapters replace the engine debt.
P106_TODAY = {
    ("engine/src/" + path, code): count
    for path, entries in {
        'xrCoop/coop_local_zones.h': {
            'inline bool local_section(std::string_view section) { return section == "script_zone"; }': 1,
        },
        'xrCoop/coop_trade_permit.h': {
            'bool issue(uint32_t player, uint16_t computer, uint16_t trader, uint64_t now, uint64_t ttl_ms, float reach)': 1,
            'case Verdict::FarFromComputer: return "far from the computer";': 1,
            'case Verdict::NoComputer: return "no computer";': 1,
            'const uint16_t c = object_of(computer);': 1,
            'float to_computer = -1.f;': 1,
            'if (!(f.to_computer >= 0.f))': 1,
            'if (f.to_computer > p->reach)': 1,
            'if (player == 0 || player == kNoPlayer || computer == 0 || computer == kNoObject || trader == 0 ||': 1,
            'inline Window window_of(uint16_t trader, double computer, double ms_left, uint64_t now)': 1,
            'inline bool window_keeps(const Window& w, uint16_t partner, uint64_t now, float to_computer)': 1,
            'p.computer = computer;': 1,
            'return w.computer != kNoObject && w.trader != kNoObject && w.trader == partner && now < w.until && to_computer >= 0.f &&': 1,
            'to_computer <= kWindowReach;': 1,
            'trader == kNoObject || computer == trader || ttl == 0 || !(reach > 0.f) || std::isinf(reach))': 1,
            'uint16_t computer = kNoObject;': 2,
            'w.computer = c;': 1,
        },
        'xrCoop/coop_zone_path_rules.h': {
            'namespace zonepath': 1,
        },
        'xrGame/coop/coop_objects.cpp': {
            '!zonepath::same_zone(run.p.section_hash, zonepath::name_hash(zone->cNameSect().c_str()), run.p.origin, pos))': 1,
            '#include "xrCoop/coop_zone_path_rules.h"': 1,
            'const u32 tick = zonepath::tick_at(run.p, ran);': 1,
            'const u64 ran = zonepath::run_at(run.base_ms, run.base_run, now);': 1,
            'const zonepath::Point to = zonepath::point_at(run.p, run.ys, ran);': 1,
            'here = zonepath::same_zone(s.p.section_hash, zonepath::name_hash(zone->cNameSect().c_str()), s.p.origin, pos);': 1,
            'if (!(v > -double(zonepath::kMaxCoord) && v < double(zonepath::kMaxCoord)))': 1,
            'if (!r.ok() || count > zonepath::kMaxPathsPerMessage)': 1,
            'if (!zonepath::read_path(r, p, phase))': 1,
            'if (run.zone || now - run.received > zonepath::kPendingTtlMs)': 1,
            'int l_zone_path(lua_State* L)': 1,
            'lua_finite(L, 3, p.origin[1]) && lua_finite(L, 4, p.origin[2]) && lua_whole(L, 5, 0, zonepath::kCircle - 1, i0) &&': 1,
            'lua_pushcfunction(L, &l_zone_path);': 1,
            'lua_setfield(L, -2, "zone_path");': 1,
            'lua_whole(L, 6, 1, zonepath::kMaxIStep, i_step) && lua_whole(L, 7, 1, zonepath::kMaxJStep, j_step) &&': 1,
            'ok = zonepath::valid(p) && zonepath::same_zone(p.section_hash, p.section_hash, p.origin, pos);': 1,
            'p.section_hash = zonepath::name_hash(zone->cNameSect().c_str());': 1,
            'return zonepath::heights(p, [graph](float x, float y, float z, float& out) {': 1,
            'std::vector<float> path_heights(const zonepath::Path& p)': 1,
            'zonepath::Path p;': 4,
            'zonepath::write_path(w, run.p, zonepath::phase_ms(run.p, zonepath::run_at(run.base_ms, run.base_run, now)));': 1,
        },
        'xrGame/coop/coop_requests.cpp': {
            'constexpr const char* kRiderScript = "coop_mods_item_state";': 1,
            'int lua_silencer_state(lua_State* L)': 1,
            'lua_getfield(L, -1, "native_silencer_state");': 1,
            'lua_getglobal(L, "coop_mods_items");': 1,
            'lua_getglobal(L, "coop_mods_move_limits");': 1,
            'lua_pushcfunction(L, lua_silencer_state);': 1,
        },
        'xrGame/coop/coop_trade.cpp': {
            '::Msg("! [coop] coop_mods_trade_computer.%s failed (the stock rules stand): %s", fn, err ? err : "?");': 1,
            '::Msg("! [coop] trade: player #%u\'s computer grant for %u through %u is not kept (%s)", from, u32(trader_id),': 1,
            '::Msg("[coop] trade #%u: the computer permit does not hold (%s), the stock rules apply", d.seq,': 1,
            '::Msg("[coop] trade computer: %u permits held, %llu issued, %llu not kept, %llu deals let through",': 1,
            '::Msg("[coop] trade: player #%u may trade with %u through computer %u", from, u32(trader_id), u32(computer));': 1,
            'book.issue(from, computer, trader_id, f.now, trade_permit::ttl_of(g[1]), trade_permit::reach_of(g[2])))': 1,
            'bool call_trade_computer(const char* fn, double a, double b, double out[3])': 1,
            'const float to_computer = distance_to(Actor(), find_object(g_view.remote.computer));': 1,
            'const u16 computer = trade_permit::object_of(g[0]);': 1,
            'f.to_computer = distance_to(smart_cast<CGameObject*>(find_object(join::proxy_of_peer(from))), find_object(computer));': 1,
            'f.to_computer = distance_to(smart_cast<CGameObject*>(proxy), find_object(p->computer));': 1,
            'if (!call_trade_computer("take_grant", double(from), double(trader_id), g))': 1,
            'if (!world::is_player_proxy(computer) && !world::is_player_proxy(trader_id) &&': 1,
            'if (call_trade_computer("window_grant", double(trader), 0.0, g))': 1,
            'if (computer == trade_permit::kNoObject)': 1,
            'int lua_trade_computer(lua_State* L)': 1,
            'lua_getglobal(L, "coop_mods_trade_computer");': 1,
            'lua_pushcfunction(L, &lua_trade_computer);': 1,
            'return trade_permit::window_keeps(g_view.remote, g_view.id, now_ms(), to_computer);': 1,
            'u32(computer), trade_permit::verdict_name(v));': 1,
        },
    }.items()
    for code, count in entries.items()
}

P106_DEBT_TODAY = {
    ("R1", "zonepath", ""),
    ("R1", "l_zone_path", ""),
    ("R1", "zone_path", ""),
    ("R1", "coop_zone_path_rules", ""),
    ("R2", "to_computer", ""),
    ("R2", "lua_trade_computer", ""),
    ("R2", "call_trade_computer", ""),
    ("R2", "computer", "engine/src/xrCoop/coop_trade_permit.h"),
    ("R2", "computer", "engine/src/xrGame/coop/coop_trade.cpp"),
    ("R3", "native_silencer_state", ""),
    ("R3", "lua_silencer_state", ""),
    ("R4", "script_zone", "engine/src/xrCoop/coop_local_zones.h"),
}


def test_l12_real_allow_and_debt_only_shrink():
    _, allowed = check.parse_allow((ROOT / "tools/layers_allow.txt").read_text(encoding="utf-8"))
    assert {(path, code): count for (rule, path, code), count in allowed.items()
            if rule == "L12" and count > P106_TODAY.get((path, code), 0)} == {}
    mods = check.parse_mod_names((ROOT / "tools/mod_names.txt").read_text(encoding="utf-8"))
    debt = {(row.build_or_debt, row.token, row.scope) for row in mods if row.kind == "debt"}
    assert debt <= P106_DEBT_TODAY



STOCK_MOD_SCRIPTS = Path("D:/Projects/ForEverything/anomaly-ref/unpacked/scripts")


def test_l12_real_mod_names_are_well_formed():
    mods = check.parse_mod_names((ROOT / "tools/mod_names.txt").read_text(encoding="utf-8"))
    scripts = [row.token for row in mods if row.kind == "script"]
    assert scripts == sorted(set(scripts))
    assert scripts
    local = {p.stem for folder in ("engine/gamedata/scripts", "gamedata/scripts", "gamedata_gamma/scripts")
             for p in (ROOT / folder).glob("*.script")}
    assert local.isdisjoint(scripts)


@pytest.mark.skipif(not STOCK_MOD_SCRIPTS.is_dir(), reason="stock Anomaly scripts are unavailable")
def test_l12_real_mod_names_exclude_stock_scripts_ignoring_case():
    mods = check.parse_mod_names((ROOT / "tools/mod_names.txt").read_text(encoding="utf-8"))
    stock = {p.stem.casefold() for p in STOCK_MOD_SCRIPTS.glob("*.script")}
    assert stock.isdisjoint(row.token.casefold() for row in mods if row.kind == "script")


FAR_CFG = "-- Ядро: limits\nmax_squads = 4\n\nfunction may_spawn(n)\n\treturn n < max_squads\nend\n"


def test_x2_a_load_time_helper_patching_its_parameter_is_l9(work, capsys):
    root = tree(work, {"gamedata/scripts/coop_srv_far_board.script":
                       "-- srv: far squads keep their targets\n"
                       "local function wrap(tbl, key, fn)\n\tlocal base = tbl[key]\n"
                       "\ttbl[key] = function(...) return fn(base, ...) end\nend\n\n"
                       "local function far_assign(base, board, squad, smart_id)\n\treturn base(board, squad, smart_id)\nend\n\n"
                       "wrap(sim_board.simulation_board, \"assign_squad_to_smart\", far_assign)\n"
                       "local mine = {}\nlocal function put(t, k) t[k] = true end\nput(mine, \"a\")\n"})
    code, out = run(root, capsys)
    assert code == 1 and found(out, "coop_srv_far_board.script") == [4], out  # 13: put() writes into its own table
    assert "sim_board" in out


def test_x3_x4_a_copy_of_a_foreign_table_through_rawget_or_a_file_level_global_is_not_own(work, capsys):
    root = tree(work, {"gamedata/scripts/coop_far_cfg.script": FAR_CFG,
                       "gamedata/scripts/coop_srv_far_cfg.script":
                       "-- srv: the world server's limits\nlocal cfg = rawget(_G, \"coop_far_cfg\")\n"
                       "local alt = _G[\"coop_far_cfg\"]\n\n"
                       "function on_game_start()\n\tcfg.max_squads = 2\n\talt.max_squads = 3\nend\n",
                       "gamedata/scripts/coop_srv_far_cfg2.script":
                       "-- srv: the world server's limits\nfar_cfg = coop_far_cfg\nfar_db = db\nfar_own = far_own or {}\n"
                       "far_mine = {}\nfar_alias = far_mine\n\n"
                       "function on_game_start()\n\tfar_cfg.max_squads = 2\n\tfar_db.coop_far_world = true\n"
                       "\tfar_own.x = 1\n\tfar_alias.y = 2\nend\n"})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_srv_far_cfg.script") == [6, 7], out
    assert found(out, "coop_srv_far_cfg2.script") == [9, 10], out  # 11, 12: its own tables


def test_x5_x6_a_function_literal_run_at_load_is_load_time(work, capsys):
    root = tree(work, {"gamedata/scripts/coop_srv_far_hud2.script":
                       "-- srv: no map spots for far players\nlocal started = (function()\n"
                       "\tcoop_items.set_spots_enabled(false)\n\texec_console_cmd(\"ai_use_old_vision 1\")\n"
                       "\treturn true\nend)()\n",
                       "gamedata/scripts/coop_srv_far_names.script":
                       "-- srv: far squad names\nlocal names = {}\n"
                       "string.gsub(\"far_a far_b\", \"%S+\", function(w) names[#names + 1] = w; coop_items.set_x(false) end)\n"
                       "table.sort(names, function(a, b) coop_items.set_y(1) return a < b end)\n"
                       "local ok = pcall(function() return rawget(_G, \"printf\") end)\n"
                       "pcall(function() coop_items.set_z(1) end)\n"
                       "local later = { on_tick = function() coop_items.set_w(1) end }\n"})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_srv_far_hud2.script") == [3, 4], out
    # 5: pcall of a pure body is pure (the review's false alarm); 7: a function kept in a table runs later
    assert found(out, "coop_srv_far_names.script") == [3, 4, 6], out


def test_x7_core_building_a_script_name_is_l3(work, capsys):
    root = tree(work, {"gamedata/scripts/coop_price_kinds.script":
                       "-- Ядро\nlocal KINDS = { \"group\", \"srv_far\" }\nfunction factor(item)\n\tlocal f = 1\n"
                       "\tfor _, kind in ipairs(KINDS) do\n\t\tlocal m = rawget(_G, \"coop_\" .. kind .. \"_prices\")\n"
                       "\t\tlocal n = _G[\"coop_\" .. kind]\n\t\tlocal fixed = rawget(_G, \"coop_items\")\n"
                       "\tend\n\treturn f\nend\n",
                       "gamedata/scripts/coop_srv_far_prices.script": "-- srv\nfunction price_factor(item)\n\treturn 1\nend\n"})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_price_kinds.script", "L3") == [6, 7], out  # 8: a fixed name of Ядро
    assert "computed script name" in out


HOOKS_H = ("#pragma once\nnamespace coop::hooks\n{\nusing SkipFn = bool (*)(unsigned short);\nvoid set_skip(SkipFn fn);\n"
           "template <class T> struct AutoReg\n{\n\tAutoReg() { set_skip(&T::skip); }\n};\n}\n")


def test_x8b_a_static_object_of_a_class_template_with_a_constructor_is_l9c(work, capsys):
    root = tree(work, {"engine/src/xrGame/coop/coop_hooks.h": HOOKS_H,
                       "engine/src/xrGame/coop/srv/coop_far_skip.cpp":
                       "#include \"../coop_hooks.h\"\nnamespace coop::srvfar\n{\nstruct FarSkip\n{\n"
                       "\tstatic bool skip(unsigned short id) { return false; }\n};\n"
                       "static coop::hooks::AutoReg<FarSkip> s_reg;\nstatic FarSkip s_plain;\n}\n"})
    code, out = run(root, capsys)
    assert found(out, "coop_far_skip.cpp", "L9C") == [8], out  # 9: FarSkip has no constructor
    assert "the constructor AutoReg()" in out


def test_x10b_a_function_a_srv_macro_spells_is_found_when_core_calls_it(work, capsys):
    root = tree(work, {"engine/src/xrGame/coop/coop_far_hooks.h":
                       "#pragma once\nnamespace coop\n{\nbool coop_far_hook_skip(unsigned short id);\n"
                       "inline bool far_skip_any(unsigned short id) { return coop_far_hook_skip(id); }\n}\n",
                       "engine/src/xrGame/coop/srv/coop_far_hook.cpp":
                       "#include \"../coop_far_hooks.h\"\n#define COOP_FAR_HOOK(name) bool coop_far_hook_##name(unsigned short id)\n"
                       "namespace coop\n{\nCOOP_FAR_HOOK(skip)\n{\n\treturn false;\n}\n}\n"})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_far_hooks.h", "L3") == [5], out
    assert "coop_far_hook_skip" in out


def test_x11_a_static_initializer_with_a_call_in_a_srv_test_is_l9c(work, capsys):
    root = tree(work, {"tests/test_srv_far_env.cpp":
                       "// srv tests: far squads\n#include <cstdlib>\n"
                       "static const int s_runs = (_putenv(\"COOP_FUZZ_RUNS=1\"), 0);\nstatic const int s_plain = 4;\n"
                       "TEST(far_env)\n{\n\tCHECK(s_runs == 0);\n}\n",
                       "tests/test_items.cpp": "static const int s_other = (_putenv(\"X=1\"), 0);\n"})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "tests/test_srv_far_env.cpp", "L9C") == [3], out  # 4: no call
    assert not found(out, "tests/test_items.cpp", "L9C"), out  # a co-op test file is the co-op tests' own business


# --- guard round 8: the S4 reviews' holes (temp/s4/07_7.md F2, 08_8.md B4, 04_4.md h2) ---------------------------------
# Hostile trees of the reviews (temp/rv_A-S4C/hostile.py H1-H5, H9, H11; temp/rv_A-S4ML/hostile.py h5, h6;
# temp/rv_A-S4S probe h2), written here for the same reason as above (.gitignore `engine/`).

MGR = "engine/src/xrGame/coop/coop_manager.cpp"
LEVELS = "engine/src/xrGame/coop/coop_levels.cpp"

# (1) the S4 interface (xrCoop/coop_mode.h) asked as a mode check in an Ядро file (review A-S4C, F2)
F2_NET = ("// Ядро\n#include \"xrCoop/coop_mode.h\"\nnamespace coop\n{\nvoid host_flush(PeerId to)\n{\n"
          "\tif (has(mode().roles(), ProcessRole::MapServer)) return;\n"                        # 7  H1
          "\tif (mgr().world_session().session_mode() == SessionMode::Server) return;\n"      # 8  H2
          "\tif (!strcmp(mode().name(), \"map server\")) return;\n"                            # 9  H3
          "\tif (mode().roles() & 16) return;\n"                                              # 10 H4
          "\tif (&mode() == mode_for(Entry::MapServer, SessionMode::Server)) return;\n"       # 11 H5
          "\tswitch (mgr().session().session_mode()) { case SessionMode::Server: return; default: break; }\n"  # 12 H9
          "\tif (mode().takes_own_ids()) return;\n"                                           # 13 H10: an answer
          "\t::Msg(\"[coop] mode %s\", mode().name());\n"                                     # 14 printed, not compared
          "\tif (mgr().roles() == 19) return;\n"                                              # 15 Manager's roles
          "\tif (roles_of(Phase::Live) & 16) return;\n"                                       # 16 roles_of outside set_phase
          "\tif (boot_layers()) return;\n"                                                    # 17 a boot outside the starts
          "\tif (install_mode(*mode_for(Entry::Host, SessionMode::None))) return;\n"          # 18
          "\tconst Mode& m = mode();\n\tif (m.name()[0] == 'm') return;\n"                    # 19, 20 an alias of mode()
          "\tif (typeid(mode()) == typeid(Mode)) return;\n"                                   # 21
          "\tif (mgr().has_role(ProcessRole::Player)) return;\n"                              # 22 is_player: one meaning
          "\tif (cfg.mode == SessionMode::None) return;\n"                                    # 23 no mode: no question
          "}\n}\n")
F2_MGR = ("// Ядро\n#include \"coop_manager.h\"\nnamespace coop\n{\n"
          "u8 roles_of(Phase p)\n{\n\tif (p == Phase::Off)\n\t\treturn 0;\n"
          "\tconst u8 roles = mode().roles();\n\treturn roles ? roles : client_roles();\n}\n"        # 9 allowed
          "void Manager::set_phase(Phase p)\n{\n\tm_phase = p;\n\tm_roles = roles_of(p);\n}\n"         # 15 allowed
          "bool Manager::enter_mode(Mode* m)\n{\n\treturn m && install_mode(*m);\n}\n"                  # 19 allowed
          "void Manager::enter_mode_of_welcome(SessionMode said)\n{\n"
          "\tif (Mode* m = mode_for(Entry::Client, said))\n\t\tinstall_mode(*m);\n}\n"                  # 23, 24 allowed
          "bool Manager::start_host(u16 port)\n{\n\treturn enter_mode(mode_for(Entry::Host, SessionMode::None));\n}\n"
          "bool Manager::start_map_server(u16 port)\n{\n"
          "\treturn enter_mode(mode_for(Entry::MapServer, SessionMode::Server));\n}\n"                 # 32 allowed
          "void Manager::autostart()\n{\n\tif (boot_layers())\n\t\treturn;\n}\n"                       # 36 allowed
          "void Manager::frame()\n{\n"
          "\tif (m_roles & 16)\n\t\treturn;\n"                                                         # 41 not a start
          "\tif (mode_for(Entry::Host, SessionMode::Server) == &mode())\n\t\treturn;\n"                # 43
          "\tif (enter_mode(mode_for(Entry::MapServer, SessionMode::Server)))\n\t\treturn;\n"          # 45
          "}\n}\n")
F2_LEVELS = ("// Ядро\nnamespace coop::levels\n{\nbool split()\n{\n\tif (mgr().is_client())\n"
             "\t\treturn mgr().world_session().session_mode() == SessionMode::Server;\n"              # 7 allowed
             "\treturn false;\n}\n"
             "bool remote()\n{\n\treturn mgr().world_session().session_mode() == SessionMode::Server;\n}\n}\n")  # 12
# the words' own definitions: the enums' codec and role sets (VOCABULARY in check_layers.py)
F2_ROLES = ("// Ядро\n#pragma once\nnamespace coop\n{\nenum class ProcessRole : uint8_t\n{\n\tWorldServer = 1,\n"
            "\tMapServer = 16,\n};\nconstexpr uint8_t host_roles()\n{\n"
            "\treturn uint8_t(ProcessRole::WorldServer);\n}\n"                                        # 12 allowed
            "constexpr bool is_ms(uint8_t r)\n{\n\treturn (r & uint8_t(ProcessRole::MapServer)) != 0;\n}\n}\n")  # 16
F2_PROTOCOL = ("// Ядро\nnamespace coop\n{\nconst char* session_mode_name(SessionMode mode)\n{\n"
               "\tswitch (mode)\n\t{\n\tcase SessionMode::Coop: return \"coop\";\n"                    # 8 allowed
               "\tcase SessionMode::Server: return \"server\";\n\t}\n\treturn \"none\";\n}\n"          # 9 allowed
               "bool HelloMsg::read(Reader& r)\n{\n\treturn r.u8() == uint8_t(SessionMode::Server);\n}\n}\n")  # 15
F2_SRV_MODE = ("// srv\nnamespace coop::srv\n{\nLayer& layer()\n{\n\tstatic ServerLayer s;\n\treturn s;\n}\n"
               "Mode* mode_of(Entry e, SessionMode said) { return said == SessionMode::Server ? nullptr : nullptr; }\n}\n")
F2_H11 = ("// Ядро\nnamespace coop\n{\nvoid boot()\n{\n\tstatic coop::Layer* const s_srv{&srv::layer()};\n"  # 6 H11
          "\ts_srv->boot_frame();\n}\n}\n")


def test_r8_core_asking_the_mode_interface_is_l1(work, capsys):
    root = tree(work, {X: F2_NET})
    code, out = run(root, capsys)
    assert code == 1, out
    # 13: an interface answer; 14: the name printed; 22: has_role(ProcessRole::Player); 23: SessionMode::None
    assert found(out, "coop_x.cpp", "L1") == [7, 8, 9, 10, 11, 12, 15, 16, 17, 18, 20, 21], out
    assert "the session's mode" in out


def test_r8_the_mode_interface_is_asked_only_in_the_starts_split_and_roles_of(work, capsys):
    root = tree(work, {MGR: F2_MGR, LEVELS: F2_LEVELS})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_manager.cpp", "L1") == [41, 43, 45], out  # Manager::frame is no start
    # 4: `bool split()` names the predicate (the old L1); 7: split() itself asks the Welcome's mode (S4C)
    assert found(out, "coop_levels.cpp", "L1") == [4, 12], out


def test_r8_the_words_own_definitions_pass_and_a_new_user_beside_them_fails(work, capsys):
    root = tree(work, {"engine/src/xrCoop/coop_roles.h": F2_ROLES, "engine/src/xrCoop/coop_protocol.cpp": F2_PROTOCOL,
                       "engine/src/xrGame/coop/srv/coop_srv_mode.cpp": F2_SRV_MODE})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_roles.h", "L1") == [16], out  # 12: host_roles() is the role set's own definition
    assert found(out, "coop_protocol.cpp", "L1") == [15], out  # 8, 9: the Welcome byte's own name
    assert not found(out, "coop_srv_mode.cpp", "L1"), out  # a srv file may ask what it likes


def test_r8_h11_a_brace_initialized_address_of_a_srv_function_is_l3(work, capsys):
    root = tree(work, {X: F2_H11, "engine/src/xrGame/coop/srv/coop_srv_mode.cpp": F2_SRV_MODE})
    code, out = run(root, capsys)
    assert code == 1 and found(out, "coop_x.cpp", "L3") == [6], out


def test_r8_the_frozen_lists_only_name_their_functions():
    # the exemptions are functions of named files (review A-S4C F2: only split() and roles_of, plus the starts the
    # switchboard serves and the words' own definitions); a list entry is never a whole file
    for (path, qual, name), kinds in check.IFACE_ALLOWED.items():
        assert path == path.lower() and path.startswith("engine/src/") and name and kinds, (path, qual, name)
        assert kinds <= set(check.IFACE_KINDS), kinds
    starts = {name for (path, _, name) in check.IFACE_ALLOWED if path.endswith("coop_manager.cpp")}
    assert starts == {"roles_of", "set_phase", "enter_mode", "enter_mode_of_welcome", "start_host", "start_map_server",
                      "autostart"}, starts


# (2) Lua: a server part's presence used as a mode test (review A-S4ML, B4 h6); calling a part's function is the
# sanctioned way (docs/contracts/coop_mode_api.md "Server parts") and stays allowed (h5)
B4_CORE = ("-- Ядро\nlocal qc = rawget(_G, \"coop_quests_core\")\n"
           "local function far_mod() return coop_quests_core.part(\"far\") end\n"         # 3 a getter: allowed
           "function order(id)\n\treturn coop_quests_core.part(\"far\").order(id)\nend\n"  # 5 h5: allowed
           "function server_now()\n\treturn coop_quests_core.part(\"far\") ~= nil\nend\n"  # 8 h6
           "function tick()\n\tif qc.part(\"levels\") then return 1 end\n"               # 11
           "\tif not qc.part(\"brain\") then return 2 end\n"                               # 12
           "\tlocal srv = qc.part(\"far\") and \"server\" or \"coop\"\n"                   # 13
           "\tlocal x = qc.part(\"audience\") or start_coop_only()\n"                      # 14
           "\tlocal lv = qc and qc.part and qc.part(\"levels\")\n"                         # 15 a guarded fetch: allowed
           "\tlocal text = lv and lv.elsewhere_text and lv.elsewhere_text(1)\n"            # 16 a part's function
           "\tlocal far = qc and qc.part and qc.part(\"far\") or nil\n"                    # 17 allowed
           "\tif far and far.fallback then return far.fallback(1) end\n"                   # 18 allowed
           "\tlocal is_srv = far ~= nil\n"                                                # 19 its presence kept
           "\tif far_mod() then return 4 end\n"                                           # 20 a getter's presence
           "\tif type(qc.part(\"far\")) == \"table\" then return 5 end\n"                 # 21
           "\tlocal mine = far_mod()\n"                                                   # 22 allowed
           "\tif mine == nil then return 6 end\n"                                         # 23 the guard before a call
           "\treturn mine ~= nil and mine.at_home(tick)\nend\n")                          # 24 the same guard
B4_QC = ("-- Ядро\nlocal held = { parts = {} }\nfunction set_part(name, t) held.parts[name] = t end\n"
         "function part(name) return held.parts[name] end\n"                               # 4 the definition
         "local function far() return part(\"far\") end\n"                                 # 5 a getter
         "function is_server() return part(\"far\") ~= nil end\n")                         # 6


def test_r8_lua_a_server_part_used_as_a_mode_test_is_l1(work, capsys):
    root = tree(work, {"gamedata/scripts/coop_x.script": B4_CORE, "gamedata/scripts/coop_quests_core.script": B4_QC})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_x.script", "L1") == [8, 11, 12, 13, 14, 19, 20, 21], out
    assert found(out, "coop_quests_core.script", "L1") == [6], out
    assert "presence" in out


# (3) Ядро calling the server's part of Session directly (review A-S4S, probe h2): a rule of its own (L11), never in
# the allow list; today's callers are SESSION_SRV_FROZEN in check_layers.py (A-S4Sb moves them), a list that only
# shrinks
H2_CORE = ("// Ядро\nnamespace coop\n{\nvoid bridges_up(Session& s)\n{\n"
           "\ts.issue_bridge(1, token);\n"                                    # 6
           "\tif (s.bridge_connected(0x101)) s.virtual_join(0x101, \"x\");\n"  # 7
           "\ts.on_bridge_joined = [](PeerId) {};\n"                          # 8
           "\tmgr().session().revoke_bridge(2);\n"                            # 9
           "\tif (s.is_virtual()) return;\n"                                  # 10
           "\tcfg.operator_token = token;\n"                                  # 11
           "\ts.on_operator_command = nullptr;\n"                             # 12
           "\tauto f = &Session::host_virtual;\n"                             # 13
           "\ts.send(0, Lane::Reliable, Msg::Chat, w);\n"                     # 14 the Core's own part
           "\tfor (const PeerId b : mgr().session().bridges()) kick(b);\n"    # 15
           "}\n}\n")
SESSION_SELF = ("// Ядро\nnamespace coop\n{\nvoid Session::Impl::bridge_joined(PeerId id)\n{\n"
                "\tif (m_self.on_bridge_joined)\n\t\tm_self.on_bridge_joined(id);\n}\n}\n")


def test_r8_core_calling_the_server_members_of_session_is_l11(work, capsys):
    root = tree(work, {X: H2_CORE, "engine/src/xrCoop/coop_session.cpp": SESSION_SELF})
    code, out = run(root, capsys)
    assert code == 1, out
    assert found(out, "coop_x.cpp", "L11") == [6, 7, 8, 9, 10, 11, 12, 13, 15], out  # 14: send is the Core's
    assert not found(out, "coop_session.cpp", "L11"), out  # the class's own body (A-S4Sb moves it into srv)
    assert "server's part of Session" in out


def frozen_tree(work: Path, path: str, code_line: str, times: int) -> Path:
    body = "".join("\t" + code_line + "\n\t{\n\t}\n" for _ in range(times))
    return tree(work, {path: "// Ядро\nnamespace coop\n{\nvoid f()\n{\n" + body + "}\n}\n"})


def test_r8_l11_is_never_allowed_and_the_frozen_callers_pass_once(work, capsys):
    assert "L11" not in check.ALLOWABLE
    for k, (path, code_line) in enumerate(sorted(check.SESSION_SRV_FROZEN)):
        name = path.rsplit("/", 1)[-1]
        code, out = run(frozen_tree(work / f"once{k}", path, code_line, 1), capsys)
        assert not found(out, name, "L11"), out  # today's line, once (its other rules are the allow list's)
        # once more than frozen: both lines fail, and an allow entry does not help (L11 is never allowed)
        twice = frozen_tree(work / f"twice{k}", path, code_line, 2)
        allow = twice / "tools" / "layers_allow.txt"
        allow.write_text(allow.read_text(encoding="utf-8").replace("# ceiling: 2", "# ceiling: 4")
                         + f"L11|{path}|{code_line}|2\n", encoding="utf-8", newline="\n")
        code, out = run(twice, capsys)
        assert code == 1 and found(out, name, "L11") == [6, 9], out


# today's callers (2026-11-19, review A-S4S blocker 2): the frozen list may only lose entries
SESSION_SRV_TODAY = {
    ("engine/src/xrGame/coop/coop_join.cpp", "if (mgr().session().bridge_connected(bridge))"),
    ("engine/src/xrGame/coop/coop_levels.cpp", "for (const PeerId bridge : mgr().session().bridges())"),
    ("engine/src/xrGame/coop/coop_manager.cpp",
     "m_session.on_operator_command = [](PeerId from, const std::string& line) { dedicated::run_for(from, line); };"),
    ("engine/src/xrGame/coop/coop_manager.cpp",
     "if (!m_world.connect(cfg, \"127.0.0.1\", port, &err) || !m_session.host_virtual(cfg, m_world, &err))"),
}


def test_r8_the_frozen_session_callers_only_shrink():
    assert set(check.SESSION_SRV_FROZEN) <= SESSION_SRV_TODAY
    assert all(n == 1 for n in check.SESSION_SRV_FROZEN.values())


# --- review A-REV-E-1 (temp/w9rev/A-REV-E-1.md), finding 1: the server's Lua table srv.* -------------------------------

SRV_CORE = "gamedata/scripts/coop_probe_srvtable.script"


def test_the_server_table_srv_is_a_mode_check_outside_the_server_layer(work, capsys):
    # srv/coop_srv_script.cpp makes the global table srv in every Lua state (A-S4H): srv.split(), srv.dedicated_new_world()
    # and an alias `local s = srv` got past L1, and so did coop.dedicated_new_world(). Ядро reading it is L1 (a wrapper
    # too), a stock script L5, the co-op layer L3; the server's layer reads it freely
    code, out = run(make(work, "l1_srv_table"), capsys)
    assert code == 1, out
    found_ = set(violations(out))
    assert {(p, n, r) for p, n, r in found_ if p == SRV_CORE} == {
        (SRV_CORE, n, "L1") for n in (4, 5, 6, 7, 9, 10, 11, 12, 15, 16)}, out  # 8: s.split() (its alias line is 7)
    assert ("gamedata/scripts/coop_hostplay_srvtable.script", 3, "L3") in found_, out
    assert ("engine/gamedata/scripts/xr_srvtable.script", 3, "L5") in found_, out
    assert not [v for v in found_ if v[0] == "gamedata/scripts/coop_srv_table.script"], out
    assert len([v for v in found_ if v[0] != SRV_CORE]) == 2, out
