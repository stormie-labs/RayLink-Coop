-- F5-COV-3: the real emission decision and server mode layers, with transport and map facts stubbed.
local modes = dofile("tests/lua/support/modes.lua")

local function start(role, trust_mode)
	local passed, failed = PASSES, FAILS
	MODE = role == "map" and "client" or "host"
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passed or 0, failed or 0
	coop_mode = nil
	coop.is_map_server = function() return role == "map" end
	coop.is_dedicated = function() return role == "world" end
	coop.self_id = function() return role == "map" and 257 or 0 end
	coop.levels = { split = function() return role ~= "hostplay" end }
	local roster = {
		{ id = coop.self_id(), is_self = true },
		{ id = 1, nick = "outside", level = 2, avatar_id = 501 },
		{ id = 2, nick = "inside", level = 2, avatar_id = 502 },
		{ id = 3, nick = "other map", level = 3, avatar_id = 503, elsewhere = true },
		{ id = 4, nick = "loading", level = 2 },
		{ id = 5, nick = "no map yet" },
		{ id = 6, nick = "no body or report", level = 2 },
	}
	coop.players = function() return roster end
	local positions = { [501] = {}, [502] = { cover = true }, [503] = {} }
	level.object_by_id = function(id)
		if positions[id] then
			return { id = function() return id end, position = function() return positions[id] end,
				alive = function() return true end }
		end
	end
	coop.peer_of_avatar = function(id) return id - 500 end
	level.name = function() return role == "world" and "fake_start" or "l02_garbage" end
	level_weathers = { valid_levels = { l02_garbage = true } }
	db.zone_by_name = { shelter = { inside = function(_, pos) return pos.cover == true end } }
	db.actor.id = function() return 0 end
	db.actor.position = function() return {} end
	local sm = surge_manager.get_surge_manager()
	sm.covers = { shelter = true }
	function CSurge:update() end -- trigger the stock kill hook separately from the phase tick
	load_coop_main()
	load_script_file("coop_mode")
	modes.live(coop_mode)
	load_script_file("coop_trust").reset_for_test({ default = "log", env_cover = trust_mode })
	load_script_file("coop_mods_core")
	load_script_file("coop_env_cover").on_game_start()
	load_script_file("coop_client_binders")
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick
	load_script_file("coop_srv_world").on_game_start()
	load_script_file("coop_srv_env_cover").on_game_start()
	return roster, sm
end

local function tick(ms)
	NOW, GAME_MS = NOW + ms, GAME_MS + ms * TF
	SendScriptCallback("actor_on_update")
end

local function phase(surge, psi)
	coop_main.on_event("coop_env", coop_main.encode({ s = surge, sg = 30, p = psi, pg = 30, tf = TF }), 0)
end

local function report(peer, covered)
	coop_main.on_event("coop_env_cover", coop_main.encode({ c = covered, peer = peer }), 0)
end

local function verdicts()
	local count, by_peer = 0, {}
	for _, msg in ipairs(SENT) do
		if msg.name == "coop_env_verdict" then
			count = count + 1
			by_peer[msg.target] = coop_main.decode(msg.payload)
		end
	end
	return count, by_peer
end

local function is_verdict(t, covered, source)
	return t and t.c == covered and t.s == source
end

print("== srv_env_cover")
local roster, sm = start("map", "log")
phase(false, false)
tick(250)
check(verdicts() == 0, "map_idle_sends_nothing")

report(1, true)
report(4, false)
phase(true, false)
tick(250)
local count, by_peer = verdicts()
check(count == 3 and by_peer[1] and by_peer[2] and by_peer[4], "surge_addresses_only_its_level_players_with_verdicts")
check(is_verdict(by_peer[1], true, "report"), "surge_sends_log_mode_decision_with_report_source")
check(is_verdict(by_peer[2], true, "static"), "surge_sends_static_cover_decision")
check(is_verdict(by_peer[4], false, "report"), "surge_sends_false_report_fallback_while_body_loads")

sm:kill_actor_at_pos(0)
tick(250)
tick(500)
check(verdicts() == count, "map_suppresses_duplicates_from_stock_kill_and_subsecond_frames")
roster[3].level, roster[3].elsewhere = 3, true -- peer 2 left, but its old body is still visible in this process
SENT = {}
tick(250)
count, by_peer = verdicts()
check(count == 2 and by_peer[1] and by_peer[4], "map_sends_the_next_verdicts_at_one_second")
check(not by_peer[2], "departed_peer_keeps_only_its_first_verdict")

phase(false, false)
tick(1000)
check(verdicts() == count, "ended_surge_sends_nothing")

start("map", "refuse")
report(1, true)
phase(false, true)
tick(250)
count, by_peer = verdicts()
check(count == 2 and is_verdict(by_peer[1], false, "none") and is_verdict(by_peer[2], true, "static"),
	"psi_storm_sends_refuse_mode_decision_and_keeps_the_static_cover")

for _, role in ipairs({ "world", "hostplay" }) do
	local _, manager = start(role, "refuse")
	manager.started, manager.inited_time = true, game.get_game_time()
	tick(1000)
	tick(1000)
	check(verdicts() == 0, role .. "_never_sends_map_verdicts")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
