-- Dev 57 S5: the world owns the outdoor forecast and one emission clock.
local modes = dofile("tests/lua/support/modes.lua")
local forecast, writes
local maps = { [1] = "l01_escape", [2] = "l02_garbage", [3] = "l03u_agr_underground" }
local bridges = { 257, 258 }

local function start(role, map)
	local passed, failed = PASSES, FAILS
	MODE = (role == "world" or role == "hostplay") and "host" or "client"
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passed or 0, failed or 0
	NPC_KILLS = 0
	local dedicated = role == "world"
	local map_server = role == "map"
	coop.is_dedicated = function() return dedicated end
	coop.is_map_server = function() return map_server end
	coop.is_mirror = function() return role == "player" end
	coop.levels = {
		split = function() return role ~= "hostplay" end,
		map_servers = function() return { { bridge = bridges[1] }, { bridge = bridges[2] } } end,
		level_of_player = function(peer) return peer end,
		level_name = function(id) return maps[id] end,
		bridge_of_player = function(peer) return bridges[peer] end,
	}
	coop.players = function()
		local list = {}
		for i = 1, 2 do list[i] = { id = i } end
		return list
	end
	coop.sync = {
		get = function(scope, key)
			if scope == "session" and key == "world.weather" then return forecast end
		end,
		set = function(scope, key, value)
			assert(dedicated or role == "hostplay", "only the world writes weather")
			if scope == "session" and key == "world.weather" then forecast, writes = value, writes + 1 end
			return true
		end,
	}
	local open = map == maps[1] or map == maps[2]
	local wm = {
		weatherType = open and "atmosfear" or "indoor",
		weather_file = open and "clear_1" or "indoor",
		cycle = "clear", preset = "clear_1",
	}
	local cls = {}
	cls.__index = cls
	local selected = 0
	local sky, forced
	level.name = function() return map end
	level.get_time_hours = function() return 12 end
	level.rain_wetness = function() return 0 end
	level.set_weather = function(file, now) sky, forced = file, now end
	function cls:set_brightness_boosts() end
	function cls:change_period() self.pre_blowout_period = true end
	function cls:select_weather(now)
		selected = selected + 1
		if self.weatherType == "atmosfear" and self.pre_blowout_period then
			self.levelWeather = "atmosfear_pre_blowout"
			self.weather_file = "pre_blowout_" .. map
			self.pre_blowout_period = false
		elseif self.weatherType == "atmosfear" then
			self.levelWeather, self.weather_file = "atmosfear_clear", self.preset
		else
			self.levelWeather, self.weather_file = "indoor", "indoor"
		end
		level.set_weather(self.weather_file, now)
	end
	level_weathers = {
		valid_levels = { [maps[1]] = true, [maps[2]] = true },
		WeatherManager = cls, get_weather_manager = function() return wm end,
	}
	function CSurge:start()
		if level_weathers.valid_levels[level.name()] then
			self.inited_time, self.started, self.surge_time = game.get_game_time(), true, 222
		end
	end
	coop_mode = load_script_file("coop_mode")
	coop_trust = load_script_file("coop_trust")
	coop_trust.reset_for_test({ default = "log" })
	load_coop_main()
	coop_main.on_game_start()
	coop_env.on_game_start()
	coop_route.on_game_start() -- the tick service runs the emission tick
	modes.live(coop_mode)
	load_script_file("coop_npc_players")
	load_script_file("coop_world_weather").on_game_start()
	load_script_file("coop_srv_world").on_game_start()
	return setmetatable(wm, cls), surge_manager.get_surge_manager(), function() return sky, selected, forced end
end

local function tick(ms)
	NOW, GAME_MS = NOW + ms, GAME_MS + ms * TF
	SendScriptCallback("actor_on_update")
end

local function phase_each(targets)
	local messages = {}
	for _, msg in ipairs(SENT) do
		if msg.name == "coop_env" then messages[msg.target] = msg.payload end
	end
	for _, target in ipairs(targets) do
		if not messages[target] then return end
	end
	return messages
