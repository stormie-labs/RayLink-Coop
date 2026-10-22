-- Anomaly Coop: the native route table (engine/src/xrCoop/coop_routes.h) as the Lua tests see it through the runner's
-- built-in module coop_native (tests/lua/native_coop.cpp). Run: tools\test_lua.cmd routes_native
local PASSES, FAILS = 0, 0

local function check(name, got, want)
	if got == want then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print(string.format("  FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
	end
end

if type(coop_native) ~= "table" then
	print("  FAIL coop_native missing: temp\\lua\\runlua.exe predates tests\\lua\\native_coop.cpp, rebuild it with "
		.. "set LUA_REBUILD=1 & tools\\test_lua.cmd")
	print(string.format("%d passed, %d failed", PASSES, FAILS + 1))
	return
end

-- Brief: a script override takes actor_on_update to the host.
coop_native.reset()
check("default actor_on_update", coop_native.route("actor_on_update", "treasure_manager"), "owner")
local n, errs = coop_native.add("route_scripts", { treasure_manager = "host" })
check("add treasure_manager errors", n, 0)
check("add treasure_manager error list", type(errs) == "table" and #errs, 0)
check("treasure_manager on actor_on_update", coop_native.route("actor_on_update", "treasure_manager"), "host")
check("another script keeps the default", coop_native.route("actor_on_update", "other_mod"), "owner")

-- Defaults by callback.
check("npc_on_death_callback", coop_native.route("npc_on_death_callback", "some_mod"), "host")
check("on_key_press", coop_native.route("on_key_press", "some_mod"), "view")
check("save_state", coop_native.route("save_state", "some_mod"), "host")
check("load_state", coop_native.route("load_state", "some_mod"), "view")
check("script argument is optional", coop_native.route("actor_on_item_use"), "owner")
-- Fix round 1: the player's own use action is owner; monolith's server_object_* callbacks are host.
check("npc_on_use", coop_native.route("npc_on_use", "some_mod"), "owner")
check("monster_on_loot_init", coop_native.route("monster_on_loot_init", "ui_mutant_loot"), "owner")
check("server_object_on_register", coop_native.route("server_object_on_register", "some_mod"), "host")
-- A mod's own callback: GAMMA Useful Idiots' idiots_on_start must run on a client too.
check("idiots_on_start", coop_native.route("idiots_on_start", "some_mod"), "owner")
check("idiots_on_start runs on a client", coop_native.runs_here(coop_native.route("idiots_on_start", "x"), false), true)
-- Its listeners sit in illish\patches\xr_combat_ignore.lua, a stock AI script name listed as host: the script rule
-- beats the owner default, only the forced callback brings them back.
coop_native.add("route_scripts", { xr_combat_ignore = "host" })
check("idiots_on_start under a host script", coop_native.route("idiots_on_start", "xr_combat_ignore"), "host")
coop_native.add("route_callbacks_forced", { idiots_on_start = "view" })
check("idiots_on_start forced back", coop_native.route("idiots_on_start", "xr_combat_ignore"), "view")
coop_native.reset()
coop_native.add("route_scripts", { treasure_manager = "host" })

-- Every section and its precedence.
n = coop_native.add("route_callbacks_forced", { load_state = "view" })
check("add forced", n, 0)
coop_native.add("route_scripts", { surge_manager = "host", debug_tools = "blocked", ["ea_*"] = "owner", ea_callbacks = "view" })
check("forced beats script", coop_native.route("load_state", "surge_manager"), "view")
check("forced does not beat none", coop_native.route("load_state", "debug_tools"), "none")
check("longest prefix: exact", coop_native.route("npc_on_update", "ea_callbacks"), "view")
check("longest prefix: prefix", coop_native.route("npc_on_update", "ea_other"), "owner")
coop_native.add("route_callbacks", { actor_on_update = "view" })
check("callback rule under scripts", coop_native.route("actor_on_update", "treasure_manager"), "host")
check("callback rule over default", coop_native.route("actor_on_update", "other_mod"), "view")
coop_native.add("route_pairs", { ["load_state@debug_tools"] = "view" })
check("pair beats everything", coop_native.route("load_state", "debug_tools"), "view")

-- Errors are counted and named; good lines in the same call still apply.
n, errs = coop_native.add("route_scripts", { bad_one = "hots", fine_one = "host" })
check("bad domain count", n, 1)
check("bad domain named", type(errs) == "table" and errs[1] ~= nil and errs[1]:find("bad_one", 1, true) ~= nil, true)
check("good line applied", coop_native.route("actor_on_update", "fine_one"), "host")
check("unknown section", (coop_native.add("route_typo", { x = "host" })), 1)
check("non-string entry", (coop_native.add("route_scripts", { "host" })), 1)

-- runs_here.
check("host on host", coop_native.runs_here("host", true), true)
check("host on client", coop_native.runs_here("host", false), false)
check("level on client", coop_native.runs_here("level", false), false)
check("owner on client", coop_native.runs_here("owner", false), true)
check("view on client", coop_native.runs_here("view", false), true)
check("none on host", coop_native.runs_here("none", true), false)
check("unknown domain is an error", (pcall(coop_native.runs_here, "hots", true)), false)
check("route needs a callback", (pcall(coop_native.route)), false)

-- reset drops every override.
coop_native.reset()
check("reset", coop_native.route("actor_on_update", "treasure_manager"), "owner")
check("reset forced", coop_native.route("load_state", "debug_tools"), "view")

print(string.format("%d passed, %d failed", PASSES, FAILS))
