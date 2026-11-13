-- Split levels: "the actor is in the zone" for a player on a map server's level. The map server runs the restrictors of its level and tells
-- the world server who of its players stands in which zone; in the far view the stand-in of a zone and db.actor_inside_zones answer from
-- that. The stock conditions (xr_conditions.actor_in_zone, actor_inside_zone, npc_in_zone) are copied as the stock has them.
-- Run: tools\test_lua.cmd far_zones
dofile("tests/lua/support/harness_quests.lua")

local SCRIPTS = { "coop_quests_core", "coop_levels_share", "coop_quests_far" }
local BRIDGE = 0x101
local LEVEL_NAMES = { "l01_escape", "jupiter" }

local records = {} -- the world's records: id -> fields

local function world(M)
	local e = M.env
	e.game_graph = function()
		return { vertex = function(_, v) return { level_id = function() return v end } end }
	end
	local sim = {}
	function sim:level_name(l) return LEVEL_NAMES[l] end
	function sim:switch_distance() return 150 end
	function sim:actor() return { id = 0, m_game_vertex_id = 1, position = vec(0, 0, 0) } end
	function sim:has_info() return false end
	e.alife = function() return sim end
	e.vector = function() return { set = function(_, x, y, z) return vec(x, y, z) end } end
	e.db.anomaly_by_name = {}
	e.db.zone_by_name = {}
	e.db.actor_inside_zones = {}
	local stock_object = e.alife_object
	e.alife_object = function(id)
		local r = records[id]
		if r then return r end
		local se = stock_object(id)
		if se then se.m_game_vertex_id = 1 end
		return se
	end
	e.coop.levels = {
		split = function() return true end,
		my_level = function() return M.my_level end,
		level_of_player = function(peer) return (peer == 1 or peer == 2) and 2 or 1 end,
		map_servers = function() return { { bridge = BRIDGE, level = 2 } } end,
		carried = function() return {} end,
	}
	-- the stock, xr_conditions.script
	e.xr_conditions = {
		actor_in_zone = function(actor, npc, p)
			if not e.db.actor then return false end
			for i = 1, #p do
				local zone = e.db.zone_by_name[p[i]]
				if zone and zone:inside(e.db.actor:position()) then return true end
			end
			return false
		end,
		actor_inside_zone = function(actor, npc, p)
			if not e.db.actor then return false end
			for i = 1, #p do
				if e.db.actor_inside_zones[p[i]] then return true end
			end
			return false
		end,
		npc_in_zone = function(actor, npc, p)
			for i = 1, #p do
				local zone = e.db.zone_by_name[p[i]]
				if zone and zone:inside(npc:position()) then return true end
			end
			return false
		end,
	}
end

local Hm = machine("host", 0)
local Ms = machine("client", BRIDGE)
Hm.my_level, Ms.my_level = 1, 2
world(Hm); world(Ms)
Ms.env.coop.is_map_server = function() return true end

local ZONE = "jup_a9_cam_2"
local function rec(id, pos, extra)
	local r = { id = id, parent_id = 65535, m_game_vertex_id = 2, m_level_vertex_id = 5, position = pos, online = true,
		section_name = function() return "x" .. id end, name = function() return "o" .. id end, clsid = function() return 44 end,
		alive = function() return true end }
	for k, v in pairs(extra or {}) do r[k] = v end
	records[id] = r
	return r
end
rec(500, vec(10, 0, 10))   -- player 1
rec(501, vec(100, 0, 100)) -- player 2
rec(700, vec(11, 0, 10))   -- an NPC beside player 1, in the zone
rec(800, vec(10, 0, 10), { name = function() return ZONE end }) -- the zone

