-- A trip on one's own map (Fair Fast Travel, backpack travel, a hired guide, a marsh guide, a "yes" to another player's trip): the squads
-- the traveller leads that follow him come to him, brought by the authority of his level (coop_npc_companions.bring_mine, npc.comp_bring).
-- FFT's line "Your companions, if any, travel with you - unless you asked them to wait" (owner 2026-11-16: check that it works so in co-op).
-- Ordinary co-op: the host (peer 0) and two clients (peers 1, 2; proxies 500, 501). Split levels: the world server, a map server of
-- l02_garbage (bridge 0x101) and a client on it. Squads are luabind stand-ins (tests\lua\support\luabind_like.lua).
-- Run: tools\test_lua.cmd companion_trip
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/luabind_like.lua")

local NAMES = { [1] = "l01_escape", [2] = "l02_garbage" }
local LEVEL_OF_VERTEX = { [10] = 1, [20] = 2 }
local LV, LVN = {}, 0

local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

-- AI nodes: level.vertex_id of a point is a new node at that point, level.vertex_position gives the point back.
local function lv_env(M)
	M.env.level.vertex_id = function(p) LVN = LVN + 1; LV[LVN] = vec(p.x, p.y, p.z); return LVN end
	M.env.level.vertex_position = function(lv) local p = LV[lv]; return p and vec(p.x, p.y, p.z) end
end

-- An object stands at x on machine M (a teleport, a snapshot of a proxy).
local function place(M, o, x)
	o._pos = vec(x, 0, 0)
	local lv = M.env.level.vertex_id(o._pos)
	o.level_vertex_id = function() return lv end
end

-- An online NPC of machine M: the engine's game_object:set_npc_position moves the NPC itself.
local function npc(M, id, x)
	local o = M.add(make_obj(id, x, 0, 0, { _name = "m" .. id }))
	o.set_npc_position = function(self, p) self._pos = vec(p.x, p.y, p.z); self.placed = (self.placed or 0) + 1 end
	o.dont_has_info = function(self, i) return not self:has_info(i) end
	M.env.db.storage[id] = { object = o }
	return o
end

local function new_squad(id, vertex, ...)
	local t = { id = id, members = { ... }, m_game_vertex_id = vertex }
	function t.squad_members(self)
		local i = 0
		return function() i = i + 1; local m = t.members[i]; if m then return { id = m } end end
	end
	function t.commander_id() return t.members[1] end
	function t.force_change_position(self, p) t.forced = vec(p.x, p.y, p.z) end
	return luabind_object(t), t
end

local function stock(M, W)
	local E = M.env
	E.actor_menu = { set_msg = function() end }
	E.axr_task_manager = { hostages_by_id = {} }
	E.EDDListType = { iActorBag = 1, iDeadBodyBag = 2 }
	E.CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
	E.alife_object = function(id) return W.squads[id] end
	E.get_object_squad = function(o)
		for _, sq in pairs(W.squads) do
			for k in sq:squad_members() do if k.id == o:id() then return sq end end
		end
	end
	M.se = {}
	E.se_save_var = function(id, name, var, value) M.se[id] = M.se[id] or {}; M.se[id][var] = value end
	E.se_load_var = function(id, name, var) return M.se[id] and M.se[id][var] end
	E.db.offline_objects = {}
	local ac = { companion_squads = {} }
	E.axr_companions = ac
	function ac.get_inventory_table() return {} end
	function ac.setup_companion_logic(o) o:give_info_portion("npcx_is_companion") end
	-- stock axr_companions.script:293: the commander's se var, then his infos (sim:has_info)
	function ac.companion_squad_can_teleport(squad)
		local id = squad:commander_id()
		if E.se_load_var(id, nil, "companion_cannot_teleport") then return false end
		local o = M.objects[id]
		if id and o and (o:has_info("npcx_beh_patrol_mode") or o:has_info("npcx_beh_wait")) then return false end
		return true
	end
	E.dialogs_axr_companion = {}
	E.axr_beh = { action_beh = { execute = function() end } }
	E.sim_squad_scripted = { sim_squad_scripted = { get_current_task = function() return "stock task" end } }
	E.TeleportSquad = function(squad) M.teleported = squad.id end
	E.game_graph = function()
		return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF_VERTEX[gv] end } end }
	end
	E.alife = function() return { level_name = function(_, id) return NAMES[id] end } end
end

