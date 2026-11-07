-- A fight nobody is at any more (coop_encounters): the rule, Skyfall on the real task file, the roll backs of the other tasks,
-- the scene rules. The task scripts are the real GAMMA files when E:\AnomalyCoopGamma is there.
-- Run: tools\test_lua.cmd encounters
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua")
AC_ID = 0

local BS = string.char(92)
local function gamma(name) return GAMMA_DIR .. BS .. name .. ".script" end

local function read_all(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function load_real(M, name)
	local f = assert(loadstring(read_all(gamma(name)), "@" .. gamma(name)))
	local mod = setmetatable({}, { __index = M.env })
	M.env[name] = mod
	setfenv(f, mod)
	f()
	return mod
end

local function make_world(role, peer)
	if not peer then reset_world() end -- a second machine of the same world comes with its peer
	local M = machine(role or "host", peer or (role == "client" and 1 or 0), peer and { [1] = 500 } or { [0] = 0, [1] = 500 })
	local E = M.env
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.coop_mods_core = load_script(M, "coop_mods_core")
	E.MODE = "checkpoint"
	E.get_console_cmd = function(kind, name) if name == "coop_death_mode" then return E.MODE end end
	E.LIFE = {}
	E.coop.life_of = function(id) return E.LIFE[id] or "alive" end
	E.TASKS = {}
	E.task_manager = { get_task_manager = function() return { task_info = E.TASKS } end }
	E.RELEASED = {}
	E.safe_release_manager = { release = function(t) E.RELEASED[#E.RELEASED + 1] = t.id end }
	E.LEVEL = "l03_agroprom"
	E.level.name = function() return E.LEVEL end
	E.SE = {}
	E.alife_object = function(id) return E.SE[id] end
	E.INFOS = {}
	E.has_alife_info = function(i) return E.INFOS[i] == true end
	E.give_info = function(i) E.INFOS[i] = true end
	E.disable_info = function(i) E.INFOS[i] = nil end
	E.db.actor.disable_info_portion = function(_, i) E.INFOS[i] = nil end
	E.load_ctime = function() return nil end
	M.E = E
	local enc = load_script(M, "coop_encounters")
	M.enc = enc
	return M, E, enc
end

local function se_creature(id, alive)
	return { id = id, alive = function() return alive ~= false end }
end

-- moves time on and fires the throttled tick
local function run_for(M, seconds)
	for _ = 1, seconds do
		NOW = NOW + 1000
		M.E.coop_npc_players.invalidate()
		M.fire("actor_on_update")
	end
end

print("== the rule")
do
	local _, _, enc = make_world()
	local r = {}
	check(not enc.step(r, true, false, false, 1000, 100), "nobody was ever there, not armed: nothing")
	check(enc.step({}, false, true, false, 1000, 100) == false, "not live: nothing, armed or not")
	check(not enc.step(r, true, false, true, 1000, 100), "a player there: nothing")
	check(not enc.step(r, true, false, false, 2000, 100), "he left: the wait starts")
	check(not enc.step(r, true, false, false, 2099, 100), "still waiting")
	check(not enc.step(r, true, false, true, 2100, 100), "back in time: no roll back")
	check(not enc.step(r, true, false, false, 3000, 100), "left again: a new wait")
	check(enc.step(r, true, false, false, 3100, 100), "the wait is over: roll back")
	check(not enc.step(r, true, false, false, 9000, 100), "once: the next one needs a player who came back")
	local a = {}
	check(not enc.step(a, true, true, false, 1000, 100), "armed: the wait starts with nobody ever seen")
	check(enc.step(a, true, true, false, 1100, 100), "armed: roll back")
	r = { seen = true, away = 1 }
	enc.step(r, false, false, false, 1000, 100)
	check(r.seen == nil and r.away == nil, "the fight is over: the record is clean")
	local w, rest = enc.doom_shift(true, 10.5, 0.25)
	check(w == 10 and math.abs(rest - 0.75) < 1e-6, "doom: whole seconds, the rest carried")
	check(enc.doom_shift(false, 10, 0) == 0, "doom: somebody stands, the deadline runs")
end

local have_gamma = true
for _, n in ipairs({ "tasks_skyfall", "tasks_big_game" }) do have_gamma = have_gamma and have_file(gamma(n)) end
if not have_gamma then print("  (GAMMA scripts not found: the real-file checks are skipped)") end

local PAD = vec(-177.2, 5.1, -179.6)

local function skyfall_world(role)
	local M, E, enc = make_world(role)
	E.task_status_functor, E.task_functor, E.xr_effects = {}, {}, {}
	E.dynamic_news_helper = { send_tip = function() end }
	E.level_changing = function() return false end
	E.relation_registry = { community_relation = function() return -5000 end, community_goodwill = function() return 0 end }
	E.game_relations = { ENEMIES = -1000 }
	E.a_tab_utils = { shallow_copy = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end }
	E.utils_data = { CTime_to_table = function() end }
	E.SPAWNS = {}
	E.NEAR = false
	E.nta_utils = {
		levels = { agroprom = "l03_agroprom" },
		actor_on_level = function(l) return E.LEVEL == l end,
		actor_in_range = function(pos, r) return enc.standing_near(pos, r) end,
		spawn_helicopter = function() local id = 900 + #E.SPAWNS; E.SPAWNS[#E.SPAWNS + 1] = id; return id end,
		spawn_helper = function() local id = 950 + #E.SPAWNS; E.SPAWNS[#E.SPAWNS + 1] = id; return id end,
		mass_spawn_helper = function() end,
	}
	local sky = load_real(M, "tasks_skyfall")
	enc.on_game_start()
	return M, E, enc, sky
end

local function heli_at(M, id, health)
	local h = { hp = health or 0.3 }
	function h:GetfHealth() return self.hp end
	function h:Die() self.dead = true end
	function h:Explode() end
	local bound = { st = { combat = { set_enemy = function() end } } }
	return M.add(make_obj(id, 0, 50, 0, { get_helicopter = function() return h end, binded_object = function() return bound end }))
end

if have_gamma then
	print("== Skyfall: nobody in the zone, the heli goes away; a player at the pad brings it back whole")
	local M, E, enc, sky = skyfall_world()
	local fn = E.task_status_functor.skyfall_task_status_functor
	local id = "mil_smart_terrain_7_7_freedom_leader_stalker_task_skyfall"
	local tsk = { id = id, stage = 2 }
	E.TASKS[id] = tsk
	sky.load_state({ skyfall_task_data = { dynamic_heli_id = 900, barrels_ids = {} } })
	heli_at(M, 900)
	local host = E.db.actor
	host._pos = vec(PAD.x, PAD.y, PAD.z)
	local proxy = M.add(make_obj(500, 1000, 0, 1000))

	run_for(M, 40)
	check(#E.RELEASED == 0 and tsk.stage == 2, "a standing player in the zone: nothing resets")
	E.LIFE[0] = "wounded"
	run_for(M, 10)
	check(#E.RELEASED == 0, "the last one there went down: a short wait, no reset yet")
	E.LIFE[0] = nil
	run_for(M, 15)
	check(#E.RELEASED == 0 and tsk.stage == 2, "he was back on his feet in time: nothing resets")
	E.LIFE[0] = "dead"
	proxy._pos = vec(PAD.x + 299, PAD.y, PAD.z)
	run_for(M, 40)
	check(#E.RELEASED == 0, "the other player stands inside the zone: nothing resets")
	proxy._pos = vec(PAD.x + 310, PAD.y, PAD.z)
	run_for(M, 19)
	check(#E.RELEASED == 0, "he left the zone: the wait runs")
	run_for(M, 2)
	check(E.RELEASED[1] == 900 and #E.RELEASED == 1, "the wait is over: the heli is released")
	check(tsk.stage == 0, "the task is back at its start")
	M.objects[900] = nil

	fn(tsk, id)
	check(tsk.stage == 0, "the status check does not read the release as a kill")
	E.SIMBOARD = { get_smart_by_name = function(_, n) return { id = n == "agr_smart_terrain_1_6" and 41 or 0 } end }
	check(E.task_functor.skyfall_task_target_functor(id, "target", nil, tsk) == 41, "the marker is the task's start again")
	E.LIFE[0] = nil
	host._pos = vec(PAD.x + 400, PAD.y, PAD.z)
	fn(tsk, id)
	check(tsk.stage == 0 and #E.SPAWNS == 0, "a player far from the pad brings nothing")
	host._pos = vec(PAD.x + 100, PAD.y, PAD.z)
	fn(tsk, id)
	check(tsk.stage == 2 and #E.SPAWNS == 1, "a player back at the start point: a new heli through the task")
	local hp = heli_at(M, E.SPAWNS[1], 1)
	fn(tsk, id)
	check(tsk.stage == 2, "the new heli is alive, the fight is on")
	hp:get_helicopter().hp = 0
	fn(tsk, id)
	check(tsk.stage == 3 and hp:get_helicopter().dead, "killing it still completes the stage")

	print("== Skyfall: the group left the level")
	M, E, enc, sky = skyfall_world()
	fn = E.task_status_functor.skyfall_task_status_functor
	tsk = { id = id, stage = 2 }
	E.TASKS[id] = tsk
	sky.load_state({ skyfall_task_data = { dynamic_heli_id = 900, barrels_ids = {} } })
	E.LEVEL = "l02_garbage"
	check(enc.left_level("skyfall", tsk) == true, "the group left: the task goes back instead of failing")
	check(tsk.stage == 0 and E.RELEASED[1] == 900, "stage 0, the heli released")
	check(fn(tsk, id) == nil, "no fail afterwards")
	E.LEVEL = "l03_agroprom"
	tsk.stage = 2
	check(enc.left_level("skyfall", tsk) == false, "on the level: not for this path")
	E.MODE = "hardcore"
	E.LEVEL = "l02_garbage"
	check(enc.left_level("skyfall", tsk) == false, "hardcore: stock (the task fails)")
	check(fn(tsk, id) == "fail", "hardcore: the stock fail stands")

	print("== Skyfall: the stealth stage")
	M, E, enc, sky = skyfall_world()
	id = "mil_smart_terrain_7_7_freedom_leader_stalker_task_skyfall"
	tsk = { id = id, stage = 1 }
	E.TASKS[id] = tsk
	sky.load_state({ skyfall_task_data = { static_heli_id = 950, barrels_ids = { 951 } } })
	E.db.actor._pos = vec(2000, 0, 2000)
	M.add(make_obj(500, 3000, 0, 3000))
	run_for(M, 40)
	check(tsk.stage == 1 and #E.RELEASED == 0, "stage 1: no fight, a player anywhere on the level keeps it")
	E.LIFE[0], E.LIFE[500] = "dead", "dead"
	run_for(M, 25)
	check(tsk.stage == 0 and #E.RELEASED == 2, "nobody stands: the static heli and its barrels go, the stage with them")
	E.task_status_functor.skyfall_task_status_functor(tsk, id)
	check(tsk.stage == 0, "stage 1 never saw the missing heli as a kill")

	print("== Skyfall: only the host, only the checkpoint mode")
	M, E, enc, sky = skyfall_world()
	tsk = { id = id, stage = 2 }
	E.TASKS[id] = tsk
	sky.load_state({ skyfall_task_data = { dynamic_heli_id = 900, barrels_ids = {} } })
	E.db.actor._pos = vec(5000, 0, 5000)
	E.MODE = "rollback"
	run_for(M, 40)
	check(tsk.stage == 2 and #E.RELEASED == 0, "rollback mode: nothing")
	E.MODE = "checkpoint"
	run_for(M, 40)
	check(tsk.stage == 0, "checkpoint: the roll back (armed: nobody was seen since the load)")
	M, E, enc, sky = skyfall_world("client")
	tsk = { id = id, stage = 2 }
	E.TASKS[id] = tsk
	sky.load_state({ skyfall_task_data = { dynamic_heli_id = 900, barrels_ids = {} } })
	E.db.actor._pos = vec(5000, 0, 5000)
	run_for(M, 40)
	check(tsk.stage == 2 and #E.RELEASED == 0, "a client changes nothing")

	print("== Big Game: back to the start of the fight")
	M, E, enc = make_world()
	E.nta_utils = {
		levels = { jupiter = "jupiter" },
		actor_on_level = function(l) return E.LEVEL == l end,
		mass_spawn_helper = function(_, ids) ids[#ids + 1] = 700; ids[#ids + 1] = 701 end,
		spawn_helper = function() return 702 end,
	}
	E.big_game_configs = { small_giants_spots = {}, big_giant_spot = {} }
	E.task_status_functor, E.task_functor, E.xr_effects = {}, {}, {}
	local SMART = { position = vec(100, 0, 100), id = 77 }
	E.SIMBOARD = { smarts_by_names = { jup_sim_2 = SMART } }
	E.LEVEL = "jupiter"
	local bg = load_real(M, "tasks_big_game")
	enc.on_game_start()
	local gid = "jup_b220_trapper_task_big_game"
	tsk = { id = gid, stage = 2 }
	E.TASKS[gid] = tsk
	bg.load_state({ big_game_task_data = { small_giants_ids = { 700, 701 }, big_giant_id = 702 } })
	E.SE[700], E.SE[701], E.SE[702] = se_creature(700, false), se_creature(701), se_creature(702)
	E.db.actor._pos = vec(100, 0, 140)
	run_for(M, 30)
	check(tsk.stage == 2, "a standing player at the tunnel: nothing")
	E.db.actor._pos = vec(100, 0, 400)
	run_for(M, 25)
	check(tsk.stage == 0, "nobody there: the task goes back to its start")
	local released = {}
	for _, r in ipairs(E.RELEASED) do released[r] = true end
	check(released[701] and released[702] and not released[700], "the living giants go, a body stays")
	E.db.actor._pos = vec(100, 0, 110)
	E.task_status_functor.big_game_task_status_functor(tsk, gid)
	check(tsk.stage == 1, "a player back at the tunnel: the small giants again")
	E.SE[700], E.SE[701] = se_creature(700), se_creature(701)
end

print("== heal: a hunt's squad is healed when it is online, never released")
do
	local M, E, enc = make_world()
	local tid = "bar_dolg_leader_task_2"
	local tsk = { id = tid, stage = 0 }
	E.TASKS[tid] = tsk
	local squad = { id = 800, position = vec(50, 0, 50), m_game_vertex_id = 1 }
	function squad:section_name() return "special_bloodsucker_task2_squad" end
	function squad:squad_members()
		local i = 0
		local ids = { 801, 802 }
		return function() i = i + 1; return ids[i] and { id = ids[i] } or nil end
	end
	E.SE[800] = squad
	E.SE[801], E.SE[802] = se_creature(801), se_creature(802)
	E.SIMBOARD = { smarts_by_names = { trc_sim_9 = { id = 33, position = vec(50, 0, 50) } }, smarts = { [33] = { squads = { [800] = true } } } }
	E.alife = function() return { level_name = function() return "l03_agroprom" end } end
	E.game_graph = function() return { vertex = function() return { level_id = function() return 1 end } end } end
	enc.on_game_start()
	E.db.actor._pos = vec(100, 0, 50)
	run_for(M, 5)
	E.db.actor._pos = vec(1000, 0, 50)
	run_for(M, 25)
	check(#E.RELEASED == 0, "nothing is released: the task waits for the squad's death")
	local a = M.add(make_obj(801, 50, 0, 50, { set_health_ex = function(self, v) self._hp = v end }))
	local dead = M.add(make_obj(802, 50, 0, 50, { _alive = false, set_health_ex = function(self, v) self._hp = v end }))
	run_for(M, 2)
	check(a._hp == 1, "the first time a member is online he is healed")
	check(dead._hp == nil, "a body stays a body")
	E.SE[800] = nil
	E.SIMBOARD.smarts[33].squads = {}
	a._hp = nil
	run_for(M, 30)
	check(a._hp == nil, "the squad is gone: the entry is off")
end

print("== the BTR hunt: repaired, not released")
do
	local M, E, enc = make_world()
	local tid = "mil_smart_terrain_7_7_freedom_leader_stalker_task_9"
	local tsk = { id = tid, stage = 1 }
	E.TASKS[tid] = tsk
	local DATA = { [tid] = { vehicles = { { id = 601, x = 0, y = 0, z = 0, dead = true }, { id = 602, x = 10, y = 0, z = 0 } } } }
	E.tasks_veh_destroy = { touch = function() return DATA end }
	E.SE[601], E.SE[602] = {}, {}
	E.vector = vector
	E.LEVEL = "l07_military"
	enc.on_game_start()
	E.db.actor._pos = vec(20, 0, 0)
	run_for(M, 3)
	E.db.actor._pos = vec(500, 0, 0)
	run_for(M, 25)
	local car = M.add(make_obj(602, 10, 0, 0, { set_health_ex = function(self, v) self._hp = v end, alive = function() error("a car has no alive()") end }))
	local gone = M.add(make_obj(601, 0, 0, 0, { set_health_ex = function(self, v) self._hp = v end }))
	run_for(M, 2)
	check(car._hp == 1, "the BTR left is repaired")
	check(gone._hp == nil, "a dead one stays dead")
	check(#E.RELEASED == 0, "nothing is released: the task keeps the ids")
end

print("== the Impending Doom deadline")
do
	local M, E, enc = make_world()
	enc.on_game_start()
	local CT = {}
	CT.__index = CT
	function CT:diffSec(o) return self.s - o.s end
	function CT:add(o) self.s = self.s + o.s end
	function CT:setHMS(h, m, s) self.s = h * 3600 + m * 60 + s end
	local clock = { s = 1000 }
	E.game.get_game_time = function() return setmetatable({ s = clock.s }, CT) end
	E.game.CTime = function() return setmetatable({ s = 0 }, CT) end
	local stored = { s = 500 }
	E.load_ctime = function(_, k) return k == "impending_doom_timer" and setmetatable({ s = stored.s }, CT) or nil end
	E.save_ctime = function(_, k, v) if k == "impending_doom_timer" then stored.s = v.s end end
	local function tick(game_seconds)
		clock.s = clock.s + game_seconds
		run_for(M, 1)
	end
	tick(0)
	tick(60)
	check(stored.s == 500, "somebody stands: the deadline runs")
	E.LIFE[0] = "dead"
	tick(60)
	tick(60)
	check(stored.s == 620, "nobody stands: the start moves on with the game time")
	E.LIFE[0] = nil
	tick(60)
	check(stored.s == 620, "up again: it runs again")
	E.MODE = "hardcore"
	E.LIFE[0] = "dead"
	tick(60)
	check(stored.s == 620, "another death mode: stock")
end

print("== Pripyat: the timers of the evacuation stand still while nobody is at the helis")
do
	local M, E, enc = make_world()
	enc.on_game_start()
	E.db.zone_by_name.pri_a28_scene_end_zone = make_obj(320, 0, 0, 0, { _radius = 50 })
	E.db.zone_by_name.waves = make_obj(321, 0, 0, 0)
	E.db.zone_by_name.evac = make_obj(322, 0, 0, 0)
	local waves = { active_section = "sr_idle@waves_done", activation_game_time = "the start" }
	local evac = { active_section = "sr_timer@got_one_minute", activation_time = 5 }
	E.db.storage[321], E.db.storage[322] = waves, evac
	E.db.actor._pos = vec(500, 0, 0)
	run_for(M, 2)
	check(type(waves.activation_game_time) == "table", "nobody there: the game timer starts again every check")
	check(evac.activation_time == NOW, "and the last minute too")
	E.db.actor._pos = vec(10, 0, 0)
	local t1 = evac.activation_time
	run_for(M, 3)
	check(evac.activation_time == t1, "a standing player at the helis: the timers run")
	E.LIFE[0] = "wounded"
	run_for(M, 2)
	check(evac.activation_time == NOW, "one who is down does not hold them")
	E.LIFE[0] = nil
	E.MODE = "hardcore"
	E.db.actor._pos = vec(500, 0, 0)
	t1 = evac.activation_time
	run_for(M, 3)
	check(evac.activation_time == t1, "hardcore: stock")
end

print("== the Bar arena: the fight ends with its fighter gone")
do
	local M, E, enc = make_world()
	E.LEVEL = "l05_bar"
	enc.on_game_start()
	E.level.patrol_path_exists = function() return true end
	E.patrol = function() return { point = function() return vec(0, 0, 0) end } end
	E.INFOS.bar_arena_fight_begin, E.INFOS.bar_arena_fight_3 = true, true
	E.INFOS.bar_arena_fight_3_stalker_1_die = true
	E.db.OnlineStalkers = { 300, 301 }
	M.add(make_obj(300, 5, 0, 5, { _section = "bar_arena_stalker_3_1" }))
	M.add(make_obj(301, 5, 0, 5, { _section = "stalker_bartender" }))
	local PURGED, SWITCHED
	E.xr_zones = { purge_arena_items = function(n) PURGED = n end }
	E.xr_logic = { switch_to_section = function(_, _, s) SWITCHED = s end }
	E.db.zone_by_name.trigger = make_obj(310, 0, 0, 0)
	local OVER = false
	E.coop_arena = { fight_over = function() OVER = true end }
	E.db.storage[310] = { active_section = "sr_idle@wait_finish", ini = { section_exist = function(_, s) return s == "sr_cutscene@fight_1" end } }
	E.db.actor._pos = vec(5, 0, 5)
	run_for(M, 40)
	check(E.INFOS.bar_arena_fight_3 == true, "the fighter in the arena: nothing")
	E.db.actor._pos = vec(500, 0, 5)
	run_for(M, 25)
	check(E.INFOS.bar_arena_fight_3 == nil and E.INFOS.bar_arena_fight_begin == nil, "he is gone: the fight is off")
	check(#E.RELEASED == 1 and E.RELEASED[1] == 300, "the opponents go, nobody else")
	check(PURGED == "bar_arena" and SWITCHED == "sr_idle@idle", "the items are purged, the trigger is at its start")
	check(E.INFOS.bar_arena_fight_3_done == nil, "not a win: no reward, the fight can be asked for again")
	check(E.INFOS.bar_arena_fight_3_stalker_1_die == nil, "the deaths of this try are forgotten")
	check(OVER == true, "coop_arena forgets the fighter of the fight: his gear waits for him")
end

print("== split levels: the Bar is a map server's, the world server stands at Agroprom")
do
	local BRIDGE = 0x101
	local LEVELS = { "l03_agroprom", "l05_bar" }
	local W, E, enc = make_world()
	local Mk, F, mk_enc = make_world("client", BRIDGE)
	local function stage(env, mine)
		env.coop.levels = {
			split = function() return true end,
			my_level = function() return mine end,
			level_of_player = function(p) return p == 1 and 2 or 1 end,
			map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
			bridge_of_player = function(p) return p == 1 and BRIDGE or nil end,
			carried = function() return {} end,
		}
		env.LEVEL = LEVELS[mine]
		env.alife = function() return { level_name = function(_, l) return LEVELS[l] end } end
		env.game_graph = function() return { vertex = function(_, v) return { level_id = function() return v end } end } end
		env.level.patrol_path_exists = function() return mine == 2 end
		env.patrol = function() return { point = function() return vec(0, 0, 0) end } end
		env.PURGED, env.SWITCHED = nil, nil
		env.xr_zones = { purge_arena_items = function(n) env.PURGED = n end }
		env.xr_logic = { switch_to_section = function(_, _, s) env.SWITCHED = s end }
		env.coop_quests_core = load_script(mine == 1 and W or Mk, "coop_quests_core")
		env.coop_levels_share = load_script(mine == 1 and W or Mk, "coop_levels_share")
		env.coop_levels_share.on_game_start()
	end
	stage(E, 1)
	stage(F, 2)
	F.coop.is_map_server = function() return true end
	F.coop.is_mirror = function() return false end
	F.db.actor._pos = vec(0, 0, 0) -- its ghost stands at the point: nobody
	enc.on_game_start()
	mk_enc.on_game_start()
	local body = { id = 500, position = vec(5, 0, 5), m_level_vertex_id = 1, m_game_vertex_id = 2 }
	E.SE[500] = body
	local player = Mk.add(make_obj(500, 5, 0, 5))
	-- the opponents, the trigger: on the map server
	F.db.OnlineStalkers = { 300, 301 }
	Mk.add(make_obj(300, 5, 0, 5, { _section = "bar_arena_stalker_3_1" }))
	Mk.add(make_obj(301, 5, 0, 5, { _section = "stalker_bartender" }))
	F.db.zone_by_name.trigger = make_obj(310, 0, 0, 0)
	F.db.storage[310] = { active_section = "sr_idle@wait_finish", ini = { section_exist = function(_, s) return s == "sr_cutscene@fight_1" end } }
	for _, env in ipairs({ E, F }) do env.INFOS.bar_arena_fight_begin, env.INFOS.bar_arena_fight_3 = true, true end
	local function both(seconds)
		for _ = 1, seconds do
			run_for(W, 1)
			run_for(Mk, 1)
			pump()
		end
	end
	both(40)
	check(E.INFOS.bar_arena_fight_3 == true, "the fighter in the arena of a map server's level: nothing")
	body.position, player._pos = vec(500, 0, 5), vec(500, 0, 5)
	both(25)
	check(E.INFOS.bar_arena_fight_3 == nil and E.INFOS.bar_arena_fight_begin == nil, "he is gone: the world server takes the fight off")
	check(#F.RELEASED == 1 and F.RELEASED[1] == 300 and #E.RELEASED == 0, "the map server releases the opponents, the world server has none")
	check(F.PURGED == "bar_arena" and E.PURGED == nil, "the map server purges the arena")
	check(F.SWITCHED == nil, "the trigger waits: back at its start with the infos still here it would start the fight again")
	F.INFOS.bar_arena_fight_begin = nil
	both(2)
	check(F.SWITCHED == nil, "the info of the fight itself is what it starts on")
	F.INFOS.bar_arena_fight_3 = nil
	both(2)
	check(F.SWITCHED == "sr_idle@idle" and E.SWITCHED == nil, "the infos are gone: the trigger is back at its start, on the map server")

	-- the evacuation: the zone and the timers are the map server's, the rule the world server's
	F.db.zone_by_name.pri_a28_scene_end_zone = make_obj(320, 0, 0, 0, { _radius = 50 })
	F.db.zone_by_name.evac = make_obj(322, 0, 0, 0)
	local evac = { active_section = "sr_timer@got_one_minute", activation_time = 5 }
	F.db.storage[320], F.db.storage[322] = {}, evac
	F.MODE = nil -- a map server's console knows nothing of the rule
	both(5)
	check(evac.activation_time == NOW, "nobody at the helis of a map server's level: the timer stands still")
	player._pos = vec(10, 0, 0)
	local t1 = evac.activation_time
	both(3)
	check(evac.activation_time == t1, "a player at the helis: the timers run")
	player._pos = vec(500, 0, 5)
	E.MODE = "hardcore"
	both(5)
	t1 = evac.activation_time
	both(3)
	check(evac.activation_time == t1, "the world server's rule says hardcore: stock")
	E.MODE = "checkpoint"

	-- a hunt's target on a map server's level is healed through the far view
	local tid = "bar_dolg_leader_task_2"
	E.TASKS[tid] = { id = tid, stage = 0 }
	local squad = { id = 800, position = vec(500, 0, 5), m_game_vertex_id = 2 }
	function squad:section_name() return "special_bloodsucker_task2_squad" end
	function squad:squad_members()
		local i = 0
		return function() i = i + 1; return i == 1 and { id = 801 } or nil end
	end
	E.SE[800], E.SE[801] = squad, se_creature(801)
	E.SIMBOARD = { smarts_by_names = { trc_sim_9 = { id = 33, position = vec(500, 0, 5) } }, smarts = { [33] = { squads = { [800] = true } } } }
	local through
	local stand_in = make_obj(801, 500, 0, 5, { set_health_ex = function(self, v) self._hp = v end })
	E.coop_quests_core.with_target = function(id, peer, what, fn, ...)
		through = id
		local real = E.level.object_by_id
		E.level.object_by_id = function(i) return i == id and stand_in or real(i) end
		local ok, err = pcall(fn, ...)
		E.level.object_by_id = real
		if not ok then error(err, 0) end
	end
	both(3)
	body.position = vec(2000, 0, 5)
	both(25)
	check(through == 801 and stand_in._hp == 1, "the target of a hunt on another level is healed on its level")
end

print("== Hidden Threat: Degtyarev is not hurt while nobody is near")
do
	local M, E, enc = make_world()
	enc.on_game_start()
	local tid = "sl_hidden_threat_task_5"
	E.TASKS[tid] = { id = tid, stage = 2 }
	local squad = { position = vec(0, 0, 0) }
	function squad:squad_members()
		local i = 0
		return function() i = i + 1; return i == 1 and { id = 880 } or nil end
	end
	E.get_story_squad = function(n) return n == "pri_b35_mercs_ht_degtyarev_squad" and squad or nil end
	local npc = make_obj(880, 0, 0, 0)
	E.db.actor._pos = vec(100, 0, 0)
	run_for(M, 2)
	local h = { power = 1 }
	M.fire("npc_on_before_hit", npc, h)
	check(h.power == 1, "a player near: the fight is real")
	E.LIFE[0] = "wounded"
	run_for(M, 2)
	M.fire("npc_on_before_hit", npc, h)
	check(h.power == 0, "the group is down: he takes no damage")
	E.TASKS[tid] = nil
	run_for(M, 2)
	h.power = 1
	M.fire("npc_on_before_hit", npc, h)
	check(h.power == 1, "the task is over: nothing")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
