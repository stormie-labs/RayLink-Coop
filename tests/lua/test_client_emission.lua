-- Anomaly Coop (F0, review R5 I2): a client mirrors the host's emission / psi-storm and never decides on its own
-- when they end or start again.
-- The stock surge_manager.update() ends the emission by itself once the elapsed seconds reach surge_time (psi storm:
-- psi_storm_duration). The mirror's clock is extrapolated, so it can get there before the host's "ended" state arrives;
-- then the stock end_surge() runs on the client (statistic +5 rank, "emission_end"), the next tick sees "the host says
-- running, mine is not" and starts a new mirror (more events, more rank), and so on every cycle until the host ends it.
-- launch_rockets() (signal lights) was not disabled on the client either (the psi storm calls it unconditionally).
-- Real coop_main.script; the stock managers are stand-ins that keep the stock end/launch logic (line refs below).
-- Not shipped. Run: tools\test_lua.cmd client_emission
MODE = "client"
dofile("tests/lua/support/stubs.lua")

-------------------------------------------------------------------------------
-- stock stand-ins
-------------------------------------------------------------------------------
STAT = { emissions = 0, psi_storms = 0 }
RANK = 0
-- game_statistics.script:112: ["emissions"] = { rank = 5 }; increment_statistic adds that rank to the actor
game_statistics = {
	increment_statistic = function(name)
		STAT[name] = (STAT[name] or 0) + 1
		if name == "emissions" then RANK = RANK + 5 end
	end,
}
CALLS = { surge_end = 0, psi_finish = 0 }
ROCKETS = { surge = 0, psi = 0 }
EVENTS = {}

local function stock_class()
	local c = {}
	c.__index = c
	return c
end

local function elapsed(m)
	return math.ceil(game.get_game_time():diffSec(m.inited_time) / level.get_time_factor())
end

-- surge_manager.script: initialize L153 (surge_time = 222), update L601-606 (end when diff_sec >= surge_time),
-- end_surge L306-319, launch_rockets L1160
local CSurge = stock_class()
function CSurge:initialize() self.surge_time = 222 end
function CSurge:finalize() end
function CSurge:update()
	local diff_sec = elapsed(self)
	if diff_sec >= self.surge_time then
		self:end_surge()
		return
	end
	if diff_sec >= 30 and self.task_given ~= true then self:launch_rockets() end
end
function CSurge:end_surge()
	CALLS.surge_end = CALLS.surge_end + 1
	if self.started == true then
		game_statistics.increment_statistic("emissions")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "emissions")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "emission_end")
	end
	self.started = false
end
function CSurge:launch_rockets() ROCKETS.surge = ROCKETS.surge + 1 end
function CSurge:kill_objects_at_pos() end
function CSurge:kill_crows_at_pos() end
function CSurge:turn_to_zombie() end
function CSurge:explode() end
function CSurge:kill_actor_at_pos() end
function CSurge:kill_all_unhided() end
function CSurge:give_surge_hide_task() end
function CSurge:pos_in_cover() return false end
function CSurge:init_surge_covers() end
local surge_instance = setmetatable({ _state_loaded = true, started = false }, CSurge)
surge_instance:initialize() -- the game initialises the singleton once at load: surge_time = 222
surge_manager = { CSurgeManager = CSurge, get_surge_manager = function() return surge_instance end }

-- psi_storm_manager.script: initialize L39-69 (psi_storm_duration = 254), update L298-302 (finish when
-- diff_sec >= psi_storm_duration), siren stage L325-328 calls launch_rockets, finish L195-208
local CPsi = stock_class()
function CPsi:initialize() self.psi_storm_duration = 254 end
function CPsi:finalize() end
function CPsi:update()
	local diff_sec = elapsed(self)
	if diff_sec >= self.psi_storm_duration then
		self:finish()
		return
	end
	if diff_sec >= 10 and not self.sirened then
		self.sirened = true
		self:launch_rockets()
	end
end
function CPsi:finish()
	CALLS.psi_finish = CALLS.psi_finish + 1
	if self.started then
		game_statistics.increment_statistic("psi_storms")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "psi_storms")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "psi_storm_end")
	end
	self.started = false
	self.sirened = nil
end
function CPsi:launch_rockets() ROCKETS.psi = ROCKETS.psi + 1 end
function CPsi:kill_objects_at_pos() end
function CPsi:kill_crows_at_pos() end
function CPsi:give_psi_storm_hide_task() end
local psi_instance = setmetatable({ _state_loaded = true, started = false }, CPsi)
psi_instance:initialize() -- psi_storm_duration = 254
psi_storm_manager = { CPsiStormManager = CPsi, get_psi_storm_manager = function() return psi_instance end }

