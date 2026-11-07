-- Co-op debug, package 2 (docs\DEBUG_DESIGN.md B.5, C): the command registry coop_debug_cmds, shared by the world server, its
-- console and the F7 window. Every v1 command of the design has a class, an executor and an argument schema; the schema refuses
-- what the stock would not take. Run: tools\test_lua.cmd debug_cmds
dofile("tests/lua/support/harness_npc.lua")

local M = machine("host", 0, { [0] = 0 })
M.env.ini_sys = make_ini({
	wpn_ak74 = { { "class", "WP_AK74" } },
	medkit = { { "class", "II_MEDKI" } },
	af_medusa = { { "class", "ARTEFACT" } },
	sim_squad_bandit = { { "class", "ON_OFF_S" } },
	m_poltergeist_tele = { { "class", "SM_POLTR" } },
	phantom = { { "class", "AI_PHANT" } },
	zone_mosquito_bald = { { "class", "ZS_MBALD" } },
	actor = { { "class", "S_ACTOR" } },
	kit_mod = { { "class", "WP_AK74" }, { "kind", "i_tool" } },
})
local R = load_script(M, "coop_debug_cmds")

print("== the registry")
check(R ~= nil and type(R.get) == "function" and type(R.list) == "function" and type(R.validate) == "function", "get, list, validate")
check(R.VERSION == 1, "schema version 1")

-- The v1 commands of the design (C.1, the column v1 = check), by class.
local V1 = {
	view = { "obj_info", "can_see" },
	world = { "time_add", "time_to", "time_factor", "weather", "surge", "psi", "unlock_routes", "unlock_ency",
		"release_common_squads", "respawns", "info" },
	self = { "money", "god", "ammo", "invis", "basic_kit", "tp", "tp_to_player", "level" },
	spawn = { "spawn_item", "spawn_object", "test_squad" },
	target = { "kill", "release", "trade_refresh", "companion", "relation", "goodwill", "squad_goodwill", "wound",
		"inv_clear", "faction" },
	operator = { "lua" },
}
for class, ids in pairs(V1) do
	for _, id in ipairs(ids) do
		local c = R.get(id)
		check(c ~= nil, id .. " is in the registry")
		if c then
			check(c.class == class, id .. " has class " .. class)
			check(type(c.run) == "function", id .. " has an executor")
			check(type(c.args) == "table", id .. " has an argument schema")
			check(type(c.help) == "string" and c.help ~= "", id .. " has a help line")
			check(c.where == "ws" or c.where == "player_level" or c.where == "target_level",
				id .. " says where it runs (" .. tostring(c.where) .. ")")
		end
	end
end
local n = 0
for _, id in ipairs(R.list()) do
	n = n + 1
	local c = R.get(id)
	check(R.CLASSES[c.class] == true, id .. ": a known class")
