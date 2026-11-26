-- Emission cover on the co-op host, the player's map server, and the world relay.
local modes = dofile("tests/lua/support/modes.lua")

local function start(role, trust_mode)
	MODE = role == "srv_map" and "client" or "host"
	dofile("tests/lua/support/stubs.lua")
	coop_mode, coop_srv_world = nil, nil
	local map_server = role == "srv_map"
	coop.is_map_server = function() return map_server end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.levels = { split = function() return role ~= "hostplay" end,
		bridge_of_player = function(peer) return peer == 1 and 257 end }
	level.name = function() return "l02_garbage" end
	level_weathers = { valid_levels = { l02_garbage = true } }
	local body = { id = function() return 500 end, alive = function() return true end,
		position = function() return PROXY_POS end }
	level.object_by_id = function(id) if id == 500 then return body end end
	coop.peer_of_avatar = function(id) if id == 500 then return 1 end end
	coop.players = function()
		return { { id = 1, nick = "player %s", avatar_id = 500, level = 2 } }
	end
	if map_server then coop.self_id = function() return 257 end end
	db.zone_by_name = { shelter = { inside = function(_, pos) return pos.cover == true end } }
	local sm = surge_manager.get_surge_manager()
	sm.covers = { shelter = true }
	function CSurge:update() end -- the test controls the stock kill moment
	load_coop_main()
	load_script_file("coop_mode")
	modes.live(coop_mode)
	load_script_file("coop_trust").reset_for_test({ default = "log", env_cover = trust_mode })
	load_script_file("coop_mods_core")
	load_script_file("coop_env_cover")
	load_script_file("coop_srv_world").on_game_start()
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick
	return sm
end

local function report(role, covered)
	local relay = role == "srv_map"
	coop_main.on_event("coop_env_cover", coop_main.encode({ c = covered, peer = relay and 1 or 99 }), relay and 0 or 1)
end

local function tick(ms)
	NOW = NOW + ms
	SendScriptCallback("actor_on_update")
end

local function phase(role, sm)
	if role == "srv_map" then
		coop_main.on_event("coop_env", coop_main.encode({ s = true, sg = 30, tf = 6, c = true }), 0)
	else
		sm.started, sm.inited_time = true, game.get_game_time()
	end
	tick(250)
end

local function sent(name, target)
	for _, row in ipairs(SENT) do
		if row.name == name and row.target == target then return coop_main.decode(row.payload) end
	end
end

local passed, failed = 0, 0
local function collect()
	passed, failed = passed + PASSES, failed + FAILS
end

for _, role in ipairs(modes.names()) do
	if role == "hostplay" or role == "srv_map" then
		print("== " .. role .. " emission cover")
		for _, mode in ipairs({ "log", "refuse" }) do
			local sm = start(role, mode)
			local scans, scan = 0, coop_env_cover.tick
			coop_env_cover.tick = function(peer, body) scans = scans + 1; return scan(peer, body) end
			report(role, true)
			phase(role, sm)
			sm:kill_all_unhided()
			local covered, age, source
			if coop_env_cover.cover_of then covered, age, source = coop_env_cover.cover_of(500) end
			check(covered == (mode == "log") and age == (mode == "log" and 250 or 0)
				and source == (mode == "log" and "report" or "none"),
				mode .. ": accessor exposes the effective decision and the age of its evidence")
			check((sent("coop_env_kill", 1) == nil) == (mode == "log"), mode .. ": kill follows the effective decision")
			if role == "hostplay" then
				local state = sent("coop_env", 1)
				check(state and state.c == (mode == "log"), mode .. ": phase c follows the effective decision")
			end
			local counter = coop_trust.status().env_cover
			check(counter and counter.failed == 1 and counter.refused == (mode == "refuse" and 1 or 0),
				mode .. ": one failed trust check for the claim")
			local lines = 0
			for _, line in ipairs(LOG) do
				if line:find("player %s claims cover, the level sees none (none, score 0.00)", 1, true)
					and line:find(mode == "log" and "would be refused: let through" or "refused", 1, true) then
					lines = lines + 1
				end
			end
			check(lines == 1, mode .. ": one trust line with a literal nickname and the decider's evidence")
			check(scans == 1, mode .. ": phase publication and kill share one scan budget")
			tick(1000)
			check(scans == 2, mode .. ": active scan runs again one second later")
			coop.peer_of_avatar = function() return nil end
			check(not coop_env_cover.cover_of or coop_env_cover.cover_of(500) == nil,
				mode .. ": the previous decision is unavailable when the body is no longer bound to a player")
			collect()
		end

		local sm = start(role, "refuse")
		PROXY_POS.cover = true
		phase(role, sm)
		sm:kill_all_unhided()
		local covered, age, source
		if coop_env_cover.cover_of then covered, age, source = coop_env_cover.cover_of(500) end
		check(covered == true and age == 0 and source == "static", "no report: static cover decides")
		check(not sent("coop_env_kill", 1), "no report: static cover spares the player")
		report(role, false)
		tick(1000)
		sm:kill_all_unhided()
		check(not sent("coop_env_kill", 1), "negative report cannot override verified static cover")
		collect()

		sm = start(role, "refuse")
		level.object_by_id = function() return nil end
		report(role, true)
		phase(role, sm)
		sm:kill_all_unhided()
		local unchecked = coop_trust.status().env_cover_unchecked
		check(unchecked and unchecked.checked == 1 and not sent("coop_env_kill", 1),
			"no body: honor the report and count it once as unchecked")
		report(role, false)
		sm:kill_all_unhided()
		check(sent("coop_env_kill", 1) ~= nil, "no body: an explicit negative report still exposes the player")
		collect()
	elseif role == "srv_world" then
		local sm = start(role, "refuse")
		report(role, true)
		phase(role, sm)
		local relay = sent("coop_env_cover", 257)
		check(relay and relay.peer == 1 and relay.c == true, "world relays cover with the transport peer")
		check(not coop_trust.status().env_cover and not sent("coop_env_kill", 1), "world does not decide cover")
		collect()
	end
end

print(string.format("%d passed, %d failed", passed, failed))
