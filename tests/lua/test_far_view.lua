-- Split levels: the far view of the world server (coop_quests_far), one scope for one call, and the orders it gives to a map server. Real
-- scripts over the stubs. Run: tools\test_lua.cmd far_view
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local LEVELS = { [10] = 1, [20] = 2, [30] = 3 } -- game vertex -> level
game_graph = function()
	return { vertex = function(_, v) return { level_id = function() return LEVELS[v] end } end }
end
local function vec(x, y, z)
	return setmetatable({ x = x, y = y, z = z }, { __index = {
		distance_to_sqr = function(a, b) return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 end } })
end
vector = function() return { set = function(_, x, y, z) return vec(x, y, z) end } end

local RECORDS = {
	[500] = { id = 500, position = vec(5, 0, 5), m_level_vertex_id = 77, m_game_vertex_id = 20, parent_id = 65535, online = true }, -- player 1
	[600] = { id = 600, position = vec(7, 0, 7), m_level_vertex_id = 7, m_game_vertex_id = 20, parent_id = 65535, online = true, -- an NPC he stands at
		section_name = function() return "stalker_x" end, name = function() return "npc600" end, community = function() return "stalker" end,
		character_name = function() return "Vasya" end, alive = function() return true end, clsid = function() return 44 end },
	[601] = { id = 601, position = vec(900, 0, 900), m_level_vertex_id = 8, m_game_vertex_id = 20, parent_id = 65535, online = false }, -- out of reach
	[602] = { id = 602, position = vec(8, 0, 8), m_level_vertex_id = 9, m_game_vertex_id = 20, parent_id = 65535, online = false }, -- near, no creature
	[700] = { id = 700, position = vec(1, 0, 1), m_game_vertex_id = 10, parent_id = 65535, online = false }, -- on the world server's level
	[800] = { id = 800, position = vec(1, 0, 1), m_game_vertex_id = 30, parent_id = 65535, online = false }, -- a level with nobody on it
	[603] = { id = 603, position = vec(7, 0, 7), m_game_vertex_id = 20, parent_id = 600, online = false }, -- an item of the NPC
}
alife_object = function(id) return RECORDS[id] end
local SIM = {}
function SIM:level_name(l) return ({ "l01_escape", "k00_marsh", "zaton" })[l] end
function SIM:switch_distance() return 150 end
function SIM:actor() return { id = 0, real = true } end
function SIM:has_info(id, name) return id == 600 and name == "he_knows" end
SIM.give_info = function(_, id, name) SIM.given = { id, name } end
SIM.kill_entity = function(_, se) SIM.killed = se.id end
alife = function() return SIM end

local PLAYERS = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
coop.players = function() return PLAYERS end
coop.avatar_of = function(peer) return peer == 1 and 500 or nil end
coop.levels = {
	split = function() return true end,
	my_level = function() return 1 end,
	level_of_player = function(peer) return peer == 1 and 2 or 1 end,
	carried = function(id) return id == 600 and { { id = 603, section = "docs", condition = 0.5 } } or {} end,
	map_servers = function() return { { bridge = 0x101, level = 2 } } end,
}
local ACTOR = {}
function ACTOR:id() return 0 end
function ACTOR:position() return vec(1, 0, 1) end
function ACTOR:game_vertex_id() return 10 end
function ACTOR:alive() return true end
db = db or {}
db.actor = ACTOR
db.storage = { [0] = { object = ACTOR } }
local STOCK_ANOMALIES = { stock_field = { object = ACTOR } }
db.anomaly_by_name = STOCK_ANOMALIES
db.zone_by_name = { here = ACTOR }
level = level or {}
local REAL = { [0] = ACTOR }
level.object_by_id = function(id) return REAL[id] end
level.name = function() return "l01_escape" end
simulation_objects = { is_on_the_actor_level = function() return "stock" end }

load_script_file("coop_quests_core")
load_script_file("coop_levels_share")
load_script_file("coop_quests_far")
local qc, far = coop_quests_core, coop_quests_far
qc.on_game_start()
far.on_game_start()
local STOCK_ALIFE = alife

local function stock_again(what)
	check(level.name() == "l01_escape", what .. ": level.name is the stock's")
	check(level.object_by_id(600) == nil, what .. ": level.object_by_id says offline again")
	check(db.storage[600] == nil, what .. ": db.storage has nothing of it")
	check(db.anomaly_by_name == STOCK_ANOMALIES, what .. ": db.anomaly_by_name is the stock's")
	check(db.zone_by_name.zone_there == nil, what .. ": db.zone_by_name has nothing of it")
	check(alife == STOCK_ALIFE, what .. ": alife is the stock's")
	check(simulation_objects.is_on_the_actor_level({ m_game_vertex_id = 20 }) == "stock", what .. ": is_on_the_actor_level is the stock's")
	check(far.in_scope() == nil, what .. ": no scope is open")
end

print("== outside a scope nil still means offline")
stock_again("before")

