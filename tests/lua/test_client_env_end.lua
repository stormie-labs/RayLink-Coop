-- Anomaly Coop, live 2026-11-08 (Banan4ik, client, G.A.M.M.A., split maps on): "after a psi storm the CLIENT still had the
-- psi-storm bar on screen". The storm ended on the host, the client's mirror ended too (pm.started false), but the
-- storm's HUD flags stayed on for good.
-- The stock writes its "running" flags only inside update(): GAMMA psi_storm_manager.script L297
-- SetEvent("psi_storm", "state", self.started) on every update, L370 "vortex" from a vortex's 18th second, false at L386 from
-- its 23rd; surge_manager.script L606 SetEvent("surge", "state", self.started). finish() (L193-245) and end_surge()
-- (L328-394) never write them. The host and single player keep calling update() every second after the end
-- (surge_manager.script L51-64 main_loop), so the next call writes "state" false. A client calls update() only inside the
-- mirror while the host's phase runs (coop_main client_env_tick); the stock loop is host (coop_route.ltx surge_manager /
-- psi_storm_manager = host). So on a client the flags stayed as the last mirror update left them: true.
-- Their readers run on a client: dynamic_emission_cover_mcm.actor_on_update L129-131 / L144 / L250 (the cover bar: shown
-- while either "state" is on), item_device L774 / L909 (NVG and PDA glitch), item_radio, ui_dosimeter, level_environment.
-- Real coop_main.script; the stock managers are stand-ins that keep the stock's flag writes (line refs above).
-- Not shipped. Run: tools\test_lua.cmd client_env_end
MODE = "client"
dofile("tests/lua/support/stubs.lua")

-------------------------------------------------------------------------------
-- stock stand-ins
-------------------------------------------------------------------------------
STAT = {}
game_statistics = { increment_statistic = function(name) STAT[name] = (STAT[name] or 0) + 1 end }
CALLS = { surge_end = 0, psi_finish = 0 }
EVENTS = {}
HP = 1
PPE_REMOVED = {}
level.remove_pp_effector = function(id) PPE_REMOVED[id] = (PPE_REMOVED[id] or 0) + 1 end
FINISH_RAISES = false

local function stock_class()
	local c = {}
	c.__index = c
	return c
end

local function elapsed(m)
	return math.ceil(game.get_game_time():diffSec(m.inited_time) / level.get_time_factor())
end

-- GAMMA surge_manager.script: update L606 "state" on every update, L696 "time"; end_surge L328-394 leaves both
local CSurge = stock_class()
function CSurge:initialize() self.surge_time = 222 end
function CSurge:finalize() end
function CSurge:update()
	SetEvent("surge", "state", self.started)
	if not self.started then return end
	local diff_sec = elapsed(self)
	if diff_sec >= self.surge_time then
		self:end_surge()
		return
	end
	SetEvent("surge", "time", diff_sec)
end
function CSurge:end_surge()
	CALLS.surge_end = CALLS.surge_end + 1
	if self.started == true then
		game_statistics.increment_statistic("emissions")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "emission_end")
	end
	self.started, self.finished = false, true
end
function CSurge:launch_rockets() end
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
surge_instance:initialize()
surge_manager = { CSurgeManager = CSurge, get_surge_manager = function() return surge_instance end }

-- GAMMA psi_storm_manager.script: update L272-394 (one vortex here: born at 30, flag from 48, hits at 50, flag off at 53),
-- finish L193-245: started/finished first (L200-201), then new_psi_storm_time (L204, reads surge_manager's _delta: nil
-- on a client that never had its surge manager loaded raises there), the vortex table emptied last (L241)
local CPsi = stock_class()
function CPsi:initialize() self.psi_storm_duration = 103 end
function CPsi:finalize() end
function CPsi:update()
	SetEvent("psi_storm", "state", self.started)
	if not self.started then return end
	local diff_sec = elapsed(self)
	if diff_sec >= self.psi_storm_duration then
		self:finish()
		return
	end
	SetEvent("psi_storm", "time", diff_sec)
	if diff_sec >= 30 and not self.vortexes[1] then self.vortexes[1] = { start_time = 30, hit = false } end
	for _, v in pairs(self.vortexes) do
		local life = diff_sec - v.start_time
		if life >= 18 and v.hit == false then SetEvent("psi_storm", "vortex", { x = 1, y = 60, z = 1 }) end
		if life >= 20 and v.hit == false then
			if not GetEvent("current_safe_cover") then self:vortex_actor_hit(v) end
			v.hit = true
		end
		if life >= 23 then SetEvent("psi_storm", "vortex", false) end
	end
