-- TZ P45 (Dev 58, report RL-89RT-DQYR #1664, temp/r45/report-1664.txt), Server. The world server died on
-- FATAL R_ASSERT l_tpALifeMonsterAbstract->children.empty() in CALifeCombatManager::kill_entity: coop_srv_quests_far's order "kill",
-- carried out on the record when the map server of the level is gone or does not answer, called alife():kill_entity, which detaches
-- the inventory first; the stock's detach of a stalker does nothing (alife_human_object_handler.cpp detach_all), so a stalker with any
-- item fails the assert. The order came from bar_dolg_general_petrenko_stalker_task_rioc_pol (tasks_recover_item_on_corpse:
-- kill_if_online on the corpse it made with the quest item inside). Before it every party check of that task failed with
-- "tasks_recover_item_on_corpse.script:110: luabind: the value at stack #3 is a table, a C++ object was expected": the far view's
-- stand-in of a critter became the draftsman of the engine's hit (h.draftsman = o).
-- Real scripts over the stubs (the setup of test_srv_far_view.lua); the engine's answers are stand-ins below: alife():kill_entity
-- asserts as the engine does for a body with children, srv.kill_record is the world server's binding (coop_srv_script.cpp), hit is
-- the engine's class (a draftsman must be a game object). Coop: no co-op script reaches kill_entity (the scan below; the Core's record
-- changes nothing, coop_quests_core record:kill). Run: tools\test_lua.cmd issue_p45
MODE = "host"
dofile("tests/lua/support/stubs.lua")
dofile("tests/lua/support/mod_source.lua")

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
local RECORDS = {
	[500] = { id = 500, position = vec(5, 0, 5), m_level_vertex_id = 77, m_game_vertex_id = 20, parent_id = 65535, online = true }, -- player 1
	-- the corpse a recover-item task made: a stalker with the quest item and his own things inside
	[600] = { id = 600, position = vec(7, 0, 7), m_level_vertex_id = 7, m_game_vertex_id = 20, parent_id = 65535, online = true,
		section_name = function() return "sim_default_stalker_0" end, alive = alive_fn(true), clsid = function() return 44 end },
	[603] = { id = 603, position = vec(7, 0, 7), m_game_vertex_id = 20, parent_id = 600, online = false }, -- the quest item
	[604] = { id = 604, position = vec(7, 0, 7), m_game_vertex_id = 20, parent_id = 600, online = false }, -- his bread
	-- a critter of the task, near the corpse
	[650] = { id = 650, position = vec(8, 0, 8), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = true,
		section_name = function() return "dog_normal_red" end, alive = alive_fn(true), clsid = function() return 20 end },
	[610] = { id = 610, position = vec(9, 0, 9), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = false }, -- a box
}
alife_object = function(id) return RECORDS[id] end
local function children_of(id)
	local out = {}
	for cid, r in pairs(RECORDS) do
		if r.parent_id == id then out[#out + 1] = cid end
	end
	table.sort(out)
	return out
end

local SIM = {}
function SIM:level_name(l) return ({ "l01_escape", "y04_pole", "zaton" })[l] end
function SIM:switch_distance() return 150 end
function SIM:actor() return { id = 0, real = true } end
function SIM:has_info(id, name) return false end
SIM.give_info = function(_, id, name) SIM.given = { id, name } end
-- the engine: CALifeCombatManager::kill_entity detaches nothing of a stalker and asserts that he holds nothing (a FATAL in the game;
-- here an error, which the pcall of carry_out would take: the count says it was reached)
local kill_entity_calls = 0
SIM.kill_entity = function(_, se)
	kill_entity_calls = kill_entity_calls + 1
	if #children_of(se.id) > 0 then error("FATAL R_ASSERT l_tpALifeMonsterAbstract->children.empty()", 0) end
	se.alive = alive_fn(false)
end
local on_release = nil
SIM.release = function(_, se)
	RECORDS[se.id] = nil
	if on_release then on_release(se) end
end
alife = function() return SIM end

-- the world server's binding (coop_srv_script.cpp l_kill_record -> levels::host_apply_death): health 0, the body keeps its things
local KILLS = {}
local on_kill = nil
local SRV = {
	kill_record = function(id, killer)
		KILLS[#KILLS + 1] = { id = id, killer = killer }
		local se = RECORDS[id]
		if not (se and se.alive and se.alive()) then return false end
		se.alive = alive_fn(false)
		if on_kill then on_kill(id, killer) end
		return true
	end,
}
srv = SRV

-- the engine's hit (script_hit_script.cpp): its draftsman is a game object, anything else is luabind's error
local HIT_MT = {}
HIT_MT.__index = function(h, k) return rawget(h, "fields")[k] end
HIT_MT.__newindex = function(h, k, v)
	if k == "draftsman" and v ~= nil and not (type(v) == "table" and rawget(v, "engine_object")) then -- a stand-in answers any name
		error("luabind: the value at stack #3 is a table, a C++ object was expected", 2)
	end
	rawget(h, "fields")[k] = v
end
local STOCK_HIT = setmetatable({ burn = 0, wound = 5, fire_wound = 6, strike = 7 }, { __call = function()
	return setmetatable({ fields = { power = 100, impulse = 100, type = 5 } }, HIT_MT)
end })
hit = STOCK_HIT

local PLAYERS = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
coop.players = function() return PLAYERS end
coop.avatar_of = function(peer) return peer == 1 and 500 or nil end
local MAP_SERVERS = { { bridge = 0x101, level = 2 } }
coop.levels = {
	split = function() return true end,
	my_level = function() return 1 end,
	level_of_player = function(peer) return peer == 1 and 2 or 1 end,
	carried = function(id) return {} end,
	map_servers = function() return MAP_SERVERS end,
}
local ACTOR = { engine_object = true }
function ACTOR:id() return 0 end
function ACTOR:position() return vec(1, 0, 1) end
function ACTOR:game_vertex_id() return 10 end
function ACTOR:alive() return true end
db = db or {}
db.actor = ACTOR
db.storage = { [0] = { object = ACTOR } }
db.anomaly_by_name = {}
db.zone_by_name = {}
level = level or {}
local REAL = { [0] = ACTOR }
level.object_by_id = function(id) return REAL[id] end
level.name = function() return "l01_escape" end
simulation_objects = { is_on_the_actor_level = function() return "stock" end }

coop.is_dedicated = function() return true end
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script_file("coop_mode")
facade.on_game_start()
modes.live(facade)
load_script_file("coop_quests_core")
load_script_file("coop_srv_quests_core").on_game_start()
load_script_file("coop_srv_levels_share")
load_script_file("coop_srv_quests_far")
local qc, far = coop_quests_core, coop_srv_quests_far
qc.on_game_start()
far.on_game_start()

local SENT = {} -- what the far view sends (coop_quests_core.send, before its encoding)
qc.send = function(name, t, target) SENT[#SENT + 1] = { name = "quests." .. name, payload = t, target = target } return true end
local CLOCK = 1000
time_global = function() return CLOCK end
local logged = {}
local real_printf = printf
local function capture_log() logged = {}; printf = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end end
local function log_has(text)
	for _, l in ipairs(logged) do
		if l:find(text, 1, true) then return true end
	end
	return false
end
local function far_do(v)
	local out = {}
	for _, s in ipairs(SENT) do
		if s.name == "quests.far_do" and s.payload and s.payload.v == v then out[#out + 1] = s.payload end
	end
	return out
end
local function tick()
	local ok, err = pcall(far._test.tick)
	return ok, err
end

print("== no co-op script calls alife():kill_entity (both modes: it asserts on any body that holds something)")
do
	local pipe = assert(io.popen("dir /b /on gamedata" .. BS .. "scripts" .. BS .. "coop_*.script 2>nul"))
	local files, calls = 0, {}
	for name in pipe:lines() do
		local fh = io.open("gamedata" .. BS .. "scripts" .. BS .. name, "rb")
		if fh then
			files = files + 1
			local n = 0
			for line in fh:read("*a"):gmatch("([^\n]*)\n?") do
				n = n + 1
				local code = line:gsub("%-%-.*$", "")
				if code:find("kill_entity", 1, true) then calls[#calls + 1] = name .. ":" .. n end
			end
			fh:close()
		end
	end
	pipe:close()
	check(files > 100, "the co-op scripts were read: " .. files)
	check(#calls == 0, "none calls kill_entity: " .. table.concat(calls, ", "))
end

print("== a kill order on the record of a stalker with items: its map server is gone")
qc.with_level_of(1, function()
	local corpse = level.object_by_id(600)
	check(corpse and corpse.far == true, "the corpse on the player's level is a stand-in")
	corpse:kill(db.actor)
end)
check(far.orders_held() == 1 and #far_do("kill") == 1 and far_do("kill")[1].i == 600, "the kill went to the map server of the level")
MAP_SERVERS = {}
capture_log()
local ok, err = tick()
printf = real_printf
check(ok, "the tick ends: " .. tostring(err))
check(far.orders_held() == 0, "the order is carried out here")
check(kill_entity_calls == 0, "alife():kill_entity is not called (FATAL children.empty() in the game)")
check(#KILLS == 1 and KILLS[1].id == 600, "the world server applies the death through srv.kill_record")
check(KILLS[1] and KILLS[1].killer == 500, "the killer is the player of the scope, not the ghost: " .. tostring(KILLS[1] and KILLS[1].killer))
check(not RECORDS[600].alive(), "the stalker is dead")
local things = children_of(600)
check(#things == 2 and things[1] == 603 and things[2] == 604, "the quest item and his things stay with the body")
check(log_has("order kill on 600 carried out here (its map server is gone)"), "with its line in the log")

print("== the same when the map server does not answer")
MAP_SERVERS = { { bridge = 0x101, level = 2 } }
RECORDS[600].alive = alive_fn(true)
KILLS = {}
far.object(600):kill()
check(far.orders_held() == 1, "held")
for _ = 1, 6 do
	CLOCK = CLOCK + 4000
	ok, err = tick()
	check(ok, "the tick ends: " .. tostring(err))
end
check(far.orders_held() == 0, "after the last try it is carried out here")
check(kill_entity_calls == 0, "kill_entity is still not called")
check(#KILLS == 1 and KILLS[1].id == 600 and KILLS[1].killer == nil, "srv.kill_record, no killer: " .. tostring(#KILLS))
check(not RECORDS[600].alive() and #children_of(600) == 2, "dead, his things with him")

print("== an exe without srv.kill_record: the order is reported, nothing asserts")
RECORDS[600].alive = alive_fn(true)
KILLS = {}
srv = nil
local reported = {}
local real_report = qc.report
qc.report = function(tag, what, e) reported[#reported + 1] = tostring(what) .. ": " .. tostring(e) end
MAP_SERVERS = {}
far.object(600):kill()
ok, err = tick()
qc.report = real_report
srv = SRV
check(ok, "the tick ends: " .. tostring(err))
check(far.orders_held() == 0, "the order is done with")
check(kill_entity_calls == 0 and #KILLS == 0, "neither kill_entity nor a binding that is not there")
check(RECORDS[600].alive(), "the stalker lives on")
check(#reported == 1 and reported[1]:find("order kill", 1, true) ~= nil and reported[1]:find("srv.kill_record", 1, true) ~= nil,
	"one report says why: " .. tostring(reported[1]))

print("== what a death runs (the stock on_death, the tasks' relay) may give orders: the tick still ends")
KILLS = {}
on_kill = function(id)
	for i = 1, 40 do far.order(610, "info", "p45_" .. i) end
end
far.object(600):kill()
ok, err = tick()
on_kill = nil
check(ok, "the tick ends: " .. tostring(err))
check(#KILLS == 1, "the kill was carried out")
check(far.orders_held() == 40, "the orders given by the death wait for the next tick: " .. far.orders_held())
far._test.orders_clear()

print("== the same for a release on the record (the stock unregister callbacks)")
on_release = function()
	for i = 1, 40 do far.order(600, "info", "p45_r" .. i) end
end
far.order(610, "release")
ok, err = tick()
on_release = nil
check(ok, "the tick ends: " .. tostring(err))
check(RECORDS[610] == nil, "the box is released")
check(far.orders_held() == 40, "the orders given by the release wait for the next tick: " .. far.orders_held())
far._test.orders_clear()
RECORDS[610] = { id = 610, position = vec(9, 0, 9), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = false }

print("== a hit a task makes inside a scope takes a stand-in as its draftsman (the flood before the crash)")
assert(GAMMA_DIR and have_file(GAMMA_DIR .. BS .. "tasks_recover_item_on_corpse.script"),
	"real GAMMA tasks_recover_item_on_corpse.script required (GAMMA_SCRIPTS)")
local kill_if_online_mutant, kill_if_online = mod_chunk(GAMMA_DIR .. BS .. "tasks_recover_item_on_corpse.script",
	{ "function kill_if_online(id)", "function kill_if_online_mutant(id, random_push)" }, "tasks_recover_item_on_corpse",
	"return kill_if_online_mutant, kill_if_online")
assert(type(kill_if_online_mutant) == "function", "kill_if_online_mutant: " .. tostring(kill_if_online))
MAP_SERVERS = { { bridge = 0x101, level = 2 } }
RECORDS[600].alive = alive_fn(true)
SENT = {}
local inside = {}
local okc, errc = pcall(qc.with_level_of, 1, function()
	inside.wound = hit.wound
	inside.swapped = hit ~= STOCK_HIT
	kill_if_online(600)
	kill_if_online_mutant(650, true)
end)
check(okc, "the task's check runs to its end: " .. tostring(errc))
check(inside.swapped and inside.wound == STOCK_HIT.wound, "inside, hit is the far view's, with the engine's kinds")
check(hit == STOCK_HIT, "outside again, hit is the engine's")
local infos, hits, kills = far_do("info"), far_do("hit"), far_do("kill")
check(#kills == 1 and kills[1].i == 600 and kills[1].a == 600, "the corpse: a kill order (the corpse its own killer, as the task says)")
check(#infos == 1 and infos[1].i == 650 and infos[1].a == "mutant_to_kill", "the critter: the info order")
check(#hits == 1 and hits[1].i == 650 and hits[1].a == 10 and hits[1].b == STOCK_HIT.wound and hits[1].c == 650,
	"the critter: the hit order, power 10, a wound, struck by itself")
far._test.orders_clear()

print("== a hit made outside a scope is the engine's")
local h = hit()
check(getmetatable(h) == HIT_MT, "the engine's object")
h.draftsman = ACTOR
check(h.draftsman == ACTOR, "a game object as its draftsman")

print("== a copy of a hit inside a scope keeps its fields")
inside.copy, inside.fresh = {}, {}
local okh, errh = pcall(qc.with_level_of, 1, function()
	local a = hit()
	a.power, a.type, a.draftsman = 3, STOCK_HIT.strike, far.object(650)
	local b = hit(a)
	inside.copy = { b.power, b.type, b.draftsman and b.draftsman:id(), b.impulse }
	local c = hit()
	inside.fresh = { c.power, c.impulse, c.type }
end)
check(okh, "no error: " .. tostring(errh))
check(inside.copy[1] == 3 and inside.copy[2] == STOCK_HIT.strike and inside.copy[3] == 650 and inside.copy[4] == 100, "power, kind, draftsman, impulse")
check(inside.fresh[1] == 100 and inside.fresh[2] == 100 and inside.fresh[3] == STOCK_HIT.wound, "a new one has the engine's defaults")

print(string.format("%d passed, %d failed", PASSES, FAILS))