-- Fair Fast Travel as it is (temp\gamma_ref\scripts\game_fast_travel.script 1244-1289, tp_respects_waitfollow and tp_ignores_hostages on):
-- the stock's own walk over axr_companions.companion_squads, run by the time event after a trip on the same map.
local function fft(M, on)
	local E = M.env
	local m = { on = on }
	function m.companions_travel_with_actor() return m.on end
	function m.bring_companions_to_actor(forced)
		if not (forced or m.companions_travel_with_actor()) then return end
		local lvid_pos = E.level.vertex_position(E.db.actor:level_vertex_id())
		for _, squad in pairs(E.axr_companions.companion_squads) do
			if squad then
				if squad.online == false then squad:force_change_position(lvid_pos) end
				for k in squad:squad_members() do
					local o = E.db.storage[k.id] and E.db.storage[k.id].object
					local hostage = E.se_load_var(k.id, "", "companion_cannot_teleport")
					local following = o and o:dont_has_info("npcx_beh_wait") and true or false
					if following and not hostage then
						E.db.offline_objects[k.id] = E.db.offline_objects[k.id] or {}
						E.db.offline_objects[k.id].level_vertex_id = E.level.vertex_id(lvid_pos)
						o:set_npc_position(lvid_pos)
					end
				end
			end
		end
		return true
	end
	E.game_fast_travel = m
	return m
end

-- Squads on the host: 300 (member 201) A's, follows; 330 (231) A's, told to wait; 340 (241) A's, may not teleport (a hostage, the
-- Fanatic); 310 (211) B's; 320 (221) the host's own. Members stand at x = 50..58, the host at 0, A at 5, B at 6.
local function stand(opts)
	opts = opts or {}
	reset_world()
	LV, LVN = {}, 0
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	local W = { H = H, A = A, B = B, squads = {}, raw = {} }
	for _, M in ipairs({ H, A, B }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W)
		lv_env(M)
		if opts.env then opts.env(M) end
	end
	W.proxy_a = H.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = H.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	place(H, W.proxy_a, 5)
	place(H, W.proxy_b, 6)
	place(H, H.env.db.actor, 0)
	local rows = { { 300, 201, 500, 50 }, { 330, 231, 500, 52 }, { 340, 241, 500, 54 }, { 310, 211, 501, 56 }, { 320, 221, nil, 58 } }
	for _, r in ipairs(rows) do
		W.squads[r[1]], W.raw[r[1]] = new_squad(r[1], 10, r[2])
		W[r[2]] = npc(H, r[2], r[4])
		W[r[2]]:give_info_portion("npcx_is_companion")
	end
	W.CH = load_script(H, "coop_npc_companions")
	W.CA = load_script(A, "coop_npc_companions")
	W.CB = load_script(B, "coop_npc_companions")
	W.CH.on_game_start()
	W.CA.on_game_start()
	W.CB.on_game_start()
	for _, r in ipairs(rows) do
		H.env.axr_companions.companion_squads[r[1]] = W.squads[r[1]]
		W.CH._leaders()[r[1]] = r[3]
	end
	W[231]:give_info_portion("npcx_beh_wait")
	H.se[241] = { companion_cannot_teleport = true }
	function W.tick(ms)
		NOW = NOW + (ms or 300)
		for _, M in ipairs({ H, A, B }) do
			M.env.coop_npc_players.invalidate()
			M.fire("actor_on_update")
		end
		pump()
	end
	W.tick(3000)
	return W
end

local function at(o, x) return math.abs(o._pos.x - x) < 0.01 end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

