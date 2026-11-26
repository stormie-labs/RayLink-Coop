-- G17-2: real stock/mod entrypoints, real timer queue and native route table.
-- Removing the Live/confirmation guard, material probe or original-widget route
-- must break these cases. No game installation or network is used.
local passed, failed = 0, 0
local function test(name, f)
	local ok, err = pcall(f)
	if ok then passed = passed + 1; print("  ok   " .. name)
	else failed = failed + 1; print("  FAIL " .. name .. ": " .. tostring(err)) end
end

local function source(name, path)
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	local f = assert(loadfile(path))
	setfenv(f, env)()
	return env
end

local function fixture(role, late, early, skip_adapter)
	MODE = role == "none" and "sp" or (role == "client" or role == "srv_player") and "client" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	coop_main, coop_route, coop_mods_core, coop_mods_start_guard, coop_mode = nil, nil, nil, nil, nil
	_coop_route_wrappers = nil
	if role == "srv_map" then coop.is_map_server = function() return true end end
	if role == "srv_world" then coop.is_dedicated = function() return true end end
	local modes = dofile("tests/lua/support/modes.lua")
	load_script("coop_mode")
	if role == "client" then
		modes.install(coop_mode, "hostplay", { is_player_mirror = function() return true end })
	elseif role == "srv_player" then
		modes.install(coop_mode, "srv_map", {
			actor_is_player = function() return true end,
			leads_here = function() return false end,
			is_player_mirror = function() return true end,
			decider = function() return "other" end,
		})
	else modes.install(coop_mode, role) end
	local s = { live = false, acknowledge = false, attempts = 0, hits = 0, material = "default", probes = 0 }
	coop.is_live = function() return s.live end
	local actor = make_actor()
	local vars = {}
	function save_var(obj, key, value) vars[obj:id() .. key] = value end
	function load_var(obj, key) return vars[obj:id() .. key] end
	function empty_table(t) for k in pairs(t) do t[k] = nil end end
	VEC_Z = vector():set(0, 0, 1)
	hit = setmetatable({ radiation = 3 }, { __call = function() return {} end })
	actor.hit = function(_, h) s.hits = s.hits + 1; s.power = h.power end
	level.pick_material = function(pos, dir, distance, ignore)
		assert(pos.x == actor:position().x and pos.z == actor:position().z, "probe own actor position")
		assert(pos.y > actor:position().y and dir.y == -1 and distance > 0 and distance <= 2, "bounded downward probe")
		assert(ignore:id() == actor:id(), "probe ignores own body")
		s.probes = s.probes + 1
		return s.material
	end
	alife_release_id = function(id)
		s.attempts = s.attempts + 1
		if s.live and s.acknowledge then release_id(id) end
	end
	AddScriptCallback("actor_on_footstep")
	AddScriptCallback("imgui_on_render")
	local dte = source("demonized_time_events", "temp/review/corpus/merged/demonized_time_events.script")
	local knife = source("grok_remove_knife_ammo_on_start", "temp/review/corpus/merged/grok_remove_knife_ammo_on_start.script")
	local water = source("gameplay_radioactive_water", "temp/stock_scripts/scripts/gameplay_radioactive_water.script")
	water.get_damage_ms = function() return 0.002 end
	s.menus, s.debugger = {}, 0
	ImGui = {
		BeginMenu = function(name) s.menus[name] = (s.menus[name] or 0) + 1; return true end,
		EndMenu = function() end,
		MenuItem = function() return true end,
	}
	s.debug_enabled = function(enabled)
		debugger_attach = enabled and function() s.debugger = s.debugger + 1 end or nil
		debugger_stop, debugger_reconnect, DebuggerMode = nil, nil, false
	end
	s.debug_enabled(true)
	source("_imgui_groups", "temp/review/corpus/merged/_imgui_groups.script")
	if not late then source("imgui_lua_debug", "temp/review/corpus/merged/imgui_lua_debug.script") end
	load_script("coop_mods_core")
	load_script("coop_route").install()
	local function start_mods()
		dte.on_game_start()
		knife.on_game_start()
		water.on_game_start()
		_imgui_groups.on_game_start()
	end
	if not early then start_mods() end
	-- A missing adapter leaves stock behaviour in place for the initial RED run.
	local adapter_file = io.open("gamedata/scripts/coop_mods_start_guard.script", "r")
	if adapter_file then
		adapter_file:close()
		if not skip_adapter then load_script("coop_mods_start_guard").on_game_start() end
	end
	if early then start_mods() end
	if late then source("imgui_lua_debug", "temp/review/corpus/merged/imgui_lua_debug.script") end
	function s.tick(ms)
		for _ = 1, math.ceil((ms or 250) / 250) do
			NOW = NOW + 250
			SendScriptCallback("actor_on_update", db.actor, 0)
		end
	end
	s.actor, s.knife, s.water = actor, knife, water
	return s
