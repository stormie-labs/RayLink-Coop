-- TZ P50 (Dev 58), both modes: at level exits collision between players is off (the owner, 2026-11-22: "always when you are at a
-- transition ... collision between players just switches off"). The engine knows the level changers of the level (g_lchangers);
-- Anomaly / G.A.M.M.A. lead most exits through a route restrictor of sr_teleport_sections.ltx instead (the group queues there:
-- Cordon -> Garbage is esc_space_restrictor_to_garbage_*), and only scripts\coop_transition_route.script lists those. It hands the
-- list to the engine (coop.player_touch_zones, engine xrGame\coop\coop_player_touch.cpp) each time it lists the level, on every
-- machine of a session (the machine that plays an actor uses it for its own actor; another ignores it): Coop host and clients,
-- Server clients. Not in single player (no session: nothing listed). An exe without the binding: nothing, no error.
-- Engine stand-ins: coop.is_active, coop.transition_route, coop.player_touch_zones, db.zone_by_name, ini_file.
-- Run: tools\test_lua.cmd issue_p50   (VERBOSE=1 for logs)
local ROOT = "gamedata/"

FAILS, PASSES = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

local function readfile(p)
	local fh = io.open(p, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local SECTIONS = {
	esc_space_restrictor_to_garbage_1 = { position = "120.5, 3.25, -44,1.57" },
	esc_space_restrictor_to_garbage_2 = { position = "-170.0, 2.0, 340.0" },
	gar_space_restrictor_to_escape = { position = "10.0, 1.0, -300.0" },
}

local NOW = 100000
local function machine(opts)
	opts = opts or {}
	local M = { log = {}, cb = {}, zones = {}, active = opts.active ~= false }
	local env = setmetatable({}, { __index = _G })
	env._G = env
	M.env = env
	function env.printf(fmt, ...)
		local ok, line = pcall(string.format, fmt, ...)
		line = ok and line or tostring(fmt)
		M.log[#M.log + 1] = line
		if os.getenv("VERBOSE") then print("    " .. line) end
	end
	env.time_global = function() return NOW end
	env.RegisterScriptCallback = function(name, f)
		M.cb[name] = M.cb[name] or {}
		table.insert(M.cb[name], f)
	end
	M.actor_at = { x = 0, y = 0, z = 0 }
	env.db = { actor = { position = function() return M.actor_at end }, zone_by_name = {} }
	M.objects, M.level_name = {}, "l01_escape"
	env.level = {
		object_by_id = function(id) return M.objects[id] end,
		name = function() return M.level_name end,
	}
	function M.zone(id, name)
		local z = {}
		function z:id() return id end
		function z:name() return name end
		function z:inside() return false end
		env.db.zone_by_name[name] = z
		M.objects[id] = z
		return z
	end
	function M.gone(id, name)
		M.objects[id] = nil
		env.db.zone_by_name[name] = nil
	end
	env.get_object_story_id = function() return nil end
	env.ini_file = function()
		local ini = {}
		function ini:section_exist(s) return SECTIONS[s] ~= nil end
		function ini:r_string_ex(s, k) return SECTIONS[s] and SECTIONS[s][k] or nil end
		return ini
	end
	env.alife_storage_manager = { get_state = function() return {} end }
	env.txr_routes = { scan_route = function() return false end }
	env.mlr_utils = { load_var = function() return nil end }
	local cls = {}
	cls.__index = cls
	function cls:OnMsgOk() end
	env.ui_sr_teleport = { msg_box_ui = cls }
	env.coop = {
		is_active = function() return M.active end,
		transition_route = function() return nil end,
	}
	if opts.binding ~= false then
		env.coop.player_touch_zones = function(ids)
			if opts.engine_error then error("the engine is gone") end
			local copy = {}
			for i, v in ipairs(ids) do copy[i] = v end
			M.zones[#M.zones + 1] = copy
			return #copy
		end
	end
	local function load_script(name)
		local mod = setmetatable({}, { __index = env })
		env[name] = mod
		local path = ROOT .. "scripts/" .. name .. ".script"
		local f = assert(loadstring(readfile(path), "@" .. path))
		setfenv(f, mod)()
		return mod
	end
	load_script("coop_util")
	M.mode = load_script("coop_mode")
	M.R = load_script("coop_transition_route")
	M.R.on_game_start()
	return M
end

local function frames(M, ms)
	local t_end = NOW + (ms or 0)
	repeat
		for _, f in ipairs(M.cb.actor_on_update or {}) do f() end
		NOW = NOW + 16
	until NOW >= t_end
end

local function same(a, b)
	if type(a) ~= "table" or #a ~= #b then return false end
	for i = 1, #b do
		if a[i] ~= b[i] then return false end
	end
	return true
end

local modes = dofile("tests/lua/support/modes.lua")
for _, set in ipairs(modes.names()) do
	print("== answer set " .. set)
	local M = machine()
	modes.install(M.mode, set)
	M.zone(901, "esc_space_restrictor_to_garbage_1")
	M.zone(700, "esc_space_restrictor_to_garbage_2")
	M.zone(650, "esc_smart_terrain_2_12_restrictor") -- a zone of the level, no route
	frames(M, 300)
	check(#M.zones >= 1, set .. ": the engine got the route exits of the level at the first listing")
	check(same(M.zones[#M.zones], { 700, 901 }), set .. ": every route restrictor of the level, in id order, and nothing else")
	local before = #M.zones
	M.gone(901, "esc_space_restrictor_to_garbage_1")
	frames(M, 5200)
	check(#M.zones > before and same(M.zones[#M.zones], { 700 }), set .. ": listed again: a restrictor that left the world is gone")
	M.level_name = "l02_garbage"
	M.gone(700, "esc_space_restrictor_to_garbage_2")
	M.zone(1200, "gar_space_restrictor_to_escape")
	frames(M, 300)
	check(same(M.zones[#M.zones], { 1200 }), set .. ": another level: its own route exits at once")
	local errors_before = #M.log

	print("== " .. set .. ": no session, an exe without the binding, an engine that throws")
	local off = machine({ active = false })
	modes.install(off.mode, set)
	off.zone(901, "esc_space_restrictor_to_garbage_1")
	frames(off, 300)
	check(#off.zones == 0, set .. ": no session (single player): nothing is handed to the engine")
	local old = machine({ binding = false })
	modes.install(old.mode, set)
	old.zone(901, "esc_space_restrictor_to_garbage_1")
	local ok = pcall(frames, old, 300)
	check(ok, set .. ": an exe without coop.player_touch_zones: no error")
	local bad = machine({ engine_error = true })
	modes.install(bad.mode, set)
	bad.zone(901, "esc_space_restrictor_to_garbage_1")
	ok = pcall(frames, bad, 300)
	check(ok, set .. ": an engine that throws does not stop the route exits")
	check(#M.log == errors_before, set .. ": the good machine logged nothing more meanwhile")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if UNKNOWN then
	local names = {}
	for k in pairs(UNKNOWN) do names[#names + 1] = k end
	table.sort(names)
	print("  globals read and not stubbed: " .. table.concat(names, ", "))
end