end
check(n >= 34, "at least 34 commands listed (" .. n .. ")")
check(#R.list("world") == #V1.world, "list(class) gives that class only")

print("== nothing out of v1 (C.3)")
for _, id in ipairs({ "release_all_squads", "info_clear", "game_graph_show", "execute", "trade", "dev_debug", "community",
	"heli", "chopper", "weather_reload", "set_rank" }) do
	check(R.get(id) == nil, id .. " is not a command")
end

local function ok_args(id, a)
	local ok, clean, why = R.validate(id, a)
	return ok, clean, why
end
local function refused(id, a, code)
	local ok, c = R.validate(id, a)
	return ok == false and c == (code or "bad_args")
end

print("== the schema")
do
	local ok, a = ok_args("spawn_item", { sec = "wpn_ak74", at = "inv" })
	check(ok and a.sec == "wpn_ak74" and a.n == 1 and a.at == "inv", "spawn_item: n defaults to 1")
	ok, a = ok_args("spawn_item", { sec = "wpn_ak74" })
	check(ok and a.at == "inv", "spawn_item: at defaults to inv")
	check(refused("spawn_item", { sec = "no_such_section" }), "spawn_item: an unknown section")
	check(refused("spawn_item", { sec = "sim_squad_bandit" }), "spawn_item: a section of no item class (stock itm_to_spawn_classes)")
	check(ok_args("spawn_item", { sec = "kit_mod" }), "spawn_item: kind wins over class, as the stock")
	check(refused("spawn_item", { sec = string.rep("a", 65) }), "spawn_item: a string longer than 64")
	check(refused("spawn_item", { sec = "wpn_ak74", n = 0 }), "spawn_item: n = 0")
	check(refused("spawn_item", { sec = "wpn_ak74", n = 2.5 }), "spawn_item: n not whole")
	check(refused("spawn_item", { sec = "wpn_ak74", n = 21 }, "cap"), "spawn_item: n = 21 without ok is cap")
	check(ok_args("spawn_item", { sec = "wpn_ak74", n = 100, ok = true }), "spawn_item: n = 100 with ok (whole category, confirmed)")
	check(refused("spawn_item", { sec = "wpn_ak74", n = 101, ok = true }, "cap"), "spawn_item: n = 101 is cap even with ok")
	check(refused("spawn_item", { sec = "wpn_ak74", at = "smart" }), "spawn_item: at = smart is not an item mode")
	check(refused("spawn_item", { sec = "wpn_ak74", at = "point" }), "spawn_item: at = point needs x y z lv")
	check(ok_args("spawn_item", { sec = "wpn_ak74", at = "point", x = 1, y = 2, z = 3, lv = 77 }), "spawn_item: at = point with a point")
	check(refused("spawn_item", { sec = "wpn_ak74", at = "point", x = 0 / 0, y = 2, z = 3, lv = 77 }), "spawn_item: NaN")
	check(refused("spawn_item", { sec = "wpn_ak74", at = "point", x = 1, y = 2, z = 3, lv = -1 }), "spawn_item: lv < 0")
	check(refused("spawn_item", { sec = { "x" } }), "spawn_item: a table")

	ok, a = ok_args("spawn_object", { sec = "sim_squad_bandit", at = "smart", sm = "esc_smart_terrain_2_12" })
	check(ok and a.sm == "esc_smart_terrain_2_12", "spawn_object: a squad at a smart")
	check(ok_args("spawn_object", { sec = "zone_mosquito_bald", at = "near" }), "spawn_object: an anomaly near")
	check(ok_args("spawn_object", { sec = "m_poltergeist_tele", at = "point", x = 1, y = 2, z = 3, lv = 1 }), "spawn_object: a mutant")
	check(refused("spawn_object", { sec = "phantom", at = "near" }), "spawn_object: a phantom is out of v1 (no ALife)")
	check(refused("spawn_object", { sec = "wpn_ak74", at = "near" }), "spawn_object: an item is not an object")
	check(refused("spawn_object", { sec = "actor", at = "near" }), "spawn_object: the actor class is not spawnable")
	check(refused("spawn_object", { sec = "sim_squad_bandit", at = "smart" }), "spawn_object: at = smart needs sm")
	check(refused("spawn_object", { sec = "sim_squad_bandit", at = "inv" }), "spawn_object: no inventory mode")

	ok, a = ok_args("time_add", { h = 6 })
	check(ok and a.d == 0 and a.h == 6 and a.m == 0, "time_add: missing parts are 0")
	check(refused("time_add", {}), "time_add: nothing to add")
	check(refused("time_add", { h = -1 }), "time_add: never back (the stock clock has no way back)")
	check(ok_args("time_to", { h = 6, m = 30 }), "time_to: 06:30")
	check(refused("time_to", { h = 24 }), "time_to: hour 24")
	check(refused("time_to", { h = 6, m = 60 }), "time_to: minute 60")
	check(ok_args("time_factor", { f = 10 }), "time_factor 10")
	check(refused("time_factor", { f = 0 }), "time_factor 0 (frozen clock)")
	check(ok_args("weather", { w = "w_storm1" }), "weather w_storm1")
	check(refused("weather", { w = "../x" }), "weather: a path")
	check(ok_args("surge", { on = true }), "surge on")
	check(ok_args("surge", { on = "start" }), "surge start (stock word)")
	ok, a = ok_args("surge", { on = "stop" })
	check(ok and a.on == false, "surge stop is on = false")
	check(refused("surge", {}), "surge: on is required")
	check(ok_args("unlock_ency", { what = "notes" }), "unlock_ency notes")
	check(refused("unlock_ency", { what = "all" }), "unlock_ency all")
	check(ok_args("info", { k = "give", i = "debug_info_x" }), "info give")
	check(refused("info", { k = "clear" }), "info clear is out of v1")

	ok, a = ok_args("money", { a = 50000 })
	check(ok and a.a == 50000, "money 50000")
	check(refused("money", { a = 1000001 }), "money over 1 000 000 at once")
	check(refused("money", { a = 0 }), "money 0")
	check(ok_args("money", { a = -500 }), "money can take")
	check(ok_args("god", { on = 1 }), "god on = 1")
	check(ok_args("god", { on = "off" }), "god off")
	check(ok_args("tp", { x = 1, y = 2, z = 3 }), "tp to a point")
	check(refused("tp", { x = 1, y = 2 }), "tp: z missing")
	check(ok_args("tp_to_player", { p = 2 }), "tp_to_player p = 2")
	check(refused("tp_to_player", { p = 8 }), "tp_to_player: no peer 8")
	check(ok_args("level", { name = "l01_escape" }), "level l01_escape")

	check(ok_args("kill", { t = 1234 }), "kill t")
	check(refused("kill", {}), "kill: t is required")
	check(refused("kill", { t = 65535 }), "kill: t = 65535 (no object)")
	ok, a = ok_args("relation", { t = 10, r = "enemy" })
	check(ok and a.t2 == nil, "relation: t2 is optional (the requester)")
	check(refused("relation", { t = 10, r = "lover" }), "relation: an unknown word")
	check(ok_args("goodwill", { t = 10, g = 5000 }) and ok_args("goodwill", { t = 10, g = -5000 }), "goodwill +-5000 (the stock buttons)")
	check(refused("goodwill", { t = 10, g = 5001 }), "goodwill over 5000")
	check(ok_args("faction", { t = 10, c = "bandit" }), "faction bandit")
	check(ok_args("lua", { code = "printf('x')" }), "lua code (operator)")
	check(refused("no_such_command", {}, "unknown_cmd"), "an unknown command is unknown_cmd")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
