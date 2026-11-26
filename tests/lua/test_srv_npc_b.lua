-- NPC compatibility on separate server maps.
dofile("tests/lua/support/harness_npc.lua")

local modes = dofile("tests/lua/support/modes.lua")
local function server(map)
	reset_world()
	local M = machine(map and "client" or "host", map and 0x101 or 0, { [1] = 500 })
	M.env.coop.is_dedicated = function() return not map end
	M.env.coop.is_map_server = function() return map end
	modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
	load_script(M, "coop_trust")
	load_script(M, "coop_npc_players")
	local proxy = map and M.add(make_obj(500, 10, 0, 0, { _name = "proxy1" }))
	return M, proxy
end

print("== coop_npc_compat: a player on a map server's level is a record on the world server, and he counts")
local H, proxy = server(false)
local SQ = {}
SQ.check_online_status = function(self)
	if self.position:distance_to(H.env.db.actor:position()) <= 75 then self.forced_online_status = false else self.forced_online_status = nil end
end
local SM = {}
SM.try_respawn = function(self) self.respawned = true; self.saw = self.is_on_actor_level end
H.env.sim_squad_scripted = { sim_squad_scripted = SQ }
H.env.smart_terrain = { se_smart_terrain = SM }
local KS = load_script(H, "coop_npc_compat")
KS.on_game_start()
H.env.coop_npc_players.host_on = function() return true end
local LEVEL_OF = { [1] = 1, [2] = 2 } -- game vertex -> level
H.env.game_graph = function() return { vertex = function(_, v) return { level_id = function() return LEVEL_OF[v] end } end } end
local RECORD = { m_game_vertex_id = 2, position = vector():set(7000, 0, 7000) }
H.env.alife_object = function(id) return id == 500 and RECORD or nil end
local his_smart = { position = vector():set(7030, 0, 7000), respawn_radius = 150, m_game_vertex_id = 2 }
SM.try_respawn(his_smart)
check(his_smart.respawned == nil, "no respawn 30 m from the record of his body")
local on_his_level = { position = vector():set(9000, 0, 7000), respawn_radius = 150, m_game_vertex_id = 2 }
SM.try_respawn(on_his_level)
check(on_his_level.respawned == true and on_his_level.saw == true, "far from him: it respawns, with his level as the actor's (respawn_only_level)")
check(on_his_level.is_on_actor_level == nil, "and the smart stays as it was")
RECORD.m_game_vertex_id = 1
local another_level = { position = vector():set(7030, 0, 7000), respawn_radius = 150, m_game_vertex_id = 2 }
SM.try_respawn(another_level)
check(another_level.respawned == true, "the same coordinates on another level are nobody's")

print("== coop_npc_compat: on a map server its ghost is nobody")
H, proxy = server(true)
SQ = {}
SQ.check_online_status = function(self)
	if self.position:distance_to(H.env.db.actor:position()) <= 75 then self.forced_online_status = false else self.forced_online_status = nil end
end
H.env.sim_squad_scripted = { sim_squad_scripted = SQ }
H.env.smart_terrain = { se_smart_terrain = {} }
H.env.se_actor = { se_actor = {
	get_location = function(self) return self.position, self.m_level_vertex_id, self.m_game_vertex_id end,
	get_alife_task = function(self) return "ghost's" end,
} }
KS = load_script(H, "coop_npc_compat")
KS.on_game_start()
H.env.coop_npc_players.host_on = function() return true end
H.env.db.actor._pos = vector():set(5000, 0, 5000) -- where the ghost stands
local at_ghost = { online = false, position = vector():set(5010, 0, 5000) }
SQ.check_online_status(at_ghost)
check(at_ghost.forced_online_status == nil, "a squad next to the ghost is near nobody")
local at_player = { online = false, position = vector():set(proxy:position().x + 20, 0, proxy:position().z) }
SQ.check_online_status(at_player)
check(at_player.forced_online_status == false, "a squad 20 m from a player of its level stays offline")
check(H.env.coop_npc_players.any_within(vector():set(5001, 0, 5000), 50) == false, "nothing is near the ghost")
check(H.env.coop_npc_players.any_within(proxy:position(), 50) == true, "the player of the level is")
local GHOST = { position = vector():set(5000, 0, 5000), m_level_vertex_id = 1, m_game_vertex_id = 1 }
check(H.env.se_actor.se_actor.get_location(GHOST) == proxy:position(), "a squad sent at the actor goes to a player of the level")
H.env.CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
check(H.env.se_actor.se_actor.get_alife_task(GHOST).lv == proxy:level_vertex_id(), "the engine's task too")
H.env.sim_squad_scripted, H.env.smart_terrain, H.env.se_actor = nil, nil, nil

print("== coop_npc_compat: an old corpse near a client is not released (audit B6)")
H, proxy = server(true)
local RB = {}
-- release_body_manager.script Crelease_body:clear L144-199: releases what lies >= dist (sq) from db.actor
RB.clear = function(self, all, dist)
	local pos = H.env.db.actor:position()
	for id, v in pairs(self.release_objects_table) do
		local se = H.env.alife():object(id)
		if all or pos:distance_to_sqr(se.position) >= (dist or 5625) then
			self.released[#self.released + 1] = id
			self.release_objects_table[id] = nil
			self.size = self.size - 1
		end
	end
end
H.env.release_body_manager = { Crelease_body = RB }
local bodies = {
	[801] = { position = vector():set(proxy:position().x + 10, 0, proxy:position().z) }, -- next to the client
	[802] = { position = vector():set(proxy:position().x + 900, 0, proxy:position().z + 900) }, -- far from everybody
}
H.env.alife = function() return { object = function(_, id) return bodies[id] end } end
local KB = load_script(H, "coop_npc_compat")
KB.on_game_start()
H.env.coop_npc_players.host_on = function() return true end
H.env.db.actor._pos = vector():set(5000, 0, 5000)
local rb = setmetatable({ release_objects_table = { [801] = true, [802] = true }, size = 6, released = {} }, { __index = RB })
RB.clear(rb)
check(#rb.released == 1 and rb.released[1] == 802, "only the body far from every player is released")
check(rb.release_objects_table[801] == true and rb.release_objects_table[802] == nil, "the body near the client stays queued")
check(rb.size == 5, "the count follows what was released")
rb.released = {}
RB.clear(rb, true)
check(#rb.released == 0 and rb.release_objects_table[801] == true, "clear(all) with a player on this level: the map keeps bodies near a player who stays")

print(string.format("\nRESULT: %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("tests failed") end