end

for _, role in ipairs({ "hostplay", "client", "srv_player" }) do
	test(role .. ": cleanup waits for Live and retries until all copies disappear", function()
		local s = fixture(role)
		spawn("ammo_knife", s.actor:position(), s.actor:id())
		spawn("ammo_knife", s.actor:position(), s.actor:id())
		spawn("ammo_knife_6", s.actor:position(), s.actor:id())
		SendScriptCallback("actor_on_first_update")
		s.tick(20000)
		assert(s.attempts == 0, "cleanup ran before Live")
		s.live = true
		s.tick(1000)
		assert(s.attempts >= 3 and s.actor:object("ammo_knife"), "must retry unconfirmed removals")
		s.acknowledge = true
		s.tick(2000)
		assert(not s.actor:object("ammo_knife") and not s.actor:object("ammo_knife_6"), "all knife ammo removed")
		local attempts = s.attempts
		s.tick(2000)
		assert(s.attempts == attempts, "confirmed cleanup must stop")
	end)
	test(role .. ": an empty first pass still checks late startup ammo on the second pass", function()
		local s = fixture(role)
		s.live, s.acknowledge = true, true
		SendScriptCallback("actor_on_first_update")
		s.tick(250)
		assert(s.attempts == 0, "first pass had no ammo to remove")
		spawn("ammo_knife_4", s.actor:position(), s.actor:id())
		s.tick(250)
		assert(not s.actor:object("ammo_knife_4") and s.attempts == 1, "second startup pass must remove late ammo once")
	end)
	test(role .. ": failed cleanup has bounded retries", function()
		local s = fixture(role)
		s.live = true
		spawn("ammo_knife_3", s.actor:position(), s.actor:id())
		SendScriptCallback("actor_on_first_update")
		s.tick(60000)
		local attempts = s.attempts
		s.tick(60000)
		assert(attempts > 2 and attempts <= 150 and s.attempts == attempts, "unfinished cleanup must retry then stop")
	end)
	test(role .. ": dry load clears stale water before stationary update", function()
		local s = fixture(role)
		s.live = true
		save_var(s.actor, "grw_in_water", true)
		SendScriptCallback("load_state", {})
		assert(load_var(s.actor, "grw_in_water") == nil, "load itself must clear the saved flag")
		SendScriptCallback("actor_on_update", s.actor, 100)
		assert(load_var(s.actor, "grw_in_water") ~= true and s.hits == 0, "dry actor inherited saved water damage")
		assert(s.probes == 1, "stationary actor's current material must be queried")
	end)
	test(role .. ": stationary water load and dry transition use local material", function()
		local s = fixture(role)
		s.live, s.material = true, "materials\\water"
		SendScriptCallback("load_state", {})
		SendScriptCallback("actor_on_update", s.actor, 100)
		assert(s.hits == 1 and s.power == 0.2, "wet stationary actor must receive stock damage")
		assert(load_var(s.actor, "grw_in_water") ~= true, "water flag must stay transient")
		SendScriptCallback("actor_on_update", s.actor, 100)
		assert(s.hits == 2 and s.probes == 1, "a player who stands where he was probed keeps the result: no new ray")
		s.hits = 1
		-- a transition loads the level: the next update probes the ground again
		s.material = "default"
		SendScriptCallback("load_state", {})
		SendScriptCallback("actor_on_footstep", "materials\\water")
		SendScriptCallback("actor_on_update", s.actor, 100)
		assert(s.hits == 1, "stale footstep must not override current dry material")
	end)
	for _, late in ipairs({ false, true }) do
		for _, enabled in ipairs({ false, true }) do
			test(role .. ": LuaDebug route none; late=" .. tostring(late) .. ", lua_debug=" .. tostring(enabled), function()
				local s = fixture(role, late)
				s.debug_enabled(enabled)
				local allowed = 0
				ImGui.Groups.Debug.Widget(function() allowed = allowed + 1 end)
				ImGui.Groups.Debug.Render()
				assert(not s.menus.LuaDebug and s.debugger == 0, "route none widget must not draw or execute")
				assert(allowed == 1, "allowed widget must still render")
			end)
		end
	end
end

