-- Split levels: what a map server shares with the world server: tables of the stock and GAMMA (coop_srv_levels_share, coop_srv_levels_tables), the
-- anomalies of a level after an emission, a story reward of a map server's condlist, a verb of a player. Real scripts over the quests
-- harness: the world server (level 1) and the map server of level 2. Run: tools\test_lua.cmd srv_far_levels
dofile("tests/lua/support/harness_quests.lua")

local BRIDGE = 0x101
local LEVEL_NAMES = { "l01_escape", "k00_marsh" }

local function world(M)
	local e = M.env
	M.ObjMT.money = function(self) return self._money or 0 end
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
		split = function() return true end,
		my_level = function() return M.my_level end,
		level_of_player = function(peer) return peer == 1 and 2 or 1 end,
		bridge_of_player = function(peer) return peer == 1 and BRIDGE or nil end,
		map_servers = function() return M.bridges end,
		carried = function() return {} end,
	}
	e.coop_mods_core = { find_local = function() end, swap_callback = function(name, old, new) M.swapped = { name, old, new } end }
	e.level.name = function() return M.level_name end
end

local SCRIPTS = { "coop_trust", "coop_quests_core", "coop_srv_levels_share", "coop_srv_quests_far", "coop_srv_levels_tables",
	"coop_tasks", "coop_quests_story", "coop_srv_quests_story" }

local function boot(M)
	load_script(M, "coop_mode")
	load_script(M, "coop_hostplay_mode").on_game_start()
	load_script(M, "coop_srv_mode").on_game_start()
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
end

local Hm = machine("host", 0)
local Ms = machine("client", BRIDGE)
Hm.my_level, Ms.my_level = 1, 2
Hm.level_name, Ms.level_name = "l01_escape", "k00_marsh"
world(Hm); world(Ms)
Hm.env.coop.is_dedicated = function() return true end
Ms.env.coop.is_map_server = function() return true end
Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500 } }

-- the stock's tables
local function trade(M)
	local tm = {}
	M.env.trade_manager = { trade_save = function(t) t.trade_manager = tm end }
	return tm
end
local tm_h, tm_m = trade(Hm), trade(Ms)