print("== a client's trip on his map: his following squad comes to him, once the host saw him arrive")
do
	local W = stand()
	local H, A = W.H, W.A
	place(A, A.env.db.actor, 1000)
	W.CA.bring_mine()
	local sent = sent_named(A, "npc.comp_bring")
	check(#sent == 1 and sent[1].target == 0, "the client asks the authority of his level")
	check(sent[1] and sent[1].payload == "", "the word carries no position and no squad")
	pump()
	check(at(W[201], 50), "the host still sees him at the old place: the squad is not put there")
	W.tick(300)
	check(at(W[201], 50), "nor on the next tick, before the host's view of him moved")
	place(H, W.proxy_a, 1000)
	W.tick(300)
	check(at(W[201], 1000), "his following squad is brought to him once the host saw him arrive")
	check(W[201].placed == 1, "the online NPC itself is put there (set_npc_position)")
	check(H.teleported == nil, "no ALife teleport: it would take an online NPC offline")
	check(at(W[231], 52), "a squad told to wait stays")
	check(at(W[241], 54), "a squad that may not teleport stays")
	check(at(W[211], 56), "another client's squad stays")
	check(at(W[221], 58), "the host's own squad stays")
	W.tick(2000)
	check(W[201].placed == 1, "brought once")
end

print("== the host's view of him never moves: after the deadline the squad comes to where the host sees him")
do
	local W = stand()
	local H, A = W.H, W.A
	W.CA.bring_mine()
	pump()
	W.tick(300)
	W.tick(300)
	check(at(W[201], 50), "not before the deadline")
	W.tick(1000)
	check(at(W[201], 5), "after it (1.5 s), to his character as the host sees it")
end

print("== a squad already next to its leader stays put")
do
	local W = stand()
	local H = W.H
	W.CA.bring_mine()
	pump()
	place(H, W.proxy_a, 47)
	W.tick(300)
	W.tick(2000)
	check(W[201].placed == nil and at(W[201], 50), "not moved")
end

print("== a forged word: squads and a place on the wire count for nothing")
do
	local W = stand()
	local H, A = W.H, W.A
	A.env.coop_npc_players.send("npc.comp_bring", { s = 310, i = 211, x = 777, y = 0, z = 0 }, 0)
	pump()
	place(H, W.proxy_a, 1000)
	W.tick(300)
	check(at(W[201], 1000), "his own squad comes to his character")
	check(at(W[211], 56), "the squad named on the wire, another player's, stays")
end

print("== a player who leads nothing: costs nothing, logs nothing")
do
	local W = stand()
	local H, B = W.H, W.B
	W.CH._leaders()[310] = nil
	H.env.axr_companions.companion_squads[310] = nil
	local refused, lines = W.CH._stats().refused, #H.log
	W.CB.bring_mine()
	pump()
	check(count(W.CH._bring_wait()) == 0, "no request kept")
	check(W.CH._stats().refused == refused and #H.log == lines, "nothing counted, nothing logged")
	W.CB.bring_mine()
	pump()
	check(W.CH._stats().refused == refused, "a second one neither")
	place(H, W.proxy_b, 1000)
	W.tick(2000)
	check(at(W[201], 50) and at(W[221], 58), "nobody's squad moved")
end

print("== two requests in a row: the second is refused")
do
	local W = stand()
	local H, A = W.H, W.A
	local refused = W.CH._stats().refused
	W.CA.bring_mine()
	W.CA.bring_mine()
	pump()
	check(W.CH._stats().refused == refused + 1, "the second is refused (stats.refused)")
	place(H, W.proxy_a, 1000)
	W.tick(300)
	check(W[201].placed == 1 and at(W[201], 1000), "the first is served, once")
	W.tick(3000)
	W.CA.bring_mine()
	pump()
	check(W.CH._stats().refused == refused + 1 and count(W.CH._bring_wait()) == 1, "a later trip is served again")
end

print("== the host's own trip: Fair Fast Travel's stock walk moves only the squads the host leads")
do
	local W = stand({ env = function(M) fft(M, true) end })
	local H = W.H
	W.tick(300)
	place(H, H.env.db.actor, 2000)
	H.env.game_fast_travel.bring_companions_to_actor() -- the stock time event after a trip on the same map
	check(at(W[221], 2000), "his own squad comes with him")
	check(at(W[201], 50), "a client's squad is not dragged to the host")
	check(at(W[211], 56), "nor the other client's")
	check(at(W[231], 52), "a squad told to wait stays")
	check(count(H.env.axr_companions.companion_squads) == 5, "the stock table is whole again after the call")
	W.CH.bring_mine()
	check(at(W[201], 50) and at(W[211], 56) and at(W[221], 2000), "bring_mine on the host: the same squads")
	check(#sent_named(H, "npc.comp_bring") == 0, "the host asks nobody")
end

print("== the host's own trip without Fair Fast Travel: bring_mine brings his squads")
do
	local W = stand()
	local H = W.H
	place(H, H.env.db.actor, 2000)
	W.CH.bring_mine()
	check(at(W[221], 2000) and W[221].placed == 1, "his own squad comes with him")
	check(at(W[201], 50) and at(W[231], 52) and at(W[241], 54) and at(W[211], 56), "nobody else's, no waiting one, no hostage")
end

print("== an offline squad of his: moved as the stock does (force_change_position)")
do
	local W = stand()
	local H = W.H
	W.raw[300].online = false
	H.objects[201], H.env.db.storage[201] = nil, nil
	W.CA.bring_mine()
	pump()
	place(H, W.proxy_a, 1000)
	W.tick(300)
	check(W.raw[300].forced and math.abs(W.raw[300].forced.x - 1000) < 0.01, "the squad's server object goes to him")
end

print("== Fair Fast Travel's switch off: nobody is brought")
do
	local W = stand({ env = function(M) fft(M, false) end })
	local H, A = W.H, W.A
	W.tick(300)
	W.CA.bring_mine()
	check(#sent_named(A, "npc.comp_bring") == 0, "the client asks nothing")
	place(H, H.env.db.actor, 2000)
	H.env.game_fast_travel.bring_companions_to_actor()
	W.CH.bring_mine()
	check(at(W[221], 58), "the host's own squad stays")
	H.env.game_fast_travel.on = true
	W.CH.bring_mine()
	check(at(W[221], 2000), "switched on again: it comes")
end

print("== outside a session, and before the start: nothing")
do
	reset_world()
	local S = machine("single", 0, { [0] = 0 })
	local W = { squads = {} }
	if not S.env.coop_mode then
		modes.live(load_script(S, "coop_mode"), function(name) return load_script(S, name) end)
	end
	if not S.env.coop_trust then load_script(S, "coop_trust") end
	S.env.coop_npc_players = load_script(S, "coop_npc_players")
	stock(S, W)
	lv_env(S)
	local C = load_script(S, "coop_npc_companions")
	check(pcall(C.bring_mine), "before on_game_start: no error")
	C.on_game_start()
	check(pcall(C.bring_mine) and #S.sent == 0, "single player: no error, nothing sent")
end

print("== split levels: the map server of his level brings it, the world server only passes the word on")
do
	reset_world()
	LV, LVN = {}, 0
	local BRIDGE = 0x101
	local W = { squads = {}, raw = {} }
	local level_of = { [0] = 1, [1] = 1, [2] = 2 }
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local Mk = machine("client", BRIDGE, { [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	Mk.env.coop.is_map_server = function() return true end
	H.env.coop.is_dedicated = function() return true end -- the engine splits the levels of a -coop_dedicated world only
	Mk.env.coop.is_mirror = function() return false end
	Mk.env.level.name = function() return NAMES[2] end
	for _, M in ipairs({ H, Mk, B }) do
		if not M.env.coop_mode then
			modes.live(load_script(M, "coop_mode"), function(name) return load_script(M, name) end)
		end
		if not M.env.coop_trust then load_script(M, "coop_trust") end
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W)
		lv_env(M)
		M.env.coop.levels = {
			split = function() return true end,
			level_of_player = function(p) return level_of[p] end,
			level_name = function(id) return NAMES[id] end,
			bridge_of_player = function(p) if M == H and level_of[p] == 2 then return BRIDGE end return nil end,
			online_at_server = function() return false end,
			map_servers = function() return M == H and { { bridge = BRIDGE, level = 2 } } or {} end,
		}
	end
	local proxy_b = Mk.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	place(Mk, proxy_b, 6)
	W.squads[400], W.raw[400] = new_squad(400, 20, 301)
	local m301 = npc(Mk, 301, 50)
	m301:give_info_portion("npcx_is_companion")
	local CH, CM, CB = load_script(H, "coop_npc_companions"), load_script(Mk, "coop_npc_companions"), load_script(B, "coop_npc_companions")
	CH.on_game_start()
	CM.on_game_start()
	CB.on_game_start()
	Mk.env.axr_companions.companion_squads[400] = W.squads[400]
	CM._leaders()[400] = 501
	local function tick(ms)
		NOW = NOW + (ms or 300)
		for _, M in ipairs({ H, Mk, B }) do
			M.env.coop_npc_players.invalidate()
			M.fire("actor_on_update")
		end
		pump()
	end
	tick(3000)
	place(B, B.env.db.actor, 900)
	CB.bring_mine()
	pump()
	local relayed = sent_named(H, "npc.comp_bring")
	check(#relayed == 1 and relayed[1].target == BRIDGE, "the world server passes the word to the map server of his level")
	check(count(CH._bring_wait()) == 0, "and keeps nothing of it")
	check(count(CM._bring_wait()) == 1, "the map server took it, for him (the peer the world server stamped)")
	tick(300)
	check(at(m301, 50), "the map server waits for its view of him")
	place(Mk, proxy_b, 900)
	tick(300)
	check(at(m301, 900), "then brings his squad on its level")
	check(H.teleported == nil and Mk.teleported == nil, "no ALife teleport anywhere")
	check(CM._leaders()[400] == 501, "the squad stays his")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