end
function CPsi:vortex_actor_hit() HP = HP - 0.1 end
function CPsi:finish()
	CALLS.psi_finish = CALLS.psi_finish + 1
	if self.started then
		game_statistics.increment_statistic("psi_storms")
		SendScriptCallback("actor_on_interaction", "anomalies", nil, "psi_storm_end")
	end
	self.started, self.finished = false, true
	if FINISH_RAISES then error("attempt to perform arithmetic on field '_delta' (a nil value)") end
	self.vortexes = {}
end
function CPsi:launch_rockets() end
function CPsi:kill_objects_at_pos() end
function CPsi:kill_crows_at_pos() end
function CPsi:give_psi_storm_hide_task() end
local psi_instance = setmetatable({ _state_loaded = true, started = false, vortexes = {} }, CPsi)
psi_instance:initialize()
psi_storm_manager = { CPsiStormManager = CPsi, get_psi_storm_manager = function() return psi_instance end }

-- GAMMA dynamic_emission_cover_mcm.actor_on_update L129-131, L144 (activate_hud), L250 (deactivate_hud)
local function cover_bar()
	return (GetEvent("surge", "state") or GetEvent("psi_storm", "state")) and true or false
end

-------------------------------------------------------------------------------
load_coop_main()
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
local function count_log(what)
	local n = 0
	for _, line in ipairs(LOG) do
		if line:find(what, 1, true) then n = n + 1 end
	end
	return n
end
local DISAGREE = "disagrees with the host's"

TF = 10

print("== 1. the host ends a psi storm: the client's storm is over, its HUD too")
host_state({ s = false, sg = 0, p = true, pg = 40 * TF, tf = TF, c = false })
tick(1)
check(pm.started == true and GetEvent("psi_storm", "state") == true, "the mirror runs and writes the stock 'state' flag")
check(cover_bar(), "the cover bar shows during the storm")
for _ = 1, 9 do host_state({ s = false, sg = 0, p = true, pg = (41 + _) * TF, tf = TF, c = false }) tick(1) end
check(GetEvent("psi_storm", "vortex") ~= nil and GetEvent("psi_storm", "vortex") ~= false,
	"a vortex is over the client when the host ends the storm (flag set at 48, cleared by the stock only at 53)")
local hp_at_end = HP
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(pm.started == false and CALLS.psi_finish == 1 and EVENTS.psi_storm_end == 1, "the stock finish ran once, by the host's end")
check(GetEvent("psi_storm", "state") == false, "the 'state' flag is off after the host's end (stuck true before the fix)")
check(not GetEvent("psi_storm", "vortex"), "the 'vortex' flag is off after the host's end")
check(not cover_bar(), "the cover bar is gone after the host's end")
check(PPE_REMOVED[666] == 1 and PPE_REMOVED[667] == 1, "the vortex hit's psi/electro effectors are taken off")
check(count_log("psi-storm ended by the host") == 1, "the end is in the log")
for _ = 1, 30 do
	if _ % 10 == 0 then host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true }) end
	tick(1)
end
check(not cover_bar() and pm.started == false and CALLS.psi_finish == 1, "30 s later: still off, no second finish")
check(HP == hp_at_end, "no hit after the host's end")
check(count_log(DISAGREE) == 0, "a clean end is not reported as a disagreement")

print("== 2. the host ends an emission: the same for the surge flag")
host_state({ s = true, sg = 150 * TF, p = false, pg = 0, tf = TF, c = true })
tick(1)
check(sm.started == true and GetEvent("surge", "state") == true and cover_bar(), "the emission mirror runs, the bar shows")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(sm.started == false and CALLS.surge_end == 1, "the stock end_surge ran once")
check(GetEvent("surge", "state") == false, "the surge 'state' flag is off after the host's end (stuck true before the fix)")
check(not cover_bar(), "the cover bar is gone after the emission")

