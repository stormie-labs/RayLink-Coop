-- TZ P45 leftovers (P45b, Dev 58, report RL-89RT-DQYR #1664), Server: the orders of the world server's far view.
-- 1. One held order per (object, verb, arguments). The stock check of a recover-item task (tasks_recover_item_on_corpse) runs
--    kill_if_online(corpse) and kill_if_online_mutant(critter) at every check of the task. Inside the far view each call was a new
--    order to the map server, up to 5 sends each, while the world's record still said "alive" and "no info": a flood of kill,
--    info and hit orders. A repeat while one is held adds nothing; once it is answered, carried out on the record or dropped,
--    a new one may be made. give_money adds up: two of the same amount are two payments, it is never merged. The world's record
--    does not learn an info a map server gives (no caller of LevelSide::level_info_up yet): the stand-in's has_info answers what
--    the far view's orders gave or took, or the stock's guard (has_info, then give_info_portion and a hit) repeats after every
--    answer.
--    A setting merges with its newest order only. A, B, A sends all three on creation but keeps only the last one for retry
--    or carry-out (W3C-far). A late ack of a superseded order is ignored.
-- 2. The far hit edge. Inside a scope hit() is the far view's table, and the engine's game_object:hit takes only its own hit:
--    a far hit given to a game object of the world server raises luabind's "no overload". The only game object of the world
--    server a task can reach is its ghost actor, and no player is meant by a hit on it: the scan below (task and dialog
--    scripts) and the report of P45b (configs of tasks and dialogs; the relayed callbacks). The one task that hits "the
--    actor" (tasks_mystery_of_the_swamps.spawn_garbage_ghost) runs its timer as the nearest standing player (coop_mods_nta
--    install_mystery, coop_mods_core.as_player): db.actor is his stand-in. Its first line played a 2D sound on db.actor, and the
--    engine's sound_object took no stand-in: luabind's "no overload of 'sound_object:play'" ended the timer before the blow
--    (found by the verifier of P45b). Fix round FP45b: inside a scope a sound object takes a stand-in as no owner, the blow is
--    an order "hit" on his avatar. Tested through the real wrapper chain, the stock's timer firing after the check.
-- Every answer set, each its own process (tools\test_lua.cmd sets COOP_LUA_MODE): srv_world (the far view and its orders),
-- srv_map (a map server: it makes no order, a repeated far_do runs once), hostplay and none (the far view is never set up:
-- coop_mode.when_srv does not run there; the stock acts on the objects of its own process as before).
-- Real scripts over the stubs (the setup of test_issue_p45_kill_record.lua). Run: tools\test_lua.cmd issue_p45b
MODE = "host"
dofile("tests/lua/support/stubs.lua")
dofile("tests/lua/support/mod_source.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BS = string.char(92)
local LEVELS = { [10] = 1, [20] = 2, [30] = 3 } -- game vertex -> level
game_graph = function()
	return { vertex = function(_, v) return { level_id = function() return LEVELS[v] end } end }
end
local function vec(x, y, z)
	return setmetatable({ x = x, y = y, z = z }, { __index = {
		distance_to_sqr = function(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 end } })
end
vector = function() return { set = function(_, x, y, z) return vec(x, y, z) end } end
local function alive_fn(v) return function() return v end end

-- the engine's hit (script_hit_script.cpp): its draftsman is a game object, anything else is luabind's error
local HIT_MT = {}
HIT_MT.__index = function(h, k) return rawget(h, "fields")[k] end
HIT_MT.__newindex = function(h, k, v)
	if k == "draftsman" and v ~= nil and not (type(v) == "table" and rawget(v, "engine_object")) then
		error("luabind: the value at stack #3 is a table, a C++ object was expected", 2)
	end
	rawget(h, "fields")[k] = v
end
local STOCK_HIT = setmetatable({ burn = 0, wound = 5, fire_wound = 6, strike = 7 }, { __call = function()
	return setmetatable({ fields = { power = 100, impulse = 100, type = 5 } }, HIT_MT)
end })

-- a game object of this process (the engine's): game_object:hit takes only the engine's hit
local ENGINE = {}
ENGINE.__index = ENGINE
local function engine_object(id)
	return setmetatable({ engine_object = true, oid = id, kills = 0, hits = {}, infos = {}, is_alive = true }, ENGINE)
end
function ENGINE:id() return self.oid end
function ENGINE:alive() return self.is_alive end
function ENGINE:position() return vec(1, 0, 1) end
function ENGINE:game_vertex_id() return 10 end
function ENGINE:direction() return vec(0, 0, 1) end
function ENGINE:kill(who)
	self.kills = self.kills + 1
	self.is_alive = false
end
function ENGINE:has_info(name) return self.infos[name] == true end
function ENGINE:give_info_portion(name) self.infos[name] = true return true end
function ENGINE:disable_info_portion(name) self.infos[name] = nil end
function ENGINE:set_health_ex(value) self.health = value end
function ENGINE:give_game_news() end
function ENGINE:hit(h)
	if getmetatable(h) ~= HIT_MT then
		error("no overload of  'game_object:hit' matched the arguments (game_object, table)", 2)
	end
	self.hits[#self.hits + 1] = { power = h.power, type = h.type }
end

-- the world: records of level 2 (a map server's) and the engine's answers
local RECORDS, REAL, INFOS, KILLS, ACTOR, MAP_SERVERS
local SIM = {}
function SIM:level_name(l) return ({ "l01_escape", "y04_pole", "zaton" })[l] end
function SIM:switch_distance() return 150 end
function SIM:actor() return { id = 0, real = true } end
function SIM:has_info(id, name) return INFOS[id] ~= nil and INFOS[id][name] == true end
function SIM:give_info(id, name)
	INFOS[id] = INFOS[id] or {}
	INFOS[id][name] = true
end
function SIM:disable_info(id, name) if INFOS[id] then INFOS[id][name] = nil end end
function SIM:release(se) RECORDS[se.id] = nil end
function SIM:kill_entity(se) error("FATAL R_ASSERT l_tpALifeMonsterAbstract->children.empty()", 0) end
-- the world server's binding (coop_srv_script.cpp l_kill_record -> levels::host_apply_death)
local SRV = {
	kill_record = function(id, killer)
		KILLS[#KILLS + 1] = { id = id, killer = killer }
		local se = RECORDS[id]
		if not (se and se.alive and se.alive()) then return false end
		se.alive = alive_fn(false)
		return true
	end,
}

local function reset_world()
	RECORDS = {
		[500] = { id = 500, position = vec(5, 0, 5), m_level_vertex_id = 77, m_game_vertex_id = 20, parent_id = 65535, online = true }, -- player 1
		-- the corpse a recover-item task made: a stalker with the quest item inside
		[600] = { id = 600, position = vec(7, 0, 7), m_level_vertex_id = 7, m_game_vertex_id = 20, parent_id = 65535, online = true,
			section_name = function() return "sim_default_stalker_0" end, alive = alive_fn(true), clsid = function() return 44 end },
		[603] = { id = 603, position = vec(7, 0, 7), m_game_vertex_id = 20, parent_id = 600, online = false }, -- the quest item
		-- a critter of the task, near the corpse
		[650] = { id = 650, position = vec(8, 0, 8), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = true,
			section_name = function() return "dog_normal_red" end, alive = alive_fn(true), clsid = function() return 20 end },
		-- a stalker of that level, for the verbs
		[620] = { id = 620, position = vec(9, 0, 9), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = true,
			section_name = function() return "sim_default_duty_1" end, alive = alive_fn(true), clsid = function() return 44 end },
	}
	INFOS, KILLS = {}, {}
	MAP_SERVERS = { { bridge = 0x101, level = 2 } }
	ACTOR = engine_object(0) -- the world server's ghost (on a map server and in the co-op: its own actor)
	REAL = { [0] = ACTOR }
end
alife_object = function(id) return RECORDS[id] end

local PLAYERS = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
local SET = nil
coop.is_active = function() return SET ~= "none" end
coop.is_host = function() return SET == "srv_world" or SET == "hostplay" end -- the world's role: the world server, the co-op host
coop.is_client = function() return false end
coop.is_dedicated = function() return SET == "srv_world" end
coop.is_map_server = function() return SET == "srv_map" end
coop.self_id = function() return 0 end
coop.players = function() return PLAYERS end
coop.avatar_of = function(peer) return peer == 1 and 500 or nil end
coop.levels = {
	split = function() return SET == "srv_world" end,
	my_level = function() return SET == "srv_map" and 2 or 1 end,
	level_of_player = function(peer) return peer == 1 and 2 or 1 end,
	carried = function(id) return {} end,
	map_servers = function() return MAP_SERVERS end,
}

-- the transport: handlers by event name, payloads as tables (coop_quests_core decodes through coop_main)
local HANDLERS = {}
coop_main = {
	add_event_handler = function(name, fn) HANDLERS[name] = fn return true end,
	encode = function(t) return t end,
	decode = function(s) return s end,
}
local CLOCK = 1000
time_global = function() return CLOCK end
AddScriptCallback("server_entity_on_unregister") -- the stubs' axr_main knows only a few callbacks

-- A fresh process of the set: its own level, db and loaded scripts (each script installs its views once per table).
local function boot(set)
	SET = set
	reset_world()
	HANDLERS = {}
	SENT = {}
	CLOCK = 1000
	srv = SRV
	hit = STOCK_HIT
	alife = function() return SIM end
	db = { actor = ACTOR, storage = { [0] = { object = ACTOR } }, anomaly_by_name = {}, zone_by_name = {} }
	level = { object_by_id = function(id) return REAL[id] end, name = function() return "l01_escape" end }
	simulation_objects = { is_on_the_actor_level = function() return "stock" end }
	local facade = load_script_file("coop_mode")
	facade.on_game_start()
	modes.live(facade)
	load_script_file("coop_quests_core")
	load_script_file("coop_srv_quests_core").on_game_start()
	load_script_file("coop_srv_levels_share")
	load_script_file("coop_srv_quests_far")
	load_script_file("coop_mods_core")
	coop.sync = { on = function() end }
	load_script_file("coop_npc_players")
	load_script_file("coop_world_fx").on_game_start()
	local qc, far = coop_quests_core, coop_srv_quests_far
	qc.on_game_start()
	far.on_game_start()
	qc.send = function(name, t, target) SENT[#SENT + 1] = { name = "quests." .. name, payload = t, target = target } return true end
	return facade, qc, far
end

local function sent(name, v, id)
	local out = {}
	for _, s in ipairs(SENT) do
		if s.name == name and (v == nil or s.payload.v == v) and (id == nil or s.payload.i == id) then out[#out + 1] = s.payload end
	end
	return out
end
local function far_do(v, id) return sent("quests.far_do", v, id) end
local function qs(list)
	local seen, n = {}, 0
	for _, p in ipairs(list) do
		if not seen[p.q] then seen[p.q], n = true, n + 1 end
	end
	return n
end

-- the stock: what the task checks run (the real G.A.M.M.A. files)
assert(GAMMA_DIR and have_file(GAMMA_DIR .. BS .. "tasks_recover_item_on_corpse.script"),
	"real GAMMA tasks_recover_item_on_corpse.script required (GAMMA_SCRIPTS)")
local kill_if_online, kill_if_online_mutant = mod_chunk(GAMMA_DIR .. BS .. "tasks_recover_item_on_corpse.script",
	{ "function kill_if_online(id)", "function kill_if_online_mutant(id, random_push)" }, "tasks_recover_item_on_corpse",
	"return kill_if_online, kill_if_online_mutant")
assert(type(kill_if_online_mutant) == "function", "kill_if_online_mutant: " .. tostring(kill_if_online))
-- the ghost's blow of Mystery of the Swamps: the stock function and the stock timer (nta_utils.set_timeout -> CreateTimeEvent), the real
-- wrapper of coop_mods_nta (install_mystery) over them; the timer fires after the check, outside its scope (the scope's CreateTimeEvent
-- opens it again, as in the game)
tasks_mystery_of_the_swamps = { configs = { garbage_ghost_configs = {} }, state = { mutant_ids = {} } }
nta_utils = { mass_spawn_helper = function() end, delayed_message_by_story_id = function() end, timeout_helper = 0 }
mystery_of_the_swamps_configs = { garbage_ghost_configs = { { vector = vec(5, 0, 6) } } } -- the ghost's spot, a metre from player 1
local set_timeout = mod_chunk(GAMMA_DIR .. BS .. "nta_utils.script", { "function set_timeout(callback, timeout)" }, "nta_utils",
	"return set_timeout")
assert(type(set_timeout) == "function", "set_timeout of nta_utils.script: " .. tostring(set_timeout))
-- The engine's sound_object (script_sound_script.cpp) takes only an engine game_object or nil as owner.
local PLAYS = {}
local SOUND_MT = {}
SOUND_MT.__index = SOUND_MT
local function sound_play(self, method, obj, delay, flags, pos, volume, frequency)
	if obj ~= nil and getmetatable(obj) ~= ENGINE then
		error("no overload of 'sound_object:" .. method .. "' matched owner type " .. type(obj), 2)
	end
	PLAYS[#PLAYS + 1] = { path = self.path, owner = obj, delay = delay, flags = flags, pos = pos,
		volume = volume or self.volume, frequency = frequency }
end
function SOUND_MT:length() return 1 end
function SOUND_MT:play(obj, delay, flags) sound_play(self, "play", obj, delay, flags) end
function SOUND_MT:play_at_pos(obj, pos, delay, flags) sound_play(self, "play_at_pos", obj, delay, flags, pos) end
function SOUND_MT:play_no_feedback(obj, flags, delay, pos, volume, frequency)
	sound_play(self, "play_no_feedback", obj, delay, flags, pos, volume, frequency)
end
local STOCK_SOUND = setmetatable({ s2d = 2, s3d = 0, looped = 1 }, { __call = function(_, path)
	return setmetatable({ path = path }, SOUND_MT)
end })
sound_object = STOCK_SOUND
local SOUNDS = {}
xr_sound = { get_safe_sound_object = function(path)
	SOUNDS[path] = SOUNDS[path] or sound_object(path)
	return SOUNDS[path]
end }
local function stock_sound_script(name)
	local path = GAMMA_DIR .. BS .. name .. ".script"
	if have_file(path) then return path end
	path = "../anomaly-ref/unpacked/scripts/" .. name .. ".script"
	if have_file(path) then return path end
	return "temp/stock_scripts/scripts/" .. name .. ".script"
end
local ZERO = vec(0, 0, 0)
local CAPTION_OWNER
sound_theme = {
	actor_sound = {}, theme = {}, can_play_sound = {}, VEC_ZERO = ZERO,
	closecaption = { sound = function(_, _, actor) CAPTION_OWNER = actor return true end },
}
assert(mod_chunk(stock_sound_script("sound_theme"),
	{ "function actor_sound:play(", "function actor_sound:select_next_sound(" },
	"sound_theme", "return actor_sound.play"))
assert(mod_chunk(stock_sound_script("xr_sound"), { "function set_sound_play(" }, "xr_sound", "return set_sound_play"))
local teleport_visuals = {}
for _, name in ipairs({ "nta_utils", "new_tasks_addon_tasks_utils" }) do
	local f = assert(mod_chunk(GAMMA_DIR .. BS .. name .. ".script", { "function teleport_visual()" }, name, "return teleport_visual"))
	local m = _G[name]
	m.VEC_ZERO = vec(0, 0, 0)
	m.teleport_visual = f
	teleport_visuals[#teleport_visuals + 1] = m
end
do
	dialogs_lostzone = { txr_routes = { open_route = function() end },
		game = { translate_string = function(s) return s end } }
	dialogs_lostzone.unlock_routes_south = assert(mod_chunk(GAMMA_DIR .. BS .. "dialogs_lostzone.script",
		{ "function unlock_routes_south(" }, "dialogs_lostzone", "return unlock_routes_south"))
	xr_effects = {}
	xr_effects.play_sound_on_actor = assert(mod_chunk(GAMMA_DIR .. BS .. "xr_effects.script",
		{ "function play_sound_on_actor(" }, "xr_effects", "return play_sound_on_actor"))
end
local spawn_garbage_ghost = mod_chunk(GAMMA_DIR .. BS .. "tasks_mystery_of_the_swamps.script", { "function spawn_garbage_ghost(args)" },
	"tasks_mystery_of_the_swamps", "return spawn_garbage_ghost")
assert(type(spawn_garbage_ghost) == "function", "spawn_garbage_ghost of tasks_mystery_of_the_swamps.script")
AddScriptCallback("actor_on_first_update") -- coop_srv_quests_far patch_world_calls, coop_mods_nta late_install

local TASK = "bar_dolg_general_petrenko_stalker_task_rioc_pol"
-- one check of the task, as coop_quests_party runs it: on the level of its target, for the player who stands there
local function task_check(qc)
	return pcall(qc.with_target, 600, 1, TASK, function()
		kill_if_online(600)
		kill_if_online_mutant(650, true)
	end)
end

local function superseded_settings(far)
	local function ack(p, result)
		HANDLERS["quests.far_ack"]({ q = p.q, r = result }, 0x101)
	end
	local function offline_send(call)
		call()
		local send = SENT[#SENT].payload
		ack(send, 0)
		return send
	end
	local function online_retry(verb, newest, apply)
		SENT = {}
		CLOCK = CLOCK + 4000
		far._test.tick()
		local sends = far_do(verb, 620)
		-- Deliver the retries newest first to expose any stale setting that can still overwrite it.
		for i = #sends, 1, -1 do
			apply(sends[i])
			ack(sends[i], 1)
		end
		check(#sends == 1 and sends[1].q == newest.q, newest.v .. ": only the newest setting is retried, got " .. #sends)
	end

	print("== srv_world: r = 0 on both health orders, then online: B is the only retry")
	local npc = far.object(620)
	local map_npc = engine_object(620)
	local a = offline_send(function() npc:set_health_ex(1) end)
	local b = offline_send(function() npc:set_health_ex(0.5) end)
	check(far.orders_held() == 1 and far._test.stats().superseded == 1, "health A was superseded once")
	far.print_status()
	check(LOG[#LOG]:find("superseded 1", 1, true) ~= nil, "far status counts superseded orders")
	local acked = far._test.stats().acks
	ack(a, 0)
	check(far._test.stats().acks == acked and far.orders_held() == 1, "late r = 0 of health A is ignored")
	online_retry("health", b, function(p) map_npc:set_health_ex(p.a) end)
	check(map_npc.health == 0.5 and far.orders_held() == 0, "map server ends on health B and answers it")

	print("== srv_world: info then uninfo share a setting on retries")
	local name = "p45b_superseded"
	offline_send(function() npc:give_info_portion(name) end)
	local remove = offline_send(function() npc:disable_info_portion(name) end)
	check(not npc:has_info(name), "the stand-in remembers uninfo before the map answers")
	online_retry(nil, remove, function(p)
		if p.v == "info" then map_npc:give_info_portion(p.a) else map_npc:disable_info_portion(p.a) end
	end)
	check(not map_npc:has_info(name), "map server ends on uninfo")
	far._test.orders_clear()

	print("== srv_world: A, B, A makes a new A and retires both earlier orders")
	a = offline_send(function() npc:set_health_ex(1) end)
	b = offline_send(function() npc:set_health_ex(0.5) end)
	local last = offline_send(function() npc:set_health_ex(1) end)
	check(last.q ~= a.q and last.q ~= b.q, "last A is a new order")
	acked = far._test.stats().acks
	ack(a, 1)
	check(far._test.stats().acks == acked, "late r = 1 of the first A is ignored")
	local sent_count, repeats = #SENT, far._test.stats().repeats
	check(far.order(620, "health", 1) == true and #SENT == sent_count and far._test.stats().repeats == repeats + 1,
		"repeating the newest A merges")
	online_retry("health", last, function(p) map_npc:set_health_ex(p.a) end)
	check(map_npc.health == 1 and far.orders_held() == 0, "map server ends on the last A")

	print("== srv_world: money and kill still have independent orders")
	local n = far._test.stats().superseded
	SENT = {}
	local kill = offline_send(function() npc:kill(npc) end)
	offline_send(function() npc:give_money(100) end)
	offline_send(function() npc:give_money(100) end)
	check(#far_do("money", 620) == 2 and qs(far_do("money", 620)) == 2 and far.orders_held() == 3
		and far._test.stats().superseded == n, "two identical payments and the kill are all held")
	offline_send(function() npc:set_health_ex(0.5) end)
	offline_send(function() npc:set_health_ex(1) end)
	SENT = {}
	CLOCK = CLOCK + 4000
	far._test.tick()
	local kills = far_do("kill", 620)
	check(#kills == 1 and kills[1].q == kill.q and #far_do("money", 620) == 2, "setting changes do not retire kill or money")
	far._test.orders_clear()

	print("== srv_world: a map server gone, only the last info setting is carried out on the ALife record")
	SIM:give_info(620, name)
	offline_send(function() npc:give_info_portion(name) end)
	offline_send(function() npc:disable_info_portion(name) end)
	local carried = far._test.stats().on_record
	MAP_SERVERS = {}
	far._test.tick()
	check(far._test.stats().on_record == carried + 1 and not SIM:has_info(620, name) and far.orders_held() == 0,
		"only uninfo was carried out on the record")
	MAP_SERVERS = { { bridge = 0x101, level = 2 } }
	SENT = {}
end

-------------------------------------------------------------------------------
local function world_server()
	local _, qc, far = boot("srv_world")
	superseded_settings(far)
	local N = 12

	print("== srv_world: N checks of the recover-item task while its orders are held: one order each")
	local ok, err = true, nil
	for _ = 1, N do
		local okc, errc = task_check(qc)
		if not okc then ok, err = okc, errc end
	end
	check(ok, "every check runs to its end: " .. tostring(err))
	check(#far_do("kill", 600) == 1 and far_do("kill", 600)[1].a == 600, "the corpse: one kill order, one send: " .. #far_do("kill", 600))
	check(#far_do("info", 650) == 1 and far_do("info", 650)[1].a == "mutant_to_kill", "the critter: one info order: " .. #far_do("info", 650))
	check(#far_do("hit", 650) == 1, "the critter: one hit order: " .. #far_do("hit", 650))
	check(far.orders_held() == 3, "three orders held: " .. far.orders_held())

	print("== the map server says the objects are not online there (r = 0): held, the checks still add nothing")
	for _, p in ipairs(far_do()) do HANDLERS["quests.far_ack"]({ q = p.q, r = 0 }, 0x101) end
	for _ = 1, N do task_check(qc) end
	check(far.orders_held() == 3 and #far_do() == 3, "still three held, three sent: " .. far.orders_held() .. ", " .. #far_do())

	print("== the resends between the checks: at most five sends of each, then the record takes them")
	for _ = 1, 6 do
		CLOCK = CLOCK + 4000
		local okt, errt = pcall(far._test.tick)
		check(okt, "the tick ends: " .. tostring(errt))
		for _ = 1, N do task_check(qc) end
	end
	check(qs(far_do("kill", 600)) == 1 and #far_do("kill", 600) == 5, "the kill: one order, five sends: " .. #far_do("kill", 600))
	check(qs(far_do("info", 650)) == 1 and #far_do("info", 650) == 5, "the info: one order, five sends: " .. #far_do("info", 650))
	check(qs(far_do("hit", 650)) == 1 and #far_do("hit", 650) == 5, "the hit: one order, five sends: " .. #far_do("hit", 650))
	check(#KILLS == 1 and KILLS[1].id == 600 and not RECORDS[600].alive(), "the corpse died once, through srv.kill_record: " .. #KILLS)
	check(SIM:has_info(650, "mutant_to_kill"), "the critter's record has the info")
	check(far.orders_held() == 0, "nothing held: the checks see a dead corpse and the info: " .. far.orders_held())

	print("== a map server that answers at once (r = 1): the info it gave is the stand-in's, the stock's guard holds")
	-- the world's record does not learn an info a map server gives (no caller of LevelSide::level_info_up yet): has_info of the
	-- stand-in answers what the far view's orders gave, so kill_if_online_mutant does not give and hit again at every check
	RECORDS[660] = { id = 660, position = vec(8, 0, 8), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = true,
		section_name = function() return "dog_normal_red" end, alive = alive_fn(true), clsid = function() return 20 end }
	SENT = {}
	local acked = {}
	for _ = 1, N do
		pcall(qc.with_target, 660, 1, TASK, function() kill_if_online_mutant(660, true) end)
		for _, p in ipairs(far_do()) do
			if not acked[p.q] then
				acked[p.q] = true
				HANDLERS["quests.far_ack"]({ q = p.q, r = 1 }, 0x101)
			end
		end
	end
	check(#far_do("info", 660) == 1 and #far_do("hit", 660) == 1 and far.orders_held() == 0,
		"one info, one hit in all: " .. #far_do("info", 660) .. ", " .. #far_do("hit", 660))
	check(not SIM:has_info(660, "mutant_to_kill") and far.object(660):has_info("mutant_to_kill")
		and not far.object(660):dont_has_info("mutant_to_kill"), "the record has no info, the stand-in has it")
	far.object(660):disable_info_portion("mutant_to_kill")
	check(not far.object(660):has_info("mutant_to_kill") and far.object(660):dont_has_info("mutant_to_kill"), "taken away: no longer")
	check(not far.object(620):has_info("mutant_to_kill"), "another object: the record answers")
	far.object(660):give_info_portion("mutant_to_kill")
	SendScriptCallback("server_entity_on_unregister", RECORDS[660])
	check(not far.object(660):has_info("mutant_to_kill"), "the record unregistered: the far view forgets what it gave")
	far._test.orders_clear()

	print("== the hits a task waits for, relayed: the stock's set_health_ex at each one is one held order (tasks_the_living_fire)")
	SENT = {}
	qc.add_death_listener("npc_on_before_hit", function(npc, h) npc:set_health_ex(1) end)
	for _ = 1, N do HANDLERS["quests.far_hit"]({ c = "npc_on_before_hit", i = 620, k = 500, p = 1, t = 5 }, 0x101) end
	check(#far_do("health", 620) == 1 and far.orders_held() == 1, "one health order: " .. #far_do("health", 620))
	far._test.orders_clear()

	print("== answered, carried out or dropped: a new one may be made")
	SENT = {}
	local s = far.object(620)
	for _ = 1, 3 do s:give_info_portion("p45b_a") end
	check(#far_do("info", 620) == 1 and far.orders_held() == 1, "held: one")
	HANDLERS["quests.far_ack"]({ q = far_do("info", 620)[1].q, r = 1 }, 0x101)
	check(far.orders_held() == 0, "the map server did it (r = 1): no longer held")
	s:give_info_portion("p45b_a")
	check(#far_do("info", 620) == 2 and qs(far_do("info", 620)) == 2 and far.orders_held() == 1, "the next one is a new order")
	MAP_SERVERS = {}
	pcall(far._test.tick)
	check(far.orders_held() == 0 and SIM:has_info(620, "p45b_a"), "its map server is gone: carried out on the record")
	MAP_SERVERS = { { bridge = 0x101, level = 2 } }
	s:give_info_portion("p45b_a")
	check(far.orders_held() == 1 and qs(far_do("info", 620)) == 3, "and after that a new one again")
	far._test.orders_clear()
	RECORDS[630] = { id = 630, position = vec(9, 0, 9), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = true,
		alive = alive_fn(true) }
	for _ = 1, 3 do far.object(630):kill() end
	check(far.orders_held() == 1, "a kill on a record: held once")
	local kill_dropped, log_from = far._test.stats().dropped, #LOG
	RECORDS[630] = nil
	CLOCK = CLOCK + 4000
	pcall(far._test.tick)
	check(far.orders_held() == 0, "the record is no more: the order is dropped")
	check(far._test.stats().dropped == kill_dropped + 1 and LOG[log_from + 1]
		and LOG[log_from + 1]:find("far: order kill on 630 dropped: the object is no more", 1, true),
		"a missing kill target still counts as dropped and logs why")
	far.order(630, "kill")
	check(far.orders_held() == 1, "after the drop a new one may be made")
	far._test.orders_clear()

	print("== srv_world: a held release whose record is gone is done silently")
	RECORDS[630] = { id = 630, m_game_vertex_id = 20, parent_id = 65535 }
	check(far.order(630, "release") and far.orders_held() == 1, "the release waits for its map server")
	local carried, dropped, release_log_from = far._test.stats().on_record, far._test.stats().dropped, #LOG
	RECORDS[630] = nil
	far._test.tick()
	check(far.orders_held() == 0 and far._test.stats().on_record == carried + 1 and far._test.stats().dropped == dropped,
		"the gone release is cleared and counts as carried out")
	check(#LOG == release_log_from, "the gone release writes no log line: " .. tostring(LOG[release_log_from + 1]))

	print("== every verb of a stand-in: five calls while held, one order; other arguments, another order")
	local who = far.object(500)
	local pos = vec(1, 2, 3)
	local calls = {
		{ "kill", function() s:kill(who) end },
		{ "info", function() s:give_info_portion("p45b_x") end },
		{ "uninfo", function() s:disable_info_portion("p45b_x") end },
		{ "relation", function() s:set_relation(1, who) end },
		{ "goodwill", function() s:force_set_goodwill(100, who) end },
		{ "comm_goodwill", function() s:set_community_goodwill("dolg", 100) end },
		{ "community", function() s:set_character_community("dolg", 1, 2) end },
		{ "health", function() s:set_health_ex(1) end },
		{ "place", function() s:set_npc_position(pos); s:force_set_position(pos) end },
		{ "hit", function() s:hit({ power = 5, type = 7, draftsman = who }) end },
		{ "release", function() far.order(620, "release") end },
		{ "companion", function() far.order(620, "companion") end },
	}
	for _, c in ipairs(calls) do
		SENT = {}
		far._test.orders_clear()
		for _ = 1, 5 do c[2]() end
		check(#far_do(c[1], 620) == 1 and far.orders_held() == 1, c[1] .. ": one order: " .. #far_do(c[1], 620))
	end
	SENT = {}
	far._test.orders_clear()
	s:give_info_portion("p45b_x")
	s:give_info_portion("p45b_y")
	s:give_info_portion("p45b_x")
	s:kill(who)
	s:kill(s)
	check(far.orders_held() == 4 and #far_do() == 4, "another info, another killer: their own orders: " .. far.orders_held())
	SENT = {}
	far._test.orders_clear()
	for _ = 1, 3 do s:give_money(100) end
	check(#far_do("money", 620) == 3 and far.orders_held() == 3, "give_money adds up: three payments, three orders")
	far._test.orders_clear()

	print("== a setting given A, B, A while A is held: the map server ends on the last call, as before P45b (FP45b)")
	-- the merge is with the newest order of the same setting only: info and uninfo of one name are one setting, a relation and a
	-- goodwill are one per the other side, health, place and community one each
	local function sent_values(verb, field)
		local out = {}
		for _, p in ipairs(SENT) do
			if p.name == "quests.far_do" and p.payload.i == 620 and (verb == nil or p.payload.v == verb) then
				out[#out + 1] = verb and tostring(p.payload[field or "a"]) or p.payload.v
			end
		end
		return table.concat(out, ",")
	end
	local settings = {
		{ "info/uninfo", nil, function() s:give_info_portion("p45b_z") end, function() s:disable_info_portion("p45b_z") end, "info,uninfo,info" },
		{ "health", "health", function() s:set_health_ex(1) end, function() s:set_health_ex(0.5) end, "1,0.5,1" },
		{ "relation", "relation", function() s:set_relation(2, who) end, function() s:set_relation(0, who) end, "2,0,2" },
		{ "goodwill", "goodwill", function() s:force_set_goodwill(100, who) end, function() s:force_set_goodwill(-100, who) end, "100,-100,100" },
		{ "comm_goodwill", "comm_goodwill", function() s:set_community_goodwill("dolg", 100) end,
			function() s:set_community_goodwill("dolg", 0) end, "100,0,100", "b" },
		{ "community", "community", function() s:set_character_community("dolg", 1, 2) end,
			function() s:set_character_community("freedom", 1, 2) end, "dolg,freedom,dolg" },
		{ "place", "place", function() s:set_npc_position(vec(1, 0, 0)) end, function() s:set_npc_position(vec(4, 0, 0)) end, "1,4,1" },
	}
	for _, c in ipairs(settings) do
		SENT = {}
		far._test.orders_clear()
		c[3]()
		c[4]()
		c[3]()
		check(sent_values(c[2], c[6]) == c[5] and far.orders_held() == 1,
			c[1] .. ": A, B, A sends all three and holds only the last: " .. sent_values(c[2], c[6]))
		c[3]()
		check(#far_do() == 3, c[1] .. ": a repeat of the newest is still merged")
	end
	check(far.object(620):has_info("p45b_z") and not far.object(620):dont_has_info("p45b_z"),
		"the stand-in answers the last call, the one the map server ends on")
	SENT = {}
	far._test.orders_clear()
	s:set_health_ex(1)
	s:set_health_ex(0.5)
	s:set_health_ex(0.5)
	s:give_info_portion("p45b_w")
	s:give_info_portion("p45b_v")
	s:give_info_portion("p45b_w")
	check(far.orders_held() == 3 and sent_values("health") == "1,0.5", "A, B, B: B merged; another info name is its own setting: "
		.. far.orders_held() .. ", " .. sent_values("health"))
	HANDLERS["quests.far_ack"]({ q = far_do("health", 620)[2].q, r = 1 }, 0x101)
	s:set_health_ex(0.5)
	check(sent_values("health") == "1,0.5,0.5", "the newest answered: the same value again is a new order")
	far._test.orders_clear()
	return qc, far
end

-- The far hit edge, through the real wrapper chain: coop_mods_nta install_mystery -> nearest_standing -> coop_mods_core.as_player, the
-- stock's timer firing after the check (the scope's CreateTimeEvent opens the scope again).
local function mystery_ghost(qc, far)
	load_script_file("coop_mods_core")
	local nta = load_script_file("coop_mods_nta")
	nta.on_game_start()
	SendScriptCallback("actor_on_first_update") -- coop_srv_quests_far patch_world_calls, coop_mods_nta late_install (install_mystery)
	check(tasks_mystery_of_the_swamps.spawn_garbage_ghost ~= spawn_garbage_ghost, "coop_mods_nta wrapped spawn_garbage_ghost")
	local function ghost_blow()
		SENT, PLAYS, TIMEEV = {}, {}, {}
		local from = #LOG
		local ok, err = pcall(qc.with_level_of, 1, tasks_mystery_of_the_swamps.spawn_garbage_ghost, { bonk_actor = true })
		check(ok and #TIMEEV == 1, "the check starts the stock's timer: " .. tostring(err) .. ", " .. #TIMEEV)
		check(qc.part("far").in_scope() == nil and hit == STOCK_HIT, "the check's scope is closed")
		for _, ev in ipairs(TIMEEV) do
			local okt, errt = pcall(ev.f, unpack(ev.p))
			check(okt, "the timer runs: " .. tostring(errt))
		end
		check(qc.part("far").in_scope() == nil and hit == STOCK_HIT, "the timer's scope is closed, hit is the engine's again")
		local reported = {}
		for i = from + 1, #LOG do
			if LOG[i]:find("ghost", 1, true) then reported[#reported + 1] = LOG[i] end
		end
		return reported
	end

	print("== srv_world: the ghost's blow lands on the nearest standing player: an order on his avatar")
	local reported = ghost_blow()
	check(#reported == 0, "nothing reported: " .. table.concat(reported, " | "))
	local hits = far_do("hit")
	check(#hits == 1 and hits[1].i == 500 and hits[1].a == 1.3 and hits[1].b == STOCK_HIT.wound and hits[1].c == 500,
		"one hit order on the player's avatar, power 1.3, a wound, by himself: " .. #hits)
	check(#PLAYS == 1 and PLAYS[1].owner == nil and PLAYS[1].flags == sound_object.s2d,
		"its 2D sound plays on the world server as one of nobody (a stand-in is no owner of the engine's): " .. #PLAYS)
	check(#ACTOR.hits == 0, "the ghost is not hit")
	far._test.orders_clear()

	print("== srv_world: nobody stands on that level: no player is meant, no order, the ghost is not hit")
	local life_of = coop.life_of
	coop.life_of = function(id) return id == 500 and "down" or "alive" end
	reported = ghost_blow()
	coop.life_of = life_of
	check(#far_do() == 0 and #ACTOR.hits == 0 and far.orders_held() == 0, "no order, no hit on the ghost")
	check(#reported == 1 and reported[1]:find("no overload", 1, true) ~= nil,
		"one line: the far hit given to the ghost is luabind's error, under coop_mods_nta's pcall: " .. table.concat(reported, " | "))
	check(#PLAYS == 1 and PLAYS[1].owner == ACTOR, "the sound plays on the ghost as the stock does")

	print("== srv_world: outside a scope the stock's sound object is the engine's, untouched")
	check(xr_sound.get_safe_sound_object("x") == SOUNDS["x"], "get_safe_sound_object answers the engine's object outside a scope")
end

local function actor_theme_sound(qc, far)
	print("== srv_world: the stock PDA actor theme takes no engine owner inside a far scope")
	local function play()
		sound_theme.can_play_sound[0] = true
		sound_theme.theme.pda_tips = setmetatable({ class_id = "actor_sound", sound = { "pda/tips" }, shuffle = "rnd" },
			{ __index = sound_theme.actor_sound })
		xr_sound.sound_table = {}
		return xr_sound.set_sound_play(ACTOR:id(), "pda_tips")
	end
	PLAYS = {}
	local remote = far.object(500)
	local ok, snd = qc.with_target(620, 1, TASK, coop_mods_core.as_player, remote, play)
	local p = PLAYS[1]
	check(ok and #PLAYS == 1 and p.owner == nil and p.pos == ZERO and p.flags == STOCK_SOUND.s2d,
		"xr_sound.set_sound_play plays at the stock position with no far owner: " .. tostring(snd))
	check(ok and CAPTION_OWNER == remote and getmetatable(snd) == SOUND_MT,
		"captions keep the far actor and the theme returns its cached engine sound")
	PLAYS = {}
	snd = play()
	p = PLAYS[1]
	check(#PLAYS == 1 and p.owner == ACTOR and p.pos == ZERO and p.flags == STOCK_SOUND.s2d
		and getmetatable(snd) == SOUND_MT and sound_object == STOCK_SOUND,
		"outside the scope xr_sound returns the engine sound and plays it on the real actor")
end

local function direct_sounds(qc, far, in_world)
	print("== direct sound constructors in task helpers, xr_effects and dialogs")
	level.add_pp_effector = function() end
	PLAYS = {}
	local function run(fn, ...)
		if not in_world then
			return pcall(qc.with_target, 620, 1, TASK, fn, ...)
		end
		return qc.with_target(620, 1, TASK, coop_mods_core.as_player, far.object(500), fn, ...)
	end
	local expected_owner
	if not in_world then expected_owner = ACTOR end
	for _, m in ipairs(teleport_visuals) do
		local ok, err = run(m.teleport_visual)
		check(ok, "stock teleport_visual with coop_world_fx's per-script constructor: " .. tostring(err))
	end
	local ok, err = run(xr_effects.play_sound_on_actor, nil, nil, { "fx/direct" })
	check(ok, "xr_effects' direct constructor: " .. tostring(err))
	ok, err = run(dialogs_lostzone.unlock_routes_south)
	check(ok, "dialog's direct constructor: " .. tostring(err))
	check(#PLAYS == 4, "each direct constructor reaches the engine: " .. #PLAYS)
	for _, p in ipairs(PLAYS) do
		check(p.owner == expected_owner and p.delay == 0 and p.flags == STOCK_SOUND.s2d,
			"the stock sound keeps its arguments: " .. p.path)
	end
	check(PLAYS[1] and PLAYS[1].pos == teleport_visuals[1].VEC_ZERO and PLAYS[1].volume == 1 and PLAYS[1].frequency == 1,
		"play_no_feedback keeps position, volume and frequency")
	check(PLAYS[4] and PLAYS[4].volume == 1, "the dialog's volume write reaches the engine")

	if in_world then
		local pt = vec(2, 3, 4)
		ok, err = run(function()
			local s = teleport_visuals[1].sound_object("fx/position")
			s:play_at_pos(level.object_by_id(620), pt)
			s:play(ACTOR, 0, STOCK_SOUND.s2d)
			local bad, message = pcall(s.play, s, {}, 0, STOCK_SOUND.s2d)
			check(not bad and message:find("no overload", 1, true), "only far-marked tables are accepted as no owner")
		end)
		check(ok and PLAYS[5] and PLAYS[5].owner == nil and PLAYS[5].pos == pt,
			"play_at_pos removes a stand-in NPC owner and keeps position: " .. tostring(err))
		check(PLAYS[6] and PLAYS[6].owner == ACTOR, "a real engine owner passes through inside a scope")
	end

	xr_effects.play_sound_on_actor(nil, nil, { "fx/outside" })
	check(PLAYS[#PLAYS].owner == ACTOR and sound_object == STOCK_SOUND,
		"outside a scope the engine class and actor are used")
end

-------------------------------------------------------------------------------
local function map_server()
	local _, qc, far = boot("srv_map")
	print("== srv_map: a map server makes no order")
	check(far.order(600, "kill") == false and far.order(620, "health", 1) == false
		and far.orders_held() == 0 and #far_do() == 0, "order() refuses, nothing held, nothing sent")
	local health = { q = 6, i = 620, v = "health", a = 0.5 }
	HANDLERS["quests.far_do"](health, 0)
	check(sent("quests.far_ack")[1].r == 0, "an offline target answers r = 0")
	REAL[620] = engine_object(620)
	HANDLERS["quests.far_do"](health, 0)
	check(REAL[620].health == 0.5 and sent("quests.far_ack")[2].r == 1, "an online target runs the retry and answers r = 1")
	SENT = {}
	print("== srv_map: the same far_do again (a resend after a lost answer) runs once")
	local corpse = engine_object(600)
	REAL[600] = corpse
	check(type(HANDLERS["quests.far_do"]) == "function", "the map server takes far_do")
	for _ = 1, 3 do HANDLERS["quests.far_do"]({ q = 7, i = 600, v = "kill", a = 600 }, 0) end
	local acks = sent("quests.far_ack")
	check(corpse.kills == 1, "killed once: " .. corpse.kills)
	check(#acks == 3 and acks[1].r == 1 and acks[3].r == 1, "each send answered done")
	print("== srv_map: no far view here, the stock check acts on its own objects")
	local inside = {}
	local ok, err = pcall(qc.with_target, 600, 1, TASK, function()
		inside.scope = coop_mode.far().in_scope()
		inside.hit = hit
	end)
	check(ok and inside.scope == nil and inside.hit == STOCK_HIT, "no scope, the engine's hit: " .. tostring(err))
	print("== srv_map: its sound objects are the stock's (no scope opens on a map server)")
	SendScriptCallback("actor_on_first_update") -- patch_world_calls runs here too
	local snd
	pcall(qc.with_target, 600, 1, TASK, function() snd = xr_sound.get_safe_sound_object("x") end)
	check(snd ~= nil and snd == SOUNDS["x"], "get_safe_sound_object answers the engine's object")
	direct_sounds(qc, far, false)
end

-------------------------------------------------------------------------------
local function no_far_view(set)
	local _, qc, far = boot(set)
	print("== " .. set .. ": the far view is never set up (coop_mode.when_srv does not run)")
	check(qc.part("far") == nil, "the far view gives the Core nothing")
	check(HANDLERS["quests.far_do"] == nil and HANDLERS["quests.far_ack"] == nil and HANDLERS["quests.far_hit"] == nil,
		"no far handler is registered")
	check(coop_mode.far().order(600, "kill") == false and far.order(620, "health", 1) == false
		and coop_mode.far().in_scope() == nil, "neither the facade nor order() makes a far order")
	print("== " .. set .. ": the stock check acts on the objects of this process, as before")
	local corpse, critter = engine_object(600), engine_object(650)
	REAL[600], REAL[650] = corpse, critter
	local inside = {}
	local ok, err = true, nil
	for _ = 1, 5 do
		local okc, errc = pcall(qc.with_target, 600, 1, TASK, function()
			inside.scope = coop_mode.far().in_scope()
			inside.hit = hit
			kill_if_online(600)
			kill_if_online_mutant(650, true)
		end)
		if not okc then ok, err = okc, errc end
	end
	check(ok, "every check runs: " .. tostring(err))
	check(inside.scope == nil and inside.hit == STOCK_HIT, "no scope, hit is the engine's")
	check(corpse.kills == 1 and not corpse:alive(), "the engine kills the corpse at the first check")
	check(#critter.hits == 1 and critter.hits[1].power == 10 and critter.infos.mutant_to_kill, "the critter: one engine hit and its info")
	check(#SENT == 0 and far.orders_held() == 0, "nothing is sent, nothing held")

	-- the ghost's blow of Mystery of the Swamps as before FP45b: in the co-op coop_mods_nta runs the stock's timer as the player nearest
	-- to the ghost, whose character is a game object of this process; with no session the stock's own actor
	print("== " .. set .. ": the ghost's blow, as before: the engine's hit and sound on "
		.. (set == "none" and "the actor" or "the nearest player's character"))
	load_script_file("coop_mods_core")
	load_script_file("coop_mods_nta").on_game_start()
	SendScriptCallback("actor_on_first_update")
	local client = engine_object(500)
	client.position = function() return vec(5, 0, 5) end -- at the ghost's spot; the host's character is at 1, 0, 1
	REAL[500] = client
	SENT, PLAYS, TIMEEV = {}, {}, {}
	local okg, errg = pcall(tasks_mystery_of_the_swamps.spawn_garbage_ghost, { bonk_actor = true })
	for _, ev in ipairs(TIMEEV) do ev.f(unpack(ev.p)) end
	local struck = set == "none" and ACTOR or client
	check(okg and #TIMEEV == 1, "the stock's timer: " .. tostring(errg))
	check(#struck.hits == 1 and struck.hits[1].power == 1.3 and struck.hits[1].type == STOCK_HIT.wound,
		"one engine hit, power 1.3, a wound: " .. #struck.hits)
	check(#PLAYS == 1 and PLAYS[1].owner == struck, "its sound on the same game object")
	check(#SENT == 0 and xr_sound.get_safe_sound_object("x") == SOUNDS["x"], "nothing is sent; the sound objects are the stock's")
	direct_sounds(qc, far, false)
end

local tests = {
	srv_world = function()
		local qc, far = world_server()
		mystery_ghost(qc, far)
		actor_theme_sound(qc, far)
		direct_sounds(qc, far, true)
	end,
	srv_map = map_server,
	hostplay = function() no_far_view("hostplay") end,
	none = function() no_far_view("none") end,
}

print("== the far hit edge, the scan: which task and dialog scripts of the profile hit the actor (GAMMA scripts)")
do
	local found = {}
	for _, mask in ipairs({ "tasks_*.script", "task_*.script", "dialog*.script" }) do
		local pipe = assert(io.popen("dir /b /on \"" .. GAMMA_DIR .. BS .. mask .. "\" 2>nul"))
		for name in pipe:lines() do
			name = name:gsub("\r", "")
			local fh = io.open(GAMMA_DIR .. BS .. name, "rb")
			if fh then
				local n = 0
				for line in fh:read("*a"):gmatch("([^\n]*)\n?") do
					n = n + 1
					local code = line:gsub("%-%-.*$", "")
					if code:find("actor:hit(", 1, true) then found[#found + 1] = name end
				end
				fh:close()
			end
		end
		pipe:close()
	end
	check(#found == 1 and found[1] == "tasks_mystery_of_the_swamps.script",
		"only Mystery of the Swamps (its ghost's blow): " .. table.concat(found, ", "))
	local fh = assert(io.open("gamedata" .. BS .. "scripts" .. BS .. "coop_mods_nta.script", "rb"))
	local nta = fh:read("*a")
	fh:close()
	check(nta:find("\"spawn_garbage_ghost\"", 1, true) ~= nil and nta:find("as_player(who, cb)", 1, true) ~= nil,
		"coop_mods_nta runs its timer as the nearest standing player (install_mystery)")
end

for _, name in ipairs(modes.names()) do
	print("== set " .. name)
	tests[name]()
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
