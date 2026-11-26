"""Guard: the border of the three code layers, Ядро (core), Кооп (hostplay) and Сервер (srv) (docs/MODES.md section 5).

The owner, 2026-11-18: "the main thing is that there are no situations like yesterday's, when we were fixing the server
and it touched the co-op". Ядро never asks which mode it runs in; a mode layer never names the other one. This script
fails a change that writes a mode check into Ядро or lets one mode's layer reach the other's, before anything is built.
tools/check_gates.py imports it for core_reach: a srv or hostplay file that Ядро, stock or dying code reaches (includes,
calls, names in Lua, in a C++ string or in a config, declares extern, owns the class of; static initializers) counts as
Ядро for the gate, and so does everything a reached file reaches in turn (to a fixed point).

  python -I tools/check_layers.py [--root DIR] [--mod-names PATH] [--write-allow [--reset-ceiling]] [--top N]

Inputs (under <root>/tools unless given): layers.txt (the layer of every file; its `stock-list` row names the list of
GSC files, tools/stock_files.txt), layers_allow.txt (today's violations: a ceiling that only goes down), srv_entry.txt
(server functions that stock hooks reach), persisted_keys.txt (saved names that never disappear), mod_names.txt
(mod script stems, hand-listed names, ignores and frozen P106 debt). Scanned: engine/src
(without "3rd party") .cpp .h .hpp .inl, gamedata/scripts/*.script, and as stock Lua engine/gamedata/scripts/*.script
and gamedata_gamma/scripts/*.script (the stock scripts the mod patches and the GAMMA layer: axr_main runs every
script's file level and on_game_start in every process). core_reach also reads gamedata/configs,
engine/gamedata/configs and gamedata_gamma/configs (*.ltx, *.xml).

Layers: the last matching row of layers.txt wins; a path no row matches is core. A `stock` row covers only the files of
the stock list (the GSC engine as imported): a new file of ours anywhere under engine/src is core, never stock. A
`dying` row covers only the five hybrid files of DYING_FROZEN (removed in step S2): the list cannot hide a new file.

Rules (ids as in docs/MODES.md section 5):
  L1  Ядро names a mode predicate (is_map_server, g_coop_split_levels, has_role(ProcessRole::MapServer), ...; a string
      "-coop_mapserver" / "-coop_dedicated" / "-coop_host": a probe of the command line; `using namespace` of dedicated or
      mapserver), a macro whose body names one, or a function whose return (or whose short body) names one: the
      wrapper is tainted, transitively; void functions never taint. C++ by its last qualifier (`levels::leads_here(`,
      namespace aliases resolved), bare inside its own file, its namespaces and the namespaces it imports with `using
      namespace`; Lua by name inside the file (locals, aliases `local split = coop.levels.split`), as `script.fn(` from
      other files, through a module-table alias (`local L = coop.levels; L.split()`) and an indexed field
      (`coop.levels["split"]()`)
      Round 8 (review A-S4C F2): an Ядро C++ line that asks the S4 interface which mode it is in: session_mode(,
      SessionMode::Coop / ::Server, ProcessRole:: (but has_role(ProcessRole::X), the old rule), .roles() / m_roles /
      roles_of(, mode_for( / install_mode( / boot_layers(, &mode() ==, typeid / dynamic_cast of mode(), and the mode's
      name (mode().name(), an alias of mode(), session_mode_name() anywhere but in a log call); only in the functions
      IFACE_ALLOWED names (coop_levels.cpp split(), roles_of, coop_manager.cpp's starts, the words' own definitions).
      Lua (review A-S4ML B4): a server part's presence used as a mode test (coop_quests_core.part(...) compared with
      nil, a condition of if / while / not / and / or, type(...) of it; a getter of one; a local part's presence kept
      as a value); calling a part's function is allowed
      Lua (review A-REV-E-1, finding 1): any use of the server's global table srv (srv.x, srv["x"], srv:x, the table as
      a value `local s = srv`, _G.srv, _G["srv"], rawget(_G, "srv")) and dedicated_new_world; a stock script's use is
      L5, the co-op layer's L3, the server layer's own
  L2  Ядро uses an overloaded role: C++ is_host( is_client( is_map_authority( has_role(ProcessRole::WorldClient);
      Lua is_world_server( is_host(; and wrappers of those (taint as L1)
  L3  a reference across layers: Ядро or stock -> srv / hostplay, srv <-> hostplay. C++ #include of a file of that
      layer (an #include of a macro is refused in Ядро: it cannot be resolved), a call of a server entry point
      (srv_entry.txt) or of any function defined only in a file of that layer, a string that names a script of that
      layer (`lua_getglobal(L, "coop_dedicated")`), `extern` of a global only that layer defines; Lua `coop_x.fn` /
      mod("coop_x") / rawget(_G, "coop_x") / _G["coop_x"] / module_of / call_module of a script of that layer (also from
      the stock Lua roots), and a plain string that is exactly a script's name (a dispatch table `{ "coop_x" }` read
      through rawget(_G, name); review 3, C6). The facade coop_mode is allowed. A hostplay script that uses the server's
      Lua table srv (as L1 reads it; review A-REV-E-1, finding 1). And a srv / hostplay file that defines a
      member of a class only Ядро or stock define (`bool coop::FarPolicy::keep_online(...)`: Ядро calls it through an
      object), a member function or a static data member (`u32 FarLimits::squads_per_player = 4;`, C8)
  L4  a default argument or a default member of type bool in an Ядро file whose name has a mode word (level, split,
      host, here, plays, server, elsewhere) or whose comment speaks of a mode (split, map server, world server,
      dedicated, hybrid). Defaults of other types are data (`uint16_t level = kNoLevel`). A member of a .cpp counts only
      with `= true` (`bool here = false;` on a file's own data row is the safe value); headers and parameters always
  L5  a stock engine file line that names a mode predicate, g_coop_headless, g_coop_dedicated, coop_console::, a server
      entry point, a function defined only in a srv or hostplay file, or a tainted L1 wrapper; a stock Lua line that
      names a mode predicate. A hook into an Ядро function is not L5: a stock edit is an Ядро change for
      tools/check_gates.py anyway
  L6  a tombstone of the hybrid anywhere but in a dying file (coop_soft_move, softmove::, story_together (also inside
      g_coop_story_together), coop_world_wait, coop_world_server.h, HostProcess, led_by_host_process)
  L7  a script with more than 190 file-level locals (LuaJIT's limit is 200); every local above 190 counts once
  L8  Steam outside hostplay and xrEngine/x_ray.cpp (Steam, RAYLINK_STEAM_, steam_invite, steam_join)
  L9  a srv script, outside the anonymous functions given to coop_mode.when_srv(...): registers
      (RegisterScriptCallback, also through an alias; xr_conditions / xr_effects / xr_logic fields assigned by `.X =`,
      `["X"] =` or rawset; add_event_handler); assigns into a table that is not its own (`coop_items.pick = ...`,
      `function sim_board.x.f()`, rawset(t, ...), setmetatable(t, ...), `db.flag = true`, `_G.x =`: anything but its
      locals, parameters, for variables, self, its classes, its file-level globals and itself; a local that copies a
      table which is not its own, `local db = db`, is that table, review 3 C1, C3); or calls anything at load: at file
      level, in on_game_start, in a function assigned to it (`on_game_start = start`) and in every function of the file
      those call by name, also from inside a when_srv(...) parenthesis outside an anonymous function (C2, C4):
      CreateTimeEvent, exec_console_cmd, an Ядро setter ..., except pure lookups (rawget, type, pairs, tostring,
      tonumber, string.*, math.*, printf, class, table.insert or setmetatable on a table of its own or a new one,
      pcall of a pure function ...). `coop_mode.when_srv(f())` (the result of a call) is L9 too
  L9C a namespace-scope variable of a srv / hostplay C++ file whose initializer calls a function, or an object of a
      class of ours with a user-declared constructor (`static Registrar s_r;`, `static Registrar s_r(1);`, review 3 C7):
      static initialization runs in every process, the co-op host too; constexpr initializers are not calls
  L10 a key of persisted_keys.txt no longer appears in any script
  L11 an Ядро or stock C++ line names the server's part of Session (issue_bridge, revoke_bridge, bridges, bridge_*,
      virtual_*, is_virtual, host_virtual, on_bridge_*, on_operator_command, operator_refused, operator_token; review
      A-S4S probe h2): only srv reaches it, through srv::SessionSrv. Never an allow entry: today's callers are
      SESSION_SRV_FROZEN (a list that only shrinks); coop_session.cpp/.h are the class itself
  L12 engine C++ in any layer names a mod in code or a literal: a coop_mods_ literal, a name in mod_names.txt, or a
      P106 debt token within its scope. The inventory is generated separately by tools/gen_mod_names.py.
Comments are not code; string contents are not code either (L6, L8, the command-line keys and the Lua module
references and mod names read them).

Allow list: `rule|path|code of the line, comments dropped, white space collapsed|count`, first line `# ceiling: N`.
No line numbers: an edit elsewhere in a file does not break an entry. A (rule, path, code) found more often than
allowed fails on every line of it; found less often is a stale entry (a warning: lower the list with --write-allow).
The sum of the counts may not exceed the ceiling. --write-allow rewrites the list from the tree (sorted, so the same
tree always gives the same file) and sets the ceiling to the new sum; it refuses a new entry or a raised count, and a
higher ceiling, unless --reset-ceiling is given too (only the lead does that, after reviewing the added entries): a
dropped line cannot be traded for a new one.
No `layer-ok` marker exists: an exception is an allow-list entry under the ceiling, visible in review.

Output: one line per violation `path:line: [Ln] text — why`, warnings, then
`check_layers: OK (N files, ceiling M, used K)` (exit 0) or `check_layers: FAIL (n)` (exit 1). Exit 2: an input file
is missing or unreadable.
"""
from __future__ import annotations

import argparse
import bisect
import os
import pathlib
import re
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import date
from typing import Iterable, Iterator, NamedTuple, Optional, Sequence

ROOT = pathlib.Path(__file__).resolve().parent.parent
LAYERS = ("core", "hostplay", "srv", "stock", "dying")
GATE_ROWS = ("gate-core",)  # rows that only tools/check_gates.py reads
CPP_SUFFIXES = frozenset({".cpp", ".h", ".hpp", ".inl"})
HEADER_SUFFIXES = (".h", ".hpp", ".inl")
# stock Lua: the stock scripts the mod patches and the GAMMA layer's scripts (axr_main.script runs every script's
# file level and on_game_start in every process)
STOCK_LUA_ROOTS = ("engine/gamedata/scripts", "gamedata_gamma/scripts")
# configs that name script functions (dialog preconditions and actions, logic condlists)
CONFIG_ROOTS = ("gamedata/configs", "engine/gamedata/configs", "gamedata_gamma/configs")
LOCALS_LIMIT = 190
STEAM_EXEMPT = frozenset({"engine/src/xrEngine/x_ray.cpp"})
FACADE = "coop_mode"
# The hybrid's files, removed in step S2: the only files a `dying` row may cover (a row that names another file is
# ignored, so a new mode check cannot be hidden by calling its file dying). This list only shrinks.
DYING_FROZEN = frozenset({
    "engine/src/xrcoop/coop_soft_move.h",
    "engine/src/xrgame/coop/coop_world_server.cpp",
    "engine/src/xrgame/coop/coop_world_server.h",
    "gamedata/scripts/coop_world_wait.script",
    "gamedata/scripts/coop_world_stage_file.script",
})

# Guard round 8 (review A-S4C, F2). The S4 interface (xrCoop/coop_mode.h) lets Ядро ask a mode's layer about a player,
# a level or its own actor (where, decider_of, decides_world, ...): those answers are allowed. What mode the session is
# in, which roles the process has, the mode's name and the switchboard are not questions Ядро may ask: in an Ядро C++
# file each of these kinds is L1, except in the functions IFACE_ALLOWED names for it.
IFACE_KINDS: dict[str, tuple[Optional[re.Pattern[str]], str]] = {
    "session_mode": (re.compile(r"\bsession_mode\s*\("), "the session's mode (Session::session_mode)"),
    "SessionMode": (re.compile(r"\bSessionMode\s*::\s*(?:Coop|Server)\b"), "a session mode by name"),
    "ProcessRole": (re.compile(r"\bProcessRole\s*::\s*[A-Za-z_]\w*"), "a process role by name"),
    "roles": (re.compile(r"(?:\.|->)\s*roles\s*\(\s*\)"), "the process's roles (mode().roles(), mgr().roles())"),
    "m_roles": (re.compile(r"\bm_roles\b"), "the Manager's roles"),
    "roles_of": (re.compile(r"\broles_of\s*\("), "the roles of a phase (roles_of)"),
    "mode_for": (re.compile(r"\bmode_for\s*\("), "the switchboard (mode_for)"),
    "install_mode": (re.compile(r"\binstall_mode\s*\("), "the switchboard (install_mode)"),
    "boot_layers": (re.compile(r"\bboot_layers\s*\("), "the layers' boots (boot_layers)"),
    "mode_identity": (re.compile(
        r"&\s*(?:coop\s*::\s*)?mode\s*\(\s*\)\s*[!=]=|[!=]=\s*&\s*(?:coop\s*::\s*)?mode\s*\(\s*\)"
        r"|\btypeid\s*\(\s*\*?\s*&?\s*(?:coop\s*::\s*)?mode\s*\("
        r"|\bdynamic_cast\s*<[^<>;]*>\s*\(\s*&?\s*(?:coop\s*::\s*)?mode\s*\("), "which mode object the session has"),
    # mode().name() / session_mode_name(...) anywhere but as an argument of a log call (IFACE_LOG_CALLS)
    "mode_name": (None, "the mode's name used for something else than the log"),
}
# the log calls a mode's name may be given to (they return nothing to branch on)
IFACE_LOG_CALLS = frozenset({"Msg", "Log", "logf", "log", "log_line", "printf", "fprintf", "LogMsg"})
IFACE_MODE_NAME = re.compile(r"\b(?:coop\s*::\s*)?mode\s*\(\s*\)\s*(?:\.|->)\s*name\s*\(\s*\)|\bsession_mode_name\s*\(")
IFACE_MODE_ALIAS = re.compile(r"\b(?:Mode|auto)\s*(?:const\s*)?[&*]\s*([A-Za-z_]\w*)\s*(?:=|\{)\s*&?\s*"
                              r"(?:coop\s*::\s*)?mode\s*\(\s*\)")
IFACE_LITERALS = ("session_mode", "SessionMode", "ProcessRole", "roles", "mode_for", "install_mode", "boot_layers",
                  "mode(", "mode (", "name(", "name (")
