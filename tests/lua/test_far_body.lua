-- A player on a map server's level has no game object on the world server: his records stand for him in what the task code asks of a
-- character (coop_quests_core far_body, coop_tasks party_*, coop_quests_party nearest). Real scripts over the stubs.
-- Not shipped. Run: tools\test_lua.cmd far_body
MODE = "host"
dofile("tests/lua/support/stubs.lua")

coop.is_dedicated = function() return true end
local LEVELS = { [10] = 1, [20] = 2, [30] = 3 } -- game vertex -> level
game_graph = function()
	return { vertex = function(_, v) return { level_id = function() return LEVELS[v] end } end }
end
local function vec(x, y, z) return { x = x, y = y, z = z } end

local CARRIED = {
	[500] = { { id = 901, section = "quest_doc", condition = 0.8 }, { id = 902, section = "bandage", condition = 1 }, { id = 903, section = "bandage", condition = 1 } },
}
local RECORDS = {
	[500] = { position = vec(5, 0, 5), m_level_vertex_id = 77, m_game_vertex_id = 20, alive = function() return true end },
	[510] = { position = vec(1, 0, 1), m_level_vertex_id = 10, m_game_vertex_id = 10, alive = function() return true end },
	[901] = { parent_id = 500, section_name = function() return "quest_doc" end },
	[70] = { position = vec(100, 0, 100), m_game_vertex_id = 20 }, -- a target on his level
	[71] = { position = vec(100, 0, 100), m_game_vertex_id = 10 }, -- a target on the other player's map
}
alife_object = function(id) return RECORDS[id] end
local RELEASED, MADE = {}, {}
alife_release_id = function(id) RELEASED[#RELEASED + 1] = id end
itms_manager = { create_item = function(section, to, t) MADE[#MADE + 1] = { section = section, to = to, t = t } end }
ini_sys = { r_float_ex = function(_, sec, key) return key == "max_uses" and sec == "bandage" and 3 or nil end }

coop.levels = {
	split = function() return true end,
	my_level = function() return 3 end,
	level_of_player = function(peer) return ({ [1] = 2, [2] = 1 })[peer] end,
	carried = function(id) return CARRIED[id] or {} end,
}
local ACTOR = { }
function ACTOR:id() return 0 end
function ACTOR:position() return vec(1, 0, 1) end
function ACTOR:game_vertex_id() return 30 end
function ACTOR:alive() return true end
db = db or {}
db.actor = ACTOR
level = level or {}
level.object_by_id = function(id) return id == 0 and ACTOR or nil end

print("== far_body")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script_file("coop_mode")
facade.on_game_start()
modes.live(facade)
load_script_file("coop_quests_core")
load_script_file("coop_srv_quests_core").on_game_start()
local qc = coop_quests_core
check(qc.far_body(0, 0) == nil, "the world server ghost has no far body")
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
local receiver = { id = function() return 600 end }
far:transfer_item(doc, receiver)
check(RELEASED[1] == 901 and MADE[1].section == "quest_doc" and MADE[1].to == receiver, "handing over: the record goes, a new one is made at the other end")
-- the quest audit, 2026-11-13: the stock pays a fetch task by the item's condition (cost * con^2); a new whole item was made
check(MADE[1].t and MADE[1].t.cond == 0.8, "as worn as the one that went: a worn item is not paid as a new one")
far:transfer_item(far:object("bandage"), receiver)
check(MADE[2].section == "bandage" and MADE[2].t == nil, "a whole item: made the stock's plain way")

coop.levels.split = function() return false end
check(qc.far_body(1, 500) == nil, "split levels off: nobody is far")
coop.levels.split = function() return true end

coop.avatar_of = function(peer) return ({ [1] = 500, [2] = 510 })[peer] end
coop.players = function()
	return { { id = 1, nick = "A", avatar_id = 500 }, { id = 2, nick = "B", avatar_id = 510 } }
end

print("== bodies and the nearest on a level")
local ids = {}
for _, c in ipairs(qc.bodies()) do ids[c.id] = c end
check(not ids[0] and ids[510] and ids[500] and ids[500].obj.far == true and ids[500].peer == 1, "bodies: both remote players, no ghost")
local on_chars = false
for _, c in ipairs(qc.characters()) do on_chars = on_chars or c.id == 500 end
check(not on_chars, "characters() stays what it was: objects on this level")
local who, peer, d = qc.nearest_body(RECORDS[70])
check(who and who:id() == 500 and peer == 1, "a target on his level: he is the nearest, regardless of the other player")
check(d == 95 * 95 * 2, "and his distance")
who = qc.nearest_body(RECORDS[71])
check(who and who:id() == 510, "a target on B's level: the other map is irrelevant")
check(qc.nearest_body({ position = vec(0, 0, 0), m_game_vertex_id = 30 }) == nil, "nobody on that level: nil")
check(qc.nearest_body(nil) == nil, "no target: nil")
local _, _, flat = qc.nearest_body({ position = vec(5, 40, 5), m_game_vertex_id = 20 }, true)
check(flat == 0, "flat ignores height")

print("== the group's inventory in coop_tasks")
ACTOR.iterate_inventory = function() end
ACTOR.object = function() return nil end
IsItem = function() return nil end
load_script_file("coop_tasks")
local T = coop_tasks
check(coop_tasks_items.party_count("bandage") == 2, "party_count sees what a player on another level carries")
check(coop_tasks_items.party_count("nothing") == 0, "and not what he has not")
check(coop_tasks_items.party_object("quest_doc") and coop_tasks_items.party_object("quest_doc"):id() == 901, "party_object finds his item")
check(coop_tasks_items.party_holds_id(901, "quest_doc") == true, "party_holds_id: the record of the item says who has it")
check(coop_tasks_items.party_holds_id(901, "other") == false, "of another section: no")
check(coop_tasks_items.party_holds_id(70) == false, "not an item of the group: no")
local seen = 0
coop_tasks_items.party_inventory_walker(function() end)(ACTOR, function() seen = seen + 1 end, nil)
check(seen == 3, "the walker of tasks_multifetch goes through his inventory too")

print("== Server: give_to_peer rolls a multi-use reward for a world-written body with no game object")
do
	local processor = { Uses = {}, Cond = {}, Ammo = {}, Remove = {} }
	local staged, created
	itms_manager.get_item_processor = function() return processor end
	itms_manager.create_item = function(section, to)
		created = { id = 4000, section = section, parent = to:id() }
		RECORDS[4000] = created
		return created
	end
	itms_manager.process_item = function(_, id, t) processor.Uses[id] = t.uses end
	alife_create_item = function(...) return itms_manager.create_item(...) end
	alife_process_item = function(...) return itms_manager.process_item(...) end
	device = function() return { frame = 1 } end
	IsItem = function(kind, sec) return kind == "multiuse" and sec == "bandage" end
	coop.items = { set_initial = function(id, state)
		assert(RECORDS[id] == created and level.object_by_id(id) == nil)
		staged = state
		return true
	end }
	load_script_file("coop_item_entity_state").on_game_start()
	local random = math.random
	math.random = function(lo, hi) assert(lo == 1 and hi == 3); return 1 end
	coop_tasks_items.give_to_peer(1, 0, { "bandage" })
	math.random = random
	check(created and created.parent == 500, "the reward is created under the player's record")
	check(staged and staged.uses == 1 and processor.Uses[4000] == nil,
		"the stock uses roll is staged on that entity before give_to_peer returns")
	-- Dev 58 Lua fix: a shared copy is rolled only when the stock effect that made the reward rolls it
	-- (xr_effects.reward_item, reward_random_item through it); give_actor and give_letter make it as it is
	local draws = 0
	math.random = function(lo, hi) assert(lo == 1 and hi == 3); draws = draws + 1; return 2 end
	for _, effect in ipairs({ "give_actor", "give_letter" }) do
		staged, created = nil, nil
		coop_tasks_items.give_to_peer(1, 0, { "bandage" }, effect)
		check(created and created.parent == 500 and staged == nil and draws == 0,
			"a reward shared from " .. effect .. " is made as that stock effect makes it: no roll")
	end
	for _, effect in ipairs({ "reward_item", "reward_random_item" }) do
		staged, created = nil, nil
		coop_tasks_items.give_to_peer(1, 0, { "bandage" }, effect)
		check(created and staged and staged.uses == 2, "a reward shared from " .. effect .. " gets the stock roll")
	end
	math.random = random
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