print("== 3. stale flags with no storm running here (a load / level change mid-storm, a failed end): corrected and logged")
SetEvent("psi_storm", "state", true)
SetEvent("psi_storm", "vortex", { x = 2 })
SetEvent("surge", "state", true)
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(GetEvent("psi_storm", "state") == false and not GetEvent("psi_storm", "vortex") and GetEvent("surge", "state") == false,
	"the flags follow the host's 'not running'")
check(not cover_bar(), "no bar")
check(CALLS.psi_finish == 1 and CALLS.surge_end == 1 and (STAT.psi_storms or 0) == 1,
	"no extra stock end (no statistic, no end event) for a storm that does not run here")
check(count_log(DISAGREE) == 2, "one diagnostic line per corrected manager (" .. count_log(DISAGREE) .. ")")
tick(1)
tick(1)
check(count_log(DISAGREE) == 2, "the correction is logged once, not every tick")

print("== 4. the stock finish raises on the client: the storm still ends here")
host_state({ s = false, sg = 0, p = true, pg = 40 * TF, tf = TF, c = false })
tick(1)
check(pm.started == true and cover_bar(), "a new storm from the host starts the mirror again")
FINISH_RAISES = true
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
FINISH_RAISES = false
check(pm.started == false, "not running after the failed finish")
check(GetEvent("psi_storm", "state") == false and not cover_bar(), "the flag is off although the stock finish raised")
local finishes = CALLS.psi_finish
for _ = 1, 5 do tick(1) end
check(CALLS.psi_finish == finishes, "the failed finish is not repeated every tick")

print("== 5. split maps: a client on a level the world's emission does not reach drops what it had of the storm")
local NAME = "l01_escape"
level.name = function() return NAME end
level_weathers = { valid_levels = { l01_escape = true } }
coop.levels = { split = function() return true end, on_host_level = function() return true end }
host_state({ s = false, sg = 0, p = true, pg = 40 * TF, tf = TF, c = false })
tick(1)
check(pm.started == true and cover_bar(), "on an open level the mirror runs")
NAME = "l03u_agr_underground" -- the level changed while the Lua state lived on (or a stale state came with it)
host_state({ s = false, sg = 0, p = true, pg = 45 * TF, tf = TF, c = false })
tick(1)
check(pm.started == false, "under ground the storm is not running here")
check(GetEvent("psi_storm", "state") == false and not cover_bar(), "and its HUD is off")
check(count_log("psi-storm ended here: this level is not reached") == 1, "the local end is logged with its reason")
local starts = EVENTS.psi_storm_start or 0
for _ = 1, 3 do host_state({ s = false, sg = 0, p = true, pg = (46 + _) * TF, tf = TF, c = false }) tick(1) end
check(pm.started == false and (EVENTS.psi_storm_start or 0) == starts, "under ground the host's running storm does not start here")
NAME = "l01_escape"
host_state({ s = false, sg = 0, p = true, pg = 50 * TF, tf = TF, c = false })
tick(1)
check(pm.started == true and cover_bar(), "back on an open level the host's storm runs here again")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(pm.started == false and not cover_bar(), "and ends with the host's end")
coop.levels = nil

print("== 6. the host goes silent: the phase is held (no end of its own), its next state decides")
host_state({ s = false, sg = 0, p = true, pg = 40 * TF, tf = TF, c = false })
tick(1)
local fin = CALLS.psi_finish
tick(20)
check(pm.started == true and CALLS.psi_finish == fin, "20 s without a word from the host: the storm is held, not ended")
host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(pm.started == false and not cover_bar(), "the host's next state ends it")

-- none of the mirror steps hid a Lua error except the one raised on purpose in 4
local errors = {}
for _, line in ipairs(LOG) do
	if line:find("lua error", 1, true) and (line:find("emission", 1, true) or line:find("psi-storm", 1, true))
		and not line:find("_delta", 1, true) then
		errors[#errors + 1] = line
	end
end
check(#errors == 0, "no other Lua error in the emission / psi-storm mirror (" .. (errors[1] or "") .. ")")

print(string.format("%d passed, %d failed", PASSES, FAILS))
