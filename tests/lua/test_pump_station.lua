-- Split levels: the defense of the Pump Station (stock tasks_pump_station_defense.script, coop_quests_party). The world server judges the
-- task and writes the module's table M; the commander's logic (meet_dialog, invulnerable) runs on the map server of the Swamps and reads
-- its own M. The guards are live on the map server only: the world server's stand-ins have no best_enemy. Real scripts over the quests
-- harness: the world server (level 1) and the map server of level 2. Run: tools\test_lua.cmd pump_station
dofile("tests/lua/support/harness_quests.lua")

local BRIDGE, BRIDGE2 = 0x101, 0x102
local LEVEL_NAMES = { "l01_escape", "k00_marsh" }
local COMMANDER, GUARD, AVATAR = 800, 801, 500

local function world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
	M.ObjMT.best_enemy = function(self) return self._enemy end
	e.game_graph = function() return { vertex = function(_, v) return { level_id = function() return v end } end } end
	local sim = {}
	function sim:level_name(l) return LEVEL_NAMES[l] end
	function sim:switch_distance() return 150 end
	function sim:actor() return { id = 0, m_game_vertex_id = 1 } end
	e.alife = function() return sim end
	e.db.anomaly_by_name = {}
	e.db.zone_by_name = {}
	M.bridges = { { bridge = BRIDGE, level = 2 } }
	e.coop.levels = {
		split = function() return M.split ~= false end,
		my_level = function() return M.my_level end,
		level_of_player = function(peer) return peer == 1 and 2 or 1 end,
		bridge_of_player = function(peer) return peer == 1 and BRIDGE or nil end,
		map_servers = function() return M.bridges end,
		carried = function() return {} end,
	}
	e.coop_mods_core = { find_local = function(m, name) return m["_local_" .. name] end }
	e.level.name = function() return M.level_name end
end

-- The stock module as far as these paths read it (tasks_pump_station_defense.script:47-49, 125-138, 193-210): its table is a local
-- that load_state and cleanup replace.
local function stock_psd(M)
	local e = M.env
	local psd = { _local_M = {} }
	local function m() return psd._local_M end
	function psd.give_before_attack_talk() m().before_attack_talk = true end
	function psd.aggro()
		local t = m()
		if t.commander_id then
			local comm = e.level.object_by_id(t.commander_id)
			local be = comm and comm:best_enemy()
			if be and be:id() == 0 then return true end
		end
		if not t.guards then return end
		for id in pairs(t.guards) do
			local grd = e.level.object_by_id(id)
			local be = grd and grd:best_enemy()
			if be and be:id() == 0 then return true end
		end
	end
	function psd.dist_from_trigger() return 1 end
	e.xr_conditions.pump_station_defense_task_need_intro_talk = function()
		local t = m()
		return t.stage and t.stage < 3 and not t.before_attack_talk
	end
	e.xr_conditions.pump_station_defense_task_need_intro_talk_2 = function()
		local t = m()
		return t.stage and t.stage < 3 and t.before_attack_talk
	end
	e.xr_conditions.pump_station_defense_task_need_end_talk = function()
		local t = m()
		return t.stage and t.stage > 3
	end
	e.xr_conditions.pump_station_defense_task_commander_inv_condition = function()
		local t = m()
		if not t.stage then return false end
		return t.stage < 3 and not psd.aggro()
	end
	e.tasks_pump_station_defense = psd
	return psd
end

local SCRIPTS = { "coop_quests_core", "coop_levels_share", "coop_quests_far", "coop_tasks", "coop_quests_party" }

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
	fire(M, "actor_on_first_update")
end

local Hm = machine("host", 0)
local Ms = machine("client", BRIDGE)
Hm.my_level, Ms.my_level = 1, 2
Hm.level_name, Ms.level_name = "fake_start", "k00_marsh"
world(Hm); world(Ms)
Ms.env.coop.is_map_server = function() return true end
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = AVATAR } }
Ms.players = { { id = 1, is_self = false, avatar_id = AVATAR } }
local psd_h, psd_m = stock_psd(Hm), stock_psd(Ms)
Ms.new_obj(AVATAR, "coop_player_avatar", vec(0, 0, 0), { _stalker = true })
local commander = Ms.new_obj(COMMANDER, "sim_default_csky_4", vec(1, 0, 1), { _stalker = true })
local guard = Ms.new_obj(GUARD, "sim_default_csky_1", vec(2, 0, 2), { _stalker = true })