Hm.players = { { id = 0, is_self = true, avatar_id = 0 }, { id = 1, is_self = false, avatar_id = 500 }, { id = 2, is_self = false, avatar_id = 501 } }
Ms.players = { { id = 1, is_self = false, avatar_id = 500 }, { id = 2, is_self = false, avatar_id = 501 } }
local p1 = Ms.new_obj(500, "coop_player_avatar", vec(10, 0, 10))
local p2 = Ms.new_obj(501, "coop_player_avatar", vec(100, 0, 100))
Ms.new_obj(700, "stalker", vec(11, 0, 10))
-- the restrictor of the map server: a sphere of 5 m
local zone = Ms.new_obj(800, "space_restrictor", vec(10, 0, 10), { _name = ZONE })
function zone:inside(pos) return self._pos:distance_to(pos) <= 5 end
Ms.env.db.zone_by_name[ZONE] = zone
Hm.env.db.actor._pos = vec(-500, 0, -500) -- the world server's ghost stands on its own level, far from every zone of jupiter

local function boot(M)
	for _, n in ipairs(SCRIPTS) do load_script(M, n) end
	for _, n in ipairs(SCRIPTS) do
		if M.env[n].on_game_start then M.env[n].on_game_start() end
	end
	fire(M, "actor_on_first_update")
end
boot(Hm); boot(Ms)
pump()

local function share()
	NOW = NOW + 3500
	fire(Ms, "actor_on_update")
	pump()
end

local xc = Hm.env.xr_conditions
local qc = Hm.env.coop_quests_core
local function in_view(peer, name, ...)
	local args = { ... }
	return qc.with_level_of(peer, function() return xc[name](Hm.env.db.actor, nil, args) end)
end

print("== the map server tells who stands in its zones")
share()
check(Hm.env.coop_quests_far._names_of()[2] ~= nil, "the names of its zones reach the world server")
check(in_view(1, "actor_in_zone", ZONE) == true, "actor_in_zone: player 1 stands in it, his scope says yes")
check(in_view(1, "actor_inside_zone", ZONE) == true, "actor_inside_zone: db.actor_inside_zones answers for him")
check(in_view(2, "actor_in_zone", ZONE) == false, "player 2 of the same level is not in it: his scope says no")
check(in_view(2, "actor_inside_zone", ZONE) == false, "nor db.actor_inside_zones of his scope")
check(in_view(1, "actor_in_zone", "no_such_zone") == false, "a zone the level has not: no")
check(xc.actor_in_zone(Hm.env.db.actor, nil, { ZONE }) == false, "out of the far view nothing changes: the world server has no such zone")
check(Hm.env.db.actor_inside_zones[ZONE] == nil, "and its own table is its ghost's")

print("== who asks about an NPC gets no player's answer")
local npc_says = qc.with_level_of(1, function()
	return xc.npc_in_zone(Hm.env.db.actor, Hm.env.level.object_by_id(700), { ZONE })
end)
check(npc_says == false, "npc_in_zone of a stand-in: the shape of the zone is the map server's, no is the honest answer")
local p_says = qc.with_level_of(1, function()
	return xc.npc_in_zone(Hm.env.db.actor, Hm.env.level.object_by_id(500), { ZONE })
end)
check(p_says == true, "a player's stand-in (his record's place) is himself")

print("== he walks out, the next tell says it")
p1._pos = vec(40, 0, 40)
p2._pos = vec(11, 0, 11)
local sent = count_sent(Ms, "coop_share")
share()
check(count_sent(Ms, "coop_share") > sent, "a change is sent")
check(in_view(1, "actor_in_zone", ZONE) == false, "player 1 left it")
check(in_view(2, "actor_in_zone", ZONE) == true, "player 2 came in")
sent = count_sent(Ms, "coop_share")
share()
check(count_sent(Ms, "coop_share") == sent, "nothing changed: nothing is sent")

print("== the group's answer: any player of that level (coop_npc_logic zone_has_player)")
local any = qc.with_level_of(1, function() return Hm.env.db.zone_by_name[ZONE]:anyone_inside() end)
check(any == true, "player 1 is out, player 2 of his level is in: somebody of the group stands in it")

print("== a player who went to another level is not in the zones of this one")
records[501].m_game_vertex_id = 1
check(in_view(2, "actor_in_zone", ZONE) == false, "an old line of the map server does not hold him there")
check(qc.with_level_of(1, function() return Hm.env.db.zone_by_name[ZONE]:anyone_inside() end) == false, "nor for the group")
records[501].m_game_vertex_id = 2

print(string.format("\n%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
