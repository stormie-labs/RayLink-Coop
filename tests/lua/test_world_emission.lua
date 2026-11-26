-- World parity sound L2 (coop_env.script): a client that joins during an emission does not get every past stage at once.
-- Real coop_env.script over a stand-in of the stock stages. Run: tools\test_lua.cmd world_emission
MODE = "client"
dofile("tests/lua/support/stubs.lua")

local PLAYED = {}

local function elapsed(m)
	return math.ceil(game.get_game_time():diffSec(m.inited_time) / level.get_time_factor())
end

-- The stage order of surge_manager.update: `at` seconds in, once per stages[name].
local SURGE_STAGES = { { "beginning", 0 }, { "siren", 25 }, { "impact", 47 }, { "rumble", 50 }, { "quake20", 80 }, { "quake40", 100 },
	{ "quake60", 102 }, { "quake80", 104 }, { "quake100", 106 }, { "1stwavesnd", 108 }, { "1stwave", 120 }, { "2ndwavesnd", 156 },
	{ "2ndwave", 168 } }
local CSurge = {}
CSurge.__index = CSurge
function CSurge:initialize() self.surge_time = 222 end
function CSurge:finalize() end
function CSurge:update()
	local d = elapsed(self)
	for _, s in ipairs(SURGE_STAGES) do
		if d >= s[2] and self.stages[s[1]] == nil then
			self.stages[s[1]] = true
			PLAYED[#PLAYED + 1] = s[1]
		end
	end
end
function CSurge:end_surge() self.started = false end
for _, n in ipairs({ "launch_rockets", "kill_crows_at_pos", "turn_to_zombie", "explode", "kill_actor_at_pos", "kill_all_unhided",
	"give_surge_hide_task", "init_surge_covers", "kill_objects_at_pos" }) do
	CSurge[n] = function() end
end
CSurge.pos_in_cover = function() return false end
local sm = setmetatable({ _state_loaded = true, started = false }, CSurge)
sm:initialize()
surge_manager = { CSurgeManager = CSurge, get_surge_manager = function() return sm end }

local CPsi = {}
CPsi.__index = CPsi
function CPsi:initialize() self.psi_storm_duration = 254 end
function CPsi:finalize() end
function CPsi:update()
	local d = elapsed(self)
	if d >= 0 and self.stages.beginning == nil then
		self.stages.beginning = true
		PLAYED[#PLAYED + 1] = "psi_beginning"
	end
	if d >= 10 and self.stages.siren == nil then
		self.stages.siren = true
		PLAYED[#PLAYED + 1] = "psi_siren"
	end
end
function CPsi:finish() self.started = false end
for _, n in ipairs({ "launch_rockets", "kill_crows_at_pos", "give_psi_storm_hide_task", "kill_objects_at_pos" }) do
	CPsi[n] = function() end
end
local pm = setmetatable({ _state_loaded = true, started = false }, CPsi)
pm:initialize()
psi_storm_manager = { CPsiStormManager = CPsi, get_psi_storm_manager = function() return pm end }

dofile("tests/lua/support/modes.lua").live(load_script_file("coop_mode"))
load_coop_main()
coop_main.on_game_start()
coop_env.on_game_start()
coop_route.on_game_start() -- the tick service runs the emission tick
TF = 10

local function tick(seconds)
	NOW = NOW + seconds * 1000
	SendScriptCallback("actor_on_update")
end
local function host_state(t) coop_main.on_event("coop_env", coop_main.encode(t), 0) end
local function played(name)
	for _, n in ipairs(PLAYED) do
		if n == name then return true end
	end
	return false
end

print("== joining at second 130 of the emission")
host_state({ s = true, sg = 1300, p = false, pg = 0, tf = 10, c = false })
tick(1)
check(sm.started == true, "the mirror runs")
for _, name in ipairs({ "beginning", "siren", "impact", "1stwavesnd", "1stwave" }) do
	check(not played(name), name .. ": over before this player came, not played now")
end
check(not played("quake20") and not played("quake100"), "the quake is coop_env's own ladder, not the stock's stages")
check(played("rumble"), "the rumble that is on now is started")
check(not played("2ndwavesnd"), "what is still to come stays to come")
host_state({ s = true, sg = 1570, p = false, pg = 0, tf = 10, c = false })
tick(1)
check(played("2ndwavesnd"), "and plays at its moment")

print("== from the start")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
PLAYED = {}
host_state({ s = true, sg = 10, p = false, pg = 0, tf = 10, c = false })
tick(1)
check(played("beginning"), "a client there from the start gets the beginning")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)

print("== psi storm")
PLAYED = {}
host_state({ s = false, sg = 0, p = true, pg = 600, tf = 10, c = false })
tick(1)
check(pm.started == true and not played("psi_beginning") and not played("psi_siren"), "joining a minute in: no beginning, no siren")

print(string.format("%d passed, %d failed", PASSES, FAILS))