# (file, qualifier, function) -> the kinds it may use. This list only shrinks; it never names a whole file. The review
# allowed two (coop_levels.cpp split(): a client's answer from its Welcome, S4C; roles_of: the roles come from the
# mode); the starts of coop_manager.cpp are the switchboard's only callers (a SessionMode there only as mode_for's
# argument); the Manager's own accessors of its roles; and the words' own definitions (the role sets of coop_roles.h,
# the Welcome's mode byte of coop_protocol, Session::session_mode itself).
IFACE_ALLOWED: dict[tuple[str, str, str], frozenset[str]] = {
    ("engine/src/xrgame/coop/coop_levels.cpp", "levels", "split"): frozenset({"session_mode", "SessionMode"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "coop", "roles_of"): frozenset({"roles"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "set_phase"): frozenset({"roles_of", "m_roles"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "enter_mode"): frozenset({"install_mode"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "enter_mode_of_welcome"): frozenset({"mode_for",
                                                                                                 "install_mode"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "start_host"): frozenset({"mode_for"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "start_map_server"): frozenset({"mode_for"}),
    ("engine/src/xrgame/coop/coop_manager.cpp", "Manager", "autostart"): frozenset({"boot_layers"}),
    ("engine/src/xrgame/coop/coop_manager.h", "Manager", "has_role"): frozenset({"m_roles"}),
    ("engine/src/xrgame/coop/coop_manager.h", "Manager", "roles"): frozenset({"m_roles"}),
    ("engine/src/xrcoop/coop_roles.h", "coop", "host_roles"): frozenset({"ProcessRole"}),
    ("engine/src/xrcoop/coop_roles.h", "coop", "dedicated_roles"): frozenset({"ProcessRole"}),
    ("engine/src/xrcoop/coop_roles.h", "coop", "client_roles"): frozenset({"ProcessRole"}),
    ("engine/src/xrcoop/coop_roles.h", "coop", "map_server_roles"): frozenset({"ProcessRole"}),
    ("engine/src/xrcoop/coop_protocol.h", "coop", "session_mode_of_seat"): frozenset({"SessionMode"}),
    ("engine/src/xrcoop/coop_protocol.cpp", "coop", "session_mode_name"): frozenset({"SessionMode"}),
    ("engine/src/xrcoop/coop_protocol.cpp", "WelcomeMsg", "read"): frozenset({"SessionMode"}),
    ("engine/src/xrcoop/coop_session.cpp", "Session", "session_mode"): frozenset({"session_mode"}),
}

# Guard round 8 (review A-S4S, probe h2): the server's part of Session (the bridges, the virtual host, the operator
# token's host side; srv::SessionSrv, xrCoop/srv/coop_session_srv.h, is its API) named from Ядро or stock is L11, a
# rule of its own that the allow list never takes. The class's own files define and run it (A-S4Sb moves the bodies
# into srv). SESSION_SRV_FROZEN: today's callers (path, the line's code with its strings, as an allow entry) -> count,
# which A-S4Sb switches. This list only shrinks.
SESSION_SRV = re.compile(
    r"(?:\.|->|\bSession\s*::)\s*(issue_bridge|revoke_bridge|bridges|bridge_\w+|virtual_\w+|is_virtual|host_virtual|"
    r"on_bridge_\w+|on_operator_command|operator_refused|operator_token)\b")
SESSION_SELF = frozenset({"engine/src/xrcoop/coop_session.cpp", "engine/src/xrcoop/coop_session.h"})
SESSION_SRV_FROZEN: dict[tuple[str, str], int] = {}  # A-S4Sb switched every caller (2026-11-19): empty for good

# Guard round 8 (review A-S4ML, B4 h6): Lua Ядро reaches the server scripts only through coop_quests_core.part(name)
# (docs/contracts/coop_mode_api.md "Server parts"): calling a part's function is allowed; its presence used as a mode
# test (compared with nil, a condition of if / while / not / and / or) is L1. The part is a call `part(...)` (bare in
# coop_quests_core, `x.part(...)` elsewhere), a function of the file that returns one, or a local set to one
# (compared with nil).
LUA_PART = re.compile(r"(?<![\w])(?:((?:[A-Za-z_]\w*(?:\s*\(\s*\))?\s*[.:]\s*)*)|)\bpart\s*\(")
LUA_PART_DEFAULT = re.compile(r"\s*or\s+(?:nil|false|\{\s*\})(?![\w.:(\[])")
LUA_PART_TEST_AFTER = re.compile(r"\s*(?:then\b|do\b|and\b|or\b|==|~=)")
LUA_PART_TEST_BEFORE = re.compile(r"(?:\b(?:if|elseif|while|until|not)|==|~=)\s*$")

# ---- rule patterns ------------------------------------------------------------------------------------------------

CPP_MODE = re.compile(
    r"\bis_map_server\b|\bis_world_server\b|\bdedicated\s*::|\bg_coop_dedicated\b|\bg_coop_headless\b"
    r"|\bg_coop_(?:split_levels|world_server|story_together|soft_host_move|max_map_servers|map_servers_rev"
    r"|mapserver_\w+)\b"
    r"|\bsplit\s*\(\s*\)|\blevels\s*::\s*split\b|(?<![A-Za-z0-9])story_together\b|\bghost_actor\b|\bon_host_level\b"
    r"|\bhost_character_elsewhere\b|\bbody_facts\b|\bled_by_host_process\b|\bis_bridge\b|\bmapserver\s*::"
    r"|\bleads_my_level\b|\bworld_server_now\s*\(|\bgame_split\s*\("
    r"|\bhas_role\s*\(\s*ProcessRole\s*::\s*(?:WorldServer|MapAuthority|MapServer)\b"
    r"|\busing\s+namespace\s+(?:::)?(?:\w+\s*::\s*)*(?:dedicated|mapserver)\s*;"
    r"|\bnamespace\s+\w+\s*=\s*(?:::)?(?:\w+\s*::\s*)*(?:dedicated|mapserver)\s*;"
)
# a probe of the command line for a mode key (the keys are the launcher's contract, docs/MODES.md section 6)
MODE_KEY = re.compile(r"""["']-coop_(?:mapserver|dedicated|host|operator|hidden|stage)\b""")
# The server's Lua table srv.* (srv/coop_srv_script.cpp makes it in every Lua state, A-S4H): the server layer's own
# predicates. Any use of the global outside that layer is a mode check, whatever it reads (review A-REV-E-1, finding 1:
# srv.split(), srv.dedicated_new_world() and `local s = srv` got through): srv.x / srv["x"] / srv:x, the table as a value
# (`= srv`, `f(srv)`), _G.srv and _G["srv"] (read as _G.srv by lua_norm). Not the table: a field (t.srv), a constructor
# key or an assignment target (`{ srv = true }`, `srv = x`), a longer name (when_srv). A local named srv reads as the
# table too: a Core script does not name one so. rawget(_G, "srv") is in its strings: LUA_SRV_NAMED.
LUA_SRV_TABLE = r"(?<![\w.:])srv\b(?!\s*=(?!=))|\b_G\s*\.\s*srv\b"
LUA_SRV_NAMED = re.compile(r"""\brawget\s*\(\s*_G\s*,\s*(["'])srv\1""")
LUA_MODE = re.compile(
    r"\bis_map_server\b|\bis_dedicated\b|\blevels\s*\.\s*split\b|\bapi\s*\.\s*levels\b|\bactor_is_nobody\b"
    r"|\blevel_of_player\b|\bmap_servers\b|(?<![A-Za-z0-9])story_together\b|\bon_host_level\b|\bled_by_host_process\b"
    r"|\bhost_character_elsewhere\b|\bbody_facts\b|\bghost_actor\b|\bis_bridge\b|\bworld_server_now\b|\bgame_split\b"
    r"|\bdedicated_new_world\b|" + LUA_SRV_TABLE
)
LUA_SRV = re.compile(LUA_SRV_TABLE)
CPP_ROLE = re.compile(r"\bis_host\s*\(|\bis_client\s*\(|\bis_map_authority\s*\("
                      r"|\bhas_role\s*\(\s*ProcessRole\s*::\s*WorldClient\b")
LUA_ROLE = re.compile(r"\bis_world_server\s*\(|\bis_host\s*\(")
STOCK_HOOK = re.compile(r"\bcoop_console\s*::")
TOMBSTONE = re.compile(
    r"coop_soft_move|\bsoftmove\s*::|\bstory_together\b|coop_world_wait|coop_world_server\.h|\bHostProcess\b"
    r"|\bled_by_host_process\b"
)
TOMBSTONE_CODE = re.compile(r"(?<![A-Za-z0-9])story_together\b")  # g_coop_story_together in code (not the saved key)
STEAM = re.compile(r"Steam|RAYLINK_STEAM_|steam_invite|steam_join")
LUA_REGISTER = re.compile(
    r"\bRegisterScriptCallback\b|\bxr_(?:conditions|effects|logic)\s*(?:\.\s*\w+|\[[^\]]*\])\s*=(?!=)"
    r"|\brawset\s*\(\s*xr_(?:conditions|effects|logic)\b|\badd_event_handler\b"
)
REGISTER_NAMES = frozenset({"RegisterScriptCallback", "add_event_handler", "xr_conditions", "xr_effects", "xr_logic"})
LUA_PATCH = re.compile(r"(?<![\w.:])([A-Za-z_]\w*)\s*(?:\.\s*[A-Za-z_]\w*|\[[^\]]*\])+\s*=(?!=)")
LUA_PATCH_FN = re.compile(r"\bfunction\s+([A-Za-z_]\w*)\s*[.:]")
LUA_RAWSET = re.compile(r"\brawset\s*\(\s*([A-Za-z_]\w*)\s*,")
WHEN_SRV = re.compile(r"\bcoop_mode\s*\.\s*when_srv\s*\(")
LUA_MODULE_NAME = re.compile(r"\b(coop_\w+)\s*[.:]\s*[A-Za-z_]")
LUA_MODULE_CALL = re.compile(
    r"""\b(?:mod|module_of|call_module|rawget\s*\(\s*_G\s*,)\s*\(?\s*["'](coop_\w+)["']|\b_G\s*\[\s*["'](coop_\w+)["']""")
LUA_INDEX = re.compile(r"""\[\s*(["'])([A-Za-z_]\w*)\1\s*\]""")
LUA_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
# a script named in a C++ string: lua_getglobal(L, "coop_dedicated"), "coop_x.fn" (C++ -> Lua by name)
FILE_EXT = r"(?:ltx|xml|script|h|hpp|cpp|txt|json|log|ogg|dds|ini|lua|exe|dll)\b"
CPP_SCRIPT_STRING = re.compile(r'"(coop_\w+?)(?:[.:](?!' + FILE_EXT + r')[A-Za-z_]\w*)?"')
# a script function named by a config (`<precondition>coop_x.fn</precondition>`, `{=coop_x.fn}`)
CFG_SCRIPT = re.compile(r"\b(coop_\w+)\s*\.\s*(?!" + FILE_EXT + r")[A-Za-z_]\w*")
# `extern bool g_x;` (not extern "C" blocks: strings are emptied in code, so `extern ""`)
EXTERN = re.compile(r'\bextern\s+(?!"")[\w:<>\s\*&]+?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*;')
# a class or struct defined with a body (stock files read as bytes): the name of the trie is filled in
CLASS_DEF_BYTES = rb"\b(?:class|struct)\s+(?:[A-Z_][A-Z0-9_]*\s+)?(%s)\b\s*(?:final\s*)?(?::[^;{()]*)?\{"
# Lua: a call (`f(`, `a.b(`, `a:b(`); what runs at load in a srv script outside coop_mode.when_srv is L9
LUA_CALL = re.compile(r"([A-Za-z_][\w.:]*)\s*\(")
LUA_KEYWORDS = frozenset({"if", "elseif", "while", "until", "return", "and", "or", "not", "local", "then", "do", "in",
                          "for", "function", "end", "else"})
# pure lookups a srv script may make at load: they change nothing in the process
LUA_PURE = frozenset({"rawget", "rawequal", "rawlen", "type", "pairs", "ipairs", "next", "select", "tostring", "tonumber",
                      "unpack", "getmetatable", "class", "table.concat", "table.unpack", "table.getn",
                      "table.maxn", "coop_mode.when_srv", "printf", "print"})
# pcall / xpcall run their first argument: pure only when that is a pure function (`pcall(string.format, ...)`)
LUA_PROTECTED = frozenset({"pcall", "xpcall"})
# calls that change their first argument: allowed at load only on a table of the script's own (setmetatable also on a
# new table `{...}`); setmetatable(db.storage, {__mode = "v"}) makes a shared table weak in every process (review 3, C3)
LUA_OWN_ARG = frozenset({"table.insert", "table.remove", "table.sort", "setmetatable"})
LUA_SETMETA = re.compile(r"\bsetmetatable\s*\(\s*([A-Za-z_]\w*)")
# a script named by a plain string: a dispatch table of Ядро (`{ "coop_economy_group", "coop_srv_far_prices" }` read
# through rawget(_G, name)) reaches the script as surely as `coop_x.fn` (review 3, C6)
LUA_SCRIPT_STRING = re.compile(r"""["'](coop_\w+)["']""")
# a local that copies a table (`local db = db`, `local t = sim_board.x or {}`): the copy is that table, not the
# script's own (review 3, C1)
LUA_TABLE_COPY = re.compile(r"([A-Za-z_]\w*)(?:\s*\.\s*\w+|\[[^\]]*\])*(?:\s+or\s+\{\s*\})?")
LUA_PURE_PREFIX = ("string.", "math.", "bit.")
# calls that run a function given to them at once: a function literal given to one runs at load when the call does
# (`string.gsub(s, p, function() ... end)`, `pcall(function() ... end)`; review 4, X6)
LUA_RUNS_ARG = frozenset({"string.gsub", "table.sort", "pcall", "xpcall", "table.foreach", "table.foreachi"})
# Ядро builds a script's name at run time: no string names the script it reaches (review 4, X7)
LUA_COMPUTED_SCRIPT = re.compile(r"""(?:\brawget\s*\(\s*_G\s*,|\b_G\s*\[)\s*(["'])coop_[^"'\n]*\1\s*\.\.""")
# a one-line function-like macro that pastes tokens: `#define COOP_FAR_HOOK(name) bool coop_far_hook_##name(u16 id)`
# spells the name of what it defines (review 4, X10b)
PASTE_MACRO = re.compile(r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)\(([^()\n]*)\)[ \t]+([^\n\\]*##[^\n\\]*)$", re.M)
LUA_STRING_METHODS = frozenset({"format", "sub", "gsub", "find", "match", "gmatch", "len", "lower", "upper", "rep", "byte",
                                "char", "reverse", "split", "trim"})
INCLUDE = re.compile(r'^\s*#\s*include\s*[<"]([^">]+)[">]')
INCLUDE_MACRO = re.compile(r"^\s*#\s*include\s+[A-Za-z_]")
INCLUDE_BYTES = re.compile(rb'^[ \t]*#[ \t]*include[ \t]*[<"]([^">\r\n]+)[">]', re.M)
MACRO_DEF = re.compile(r"^[ \t]*#[ \t]*define[ \t]+([A-Za-z_]\w*)((?:[^\n]*\\\n)*[^\n]*)", re.M)
ALIAS_NS = re.compile(r"\bnamespace\s+([A-Za-z_]\w*)\s*=\s*(?:::)?((?:[A-Za-z_]\w*\s*::\s*)*[A-Za-z_]\w*)\s*;")
USING_NS = re.compile(r"\busing\s+namespace\s+(?:::)?((?:[A-Za-z_]\w*\s*::\s*)*[A-Za-z_]\w*)\s*;")
# plain substrings that every match of the regex above holds (the fast first pass of the scan)
LIT_CPP_MODE = ("is_map_server", "is_world_server", "dedicated", "g_coop_", "split", "story_together", "ghost_actor",
                "on_host_level", "host_character_elsewhere", "body_facts", "led_by_host_process", "is_bridge",
                "mapserver", "leads_my_level", "world_server_now", "has_role", "-coop_")
LIT_LUA_MODE = ("is_map_server", "is_dedicated", "split", "levels", "actor_is_nobody", "level_of_player", "map_servers",
                "story_together", "on_host_level", "led_by_host_process", "host_character_elsewhere", "body_facts",
                "ghost_actor", "is_bridge", "world_server_now", "-coop_", "dedicated_new_world", "srv")
LIT_CPP_ROLE = ("is_host", "is_client", "is_map_authority", "has_role")
LIT_LUA_ROLE = ("is_world_server", "is_host")
LIT_STOCK = ("coop", "has_role", "split", "story_together", "ghost_actor", "on_host_level", "host_character_elsewhere",
             "body_facts", "led_by_host_process", "is_bridge", "leads_my_level", "world_server_now")
LIT_TOMBSTONE = ("coop_soft_move", "softmove", "story_together", "coop_world_wait", "coop_world_server.h", "HostProcess",
                 "led_by_host_process")
LIT_STEAM = ("Steam", "RAYLINK_STEAM_", "steam_invite", "steam_join")
LIT_LUA_REGISTER = ("RegisterScriptCallback", "xr_conditions", "xr_effects", "xr_logic", "add_event_handler", "rawset",
                    "_G", "=", "setmetatable")
LIT_INCLUDE = ("include",)
QUICK = (b"coop", b"Steam", b"steam_", b"softmove", b"story_together", b"HostProcess", b"led_by_host_process",
         b"RAYLINK_STEAM_", b"has_role", b"ghost_actor", b"body_facts", b"on_host_level", b"is_bridge")
MODE_WORDS = frozenset({"level", "levels", "split", "host", "hosts", "here", "plays", "server", "servers", "elsewhere"})
MODE_COMMENT = re.compile(r"split|map[ _-]?server|world[ _-]?server|dedicated|hybrid", re.I)
IDENT = re.compile(r"[A-Za-z_]\w*")

WHY = {
    "L1": "Ядро never asks the mode; move the branch into hostplay/ or srv/ behind coop_mode (docs/MODES.md §3 rule 1)",
    "L2": "a role with two meanings (co-op host = world server); ask coop_mode about a player, a level or my actor (§3 rule 4)",
    "L3": "layers do not name each other; Ядро and stock reach srv only through mode() / coop_mode (§3 rule 7)",
    "L4": "a default that carries a mode or level fact; make every caller pass it (§3 rule 5, R1 of build 52)",
    "L5": "a stock hook into the server or a mode check; reach srv through mode() (§3 rule 8, critique H5)",
    "L6": "the hybrid is removed (docs/MODES.md §7); do not add to it",
    "L7": f"more than {LOCALS_LIMIT} file-level locals (LuaJIT allows 200); call coop_mode.x(...) without a new local",
    "L8": "Steam only in hostplay (docs/MODES.md §8)",
    "L9": "a srv script registers callbacks, conditions, effects and events, patches tables that are not its own and "
          "calls things at load only inside coop_mode.when_srv(...): every process loads every script (critique H4)",
    "L9C": "a static initializer runs in every process, the co-op host too; register from the mode's init through "
           "mode() (review 2, B3)",
    "L10": "a saved key disappeared from the scripts; saved names are never renamed or dropped (§3 rule 10)",
    "L11": "Ядро calls the server's part of Session (bridges, virtual host, operator token): only srv does, through "
           "srv::SessionSrv (docs/MODES.md §4; never an allow entry, SESSION_SRV_FROZEN only shrinks)",
    "L12": "the engine knows no mod (TZ P106): a mod's names, data and formulas live in its adapter "
           "gamedata/scripts/coop_mods_*.script; give the engine a generic mechanism the adapter registers with",
}
ALLOWABLE = frozenset({"L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L9C", "L12"})


def rule_order(rule: str) -> tuple[int, str]:
    m = re.match(r"L(\d+)(.*)", rule)
    return (int(m.group(1)), m.group(2)) if m else (99, rule)


class Finding(NamedTuple):
    rule: str
    path: str
    line: int
    code: str
    note: str = ""


Key = tuple[str, str, str]  # (rule, path, normalised code of the line)


# ---- inputs -------------------------------------------------------------------------------------------------------

class InputError(Exception):
    pass


def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**` any path (also empty), `*` any text without a slash, `?` one character."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append(r"(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(r".*")
            i += 2
        elif pattern[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(out) + r"\Z", re.I)


@dataclass
class LayerMap:
    rows: list[tuple[str, re.Pattern[str], str]] = field(default_factory=list)  # (layer, regex, glob)
    gate: list[tuple[str, re.Pattern[str], str]] = field(default_factory=list)
    stock_files: Optional[frozenset[str]] = None  # lower-case paths of the stock list
    stock_list: str = ""                          # its path, as layers.txt names it

    def layer_of(self, path: str) -> str:
        low = path.lower()
        layer = "core"
        for name, rx, _ in self.rows:
            if not rx.match(path):
                continue
            if name == "stock" and self.stock_files is not None and low not in self.stock_files:
                continue  # a file of ours under engine/src: not GSC's
            if name == "dying" and low not in DYING_FROZEN:
                continue  # the hybrid's list is frozen
            layer = name
        return layer

    def gate_row(self, path: str) -> Optional[str]:
        hit = None
        for name, rx, _ in self.gate:
            if rx.match(path):
                hit = name
        return hit


def parse_layers(text: str, root: Optional[pathlib.Path] = None) -> LayerMap:
    """The rows of layers.txt. `stock-list <file>` (relative to root) names the GSC file list that `stock` rows cover."""
    result = LayerMap()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] == "stock-list":
            rel = parts[1].strip()
            path = (root or ROOT) / rel
            if not path.is_file():
                raise InputError(f"missing input file {rel} (the stock-list of layers.txt line {number}): {path}")
            result.stock_files = frozenset(p.replace("\\", "/").lower() for p in parse_names(
                path.read_text(encoding="utf-8")))
            result.stock_list = rel
            continue
        if len(parts) != 2 or parts[0] not in LAYERS + GATE_ROWS:
            raise InputError(f"layers.txt line {number}: expected '<{'|'.join(LAYERS + GATE_ROWS + ('stock-list',))}> "
                             f"<glob>', got {raw!r}")
        target = result.gate if parts[0] in GATE_ROWS else result.rows
        target.append((parts[0], glob_regex(parts[1].strip()), parts[1].strip()))
    if any(name == "stock" for name, _, _ in result.rows) and result.stock_files is None:
        raise InputError("layers.txt has `stock` rows but no `stock-list <file>` row: without the list of GSC files "
                         "every new file of ours under engine/src would be stock")
    return result


def parse_allow(text: str) -> tuple[Optional[int], dict[Key, int]]:
    ceiling: Optional[int] = None
    allowed: dict[Key, int] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):
            m = re.match(r"#\s*ceiling:\s*(\d+)\s*$", line)
            if m and ceiling is None:
                ceiling = int(m.group(1))
            continue
        try:
            rule, rest = line.split("|", 1)
            path, rest = rest.split("|", 1)
            code, count = rest.rsplit("|", 1)
            key = (rule.strip(), path.strip(), code.strip())
            allowed[key] = allowed.get(key, 0) + int(count)
        except ValueError:
            raise InputError(f"layers_allow.txt line {number}: expected rule|path|code|count, got {raw!r}") from None
    return ceiling, allowed


def parse_names(text: str) -> list[str]:
    return [l.split("#", 1)[0].strip() for l in text.splitlines() if l.split("#", 1)[0].strip()]


def parse_keys(text: str) -> list[tuple[int, str, str]]:
    """(line, kind, key) of persisted_keys.txt rows `<kind> <key>`."""
    rows = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise InputError(f"persisted_keys.txt line {number}: expected '<kind> <key>', got {raw!r}")
        rows.append((number, parts[0], parts[1].strip()))
    return rows


MOD_WORD = re.compile(r"\w+")
MOD_BUILD_TAG = re.compile(r"[\w-]+")
MOD_DEBT_IDS = frozenset({"R1", "R2", "R3", "R4"})


class ModRow(NamedTuple):
    line: int
    kind: str
    token: str
    build_or_debt: str = ""
    scope: str = ""


def valid_mod_build(fields: list[str]) -> bool:
    # Split the stand path from the right so it may contain spaces.
    if len(fields) != 4 or not MOD_BUILD_TAG.fullmatch(fields[1]):
        return False
    tail = fields[3].rsplit(None, 2)
    if len(tail) != 3 or not all(re.fullmatch(r"[0-9]+", n) for n in tail[1:]):
        return False
    try:
        return date.fromisoformat(fields[2]).isoformat() == fields[2]
    except ValueError:
        return False


def parse_mod_names(text: str) -> list[ModRow]:
    rows = []
    seen: set[tuple[str, ...]] = set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        kind = fields[0]
        if (kind == "script" and len(fields) == 3
                and MOD_WORD.fullmatch(fields[1]) and MOD_BUILD_TAG.fullmatch(fields[2])):
            row = ModRow(number, kind, fields[1], fields[2])
        elif kind in ("name", "ignore") and len(fields) == 2 and MOD_WORD.fullmatch(fields[1]):
            row = ModRow(number, kind, fields[1])
        elif (kind == "debt" and len(fields) in (3, 4)
              and fields[1] in MOD_DEBT_IDS and MOD_WORD.fullmatch(fields[2])):
            scope = fields[3].replace("\\", "/") if len(fields) == 4 else ""
            row = ModRow(number, kind, fields[2], fields[1], scope)
        elif kind == "build" and valid_mod_build(line.split(None, 3)):
            row = ModRow(number, kind, fields[1])
        else:
            raise InputError(f"mod_names.txt line {number}: malformed row {raw!r}")
        key = tuple(row[1:] if kind == "debt" else row[1:3])
        if key in seen:
            raise InputError(f"mod_names.txt line {number}: duplicate row {raw!r}")
        seen.add(key)
        rows.append(row)
    return rows


# ---- source text --------------------------------------------------------------------------------------------------

def decode(data: bytes) -> str:
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("cp1251", "replace")  # GSC files: cp1251 comments
    return text.replace("\r\n", "\n").replace("\r", "\n")


def read_source(path: pathlib.Path) -> str:
    return decode(path.read_bytes())


CPP_TOKENS = re.compile(
    r'//(?:[^\n\\]|\\.)*'
    r'|/\*.*?(?:\*/|\Z)'
    r'|(?<![\w])R"([^(\s]{0,16})\((?:.|\n)*?\)\1"'
    r'|"(?:[^"\\\n]|\\.)*"?'
    r"|'(?:[^'\\\n]|\\.)*'?",
    re.S,
)
LUA_TOKENS = re.compile(
    r'--\[(=*)\[.*?(?:\]\1\]|\Z)'
    r'|--[^\n]*'
    r'|\[(=*)\[.*?(?:\]\2\]|\Z)'
    r'|"(?:[^"\\\n]|\\.)*"?'
    r"|'(?:[^'\\\n]|\\.)*'?",
    re.S,
)


def _blank(m: re.Match[str], keep_strings: bool, comment: bool) -> str:
    body = m.group(0)
    lines = "\n" * body.count("\n")
    if comment:
        return " " + lines
    if keep_strings:
        return body
    q = body[0] if body[0] in "\"'" else '"'
    return q + q + lines


def cpp_code(text: str, keep_strings: bool) -> str:
    """Comments removed (line breaks kept); string and char literal contents emptied unless keep_strings."""
    return CPP_TOKENS.sub(lambda m: _blank(m, keep_strings, m.group(0).startswith("/")), text)


def strip_both(text: str, tokens: re.Pattern[str], comment: str) -> tuple[str, str]:
    """(code, code with strings) in one pass: comments removed in both, string contents emptied in the first."""
    code: list[str] = []
    kept: list[str] = []
    pos = 0
    for m in tokens.finditer(text):
        between = text[pos:m.start()]
        code.append(between)
        kept.append(between)
        body = m.group(0)
        lines = "\n" * body.count("\n")
        if body.startswith(comment):
            code.append(" " + lines)
            kept.append(" " + lines)
        else:
            q = body[0] if body[0] in "\"'" else '"'
            code.append(q + q + lines)
            kept.append(body)
        pos = m.end()
    code.append(text[pos:])
    kept.append(text[pos:])
    return "".join(code), "".join(kept)


def lua_code(text: str, keep_strings: bool) -> str:
    """Comments removed (line breaks kept); string contents (also [[long]] strings) emptied unless keep_strings."""
    return LUA_TOKENS.sub(lambda m: _blank(m, keep_strings, m.group(0).startswith("--")), text)


def blank_preprocessor(code: str) -> str:
    """Preprocessor lines (and their continuations) blanked, line breaks kept: the scope walker ignores them."""
    lines = code.split("\n")
    out = []
    cont = False
    for line in lines:
        if cont or line.lstrip().startswith("#"):
            cont = line.rstrip().endswith("\\")
            out.append("")
        else:
            out.append(line)
    return "\n".join(out)


def line_starts(text: str) -> list[int]:
    starts = [0]
    pos = text.find("\n")
    while pos >= 0:
        starts.append(pos + 1)
        pos = text.find("\n", pos + 1)
    return starts


def norm(line: str) -> str:
    return " ".join(line.split())


def trie_regex(words: Iterable[str]) -> str:
    """One regex alternation of the words, factored as a trie (fast on long texts)."""
    trie: dict = {}
    for w in words:
        node = trie
        for ch in w:
            node = node.setdefault(ch, {})
        node[""] = {}

    def build(node: dict) -> str:
        end = "" in node
        alts = [re.escape(ch) + build(node[ch]) for ch in sorted(k for k in node if k)]
        if not alts:
            return ""
        body = alts[0] if len(alts) == 1 and not end else "(?:" + "|".join(alts) + ")"
        return body + ("?" if end else "")

    return build(trie)


# ---- C++ scopes: functions, parameters and members ----------------------------------------------------------------

@dataclass
class CppFunction:
    path: str
    name: str            # last identifier
    qualifier: str       # the innermost name before it: `A` of `A::b`, else the class, else the namespace ("" = none)
    local: bool          # anonymous namespace or `static` at namespace scope: visible only in its file
    line: int
    body: str            # the body without its braces
    body_line: int       # line of the opening brace
    returns_void: bool = False
    head_line: int = 0   # line of the (qualified) name in the head
    out_of_class: bool = False  # defined as `A::b` outside the body of class A


@dataclass
class CppDefault:
    line: int
    name: str
    comment: str
    type_text: str = ""  # the declared type before the name
    member: bool = False  # a class member's default (else a parameter's)
    value: str = ""       # the initializer text (`true` of `bool x = true;` and of `bool x{true};`)


@dataclass
class CppVar:
    """A variable defined at namespace scope (not `extern`, not a function)."""
    line: int
    name: str
    internal: bool        # `static`, or in an anonymous namespace: no other file can name it
    call: str = ""        # a function its initializer calls (it runs at static initialization, in every process)
    qualifier: str = ""   # `Q` of `u32 Q::x = 4;`: the definition of a static member of class Q (review 3, C8)
    type: str = ""        # the declared class of an object (`Registrar` of `static Registrar r;`); "" for a pointer


@dataclass
class CppFile:
    functions: list[CppFunction] = field(default_factory=list)
    defaults: list[CppDefault] = field(default_factory=list)
    namespaces: set[str] = field(default_factory=set)
    classes: set[str] = field(default_factory=set)        # classes, structs and unions defined (with a body) here
    variables: list[CppVar] = field(default_factory=list)  # namespace-scope variables


TEMPLATE_HEAD = re.compile(r"^\s*template\s*<")
LABEL = re.compile(r"^\s*(?:public|private|protected)\s*:(?!:)")
CONTROL = frozenset({"if", "for", "while", "switch", "catch", "return", "sizeof", "decltype", "alignof", "static_assert",
                     "defined", "noexcept", "throw", "new", "delete", "case"})


def strip_template(head: str) -> str:
    while True:
        m = TEMPLATE_HEAD.match(head)
        if not m:
            return head
        depth = 0
        i = m.end() - 1
        while i < len(head):
            if head[i] == "<":
                depth += 1
            elif head[i] == ">":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        head = head[i + 1:]


def top_groups(head: str) -> list[tuple[int, int]]:
    """(open, close) of every top-level parenthesis group."""
    groups = []
    depth = 0
    start = -1
    for i, c in enumerate(head):
        if c == "(":
            if depth == 0:
                start = i
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0 and start >= 0:
                groups.append((start, i))
            depth = max(depth, 0)
    return groups


def split_top(text: str, sep: str = ",") -> list[tuple[int, str]]:
    """(offset, part) of text split at top-level separators (outside (), <>, {}, [])."""
    parts = []
    depth = 0
    start = 0
    for i, c in enumerate(text):
        if c in "([{<":
            depth += 1
        elif c in ")]}>":
            depth = max(depth - 1, 0)
        elif c == sep and depth == 0:
            parts.append((start, text[start:i]))
            start = i + 1
    parts.append((start, text[start:]))
    return parts


def function_name(head: str) -> Optional[tuple[str, str, int, int]]:
    """(name, qualifier from `A::b`, offset of the parameter list, offset of the qualified name) of a function head."""
    for open_, _ in top_groups(head):
        before = head[:open_].rstrip()
        m = re.search(r"((?:[A-Za-z_]\w*\s*::\s*)*)(~?[A-Za-z_]\w*|operator\s*\S+)\s*$", before)
        if not m:
            return None
        name = m.group(2)
        if name in CONTROL:
            return None
        quals = [q for q in re.split(r"\s*::\s*", m.group(1).strip()) if q]
        return name, (quals[-1] if quals else ""), open_, m.start()
    return None


def type_before(text: str) -> str:
    """The declared type of `type name` (text without its last identifier)."""
    names = list(IDENT.finditer(text))
    return text[:names[-1].start()] if names else ""


def class_name(head: str) -> str:
    """The name of `class X`, `struct ENGINE_API X final : Base`, `struct alignas(8) X` (empty for an anonymous one)."""
    m = re.search(r"\b(?:class|struct|union)\b", head)
    if not m:
        return ""
    rest = re.split(r"(?<!:):(?!:)", head[m.end():], maxsplit=1)[0]
    rest = re.sub(r"\([^()]*\)", " ", rest)
    names = [n for n in IDENT.findall(rest) if n not in ("final", "alignas", "__declspec")]
    return names[-1] if names else ""


INIT_CALL = re.compile(r"\b([A-Za-z_]\w*)\s*\(")
NS_VAR = re.compile(r"^\s*([\w:<>,\s\*&]+?)\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*(=|\{|\Z)")
NOT_A_VAR = re.compile(r"^\s*(?:using|typedef|friend|enum|class|struct|union|namespace|static_assert|extern|return|"
                       r"template|public|private|protected)\b")


CPP_DECL_WORDS = frozenset({"static", "const", "inline", "constexpr", "constinit", "thread_local", "volatile", "extern",
                            "mutable", "unsigned", "signed", "struct", "class"})
VALUE_ARG = re.compile(r"""^\s*(?:-?\d[\w.']*|""|''|true|false|nullptr|[&!\-].*|[A-Za-z_][\w:]*\s*\((?!\s*[*&]).*)\s*$""", re.S)


def init_call(text: str) -> str:
    """The first function an initializer calls (sizeof, decltype and the like are not calls)."""
    for m in INIT_CALL.finditer(text):
        if m.group(1) not in CONTROL:
            return m.group(1)
    return ""


def object_args(head: str, open_: int) -> bool:
    """`T x(1)`, `T x(&f)`, `T x(make())`: the parenthesis after the name holds a value (a literal, an address, a call),
    so the statement defines an object; `T f(int a)` / `T f()` declare a function."""
    close = next((c for o, c in top_groups(head) if o == open_), None)
    if close is None:
        return False
    inner = head[open_ + 1:close]
    if not inner.strip() or not re.search(r"[A-Za-z_]\w*\s*$", head[:open_]):
        return False
    before = head[:open_].rstrip()
    if re.search(r"::\s*~?[A-Za-z_]\w*$", before) or not re.match(r"^\s*(?:[\w:<>,\s\*&]+?)\s+[A-Za-z_]\w*$", before):
        return False  # `X::f(...)`: an out-of-class member, or no declared type before the name
    return any(VALUE_ARG.match(part) for _, part in split_top(inner))


def parse_cpp(path: str, code: str) -> CppFile:
    """Walk the braces of code (comments and strings already removed, preprocessor lines blanked)."""
    result = CppFile()
    line_starts_ = [0]
    for i, c in enumerate(code):
        if c == "\n":
            line_starts_.append(i + 1)

    def line_of(offset: int) -> int:
        return bisect.bisect_right(line_starts_, offset)

    # stack entries: (kind, name, open offset, extra)
    stack: list[tuple[str, str, int, object]] = []
    seg = 0

    def scope_kind() -> str:
        return stack[-1][0] if stack else "ns"

    def enclosing_names() -> tuple[str, bool]:
        """(innermost class or namespace name, inside an anonymous namespace)."""
        anonymous = any(k == "ns" and n == "" for k, n, _, _ in stack)
        for kind, name, _, _ in reversed(stack):
            if kind in ("class", "ns") and name:
                return name, anonymous
        return "", anonymous

    def params(head: str, head_offset: int, open_: int) -> None:
        groups = top_groups(head)
        close = next((c for o, c in groups if o == open_), None)
        if close is None:
            return
        inner = head[open_ + 1:close]
        for off, part in split_top(inner):
            if "=" not in part:
                continue
            eq = part.index("=")
            if part[eq + 1:eq + 2] == "=" or part[eq - 1:eq] in "!<>":
                continue
            names = IDENT.findall(part[:eq])
            if names:
                result.defaults.append(CppDefault(line_of(head_offset + open_ + 1 + off + eq), names[-1], "",
                                                  type_before(part[:eq])))

    def variable(body: str, offset: int) -> None:
        """A definition at namespace scope: a variable, and the function its initializer calls (static init)."""
        if NOT_A_VAR.match(body):
            return
        m = NS_VAR.match(body)
        if not m or m.group(2) in CONTROL or not m.group(1).strip():
            return
        prefix = m.group(1)
        init = body[m.end(3) - (1 if m.group(3) == "{" else 0):] if m.group(3) else ""
        compile_time = bool(re.search(r"\b(?:constexpr|consteval|constinit)\b", prefix))
        call = "" if compile_time else init_call(init)
        anonymous = any(k == "ns" and n == "" for k, n, _, _ in stack)
        # internal linkage: `static`, an anonymous namespace, or a const object that is not `inline` / `extern`
        constant = bool(re.search(r"\bconstexpr\b", prefix) or re.search(r"\*\s*const\s*$", prefix)
                        or (re.search(r"\bconst\b", prefix) and "*" not in prefix and "&" not in prefix))
        internal = anonymous or bool(re.search(r"\bstatic\b", prefix)) or (constant and not re.search(r"\binline\b", prefix))
        # `u32 FarLimits::squads_per_player = 4;` defines a static member of FarLimits (C8)
        q = re.search(r"([A-Za-z_]\w*)\s*::\s*$", prefix)
        type_text = re.sub(r"(?:[A-Za-z_]\w*\s*::\s*)+$", "", prefix)
        # `coop::hooks::AutoReg<FarSkip>`: the class is AutoReg, not its template argument (review 4, X8b)
        bare_type = type_text
        while True:
            stripped = re.sub(r"<[^<>]*>", " ", bare_type)
            if stripped == bare_type:
                break
            bare_type = stripped
        names = [n for n in IDENT.findall(bare_type) if n not in CPP_DECL_WORDS]
        # the class of an object, when it is one: its constructor runs at static initialization (C7)
        obj_type = names[-1] if names and not compile_time and "*" not in bare_type and "&" not in bare_type else ""
        result.variables.append(CppVar(line_of(offset + m.start(2)), m.group(2), internal, call,
                                       q.group(1) if q else "", obj_type))

    def statement(stmt: str, offset: int) -> None:
        """A declaration at namespace or class scope ended by ';'."""
        body = LABEL.sub(lambda m: " " * len(m.group(0)), stmt)
        body = strip_template(body)
        fn = function_name(body)
        eq_top = [o for o, part in split_top(body, "=")][1:]
        if fn and not eq_top and scope_kind() == "ns" and object_args(body, fn[2]):
            # `static Registrar s_r(1);` at namespace scope: an object built with arguments, not a function declared
            # (the parenthesis holds values, not parameters; review 3, C7): read it as `static Registrar s_r{1};`
            close = next((c for o, c in top_groups(body) if o == fn[2]), None)
            if close is not None:
                variable(body[:fn[2]] + "{" + body[fn[2] + 1:close] + "}" + body[close + 1:],
                         offset + (len(stmt) - len(body)))
                return
        if fn and (not eq_top or fn[2] < eq_top[0] - 1):
            # a declaration: its parameter defaults
            params(body, offset + (len(stmt) - len(body)), fn[2])
            return
        if scope_kind() == "class":
            m = re.match(r"^\s*(?:[\w:<>,\s\*&\[\]]+?)\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)?(=|\{)", body)
            constant = re.match(r"^\s*(?:(?:inline|static|constexpr|const)\s+)*(?:static|constexpr)\b", body)
            if m and not constant and not re.match(r"^\s*(?:using|typedef|friend|enum|return)\b", body) \
                    and m.group(1) not in CONTROL:
                value = body[m.end(2):].strip()
                if m.group(2) == "{" and value.endswith("}"):
                    value = value[:-1].strip()
                result.defaults.append(CppDefault(line_of(offset + (len(stmt) - len(body)) + m.start(2)), m.group(1), "",
                                                  body[:m.start(1)], True, value))
        elif scope_kind() == "ns":
            variable(body, offset + (len(stmt) - len(body)))

    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        if c == "{":
            head_raw = code[seg:i]
            parent = scope_kind()
            kind, name, extra = "block", "", None
            if parent in ("ns", "class"):
                head = strip_template(LABEL.sub(lambda m: " " * len(m.group(0)), head_raw))
                if re.search(r"\bnamespace\b", head) and "(" not in head:
                    m = re.search(r"\bnamespace\s+([\w:]+)?\s*$", head)
                    full = (m.group(1) or "") if m else ""
                    for part in full.split("::"):
                        if part:
                            result.namespaces.add(part)
                    kind, name = "ns", full.split("::")[-1] if full else ""
                elif re.search(r'\bextern\s*""\s*$', head):
                    kind, name = "ns", "extern"
                elif re.search(r"\benum\b", head):
                    kind = "enum"
                elif re.search(r"\b(class|struct|union)\b", head) and not top_groups(head.split("=")[0]) or re.search(
                        r"\b(class|struct|union)\s+[A-Za-z_]\w*\s*(final\s*)?(:[^;(]*)?$", head):
                    kind, name = "class", class_name(head)
                    if name:
                        result.classes.add(name)
                else:
                    lam = re.search(r"\b([A-Za-z_]\w*)\s*=\s*\[[^\]]*\]", head)
                    fn = function_name(head)
                    head_off = seg + (len(head_raw) - len(head))
                    if lam and (not fn or head.find("=") < fn[2]):
                        kind, name, extra = "func", lam.group(1), ("", head_raw, False, line_of(head_off + lam.start(1)),
                                                                    False, True)
                    elif fn and "=" not in head[:fn[2]]:
                        void = bool(re.search(r"\bvoid\s*$", head[:fn[3]]))
                        kind, name, extra = "func", fn[0], (fn[1], head_raw, void, line_of(head_off + fn[3]),
                                                            bool(fn[1]) and parent == "ns", False)
                        params(head, head_off, fn[2])
                    elif "=" in head or re.match(r"^\s*[\w:<>,\s\*&]+\s+[A-Za-z_]\w*\s*$", head):
                        kind = "init"
            stack.append((kind, name, i, extra))
            if kind != "init":
                seg = i + 1
            i += 1
            continue
        if c == "}":
            if stack:
                kind, name, start, extra = stack.pop()
                if kind == "func":
                    qual, head_raw, void, head_line, out_of_class, lam = extra  # type: ignore[misc]
                    outer, anonymous = enclosing_names()
                    is_static = bool(re.search(r"\bstatic\b", head_raw)) and scope_kind() == "ns"
                    result.functions.append(CppFunction(
                        path, name, qual or outer, anonymous or is_static, line_of(start), code[start + 1:i], line_of(start),
                        void, head_line, out_of_class))
                    if lam and scope_kind() == "ns" and re.match(r"\s*\(", code[i + 1:i + 64]):
                        # `static const bool r = [] { ... }();`: a lambda called at static initialization
                        result.variables.append(CppVar(head_line, name, anonymous or is_static, "an immediately invoked lambda"))
                if kind == "init" and scope_kind() in ("ns", "class"):
                    i += 1
                    continue  # `x{1}` of a member or of an initializer list: the head goes on
            seg = i + 1
            i += 1
            continue
        if c == ";":
            if scope_kind() in ("ns", "class"):
                statement(code[seg:i], seg)
            seg = i + 1
        i += 1
    return result


def comment_of_line(raw: str) -> str:
    j = raw.find("//")
    return raw[j + 2:] if j >= 0 else ""


def words_of(name: str) -> set[str]:
    parts = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower().split("_")
    return {p for p in parts if p}


# ---- Lua functions ------------------------------------------------------------------------------------------------

@dataclass
class LuaFunction:
    path: str
    name: str        # last name (`fn` of `M.fn`; "" for an anonymous function)
    local: bool
    line: int
    body: str
    start: int = 0   # offsets of the body in the code (after the parameter list, up to its `end`)
    end: int = 0


LUA_TOKEN = re.compile(r"\b(function|if|for|while|do|repeat|end|until)\b")


def parse_lua(path: str, code: str, spans: Optional[list[LuaFunction]] = None) -> tuple[
        list[LuaFunction], list[tuple[str, int, str]]]:
    """Functions with their bodies, and `local NAME = <expression without a call>` aliases (name, line, expression).
    spans, when given, receives every function, anonymous ones too (what runs only when called)."""
    functions: list[LuaFunction] = []
    stack: list[tuple[str, str, bool, int]] = []  # (kind, name, local, body start)
    pending_do = 0
    for m in LUA_TOKEN.finditer(code):
        word = m.group(1)
        if word == "function":
            after = code[m.end():m.end() + 200]
            named = re.match(r"\s*([A-Za-z_][\w.:]*)\s*\(", after)
            before = code[max(0, m.start() - 200):m.start()]
            local = bool(re.search(r"\blocal\s+$", before))
            name = ""
            if named:
                name = re.split(r"[.:]", named.group(1))[-1]
            else:
                assign = re.search(r"(\blocal\s+)?([A-Za-z_][\w.]*)\s*=\s*$", before)
                if assign:
                    name = assign.group(2).split(".")[-1]
                    local = bool(assign.group(1))
            paren = code.find(")", m.end())
            stack.append(("func", name, local, paren + 1 if paren >= 0 else m.end()))
        elif word in ("if", "repeat"):
            stack.append((word, "", False, m.end()))
        elif word in ("for", "while"):
            stack.append(("loop", "", False, m.end()))
            pending_do += 1
        elif word == "do":
            if pending_do:
                pending_do -= 1
            else:
                stack.append(("do", "", False, m.end()))
        elif word in ("end", "until"):
            if stack:
                kind, name, local, start = stack.pop()
                if kind == "func":
                    fn = LuaFunction(path, name, local, code.count("\n", 0, start) + 1, code[start:m.start()], start,
                                     m.start())
                    if name:
                        functions.append(fn)
                    if spans is not None:
                        spans.append(fn)
    aliases = []
    for m in re.finditer(r"^[ \t]*local\s+([A-Za-z_]\w*)\s*=\s*([^\n]*)$", code, re.M):
        expr = m.group(2).strip()
        if expr and "(" not in expr and not expr.startswith("function"):
            aliases.append((m.group(1), code.count("\n", 0, m.start()) + 1, expr))
    return functions, aliases


def lua_norm(with_strings: str) -> str:
    """A Lua line with `t["name"]` read as `t.name` and every other string emptied."""
    return LUA_STRING.sub('""', LUA_INDEX.sub(lambda m: "." + m.group(2), with_strings))


# ---- the sources --------------------------------------------------------------------------------------------------

@dataclass
class Source:
    path: str          # posix, relative to the root
    layer: str
    lang: str          # "cpp" | "lua"
    raw: str
    code: str          # comments removed, strings emptied
    code_strings: str  # comments removed, strings kept
    cpp: Optional[CppFile] = None
    lua_functions: list[LuaFunction] = field(default_factory=list)
    lua_aliases: list[tuple[str, int, str]] = field(default_factory=list)
    includes: list[str] = field(default_factory=list)       # every #include "x" / <x> of the file (C++)
    data: bytes = b""                                       # a stock file not read as text yet
    aliases: dict[str, str] = field(default_factory=dict)   # C++ `namespace a = x::y;` -> a: "x::y"; Lua alias -> expr
    usings: set[str] = field(default_factory=set)           # C++ `using namespace x::y;` -> "y"
    lua_alias_spans: list[tuple[str, str, int, int]] = field(default_factory=list)  # Lua (name, expr, first, last line)
    lua_spans: list[LuaFunction] = field(default_factory=list)  # every Lua function body, anonymous ones too
    _lines: Optional[list[str]] = None
    _names: Optional[dict[str, list[int]]] = None

    def lines(self) -> list[str]:
        if self._lines is None:
            self._lines = self.code.split("\n")
        return self._lines

    def name_lines(self) -> dict[str, list[int]]:
        """identifier -> the code lines that name it."""
        if self._names is None:
            starts = line_starts(self.code)
            out: dict[str, list[int]] = defaultdict(list)
            for m in IDENT.finditer(self.code):
                out[m.group(0)].append(bisect.bisect_right(starts, m.start()))
            self._names = dict(out)
        return self._names

    def visible(self) -> set[str]:
        """Namespaces whose names a bare call here may reach: its own and the imported ones."""
        return (self.cpp.namespaces if self.cpp else set()) | self.usings

    def read(self) -> None:
        """Read a stock file held as bytes."""
        if self.data and not self.raw:
            self.raw = decode(self.data)
            self.code, self.code_strings = strip_both(self.raw, CPP_TOKENS, "/")
            self.data = b""


def collect(root: pathlib.Path, layers: LayerMap) -> list[Source]:
    sources: list[Source] = []
    engine = root / "engine" / "src"
    prefix = root.as_posix().rstrip("/") + "/"
    found: list[str] = []
    if engine.is_dir():
        for folder, dirs, files in os.walk(engine):
            dirs[:] = sorted(d for d in dirs if d != "3rd party")
            base = pathlib.Path(folder).as_posix()
            for name in files:
                if os.path.splitext(name)[1].lower() in CPP_SUFFIXES:
                    found.append(base + "/" + name)
    for full in sorted(found):
        rel = full[len(prefix):] if full.startswith(prefix) else pathlib.Path(full).relative_to(root).as_posix()
        layer = layers.layer_of(rel)
        with open(full, "rb") as f:
            data = f.read()
        includes = [m.group(1).decode("utf-8", "replace") for m in INCLUDE_BYTES.finditer(data)]
        if layer == "stock" and not any(q in data for q in QUICK):
            sources.append(Source(rel, layer, "cpp", "", "", "", includes=includes, data=data))
            continue
        raw = decode(data)
        sources.append(Source(rel, layer, "cpp", raw, *strip_both(raw, CPP_TOKENS, "/"), includes=includes))
    scripts = root / "gamedata" / "scripts"
    if scripts.is_dir():
        for path in sorted(scripts.glob("*.script")):
            rel = path.relative_to(root).as_posix()
            raw = read_source(path)
            sources.append(Source(rel, layers.layer_of(rel), "lua", raw, *strip_both(raw, LUA_TOKENS, "--")))
    # the stock scripts the mod patches (axr_main.script ...) and the GAMMA layer's scripts: stock Lua, scanned for
    # references to srv / hostplay scripts (L3) and mode names (L5); Ядро for tools/check_gates.py anyway
    for folder in STOCK_LUA_ROOTS:
        base = root / folder
        if base.is_dir():
            for path in sorted(base.glob("*.script")):
                rel = path.relative_to(root).as_posix()
                raw = read_source(path)
                sources.append(Source(rel, "stock", "lua", raw, *strip_both(raw, LUA_TOKENS, "--")))
    return sources


def stock_script_names(root: pathlib.Path) -> set[str]:
    """Module names of the stock scripts the mod patches (engine/gamedata/scripts, gamedata_gamma/scripts)."""
    names = set()
    for folder in STOCK_LUA_ROOTS:
        if (root / folder).is_dir():
            names |= {p.stem for p in (root / folder).glob("*.script")}
    return names


def is_gamedata_script(path: str) -> bool:
    return path.startswith("gamedata/scripts/")


@dataclass
class Taint:
    rule: str
    origin: str  # "path:line name"


def resolve_alias(q: str, aliases: dict[str, str]) -> str:
    target = aliases.get(q)
    return re.split(r"\s*::\s*", target)[-1] if target else q


def rewrite_cpp_aliases(line: str, aliases: dict[str, str]) -> str:
    """`lv::split()` with `namespace lv = coop::levels;` read as `coop::levels::split()`."""
    if not aliases:
        return line
    return re.sub(r"(?<![\w:.])(" + "|".join(map(re.escape, aliases)) + r")(\s*::)",
                  lambda m: aliases[m.group(1)] + m.group(2), line)


def macro_taints(sources: list[Source]) -> dict[str, Taint]:
    """Macros (of any file but stock) whose body names a mode predicate (L1) or a role (L2)."""
    out: dict[str, Taint] = {}
    for src in sources:
        if src.lang != "cpp" or not src.code or src.layer == "stock":
            continue
        for m in MACRO_DEF.finditer(src.code):
            body = m.group(2)
            hit = CPP_MODE.search(body)
            rule = "L1" if hit else None
            if rule is None:
                hit = CPP_ROLE.search(body)
                rule = "L2" if hit else None
            if rule and hit:
                line = src.code.count("\n", 0, m.start()) + 1
                out.setdefault(m.group(1), Taint(rule, f"macro {m.group(1)} at {src.path}:{line} names {hit.group(0).strip()}"))
    return out


def taint_cpp(sources: list[Source], macros: Optional[dict[str, Taint]] = None) -> tuple[
        dict[tuple[str, str], Taint], dict[tuple[str, str], Taint], dict[str, dict[str, Taint]]]:
    """Tainted C++ functions: (qualifier, name) -> taint, (namespace, name) -> taint for bare calls inside the same
    namespace, path -> {name: taint} for file-local ones. Iterated to a fixed point (a wrapper of a wrapper). A void
    function never taints (calling a command is not asking the mode); a function named like a predicate or a role is
    that predicate (its calls are found by name)."""
    qualified: dict[tuple[str, str], Taint] = {}
    by_ns: dict[tuple[str, str], Taint] = {}
    local: dict[str, dict[str, Taint]] = defaultdict(dict)
    macros = macros or {}
    macro_rx = re.compile(r"\b(" + "|".join(map(re.escape, macros)) + r")\b") if macros else None
    funcs = [(s, f) for s in sources if s.cpp for f in s.cpp.functions
             if not f.returns_void and not CPP_MODE.search(f.name + "()") and not CPP_ROLE.search(f.name + "(")]

    def lookup(src: Source, text: str) -> Optional[Taint]:
        """The taint of the first tainted call in text."""
        for m in re.finditer(r"(?:\b([A-Za-z_]\w*)\s*::\s*)?\b([A-Za-z_]\w*)\s*\(", text):
            q, nm = m.group(1), m.group(2)
            if q:
                q = resolve_alias(q, src.aliases)
                if (q, nm) in qualified:
                    return qualified[(q, nm)]
            if not q:
                prefix = text[max(0, m.start() - 2):m.start()]
                if prefix.endswith(".") or prefix.endswith("->") or prefix.endswith(":"):
                    continue
                if nm in local.get(src.path, {}):
                    return local[src.path][nm]
                for ns in src.visible():
                    if (ns, nm) in by_ns:
                        return by_ns[(ns, nm)]
        if macro_rx:
            m = macro_rx.search(text)
            if m:
                return macros[m.group(1)]
        return None

    changed = True
    rounds = 0
    while changed and rounds < 12:
        changed = False
        rounds += 1
        for src, fn in funcs:
            key = (fn.qualifier, fn.name)
            if fn.local and fn.name in local.get(src.path, {}):
                continue
            if not fn.local and key in qualified:
                continue
            rets = [m.group(1) for m in re.finditer(r"\breturn\b([^;]*);", fn.body)]
            short = fn.body.count(";") <= 2
            texts = rets + ([fn.body] if short else [])
            rule = None
            origin_text = ""
            for t in texts:
                if CPP_MODE.search(rewrite_cpp_aliases(t, src.aliases)):
                    rule, origin_text = "L1", CPP_MODE.search(rewrite_cpp_aliases(t, src.aliases)).group(0)
                    break
            if rule is None:
                for t in texts:
                    hit = lookup(src, t)
                    if hit and hit.rule == "L1":
                        rule, origin_text = "L1", hit.origin
                        break
            if rule is None:
                for t in texts:
                    if CPP_ROLE.search(t):
                        rule, origin_text = "L2", CPP_ROLE.search(t).group(0)
                        break
                    hit = lookup(src, t)
                    if hit:
                        rule, origin_text = hit.rule, hit.origin
                        break
            if rule is None:
                continue
            taint = Taint(rule, f"{fn.name} at {src.path}:{fn.line} returns {origin_text.strip()}")
            if fn.local:
                local[src.path][fn.name] = taint
            else:
                qualified[key] = taint
                if fn.qualifier:
                    by_ns[key] = taint
            changed = True
    return qualified, by_ns, local


def taint_lua(sources: list[Source]) -> tuple[dict[str, dict[str, Taint]], dict[tuple[str, str], Taint]]:
    """Tainted Lua names: path -> {name: taint} (file scope: locals, aliases, the file's own globals) and
    (module, name) -> taint for `module.name(` from other files."""
    in_file: dict[str, dict[str, Taint]] = defaultdict(dict)
    module: dict[tuple[str, str], Taint] = {}
    changed = True
    rounds = 0

    def lookup(src: Source, text: str) -> Optional[Taint]:
        for m in re.finditer(r"(?:\b(\w+)\s*[.:]\s*)?\b([A-Za-z_]\w*)\s*\(", text):
            mod_, nm = m.group(1), m.group(2)
            if mod_ and (mod_, nm) in module:
                return module[(mod_, nm)]
            if not mod_ and nm in in_file.get(src.path, {}):
                return in_file[src.path][nm]
        return None

    while changed and rounds < 12:
        changed = False
        rounds += 1
        for src in sources:
            if src.lang != "lua":
                continue
            mod_name = pathlib.PurePosixPath(src.path).stem
            for name, line, expr in src.lua_aliases:
                if name in in_file[src.path]:
                    continue
                rule = "L1" if LUA_MODE.search(expr) else (
                    "L2" if re.search(r"\bis_world_server\b|\bis_host\b", expr) else None)
                if rule is None and src.lines()[line - 1].startswith("local"):
                    # file level only (a function's own `local orig = cls.update` is another name):
                    # `local f = wrapper` (a tainted name of this file) or `local f = coop_x.wrapper` (of another)
                    bare_name = re.fullmatch(r"([A-Za-z_]\w*)", expr)
                    dotted = re.fullmatch(r"([A-Za-z_]\w*)\s*\.\s*([A-Za-z_]\w*)", expr)
                    if bare_name and bare_name.group(1) in in_file[src.path]:
                        rule = in_file[src.path][bare_name.group(1)].rule
                    elif dotted and (dotted.group(1), dotted.group(2)) in module:
                        rule = module[(dotted.group(1), dotted.group(2))].rule
                if rule:
                    in_file[src.path][name] = Taint(rule, f"{name} at {src.path}:{line} = {expr}")
                    changed = True
            for fn in src.lua_functions:
                if fn.name in in_file[src.path]:
                    continue
                rets = [m.group(1) for m in re.finditer(r"\breturn\b([^\n]*)", fn.body)]
                lines = [l for l in fn.body.split("\n") if l.strip()]
                texts = rets + ([fn.body] if len(lines) <= 3 else [])
                rule = None
                origin = ""
                for t in texts:
                    if LUA_MODE.search(t):
                        rule, origin = "L1", LUA_MODE.search(t).group(0)
                        break
                if rule is None:
                    for t in texts:
                        hit = lookup(src, t)
                        if hit and hit.rule == "L1":
                            rule, origin = "L1", hit.origin
                            break
                if rule is None:
                    for t in texts:
                        if LUA_ROLE.search(t):
                            rule, origin = "L2", LUA_ROLE.search(t).group(0)
                            break
                        hit = lookup(src, t)
                        if hit:
                            rule, origin = hit.rule, hit.origin
                            break
                if rule is None:
                    continue
                taint = Taint(rule, f"{fn.name} at {src.path}:{fn.line} returns {origin.strip()}")
                in_file[src.path][fn.name] = taint
                if not fn.local:
                    module[(mod_name, fn.name)] = taint
                changed = True
    return in_file, module


def resolve_include(includer: str, inc: str, index: dict[str, list[str]]) -> Optional[str]:
    inc = inc.replace("\\", "/")
    parts = [p for p in inc.split("/") if p not in ("", ".")]
    while ".." in parts:
        k = parts.index("..")
        parts = parts[k + 1:]
    if not parts:
        return None
    tail = "/".join(parts)
    candidates = [p for p in index.get(parts[-1].lower(), []) if p.lower().endswith("/" + tail.lower())]
    if not candidates:
        return None
    here = includer.rsplit("/", 1)[0]
    candidates.sort(key=lambda p: (not p.startswith(here + "/"), p))
    return candidates[0]


def crosses(src_layer: str, dst_layer: str) -> bool:
    if src_layer in ("core", "stock"):
        return dst_layer in ("srv", "hostplay")
    if src_layer == "srv":
        return dst_layer == "hostplay"
    if src_layer == "hostplay":
        return dst_layer == "srv"
    return False


USE_KEYWORDS = frozenset({"return", "else", "case", "throw", "co_return", "not", "and", "or", "new", "delete", "then",
                          "do", "in", "until", "elseif", "if", "while"})


def is_definition(before: str) -> bool:
    """The text before a name( is that of its own definition or declaration (`bool ghost(`, `static bool ns::ghost(`,
    `local function ghost(`, `function M.ghost(`), not of a call."""
    if re.search(r"\bfunction\s+$", before):
        return True
    stripped = before.rstrip()
    if not stripped:
        return False
    if re.search(r"(&&|\|\||[=(,!?:{\[+\-|<%/^~;.])\s*$", stripped) and not stripped.endswith("::"):
        return False
    last = re.search(r"([A-Za-z_]\w*|[*&>])\s*$", stripped)
    return bool(last) and last.group(1) not in USE_KEYWORDS


def declares(before: str) -> bool:
    """is_definition, except that `= &f` / `(&f` takes the address of f (a use)."""
    return is_definition(before) and not re.search(r"(?:[=(,?:{]|return)\s*&\s*$", before)


def chain_start(line: str, pos: int) -> int:
    """The start of the qualified name `a::b::c` that has a part at pos."""
    while True:
        m = re.search(r"(?:::\s*)?([A-Za-z_]\w*)\s*::\s*$", line[:pos])
        if not m or m.end() != pos:
            m2 = re.search(r"::\s*$", line[:pos])
            if m2:
                pos = m2.start()
                continue
            return pos
        pos = m.start(1)


CALL_ANY = re.compile(r"\b([A-Za-z_]\w*)\s*\(")
CALL_TOKEN = re.compile(r"(?:\b([A-Za-z_]\w*)\s*(::|\.|:|->)\s*)?\b([A-Za-z_]\w*)\s*\(")
QUAL_REF = re.compile(r"(?=\b([A-Za-z_]\w*)\s*::\s*(~?[A-Za-z_]\w*)\b)")


def tainted_call(line: str, qual: dict[tuple[str, str], Taint], bare: dict[str, Taint], rule: str,
                 qual_seps: tuple[str, ...], aliases: Optional[dict[str, str]] = None) -> Optional[Taint]:
    """The taint of the first call in line of a tainted name with this rule: `q<sep>name(` by qual (sep one of
    qual_seps; q through the namespace aliases), a bare `name(` (not after `.`, `->` or `:`) by bare. Definitions and
    declarations are not calls."""
    for m in CALL_TOKEN.finditer(line):
        q, sep, name = m.group(1), m.group(2), m.group(3)
        if q is not None:
            if aliases and sep == "::":
                q = resolve_alias(q, aliases)
            t = qual.get((q, name)) if sep in qual_seps else None
        else:
            before = line[:m.start()].rstrip()
            if before.endswith((".", "->", ":")) and not before.endswith("::"):
                continue
            t = bare.get(name)
        if t is None or t.rule != rule:
            continue
        if is_definition(line[:m.start()]):
            continue
        return t
    return None


def count_locals(code: str) -> list[int]:
    """Lines of the file-level locals (column 0 `local`), one entry per name."""
    lines = []
    for number, line in enumerate(code.split("\n"), 1):
        if re.match(r"^local\s+function\s+[A-Za-z_]\w*", line):
            lines.append(number)
            continue
        m = re.match(r"^local\s+([A-Za-z_][\w\s,]*?)(=|$)", line)
        if m:
            lines += [number] * len([x for x in m.group(1).split(",") if x.strip()])
    return lines


# ---- the model: sources, taints, the index of server functions ----------------------------------------------------

@dataclass
class Defs:
    """Functions defined (not only declared) in non-stock C++ files, by (qualifier, name)."""
    srv: dict[tuple[str, str], list[str]] = field(default_factory=dict)   # defined in a srv / hostplay file
    other: set[tuple[str, str]] = field(default_factory=set)              # defined in an Ядро or dying file
    names: frozenset[str] = frozenset()   # srv names a bare call can reach (free functions: qualifier "" or a namespace)
    quals: frozenset[str] = frozenset()   # classes of srv member functions (reached only as `Class::f`)
    outside: frozenset[str] = frozenset()  # what code outside our namespaces names to reach one: globals and qualifiers


def build_defs(sources: list[Source]) -> Defs:
    srv: dict[tuple[str, str], list[str]] = defaultdict(list)
    other: set[tuple[str, str]] = set()
    namespaces: set[str] = set()
    for src in sources:
        if src.cpp:
            namespaces |= src.cpp.namespaces | src.usings
    for src in sources:
        if not src.cpp:
            continue
        for fn in src.cpp.functions:
            if fn.local or fn.name.startswith("~") or fn.name.startswith("operator"):
                continue
            key = (fn.qualifier, fn.name)
            if src.layer in ("srv", "hostplay"):
                if src.path not in srv[key]:
                    srv[key].append(src.path)
            else:
                other.add(key)
    free = [(q, nm) for q, nm in srv if not q or q in namespaces]
    return Defs(dict(srv), other, frozenset(nm for _, nm in free),
                frozenset(q for q, nm in srv if q and q not in namespaces),
                frozenset({nm for q, nm in srv if not q} | {q for q, _ in srv if q}))


def srv_refs(src: Source, line: str, defs: Defs, exclusive: bool) -> list[tuple[tuple[str, str], list[str]]]:
    """Server or co-op functions this line refers to: `q::name` (a call or a pointer; q through the namespace aliases)
    and bare `name(` calls where the name is one of the file's namespaces or imported ones. exclusive: only functions no
    Ядро file defines too (an overload or a homonym of Ядро is not counted)."""
    out = []
    for m in QUAL_REF.finditer(line):
        q, nm = resolve_alias(m.group(1), src.aliases), m.group(2)
        key = (q, nm)
        if key in defs.srv and not (exclusive and key in defs.other):
            if declares(line[:chain_start(line, m.start())]):
                continue  # `bool coop::levels::x(` declares or defines it here
            out.append((key, defs.srv[key]))
    visible = src.visible() | {""}
    for m in CALL_TOKEN.finditer(line):
        if m.group(1) is not None:
            continue
        nm = m.group(3)
        if nm not in defs.names:
            continue
        before = line[:m.start()].rstrip()
        if before.endswith((".", "->", ":")):
            continue
        if is_definition(line[:m.start()]):
            continue
        if exclusive and any((ns, nm) in defs.other for ns in visible):
            continue  # an Ядро function of the same name is nearer (not exclusive: an overload may be the srv one, C9)
        for ns in sorted(visible):
            key = (ns, nm)
            if key in defs.srv and not (exclusive and key in defs.other):
                out.append((key, defs.srv[key]))
                break
    return out


@dataclass
class Model:
    root: pathlib.Path
    layers: LayerMap
    sources: list[Source]
    by_path: dict[str, Source]
    qualified: dict[tuple[str, str], Taint]
    by_ns: dict[tuple[str, str], Taint]
    local: dict[str, dict[str, Taint]]
    macros: dict[str, Taint]
    lua_in_file: dict[str, dict[str, Taint]]
    lua_module: dict[tuple[str, str], Taint]
    defs: Defs
    include_index: dict[str, list[str]]
    script_layer: dict[str, str]
    stock_scripts: set[str]
    entry: Optional[re.Pattern[str]]
    entry_bare: dict[str, list[str]]  # qualifier -> names of srv_entry `q::name` (bare calls after `using namespace q`)
    entry_lits: tuple[str, ...]
    core_classes: dict[str, str] = field(default_factory=dict)       # class only Ядро / stock / dying define -> a file
    srv_globals: dict[str, list[str]] = field(default_factory=dict)  # namespace-scope variable of srv/hostplay -> files
    core_globals: frozenset[str] = frozenset()                       # namespace-scope variables Ядро / dying define


def lua_aliases_of(src: Source, script_names: set[str]) -> tuple[dict[str, str], list[tuple[str, str, int, int]]]:
    """Lua `local X = a.b(.c)` (a table path), `local X = coop_x` (a script) and `local X = RegisterScriptCallback` /
    `xr_conditions` ...: X -> the expression, and (X, expression, first line, last line) of where the local lives: to the
    end of the innermost function that holds it (the end of the file for a file-level one)."""
    out: dict[str, str] = {}
    spans: list[tuple[str, str, int, int]] = []
    last_line = src.code.count("\n") + 1
    bodies = [(fn.line, fn.line + fn.body.count("\n")) for fn in src.lua_functions]
    for name, line, expr in src.lua_aliases:
        if re.fullmatch(r"[A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)+", expr):
            expr = re.sub(r"\s+", "", expr)
        elif not (re.fullmatch(r"[A-Za-z_]\w*", expr) and (expr in script_names or expr in REGISTER_NAMES)):
            continue
        out[name] = expr
        inside = [(b - a, b) for a, b in bodies if a <= line <= b]
        spans.append((name, expr, line, min(inside)[1] if inside else last_line))
    return out, spans


def aliases_at(src: Source, line: int) -> dict[str, str]:
    """The Lua aliases in scope at a line (a later one of the same name wins)."""
    return {name: expr for name, expr, first, last in src.lua_alias_spans if first <= line <= last}


def rewrite_lua(line: str, aliases: dict[str, str]) -> str:
    """The aliases of the file read as what they stand for (not where they are assigned)."""
    if not aliases:
        return line
    return re.sub(r"(?<![\w.:])(" + "|".join(map(re.escape, aliases)) + r")\b(?!\s*=[^=])",
                  lambda m: aliases[m.group(1)], line)


def paste_macros(sources: Iterable[Source]) -> dict[str, tuple[list[str], str]]:
    """name -> (parameters, body) of the one-line token-pasting function-like macros of our C++ files."""
    out: dict[str, tuple[list[str], str]] = {}
    for src in sources:
        if src.lang == "cpp" and src.code and src.layer != "stock" and "##" in src.code:
            for m in PASTE_MACRO.finditer(src.code):
                out.setdefault(m.group(1), ([p.strip() for p in m.group(2).split(",")], m.group(3).strip()))
    return out


def expand_paste(code: str, macros: dict[str, tuple[list[str], str]]) -> str:
    """code with every use of a paste macro expanded on its own line (lines are kept): `COOP_FAR_HOOK(skip) {` reads as
    `bool coop_far_hook_skip(u16 id) {`, so the function it defines is indexed (review 4, X10b)."""
    rx = re.compile(r"\b(" + "|".join(map(re.escape, macros)) + r")\s*\(([^()\n]*)\)")

    def one(m: re.Match[str]) -> str:
        params, body = macros[m.group(1)]
        args = [a.strip() for a in m.group(2).split(",")]
        if len(args) != len(params):
            return m.group(0)
        for p, a in zip(params, args):
            if p:
                body = re.sub(rf"\b{re.escape(p)}\b", lambda _m, a=a: a, body)
        return re.sub(r"\s*##\s*", "", body)

    lines = code.split("\n")
    for i, line in enumerate(lines):
        if not re.match(r"[ \t]*#", line) and rx.search(line):
            lines[i] = rx.sub(one, line)
    return "\n".join(lines)


def build(root: pathlib.Path, layers: LayerMap, srv_entry: Sequence[str]) -> Model:
    sources = collect(root, layers)
    pastes = paste_macros(sources)
    for src in sources:
        if src.lang == "cpp" and src.code and src.layer != "stock":
            code = expand_paste(src.code, pastes) if pastes and src.layer in ("srv", "hostplay") else src.code
            src.cpp = parse_cpp(src.path, blank_preprocessor(code))
            src.aliases = {a: re.sub(r"\s+", "", t) for a, t in ALIAS_NS.findall(src.code)}
            src.usings = {re.split(r"\s*::\s*", u)[-1] for u in USING_NS.findall(src.code)}
        elif src.lang == "lua":
            src.lua_functions, src.lua_aliases = parse_lua(src.path, src.code, src.lua_spans)
    # a script's layer by its module name: gamedata/scripts first (the stock roots only add the names they alone have)
    script_layer: dict[str, str] = {}
    for s in sources:
        if s.lang == "lua" and is_gamedata_script(s.path):
            script_layer[pathlib.PurePosixPath(s.path).stem] = s.layer
    for s in sources:
        if s.lang == "lua" and not is_gamedata_script(s.path):
            script_layer.setdefault(pathlib.PurePosixPath(s.path).stem, s.layer)
    stock_scripts = stock_script_names(root)
    for src in sources:
        if src.lang == "lua":
            src.aliases, src.lua_alias_spans = lua_aliases_of(src, set(script_layer) | stock_scripts)
    defs = build_defs(sources)
    macros = macro_taints(sources)
    qualified, by_ns, local = taint_cpp(sources, macros)
    lua_in_file, lua_module = taint_lua([s for s in sources if s.layer != "stock"])

    # an object of a class with a user-declared constructor, defined at namespace scope, is built at static
    # initialization: its constructor runs in every process, the co-op host too (`static Registrar s_r;`, review 3, C7)
    ctor_classes = {f.qualifier for s in sources if s.cpp for f in s.cpp.functions if f.qualifier and f.name == f.qualifier}
    for src in sources:
        if src.cpp:
            for var in src.cpp.variables:
                if not var.call and var.type and var.type in ctor_classes:
                    var.call = f"the constructor {var.type}()"

    # namespace-scope variables: those a srv / hostplay file defines (Ядро must not read them through extern, B4)
    srv_globals: dict[str, list[str]] = defaultdict(list)
    core_globals: set[str] = set()
    srv_classes: set[str] = set()
    class_files: dict[str, str] = {}
    for src in sources:
        if not src.cpp:
            continue
        mode_layer = src.layer in ("srv", "hostplay")
        for var in src.cpp.variables:
            if not var.internal:
                if mode_layer:
                    if src.path not in srv_globals[var.name]:
                        srv_globals[var.name].append(src.path)
                else:
                    core_globals.add(var.name)
        if mode_layer:
            srv_classes |= src.cpp.classes
        else:
            for name in sorted(src.cpp.classes):
                class_files.setdefault(name, src.path)

    entry_rx = []
    entry_bare: dict[str, list[str]] = defaultdict(list)
    for name in srv_entry:
        if "::" in name:
            q, nm = name.rsplit("::", 1)
            entry_rx.append(rf"\b{re.escape(q)}\s*::\s*{re.escape(nm)}\b")
            entry_bare[q.rsplit("::", 1)[-1]].append(nm)
        else:
            entry_rx.append(rf"\b{re.escape(name)}\b")
    entry = re.compile("|".join(entry_rx)) if entry_rx else None
    entry_lits = tuple(name.rsplit("::", 1)[-1] for name in srv_entry)

    # stock files held as bytes: read those that name a server function or a server entry point
    # (a stock file sits outside our namespaces: it reaches a server function as `ns::f`, `Class::f` or a global `f`)
    names = sorted(defs.outside | {name.rsplit("::", 1)[0].rsplit("::", 1)[-1] if "::" in name else name
                                   for name in srv_entry}
                   | {q for (q, _), t in qualified.items() if t.rule == "L1" and q}
                   | (set(srv_globals) - core_globals))
    if names:
        rx = re.compile((r"\b" + trie_regex(names) + r"\b").encode())
        for src in sources:
            if src.data and rx.search(src.data):
                src.read()

    # classes that only Ядро, stock or dying files define, among those whose members srv / hostplay files define:
    # such a member is server code inside an Ядро object (`far_policy().keep_online(id)`, review 2, B2)
    core_classes: dict[str, str] = {}
    candidates = ({f.qualifier for s in sources if s.cpp and s.layer in ("srv", "hostplay")
                   for f in s.cpp.functions if f.out_of_class and f.qualifier}
                  # and static data members defined in a srv / hostplay file (`u32 FarLimits::n = 4;`, review 3, C8)
                  | {v.qualifier for s in sources if s.cpp and s.layer in ("srv", "hostplay")
                     for v in s.cpp.variables if v.qualifier}) - srv_classes
    for name in sorted(candidates & set(class_files)):
        core_classes[name] = class_files[name]
    rest = sorted(candidates - set(core_classes))
    if rest:
        class_rx = re.compile(CLASS_DEF_BYTES % trie_regex(rest).encode())
        word_rx = re.compile((r"\b" + trie_regex(rest) + r"\b").encode())
        for src in sources:
            if src.lang != "cpp" or src.layer != "stock":
                continue
            blob = src.data or src.code.encode("utf-8", "replace")
            if not word_rx.search(blob):
                continue
            for m in class_rx.finditer(blob):
                core_classes.setdefault(m.group(1).decode(), src.path)

    index: dict[str, list[str]] = defaultdict(list)
    for src in sources:
        if src.lang == "cpp":
            index[src.path.rsplit("/", 1)[-1].lower()].append(src.path)
    return Model(root, layers, sources, {s.path: s for s in sources}, qualified, by_ns, local, macros, lua_in_file,
                 lua_module, defs, index, script_layer, stock_scripts, entry, dict(entry_bare), entry_lits,
                 core_classes, dict(srv_globals), frozenset(core_globals))


# ---- srv scripts: what runs at load -------------------------------------------------------------------------------

def lua_own_names(code: str, mod_name: str, code_strings: str = "",
                  aliases: Sequence[tuple[str, int, str]] = ()) -> set[str]:
    """Tables a script may assign into outside when_srv: its locals (any scope), parameters, for variables, `self`, the
    script itself, its classes (`class "x"`) and its file-level globals (a script's globals live in its own module
    table). A local that copies a table which is not its own (`local db = db`, `local t = sim_board.x or {}`: aliases,
    the `local NAME = <expression without a call>` of parse_lua) is that table, not its own (review 3, C1)."""
    own = {"self", mod_name}
    own |= set(re.findall(r"""\bclass\s*["']([A-Za-z_]\w*)["']""", code_strings))
    own |= set(re.findall(r"\blocal\s+function\s+([A-Za-z_]\w*)", code))
    for names in re.findall(r"\blocal\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)", code):
        own |= {n.strip() for n in names.split(",")}
    for params in re.findall(r"\bfunction\b[^(\n]*\(([^)]*)\)", code):
        own |= {p.strip() for p in params.split(",") if re.fullmatch(r"\s*[A-Za-z_]\w*\s*", p)}
    for names in re.findall(r"\bfor\s+([A-Za-z_][\w\s,]*?)\s+in\b", code) + re.findall(r"\bfor\s+([A-Za-z_]\w*)\s*=", code):
        own |= {n.strip() for n in names.split(",")}
    own |= set(re.findall(r"^([A-Za-z_]\w*)\s*=(?!=)", code, re.M))
    for name, _, expr in aliases:
        m = LUA_TABLE_COPY.fullmatch(expr.strip())
        if m and m.group(1) not in ("nil", "true", "false") and (m.group(1) == name or m.group(1) not in own):
            own.discard(name)
    # `local cfg = rawget(_G, "coop_far_cfg")` (`or {}` too) is that table, not one of its own (review 4, X3)
    for name in re.findall(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*rawget\s*\(", code):
        own.discard(name)
    # a file-level global that copies another table (`far_cfg = coop_far_cfg`, `far_db = db`, `x = rawget(...)`) is
    # that table (review 4, X4); `x = x or {}` and a copy of a table of its own stay its own
    file_level = re.findall(r"^([A-Za-z_]\w*)\s*=(?!=)[ \t]*([^\n]*)$", code, re.M)
    changed = True
    while changed:
        changed = False
        for name, expr in file_level:
            if name not in own:
                continue
            expr = expr.strip()
            m = LUA_TABLE_COPY.fullmatch(expr)
            if re.match(r"rawget\s*\(", expr) or (m and m.group(1) not in ("nil", "true", "false")
                                                  and m.group(1) != name and m.group(1) not in own):
                own.discard(name)
                changed = True
    return own


def lua_load_functions(src: Source, calls: list[tuple[int, str, Optional[LuaFunction]]]) -> set[int]:
    """ids of the named functions of a script that run at load: on_game_start, a function assigned to it at file level
    (`on_game_start = start`) and, to a fixed point, every function of the file called by its bare name from code that
    runs at load (file level, a function that runs at load, a when_srv(...) argument outside an anonymous function;
    review 3, C2 and C4)."""
    by_name: dict[str, list[LuaFunction]] = defaultdict(list)
    for fn in src.lua_functions:
        by_name[fn.name].append(fn)
    load = {id(fn) for fn in by_name.get("on_game_start", ()) if not fn.local}
    for name in re.findall(r"(?m)^[ \t]*on_game_start\s*=\s*([A-Za-z_]\w*)\s*$", src.code):
        load |= {id(fn) for fn in by_name.get(name, ())}
    literals = lua_literals_run_now(src)
    changed = True
    while changed:
        changed = False
        for fid, around in literals:
            if fid not in load and (around is None or id(around) in load):
                load.add(fid)  # a function literal called at once, or given to string.gsub / pcall ... (X5, X6)
                changed = True
        for pos, name, inner in calls:
            if inner is not None and id(inner) not in load:
                continue
            for fn in by_name.get(name, ()) if re.fullmatch(r"[A-Za-z_]\w*", name) else ():
                if id(fn) not in load:
                    load.add(id(fn))
                    changed = True
    return load


def open_paren_before(code: str, pos: int, limit: int = 4000) -> Optional[int]:
    """The `(` whose argument list holds pos directly (not inside a table constructor `{...}`), or None."""
    parens = braces = 0
    i = pos - 1
    stop = max(0, pos - limit)
    while i >= stop:
        c = code[i]
        if c == ")":
            parens += 1
        elif c == "(":
            if parens == 0:
                return i if braces == 0 else None
            parens -= 1
        elif c == "}":
            braces += 1
        elif c == "{":
            if braces == 0:
                return None
            braces -= 1
        i -= 1
    return None


def lua_literals_run_now(src: Source) -> list[tuple[int, Optional[LuaFunction]]]:
    """(id, the function around it or None at file level) of every function literal that runs as soon as the code
    around it runs: called at once, `(function() ... end)()` (review 4, X5), or given straight to a call that runs its
    argument now: string.gsub, s:gsub, table.sort, pcall, xpcall, table.foreach and locals that stand for them (X6). A
    literal given to any other call (CreateTimeEvent, RegisterScriptCallback, coop_mode.when_srv) runs later; that call
    itself is what counts."""
    code = src.code
    runners = set(LUA_RUNS_ARG)
    for name, expr in re.findall(r"(?m)^[ \t]*local\s+([A-Za-z_]\w*)\s*=\s*([\w.]+)\s*$", code):
        if expr in LUA_RUNS_ARG:
            runners.add(name)
    spans = sorted(src.lua_spans, key=lambda f: (f.start, -f.end))
    out: list[tuple[int, Optional[LuaFunction]]] = []
    for f in spans:
        if f.name:
            continue
        kw = code.rfind("function", 0, f.start)
        if kw < 0:
            continue
        now = bool(re.match(r"\s*\)\s*\(", code[f.end + 3:f.end + 64])) and code[:kw].rstrip().endswith("(")
        if not now:
            j = open_paren_before(code, kw)
            if j is not None and (not code[j + 1:kw].strip() or code[j + 1:kw].rstrip().endswith(",")):
                callee = re.search(r"([A-Za-z_][\w.:]*)\s*$", code[:j])
                if callee:
                    c = callee.group(1)
                    now = c in runners or (re.split(r"[.:]", c)[-1] == "gsub" and ":" in c)
        if not now:
            continue
        around = None
        for g in spans:
            if g is not f and g.start <= kw < g.end and (around is None or g.start >= around.start):
                around = g
        out.append((id(f), around))
    return out


def lua_param_writes(src: Source, own: set[str], load: set[int],
                     when_spans: list[tuple[int, int]]) -> list[tuple[int, str]]:
    """A load-time function of the file that writes into its parameter when a call at load gives it a table that is not
    the script's own: `wrap(sim_board.simulation_board, "assign_squad_to_smart", f)` with `tbl[key] = ...` in wrap
    (review 4, X2). (line, why)."""
    code = src.code
    starts = line_starts(code)
    spans = sorted(src.lua_spans, key=lambda f: (f.start, -f.end))

    def innermost(pos: int) -> Optional[LuaFunction]:
        best = None
        for g in spans:
            if g.start <= pos < g.end and (best is None or g.start >= best.start):
                best = g
        return best

    out: list[tuple[int, str]] = []
    for fn in src.lua_functions:
        if id(fn) not in load or not fn.name:
            continue
        open_ = code.rfind("(", 0, max(0, fn.start - 1))
        params = [p.strip() for p in code[open_ + 1:fn.start - 1].split(",")] if open_ >= 0 else []
        foreign: dict[str, str] = {}
        for m in re.finditer(rf"(?<![\w.:]){re.escape(fn.name)}\s*\(", code):
            if re.search(r"\bfunction\s*$", code[max(0, m.start() - 24):m.start()]):
                continue  # the definition
            around = innermost(m.start())
            if (around is not None and id(around) not in load) or any(a <= m.start() <= b for a, b in when_spans):
                continue  # not a call at load
            depth, j, k = 0, m.end() - 1, m.end() - 1
            parts: list[str] = []
            while j < len(code):
                c = code[j]
                if c in "({[":
                    depth += 1
                elif c in ")}]":
                    depth -= 1
                    if depth == 0:
                        parts.append(code[k + 1:j])
                        break
                elif c == "," and depth == 1:
                    parts.append(code[k + 1:j])
                    k = j
                j += 1
            for param, arg in zip(params, parts):
                t = LUA_TABLE_COPY.fullmatch(arg.strip())
                if param and t and t.group(1) not in ("nil", "true", "false") and t.group(1) not in own:
                    foreign.setdefault(param, re.sub(r"\s+", "", arg.strip()))
        if not foreign:
            continue
        for rx in (LUA_PATCH, LUA_RAWSET, LUA_SETMETA):
            for m in rx.finditer(code, fn.start, fn.end):
                target = m.group(1)
                if target in foreign and innermost(m.start()) is fn and \
                        not any(a <= m.start() <= b for a, b in when_spans):
                    out.append((bisect.bisect_right(starts, m.start()),
                                f"writes into its parameter {target}, which a call at load gives {foreign[target]} (a "
                                "table this script does not own), outside coop_mode.when_srv"))
    return out


def lua_calls(src: Source) -> list[tuple[int, re.Match[str], Optional[LuaFunction]]]:
    """Every call of a script that is not a definition (`function foo(`) or a keyword (`if (`): (offset, match, the
    innermost function around it or None at file level)."""
    code = src.code
    spans = sorted(src.lua_spans, key=lambda f: (f.start, -f.end))
    stack: list[LuaFunction] = []
    k = 0
    out = []
    for m in LUA_CALL.finditer(code):
        pos = m.start()
        while k < len(spans) and spans[k].start <= pos:
            stack.append(spans[k])
            k += 1
        while stack and stack[-1].end <= pos:
            stack.pop()
        first = re.split(r"[.:]", m.group(1))[0]
        if first in LUA_KEYWORDS or re.search(r"\bfunction\s*$", code[max(0, pos - 24):pos]):
            continue  # `if (`, `function foo(`: not a call
        out.append((pos, m, stack[-1] if stack else None))
    return out


def lua_load_calls(src: Source, own: set[str], when_spans: list[tuple[int, int]]) -> list[tuple[int, str]]:
    """Calls of a srv script that run when the script loads, in every process (axr_main runs every script's file level
    and on_game_start): at file level, in on_game_start, in a function assigned to it and in every function of the file
    those call by name (lua_load_functions), outside the anonymous functions given to coop_mode.when_srv(...). Pure
    lookups (rawget, type, string.*, math.*, table.insert or setmetatable on an own table ...), calls of a load-time
    function of the file (its body is checked instead) and calls inside other functions are not."""
    code = src.code
    starts = line_starts(code)
    calls = lua_calls(src)
    bare = [(pos, "" if pos and code[pos - 1] in ".:" else m.group(1), inner) for pos, m, inner in calls]
    load = lua_load_functions(src, bare)
    load_names = {fn.name for fn in src.lua_functions if id(fn) in load}
    pure_aliases: set[str] = set()
    for names, exprs in re.findall(r"(?m)^[ \t]*local\s+([A-Za-z_][\w \t,]*?)\s*=\s*([^\n(]*)$", code):
        # `local string_format, table_sort = string.format, table.sort`: locals that stand for pure functions
        for name, expr in zip(names.split(","), exprs.split(",")):
            expr = re.sub(r"\s+", "", expr)
            if expr in LUA_PURE or expr.startswith(LUA_PURE_PREFIX):
                pure_aliases.add(name.strip())
    for name, expr in re.findall(r"""(?m)^[ \t]*local\s+([A-Za-z_]\w*)\s*=\s*rawget\s*\(\s*_G\s*,\s*["']([\w.]+)["']\s*\)""",
                                 src.code_strings):
        if expr in LUA_PURE or expr.startswith(LUA_PURE_PREFIX):
            pure_aliases.add(name)  # `local pf = rawget(_G, "printf")` (review 4, a false alarm of round 4)
    out: list[tuple[int, str]] = []
    seen: set[int] = set()
    for pos, m, inner in calls:
        if inner is not None and id(inner) not in load:
            continue  # runs when that function is called
        if any(a <= pos <= b for a, b in when_spans):
            continue
        name = m.group(1)
        if name in LUA_PURE or name.startswith(LUA_PURE_PREFIX):
            continue
        if name in load_names and not (pos and code[pos - 1] in ".:"):
            continue  # a load-time function of this file: its own calls are checked
        if name in pure_aliases:
            continue  # `local string_format = string.format`
        if name in LUA_PROTECTED and re.match(r"\s*\(\s*function\b", code[m.end() - 1:]):
            continue  # pcall(function() ... end): the literal's body runs at load and is checked itself (X6)
        if name in LUA_PROTECTED:
            arg = re.match(r"\s*\(\s*([A-Za-z_][\w.]*)\s*[,)]", code[m.end() - 1:])
            if arg and (arg.group(1) in LUA_PURE or arg.group(1).startswith(LUA_PURE_PREFIX)
                        or arg.group(1) in pure_aliases):
                continue  # pcall(string.format, ...): a pure function, protected
        if name in LUA_OWN_ARG:
            rest = code[m.end() - 1:]
            arg = re.match(r"\s*\(\s*([A-Za-z_]\w*)", rest)
            if arg and arg.group(1) in own:
                continue  # into a table of its own
            if name == "setmetatable" and re.match(r"\s*\(\s*\{", rest):
                continue  # a new table
        if pos and code[pos - 1] in ":." and name in LUA_STRING_METHODS and \
                re.search(r"""(?:\(\s*(?:""|'')\s*\)|""|'')\s*[:.]$""", code[max(0, pos - 12):pos]):
            continue  # ("%s"):format(...)
        number = bisect.bisect_right(starts, pos)
        if number in seen:
            continue
        seen.add(number)
        where = "file level" if inner is None else (
            "on_game_start" if inner.name == "on_game_start" else
            "a function literal that runs at load" if not inner.name else f"{inner.name}(), which runs at load")
        out.append((number, f"calls {name}() at load ({where}) outside coop_mode.when_srv: every process runs it"))
    return out


# ---- the scan -----------------------------------------------------------------------------------------------------

def enclosing_function(src: Source, line: int) -> Optional[CppFunction]:
    """The innermost C++ function (or lambda) whose head or body holds line, None at namespace or class scope."""
    best: Optional[CppFunction] = None
    for fn in src.cpp.functions if src.cpp else ():
        first = fn.head_line or fn.line
        last = fn.line + fn.body.count("\n")
        if first <= line <= last and (best is None or first >= (best.head_line or best.line)):
            best = fn
    return best


def is_call_at(line: str, pos: int) -> bool:
    """name( at pos is a call, not the head of its own definition or declaration (`SessionMode Session::session_mode()
    const`, `bool install_mode(Mode& m);`)."""
    before = line[:chain_start(line, pos)]
    if before.rstrip().endswith(("->", ".")):
        return True
    return not declares(before)


def call_name_around(code: str, pos: int) -> str:
    """The name of the call whose argument list holds pos (`Msg` of `::Msg("%s", mode().name())`), "" if none."""
    open_ = open_paren_before(code, pos)
    if open_ is None:
        return ""
    m = re.search(r"([A-Za-z_]\w*)\s*$", code[max(0, open_ - 80):open_])
    return m.group(1) if m else ""


def strip_mode_for_args(line: str) -> str:
    """The line with the argument list of every mode_for(...) blanked: a start may say the mode it asks for there."""
    out = line
    for m in reversed(list(re.finditer(r"\bmode_for\s*\(", line))):
        depth, j = 0, m.end() - 1
        while j < len(line):
            if line[j] == "(":
                depth += 1
            elif line[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out = out[:m.end()] + " " * max(0, j - m.end()) + out[j:]
    return out


def iface_check(src: Source, number: int, line: str, starts: list[int], aliases: set[str]) -> Optional[str]:
    """Why an Ядро C++ line asks the mode through the S4 interface (IFACE_KINDS), or None (guard round 8, F2)."""
    fn = enclosing_function(src, number)
    allowed = IFACE_ALLOWED.get((src.path.lower(), fn.qualifier, fn.name), frozenset()) if fn else frozenset()
    if "mode_for" in allowed:
        line = strip_mode_for_args(line)
    for kind, (rx, what) in IFACE_KINDS.items():
        if rx is None or kind in allowed:
            continue
        for m in rx.finditer(line):
            if kind == "m_roles" and fn is None:
                continue  # the member's own declaration (`u8 m_roles = 0;`)
            if kind == "ProcessRole" and re.search(r"\bhas_role\s*\(\s*$", line[:m.start()]):
                continue  # has_role(ProcessRole::X): the old predicates' own rule (L1 / L2; Player is is_player)
            if kind in ("session_mode", "roles_of", "mode_for", "install_mode", "boot_layers") and \
                    not is_call_at(line, m.start()):
                continue  # the head of its own definition or declaration
            return f"asks {what}: Ядро asks coop_mode about a player, a level or its own actor ('{m.group(0)}')"
    if "mode_name" not in allowed:
        names = [m for m in IFACE_MODE_NAME.finditer(line)]
        if aliases:
            names += list(re.finditer(r"\b(?:" + "|".join(map(re.escape, aliases)) + r")\s*(?:\.|->)\s*name\s*\(\s*\)",
                                      line))
        for m in names:
            if m.group(0).startswith("session_mode_name") and not is_call_at(line, m.start()):
                continue  # its own definition
            if call_name_around(src.code, starts[number - 1] + m.start()) in IFACE_LOG_CALLS:
                continue
            return f"asks {IFACE_KINDS['mode_name'][1]} ('{m.group(0)}'): print it, never compare or keep it"
    return None


def lua_part_tests(src: Source, getters: dict[tuple[str, str], str]) -> list[tuple[int, str]]:
    """(line, why) of every use of a server part's presence as a mode test in an Ядро script (guard round 8, B4 h6).
    getters: (module, function) -> origin of the functions of any Ядро script that return a part."""
    mod_name = pathlib.PurePosixPath(src.path).stem
    lines = src.lines()
    out: list[tuple[int, str]] = []
    local_getters = {nm for (mod, nm) in getters if mod == mod_name}

    def parts_in(text: str) -> list[tuple[int, int]]:
        """(start, end) of every part expression of text: `part(...)`, `x.part(...)`, `getter()`, `mod.getter()`."""
        found = []
        for m in LUA_PART.finditer(text):
            if re.search(r"\bfunction\s+(?:[A-Za-z_][\w.:]*[.:]\s*)?$", text[:m.start(0) + len(m.group(1) or "")]):
                continue  # `function part(` / `function M.part(`: the definition
            found.append((m.start(0), m.end(0) - 1))
        for m in re.finditer(r"(?<![\w.:])(?:([A-Za-z_]\w*)\s*\.\s*)?([A-Za-z_]\w*)\s*\(", text):
            mod, nm = m.group(1), m.group(2)
            if (mod and (mod, nm) in getters) or (not mod and nm in local_getters):
                if not re.search(r"\bfunction\s+$", text[:m.start()]):
                    found.append((m.start(), m.end() - 1))
        result = []
        for start, open_ in found:
            depth, j = 0, open_
            while j < len(text):
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            result.append((start, j + 1))
        return result

    def test_use(text: str, start: int, end: int) -> bool:
        before, after = text[:start], text[end:]
        while True:  # (P), type(P): the same presence
            b = before.rstrip()
            if b.endswith("(") and after.lstrip().startswith(")"):
                before = b[:-1]
                after = after.lstrip()[1:]
                if re.search(r"\btype\s*$", before):
                    before = re.sub(r"\btype\s*$", "", before)
                continue
            break
        if LUA_PART_DEFAULT.match(after):
            after = after[LUA_PART_DEFAULT.match(after).end():]  # `P or nil`: still the part
        if re.match(r"\s*[.:\[]", after):
            return False  # P.fn(...): calling a part's function
        return bool(LUA_PART_TEST_AFTER.match(after) or LUA_PART_TEST_BEFORE.search(before))

    getter_names = {nm for (_, nm) in getters}
    part_vars: dict[str, int] = {}
    for number, line in enumerate(lines, 1):
        spans = parts_in(line) if "part" in line or any(nm in line for nm in getter_names) else []
        if any(test_use(line, start, end) for start, end in spans):
            out.append((number, "uses a server part's presence as a mode test (coop_quests_core.part): call the "
                                "part's function, or ask coop_mode"))
            continue
        for start, end in spans:
            m = re.search(r"\blocal\s+([A-Za-z_]\w*)\s*=\s*(?:[^=]*\band\s+)?$", line[:start])
            rest = line[end:]
            rest = rest[LUA_PART_DEFAULT.match(rest).end():] if LUA_PART_DEFAULT.match(rest) else rest
            if m and not rest.strip():
                part_vars[m.group(1)] = number
        for var, at in part_vars.items():
            # its presence kept or returned as a value (`return far ~= nil`, `local srv = not not far`); a guard
            # before a call of its function (`if far == nil then return fn() end`, `far ~= nil and far.f()`) is not
            v = re.escape(var)
            if var in line and re.search(
                    rf"(?:\breturn|(?<![=~<>])=)\s*(?:{v}\s*[~=]=\s*nil|nil\s*[~=]=\s*{v}|not\s+not\s+{v})\s*(?:;|\bend\b|$)",
                    line):
                out.append((number, f"keeps the presence of {var}, a server part (line {at}), as a value: a mode "
                                    "test; call the part's function, or ask coop_mode"))
                break
    return out


def lua_part_getters(sources: list[Source]) -> dict[tuple[str, str], str]:
    """(module, function) of the Ядро script functions whose return value is a server part (`return part("far")`,
    `return qc and qc.part and qc.part("far") or nil`)."""
    out: dict[tuple[str, str], str] = {}
    for src in sources:
        if src.lang != "lua" or src.layer != "core" or "part" not in src.code:
            continue
        mod_name = pathlib.PurePosixPath(src.path).stem
        for fn in src.lua_functions:
            if fn.name == "part":
                continue
            for m in re.finditer(r"\breturn\b([^\n]*)", fn.body):
                expr = LUA_PART_DEFAULT.sub("", m.group(1)).strip()
                expr = re.sub(r"\s*\bend\s*$", "", expr).strip()
                if re.search(r"(?:^|\band\s+)(?:[A-Za-z_]\w*(?:\s*\(\s*\))?\s*[.:]\s*)*part\s*\([^()]*\)$", expr):
                    out[(mod_name, fn.name)] = f"{src.path}:{fn.line}"
                    break
    return out


def session_srv_line(src: Source, line: str) -> Optional[str]:
    """Why an Ядро / stock C++ line names the server's part of Session (L11), or None."""
    if src.path.lower() in SESSION_SELF:
        return None
    m = SESSION_SRV.search(line)
    return f"'{m.group(1)}' of Session: the server's part (srv::SessionSrv)" if m else None


def scan_model(model: Model, keys: list[tuple[int, str, str]], keys_path: str) -> list[Finding]:
    layers, sources = model.layers, model.sources
    qualified, by_ns, local, defs = model.qualified, model.by_ns, model.local, model.defs
    ENTRY = model.entry
    findings: list[Finding] = []

    cpp_names = frozenset([nm for (_, nm) in qualified] + [nm for (_, nm) in by_ns] +
                          [nm for d in local.values() for nm in d])
    lua_names = frozenset([nm for d in model.lua_in_file.values() for nm in d] + [nm for (_, nm) in model.lua_module])
    macro_rx = {r: re.compile(r"\b(" + "|".join(map(re.escape, [n for n, t in model.macros.items() if t.rule == r]))
                              + r")\b") for r in ("L1", "L2") if any(t.rule == r for t in model.macros.values())}
    l1_qual = {k: t for k, t in qualified.items() if t.rule == "L1"}
    stock_words = tuple(sorted(defs.outside | {q for (q, _) in l1_qual if q}))
    part_getters = lua_part_getters(sources)

    for src in sources:
        if not src.code:
            continue
        code_lines = src.lines()
        string_lines = src.code_strings.split("\n")
        raw_lines = src.raw.split("\n")
        starts = line_starts(src.code)
        starts_s = line_starts(src.code_strings)

        def lines_with(literals: Sequence[str]) -> set[int]:
            """Lines of code_strings (same line layout as code) holding any of the literals."""
            text = src.code_strings
            out: set[int] = set()
            for lit in literals:
                pos = text.find(lit)
                while pos >= 0:
                    out.add(bisect.bisect_right(starts_s, pos))
                    pos = text.find(lit, pos + len(lit))
            return out

        def lines_naming(names: Iterable[str]) -> set[int]:
            table = src.name_lines()
            out: set[int] = set()
            for nm in names:
                out.update(table.get(nm, ()))
            return out

        def calls_of(names: frozenset[str]) -> set[int]:
            return {bisect.bisect_right(starts, m.start()) for m in CALL_ANY.finditer(src.code) if m.group(1) in names}

        def add(rule: str, line: int, note: str = "") -> None:
            # the key text keeps string contents (`#include "coop_scope.h"`, `rawget(_G, "coop_x")`): two different
            # includes of one file are two entries, not one entry with a count
            code_line = string_lines[line - 1] if line - 1 < len(string_lines) else ""
            raw_line = raw_lines[line - 1] if line - 1 < len(raw_lines) else ""
            findings.append(Finding(rule, src.path, line, norm(code_line) or norm(raw_line), note))

        layer = src.layer
        if src.lang == "cpp":
            bare: dict[str, Taint] = {}
            if layer == "core":
                visible = src.visible()
                for (q, nm), t in by_ns.items():
                    if q in visible:
                        bare.setdefault(nm, t)
                bare.update(local.get(src.path, {}))
            # candidate lines by plain substrings (fast); every rule below checks its own regex on the line
            candidates = lines_with(LIT_INCLUDE + LIT_TOMBSTONE + LIT_STEAM)
            if layer == "core":
                candidates |= lines_with(LIT_CPP_MODE + LIT_CPP_ROLE + model.entry_lits + tuple(src.aliases)) \
                    | calls_of(cpp_names) | lines_naming(list(model.macros) + list(defs.names) + list(defs.quals))
                for q, nms in model.entry_bare.items():
                    if q in src.visible():
                        candidates |= lines_naming(nms)
            elif layer in ("srv", "hostplay"):
                candidates |= lines_naming(list(defs.names) + list(defs.quals))
            elif layer == "stock":
                candidates |= lines_with(LIT_STOCK + model.entry_lits + stock_words)
            if layer in ("core", "stock"):
                candidates |= lines_with(('"coop_',)) | (lines_with(("extern",)) if model.srv_globals else set())
                candidates |= lines_with(("bridge", "virtual", "operator_"))  # L11
            iface_aliases: set[str] = set()
            if layer == "core":
                candidates |= lines_with(IFACE_LITERALS)
                iface_aliases = set(IFACE_MODE_ALIAS.findall(src.code))
            for number in sorted(candidates):
                line = code_lines[number - 1]
                with_strings = string_lines[number - 1] if number - 1 < len(string_lines) else line
                inc = INCLUDE.match(with_strings)
                rew = rewrite_cpp_aliases(line, src.aliases)
                if layer in ("core", "stock") and not inc:
                    # C++ that reaches a srv script by its name (lua_getglobal(L, "coop_dedicated")) or reads a srv
                    # global through `extern` (review 2, B7 and B4)
                    l3s = None
                    if '"coop_' in with_strings:
                        for m in CPP_SCRIPT_STRING.finditer(with_strings):
                            dst = model.script_layer.get(m.group(1))
                            if dst and crosses(layer, dst):
                                l3s = f"names the script {m.group(1)} ({dst}) in a string"
                                break
                    if l3s is None and "extern" in line:
                        for m in EXTERN.finditer(line):
                            nm = m.group(1)
                            if nm in model.srv_globals and nm not in model.core_globals:
                                where = model.srv_globals[nm][0]
                                l3s = f"declares extern {nm}, defined only in {where} ({layers.layer_of(where)})"
                                break
                    if l3s:
                        add("L3", number, l3s)
                    why = session_srv_line(src, line)
                    if why:
                        add("L11", number, why)
                if layer == "core" and not inc:
                    hit = CPP_MODE.search(rew) or MODE_KEY.search(with_strings)
                    iface = None
                    if not hit and (any(w in line for w in ("mode", "Mode", "roles", "ProcessRole", "boot_layers"))
                                    or (iface_aliases and "name" in line)):
                        iface = iface_check(src, number, line, starts, iface_aliases)
                    if hit:
                        add("L1", number, f"'{hit.group(0)}'")
                    elif iface:
                        add("L1", number, iface)
                    else:
                        t = tainted_call(line, qualified, bare, "L1", ("::",), src.aliases)
                        m = macro_rx["L1"].search(line) if "L1" in macro_rx and not line.lstrip().startswith("#") \
                            else None
                        if t:
                            add("L1", number, f"calls a wrapper: {t.origin}")
                        elif m:
                            add("L1", number, f"uses a {model.macros[m.group(1)].origin}")
                    hit = CPP_ROLE.search(rew)
                    if hit:
                        add("L2", number, f"'{hit.group(0)}'")
                    else:
                        t = tainted_call(line, qualified, bare, "L2", ("::",), src.aliases)
                        m = macro_rx["L2"].search(line) if "L2" in macro_rx and not line.lstrip().startswith("#") \
                            else None
                        if t:
                            add("L2", number, f"calls a wrapper: {t.origin}")
                        elif m:
                            add("L2", number, f"uses a {model.macros[m.group(1)].origin}")
                    l3 = None
                    hit = next((h for h in ENTRY.finditer(rew) if not declares(rew[:chain_start(rew, h.start())])),
                               None) if ENTRY else None
                    if hit:
                        l3 = f"names the server entry point '{hit.group(0)}'"
                    if l3 is None:
                        for q, nms in model.entry_bare.items():
                            if q not in src.visible():
                                continue
                            for m in CALL_TOKEN.finditer(rew):
                                if m.group(1) is None and m.group(3) in nms and not declares(rew[:m.start()]) \
                                        and not rew[:m.start()].rstrip().endswith((".", "->", ":")):
                                    l3 = f"calls the server entry point {q}::{m.group(3)} (using namespace {q})"
                                    break
                            if l3:
                                break
                    if l3 is None:
                        refs = srv_refs(src, rew, defs, exclusive=True)
                        if refs:
                            (q, nm), paths = refs[0]
                            l3 = f"calls {q + '::' if q else ''}{nm}, defined only in {paths[0]} ({layers.layer_of(paths[0])})"
                    if l3:
                        add("L3", number, l3)
                if layer == "core" and INCLUDE_MACRO.match(with_strings):
                    add("L3", number, "an #include of a macro: the layer of the file cannot be checked")
                if inc and layer in ("core", "stock", "srv", "hostplay"):
                    target = resolve_include(src.path, inc.group(1), model.include_index)
                    if target:
                        dst = layers.layer_of(target)
                        if crosses(layer, dst):
                            add("L3", number, f"includes {target} ({dst})")
                if layer in ("srv", "hostplay") and not inc:
                    for (q, nm), paths in srv_refs(src, rew, defs, exclusive=True):
                        dst = {layers.layer_of(p) for p in paths}
                        if all(crosses(layer, d) for d in dst):
                            add("L3", number, f"calls {q + '::' if q else ''}{nm} of {paths[0]} ({'/'.join(sorted(dst))})")
                            break
                if layer == "stock" and not inc:
                    why = None
                    hit = CPP_MODE.search(line) or STOCK_HOOK.search(line)
                    if hit:
                        why = f"'{hit.group(0)}'"
                    if why is None and ENTRY:
                        hit = next((h for h in ENTRY.finditer(line)
                                    if not declares(line[:chain_start(line, h.start())])), None)
                        if hit:
                            why = f"the server entry point '{hit.group(0)}'"
                    if why is None:
                        refs = srv_refs(src, line, defs, exclusive=True)
                        if refs:
                            (q, nm), paths = refs[0]
                            why = f"calls {q + '::' if q else ''}{nm} of {paths[0]}"
                    if why is None:
                        t = tainted_call(line, l1_qual, {}, "L1", ("::",))
                        if t:
                            why = f"calls a wrapper: {t.origin}"
                    if why:
                        add("L5", number, why)
                hit = TOMBSTONE.search(with_strings) or TOMBSTONE_CODE.search(line)
                if layer != "dying" and hit:
                    add("L6", number, f"'{hit.group(0)}'")
                hit = STEAM.search(with_strings)
                if layer != "hostplay" and src.path not in STEAM_EXEMPT and hit:
                    add("L8", number, f"'{hit.group(0)}'")
            if layer == "core" and src.cpp:
                seen = set()
                header = src.path.lower().endswith(HEADER_SUFFIXES)
                for d in src.cpp.defaults:
                    raw = raw_lines[d.line - 1] if d.line - 1 < len(raw_lines) else ""
                    if not re.search(r"\bbool\b", d.type_text):
                        continue  # `uint16_t level = kNoLevel` is data, not a mode fact
                    if d.member and not header and d.value != "true":
                        continue  # a member of a .cpp's own data row: `bool here = false;` is the safe value
                    if (words_of(d.name) & MODE_WORDS or MODE_COMMENT.search(comment_of_line(raw))) and d.line not in seen:
                        seen.add(d.line)
                        add("L4", d.line, f"default of '{d.name}'")
            if layer in ("srv", "hostplay") and src.cpp:
                for fn in src.cpp.functions:
                    # a member of a class only Ядро / stock define: server code inside an Ядро object (review 2, B2)
                    if fn.out_of_class and fn.qualifier in model.core_classes:
                        add("L3", fn.head_line or fn.line, f"defines {fn.qualifier}::{fn.name}, a member of the Ядро "
                            f"class {fn.qualifier} ({model.core_classes[fn.qualifier]})")
                for var in src.cpp.variables:
                    if var.call:
                        by = var.call if " " in var.call else f"{var.call}(...)"
                        add("L9C", var.line, f"{var.name} is initialized by {by} when the exe loads")
                    if var.qualifier and var.qualifier in model.core_classes:
                        # `u32 FarLimits::squads_per_player = 4;`: Ядро reads it through its class (review 3, C8)
                        add("L3", var.line, f"defines the static member {var.qualifier}::{var.name} of the Ядро class "
                                            f"{var.qualifier} ({model.core_classes[var.qualifier]})")
        else:
            mod_name = pathlib.PurePosixPath(src.path).stem
            tainted_local = model.lua_in_file.get(src.path, {})
            lua_qual = {k: t for k, t in model.lua_module.items() if k[0] != mod_name}
            alias_lines = {line for name, line, expr in src.lua_aliases}
            spans = []
            call_results: list[int] = []
            if layer == "srv":
                for m in WHEN_SRV.finditer(src.code):
                    depth = 0
                    j = m.end() - 1
                    while j < len(src.code):
                        if src.code[j] == "(":
                            depth += 1
                        elif src.code[j] == ")":
                            depth -= 1
                            if depth == 0:
                                break
                        j += 1
                    # only the bodies of the anonymous functions given to when_srv wait for the srv layer; the rest of
                    # the parenthesis is evaluated at once (`when_srv(hide_far_spots())` runs it at load; review 3, C2)
                    spans += [(f.start, f.end) for f in src.lua_spans if m.end() <= f.start < j]
                    if re.match(r"\s*(?!function\b)[A-Za-z_][\w.:]*\s*\(", src.code[m.end():j]):
                        call_results.append(bisect.bisect_right(starts, m.start()))
            own = lua_own_names(src.code, mod_name, src.code_strings, src.lua_aliases) if layer == "srv" else set()
            candidates = lines_with(LIT_TOMBSTONE + LIT_STEAM)
            if layer == "core":
                candidates |= lines_with(LIT_LUA_MODE + LIT_LUA_ROLE) | calls_of(lua_names) | alias_lines
            if layer in ("core", "srv", "hostplay", "stock"):
                candidates |= lines_with(("coop_",)) | (lines_naming(src.aliases) if src.aliases else set())
            if layer == "stock":
                candidates |= lines_with(LIT_LUA_MODE)
            if layer == "hostplay":
                candidates |= lines_with(("srv",))
            if layer == "srv":
                candidates |= lines_with(LIT_LUA_REGISTER + ("function",))
            for number in sorted(candidates):
                line = code_lines[number - 1]
                with_strings = string_lines[number - 1] if number - 1 < len(string_lines) else line
                normed = lua_norm(with_strings)
                variants = [line, normed]
                here = aliases_at(src, number) if src.aliases else {}
                if here:
                    variants += [rewrite_lua(line, here), rewrite_lua(normed, here)]
                if layer == "core":
                    hit = next((h for h in (LUA_MODE.search(v) for v in variants) if h), None) \
                        or MODE_KEY.search(with_strings) or LUA_SRV_NAMED.search(with_strings)
                    if hit:
                        add("L1", number, f"'{hit.group(0)}'")
                    else:
                        t = next((t for t in (tainted_call(v, lua_qual, tainted_local, "L1", (".", ":"))
                                              for v in variants) if t), None)
                        if t:
                            add("L1", number, f"calls a wrapper: {t.origin}")
                    hit = next((h for h in (LUA_ROLE.search(v) for v in variants) if h), None)
                    if hit:
                        add("L2", number, f"'{hit.group(0)}'")
                    else:
                        t = next((t for t in (tainted_call(v, lua_qual, tainted_local, "L2", (".", ":"))
                                              for v in variants) if t), None)
                        if t:
                            add("L2", number, f"calls a wrapper: {t.origin}")
                        elif number in alias_lines and re.search(r"\bis_world_server\b|\bis_host\b", line):
                            add("L2", number, "an alias of a role")
                if layer == "stock":
                    # a stock-patch script runs in every process: a mode name in it is a stock hook (as L5 in C++)
                    hit = next((h for h in (LUA_MODE.search(v) for v in variants) if h), None) \
                        or LUA_SRV_NAMED.search(with_strings)
                    if hit:
                        add("L5", number, f"'{hit.group(0)}'")
                if layer == "hostplay":
                    # the co-op layer reads the engine's coop.*: the server's table is the other layer's (A-REV-E-1, 1)
                    hit = next((h for h in (LUA_SRV.search(v) for v in variants) if h), None) \
                        or LUA_SRV_NAMED.search(with_strings)
                    if hit:
                        add("L3", number, f"names the server's table srv ('{hit.group(0)}', srv/coop_srv_script.cpp)")
                if layer in ("core", "srv", "hostplay", "stock"):
                    refs: set[str] = set()
                    for v in variants:
                        refs |= {m.group(1) for m in LUA_MODULE_NAME.finditer(v)}
                    refs |= {m.group(1) or m.group(2) for m in LUA_MODULE_CALL.finditer(with_strings)}
                    # a plain string with a script's name (a dispatch table read through rawget(_G, name), C6)
                    refs |= set(LUA_SCRIPT_STRING.findall(with_strings))
                    if layer == "core" and LUA_COMPUTED_SCRIPT.search(with_strings):
                        add("L3", number, "a computed script name (rawget(_G, \"coop_\" .. x)): Ядро reaches a script "
                                          "no string names, of any layer; ask coop_mode instead (review 4, X7)")
                    for ref in sorted(refs):
                        if ref == FACADE or ref == mod_name or ref not in model.script_layer:
                            continue
                        if crosses(layer, model.script_layer[ref]):
                            add("L3", number, f"names the script {ref} ({model.script_layer[ref]})")
                            break
                hit = TOMBSTONE.search(with_strings)
                if layer != "dying" and hit:
                    add("L6", number, f"'{hit.group(0)}'")
                hit = STEAM.search(with_strings)
                if layer != "hostplay" and hit:
                    add("L8", number, f"'{hit.group(0)}'")
                if layer == "srv":
                    pos = starts[number - 1]

                    def outside(at: int) -> bool:
                        p = pos + min(at, len(line))
                        return not any(a <= p <= b for a, b in spans)

                    reg = None
                    rew_line = rewrite_lua(line, here)
                    for v in (line, rew_line):
                        m = next((m for m in LUA_REGISTER.finditer(v) if outside(m.start())), None)
                        if m:
                            reg = f"'{m.group(0).strip()}' outside coop_mode.when_srv"
                            break
                    for rx in (LUA_PATCH, LUA_PATCH_FN, LUA_RAWSET, LUA_SETMETA):
                        for m in (rx.finditer(rew_line) if reg is None else ()):
                            target = m.group(1)
                            if not outside(m.start()):
                                continue
                            if rx is LUA_SETMETA and target not in own:
                                # setmetatable changes how a shared table behaves in every process (C3)
                                reg = (f"sets the metatable of {target}, a table this script does not own, outside "
                                       "coop_mode.when_srv")
                            elif target == "_G":
                                reg = "assigns a global through _G outside coop_mode.when_srv"
                            elif target not in own:
                                # any table that is not this script's own: another script (in the repository or not:
                                # sim_board, smart_terrain), db, a global (review 2, B5)
                                known = model.script_layer.get(target) or ("stock" if target in model.stock_scripts
                                                                          else None)
                                reg = (f"patches the script {target} ({known})" if known else
                                       f"assigns into {target}, a table this script does not own,") + \
                                    " outside coop_mode.when_srv"
                            if reg:
                                break
                    if reg:
                        add("L9", number, reg)
            if layer == "core" and ("part" in src.code or part_getters):
                for number, why in lua_part_tests(src, part_getters):
                    add("L1", number, why)
            if layer == "srv":
                for number, why in lua_load_calls(src, own, spans):
                    add("L9", number, why)
                calls_ = lua_calls(src)
                bare_calls = [(p, "" if p and src.code[p - 1] in ".:" else m_.group(1), inner_)
                              for p, m_, inner_ in calls_]
                for number, why in lua_param_writes(src, own, lua_load_functions(src, bare_calls), spans):
                    add("L9", number, why)
                for number in call_results:
                    add("L9", number, "coop_mode.when_srv gets the result of a call: the call runs at load in every "
                                      "process; give it the function, not its result")
            locals_ = count_locals(src.code)
            if len(locals_) > LOCALS_LIMIT:
                for k, line_no in enumerate(locals_[LOCALS_LIMIT:], LOCALS_LIMIT + 1):
                    findings.append(Finding("L7", src.path, line_no, f"file-level locals over {LOCALS_LIMIT}",
                                            f"local number {k} of {len(locals_)}"))

    findings += srv_test_inits(model.root)

    # L10: every saved key still appears in some script
    script_text = "\n".join(s.code_strings for s in sources if s.lang == "lua" and is_gamedata_script(s.path))
    for line, kind, key in keys:
        word = key.split("|", 1)[1] if key.startswith("c|") else key
        if not re.search(rf"(?<![\w]){re.escape(word)}(?![\w])", script_text):
            findings.append(Finding("L10", keys_path, line, f"{kind} {key}", "not found in gamedata/scripts"))

    # one finding per (rule, path, line)
    unique: dict[tuple[str, str, int], Finding] = {}
    for f in findings:
        unique.setdefault((f.rule, f.path, f.line), f)
    return sorted(unique.values(), key=lambda f: (f.path, f.line, f.rule))


def srv_test_inits(root: pathlib.Path) -> list[Finding]:
    """L9C over tests/test_srv_*.cpp (review 4, X11): a srv-only change may add or edit these, and a namespace-scope
    initializer with a call (`static const int s = (_putenv("COOP_FUZZ_RUNS=1"), 0);`) runs before every co-op test of
    the same native exe."""
    out: list[Finding] = []
    tests = root / "tests"
    for path in sorted(tests.glob("test_srv_*.cpp")) if tests.is_dir() else []:
        rel = path.relative_to(root).as_posix()
        raw = read_source(path)
        code, with_strings = strip_both(raw, CPP_TOKENS, "/")
        cpp = parse_cpp(rel, blank_preprocessor(code))
        ctor = {f.qualifier for f in cpp.functions if f.qualifier and f.name == f.qualifier}
        lines = with_strings.split("\n")
        for var in cpp.variables:
            call = var.call or (f"the constructor {var.type}()" if var.type and var.type in ctor else "")
            if call:
                by = call if " " in call else f"{call}(...)"
                out.append(Finding("L9C", rel, var.line, norm(lines[var.line - 1] if var.line - 1 < len(lines) else ""),
                                   f"{var.name} is initialized by {by} when the test exe loads: it runs before every "
                                   "co-op test of that exe"))
    return out


def scan(root: pathlib.Path, layers: LayerMap, srv_entry: list[str], keys: list[tuple[int, str, str]],
         keys_path: str) -> tuple[list[Finding], list[Source]]:
    model = build(root, layers, srv_entry)
    return scan_model(model, keys, keys_path), model.sources


# ---- L12: mod names in engine C++ ----------------------------------------------------------------------------------

MOD_ADAPTER = "coop_mods_"
MOD_ADAPTER_RX = re.compile(r"coop_mods_\w*")
CPP_ESCAPE = r"\\(?:x[0-9A-Fa-f]+|[0-7]{1,3}|.)"
MOD_ESCAPE = re.compile(CPP_ESCAPE, re.S)
# A name may not be a whole word until an escape is replaced or adjacent literals are joined. Comments between
# literals are whitespace after strip_both; the bytes prefilter must allow those joins as well.
CPP_LITERAL_JOIN = r"""["'](?:\s+|//[^\r\n]*|/\*[\s\S]*?\*/)*+(?:["'](?=\w)|R")"""
MOD_JOIN = re.compile(CPP_LITERAL_JOIN)
MOD_JOIN_BYTES = re.compile(CPP_LITERAL_JOIN.encode("ascii"))


def cpp_literal_bodies(text: str) -> Iterator[tuple[int, str]]:
    """Starting offset and body with escapes replaced, joining adjacent literals in comment-free C++."""
    end = start = 0
    parts: list[str] = []
    for match in CPP_TOKENS.finditer(text):
        literal = match[0]
        if not literal.startswith(("R\"", '"', "'")):
            continue
        if parts and (gap := text[end:match.start()]) and not gap.isspace():
            yield start, "".join(parts)
            parts.clear()
        if not parts:
            start = match.start()
        if (delimiter := match[1]) is not None:
            body = literal[3 + len(delimiter):-2 - len(delimiter)]
        else:
            body = literal[1:-1] if len(literal) > 1 and literal.endswith(literal[0]) else literal[1:]
        parts.append(MOD_ESCAPE.sub(" ", body))
        end = match.end()
    if parts:
        yield start, "".join(parts)


class ModLine(NamedTuple):
    path: str
    number: int
    code: str
    code_tokens: list[str]
    string_tokens: list[str]
    adapter: str


def mod_lines(sources: Iterable[Source], words: set[str], adapters: bool = False) -> Iterator[ModLine]:
    """Lines matching the named tokens, or (for L12 itself) containing a coop_mods_ literal."""
    if not words and not adapters:
        return
    trie = trie_regex(words) if words else r"(?!)"
    word = re.compile(rf"(?<!\w)(?:{trie})(?!\w)")
    escaped = re.compile(rf"{CPP_ESCAPE}(?:{trie})(?!\w)")
    byte_word = re.compile(rb"(?<![A-Za-z0-9_])(?:" + trie.encode() + rb")(?![A-Za-z0-9_])")
    byte_escaped = re.compile(CPP_ESCAPE.encode() + rb"(?:" + trie.encode() + rb")(?![A-Za-z0-9_])")
    # A non-ASCII input word could occur in a cp1251 stock file as well as in its usual UTF-8 encoding.
    unicode_words = any(not token.isascii() for token in words)
    for src in sources:
        if src.lang != "cpp":
            continue
        code, kept = src.code, src.code_strings
        if src.data:
            data = src.data
            if not (unicode_words or (adapters and b"coop_mods_" in data) or byte_word.search(data)
                    or (b"\\" in data and byte_escaped.search(data)) or MOD_JOIN_BYTES.search(data)):
                continue
            code, kept = strip_both(decode(data), CPP_TOKENS, "/")

        code_hits: dict[int, list[str]] = defaultdict(list)
        string_hits: dict[int, list[str]] = defaultdict(list)
        adapter_hits: dict[int, str] = {}
        starts = []
        for hit in word.finditer(code):
            if not starts:
                starts = line_starts(code)
            code_hits[bisect.bisect_right(starts, hit.start())].append(hit[0])
        if ((adapters and MOD_ADAPTER in kept) or word.search(kept)
                or ("\\" in kept and escaped.search(kept)) or MOD_JOIN.search(kept)):
            literal_starts = []
            for offset, body in cpp_literal_bodies(kept):
                tokens = word.findall(body)
                adapter = MOD_ADAPTER_RX.search(body) if adapters else None
                if not tokens and not adapter:
                    continue
                # code and kept have equal line layout but different offsets.
                if not literal_starts:
                    literal_starts = line_starts(kept)
                number = bisect.bisect_right(literal_starts, offset)
                string_hits[number].extend(tokens)
                if adapter:
                    adapter_hits.setdefault(number, adapter[0])
        numbers = code_hits.keys() | string_hits.keys() | adapter_hits.keys()
        if numbers:
            lines = kept.split("\n")
            for number in sorted(numbers):
                yield ModLine(src.path, number, norm(lines[number - 1]), code_hits[number],
                              string_hits[number], adapter_hits.get(number, ""))


def mod_findings(sources: Iterable[Source], mods: Sequence[ModRow]) -> tuple[list[Finding], list[str]]:
    scripts = {row.token: row for row in mods if row.kind == "script"}
    ignores = {row.token for row in mods if row.kind == "ignore"}
    watched = {row.token: row for row in mods if row.kind == "name"}
    watched.update((word, row) for word, row in scripts.items() if len(word) >= 4)
    for word in ignores:
        watched.pop(word, None)
    debt = [row for row in mods if row.kind == "debt"]
    debt_tokens: dict[str, list[tuple[ModRow, Optional[re.Pattern[str]]]]] = defaultdict(list)
    for row in debt:
        debt_tokens[row.token].append((row, glob_regex(row.scope) if row.scope else None))

    findings = []
    used_debt: set[ModRow] = set()
    for line in mod_lines(sources, set(watched) | debt_tokens.keys(), adapters=True):
        tokens = line.code_tokens + line.string_tokens
        matched_debt = [row for word in tokens for row, scope in debt_tokens.get(word, ())
                        if scope is None or scope.match(line.path)]
        used_debt.update(matched_debt)
        named = next((watched[word] for word in tokens if word in watched), None)
        if line.adapter:
            note = f"a string names the mods layer '{line.adapter}'"
        elif named:
            prefix = "" if named.token in line.code_tokens else "a string "
            location = f"tools/mod_names.txt:{named.line}"
            if named.kind == "script":
                location += f", {named.build_or_debt}"
            note = f"{prefix}names the mod script '{named.token}' ({location})"
        elif matched_debt:
            item = matched_debt[0]
            note = f"P106 {item.build_or_debt} debt '{item.token}' (tools/mod_names.txt:{item.line})"
        else:
            continue  # A debt word outside its configured path.
        findings.append(Finding("L12", line.path, line.number, line.code, note))
    warnings = [
        f"warning: tools/mod_names.txt:{row.line}: debt {row.build_or_debt} '{row.token}' names no line any more: "
        "the item is moved, delete the row"
        for row in debt if row not in used_debt
    ] + [
        f"warning: tools/mod_names.txt:{row.line}: ignore '{row.token}' covers no script row"
        for row in mods if row.kind == "ignore" and row.token not in scripts
    ]
    return findings, warnings


# ---- what Ядро reaches (tools/check_gates.py) ---------------------------------------------------------------------

def config_refs(root: pathlib.Path, script_layer: dict[str, str]) -> list[tuple[str, int, str]]:
    """(config, line, script) of every srv / hostplay script function a config names: dialog preconditions and actions
    (`<precondition>coop_x.fn</precondition>`), logic condlists. XML comments and LTX `;` comments are not names."""
    out: list[tuple[str, int, str]] = []
    for folder in CONFIG_ROOTS:
        base = root / folder
        if not base.is_dir():
            continue
        for path in sorted(base.rglob("*")):
            suffix = path.suffix.lower()
            if suffix not in (".ltx", ".xml") or not path.is_file():
                continue
            data = path.read_bytes()
            if b"coop_" not in data:
                continue
            text = decode(data)
            if suffix == ".xml":
                text = re.sub(r"<!--.*?(?:-->|\Z)", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
            else:
                text = re.sub(r";[^\n]*", "", text)
            rel = path.relative_to(root).as_posix()
            for m in CFG_SCRIPT.finditer(text):
                if script_layer.get(m.group(1)) in ("srv", "hostplay"):
                    out.append((rel, text.count("\n", 0, m.start()) + 1, m.group(1)))
    return out


def core_reach(model: Model, roots: Iterable[str] = ()) -> dict[str, str]:
    """srv and hostplay files that run in both modes, lower-case path -> why; tools/check_gates.py counts them as Ядро.
    Ядро, stock (also the stock-patch scripts) and dying code reach a file when they include it, call a function it
    defines (an overload of an Ядро function too: review 3, C9), name it (Lua, also a plain string of a dispatch table;
    a C++ string, a config), declare `extern` a global it defines, or own the class whose member (function or static
    data, C8) it defines; a srv file with a static initializer that calls a function or a constructor (C7) runs in every
    process. Then, to a fixed point, every reached file is a root itself (and so are `roots`: the files the gate counts
    as Ядро for another reason), so a srv header that only a reached srv .cpp includes is reached too (review 2, B1),
    and so is a srv file that defines a member of a class declared in a reached file (review 3, C11)."""
    layers = model.layers
    reach: dict[str, str] = {}
    gate_core = ("core", "stock", "dying")

    def mark(path: str, why: str) -> None:
        if layers.layer_of(path) in ("srv", "hostplay"):
            reach.setdefault(path.lower(), why)

    def script(name: str) -> str:
        return f"gamedata/scripts/{name}.script"

    def lua_refs(src: Source) -> list[tuple[int, str]]:
        """(line, script) of the srv / hostplay scripts a Lua file names."""
        out = []
        mod_name = pathlib.PurePosixPath(src.path).stem
        for number, (line, with_strings) in enumerate(zip(src.lines(), src.code_strings.split("\n")), 1):
            if "coop_" not in with_strings and not src.aliases:
                continue
            normed = lua_norm(with_strings)
            refs = {m.group(1) for v in (line, normed, rewrite_lua(normed, aliases_at(src, number)))
                    for m in LUA_MODULE_NAME.finditer(v)}
            refs |= {m.group(1) or m.group(2) for m in LUA_MODULE_CALL.finditer(with_strings)}
            refs |= set(LUA_SCRIPT_STRING.findall(with_strings))  # a dispatch table of script names (C6)
            for ref in sorted(refs):
                if ref != mod_name and model.script_layer.get(ref) in ("srv", "hostplay"):
                    out.append((number, ref))
        return out

    def string_refs(src: Source) -> list[tuple[int, str]]:
        """(line, script) of the srv / hostplay scripts a C++ file names in a string (lua_getglobal(L, "coop_x"))."""
        out = []
        if '"coop_' not in src.code_strings:
            return out
        for number, with_strings in enumerate(src.code_strings.split("\n"), 1):
            if '"coop_' in with_strings and not INCLUDE.match(with_strings):
                for m in CPP_SCRIPT_STRING.finditer(with_strings):
                    if model.script_layer.get(m.group(1)) in ("srv", "hostplay"):
                        out.append((number, m.group(1)))
        return out

    def call_refs(src: Source, words: Iterable[str]) -> list[tuple[int, tuple[str, str], list[str]]]:
        out = []
        table = src.name_lines()
        code_lines = src.lines()
        for number in sorted({n for nm in table.keys() & set(words) for n in table[nm]}):
            line = rewrite_cpp_aliases(code_lines[number - 1], src.aliases)
            # a name that Ядро defines too counts as well: the call may pick the srv overload (`may_switch(g)` of
            # `may_switch(const FarGroup&)`); the gate errs towards Ядро, L3 stays exclusive (review 3, C9)
            for key, paths in srv_refs(src, line, model.defs, exclusive=False):
                out.append((number, key, paths))
        return out

    # 1. the include graph, from every Ядро / stock / dying C++ file
    edges: dict[str, list[str]] = {}
    for src in model.sources:
        if src.lang == "cpp":
            targets = []
            for inc in src.includes:
                t = resolve_include(src.path, inc, model.include_index)
                if t and t != src.path:
                    targets.append(t)
            edges[src.path] = targets
    seen: dict[str, str] = {}
    queue = [(s.path, s.path) for s in model.sources if s.lang == "cpp" and s.layer in gate_core]
    for path, _ in queue:
        seen[path] = path
    while queue:
        path, origin = queue.pop()
        for t in edges.get(path, ()):
            if t in seen:
                continue
            seen[t] = origin
            mark(t, f"included by {origin}" + (f" (through {path})" if path != origin else ""))
            queue.append((t, origin))
    # 2. calls of server / co-op functions from Ядро / stock / dying code
    inside = model.defs.names | model.defs.quals  # what our namespaces name; stock code names defs.outside
    for src in model.sources:
        if src.lang != "cpp" or src.layer not in gate_core or not src.code:
            continue
        for number, (q, nm), paths in call_refs(src, model.defs.outside if src.layer == "stock" else inside):
            for p in paths:
                mark(p, f"defines {q + '::' if q else ''}{nm}, called from {src.path}:{number}")
    # 3. Lua: a srv / hostplay script named by an Ядро script or a stock-patch script (engine/gamedata/scripts,
    # gamedata_gamma/scripts: axr_main runs them in every process)
    for src in model.sources:
        if src.lang == "lua" and src.layer in gate_core and src.code:
            for number, ref in lua_refs(src):
                mark(script(ref), f"named by {src.path}:{number}")
    # 4. C++: a srv / hostplay script named in a string of Ядро / stock code (lua_getglobal(L, "coop_dedicated"))
    for src in model.sources:
        if src.lang == "cpp" and src.layer in gate_core and src.code:
            for number, ref in string_refs(src):
                mark(script(ref), f"named in a string by {src.path}:{number}")
    # 5. configs: a dialog or a logic section names a srv / hostplay script function
    for rel, number, ref in config_refs(model.root, model.script_layer):
        mark(script(ref), f"named by {rel}:{number}")
    # 6. a global that Ядро / stock / dying code declares `extern` and a srv / hostplay file defines
    srv_only = {nm: paths for nm, paths in model.srv_globals.items() if nm not in model.core_globals}
    if srv_only:
        for src in model.sources:
            if src.lang != "cpp" or src.layer not in gate_core or not src.code or "extern" not in src.code:
                continue
            for m in EXTERN.finditer(src.code):
                for p in srv_only.get(m.group(1), ()):
                    mark(p, f"defines {m.group(1)}, declared extern by {src.path}")
    # 7. a member of a class only Ядро / stock define; a static initializer that calls a function (every process)
    for src in model.sources:
        if not src.cpp or src.layer not in ("srv", "hostplay"):
            continue
        fn = next((f for f in src.cpp.functions if f.out_of_class and f.qualifier in model.core_classes), None)
        if fn:
            mark(src.path, f"defines {fn.qualifier}::{fn.name}, a member of the Ядро class {fn.qualifier} "
                           f"({model.core_classes[fn.qualifier]})")
        var = next((v for v in src.cpp.variables if v.call), None)
        if var:
            mark(src.path, f"a static initializer with a call at {src.path}:{var.line} runs in every process")
        var = next((v for v in src.cpp.variables if v.qualifier and v.qualifier in model.core_classes), None)
        if var:
            # `u32 FarLimits::squads_per_player = 4;` of an Ядро class: Ядро reads it (review 3, C8)
            mark(src.path, f"defines the static member {var.qualifier}::{var.name} of the Ядро class {var.qualifier} "
                           f"({model.core_classes[var.qualifier]})")
    # 8. to a fixed point: what a reached file (or a root) includes, calls or names is reached too; and a srv / hostplay
    # file that defines a member (a function or a static data member) of a class declared in a reached file: Ядро calls
    # it through an object of that class (`operator_book().may_run(line)` of coop_operator.h's Book, review 3, C11)
    by_low = {s.path.lower(): s for s in model.sources}
    members = [(s, f"{f.qualifier}::{f.name}", f.qualifier) for s in model.sources
               if s.cpp and s.layer in ("srv", "hostplay") for f in s.cpp.functions if f.out_of_class and f.qualifier]
    members += [(s, f"{v.qualifier}::{v.name}", v.qualifier) for s in model.sources
                if s.cpp and s.layer in ("srv", "hostplay") for v in s.cpp.variables if v.qualifier]
    root_lows = [r.lower() for r in roots]
    pending = list(reach) + root_lows
    done: set[str] = set()
    while pending:
        while pending:
            low = pending.pop()
            if low in done:
                continue
            done.add(low)
            src = by_low.get(low)
            if src is None or not src.code:
                continue
            before = set(reach)
            if src.lang == "cpp":
                for t in edges.get(src.path, ()):
                    mark(t, f"included by the reached {src.path}")
                for number, (q, nm), paths in call_refs(src, inside):
                    for p in paths:
                        mark(p, f"defines {q + '::' if q else ''}{nm}, called by the reached {src.path}:{number}")
                for number, ref in string_refs(src):
                    mark(script(ref), f"named in a string by the reached {src.path}:{number}")
            else:
                for number, ref in lua_refs(src):
                    mark(script(ref), f"named by the reached {src.path}:{number}")
            pending.extend(set(reach) - before)
        declared: dict[str, str] = {}
        for low in sorted(set(reach) | set(root_lows)):
            src = by_low.get(low)
            if src is not None and src.cpp:
                for name in sorted(src.cpp.classes):
                    declared.setdefault(name, src.path)
        for s, what, cls in members:
            if cls in declared and s.path.lower() not in reach and s.path.lower() not in root_lows:
                mark(s.path, f"defines {what}, a member of the class {cls} declared in the reached {declared[cls]}")
                if s.path.lower() in reach:
                    pending.append(s.path.lower())
    return reach


# ---- main ---------------------------------------------------------------------------------------------------------

def apply_session_frozen(findings: list[Finding], root: pathlib.Path) -> tuple[list[Finding], list[str]]:
    """L11 lines that SESSION_SRV_FROZEN still covers drop out (a (path, code) found at most as often as frozen); one
    found more often fails on every line of it. A warning for a frozen line of an existing file that is gone (the list
    only shrinks: delete its entry)."""
    by_key: dict[tuple[str, str], list[Finding]] = defaultdict(list)
    for f in findings:
        if f.rule == "L11":
            by_key[(f.path, f.code)].append(f)
    covered = {id(f) for key, items in by_key.items() if len(items) <= SESSION_SRV_FROZEN.get(key, 0) for f in items}
    warnings = [f"warning: SESSION_SRV_FROZEN names a line no longer there (frozen {n}, found "
                f"{len(by_key.get(key, []))}): {key[0]}|{key[1]} - delete the entry in tools/check_layers.py"
                for key, n in sorted(SESSION_SRV_FROZEN.items())
                if len(by_key.get(key, [])) < n and (root / key[0]).is_file()]
    return [f for f in findings if id(f) not in covered], warnings


def group(findings: Iterable[Finding]) -> dict[Key, list[Finding]]:
    out: dict[Key, list[Finding]] = defaultdict(list)
    for f in findings:
        if f.rule in ALLOWABLE:
            out[(f.rule, f.path, f.code)].append(f)
    return out


def format_allow(found: dict[Key, list[Finding]]) -> str:
    entries = sorted(f"{rule}|{path}|{code}|{len(items)}" for (rule, path, code), items in found.items())
    total = sum(len(items) for items in found.values())
    header = (
        f"# ceiling: {total}\n"
        "# Today's violations of the layer rules (tools/check_layers.py, docs/MODES.md section 5).\n"
        "# rule|path|code of the line, comments dropped, white space collapsed|count. The ceiling only goes down:\n"
        "# a migration step deletes lines here and lowers the ceiling in the same commit (python -I tools\\check_layers.py\n"
        "# --write-allow). Any change to a file listed here is an Ядро change (critique H9, tools/check_gates.py).\n"
    )
    return header + "".join(e + "\n" for e in entries)


def load_inputs(root: pathlib.Path, args: argparse.Namespace) -> tuple[LayerMap, list[str], list[tuple[int, str, str]],
                                                                      pathlib.Path, pathlib.Path]:
    tools = root / "tools"
    paths = {
        "layers.txt": pathlib.Path(args.layers) if getattr(args, "layers", None) else tools / "layers.txt",
        "srv_entry.txt": pathlib.Path(args.srv_entry) if getattr(args, "srv_entry", None) else tools / "srv_entry.txt",
        "persisted_keys.txt": pathlib.Path(args.keys) if getattr(args, "keys", None) else tools / "persisted_keys.txt",
    }
    for name, path in paths.items():
        if not path.is_file():
            raise InputError(f"missing input file {name}: {path}")
    layers = parse_layers(paths["layers.txt"].read_text(encoding="utf-8"), root)
    srv_entry = parse_names(paths["srv_entry.txt"].read_text(encoding="utf-8"))
    keys = parse_keys(paths["persisted_keys.txt"].read_text(encoding="utf-8"))
    return layers, srv_entry, keys, paths["persisted_keys.txt"], paths["layers.txt"]


def main(argv: Optional[Sequence[str]] = None, model: Optional[Model] = None) -> int:
    """model: one tools/check_gates.py already built from the same tree and lists (it runs this check first, in its own
    process, instead of building the model twice)."""
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--root", default=str(ROOT), help="repository root (default: this repository)")
    ap.add_argument("--layers", help="layers.txt (default <root>/tools/layers.txt)")
    ap.add_argument("--allow", help="layers_allow.txt (default <root>/tools/layers_allow.txt)")
    ap.add_argument("--srv-entry", help="srv_entry.txt (default <root>/tools/srv_entry.txt)")
    ap.add_argument("--keys", help="persisted_keys.txt (default <root>/tools/persisted_keys.txt)")
    ap.add_argument("--mod-names", help="mod_names.txt (default <root>/tools/mod_names.txt)")
    ap.add_argument("--write-allow", action="store_true", help="rewrite the allow list from the tree, ceiling = its sum")
    ap.add_argument("--reset-ceiling", action="store_true",
                    help="with --write-allow: accept new entries and let the ceiling go up (the lead, after review)")
    ap.add_argument("--top", type=int, default=0, help="also print the N Ядро files with the most allowed lines")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    allow_path = pathlib.Path(args.allow) if args.allow else root / "tools" / "layers_allow.txt"
    mods_path = pathlib.Path(args.mod_names) if args.mod_names else root / "tools" / "mod_names.txt"
    try:
        if not args.write_allow and not allow_path.is_file():
            raise InputError(f"missing input file layers_allow.txt: {allow_path}")
        layers, srv_entry, keys, keys_file, _ = load_inputs(root, args)
        if not mods_path.is_file():
            raise InputError(f"missing input file mod_names.txt: {mods_path}")
        mods = parse_mod_names(mods_path.read_text(encoding="utf-8"))
        ceiling, allowed = (parse_allow(allow_path.read_text(encoding="utf-8")) if allow_path.is_file() else (None, {}))
        if not args.write_allow and ceiling is None:
            raise InputError(f"layers_allow.txt has no '# ceiling: N' line: {allow_path}")
    except (OSError, UnicodeError, InputError) as error:
        print(f"check_layers: {error}")
        return 2

    try:
        keys_rel = keys_file.resolve().relative_to(root).as_posix()
    except ValueError:
        keys_rel = keys_file.as_posix()
    if model is not None:
        findings, sources = scan_model(model, keys, keys_rel), model.sources
    else:
        findings, sources = scan(root, layers, srv_entry, keys, keys_rel)
    mod_hits, mod_warnings = mod_findings(sources, mods)
    findings.extend(mod_hits)
    findings, frozen_warnings = apply_session_frozen(findings, root)
    found = group(findings)
    total = sum(len(v) for v in found.values())

    for w in mod_warnings:
        print(w)

    if args.write_allow:
        if not args.reset_ceiling:
            grown = sorted(k for k, items in found.items() if len(items) > allowed.get(k, 0))
            if grown:
                for k in grown:
                    print(f"new or grown: {'|'.join(k)} ({len(found[k])} found, {allowed.get(k, 0)} allowed)")
                print(f"check_layers: refusing --write-allow: {len(grown)} entr{'y' if len(grown) == 1 else 'ies'} new "
                      "or grown. --write-allow only lowers the list (a dropped line is not traded for a new one): fix "
                      "the new lines, or (the lead, after review) add --reset-ceiling")
                return 1
            if ceiling is not None and total > ceiling:
                print(f"check_layers: refusing --write-allow: {total} violation(s) > ceiling {ceiling}. Fix the new "
                      f"ones, or (the lead, after review) add --reset-ceiling")
                return 1
        allow_path.write_text(format_allow(found), encoding="utf-8", newline="\n")
        print(f"check_layers: wrote {allow_path} ({len(found)} entries, ceiling {total})")
        return 0

    failures: list[str] = []
    warnings: list[str] = list(frozen_warnings)
    used = 0
    for key, items in sorted(found.items()):
        allow = allowed.get(key, 0)
        used += min(len(items), allow)
        if len(items) > allow:
            extra = f"  [{len(items)} found, {allow} allowed]" if allow else ""
            for f in items:
                note = f" ({f.note})" if f.note else ""
                failures.append(f"{f.path}:{f.line}: [{f.rule}] {f.code}{note} — {WHY[f.rule]}{extra}")
    for f in findings:
        if f.rule not in ALLOWABLE:
            failures.append(f"{f.path}:{f.line}: [{f.rule}] {f.code} ({f.note}) — {WHY[f.rule]}")
    for key, allow in sorted(allowed.items()):
        have = len(found.get(key, []))
        if have < allow:
            warnings.append(f"warning: stale allow entry (allowed {allow}, found {have}): {'|'.join(key)}")
    allowed_sum = sum(allowed.values())
    if ceiling is not None and allowed_sum > ceiling:
        failures.append(f"tools/layers_allow.txt:1: [ceiling] the entries add up to {allowed_sum}, above its ceiling "
                        f"{ceiling}: the ceiling only goes down (docs/MODES.md section 5)")
    failures.sort(key=lambda s: (s.split(":", 1)[0], int(s.split(":")[1]) if s.split(":")[1].isdigit() else 0, s))

    for w in warnings:
        print(w)
    for f in failures:
        print(f)
    if args.top:
        per_file: dict[str, int] = defaultdict(int)
        for (rule, path, _), items in found.items():
            if layers.layer_of(path) == "core" and rule in ("L1", "L2"):
                per_file[path] += len(items)
        for path, n in sorted(per_file.items(), key=lambda kv: (-kv[1], kv[0]))[:args.top]:
            print(f"top: {n:5d} {path}")
        per_rule: dict[str, int] = defaultdict(int)
        for (rule, _, _), items in found.items():
            per_rule[rule] += len(items)
        print("rules: " + ", ".join(f"{r} {per_rule[r]}" for r in sorted(per_rule, key=rule_order)))
    else:
        print(f"L12: {len(mod_hits)} findings")
    files = len(sources)
    if failures:
        print(f"check_layers: FAIL ({len(failures)})")
        return 1
    print(f"check_layers: OK ({files} files, ceiling {ceiling}, used {used})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
