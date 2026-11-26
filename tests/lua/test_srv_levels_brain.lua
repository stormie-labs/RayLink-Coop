-- One brain of the world: the world server picks the targets of squads a map server holds, the stock squad update there gets that
-- answer from the board; an NPC's logic goes with it (docs\SPLIT_LEVELS.md, plan T15). Real coop_srv_levels_brain.script (coop_levels_brain
-- before step S4) over the stubs: it starts from coop_mode.when_srv, which runs here (a split world), and hands itself to the Core
-- (coop_quests_core.part "brain"). Not shipped. Run: tools\test_lua.cmd srv_levels_brain
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local BODIES = { [300] = { id = 300, smart_id = 40 }, [310] = { id = 310, smart_id = 41 }, [40] = { id = 40 }, [50] = { id = 50 }, [41] = { id = 41 } }
alife_object = function(id) return BODIES[id] end
clsid = { online_offline_group_s = 7 }
utils_data = {
	CTime_to_table = function(t) return { at = t.at } end,
	CTime_from_table = function(t) return { at = t.at } end,
}
local asked = {}
sim_board = { simulation_board = {} }
function sim_board.simulation_board:get_squad_target(squad)
	asked[#asked + 1] = squad.id
	return BODIES[50]
end
local ASSIGNED = {}
function sim_board.simulation_board:assign_squad_to_smart(squad, smart)
	ASSIGNED[#ASSIGNED + 1] = { squad = squad.id, smart = smart }
	squad.smart_id = smart
end
SIMBOARD = setmetatable({}, { __index = sim_board.simulation_board })

local LOGIC = { game_object = {} }
alife_storage_manager = { get_state = function() return LOGIC end }
local MINDS = {} -- a table of a squad cannot be read back from a stub string
marshal = {
	encode = function(t)
		if t.active then return "<" .. tostring(t.active) .. ">" end
		MINDS[#MINDS + 1] = t
		return "#" .. #MINDS
	end,
	decode = function(s)
		local n = tonumber(s:match("#(%d+)"))
		return n and MINDS[n] or { active = s:match("<(.*)>") }
	end,
}

local KEPT = nil
local SQUADS = { 300, 310 }
coop.levels = {
	split = function() return true end,
	map_servers = function() return { { bridge = 0x101, level = 2 } } end,
	squads_at = function() return SQUADS end,
	logic_put = function(s) KEPT = s end,
	logic_bytes = function() return KEPT end,
}
local MAP_SERVER = false
coop.is_map_server = function() return MAP_SERVER end
SENT = {}
coop.send_event = function(name, payload, target)
	SENT[#SENT + 1] = { name = name, payload = payload, to = target }
	return true
end

print("== levels_brain")
-- coop_main.on_game_start asks the facade; the stand-in below replaces this one
coop_mode = { decides_world = function() return true end }
load_coop_main()
coop_main.on_game_start()
-- step S4: the co-op first: the script is there, nothing of it starts (the board is the stock's, no event, no callback)
local WAITING, PARTS = {}, {}
coop_mode = { when_srv = function(fn) WAITING[#WAITING + 1] = fn return true end }
coop_quests_core = { set_part = function(name, t) PARTS[name] = t end }
local stock_target = sim_board.simulation_board.get_squad_target
load_script_file("coop_util")
load_script_file("coop_srv_roles")
load_script_file("coop_srv_levels_brain")
coop_srv_levels_brain.on_game_start()
check(#WAITING == 1 and sim_board.simulation_board.get_squad_target == stock_target and PARTS.brain == nil,
	"S4: the co-op: when_srv waits, the stock board is untouched, no part for the Core")
check(coop_main.on_event("coop_brain", "300:41", 0) == nil and coop_srv_levels_brain._test.targets()[300] == nil,
	"S4: the co-op: an event of the brain finds no handler")
-- the server layer answers: what waited runs
WAITING[1]()
check(sim_board.simulation_board.get_squad_target ~= stock_target and PARTS.brain == coop_srv_levels_brain,
	"S4: split: the board is patched and the Core gets its part")

coop_srv_levels_brain._test.tick()
local last = SENT[#SENT]
check(last and last.name == "coop_brain" and last.to == 0x101, "the targets go to the map server that holds the squads")
check(last and last.payload == "300:50,310:50", "every squad it holds, with the world's board's answer")
local n = #SENT
coop_srv_levels_brain._test.tick()
check(#SENT == n, "a target that was just decided is not decided again")
NOW = NOW + 31000
coop_srv_levels_brain._test.tick()
check(#SENT == n + 1, "it is looked at again later")

asked = {}
MODE = "client"
MAP_SERVER = true
coop.is_host = function() return false end
coop_main.on_event("coop_brain", "300:50", 0)
check(sim_board.simulation_board.get_squad_target(SIMBOARD, BODIES[300]).id == 50, "a map server's board answers the world's target")
check(sim_board.simulation_board.get_squad_target(SIMBOARD, BODIES[310]).id == 41, "nothing decided yet: the squad stays at its smart")
check(#asked == 0, "its own board decides nothing")
coop_main.on_event("coop_brain", "310:50", 7)
check(coop_srv_levels_brain._test.targets()[310] == nil, "only the world server decides")

LOGIC.game_object[201] = { active = "beh@guard" }
coop_srv_levels_brain.logic_of(201)
check(KEPT == "<beh@guard>", "an object's logic goes to the engine as bytes")
coop_srv_levels_brain.logic_of(202)
check(KEPT == "", "an object without logic: nothing")
KEPT = "<camper@1>"
coop_srv_levels_brain.logic_in(203)
check(LOGIC.game_object[203] and LOGIC.game_object[203].active == "camper@1", "what came is what xr_logic reads when it comes online")

print("== a squad's mind goes with it, both ways")
local function group(id, t)
	t.id = id
	t.clsid = function() return clsid.online_offline_group_s end
	BODIES[id] = t
	return t
end
local here = group(400, {
	smart_id = 41, assigned_target_id = 50, current_target_id = 41, current_action = 1, task_target_id = 9, scripted_target = "esc_smart",
	idle_time = 7200, rush_to_target = true, respawn_point_id = 40, respawn_point_prop_section = "sect", stay_time = { at = 123 },
})
coop_srv_levels_brain.logic_of(400)
local bytes = KEPT
check(type(bytes) == "string" and bytes ~= "", "a squad's mind goes to the engine as bytes")
local there = group(401, { smart_id = 40, assigned_target_id = 40, current_action = 0, idle_time = 100 })
KEPT = bytes
ASSIGNED = {}
coop_srv_levels_brain.logic_in(401)
check(#ASSIGNED == 1 and ASSIGNED[1].smart == 41 and there.smart_id == 41, "it is assigned to the smart it was at, on the board of this side")
check(there.assigned_target_id == 50 and there.current_target_id == 41 and there.current_action == 1, "it goes where it was going")
check(there.task_target_id == 9 and there.scripted_target == "esc_smart" and there.idle_time == 7200, "a task's target and its stay come with it")
check(there.respawn_point_id == 40 and there.respawn_point_prop_section == "sect", "the smart that spawned it counts it when it dies")
check(there.stay_time and there.stay_time.at == 123 and there.rush_to_target == true, "the stay is not started over")
check(there.first_update == true, "what is done once a map server does not do")
ASSIGNED = {}
KEPT = bytes
coop_srv_levels_brain.logic_in(401)
check(#ASSIGNED == 0, "the same smart: nothing changes on the board")
check(LOGIC.game_object[401] == nil, "a squad's mind is not an NPC's logic")
coop_srv_levels_brain.left(401)
check(ASSIGNED[1] and ASSIGNED[1].smart == nil and there.smart_id == nil, "a squad that went home keeps no job on this level")
ASSIGNED = {}
coop_srv_levels_brain.left(300)
check(#ASSIGNED == 0, "an object that is no squad: nothing")

print("== coming home: the orders stay the world server's")
MODE = "host"
MAP_SERVER = false
coop.is_host = function() return true end
local home = group(402, { smart_id = 41, scripted_target = "newer_order", rush_to_target = nil, force_online = true, respawn_point_id = 7, first_update = false })
coop_main.on_event("coop_brain", "", 0) -- nothing: only to show the state of this side is the world server's
KEPT = bytes -- what the map server sends back: the old order, rush
coop_srv_levels_brain.logic_in(402)
check(home.assigned_target_id == 50 and home.current_action == 1, "where it went comes home")
check(home.scripted_target == "newer_order" and home.rush_to_target == nil and home.force_online == true, "what a task ordered meanwhile stays")
check(home.respawn_point_id == 7, "and the smart that made it")
check(home.first_update == false, "what is done once is still to be done here")

print("== orders of a held squad go to its map server as they change")
SQUADS = { 402 }
SENT = {}
NOW = NOW + 2000
coop_srv_levels_brain._test.tick()
local function sent_orders()
	for i = #SENT, 1, -1 do
		if SENT[i].name == "coop_orders" then return SENT[i] end
	end
end
local told = sent_orders()
check(told and told.to == 0x101 and told.payload == "402|newer_order|0|1", "its orders")
SENT = {}
NOW = NOW + 2000
coop_srv_levels_brain._test.tick()
check(sent_orders() == nil, "nothing changed: nothing goes")
home.scripted_target, home.force_online, home.rush_to_target = nil, nil, true
NOW = NOW + 2000
coop_srv_levels_brain._test.tick()
told = sent_orders()
check(told and told.payload == "402||1|0", "a change goes")
SQUADS = { 300, 310 }
MODE = "client"
MAP_SERVER = true
coop.is_host = function() return false end
local held = group(403, { scripted_target = "old" })
coop_main.on_event("coop_orders", "403|bounty|1|1", 0)
check(held.scripted_target == "bounty" and held.rush_to_target == true and held.force_online == true, "a map server takes them")
coop_main.on_event("coop_orders", "403||0|0", 0)
check(held.scripted_target == nil and held.rush_to_target == nil and held.force_online == nil, "and their end")
coop_main.on_event("coop_orders", "403|x|1|1", 4)
check(held.scripted_target == nil, "from the world server alone")

print("== a squad the world server has not started yet")
local fresh_home = group(404, { smart_id = 41, rush = true })
coop.is_host = function() return true end
MODE, MAP_SERVER = "host", false
coop_srv_levels_brain.logic_of(404)
local fresh = KEPT
coop.is_host = function() return false end
MODE, MAP_SERVER = "client", true
local fresh_there = group(405, { smart_id = 41, rush = true })
KEPT = fresh
coop_srv_levels_brain.logic_in(405)
check(fresh_there.rush_to_target == true and fresh_there.first_update == true, "rush holds on a map server all the same")

print("== treasure_manager.caches: one table of the world")
treasure_manager = { caches = { [600] = "wpn_pm,bandage", [601] = true, [602] = false, [700] = "medkit" } }
LEVELS = { [1] = 1, [2] = 2 }
game_graph = function() return { vertex = function(_, v) return { level_id = function() return LEVELS[v] end } end } end
BODIES[600] = { id = 600, m_game_vertex_id = 2 }
BODIES[601] = { id = 601, m_game_vertex_id = 2 }
BODIES[602] = { id = 602, m_game_vertex_id = 2 }
BODIES[603] = { id = 603, m_game_vertex_id = 2 }
BODIES[700] = { id = 700, m_game_vertex_id = 1 }
MODE = "host"
MAP_SERVER = false
coop.is_host = function() return true end
local function caches_sent()
	for i = #SENT, 1, -1 do
		if SENT[i].name == "coop_caches" then return SENT[i] end
	end
end
SENT = {}
NOW = NOW + 5000
coop_srv_levels_brain._test.tick()
local first = caches_sent()
check(first and first.to == 0x101, "the world server tells a map server the stashes of its level")
check(first and first.payload:find("600|s|wpn_pm,bandage", 1, true) and first.payload:find("601|t|", 1, true) and first.payload:find("602|f|", 1, true), "all of them the first time")
check(first and not first.payload:find("700|", 1, true), "not those of other levels")
SENT = {}
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
check(caches_sent() == nil, "nothing changed: nothing goes")
treasure_manager.caches[603] = "ammo_9x18"
treasure_manager.caches[600] = nil
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
local change = caches_sent()
check(change and change.payload:find("603|s|ammo_9x18", 1, true) and change.payload:find("600|n|", 1, true), "a new stash and one that is gone go")
SENT = {}
treasure_manager.caches[603] = true
coop_main.on_event("coop_caches", "603|t|;602|s|bread", 0x101)
check(treasure_manager.caches[602] == "bread", "what a map server filled comes to the world server's table")
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
check(caches_sent() == nil, "and is not told back to it")
coop_main.on_event("coop_caches", "602|f|", 5)
check(treasure_manager.caches[602] == "bread", "a player is no map server")

MODE = "client"
MAP_SERVER = true
coop.is_host = function() return false end
treasure_manager.caches = { [800] = "wpn_pm", [801] = true }
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
SENT = {}
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
check(caches_sent() == nil, "a map server starts from its save: nothing to say")
treasure_manager.caches[800] = true
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
local up = caches_sent()
check(up and up.to == 0 and up.payload == "800|t|", "a box it filled goes up")
SENT = {}
coop_main.on_event("coop_caches", "801|f|;802|s|bread", 0)
check(treasure_manager.caches[801] == false and treasure_manager.caches[802] == "bread", "the world's word goes into its copy")
coop_srv_levels_brain.caches_now()
coop_srv_levels_brain._test.tick()
check(caches_sent() == nil, "and is not told back")
coop_main.on_event("coop_caches", "801|t|", 7)
check(treasure_manager.caches[801] == false, "only the world server says")

print(string.format("%d passed, %d failed", PASSES, FAILS))