end

forecast, writes = nil, 0
local wm, sm = start("world", "fake_start")
wm:change_period()
wm:select_weather(false)
sm:start()
tick(1100)
local pre_blowout = "pre_blowout_fake_start"
check(forecast and forecast.lw == "atmosfear_pre_blowout" and forecast.f == pre_blowout,
	"world_service_map_selects_an_outdoor_forecast")
check(wm.weatherType == "indoor", "world_keeps_its_service_map_type")

local targets = { 1, 2, bridges[1], bridges[2] }
local phases = phase_each(targets)
local first = phases and coop_main.decode(phases[1])
check(first and first.s and first.sg > 0 and phases[1] == phases[2] and phases[257] == phases[258]
	and coop_main.decode(phases[257]).sg == first.sg, "world_sends_one_start_clock_to_both_levels")
SENT = {}
tick(222000)
sm:update()
tick(1100)
local ends = phase_each(targets)
check(ends and not coop_main.decode(ends[1]).s and ends[1] == ends[2] and ends[257] == ends[258],
	"world_sends_one_end_to_both_levels")

for i = 1, 2 do
	local sky
	wm, sm, sky = start("map", maps[i])
	if phases then coop_main.on_event("coop_env", phases[bridges[i]], 0) end
	tick(1100)
	check(sm.started and NPC_KILLS == 1, "map_" .. i .. "_runs_the_world_emission_locally")
	wm:select_weather(false) -- stock hour roll between world snapshots
	local file, selections = sky()
	check(file == pre_blowout and wm.weather_file == pre_blowout and selections == 0,
		"map_" .. i .. "_applies_the_world_preset_without_rerolling")
	level.is_wfx_playing = function() return true end
	wm:select_weather(true)
	local _, _, forced = sky()
	check(forced == false, "map_" .. i .. "_does_not_interrupt_the_running_weather_effect")
	if ends then coop_main.on_event("coop_env", ends[bridges[i]], 0) end
	tick(1100)
	check(not sm.started, "map_" .. i .. "_ends_the_world_emission")
	local player_weather
	player_weather, sm = start("player", maps[i])
	if phases then coop_main.on_event("coop_env", phases[i], 0) end
	tick(1100)
	check(first and sm.started and GAME_MS - sm.inited_time.ms == math.floor(first.sg + 1100 * first.tf / 1000) * 1000,
		"player_" .. i .. "_mirrors_the_world_clock")
	check(player_weather.weather_file == pre_blowout, "player_" .. i .. "_uses_the_world_outdoor_forecast")
	if ends then coop_main.on_event("coop_env", ends[i], 0) end
	tick(1100)
	check(not sm.started, "player_" .. i .. "_ends_the_world_emission")
end
check(writes == 1, "only_the_world_publishes_the_forecast")

local sky
wm, sm, sky = start("map", maps[3])
wm:select_weather(true)
tick(1100)
local indoor_file, selections = sky()
check(indoor_file == "indoor" and wm.weather_file == "indoor" and selections == 1,
	"indoor_map_keeps_its_own_weather")
wm, sm = start("player", maps[3])
if phases then coop_main.on_event("coop_env", phases[1], 0) end
tick(1100)
check(wm.weather_file == "indoor" and not sm.started, "indoor_player_keeps_local_weather_and_skips_emission")

wm, sm, sky = start("hostplay", maps[1])
wm:change_period()
wm:select_weather(false)
check(sky() == "pre_blowout_" .. maps[1] and wm.weatherType == "atmosfear", "coop_host_keeps_stock_weather_selection")

forecast, writes = nil, 0
wm = start("world", "fake_start")
tick(1100)
check(forecast and forecast.f == "clear_1", "world_publishes_outdoor_weather_before_the_first_hourly_roll")

print(string.format("%d passed, %d failed", PASSES, FAILS))
