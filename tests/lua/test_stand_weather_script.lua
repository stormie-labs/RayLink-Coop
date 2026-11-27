-- The weather_server probe measures the emission only after the player's process has its map's online set and runs on.
local path = "tools/stand/coop_zz_weather.script"
local passed, failed = 0, 0

local function check(ok, name)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print("FAIL " .. name)
	end
end

local function vec(x, y, z)
	return {
		x = x or 0, y = y or 0, z = z or 0,
		set = function(self, a, b, c) self.x, self.y, self.z = a, b, c; return self end,
		distance_to = function(self, o)
			return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2)
		end,
	}
end

local CHANGER_CLS = 77

local function fixture()
	local f = { log = {}, now = 0, exit = false, state = nil }
	local actor = { position = function() return vec(0, 0, 0) end, set_actor_position = function() end }
	local changer = { clsid = function() return CHANGER_CLS end, position = function() return vec(30, 0, 0) end }
	local friend = { id = 2, nick = "weathermove", is_self = false }
	local wm = { weatherType = "atmosfear", weather_file = "w_cloudy2_dark" }
	local sm = { started = false }
	local env = setmetatable({
		command_line = function() return "-coop_probe weatherstay" end,
		RegisterScriptCallback = function(event, callback)
			assert(event == "actor_on_update")
			f.update = callback
		end,
		time_global = function() return f.now end,
		printf = function(fmt, ...) f.log[#f.log + 1] = string.format(fmt, ...) end,
		get_console = function() return { execute = function() end } end,
		db = { actor = actor, storage = {} },
		vector = vec,
		clsid = { level_changer = CHANGER_CLS, level_changer_s = CHANGER_CLS + 1 },
		level = {
			name = function() return "k00_marsh" end,
			object_by_id = function(id) return f.exit and id == 500 and changer or nil end,
			get_weather = function() return wm.weather_file end,
		},
		coop = {
			is_live = function() return true end,
			players = function() return { friend } end,
			stash_get = function() end,
			stash_set = function() return true end,
			levels = {
				level_of_player = function() return 3 end,
				level_name = function() return "l01_escape" end,
			},
			sync = { get = function() return f.state end },
		},
		coop_mode = {
			is_player_mirror = function() return true end,
			where = function() return "away" end,
		},
		level_weathers = {
			get_weather_manager = function() return wm end,
			valid_levels = { k00_marsh = true, l01_escape = true },
		},
		surge_manager = { get_surge_manager = function() return sm end },
	}, { __index = _G })
	env._G = env
	local chunk, err = loadfile(path)
	assert(chunk, "probe missing or invalid: " .. tostring(err))
	setfenv(chunk, env)()
	env.on_game_start()
	f.env = env
	return f
end

local function has(f, literal)
	return table.concat(f.log, "\n"):find(literal, 1, true) ~= nil
end

-- Frames of `dt` ms for `ms` ms.
local function run_frames(f, ms, dt)
	local until_ms = f.now + ms
	while f.now < until_ms do
		f.now = f.now + (dt or 100)
		f.update()
	end
end

local function run(name, fn)
	local ok, err = pcall(fn)
	if not ok then check(false, name .. " (" .. tostring(err) .. ")") end
end

run("not_settled_before_the_online_set", function()
	local f = fixture()
	run_frames(f, 20000)
	check(has(f, "ready map=k00_marsh"), "ready_once_the_partner_is_away")
	check(not has(f, "settled"), "no_settled_line_while_no_level_changer_is_online")
	run_frames(f, 26000)
	check(has(f, "FAIL: the online set of k00_marsh never came") and not has(f, "settled"),
		"a_set_that_never_comes_fails_by_name")
end)

run("settled_after_quiet_frames", function()
	local f = fixture()
	f.exit = true
	run_frames(f, 4500, 250)
	check(has(f, "ready map=k00_marsh") and not has(f, "settled"), "not_settled_before_five_quiet_seconds")
	run_frames(f, 7250, 250)
	check(not has(f, "settled"), "not_settled_at_eleven_and_a_half_seconds_after_ready")
	run_frames(f, 500, 250)
	check(has(f, "settled map=k00_marsh"), "settled_at_twelve_seconds_after_ready")
	run_frames(f, 1000, 250)
	check(#f.log == 2, "settled_is_reported_once")
end)

run("a_long_frame_restarts_the_wait", function()
	local f = fixture()
	run_frames(f, 2000)
	f.exit = true -- the online set arrives in one long frame
	f.now = f.now + 6000
	f.update()
	run_frames(f, 4500)
	check(not has(f, "settled"), "the_standstill_does_not_count_as_quiet")
	run_frames(f, 1000)
	check(has(f, "settled map=k00_marsh"), "settled_five_seconds_after_the_standstill")
end)

run("a_long_frame_restarts_the_wait_with_the_exit_already_online", function()
	local f = fixture()
	f.exit = true
	run_frames(f, 100)
	run_frames(f, 4800)
	run_frames(f, 6000, 6000)
	run_frames(f, 1000, 250)
	check(not has(f, "settled"), "not_settled_before_twelve_seconds_after_an_early_standstill")
	run_frames(f, 250, 250)
	check(not has(f, "settled"), "the_arrival_wait_does_not_replace_quiet_after_the_standstill")
	run_frames(f, 3500, 250)
	check(not has(f, "settled"), "not_settled_just_before_five_quiet_seconds_after_the_standstill")
	run_frames(f, 250, 250)
	check(has(f, "settled map=k00_marsh"), "settled_five_quiet_seconds_after_the_early_standstill")
end)

run("growth_in_online_objects_restarts_the_wait", function()
	local f = fixture()
	f.exit = true
	run_frames(f, 100)
	run_frames(f, 10900)
	f.env.db.storage[500] = {}
	run_frames(f, 100)
	run_frames(f, 1000, 250)
	check(not has(f, "settled"), "not_settled_at_twelve_seconds_when_online_objects_are_still_arriving")
	run_frames(f, 3750, 250)
	check(not has(f, "settled"), "not_settled_just_before_five_seconds_after_online_objects_arrive")
	run_frames(f, 250, 250)
	check(has(f, "settled map=k00_marsh"), "settled_five_seconds_after_online_objects_arrive")
end)

run("forecast_is_reported_only_when_settled", function()
	local f = fixture()
	f.state = { lw = "atmosfear_pre_blowout", f = "w_cloudy2_dark" }
	run_frames(f, 2000)
	check(has(f, "ready map=k00_marsh") and not has(f, "forecast map="), "no_forecast_line_before_settled")
	f.exit = true
	run_frames(f, 10200)
	local log = table.concat(f.log, "\n")
	local settled_at, forecast_at = log:find("settled map=", 1, true), log:find("forecast map=k00_marsh", 1, true)
	check(settled_at and forecast_at and settled_at < forecast_at, "forecast_line_follows_the_settled_line")
end)

print(string.format("%d passed, %d failed", passed, failed))