-------------------------------------------------------------------------------
print("== client_never_ends_emission")
load_coop_main()
-- "actor_effects" is an owner-domain script: its callbacks run on a client
local observer = from_script("actor_effects", [[return function(typ, obj, name)
	if typ == "anomalies" then EVENTS[name] = (EVENTS[name] or 0) + 1 end
end]])
RegisterScriptCallback("actor_on_interaction", observer)
coop_main.on_game_start()

local sm = surge_manager.get_surge_manager()
local pm = psi_storm_manager.get_psi_storm_manager()

local function tick(seconds)
	NOW = NOW + seconds * 1000
	SendScriptCallback("actor_on_update")
end
local function host_state(t)
	coop_main.on_event("coop_env", coop_main.encode(t), 0)
end

-- the client already runs at the host's time factor (10): 1 real second = 10 game seconds = 1 stock "diff_sec"
TF = 10

-- 1. emission: the host reports it 215 stock seconds in (2150 game s); stock ends at 222
host_state({ s = true, sg = 2150, p = false, pg = 0, tf = 10, c = false })
tick(1)
check(sm.started == true, "emission mirror started by the host state")
check(EVENTS.emission_start == 1, "emission_start comes once, from the host's start")
for _ = 1, 12 do tick(1) end -- the extrapolated clock passes 222 after 7 more seconds; the host still says 'running'
check(sm.started == true, "emission mirror still running 12 s past the stock end (the host decides)")
check(CALLS.surge_end == 0, "the stock end_surge() was never called by the client itself")
check(EVENTS.emission_start == 1, "no restart of the emission on the client (emission_start still 1)")
check(EVENTS.emission_end == nil, "no emission_end before the host ends it")
check(RANK == 0 and STAT.emissions == 0, "no rank / statistic for a cycle the host has not finished (rank " .. RANK .. ")")
sm:launch_rockets()
check(ROCKETS.surge == 0, "surge launch_rockets is an empty wrapper on the client")

-- the host ends the emission: exactly one end, one rank award
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(sm.started == false, "emission mirror ended by the host")
check(CALLS.surge_end == 1 and EVENTS.emission_end == 1, "one emission_end, from the host's end")
check(RANK == 5 and STAT.emissions == 1, "rank +5 once for the cycle (rank " .. RANK .. ")")
for _ = 1, 4 do tick(1) end
check(sm.started == false and EVENTS.emission_start == 1 and CALLS.surge_end == 1,
	"after the host's end the client does not start a new emission")

-- 2. psi storm: 245 stock seconds in (2450 game s); stock ends at 254, calls launch_rockets from second 10
TF = 10
host_state({ s = false, sg = 0, p = true, pg = 2450, tf = 10, c = false })
tick(1)
check(pm.started == true, "psi-storm mirror started by the host state")
check(EVENTS.psi_storm_start == 1, "psi_storm_start comes once, from the host's start")
check(ROCKETS.psi == 0, "psi-storm launch_rockets is not called on the client")
for _ = 1, 12 do tick(1) end -- passes 254 after 9 more seconds
check(pm.started == true and CALLS.psi_finish == 0, "psi-storm mirror still running past the stock end (the host decides)")
check(EVENTS.psi_storm_end == nil and STAT.psi_storms == 0, "no psi_storm_end / statistic before the host ends it")
check(EVENTS.psi_storm_start == 1, "no restart of the psi storm on the client")
pm:launch_rockets()
check(ROCKETS.psi == 0, "psi-storm launch_rockets is an empty wrapper on the client")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(pm.started == false and CALLS.psi_finish == 1 and EVENTS.psi_storm_end == 1, "psi storm ended once, by the host")
for _ = 1, 3 do tick(1) end
check(pm.started == false and EVENTS.psi_storm_start == 1 and CALLS.psi_finish == 1,
	"after the host's end the client does not start a new psi storm")

-- the stand-ins must not have hidden a failure: none of the mirror steps raised a Lua error
local mirror_errors = {}
for _, line in ipairs(LOG) do
	if line:find("lua error", 1, true) and (line:find("emission", 1, true) or line:find("psi-storm", 1, true)) then
		mirror_errors[#mirror_errors + 1] = line
	end
end
check(#mirror_errors == 0, "no Lua error inside the emission / psi-storm mirror (" .. (mirror_errors[1] or "") .. ")")

print(string.format("%d passed, %d failed", PASSES, FAILS))
