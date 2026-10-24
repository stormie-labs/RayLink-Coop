-- Anomaly Coop (audit E2, 2026-10-24): the emission and the psi storm around every player - client side.
-- The people this player's wave / vortex reaches die on the host (the stock kill there): his machine sends where the
-- wave / vortex is (coop_env_npc_kill) instead of killing nothing. His hide task is his own: the id is made personal
-- (coop_tasks.set_local_task) and the stock update gives it here at its moment.
-- Real coop_main.script; the stock managers are stand-ins keeping the stock task and kill calls.
-- Not shipped. Run: tools\test_lua.cmd env_players_client
MODE = "client"
dofile("tests/lua/support/stubs.lua")

GIVEN, LOCAL = {}, {}
LOCAL_OK = true
task_manager = { get_task_manager = function()
	return { give_task = function(_, id) GIVEN[#GIVEN + 1] = id end }
end }
coop_tasks = { set_local_task = function(id) LOCAL[#LOCAL + 1] = id; return LOCAL_OK end }

local function stock_class()
	local c = {}
	c.__index = c
	return c
end
local function elapsed(m)
	return math.ceil(game.get_game_time():diffSec(m.inited_time) / level.get_time_factor())
end

-- surge_manager.script: update gives the task from second 30 (L734-760), give_surge_hide_task L1494-1510
local CSurge = stock_class()
function CSurge:initialize() self.surge_time = 222; self.surge_task_sect = "" end
function CSurge:finalize() end
function CSurge:update()
	if elapsed(self) >= 30 and self.task_given ~= true then
		self:give_surge_hide_task()
		self.task_given = true
	end
end
function CSurge:end_surge() self.started = false end
function CSurge:give_surge_hide_task()
	if self.surge_task_sect ~= "empty" then
		task_manager.get_task_manager():give_task(self.surge_task_sect == "" and "hide_from_surge" or self.surge_task_sect)
	end
end
STOCK_KILLS = 0
function CSurge:kill_objects_at_pos() STOCK_KILLS = STOCK_KILLS + 1 end
function CSurge:kill_crows_at_pos() end
function CSurge:turn_to_zombie() end
function CSurge:explode() end
function CSurge:kill_actor_at_pos() end
function CSurge:kill_all_unhided() end
function CSurge:launch_rockets() end
function CSurge:pos_in_cover() return false end
function CSurge:init_surge_covers() end
local surge_instance = setmetatable({ _state_loaded = true, started = false }, CSurge)
surge_instance:initialize()
surge_manager = { CSurgeManager = CSurge, get_surge_manager = function() return surge_instance end }

-- psi_storm_manager.script: update gives the task from second 12 (L350-355), give_psi_storm_hide_task L559-575
local CPsi = stock_class()
function CPsi:initialize() self.psi_storm_duration = 254; self.psi_storm_task_sect = "" end
function CPsi:finalize() end
function CPsi:update()
	if elapsed(self) >= 12 and not self.task_given then
		self:give_psi_storm_hide_task()
		self.task_given = true
	end
end
function CPsi:finish() self.started = false end
function CPsi:give_psi_storm_hide_task()
	if self.psi_storm_task_sect ~= "empty" then
		task_manager.get_task_manager():give_task(self.psi_storm_task_sect == "" and "hide_from_psi_storm"
			or self.psi_storm_task_sect)
	end
end
function CPsi:kill_objects_at_pos() STOCK_KILLS = STOCK_KILLS + 1 end
function CPsi:kill_crows_at_pos() end
function CPsi:launch_rockets() end
local psi_instance = setmetatable({ _state_loaded = true, started = false }, CPsi)
psi_instance:initialize()
psi_storm_manager = { CPsiStormManager = CPsi, get_psi_storm_manager = function() return psi_instance end }

-------------------------------------------------------------------------------
print("== env_players_client")
load_coop_main()
coop_main.on_game_start()
local sm = surge_manager.get_surge_manager()
local pm = psi_storm_manager.get_psi_storm_manager()
TF = 10

local function tick(seconds)
	NOW = NOW + seconds * 1000
	SendScriptCallback("actor_on_update")
end
local function host_state(t) coop_main.on_event("coop_env", coop_main.encode(t), 0) end
local function last_kill()
	for i = #SENT, 1, -1 do
		if SENT[i].name == "coop_env_npc_kill" then return coop_main.decode(SENT[i].payload), SENT[i].target, i end
	end
end
local function kills_sent()
	local n = 0
	for _, s in ipairs(SENT) do if s.name == "coop_env_npc_kill" then n = n + 1 end end
	return n
end

-- 1. the emission: the personal hide task, given once by the stock update
host_state({ s = true, sg = 400, p = false, pg = 0, tf = 10, c = false }) -- 40 stock seconds in
tick(1)
check(sm.started == true, "emission mirror started")
check(#GIVEN == 1 and GIVEN[1] == "hide_from_surge", "the stock update gave the hide task here (" .. tostring(GIVEN[1]) .. ")")
check(#LOCAL == 1 and LOCAL[1] == "hide_from_surge", "the hide task was made personal before it was given")
for _ = 1, 3 do tick(1) end
check(#GIVEN == 1, "the hide task is given once")

-- a task id the engine refuses to keep personal is not given (it would go to the host as a group task)
LOCAL_OK = false
sm:give_surge_hide_task()
check(#GIVEN == 1, "no hide task when it cannot be personal")
LOCAL_OK = true
sm.surge_task_sect = "empty"
sm:give_surge_hide_task()
check(#GIVEN == 1, "surge_task_sect 'empty': no task, as the stock")
sm.surge_task_sect = ""

-- 2. the wave's kill goes to the host
local before = kills_sent()
sm:kill_objects_at_pos(123.5, "kill_at_wave")
check(STOCK_KILLS == 0, "the stock kill does not run on the client")
local t, target = last_kill()
check(kills_sent() == before + 1 and t.k == "s" and t.z == 123.5 and target == 0, "the wave's z is sent to the host")
sm:kill_objects_at_pos(120, "kill_at_wave")
check(kills_sent() == before + 1, "a second wave kill within a second is not sent")
NOW = NOW + 1000
sm:kill_objects_at_pos(false, "explode")
t = last_kill()
check(kills_sent() == before + 2 and t.k == "s" and t.z == nil, "a kill of everybody unhidden goes without z")

host_state({ s = false, sg = 0, p = false, pg = 0, tf = 6, c = true })
tick(1)
check(sm.started == false, "the emission ended by the host (its hide task condition reads this phase)")

-- 3. the psi storm: personal hide task, vortex kills to the host
host_state({ s = false, sg = 0, p = true, pg = 200, tf = 10, c = false }) -- 20 stock seconds in
tick(1)
check(pm.started == true, "psi-storm mirror started")
check(GIVEN[#GIVEN] == "hide_from_psi_storm" and LOCAL[#LOCAL] == "hide_from_psi_storm",
	"the psi-storm hide task is personal and given here")
before = kills_sent()
pm:kill_objects_at_pos({ x = 10, y = 20, z = 30 }, "kill_at_vortex")
t, target = last_kill()
check(kills_sent() == before + 1 and t.k == "p" and t.x == 10 and t.y == 20 and t.z == 30 and target == 0,
	"the vortex position is sent to the host")
pm:kill_objects_at_pos({ x = 11, y = 20, z = 30 }, "kill_at_vortex")
check(kills_sent() == before + 2, "every vortex is sent")
pm:kill_objects_at_pos(nil, "kill_at_vortex")
check(kills_sent() == before + 2, "a vortex without a position is not sent")
check(STOCK_KILLS == 0, "the stock psi kill does not run on the client")

print(string.format("%d passed, %d failed", PASSES, FAILS))
