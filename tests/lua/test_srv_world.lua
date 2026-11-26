-- Dev 57 P-G: real world/environment scripts over the engine harness.
-- Run: tools\test_lua.cmd srv_world
local modes = dofile("tests/lua/support/modes.lua")
local bridge, request = 0x101, "test.level_request"

local function start(role)
	local old_passes, old_fails = PASSES or 0, FAILS or 0
	MODE = (role == "srv_map" or role == "srv_player") and "client" or "host"
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = old_passes, old_fails
	coop_mode = load_script_file("coop_mode")
	coop_trust = load_script_file("coop_trust")
	coop_trust.reset_for_test({ default = "log" })
	coop.is_map_server = function() return role == "srv_map" end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.is_mirror = function() return role == "srv_player" end
	coop.levels = {
		split = function() return role == "srv_world" or role == "srv_map" end,
		level_of_player = function(peer) return peer == 1 and 2 or nil end,
		level_name = function(id) return id == 2 and "l02_garbage" or nil end,
		bridge_of_player = function(peer) return peer == 1 and bridge or nil end,
		map_servers = function() return { { bridge = bridge } } end,
	}
	coop.players = function()
		return {
			{ id = 1, avatar_id = role ~= "srv_world" and 500 or nil, level = 2 },
			{ id = role == "srv_map" and bridge or 0, is_self = true },
		}
	end
	level.name = function() return role == "srv_world" and "fake_start" or "l02_garbage" end
	level_weathers = { valid_levels = { l02_garbage = true } }
	PROXY_POS = { x = 0, y = 0, z = 0, cover = false }
	local reached, seen_stock_map = false, nil
	function CSurge:start()
		seen_stock_map = level.name()
		if self.raise_on_start then error("stock start failed") end
		if level_weathers.valid_levels[level.name()] then
			self.inited_time, self.started = game.get_game_time(), true
			reached = true
		end
	end
	ORIG_KILL_ALL, NPC_KILLS, SURGE_ENDED = 0, 0, 0
	local stock_start = CSurge.start
	load_coop_main()
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick
	if role == "srv_player" then modes.live(coop_mode)
	else modes.install(coop_mode, role) end
	coop_mode.on_game_start()
	load_script_file("coop_srv_world").on_game_start()
	local function observed_start() return reached, seen_stock_map end
	return surge_manager.get_surge_manager(), stock_start, observed_start
end

local function tick(ms)
	NOW = NOW + (ms or 300)
	SendScriptCallback("actor_on_update")
end

local function receive(name, data, from)
	coop_main.on_event(name, coop_main.encode(data), from)
end

local function sent(name, peer)
	for _, msg in ipairs(SENT) do
		if msg.name == name and msg.target == peer then return coop_main.decode(msg.payload) end
	end
end

local function rejected(check_name)
	local c = coop_trust.status()[check_name]
	return c and c.failed or 0
end

print("== hostplay keeps the stock schedule and local level requests")
local sm, stock_start = start("hostplay")
tick()
check(CSurge.start == stock_start, "hostplay_stock_schedule_is_untouched")
check(sent("coop_env", 1) and not sent("coop_env", bridge), "hostplay_phase_stays_on_host_map")
local handled
coop_main.add_level_handler(request, function(_, from) handled = from end)
receive(request, { _peer = 9 }, 1)
check(handled == 1, "hostplay_level_request_keeps_transport_sender")

print("== world server keeps the schedule and relays map traffic")
local observed_start
sm, _, observed_start = start("srv_world")
tick()
sm:start()
local reached, stock_map = observed_start()
check(reached and stock_map == "l02_garbage" and level.name() == "fake_start", "world_schedule_uses_occupied_open_map")
sm.raise_on_start = true
local ok = pcall(sm.start, sm)
check(ok and level.name() == "fake_start", "world_schedule_restores_service_map_after_stock_error")
sm.raise_on_start = false
SENT = {}
tick()
local player_phase, bridge_phase = sent("coop_env", 1), sent("coop_env", bridge)
check(player_phase and player_phase.s and player_phase.own == true
	and bridge_phase and bridge_phase.s and bridge_phase.own == nil, "world_phase_reaches_player_and_map")
sm.surge_time = 222
GAME_MS = GAME_MS + sm.surge_time * TF * 1000
sm:update()
check(not sm.started and SURGE_ENDED == 1, "world_schedule_ends_without_updating_service_map_effects")

SENT = {}
receive("coop_env_cover", { c = true, peer = 9 }, 1)
local cover = sent("coop_env_cover", bridge)
check(cover and cover.c and cover.peer == 1, "world_cover_relay_overwrites_claimed_sender")
SENT = {}
receive("coop_env_npc_kill", { k = "s", z = math.huge }, 1)
check(#SENT == 0 and rejected("env_npc_kill_payload") == 1, "world_rejects_unbounded_wave_before_relay")
receive("coop_env_cover", { c = "true" }, 1)
check(#SENT == 0 and rejected("env_cover_payload") == 1, "world_rejects_invalid_cover_before_relay")

handled, SENT = nil, {}
coop.levels.bridge_of_player = function() error("routing belongs to the facade") end
coop_main.add_level_handler(request, function(_, from) handled = from end)
receive(request, { _peer = 9, item = 12 }, 1)
local relay = sent(request, bridge)
check(not handled and relay and relay._peer == 1 and relay.item == 12, "world_level_request_uses_mode_facade")

print("== map server follows phase and authenticates the relay")
sm = start("srv_map")
receive("coop_env", { s = true, sg = 30, tf = 6, c = true }, 0)
tick()
check(sm.started and NPC_KILLS == 1, "map_phase_runs_stock_consequences")
check(sent("coop_env_kill", 1) and not sent("coop_env_kill", bridge), "map_verdict_targets_the_exposed_player")
SENT = {}
receive("coop_env", { s = false, tf = 6 }, 0)
tick()
receive("coop_env_cover", { c = true, peer = 1 }, 0)
receive("coop_env", { s = true, sg = 30, tf = 6, c = true }, 0)
tick()
check(not sent("coop_env_kill", 1), "map_fresh_cover_report_spares_the_player")
local kills = NPC_KILLS
receive("coop_env_npc_kill", { k = "s", z = 5, peer = 1 }, 1)
check(NPC_KILLS == kills and rejected("env_map_relay") == 1, "map_refuses_direct_player_relay")
receive("coop_env_npc_kill", { k = "s", z = 5 }, 0)
check(NPC_KILLS == kills and rejected("env_map_relay") == 2, "map_refuses_relay_without_player")
receive("coop_env_npc_kill", { k = "s", z = 5, peer = 1 }, 0)
check(NPC_KILLS == kills + 1, "map_runs_wave_relay_from_world")
handled = nil
coop_main.add_level_handler(request, function(_, from) handled = from end)
receive(request, { _peer = 1, item = 12 }, 0)
check(handled == 1, "map_level_request_runs_as_relayed_player")

print("== a server player learns the map rules on joining")
sm = start("srv_player")
receive("coop_env", { s = true, sg = 30, tf = 6, c = true }, 0)
tick()
check(sm.started, "server_player_mirrors_phase_before_first_level_map")
level.name = function() return "l11_hospital" end
level_weathers.valid_levels.l11_hospital = true
SetEvent("surge", "state", true)
coop.levels.split = function() return true end
tick(1500)
check(not sm.started and GetEvent("surge", "state") == false, "server_player_clears_phase_on_excluded_map")

print(string.format("%d passed, %d failed", PASSES, FAILS))