print("== inside: the level of the player")
far._names_of()[2] = { a = { field_1 = 600 }, z = { zone_there = 600 } }
local inside = {}
local r1, r2 = qc.with_level_of(1, function(a, b)
	inside.name = level.name()
	inside.npc = level.object_by_id(600)
	inside.other = level.object_by_id(700)
	inside.nobody = level.object_by_id(800)
	inside.offline = level.object_by_id(601)
	inside.item = level.object_by_id(602)
	inside.st = db.storage[600]
	inside.anomaly = db.anomaly_by_name.field_1
	inside.zone = db.zone_by_name.zone_there
	inside.actor = alife():actor()
	inside.same = simulation_objects.is_on_the_actor_level({ m_game_vertex_id = 20 })
	inside.not_same = simulation_objects.is_on_the_actor_level({ m_game_vertex_id = 10 })
	inside.level_name = alife():level_name(3)
	return a + 1, b
end, 1, "x")
check(r1 == 2 and r2 == "x", "the results of fn come back")
check(inside.name == "k00_marsh", "level.name is his")
check(inside.npc and inside.npc.far == true and inside.npc:id() == 600, "an NPC online there has a stand-in")
check(inside.other == nil, "an object of another level: nil")
check(inside.nobody == nil, "an object of a third level: nil")
check(inside.offline == nil, "out of reach and not online: nil, offline as the stock takes it")
check(inside.item and inside.item:id() == 602, "not a creature, near a player: there")
check(inside.st and inside.st.object:id() == 600, "db.storage answers")
check(inside.anomaly and inside.anomaly.object:id() == 600, "db.anomaly_by_name has the names of that level")
check(inside.zone and inside.zone:id() == 600, "db.zone_by_name too")
check(inside.actor == RECORDS[500], "alife():actor() is the record of the player")
check(inside.same == true and inside.not_same == false, "is_on_the_actor_level looks at that level")
check(inside.level_name == "zaton", "the rest of alife() works")
stock_again("after a call")

print("== a stand-in reads records")
local o = far.object(600)
check(o:section() == "stalker_x" and o:name() == "npc600" and o:clsid() == 44, "section, name, clsid")
check(o:position() == RECORDS[600].position and o:level_vertex_id() == 7 and o:game_vertex_id() == 20, "place")
check(o[1] == o:position() and o[4] == 600, "a place for the stock create_item")
check(o:character_community() == "stalker" and o:character_name() == "Vasya", "community, name")
check(o:alive() == true, "alive")
check(o:has_info("he_knows") and not o:has_info("no"), "infos of the record")
check(o:object("docs") and o:object("docs"):id() == 603 and o:object("docs"):condition() == 0.5, "what he carries")
check(o:object("nope") == nil, "and not what he does not")
check(o.health == 1, "health is a number")
check(o.radiation == 0, "so is radiation")
local logged = {}
local real_printf = printf
local function capture_log() logged = {}; printf = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end end
capture_log()
check(o:some_new_method(1) == nil, "an unknown method answers nil")
check(o:some_new_method(1) == nil, "and again")
printf = real_printf
local lines = 0
for _, l in ipairs(logged) do
	if l:find("[coop] far: some_new_method asked by", 1, true) then lines = lines + 1 end
end
check(lines == 1, "and is logged once for its name")
check(qc.far_body(1, 500):other_method() == nil, "a far body takes the same way")

print("== an error inside closes the scope")
local ok, err = pcall(qc.with_level_of, 1, function()
	check(level.name() == "k00_marsh", "inside before the error")
	error("boom", 0)
end)
check(not ok and err == "boom", "the error goes on")
stock_again("after an error")

print("== nested")
qc.with_level_of(1, function()
	local okn, errn = pcall(qc.with_target, 800, nil, "inner", function() error("inner boom", 0) end)
	check(not okn and errn == "inner boom", "the inner error goes on")
	check(level.name() == "k00_marsh" and far.in_scope() ~= nil, "the outer scope stands after the inner one fell")
	check(level.object_by_id(600) ~= nil, "and it still sees its level")
end)
stock_again("after nesting")

print("== from inside a scope, a player of the world server's own level")
qc.with_level_of(1, function()
	local seen
	qc.with_level_of(0, function() seen = level.name() end)
	check(seen == "l01_escape", "his level, not the scope's")
	check(level.name() == "k00_marsh", "and the scope stands again")
end)
stock_again("after leaving and coming back")