local function anomalies(M)
	local da = { updated_anomaly_levels = {}, last_surge_time = 0, calls = {} }
	function da.clean_dynamic_anomalies_global()
		for name in pairs(da.updated_anomaly_levels) do da.calls[#da.calls + 1] = "clean:" .. name end
		da.updated_anomaly_levels = da.updated_anomaly_levels
	end
	function da.clean_artefacts_on_level(l) da.calls[#da.calls + 1] = "artefacts_off:" .. tostring(l) end
	function da.spawn_artefacts_on_level(l) da.calls[#da.calls + 1] = "artefacts_on:" .. tostring(l) end
	function da.build_anomalies_pos_tree() da.calls[#da.calls + 1] = "tree" end
	function da.actor_on_interaction(typ, obj, name)
		if name == "emission_end" and M.emission_global then
			da.last_surge_time = 77
			da.clean_dynamic_anomalies_global()
		elseif name == "emission_end" then
			da.clean_artefacts_on_level(M.level_name)
			da.spawn_artefacts_on_level(M.level_name)
		end
	end
	M.env.drx_da_main = da
	return da
end
local da_h, da_m = anomalies(Hm), anomalies(Ms)

local function enforcer(M)
	local data = { queued = {} }
	M.env.logic_enforcer = { save_state = function(t) t.logic_assign = data end, load_state = function(t) data = t.logic_assign end,
		get = function() return data end }
end
enforcer(Hm); enforcer(Ms)
Hm.env.guards_spawner = { guarded_smarts = {} }
Ms.env.guards_spawner = { guarded_smarts = {} }

Hm.env.xr_effects.reward_money = function(a, b, p) Hm.rewarded = (Hm.rewarded or 0) + 1 end
Ms.env.xr_effects.reward_money = function(a, b, p) Ms.rewarded = (Ms.rewarded or 0) + 1 end

-- bind_anomaly_zone.script:30-38, 42-60: a level spends its mark when it loads, the end of an emission marks every level but this one
local function stock_zone(M)
	local baz = { spawned = 0 }
	function baz.force_spawn_artefacts() baz.spawned = baz.spawned + 1 end
	function baz.first_update()
		local m = M.m_data
		local name = M.level_name
		if m.artefact_respawn_levels and m.artefact_respawn_levels[name] == true then
			m.artefact_respawn_levels[name] = nil
			M.env.bind_anomaly_zone.force_spawn_artefacts()
		end
	end
	M.m_data = {}
	M.env.bind_anomaly_zone = baz
	M.env.alife_storage_manager = { get_state = function() return M.m_data end }
end
stock_zone(Hm); stock_zone(Ms)

boot(Hm); boot(Ms)
fire(Hm, "actor_on_first_update"); fire(Ms, "actor_on_first_update")

local function frames(n)
	for _ = 1, n or 1 do
		NOW = NOW + 20000
		fire(Hm, "actor_on_update")
		fire(Ms, "actor_on_update")
		pump()
	end
end

print("== the host's move: this map server stayed, the world server's Lua is new")
Ms.new_obj(72, "trader", vec(0, 0, 0))
tm_m[72] = { cfg_ltx = "trade.ltx", resupply_time = { Y = 2012, M = 5, D = 1, h = 10, m = 0, s = 0, ms = 0 } }
frames(2)
check(tm_h[72] ~= nil, "the world server has the row")
tm_h[72] = nil -- its Lua went with the reload
frames(2)
check(tm_h[72] == nil, "the map server does not know that: nothing changed, nothing is sent")
fire(Ms, "coop_world_back")
frames(2)
check(tm_h[72] and tm_h[72].resupply_time.D == 1, "the world is back: everything goes up again")
tm_m[72] = nil

print("== a trader's restock reaches the save")
Ms.new_obj(70, "trader", vec(0, 0, 0))
tm_m[70] = { cfg_ltx = "trade.ltx", resupply_time = { Y = 2012, M = 5, D = 3, h = 10, m = 0, s = 0, ms = 0 } }
tm_m[71] = { cfg_ltx = "trade.ltx", resupply_time = { Y = 2012 } } -- stands on another level: the map server has no object of it
frames(2)
check(tm_h[70] and tm_h[70].resupply_time.D == 3, "the world server has the time of the restock")
check(tm_h[71] == nil, "a row of another level is not this map server's to tell")
tm_h[70] = nil
frames(2)
check(tm_h[70] == nil, "nothing changed: nothing is sent")
tm_m[70].resupply_time.D = 4
frames(2)
check(tm_h[70] and tm_h[70].resupply_time.D == 4, "a new restock goes up")

print("== a long table goes in parts")
local long = {}
for i = 1, 400 do long[1000 + i] = { resupply_time = { Y = 2012, M = i }, cfg_ltx = string.rep("x", 40) } end
for id, row in pairs(long) do
	tm_m[id] = row
	Ms.new_obj(id, "trader", vec(0, 0, 0))
end
frames(2)
local n = 0
for id in pairs(long) do n = n + (tm_h[id] and 1 or 0) end
check(n == 400, "every row arrived")

print("== a table of the world server reaches a map server that starts later")
Hm.env.logic_enforcer.get().queued[700] = { logic_name = "logic@x" }
frames(2)
check(Ms.env.logic_enforcer.get().queued[700] ~= nil, "logic_enforcer's queue")
Hm.env.guards_spawner.guarded_smarts.zat_b5 = { 300 }
NOW = NOW + 20000
frames(2)
check(Ms.env.guards_spawner.guarded_smarts.zat_b5 ~= nil, "guards_spawner's squads")
Hm.bridges = {}
frames(1)
Hm.bridges = { { bridge = BRIDGE, level = 2 } }
Ms.env.guards_spawner.guarded_smarts = {}
frames(1)
check(Ms.env.guards_spawner.guarded_smarts.zat_b5 ~= nil, "a new process on that bridge gets it again, though nothing changed")

print("== a new process on the same bridge says hello and gets everything")
Ms.env.guards_spawner.guarded_smarts = {}
Hm.handlers["coop_share"](Hm.env.coop_main.encode({ k = "__hello" }), BRIDGE)
frames(1)
check(Ms.env.guards_spawner.guarded_smarts.zat_b5 ~= nil, "nothing changed, the bridge stayed: it still arrives")

print("== a table longer than one codec's limit for a network string")
local huge = {}
for i = 1, 3000 do huge[20000 + i] = { resupply_time = { Y = 2012 }, cfg_ltx = string.rep("x", 40) } end
for id, row in pairs(huge) do
	tm_m[id] = row
	Ms.new_obj(id, "trader", vec(0, 0, 0))
end
frames(2)
check(tm_h[20001] ~= nil and tm_h[23000] ~= nil, "it reads on the other side")

print("== only a bridge writes to the world server, only the world server to a map server")
local before = #Ms.sent
Hm.handlers["coop_share"](Hm.env.coop_main.encode({ k = "trade", s = 99, i = 1, n = 1, d = "{}" }), 1)
check(tm_h[70] ~= nil, "a player's event is not taken")

print("== a level's anomalies")
da_h.updated_anomaly_levels.l01_escape = { time = 1, anomalies = { 1 } }
da_h.updated_anomaly_levels.k00_marsh = { time = 1, anomalies = { 2 } }
da_h.updated_anomaly_levels.zaton = { time = 1, anomalies = { 3 } }
da_m.updated_anomaly_levels.k00_marsh = { time = 5, anomalies = { 9, 10 }, anomalies_properties = { [9] = { time_active = 7, update_time = 1, active = true } } }
frames(2)
check(da_h.updated_anomaly_levels.k00_marsh.time == 5, "a map server's row replaces the world server's")
local props = da_h.updated_anomaly_levels.k00_marsh.anomalies_properties
check(props[9].time_active == 7 and props[9].update_time == nil and props[9].active == nil, "without what changes every few seconds")
local sent_share = count_sent(Ms, "coop_share")
da_m.updated_anomaly_levels.k00_marsh.anomalies_properties[9].update_time = 2
da_m.updated_anomaly_levels.k00_marsh.anomalies_properties[9].active = false
frames(2)
check(count_sent(Ms, "coop_share") == sent_share, "such a change sends nothing")
Hm.emission_global = true
da_h.calls = {}
Hm.env.drx_da_main.actor_on_interaction("anomalies", nil, "emission_end")
pump()
local cleaned = table.concat(da_h.calls, " ")
check(cleaned:find("clean:zaton", 1, true) and cleaned:find("clean:l01_escape", 1, true), "the world server cleans what nobody leads")
check(not cleaned:find("clean:k00_marsh", 1, true), "not the level a map server leads")
check(da_h.updated_anomaly_levels.k00_marsh ~= nil, "and the table is whole again")
local m_calls = table.concat(da_m.calls, " ")
check(m_calls:find("clean:k00_marsh", 1, true) and m_calls:find("tree", 1, true), "the map server takes its part of it")
check(da_m.last_surge_time == 77, "and knows when it was")
Hm.emission_global = false
da_m.calls = {}
Hm.env.drx_da_main.actor_on_interaction("anomalies", nil, "emission_end")
pump()
m_calls = table.concat(da_m.calls, " ")
check(m_calls:find("artefacts_off:k00_marsh", 1, true) and m_calls:find("artefacts_on:k00_marsh", 1, true), "or its new artefacts: one roll, on the world server")
check(Hm.swapped and Hm.swapped[1] == "actor_on_interaction", "the handler in axr_main's table is the wrapped one")

print("== a story reward of a condlist on a map server")
Hm.env.coop_tasks_items.give_to_peer = function(peer, money) Hm.paid = { peer, money } end
-- the stock's shape: the map server names the reward by its condlist (R32 W7, coop_srv_quests_story)
Ms.env.xr_logic.pick_section_from_condlist(Ms.actor, Ms.actor, stock_condlist("%=reward_money(500)%"))
pump()
check(Ms.rewarded == nil, "its ghost gets nothing")
check(Hm.rewarded == 1, "the world server's actor gets it")
check(Hm.paid and Hm.paid[1] == 1, "and the player on the other level, through share_reward")
Hm.paid, Hm.rewarded = nil, nil
Ms.env.xr_effects.reward_money(Ms.actor, nil, { "500" })
pump()
check(Hm.paid == nil and Hm.rewarded == nil, "out of a condlist a map server pays nobody")

print("== artefacts after an emission: a level spends its mark in the world's save")
Hm.m_data.artefact_respawn_levels = { k00_marsh = true, zaton = true }
local function start_map_server()
	Ms.m_data = { artefact_respawn_levels = {} } -- the save it got
	for name, v in pairs(Hm.m_data.artefact_respawn_levels) do Ms.m_data.artefact_respawn_levels[name] = v end
	Ms.env.bind_anomaly_zone.first_update()
end
start_map_server()
frames(2)
check(Ms.env.bind_anomaly_zone.spawned == 1, "the map server of the marked level spawns its artefacts")
check(Hm.m_data.artefact_respawn_levels.k00_marsh == nil, "the mark of its level is gone from the world's save")
check(Hm.m_data.artefact_respawn_levels.zaton == true, "the marks of the other levels stay")
start_map_server()
frames(2)
check(Ms.env.bind_anomaly_zone.spawned == 1, "the next map server of that level does not spawn them again")
Hm.m_data.artefact_respawn_levels.k00_marsh = true -- the next emission, this map server lives: it spawned them at its end
Ms.env.bind_anomaly_zone.force_spawn_artefacts()
frames(2)
check(Hm.m_data.artefact_respawn_levels.k00_marsh == nil, "the emission a live map server served is spent too")
Hm.m_data.artefact_respawn_levels.l01_escape = true
Hm.env.bind_anomaly_zone.first_update()
frames(2)
check(Hm.m_data.artefact_respawn_levels.l01_escape == nil and Hm.env.bind_anomaly_zone.spawned == 1, "the world server's own level is as in the stock")

print("== a box rolled for a player's window stays rolled in the world's save")
local function rolls(M)
	M.env.smr_loot = { boxes = { [500] = true } } -- the save
	M.env.zz_treasure_manager_pba_less_artys = { boxes = {} }
	M.env.coop_mods_core.find_local = function(m, name) return m[name] end
end
rolls(Hm); rolls(Ms)
Ms.env.smr_loot.boxes[501] = true
Ms.env.zz_treasure_manager_pba_less_artys.boxes[502] = true
frames(2)
check(Hm.env.smr_loot.boxes[501] == true and Hm.env.smr_loot.boxes[500] == true, "Zone Customization Project's table, added to")
check(Hm.env.zz_treasure_manager_pba_less_artys.boxes[502] == true, "PBA's table")
check(Hm.env.smr_loot.boxes[502] == nil, "each its own")

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