boot(Hm); boot(Ms)

local MACHINE_LIST = { Hm, Ms }
local function frames(n)
	for _ = 1, n or 1 do
		NOW = NOW + 5000
		for _, M in ipairs(MACHINE_LIST) do fire(M, "actor_on_update") end
		pump()
	end
end

local function cond(M, name) return M.env.xr_conditions["pump_station_defense_task_" .. name]() and true or false end

print("== (b) the commander's talk on the map server follows the world server's task")
frames(2)
check(not cond(Ms, "need_intro_talk"), "no task: no talk")
-- the status functor ran on the world server: stage 0 made the commander and the guards, the player came near (stage 1)
psd_h._local_M = { stage = 1, init = true, commander_id = COMMANDER, guards = { [GUARD] = true }, trigger_id = 900, to_release_at_end = {} }
frames(2)
check(cond(Ms, "need_intro_talk"), "stage 1: the map server's commander offers the intro talk (meet_dialog)")
check(not cond(Ms, "need_intro_talk_2"), "and not the second talk yet")
check(cond(Ms, "commander_inv_condition"), "the commander is invulnerable before the attack, as in the stock")
-- the talk's action runs on the world server (coop_quests_missions relays it there)
psd_h.give_before_attack_talk()
frames(2)
check(not cond(Ms, "need_intro_talk") and cond(Ms, "need_intro_talk_2"), "after the talk the map server offers the second talk")

print("== a map server that starts after the task was taken")
local Ms2 = machine("client", BRIDGE2)
Ms2.my_level, Ms2.level_name = 2, "k00_marsh"
world(Ms2)
Ms2.env.coop.is_map_server = function() return true end
Ms2.players = Ms.players
local psd_m2 = stock_psd(Ms2)
psd_m2._local_M = { stage = 0, cleanup_on_new_map = nil } -- what it read from an older save
boot(Ms2)
MACHINE_LIST[#MACHINE_LIST + 1] = Ms2
for _, M in ipairs({ Hm, Ms }) do M.bridges[#M.bridges + 1] = { bridge = BRIDGE2, level = 2 } end
Hm.bridges = { { bridge = BRIDGE, level = 2 }, { bridge = BRIDGE2, level = 2 } }
frames(2)
check(cond(Ms2, "need_intro_talk_2") and psd_m2._local_M.commander_id == COMMANDER, "it gets the task's table as it is now")

print("== (c) a guard fights a player: the map server tells the world server, the task fails")
check(not psd_h.aggro(), "nobody shoots: no aggro on the world server")
guard._enemy = Ms.objects[AVATAR]
frames(2)
check(psd_h.aggro() == true, "a guard on the map server is after a player: aggro on the world server")
guard._enemy = nil
frames(2)
check(psd_h.aggro() == true, "it stands when the fight is over (the stock fails the task on the first sight)")
-- another map server without these guards says "no" (a fresh one, or its first word after the world server's move)
fire(Ms2, "coop_world_back")
frames(2)
check(psd_h.aggro() == true, "a map server without the guards does not take it back")

print("== the task is over: the map server's copy is cleared, an old report does not fail the next task")
psd_h._local_M = {} -- cleanup()
frames(2)
check(not cond(Ms, "need_intro_talk") and not cond(Ms, "need_intro_talk_2") and not cond(Ms, "commander_inv_condition"),
	"the commander's talks and invulnerability end on the map server")
psd_h._local_M = { stage = 1, commander_id = COMMANDER, guards = { [GUARD] = true } } -- a later task, the same id again
frames(2)
check(not psd_h.aggro(), "a new task with a recycled commander id starts without aggro")

print("== without split levels nothing changes")
Hm.split = false
psd_h._local_M = { stage = 1, commander_id = COMMANDER, guards = { [GUARD] = true } }
local blobs = 0
for _, s in ipairs(Hm.sent) do if s.name == "coop_share" then blobs = blobs + 1 end end
frames(2)
local blobs2 = 0
for _, s in ipairs(Hm.sent) do if s.name == "coop_share" then blobs2 = blobs2 + 1 end end
check(blobs2 == blobs, "the world server sends nothing")
check(not psd_h.aggro(), "and its aggro is the stock's and the group's (test_mission_guide)")

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