print("== a timer started in a scope looks at the same level")
local TIMERS = {}
CreateTimeEvent = function(ev, act, t, f, ...) TIMERS[#TIMERS + 1] = { f = f, p = { ... } } end
local STOCK_CTE = CreateTimeEvent
local fired
qc.with_level_of(1, function()
	CreateTimeEvent("x", "y", 3, function(a) fired = { a, level.name(), db.storage[600] ~= nil } end, 5)
end)
check(CreateTimeEvent == STOCK_CTE, "CreateTimeEvent is the stock's again")
check(level.name() == "l01_escape", "the timer is not running yet")
TIMERS[1].f(unpack(TIMERS[1].p))
check(fired and fired[1] == 5 and fired[2] == "k00_marsh" and fired[3] == true, "it fires on that level")
stock_again("after a timer")

print("== by the target: who stands there")
local names = {}
qc.with_target(600, 0, "task", function() names[1] = level.name() names[2] = far.in_scope().peer end)
check(names[1] == "k00_marsh" and names[2] == 1, "a target on his level: his level, whoever took it")
names = {}
qc.with_target(700, 1, "task", function() names[1] = level.name() names[2] = far.in_scope() end)
check(names[1] == "l01_escape" and names[2] == nil, "a target on the world server's level: no scope")
names = {}
qc.with_target(800, 1, "task", function() names[1] = level.name() end)
check(names[1] == "k00_marsh", "a target where nobody stands: the level of who took it")

print("== split levels off")
coop.levels.split = function() return false end
names = {}
qc.with_level_of(1, function() names[1] = level.name() names[2] = far.in_scope() end)
check(names[1] == "l01_escape" and names[2] == nil, "no scope")
coop.levels.split = function() return true end

print("== a leak is caught at the end of the frame")
local leaked = false
local co = coroutine.create(function()
	qc.with_level_of(1, function() coroutine.yield() end)
end)
coroutine.resume(co)
check(level.name() == "k00_marsh", "a coroutine left the scope open")
capture_log()
far._tick()
printf = real_printf
for _, l in ipairs(logged) do leaked = leaked or l:find("scope leaked by player 1", 1, true) ~= nil end
check(leaked, "the frame says so")
stock_again("after a leak")

print("== what failed in a scope says what it looked for")
capture_log()
qc.with_level_of(1, function()
	local _ = level.object_by_id(700)
	_ = level.object_by_id(4242)
	far.note_fail("some_task")
end)
printf = real_printf
check(logged[1] and logged[1]:find("task some_task failed on k00_marsh", 1, true) ~= nil, "the task and the level")
check(logged[1] and logged[1]:find("700: another level", 1, true) and logged[1]:find("4242: nil", 1, true), "what it got")

print("== orders")
local SENT = {}
coop.send_event = function(name, payload, target) SENT[#SENT + 1] = { name = name, payload = payload, target = target } return true end
local CLOCK = 1000
time_global = function() return CLOCK end
local before = #SENT
o:kill()
check(#SENT == before + 1 and SENT[#SENT].name == "quests.far_do" and SENT[#SENT].target == 0x101, "a kill goes to the map server of its level")
check(far.orders_held() == 1, "and is held")
CLOCK = CLOCK + 4000
far._tick()
check(#SENT == before + 2, "no answer: it goes again")
for _ = 1, 5 do
	CLOCK = CLOCK + 4000
	far._tick()
end
check(far.orders_held() == 0, "after the last try it is carried out here")
check(SIM.killed == 600, "on the record")

print("== \"the actor\" of an order is the player of the scope: on a map server id 0 is a ghost")
local real_send, sent_order = qc.send, nil
qc.send = function(name, t) sent_order = t return true end
qc.with_level_of(1, function() o:set_relation(3, ACTOR) end)
qc.send = real_send
check(sent_order and sent_order.v == "relation" and sent_order.b == 500, "the player's avatar, not the ghost")
far._orders_clear()

print("== an order for an object that is no more")
o:give_info_portion("x")
check(far.orders_held() == 1, "held")
local rec = RECORDS[600]
RECORDS[600] = nil
capture_log()
far._tick()
printf = real_printf
RECORDS[600] = rec
check(far.orders_held() == 0, "dropped")
check(logged[1] and logged[1]:find("order info on 600 dropped", 1, true) ~= nil, "with a line in the log")

print("== its map server is gone")
o:give_info_portion("y")
coop.levels.map_servers = function() return {} end
far._tick()
check(far.orders_held() == 0 and SIM.given and SIM.given[2] == "y", "the world server gives the info to the record itself")

print("== the engine's \"no object\" id is not asked of the world")
-- Live build 46, the world server's console: "ALIFE OBJECT ID IS 65535!" and a call stack. A story squad's condlist looked for its
-- target while the task had no giver; the stock alife_object answers that id with the error line.
do
	local asked = {}
	local real_alife_object = alife_object
	alife_object = function(id) asked[#asked + 1] = id return real_alife_object(id) end
	local none, none_st, none_level
	qc.with_level_of(1, function()
		none = level.object_by_id(65535)
		none_st = db.storage[65535]
	end)
	none_level = far.level_of_id(65535)
	alife_object = real_alife_object
	check(none == nil and none_st == nil and none_level == nil, "nobody has it, and it stands on no level")
	local was = false
	for _, id in ipairs(asked) do if id == 65535 then was = true end end
	check(not was, "alife_object was not asked for it")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
