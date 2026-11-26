-- The task families with their own script, for every player (tasks_sync_audit_gamma): Skyfall's heli, Living Fire, Mirage, Baba
-- Yaga, the storylines that start for a faction, Operation Monolith, Hidden Threat, the pump station, the guide job.
-- The task scripts are the real GAMMA files when E:\AnomalyCoopGamma is there (GAMMA_SCRIPTS overrides the folder).
-- Run: tools\test_lua.cmd mission_gamma
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")
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

local REAL = { "tasks_skyfall", "tasks_the_living_fire", "tasks_mirage", "tasks_baba_yaga", "tasks_big_game", "operacia_monolith" }
local have_gamma = true
for _, n in ipairs(REAL) do have_gamma = have_gamma and have_file(gamma(n)) end
if not have_gamma then print("  (GAMMA scripts not found: the real-file checks are skipped)") end

-- host with a client at 500; the shared layers coop_mods_nta stands on
local function host_world(dedicated)
	reset_world()
	local H = machine("host", 0, dedicated and { [1] = 500 } or { [0] = 0, [1] = 500 })
	local E = H.env
	E.coop.is_dedicated = function() return dedicated == true end
	local function load(name) return load_script(H, name) end
	local facade = load("coop_mode")
	facade.on_game_start()
	modes.live(facade, load)
	H.TP = {}
	E.coop_npc_players = load_script(H, "coop_npc_players")
	E.coop_mods_core = load_script(H, "coop_mods_core")
	E.LIFE = {}
	E.coop.life_of = function(id) return E.LIFE[id] or (dedicated and id == 0 and "dead" or "alive") end
	E.getFS = function() return { exist = function() return false end, update_path = function(_, _, file) return GAMMA_DIR .. BS .. file end } end
	E.character_community = function(o) return o:character_community() end
	E.task_status_functor, E.task_functor, E.xr_effects = {}, {}, {}
	E.task_manager = { get_task_manager = function() return { task_info = E.TASKS } end }
	E.TASKS = {}
	E.INFOS = {}
	E.has_alife_info = function(i) return E.INFOS[i] == true end
	E.give_info = function(i) E.INFOS[i] = true end
	E.disable_info = function(i) E.INFOS[i] = nil end
	E.SE = {}
	E.alife_object = function(id) return E.SE[id] end
	E.get_story_object_id = function(sid) return E.STORY and E.STORY[sid] end
	E.safe_release_manager = { release = function() end }
	E.dynamic_news_helper = { send_tip = function() end }
	E.utils_data = { CTime_to_table = function() end, CTime_from_table = function() end }
	E.a_tab_utils = { shallow_copy = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end,
		filter = function(t, f) local o = {} for _, v in ipairs(t) do if f(v) then o[#o + 1] = v end end return o end,
		has_value = function(t, x) for _, v in ipairs(t) do if v == x then return true end end return false end }
	E.level_changing = function() return false end
	E.logic_enforcer = { assign = function() end }
	E.particles_object = function() return {} end
	E.xr_sound = { get_safe_sound_object = function() return {} end }
	E.sound_object = setmetatable({}, { __call = function() return { play_no_feedback = function() end } end })
	E.VEC_ZERO = vec(0, 0, 0)
	E.game.translate_string = function(s) return s end
	E.nta_utils = {
		levels = { agroprom = "l03_agroprom", bar = "l05_bar" },
		actor_on_level = function(l) return E.LEVEL == l end,
		teleport_visual = function() end,
		spawn_helper = function() end,
		spawn_attached_sound = function() end,
		delayed_message_by_story_id = function() end,
		obj_position_to_spawn_config_partial = function(o) return { vector = o:position() } end,
		set_timeout = function(cb) E.NTA_TIMER = cb end,
	}
	E.LEVEL = dedicated and "fake_start" or "l03_agroprom"
	E.level.name = function() return E.LEVEL end
	load("coop_quests_core")
	load("coop_srv_quests_core").on_game_start()
	E.CreateTimeEvent = function(a, b, t, f, ...) H.timers = H.timers or {}; H.timers[#H.timers + 1] = { name = tostring(b), f = f, p = { ... } } end
	H.add(make_obj(500, 0, 0, 0, { _name = "client", _comm = "actor_stalker" }))
	E.db.actor.set_actor_position = function(self, p) self._pos = vector():set(p) end
	E.db.storage[0] = {}
	H.E = E
	return H, E
end

local function run_timers(H)
	local list = H.timers or {}
	H.timers = {}
	for _, t in ipairs(list) do t.f(unpack(t.p)) end
end

local function start_nta(H)
	local E = H.E
	local N = load_script(H, "coop_mods_nta")
	N.on_game_start()
	H.fire("actor_on_update")
	return N
end

if have_gamma then
	print("== Skyfall: the heli works through the standing players, it is not put back on the host")
	local H, E = host_world()
	E.relation_registry = { community_relation = function() return 0 end, community_goodwill = function() return 0 end }
	E.game_relations = { ENEMIES = -1000 }
	local sky = load_real(H, "tasks_skyfall")
	E.heli_combat, E.heli_fire = nil, nil
	local K = load_script(H, "coop_npc_compat")
	K.on_game_start()
	sky.load_state({ skyfall_task_data = { dynamic_heli_id = 900, barrels_ids = {} } })
	local aimed
	local combat = { st = { enemy_id = 0 } }
	function combat:set_enemy(o) aimed = o:id(); self.st.enemy_id = o:id() end
	function combat:forget_enemy() self.st.enemy_id = nil; aimed = "forgot" end
	local seen = {}
	local heli = { isVisible = function(_, o) return seen[o:id()] == true end }
	H.add(make_obj(900, 0, 50, 0, { binded_object = function() return { st = { combat = combat } } end,
		get_helicopter = function() return heli end }))
	seen[500] = true
	sky.set_player_enemy()
	check(aimed == 500, "a client in its sight is the target, the host is not forced")
	aimed = nil
	NOW = NOW + 1000
	sky.set_player_enemy()
	check(aimed == nil, "his turn runs: it is not re-aimed every check")
	E.LIFE[500] = "wounded"
	E.coop_npc_players.invalidate()
	NOW = NOW + 1000
	seen[0] = true
	sky.set_player_enemy()
	check(aimed == 0, "he went down: the next standing player")
	E.LIFE[0] = "dead"
	E.coop_npc_players.invalidate()
	NOW = NOW + 1000
	aimed = nil
	sky.set_player_enemy()
	check(aimed == "forgot", "nobody stands: it has no target, the dead host is not one")
	E.LIFE = {}
	E.coop_npc_players.invalidate()
	seen = {}
	NOW = NOW + 20000
	aimed = nil
	sky.set_player_enemy()
	check(aimed ~= nil and aimed ~= "forgot", "nobody in sight: it goes for a player it knows of (the stock's always-known target)")

	print("== Skyfall: the Army's standing is any player's")
	E.community_rel = 0
	E.relation_registry.community_relation = function(comm) return comm == "actor_army" and -5000 or 0 end
	local N = start_nta(H)
	check(not sky.is_enemies_with_military(), "nobody is an enemy of the Army")
	H.objects[500]._comm = "actor_army"
	check(sky.is_enemies_with_military(), "the client's faction counts")
	check(E.db.actor:id() == 0, "db.actor is the host's again")

	print("== Living Fire: the Gauss shot of a client finishes Prometheus")
	H, E = host_world()
	E.STORY = { the_living_fire_prometheus = 777 }
	E.get_story_se_object = function() return { position = vec(10, 0, 0), set_character_name = function() end } end
	E.a_the_living_fire_configs = { outskirts_prometheus_location = { vector = vec(0, 0, 0) } }
	local lf = load_real(H, "tasks_the_living_fire")
	E.lf_kills = 0
	N = start_nta(H)
	local prom = H.add(make_obj(777, 10, 0, 0, { set_health_ex = function() end }))
	H.add(make_obj(880, 0, 0, 0, { _section = "wpn_gauss" }))
	E.INFOS.the_living_fire_endgame_finale = true
	local hit = { draftsman = H.objects[500], weapon_id = 880, power = 1 }
	lf.npc_on_before_hit(prom, hit, 15)
	check(E.INFOS.the_living_fire_prometheus_killed_gg == true, "the finale counts a client's shot")
	check(rawget(lf, "AC_ID") == nil, "the module's own AC_ID is gone after the call")
	E.INFOS.the_living_fire_prometheus_killed_gg = nil
	hit = { draftsman = H.objects[0], weapon_id = 880, power = 1 }
	lf.npc_on_before_hit(prom, hit, 15)
	check(E.INFOS.the_living_fire_prometheus_killed_gg == true, "and the host's")

	print("== Living Fire: stage 25 takes the player at the finale")
	H.objects[500]._pos = vec(12, 0, 0)
	E.db.actor._pos = vec(2000, 0, 0)
	H.timers = {}
	local sent0 = #H.sent
	lf.prometheus_kill_actor()
	check(#H.timers == 1 and H.timers[1].name:find("revenge_500", 1, true), "the revenge is prepared for the client")
	run_timers(H)
	local kills = sent_named(H, "mods.nta_kill")
	check(#kills == 1 and kills[1].target == 1, "the client dies, not the far host")
	check(#H.sent > sent0, "(an order went out)")
	E.LIFE[500] = "wounded"
	H.timers = {}
	lf.prometheus_kill_actor()
	check(#H.timers == 0, "nobody standing at the finale: nobody dies")
	E.LIFE[500] = nil
	H.objects[500]._pos = vec(2000, 0, 0)
	E.db.actor._pos = vec(12, 0, 0)
	E.coop_npc_players.invalidate()
	H.timers = {}
	lf.prometheus_kill_actor()
	check(H.timers[1] and H.timers[1].name:find("the_living_fire_prometheus_revenge", 1, true), "the host at the finale: the stock way")

	print("== Mirage: the blasts fall on the player at the fight, the forced return is off")
	H, E = host_world()
	E.mirage_configs = {
		teleport_activator_center_point = vec(0, 0, 0), teleport_activation_distance = 190, burer_spawn_config = {},
		first_spawn_activator = vec(9000, 0, 0), first_spawn_activation_distance = 1, second_spawn_activator = vec(9000, 0, 0),
		second_spawn_activation_distance = 1, third_spawn_activator = vec(9000, 0, 0), third_spawn_activation_distance = 1,
		sidor_spawn_activator = vec(9000, 0, 0), sidor_spawn_activation_distance = 1,
	}
	E.SIMBOARD = { get_smart_by_name = function() return { position = vec(0, 0, 0), id = 5 } end }
	local mi = load_real(H, "tasks_mirage")
	N = start_nta(H)
	E.nta_utils.levels.zaton = "zaton"
	local fn = E.task_status_functor.mirage_task_status_functor
	mi.load_state({ mirage_task_data = { enemy_ids = {} } })
	E.db.actor._pos = vec(1000, 0, 0) -- the host respawned far away
	H.objects[500]._pos = vec(1000, 0, 500)
	fn({ stage = 3 }, "t")
	check(E.db.actor._pos.x == 1000 and #sent_named(H, "mods.tp") == 0, "a player far from the fight stays where he respawned")
	H.objects[500]._pos = vec(100, 0, 0)
	E.db.actor._pos = vec(3000, 0, 0)
	local at
	E.nta_utils.spawn_at_position = function() end
	mi.start_explosions_loop()
	check(H.timers and #H.timers == 1 and H.timers[1].name:find("mirage_explosion_loop", 1, true), "a player in the circle: the stock loop runs")
	at = E.db.actor:id()
	check(at == 0, "(db.actor is the host's again)")
	H.timers = {}
	H.objects[500]._pos = vec(5000, 0, 0)
	mi.start_explosions_loop()
	check(#H.timers == 1 and H.timers[1].name == "mirage_wait", "nobody in the circle: no blast on a camp, the loop waits for them")

	print("== Baba Yaga: the trap is about the players at the artefact")
	H, E = host_world()
	E.baba_yaga_configs = { art_location = { vector = vec(0, 0, 0) }, teleport_to_location = { vector = vec(500, 0, 0) },
		hag_spot = {}, karlik_spots = {}, art_sections = { "af" } }
	E.nta_utils.levels.garbage = "l02_garbage"
	E.nta_utils.is_dark_night = function() return true end
	E.nta_utils.spawn_helper = function() return 42 end
	E.nta_utils.hide_through_teleport = function() end
	local by = load_real(H, "tasks_baba_yaga")
	N = start_nta(H)
	fn = E.task_status_functor.baba_yaga_task_status_functor
	local tsk = { stage = 1 }
	by.load_state({ baba_yaga_task_data = { art_id = 77, was_teleported = false } })
	E.SE[77] = { parent_id = 65535 }
	E.db.actor._pos = vec(1000, 0, 0) -- the host across the map
	H.objects[500]._pos = vec(10, 0, 0) -- the client at the artefact
	fn(tsk, "t")
	check(tsk.stage == 1 and E.db.actor._pos.x == 1000, "the far host's pass springs nothing")
	E.SE[77].parent_id = 500
	fn(tsk, "t")
	check(tsk.stage == 2, "a client took the artefact: the trap fires")
	local tp = sent_named(H, "mods.tp")
	check(#tp == 1 and tp[1].target == 1, "the client is moved into the lair")
	check(E.db.actor._pos.x == 1000, "the far host is not")
	run_timers(H)
	check(E.db.actor._pos.x == 1000, "still not: he does not stand at the artefact")
	by.load_state({ baba_yaga_task_data = { art_id = 77, was_teleported = true, hag_id = 42 } })
	H.objects[500]._pos = vec(1000, 0, 500)
	local n_tp = #sent_named(H, "mods.tp")
	fn({ stage = 2 }, "t")
	check(#sent_named(H, "mods.tp") == n_tp and E.db.actor._pos.x == 1000, "stage 2: nobody is pulled back to the fight")
	local t2 = { stage = 2 }
	by.monster_on_death_callback(make_obj(42, 0, 0, 0))
	fn(t2, "t")
	check(t2.stage == 3, "the hag's death still ends the stage")

	print("== Operation Monolith: an item with any player starts its stage")
	H, E = host_world()
	E.coop_tasks_items = { party_object = function(sec) return sec == "pda_barbos" and H.objects[500] or nil end }
	E.level.get_time_hours = function() return 12 end
	E.alife = function() return { create = function() end } end
	E.news_manager = { send_tip = function() end }
	E.TOUCH = 0
	E.has_alife_info = function(i) return E.INFOS[i] == true end
	E.vector = vector
	local om = load_real(H, "operacia_monolith")
	E.db.actor.object = function(self, sec) return nil end
	H.callbacks.actor_on_update = {}
	N = start_nta(H)
	local given = {}
	E.db.actor.give_info_portion = function(_, i) given[i] = true end
	NOW = NOW + 20000
	om.actor_on_update()
	check(given.pda_barbos_found == true, "a client's PDA counts")
	NOW = NOW + 20000
	local client_side = E.coop.is_host
	E.coop.is_host, E.coop.is_client = function() return false end, function() return true end
	given = {}
	om.actor_on_update()
	check(next(given) == nil, "on a client the wrapper does nothing")
	E.coop.is_host, E.coop.is_client = client_side, function() return false end
end

print("== Urgent Orders: the check of the first update looks at the level of each player")
do
	local H, E = host_world(true)
	local at = {}
	E.tasks_urgent_orders = { is_from_duty = function() return false end, is_from_army = function() return false end,
		actor_on_first_update = function() at[#at + 1] = E.PEER_SEEN end }
	E.dialogs = { actor_true_isg = function() return false end }
	E.dialogs_lostzone = {}
	E.xr_effects.lttz_set_squad_enemy_to_actor = function() end
	E.utils_slht = { valid_faction_actor = function() return false end, actor_in_smart = function() return false end }
	E.coop.levels = {
		split = function() return true end,
		my_level = function() return 1 end,
		carried = function() return {} end,
		level_of_player = function(p) if p == 1 or p == 2 then return 2 end end,
	}
	H.objects[500] = nil
	E.SE[500] = { position = vec(0, 0, 0), m_game_vertex_id = 2, m_level_vertex_id = 3,
		alive = function() return true end, community = function() return "actor_stalker" end }
	local players = E.coop.players
	E.coop.players = function()
		local list = players()
		list[#list + 1] = { id = 2, avatar_id = 501 }
		return list
	end
	E.SE[501] = { position = vec(1, 0, 0), m_game_vertex_id = 2, m_level_vertex_id = 3,
		alive = function() return true end, community = function() return "actor_stalker" end }
	E.coop_quests_core.with_level_of = function(peer, fn, ...)
		E.PEER_SEEN = peer
		return fn(...)
	end
	start_nta(H)
	local his = false
	for _, p in ipairs(at) do his = his or p == 1 end
	check(his, "the player on a map server's level is looked at on his level")
end

print("== Urgent Orders, Hidden Threat, the ISG: a player of the faction is enough")
do
	local H, E = host_world()
	local OFIRST = 0
	E.tasks_urgent_orders = { is_from_duty = function() return false end, is_from_army = function() return false end,
		actor_on_first_update = function() OFIRST = OFIRST + 1 end }
	E.dialogs = { actor_true_isg = function() return false end }
	E.dialogs_lostzone = {}
	E.xr_effects.lttz_set_squad_enemy_to_actor = function() E.ENEMY_FOR = (E.ENEMY_FOR or "") .. db_id(E) end
	function db_id(env) return tostring(env.db.actor:id()) .. "," end
	E.utils_slht = { valid_faction_actor = function() return false end, actor_in_smart = function() return false end }
	local update_calls = 0
	do
		local function hidden_threat_update() update_calls = update_calls + 1 end
		E.hidden_threat = { touch = function() return hidden_threat_update end }
	end
	E.SIMBOARD = { smarts_by_names = { pri_b35 = { position = vec(5, 0, 0) } } }
	start_nta(H)
	local uo = E.tasks_urgent_orders
	E.LEVEL = "l05_bar"
	check(not uo.is_from_duty(), "nobody of Duty")
	H.objects[500]._comm = "actor_dolg"
	check(uo.is_from_duty() and not uo.is_from_army(), "a Duty client at the Bar: Duty's Urgent Orders")
	E.LEVEL = "l03_agroprom"
	check(not uo.is_from_duty(), "at Agroprom Duty has none")
	E.TASKS.bar_dolg_leader_task_urgent_orders = {}
	check(uo.is_from_duty(), "a running task says whose it is, wherever the group is")
	E.TASKS.bar_dolg_leader_task_urgent_orders = nil
	check(OFIRST >= 1, "the check of the first update runs when a player is seen")
	H.objects[500]._comm = "actor_isg"
	check(E.dialogs.actor_true_isg() == true, "an ISG client")
	E.xr_effects.lttz_set_squad_enemy_to_actor()
	check(E.ENEMY_FOR == "0,500,", "the squad turns on every player")
	local u = E.utils_slht
	H.objects[500]._comm = "actor_stalker"
	check(not u.valid_faction_actor(), "nobody of the Army: the storyline stays off")
	H.objects[500]._comm = "actor_army"
	check(u.valid_faction_actor(), "an army client is enough")
	H.objects[500]._comm = "actor_stalker"
	E.INFOS.hidden_threat_start = true
	check(u.valid_faction_actor(), "a running storyline is not ended by him leaving")
	E.INFOS.hidden_threat_start = nil
	H.objects[500]._pos = vec(6, 0, 0)
	E.db.actor._pos = vec(500, 0, 0)
	check(u.actor_in_smart("pri_b35", 3), "any player at the smart")
	E.LIFE[500] = "wounded"
	check(not u.actor_in_smart("pri_b35", 3), "not one who is down")
end

print("== Urgent Orders: the world server checks a Duty player's record on the Bar map server")
do
	local H, E = host_world(true)
	E.tasks_urgent_orders = { is_from_duty = function() return false end, is_from_army = function() return false end }
	H.objects[500] = nil
	E.SE[500] = { position = vec(0, 0, 0), m_game_vertex_id = 2, m_level_vertex_id = 3,
		alive = function() return true end, community = function() return "actor_dolg" end }
	E.coop.levels = {
		split = function() return true end,
		my_level = function() return 1 end,
		level_of_player = function(p) if p == 1 then return 2 end end,
		carried = function() return {} end,
	}
	E.alife = function() return { level_name = function(_, l) return l == 2 and "l05_bar" or "fake_start" end } end
	start_nta(H)
	check(E.tasks_urgent_orders.is_from_duty(), "a Duty player at the Bar of a map server starts Duty's Urgent Orders")
end

print("== Hidden Threat: an army player joins a game the host's first update switched off")
do
	local H, E = host_world()
	local updates = 0
	do
		local function hidden_threat_update() updates = updates + 1 end
		E.hidden_threat = { touch = function() return hidden_threat_update end }
	end
	E.utils_slht = { valid_faction_actor = function() return false end }
	E.INFOS.hidden_threat_disabled = true
	start_nta(H)
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(E.INFOS.hidden_threat_disabled == true, "nobody of the Army: the storyline stays off")
	H.objects[500]._comm = "actor_army"
	H.coop_players = true
	local N2 = load_script(H, "coop_mods_nta")
	N2.on_game_start()
	-- the new adapter's two: its per-frame poll and its one-shot late install
	local cbs = H.callbacks.actor_on_update
	H.callbacks.actor_on_update = { cbs[#cbs - 1], cbs[#cbs] }
	H.timers = {}
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(E.INFOS.hidden_threat_disabled == nil, "an army client: on again")
	check(H.timers[1] and H.timers[1].name == "stht_update", "its time event runs again")
end

print("== Hidden Threat: its rank gate counts an army client, not the host alone")
do
	local H, E = host_world()
	local NEWS = {}
	do
		-- hidden_threat.script's shape: cond_rank (:12) is an upvalue of the local hidden_threat_update only, which the
		-- local actor_on_first_update holds, which the module function on_game_start holds (two levels down)
		local cond_rank = 1000
		local function hidden_threat_update() return cond_rank end
		local function actor_on_first_update() return hidden_threat_update end
		E.hidden_threat = { on_game_start = function() return actor_on_first_update end }
	end
	E.utils_slht = { valid_faction_actor = function() return true end,
		HTCreateNews = function(_, msg) NEWS[#NEWS + 1] = msg end }
	H.objects[500]._comm = "actor_army"
	H.objects[500].character_rank = function() return 400 end
	E.db.actor.character_rank = function() return 100 end
	start_nta(H)
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(E.INFOS.hidden_threat_start == nil, "under the rank: not yet")
	H.objects[500].character_rank = function() return 1200 end
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(E.INFOS.hidden_threat_start == true and NEWS[1] == "st_sl_hidden_threat_msg_start", "the army client reached it: the stock start")
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(#NEWS == 1, "once")
	E.INFOS.hidden_threat_start = nil
	E.INFOS.hidden_threat_disabled = true
	NOW = NOW + 6000
	H.fire("actor_on_update")
	check(E.INFOS.hidden_threat_start == nil, "a storyline that is off stays off")
end

-- The real hidden_threat.script, loaded the game's way (unlocalize.lua: no unlocalizer lists it, its locals stay locals).
-- Live shape: on_game_start -> actor_on_first_update -> hidden_threat_update -> cond_rank = 1000.
if have_file(gamma("hidden_threat")) then
	local unloc = dofile("tests/lua/support/unlocalize.lua")
	for _, dedicated in ipairs({ false, true }) do
		print("== Hidden Threat, the real script, " .. (dedicated and "Server (the world server, the player on a map server)"
			or "Co-op (the host, the client on his map)") .. ": an army player's rank starts it")
		local H, E = host_world(dedicated)
		local NEWS = {}
		E.utils_slht = { valid_faction_actor = function() return true end,
			HTCreateNews = function(_, msg) NEWS[#NEWS + 1] = msg end }
		local f = assert(unloc.loadfile(gamma("hidden_threat")))
		local ht = setmetatable({}, { __index = E })
		E.hidden_threat = ht
		setfenv(f, ht)
		f()
		ht.on_game_start()
		E.db.actor.character_rank = function() return 100 end
		local rank = 999
		if dedicated then
			H.objects[500] = nil
			E.SE[500] = { position = vec(0, 0, 0), m_game_vertex_id = 2, m_level_vertex_id = 3,
				alive = function() return true end, community = function() return "actor_army" end, rank = function() return rank end }
			E.coop.levels = {
				split = function() return true end,
				my_level = function() return 1 end,
				level_of_player = function(p) if p == 1 then return 2 end end,
				carried = function() return {} end,
			}
			E.alife = function() return { level_name = function(_, l) return l == 2 and "l05_bar" or "fake_start" end } end
		else
			H.objects[500]._comm = "actor_army"
			H.objects[500].character_rank = function() return rank end
		end
		start_nta(H)
		NOW = NOW + 6000
		H.fire("actor_on_update")
		check(E.INFOS.hidden_threat_start == nil and #NEWS == 0, "rank 999: under the script's cond_rank, not yet")
		rank = 1000
		NOW = NOW + 6000
		H.fire("actor_on_update")
		check(E.INFOS.hidden_threat_start == true and NEWS[1] == "st_sl_hidden_threat_msg_start",
			"rank 1000 = the script's cond_rank: the army player starts it the stock way")
		NOW = NOW + 6000
		H.fire("actor_on_update")
		check(#NEWS == 1, "once")
	end

	print("== Hidden Threat, the real script, single player: only the stock update starts it")
	do
		local H, E = host_world()
		E.coop.is_active = function() return false end
		local NEWS = {}
		E.utils_slht = { valid_faction_actor = function() return true end,
			HTCreateNews = function(_, msg) NEWS[#NEWS + 1] = msg end }
		E.ResetTimeEvent, E.RemoveTimeEvent = function() end, function() end
		local f = assert(unloc.loadfile(gamma("hidden_threat")))
		local ht = setmetatable({}, { __index = E })
		E.hidden_threat = ht
		setfenv(f, ht)
		f()
		ht.on_game_start()
		E.db.actor._comm = "actor_army"
		E.db.actor.character_rank = function() return 1200 end
		E.db.actor.give_info_portion = function(_, i) E.INFOS[i] = true end
		start_nta(H)
		NOW = NOW + 6000
		H.fire("actor_on_update")
		check(E.INFOS.hidden_threat_start == nil and #NEWS == 0, "no session: the co-op poll starts nothing")
		H.timers = {}
		H.fire("actor_on_first_update")
		check(H.timers[1] and H.timers[1].name == "stht_update", "the stock first update schedules its own update")
		run_timers(H)
		check(E.INFOS.hidden_threat_start == true and #NEWS == 1 and NEWS[1] == "st_sl_hidden_threat_msg_start",
			"the stock update starts it once, for db.actor")
	end
else
	print("  (GAMMA hidden_threat.script not found: the real Hidden Threat check is skipped)")
end

print("== Mystery of the Swamps: the ghost's blow lands on the player nearest to it")
do
	local H, E = host_world()
	E.mystery_of_the_swamps_configs = { garbage_ghost_configs = { { vector = vec(100, 0, 0) } } }
	local hurt
	E.tasks_mystery_of_the_swamps = { spawn_garbage_ghost = function(args)
		E.nta_utils.set_timeout(function()
			if args.bonk_actor then hurt = E.db.actor:id() end
		end, 1)
	end }
	start_nta(H)
	H.objects[500]._pos = vec(101, 0, 0)
	E.tasks_mystery_of_the_swamps.spawn_garbage_ghost({ bonk_actor = true })
	E.NTA_TIMER()
	check(hurt == 500, "the client near the ghost takes it, not the far host")
	check(E.db.actor:id() == 0, "db.actor is the host's again")
	hurt = nil
	H.objects[500]._pos = vec(5000, 0, 0)
	E.db.actor._pos = vec(100, 0, 1)
	E.tasks_mystery_of_the_swamps.spawn_garbage_ghost({ bonk_actor = true })
	E.NTA_TIMER()
	check(hurt == 0, "the host near it: his")
	local plain = E.nta_utils.set_timeout
	E.tasks_mystery_of_the_swamps.spawn_garbage_ghost({ bonk_actor = false })
	check(E.nta_utils.set_timeout == plain, "nta_utils is left as it was")
end

print("== the group's own status passes: a player who is down")
do
	local H, E = host_world()
	E.db.actor._pos = vec(10, 0, 0)
	H.objects[500]._pos = vec(10, 0, 0)
	local started = 0
	E.task_status_functor.big_game_task_status_functor = function(tsk)
		if tsk.stage == 0 and E.db.actor:position():distance_to(vec(0, 0, 0)) < 35 then
			started = started + 1
			tsk.stage = 1
		end
	end
	start_nta(H)
	local fn = E.task_status_functor.big_game_task_status_functor
	E.LIFE[0], E.LIFE[500] = "wounded", "dead"
	local tsk = { stage = 0 }
	fn(tsk, "t")
	check(started == 0 and tsk.stage == 0, "the group lies at the trigger: nothing starts")
	E.LIFE[500] = nil
	fn(tsk, "t")
	check(tsk.stage == 1, "a client on his feet starts it, the host is down")
end

print("== a status pass for a player on another level: his level, his place")
do
	local H, E = host_world(true)
	local LV = { [1] = "l03_agroprom", [2] = "l02_garbage", [3] = "fake_start" }
	E.game_graph = function() return { vertex = function(_, v) return { level_id = function() return v end } end } end
	local sim = {}
	function sim:level_name(l) return LV[l] end
	function sim:switch_distance() return 150 end
	function sim:actor() return { id = 0 } end
	E.alife = function() return sim end
	E.db.anomaly_by_name = {}
	E.vector = vector
	H.objects[500] = nil
	E.SE[500] = { id = 500, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 3, position = vec(30, 0, 0), online = true,
		alive = function() return true end, community = function() return "actor_stalker" end }
	E.coop.levels = {
		split = function() return true end,
		my_level = function() return 3 end,
		level_of_player = function(peer) if peer == 1 then return E.HIS_LEVEL end end,
		carried = function() return {} end,
		map_servers = function() return { { bridge = 0x101, level = 2 } } end,
	}
	E.HIS_LEVEL = 2
	load_script(H, "coop_srv_quests_far").on_game_start()
	local passes = {}
	E.task_status_functor.hold_the_ground_task_status_functor = function(tsk)
		passes[#passes + 1] = { E.level.name(), E.db.actor:id() }
		if E.level.name() ~= "l02_garbage" then return "fail" end
		if tsk.stage == 0 and E.db.actor:position():distance_to(vec(25, 0, 0)) < 10 then tsk.stage = 1 end
	end
	start_nta(H)
	local fn = E.task_status_functor.hold_the_ground_task_status_functor
	local tsk = { stage = 0 }
	local r = fn(tsk, "t")
	check(#passes == 1, "only the player's pass reaches the positional check")
	check(passes[1] and passes[1][2] ~= 0, "the ghost does not get a task pass")
	check(passes[1] and passes[1][1] == "l02_garbage" and passes[1][2] == 500, "the player is checked on his map")
	check(tsk.stage == 1, "his pass moves the stage: a positional task starts on a map server's level")
	check(r == nil, "and the check stays in progress")
	check(E.level.name() == "fake_start", "the far view returns to the service level")
	tsk.stage = 2
	E.SE[500].m_game_vertex_id = 1
	E.HIS_LEVEL = 1
	r = fn(tsk, "t")
	check(r == "fail", "nobody on that level: the stock's fail")
end

print("== Big Game: a giant that went offline is not a dead one")
do
	local H, E = host_world()
	E.task_status_functor.big_game_task_status_functor = function(tsk) tsk.stage = 2 end
	local state = { small_giants_ids = { 700 } }
	E.tasks_big_game = { touch = function() return state end }
	start_nta(H)
	local fn = E.task_status_functor.big_game_task_status_functor
	E.SE[700] = { alive = function() return true end }
	local tsk = { stage = 1 }
	fn(tsk, "t")
	check(tsk.stage == 1, "offline and alive: the stage waits")
	H.add(make_obj(700, 0, 0, 0))
	fn(tsk, "t")
	check(tsk.stage == 2, "online: the task's own test")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