test("client: cleanup stays pending when Live precedes the actor", function()
	local s = fixture("client", false, true)
	s.live, s.acknowledge = true, true
	spawn("ammo_knife", s.actor:position(), s.actor:id())
	SendScriptCallback("actor_on_first_update")
	db.actor = nil
	s.tick(1000)
	db.actor = s.actor
	s.tick(1000)
	assert(not s.actor:object("ammo_knife"), "missing actor must not consume the cleanup event")
end)

test("hostplay: early installation and repeated start preserve one callback and widget", function()
	local s = fixture("hostplay", false, true)
	s.live, s.material = true, "materials\\water"
	coop_mods_start_guard.on_game_start()
	SendScriptCallback("actor_on_update", s.actor, 100)
	assert(s.hits == 1, "one water hit per update after repeated start")
	ImGui.Groups.Debug.Render()
	assert(not s.menus.LuaDebug, "existing widget remains blocked")
end)

test("client: load before actor exists clears stale water on first dry update", function()
	local s = fixture("client")
	save_var(s.actor, "grw_in_water", true)
	db.actor = nil
	SendScriptCallback("load_state", {})
	db.actor, s.live = s.actor, true
	SendScriptCallback("actor_on_update", s.actor, 100)
	assert(s.hits == 0 and load_var(s.actor, "grw_in_water") ~= true, "late actor must not keep loaded flag")
end)

test("hostplay: widget chain preserves registration results and call arguments", function()
	local s = fixture("hostplay", false, false, true)
	local register = ImGui.Groups.Widget
	ImGui.Groups.Widget = function(...)
		register(...)
		return "registered", nil, 3
	end
	-- Install after another adapter has already chained the registrar.
	load_script("coop_mods_start_guard").on_game_start()
	local got
	local a, b, c = ImGui.Groups.Widget("Arguments", function(...)
		got = { n = select("#", ...), ... }
		return "widget", nil, 7
	end)
	assert(a == "registered" and b == nil and c == 3, "registrar result arity must survive")
	local x, y, z = ImGui.Groups.Arguments._widgets[1](11, nil, 22)
	assert(got.n == 3 and got[1] == 11 and got[3] == 22 and x == "widget" and y == nil and z == 7,
		"widget arguments and results must survive")
end)

test("hostplay: one failed installer does not skip water or widgets", function()
	local s = fixture("hostplay", false, false, true)
	local mod = coop_mods_core.mod
	coop_mods_core.mod = function(name)
		if name == "grok_remove_knife_ammo_on_start" then error("test installer failure") end
		return mod(name)
	end
	load_script("coop_mods_start_guard").on_game_start()
	s.live, s.material = true, "materials\\water"
	-- Call the patched module directly: callbacks were already tested above.
	s.water.actor_on_update(s.actor, 100)
	ImGui.Groups.Debug.Render()
	assert(s.hits == 1 and not s.menus.LuaDebug, "independent installers continue after failure")
	assert(log_has("test installer failure"), "startup error must be reported")
end)

for _, role in ipairs({ "srv_map", "srv_world" }) do
	test(role .. ": actor-local cleanup and water ignore a non-player actor", function()
		local s = fixture(role)
		s.live, s.acknowledge, s.material = true, true, "materials\\water"
		spawn("ammo_knife", s.actor:position(), s.actor:id())
		save_var(s.actor, "grw_in_water", true)
		SendScriptCallback("actor_on_first_update")
		s.tick(1000)
		SendScriptCallback("actor_on_update", s.actor, 100)
		assert(s.attempts == 0 and s.hits == 0 and s.probes == 0, "no local player exists on this process")
	end)
	test(role .. ": LuaDebug route none is respected", function()
		local s = fixture(role)
		ImGui.Groups.Debug.Render()
		assert(not s.menus.LuaDebug and s.debugger == 0, "none must apply on an authority too")
	end)
end

test("none: cleanup, saved water and widgets retain stock behaviour", function()
	local s = fixture("none")
	spawn("ammo_knife", s.actor:position(), s.actor:id())
	SendScriptCallback("actor_on_first_update")
	s.tick(1000)
	assert(s.attempts == 2, "single player keeps the two original passes even without Live")
	save_var(s.actor, "grw_in_water", true)
	SendScriptCallback("load_state", {})
	SendScriptCallback("actor_on_update", s.actor, 100)
	assert(load_var(s.actor, "grw_in_water") == true and s.hits == 1 and s.probes == 0, "stock persisted water outside session")
	ImGui.Groups.Debug.Render()
	assert(s.menus.LuaDebug == 1 and s.debugger == 1, "stock debugger outside session")
end)

print(string.format("mods_start_guard: %d passed, %d failed", passed, failed))
if failed > 0 then error("mods_start_guard FAILED") end
