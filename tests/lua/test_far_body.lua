-- A player on a map server's level has no game object on the world server: his records stand for him in what the task code asks of a
-- character (coop_quests_core far_body, coop_tasks party_*, coop_quests_party nearest). Real scripts over the stubs.
-- Not shipped. Run: tools\test_lua.cmd far_body
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local LEVELS = { [10] = 1, [20] = 2 } -- game vertex -> level
game_graph = function()
	return { vertex = function(_, v) return { level_id = function() return LEVELS[v] end } end }
end
local function vec(x, y, z) return { x = x, y = y, z = z } end

local CARRIED = {
	[500] = { { id = 901, section = "quest_doc", condition = 0.8 }, { id = 902, section = "bandage", condition = 1 }, { id = 903, section = "bandage", condition = 1 } },
}
local RECORDS = {
	[500] = { position = vec(5, 0, 5), m_level_vertex_id = 77, m_game_vertex_id = 20, alive = function() return true end },
	[901] = { parent_id = 500, section_name = function() return "quest_doc" end },
	[70] = { position = vec(100, 0, 100), m_game_vertex_id = 20 }, -- a target on his level
	[71] = { position = vec(100, 0, 100), m_game_vertex_id = 10 }, -- a target on the host's
}
alife_object = function(id) return RECORDS[id] end
local RELEASED, MADE = {}, {}
alife_release_id = function(id) RELEASED[#RELEASED + 1] = id end
itms_manager = { create_item = function(section, to, t) MADE[#MADE + 1] = { section = section, to = to, t = t } end }
ini_sys = { r_float_ex = function(_, sec, key) return key == "max_uses" and sec == "bandage" and 3 or nil end }

coop.levels = {
	split = function() return true end,
	my_level = function() return 1 end,
	level_of_player = function(peer) return peer == 1 and 2 or 1 end,
	carried = function(id) return CARRIED[id] or {} end,
}
local ACTOR = { }
function ACTOR:id() return 0 end
function ACTOR:position() return vec(1, 0, 1) end
function ACTOR:game_vertex_id() return 10 end
function ACTOR:alive() return true end
db = db or {}
db.actor = ACTOR
level = level or {}
level.object_by_id = function(id) return id == 0 and ACTOR or nil end

print("== far_body")
load_script_file("coop_quests_core")
local qc = coop_quests_core
check(qc.far_body(0, 500) == nil, "a player on this level has no far body")
local far = qc.far_body(1, 500)
check(far and far.far == true and far:id() == 500, "a player on another level has one")
check(far:position().x == 5 and far:level_vertex_id() == 77 and far:game_vertex_id() == 20, "it stands where his record stands")
check(far[1] == far:position() and far[2] == 77 and far[3] == 20 and far[4] == 500, "it is a place for the stock create_item")
check(far:alive() == true, "alive as his record says")
clsid = { script_stalker = 44 }
check(far:clsid() == 44, "the stock IsStalker takes him for a stalker")
RECORDS[500].community = function() return "actor_army" end
RECORDS[500].rank = function() return 900 end
check(far:character_community() == "actor_army" and far:character_rank() == 900, "faction and rank are his record's")
local n = 0
far:iterate_inventory(function(x, item)
	check(x == "x", "the walk hands on its argument")
	n = n + 1
end, "x")
check(n == 3, "the walk sees everything he carries")
local doc = far:object("quest_doc")
check(doc and doc:id() == 901 and doc:section() == "quest_doc" and doc:condition() == 0.8, "object(section): the record of the item")
check(far:object("nothing") == nil, "object(section) of what he has not: nil")
check(far:object("bandage"):get_remaining_uses() == 3, "uses of a record: the section's, no record has them")
n = 0
far:iterate_inventory(function() n = n + 1; return true end, nil)
check(n == 1, "true stops the walk, as in the engine")
far:transfer_item(doc, ACTOR)
check(RELEASED[1] == 901 and MADE[1].section == "quest_doc" and MADE[1].to == ACTOR, "handing over: the record goes, a new one is made at the other end")
-- the quest audit, 2026-11-13: the stock pays a fetch task by the item's condition (cost * con^2); a new whole item was made
check(MADE[1].t and MADE[1].t.cond == 0.8, "as worn as the one that went: a worn item is not paid as a new one")
far:transfer_item(far:object("bandage"), ACTOR)
check(MADE[2].section == "bandage" and MADE[2].t == nil, "a whole item: made the stock's plain way")

coop.levels.split = function() return false end
check(qc.far_body(1, 500) == nil, "split levels off: nobody is far")
coop.levels.split = function() return true end

print("== bodies and the nearest on a level")
local ids = {}
for _, c in ipairs(qc.bodies()) do ids[c.id] = c end
check(ids[0] and ids[500] and ids[500].obj.far == true and ids[500].peer == 1, "bodies: the actor and the player elsewhere")
local on_chars = false
for _, c in ipairs(qc.characters()) do on_chars = on_chars or c.id == 500 end
check(not on_chars, "characters() stays what it was: objects on this level")
local who, peer, d = qc.nearest_body(RECORDS[70])
check(who and who:id() == 500 and peer == 1, "a target on his level: he is the nearest, whatever the coordinates of the host")
check(d == 95 * 95 * 2, "and his distance")
who = qc.nearest_body(RECORDS[71])
check(who and who:id() == 0, "a target on the host's level: not him, though his coordinates are nearer")
check(qc.nearest_body({ position = vec(0, 0, 0), m_game_vertex_id = 30 }) == nil, "nobody on that level: nil")
check(qc.nearest_body(nil) == nil, "no target: nil")
local _, _, flat = qc.nearest_body({ position = vec(5, 40, 5), m_game_vertex_id = 20 }, true)
check(flat == 0, "flat ignores height")

print("== the group's inventory in coop_tasks")
coop.avatar_of = function(peer) return peer == 1 and 500 or nil end
coop.players = function()
	return { { id = 0, nick = "host", is_self = true, avatar_id = 0 }, { id = 1, nick = "c", is_self = false, avatar_id = 500 } }
end
ACTOR.iterate_inventory = function() end
ACTOR.object = function() return nil end
IsItem = function() return nil end
load_script_file("coop_tasks")
local T = coop_tasks
check(T.party_count("bandage") == 2, "party_count sees what a player on another level carries")
check(T.party_count("nothing") == 0, "and not what he has not")
check(T.party_object("quest_doc") and T.party_object("quest_doc"):id() == 901, "party_object finds his item")
check(T.party_holds_id(901, "quest_doc") == true, "party_holds_id: the record of the item says who has it")
check(T.party_holds_id(901, "other") == false, "of another section: no")
check(T.party_holds_id(70) == false, "not an item of the group: no")
local seen = 0
T.party_inventory_walker(function() end)(ACTOR, function() seen = seen + 1 end, nil)
check(seen == 3, "the walker of tasks_multifetch goes through his inventory too")

print(string.format("%d passed, %d failed", PASSES, FAILS))
