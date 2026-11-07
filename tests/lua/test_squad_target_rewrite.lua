-- G.A.M.M.A. sim_squad_scripted.script:139 (get_script_target): the branch for a numeric target indexes the global `obj`
-- (nil) instead of the local se_target. A squad whose scripted_target is a number ends the game (client reports
-- RL-XK6N-8U4U, RL-M68Z-RV5K, RL-PVY5-ERKS, RL-PMQ3-QJ23). coop_npc_compat rewrites that one method in place: the class
-- and every wrapper that kept the original (Useful Idiots' PATCH_get_script_target upvalue) get the fixed function.
dofile("tests/lua/support/harness_npc.lua")

local FIXTURE = "temp/lua/sim_squad_scripted.script" -- the file name is how the original is recognised

-- The shape of the GAMMA method: its header line and the faulty line are literal, the rest is reduced.
local HEADER = "function sim_squad_scripted:get_script_target()"
local BAD = "\tif se_target and (obj:clsid() == clsid.online_offline_group_s or obj:clsid() == clsid.smart_terrain) then"
local function source(bad_line)
	return table.concat({
		"-- fixture of a class module",
		"local STAY = 1",
		"",
		HEADER,
		"\tlocal new_target",
		"\tif (self.scripted_target) then",
		"\t\tnew_target = self.scripted_target",
		"\tend",
		"\tif (new_target == \"actor\") then",
		"\t\treturn 0",
		"\tend",
		"\tlocal smart = new_target and SIMBOARD.smarts_by_names[new_target]",
		"\tif (smart) then",
		"\t\treturn smart.id",
		"\tend",
		"\tlocal new_id = tonumber(new_target)",
		"\tlocal se_target = new_id and alife_object(new_id)",
		bad_line,
		"\t\treturn new_id",
		"\tend",
		"end",
		"",
		"function sim_squad_scripted:other()",
		"\treturn STAY",
		"end",
		"",
	}, "\r\n")
end

local function write_fixture(text)
	local fh = assert(io.open(FIXTURE, "wb"))
	fh:write(text)
	fh:close()
end

local CLS_SMART, CLS_SQUAD, CLS_OTHER = 1, 2, 3

-- A machine with the GAMMA module loaded the way the engine loads it (chunk source = the file's path).
local function boot(role, text, idiots)
	reset_world()
	local M = machine(role or "host", 0, { [0] = 0 })
	local E = M.env
	write_fixture(text)
	E.getFS = function() return { update_path = function(_, _, name)
		M.reads = (M.reads or 0) + 1
		return name == "sim_squad_scripted.script" and FIXTURE:gsub("/", "\\") or "absent/" .. name
	end } end
	E.clsid = { online_offline_group_s = CLS_SQUAD, smart_terrain = CLS_SMART }
	E.SIMBOARD = { smarts_by_names = { bar_smart = { id = 77 } } }
	local world = {
		[77] = { clsid = function() return CLS_SMART end },
		[88] = { clsid = function() return CLS_SQUAD end },
		[99] = { clsid = function() return CLS_OTHER end },
	}
	E.alife_object = function(id) return world[id] end
	local m = setmetatable({}, { __index = E })
	m.sim_squad_scripted = {}
	local chunk = assert(loadstring(text, "@" .. FIXTURE))
	setfenv(chunk, m)
	chunk()
	E.sim_squad_scripted = m
	local original = m.sim_squad_scripted.get_script_target
	if idiots then
		-- illish/patches/axr_companions.lua: the original kept in a local before the scripts' on_game_start
		local PATCH_get_script_target = m.sim_squad_scripted.get_script_target
		m.sim_squad_scripted.get_script_target = function(self)
			local target = PATCH_get_script_target(self)
			return target
		end
	end
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	return M, E, m, original
end

local function install(M)
	local K = load_script(M, "coop_npc_compat")
	K.on_game_start()
	return K
end

local function logged(M, needle)
	for _, l in ipairs(M.log) do if l:find(needle, 1, true) then return true end end
	return false
end

local function squad(target) return { scripted_target = target } end

-- control: the fixture reproduces the reported error
do
	local _, _, m = boot("host", source(BAD))
	local ok, err = pcall(m.sim_squad_scripted.get_script_target, squad(88))
	check(not ok and tostring(err):find("attempt to index global 'obj'", 1, true) ~= nil,
		"control: the GAMMA line fails on a numeric target as in the reports")
end

for _, role in ipairs({ "host", "client" }) do
	for _, idiots in ipairs({ false, true }) do
		local M, _, m, original = boot(role, source(BAD), idiots)
		install(M)
		local f = m.sim_squad_scripted.get_script_target
		local tag = " (" .. role .. ", idiots=" .. tostring(idiots) .. ")"
		local ok, r = pcall(f, squad(88))
		check(ok and r == 88, "a numeric target that is a squad answers its id" .. tag)
		ok, r = pcall(f, squad(77))
		check(ok and r == 77, "a numeric target that is a smart answers its id" .. tag)
		ok, r = pcall(f, squad(99))
		check(ok and r == nil, "a numeric target of another class answers nothing" .. tag)
		ok, r = pcall(f, squad(12345))
		check(ok and r == nil, "a numeric target with no object answers nothing" .. tag)
		check(f(squad("bar_smart")) == 77 and f(squad("actor")) == 0 and f(squad(nil)) == nil,
			"string targets answer as before" .. tag)
		check(m.sim_squad_scripted.other() == 1, "the rest of the module is untouched" .. tag)
		if idiots then
			check(f ~= original and debug.getinfo(f, "S").source ~= "@" .. FIXTURE, "the wrapper of the other mod stays in place" .. tag)
		end
		local fixed = debug.getinfo(m.sim_squad_scripted.get_script_target, "S")
		check(logged(M, "rewrite sim_squad_scripted.get_script_target applied"), "the rewrite is logged" .. tag)
		check(not idiots or fixed.source ~= "@" .. FIXTURE, "idiots: the class keeps the wrapper" .. tag)
	end
end

-- the fixed method keeps the file's line numbers (an error in it points at the GAMMA line)
do
	local M, _, m = boot("host", source(BAD))
	install(M)
	local info = debug.getinfo(m.sim_squad_scripted.get_script_target, "S")
	check(info.source:gsub("\\", "/") == "@" .. FIXTURE and info.linedefined == 4, "the fixed method is defined at the file's line")
end

-- another version of the script: nothing is touched, the reason is logged
do
	local good = "\tif se_target and (se_target:clsid() == clsid.online_offline_group_s or se_target:clsid() == clsid.smart_terrain) then"
	local M, _, m, original = boot("host", source(good))
	install(M)
	check(m.sim_squad_scripted.get_script_target == original, "a fixed GAMMA version stays as it is")
	check(logged(M, "rewrite sim_squad_scripted.get_script_target skipped"), "the skip is logged")
end

-- the module is not there (plain Anomaly): no source is read
do
	reset_world()
	local M = machine("host", 0, { [0] = 0 })
	M.env.getFS = function() return { update_path = function() M.reads = (M.reads or 0) + 1; return "absent/x.script" end } end
	load_script(M, "coop_npc_players")
	load_script(M, "coop_mods_core")
	install(M)
	check(not M.reads or not logged(M, "sim_squad_scripted"), "no sim_squad_scripted: nothing is rewritten")
end

-- a second game start does not rewrite again
do
	local M, _, m = boot("host", source(BAD), true)
	local K = install(M)
	local first = m.sim_squad_scripted.get_script_target
	K.on_game_start()
	check(m.sim_squad_scripted.get_script_target == first and first(squad(88)) == 88, "a second start keeps the one rewrite")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
