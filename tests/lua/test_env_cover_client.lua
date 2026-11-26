-- The local mirror uses the same effective cover for the surge and the psi storm.
local modes = dofile("tests/lua/support/modes.lua")
local passed, failed = 0, 0

local function scenario(server)
	MODE = "client"
	dofile("tests/lua/support/stubs.lua")
	coop.levels = { split = function() return server end }
	coop_mode, coop_srv_world = nil, nil
	local map = "l02_garbage"
	level.name = function() return map end
	level_weathers = { valid_levels = { l02_garbage = true, l03_agroprom = true } }
	db.actor.position = function() return PROXY_POS end
	local psi_cover
	function CPsi:update() psi_cover = GetEvent("current_safe_cover") end
	load_coop_main()
	load_script_file("coop_mode")
	modes.live(coop_mode)
	load_script_file("coop_trust").reset_for_test({ default = "log" })
	load_script_file("coop_mods_core")
	local cover = load_script_file("coop_env_cover")
	if cover.on_game_start then cover.on_game_start() end
	load_script_file("coop_srv_world").on_game_start()
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick

	local function event(name, data, from)
		coop_main.on_event(name, coop_main.encode(data), from or 0)
	end
	local function tick(ms, expected, label)
		local own = GetEvent("current_safe_cover")
		NOW = NOW + ms
		SendScriptCallback("actor_on_update")
		local last = SURGE_LOG[#SURGE_LOG]
		check(last and last.cover == expected, label .. " (surge)")
		check(psi_cover == expected, label .. " (psi storm)")
		check(GetEvent("current_safe_cover") == own, label .. " (local cover restored)")
	end

	SetEvent("current_safe_cover", true)
	event("coop_env", { s = true, p = true, sg = 30, pg = 30, tf = 6, c = false, own = server })
	event("coop_env_verdict", { c = false, s = "none" })
	tick(0, server, "log uses the existing mirror input")
	coop_trust.reset_for_test({ default = "refuse" })
	tick(1000, false, "refuse uses the authority's negative decision")
	event("coop_env_verdict", { c = true, s = "static" }, 7)
	tick(1000, false, "verdict from a peer is ignored")
	event("coop_env_verdict", { c = 1, s = "static" })
	tick(1000, false, "invalid verdict is ignored at the freshness boundary")
	tick(1000, server, "stale verdict falls back to local cover only when own is set")
	event("coop_env_verdict", { c = false, s = "none" })
	map = "l03_agroprom"
	tick(1000, server, "the previous map's verdict is ignored")
	event("coop_env_verdict", { c = true, s = "static" })
	SetEvent("current_safe_cover", false)
	event("coop_env", { s = true, p = true, sg = 30, pg = 30, tf = 6, c = false, own = server })
	tick(1000, server, "own uses the fresh positive verdict; co-op uses c")
	passed, failed = passed + PASSES, failed + FAILS
end

for _, role in ipairs(modes.names()) do
	if role == "hostplay" then scenario(false) end
	if role == "srv_map" then scenario(true) end
end
print(string.format("%d passed, %d failed", passed, failed))
