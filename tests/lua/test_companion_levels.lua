-- Companions and split levels (docs\SPLIT_LEVELS.md 7a): a stand of the world server on l01_escape (peer 0), a map server of l02_garbage
-- (bridge 0x101) and two clients (peers 1, 2; proxies 500, 501). The owner's rule: control passes only between players of one level, and
-- the machine that leads the level decides, by the engine's table of who stands where (coop.levels.level_of_player).
-- Run: tools\test_lua.cmd companion_levels
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")

local BRIDGE = 0x101
local PROXY = { [1] = 500, [2] = 501 }
local LEVEL_OF_VERTEX = { [10] = 1, [20] = 2 }
local NAMES = { [1] = "l01_escape", [2] = "l02_garbage" }

local function swap(a, b)
	return function(id)
		if id == a then return b end
		if id == b then return a end
		return id
	end
end

local function new_squad(id, vertex, ...)
	local t = { id = id, members = { ... }, m_game_vertex_id = vertex }
	function t.squad_members(self)
		local i = 0
		return function() i = i + 1; local m = t.members[i]; if m then return { id = m } end end
	end
	function t.commander_id() return t.members[1] end
	return luabind_object(t)
end

local function stock(M, W)
	local E = M.env
	E.actor_menu = { set_msg = function(_, text) M.msgs = M.msgs or {}; M.msgs[#M.msgs + 1] = text end }
	E.game.translate_string = function(s)
		if s == "st_coop_comp_gave_you" or s == "st_coop_comp_took_from_you" or s == "st_coop_comp_you_gave" then return s .. " %s %s" end
		return s .. " %s"
	end
	E.axr_task_manager = { hostages_by_id = {} }
	E.EDDListType = { iActorBag = 1, iDeadBodyBag = 2 }
	E.key_bindings = { kCUSTOM3 = 33 }
	E.dik_to_bind = function(d) return d end
	E.dialogs = { who_is_npc = function(a, b) return a:id() == 0 and b or a end }
	E.CALifeSmartTerrainTask = function(gv, lv) return { gv = gv, lv = lv } end
	E.alife_object = function(id)
		if M == W.Mk and W.not_yet[id] then return nil end
		return W.bodies[id] or W.squads[id] or M.objects[id]
	end
	E.get_object_squad = function(o)
		for _, sq in pairs(W.squads) do
			for k in sq:squad_members() do if k.id == o:id() then return sq end end
		end
	end
	E.alife = function()
		return { level_name = function(_, id) return NAMES[id] end }
	end
	E.game_graph = function()
		return { vertex = function(_, gv) return { level_id = function() return LEVEL_OF_VERTEX[gv] end } end }
	end
	M.se = {}
	E.se_save_var = function(id, name, var, value) M.se[id] = M.se[id] or {}; M.se[id][var] = value end
	E.se_load_var = function(id, name, var) return M.se[id] and M.se[id][var] end
	local ac = { companion_squads = {}, assigned = {}, logic = {} }
	E.axr_companions = ac
	function ac.setup_companion_logic(npc, st, loaded, cannot_dismiss)
		ac.logic[npc:id()] = { cannot_dismiss = cannot_dismiss }
		npc:give_info_portion("npcx_is_companion")
	end
	function ac.companion_squad_can_teleport(squad)
		return not E.se_load_var(squad:commander_id(), nil, "companion_cannot_teleport")
	end
	function ac.get_inventory_table() return {} end
	function ac.dismiss_special_squad(squad)
		if ac.companion_squads[squad.id] == nil then return end
		for k in squad:squad_members() do -- utils_obj.execute_script_on_squad: only a member online here loses the marks
			if M.objects[k.id] then M.se[k.id] = nil end
		end
		ac.companion_squads[squad.id] = nil
		M.dismissed = squad.id
	end
	function ac.list_actor_squad_by_id()
		local t = {}
		for id in pairs(ac.companion_squads) do t[#t + 1] = id end
		table.sort(t)
		return t
	end
	E.dialogs_axr_companion = {
		is_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") end,
		is_not_actor_companion = function(actor, npc) return npc:has_info("npcx_is_companion") ~= true end,
		dm_init_is_actor_companion = function(dialog) dialog:AddPhrase("stock", "1", "0", -10000) end,
		become_actor_companion = function(actor, npc)
			local sq = E.get_object_squad(npc)
			ac.companion_squads[sq.id] = sq
			npc:give_info_portion("npcx_is_companion")
		end,
		remove_companions_from_squad = function(actor, npc)
			ac.companion_squads[E.get_object_squad(npc).id] = nil
			npc:disable_info_portion("npcx_is_companion")
		end,
	}
	E.axr_beh = { action_beh = { execute = function(self) M.beh_actor = E.db.actor:id() end } }
	E.sim_squad_scripted = { sim_squad_scripted = { get_current_task = function(self) return "stock task" end } }
	E.TeleportSquad = function(squad, pos, lvid, gvid)
		M.teleported = { id = squad.id, pos = pos, lvid = lvid, gvid = gvid }
		local t = W.tables[squad.id]
		if t and not W.stale_place then t.m_game_vertex_id = gvid end
	end
end

-- The stand: A next to the host on l01_escape, B on l02_garbage under its map server. opts.split = false: split levels off.
local function stand(opts)
	opts = opts or {}
	reset_world()
	local W = { bodies = {}, squads = {}, tables = {}, level_of = { [0] = 1, [1] = 1, [2] = 2 }, split = opts.split ~= false, online = {},
		not_yet = {} }
	local H = machine("host", 0, { [0] = 0, [1] = 500, [2] = 501 })
	local mk_avatars = opts.mk_knows_all and { [1] = 500, [2] = 501 } or { [2] = 501 }
	local Mk = machine("client", BRIDGE, mk_avatars)
	local A = machine("client", 1, { [0] = 500, [1] = 0, [2] = 501 })
	local B = machine("client", 2, { [0] = 501, [1] = 500, [2] = 0 })
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	W.H, W.Mk, W.A, W.B = H, Mk, A, B
	W.mk_avatars = mk_avatars
	Mk.env.coop.is_map_server = function() return true end
	Mk.env.coop.is_mirror = function() return false end
	Mk.env.level.name = function() return NAMES[2] end
	-- what a map server says to a player of its level comes down the tunnel: the client hears the world server
	local send = Mk.env.coop.send_event
	Mk.env.coop.send_event = function(name, payload, target)
		if type(target) == "number" and target > 0 and target < 0x100 then
			Mk.sent[#Mk.sent + 1] = { name = name, payload = payload, target = target }
			QUEUE[#QUEUE + 1] = { from = 0, name = name, payload = payload, target = target }
			return true
		end
		return send(name, payload, target)
	end
	local function levels_for(M)
		return {
			split = function() return W.split end,
			level_of_player = function(peer) return W.split and W.level_of[peer] or 1 end,
			level_name = function(id) return NAMES[id] end,
			bridge_of_player = function(peer)
				if M == H and W.split and W.level_of[peer] == 2 then return BRIDGE end
				return nil
			end,
			online_at_server = function(id) return W.online[id] == true end,
			map_servers = function()
				return M == H and W.split and not W.no_server and { { bridge = BRIDGE, level = 2 } } or {}
			end,
		}
	end
	for _, M in ipairs({ H, Mk, A, B }) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W)
		M.env.coop.levels = levels_for(M)
		local players = M.env.coop.players
		M.env.coop.players = function()
			local list = players()
			for _, p in ipairs(list) do
				p.level = W.level_of[p.id]
				p.elsewhere = W.split and not p.is_self and M ~= H and M ~= Mk and p.level ~= W.level_of[M.peer] or nil
				if p.elsewhere and opts.far_no_avatar then p.avatar_id = nil end
			end
			return list
		end
		if opts.env then opts.env(M) end
	end
	W.proxy_a = H.add(make_obj(500, 5, 0, 0, { _name = "proxy_a" }))
	W.proxy_b = Mk.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
	A.add(make_obj(500, 0, 0, 0, { _name = "host_avatar" }))
	B.add(make_obj(501, 0, 0, 0, { _name = "ms_avatar" }))
	-- squad 300 (member 201) next to the host and A; squad 400 (member 301) next to B
	function W.squad(id, vertex, member)
		local t = { id = id, members = { member }, m_game_vertex_id = vertex }
		function t.squad_members(self)
			local i = 0
			return function() i = i + 1; local m = t.members[i]; if m then return { id = m, object = W.bodies[m] } end end
		end
		function t.commander_id() return t.members[1] end
		W.tables[id] = t
		W.squads[id] = luabind_object(t)
		return W.squads[id]
	end
	W.squad(300, 10, 201)
	W.squad(400, 20, 301)
	W.comp = H.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp_a = A.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp2 = Mk.add(make_obj(301, 7, 0, 0, { _name = "comp2" }))
	W.comp2_b = B.add(make_obj(301, 7, 0, 0, { _name = "comp2" }))
	W.CH = load_script(H, "coop_npc_companions")
	W.CM = load_script(Mk, "coop_npc_companions")
	W.CA = load_script(A, "coop_npc_companions")
	W.CB = load_script(B, "coop_npc_companions")
	W.CH.on_game_start()
	W.CM.on_game_start()
	W.CA.on_game_start()
	W.CB.on_game_start()
	W.comp:give_info_portion("npcx_is_companion")
	W.comp2:give_info_portion("npcx_is_companion")
	H.env.axr_companions.companion_squads[300] = W.squads[300]
	Mk.env.axr_companions.companion_squads[400] = W.squads[400]
	function W.refresh()
		NOW = NOW + 3000
		for _, M in ipairs({ H, Mk, A, B }) do
			M.env.coop_npc_players.invalidate()
			M.fire("actor_on_update")
		end
		pump()
	end
	-- a player moves: the engine's table says so, the character leaves one process and comes to the other, the session of the map server
	-- loses him or gets him (coop_trunk server_on_map: virtual_leave, virtual_join)
	function W.move(peer, level)
		W.level_of[peer] = level
		local id = PROXY[peer]
		W.mk_avatars[peer] = level == 2 and id or nil
		local obj = H.objects[id] or Mk.objects[id]
		H.objects[id], Mk.objects[id] = nil, nil
		local M = level == 1 and H or Mk
		if obj then M.objects[id] = obj end
		W.bodies[id] = { position = vec(1, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = level == 1 and 10 or 20, id = id }
		for _, each in ipairs({ H, Mk, A, B }) do each.env.coop_npc_players.invalidate() end
	end
	W.refresh()
	return W
end

-- The stock's xr_logic, as far as a condlist goes: { section, { checks }, { effects } }, kinds 1 + 2 - 3 = functor, [3] of an info: an NPC's.
local function logic_env(M)
	local E = M.env
	E.modules = { stype_restrictor = 4 }
	E.utils_obj = { npc_in_zone = function() return false end }
	local xl = {}
	E.xr_logic = xl
	function xl.pick_section_from_condlist(obj, npc, condlist)
		local actor = E.db.actor
		M.picked_as = obj and obj:id()
		for _, cond in ipairs(condlist or {}) do
			local met = true
			for _, c in ipairs(cond[2] or {}) do
				local who = c[3] and npc or actor
				if c[2] == 1 then met = who:has_info(c[1])
				elseif c[2] == 2 then met = not who:has_info(c[1])
				elseif c[2] == 3 then met = E.xr_conditions[c[1]](obj, npc, c[3])
				end
				if not met then break end
			end
			if met then
				for _, s in ipairs(cond[3] or {}) do
					local who = s[3] and npc or actor
					if s[2] == 1 then who:give_info_portion(s[1])
					elseif s[2] == 2 then who:disable_info_portion(s[1])
					else E.xr_effects[s[1]](obj, npc, s[3])
					end
				end
				return cond[1] or ""
			end
		end
		return nil
	end
	function xl.switch_to_section(npc, ini, section)
		if section == "" or section == nil then return false end
		M.section = section
		return true
	end
	function xl.try_switch_to_another_section(npc, st, actor)
		M.switch_as, M.stock_try = E.db.actor:id(), (M.stock_try or 0) + 1
		for _, c in ipairs(st.logic or {}) do
			if xl.switch_to_section(npc, st.ini, xl.pick_section_from_condlist(actor, npc, c.condlist)) then return true end
		end
		return false
	end
	function xl.determine_section_to_activate() return "nil" end
	function xl.initialize_obj() end
	function xl.save_obj() end
	E.xr_conditions = {
		dist_to_actor_le = function(actor, npc, p) return npc:position():distance_to_sqr(actor:position()) <= p[1] ^ 2 end,
		dist_to_actor_ge = function(actor, npc, p) return npc:position():distance_to_sqr(actor:position()) >= p[1] ^ 2 end,
		dist_to_task_target_anomaly_le = function(actor, npc, p) return E.load_var(E.db.actor, "task_target_anomaly") ~= nil end,
	}
	E.xr_effects = { force_talk = function(actor, npc, p) M.stock_talk = E.db.actor:id() end }
end

local function last(M) return M.msgs and M.msgs[#M.msgs] or "" end
local function ask(M, t)
	M.env.coop_npc_players.send("npc.comp_lead", t, 0)
	pump()
end

print("== hand over: refused for a player on another level, the host decides by its table")
do
	local W = stand({ far_no_avatar = true })
	local H, A, B = W.H, W.A, W.B
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	check(W.CA.dlg_can_hand(A.env.db.actor, W.comp_a) == true, "the leader is offered the hand-over")
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "1" }) == "p0", "a player of his level: the nick")
	local text = W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	check(text:find("st_coop_comp_refused_elsewhere", 1, true) and text:find("p2", 1, true),
		"a player of another level stays in the list and says so: " .. text)
	check(W.CA.dlg_slot(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == true, "his line stays in the list")
	A.msgs = nil
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 500, "the host keeps the leader")
	check(last(A):find("st_coop_comp_refused_elsewhere", 1, true) and last(A):find("p2", 1, true), "the asker hears who and why: " .. last(A))
	check(W.CH._stats().lead_refused == 1, "the refusal is counted (coop_status)")
	NOW = NOW + 3001
	ask(A, { a = "give", i = 201, to = 2 })
	check(L()[300] == 500, "a client that skips its window gets the same answer: the host decides")

	W.move(2, 1)
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 501, "the same player on the same level: the hand-over goes through")
	check(last(B):find("st_coop_comp_gave_you", 1, true) ~= nil, "the new leader is told")
end

print("== hand over on a map server's level, to the host who is not there")
do
	local W = stand()
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 501
	W.refresh()
	check(W.CB.dlg_slot_text(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" }):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil,
		"the host stands elsewhere: the line says so")
	B.msgs = nil
	W.CB.dlg_hand(B.env.db.actor, W.comp2_b, "d", "p", "", { "1" })
	pump()
	check(L()[400] == 501, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p0", 1, true), "he hears who: " .. last(B))
end

print("== take: not from a leader who stands on another level")
do
	local W = stand({ mk_knows_all = true })
	local Mk, B = W.Mk, W.B
	local L = W.CM._leaders
	L()[400] = 500 -- A leads it from l01_escape: it could not follow him
	Mk.se[301] = { companion_cannot_teleport = true }
	W.refresh()
	B.msgs = nil
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 500, "the map server keeps the leader")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p1", 1, true), "he hears who: " .. last(B))
	W.level_of[1] = 2
	Mk.add(W.proxy_a)
	W.H.objects[500] = nil
	W.proxy_a._pos = vec(5, 0, 0)
	W.refresh()
	NOW = NOW + 3001
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "on one level he takes it")
	check(Mk.msgs == nil, "a map server has nobody of its own to tell")
end

print("== take: the host hears it too: a leader on another level is no squad of his own")
do
	local W = stand()
	local H = W.H
	local L = W.CH._leaders
	L()[300] = 501 -- B leads it from l02_garbage: his character is on no level of this process, the squad could not follow him
	H.se[201] = { companion_cannot_teleport = true }
	W.refresh()
	H.msgs = nil
	W.CH.dlg_take(H.env.db.actor, W.comp)
	pump()
	check(L()[300] == 501, "the host's process keeps the leader")
	check(last(H):find("st_coop_comp_refused_elsewhere", 1, true) and last(H):find("p2", 1, true), "he hears who: " .. last(H))
end

print("== take: not a squad of the host's that stayed behind while he stands on another level")
do
	local W = stand()
	local B = W.B
	local L = W.CM._leaders
	check(L()[400] == nil, "no entry: the host's own")
	B.msgs = nil
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == nil, "the map server gives it to nobody")
	check(last(B):find("st_coop_comp_refused_elsewhere", 1, true) and last(B):find("p0", 1, true), "he hears who: " .. last(B))
end

print("== take: a leader who left the game is no reason to wait")
do
	local W = stand()
	local B = W.B
	local L = W.CM._leaders
	L()[400] = 777 -- a character of nobody in the session
	W.refresh()
	W.CB.dlg_take(B.env.db.actor, W.comp2_b)
	pump()
	check(L()[400] == 501, "it is his")
end

print("== a story NPC of a task: the same rule")
do
	local W = stand()
	local H, A = W.H, W.A
	local L = W.CH._leaders
	local taker = 1
	H.env.coop_tasks = { reward_peer = function() return taker end, giving_npc = function() return nil end }
	W.CH = load_script(H, "coop_npc_companions") -- the wrappers are put once: the module again, on its stock
	H.env.xr_effects = {
		setup_companion_task = function(actor, npc, p)
			W.squad(310, 10, 211)
			H.env.axr_companions.companion_squads[310] = W.squads[310]
		end,
	}
	H.callbacks = {}
	H.handlers = {}
	W.CH.on_game_start()
	L = W.CH._leaders
	W.story = H.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	W.story_a = A.add(make_obj(211, 7, 0, 0, { _name = "story" }))
	H.env.xr_effects.setup_companion_task(H.env.db.actor, nil, { "310", "esc_smart" })
	W.refresh()
	check(L()[310] == 500, "(the taker leads it)")
	W.CA.dlg_hand(A.env.db.actor, W.story_a, "d", "p", "", { "2" })
	pump()
	check(L()[310] == 500 and last(A):find("st_coop_comp_refused_elsewhere", 1, true) ~= nil, "not to a player of another level")
end

print("== split levels off: as before")
do
	local W = stand({ split = false })
	local H, A = W.H, W.A
	local L = W.CH._leaders
	L()[300] = 500
	W.move(2, 1)
	W.level_of[2] = 2 -- what it says is not read: there is one level for everybody
	W.proxy_b._pos = vec(6, 0, 0)
	W.refresh()
	check(W.CA.dlg_slot_text(A.env.db.actor, W.comp_a, "d", "p", "", { "2" }) == "p2", "the line is the nick")
	W.CA.dlg_hand(A.env.db.actor, W.comp_a, "d", "p", "", { "2" })
	pump()
	check(L()[300] == 501, "the hand-over goes through")
end

print("== the host's level change: a squad somebody else leads stays")
do
	local W = stand()
	local H = W.H
	local ac = H.env.axr_companions
	W.CH._leaders()[300] = 500
	W.squad(310, 10, 211)
	ac.companion_squads[310] = W.squads[310]
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "a squad a client leads does not go with the host")
	check(ac.companion_squad_can_teleport(W.squads[310]) == true, "his own does")
	H.se[211] = { companion_cannot_teleport = true }
	check(ac.companion_squad_can_teleport(W.squads[310]) == false, "the stock's rule stands for his own")
	H.se[211] = nil
	local asked = 0
	ac.companion_squad_can_teleport = function(squad) asked = asked + 1; return squad.id ~= 310 end -- Useful Idiots, loaded after us
	W.refresh()
	check(ac.companion_squad_can_teleport(W.squads[300]) == false, "over a patch that came later too")
	check(ac.companion_squad_can_teleport(W.squads[310]) == false and asked == 1, "the patch still decides for the host's own")
	W.split = false
	check(ac.companion_squad_can_teleport(W.squads[300]) == true and asked == 2, "split levels off: as before")
end

print("== a client leaves the host's level: his squad goes after him, the map server of his level takes it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp" }))
	H.objects[201] = nil
	W.move(1, 2)
	W.stale_place = true
	W.refresh()
	check(H.teleported and H.teleported.id == 300 and H.teleported.gvid == 20, "the world server teleports it to his body")
	check(L()[300] == nil and H.env.axr_companions.companion_squads[300] == nil, "it is no companion of this level any more")
	check(W.CM._leaders()[300] == 500 and Mk.env.axr_companions.companion_squads[300] == W.squads[300], "the map server takes it")
	check(Mk.env.axr_companions.logic[201] ~= nil, "with the logic of a companion")
	W.refresh()
	check(W.CM._leaders()[300] == 500, "its copy of the squad's place comes later: the map server does not take it for a stranger meanwhile")
end

print("== a squad that may not follow stays where it is, and keeps its leader")
do
	local W = stand()
	local H = W.H
	local L = W.CH._leaders
	L()[300] = 500
	W.refresh()
	H.se[201] = { companion_cannot_teleport = true } -- the Fanatic (dialogs_escape), a task's squad
	W.move(1, 2)
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "not teleported")
	check(L()[300] == 500 and H.env.axr_companions.companion_squads[300] ~= nil, "his entry stays, it is his when he comes back")
	check(W.CH.leader_of(W.comp) == nil, "meanwhile it acts for the host: no leader here")
	H.se[201] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 300, "the mark gone, it goes after him")
end

print("== a client leaves a map server's level: it lets the squad go, the world server takes it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	LM()[400] = 501
	W.refresh()
	W.online[301] = true
	W.proxy_b._alive = true
	W.move(2, 1)
	W.refresh()
	check(#Mk.env.coop.players() == 0, "(he was its only player: nobody is left in its session)")
	check(#sent_named(Mk, "npc.comp_follow") == 1, "the map server lets it go")
	check(LM()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "and keeps its owner until the world server takes it")
	check(H.teleported == nil, "the world server waits: a member is online at the map server")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "then teleports it to his body")
	check(W.CH._leaders()[400] == 501 and H.env.axr_companions.companion_squads[400] == W.squads[400], "the host's level takes it")
	check(LM()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "the map server forgets it then, no dismissal")
	check(Mk.dismissed == nil, "(no dismissal)")
end

print("== a map server nobody stands on, just loaded: it sorts the save's leaders out, once the map says the world is split")
do
	local W = stand()
	local Mk = W.Mk
	local LM = W.CM._leaders
	W.move(2, 1)
	W.refresh()
	Mk.env.coop.peer_of_avatar = function(id) return id == 500 and 1 or nil end -- A leads squad 300 on l01_escape: no squad to let go
	W.split = false -- no LevelMap yet: coop.levels.split() of a map server
	Mk.fire("load_state", { coop_npc_leaders = { [300] = 500 } })
	W.refresh()
	check(LM()[300] == 500, "(nothing is decided before the map came)")
	W.split = true
	W.refresh()
	check(LM()[300] == nil, "a squad of another level is not its own")
	check(#sent_named(Mk, "npc.comp_follow") == 0, "and it is not its to let go")
end

print("== a task's squad on a map server's level: the map server takes it, with the logic and the stock's marks")
do
	local TAKER
	local W = stand({ env = function(M)
		M.env.coop_tasks = { reward_peer = function() return TAKER end, giving_npc = function() return nil end }
		local ac = M.env.axr_companions
		-- the stock (axr_companions.add_special_squad): only a member this process holds as a live NPC gets the marks
		function ac.add_special_squad(squad, special, cannot_teleport)
			ac.companion_squads[squad.id] = squad
			for k in squad:squad_members() do
				if M.env.level.object_by_id(k.id) then
					M.se[k.id] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = cannot_teleport }
				end
			end
		end
		M.env.xr_effects = { add_task_companion = function(actor, npc, p)
			ac.add_special_squad(W_squads[p[1]], p[2] == "true", p[3] == "true")
		end }
	end })
	W_squads = W.squads
	local H, Mk = W.H, W.Mk
	local ac = Mk.env.axr_companions
	ac.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	W.not_yet[400] = true
	W.bodies[301] = { name = function() return "comp2" end }
	TAKER = 2
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 400, "false", "true" })
	TAKER = nil
	pump()
	check(ac.companion_squads[400] == nil, "the squad is not on the map server yet: nothing to take")
	W.not_yet[400] = nil
	W.refresh()
	check(W.CM._leaders()[400] == 501 and ac.companion_squads[400] == W.squads[400], "it comes: the map server takes it, its leader the taker")
	check(ac.logic[301] ~= nil and ac.logic[301].cannot_dismiss == true, "the logic of a companion: he does not go back to his own walker")
	check(Mk.se[301] and Mk.se[301].companion == true and Mk.se[301].companion_cannot_dismiss == true
		and Mk.se[301].companion_cannot_teleport == true, "the stock's marks: the binder reads them when he comes online")
	check(H.se[301] and H.se[301].companion_cannot_dismiss == true and H.se[301].companion_cannot_teleport == true,
		"the world server's record has them too: the next word (follow_home) and the save read them there")
	check(W.CH._leaders()[400] == nil, "the world server does not lead it")
	check(H.env.axr_companions.companion_squads[400] ~= nil, "its table keeps the squad: task scripts ask it")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "the save has the leader at once")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "it does not go with the host")
	check(#H.env.axr_companions.list_actor_squad_by_id() == 1, "the host's squad list and keys are not for it")
	W.refresh()
	check(H.teleported == nil and W.CM._leaders()[400] == 501, "with its leader on its level it stays")

	print("-- with no ban on teleports in the task's call")
	W.CM._leaders()[400] = nil
	ac.companion_squads[400] = nil
	H.env.axr_companions.companion_squads[400] = nil
	H.se[301], Mk.se[301] = nil, nil
	W.refresh()
	TAKER = 2
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 400 })
	TAKER = nil
	pump()
	check(Mk.se[301].companion_cannot_dismiss == true and not Mk.se[301].companion_cannot_teleport, "it is an escort, and it may follow")

	print("-- the world server has the NPC itself: the stock's marks stand")
	local H2 = H.env.axr_companions
	H2.companion_squads[300] = nil
	H.se[201] = nil
	TAKER = 1
	H.env.xr_effects.add_task_companion(H.env.db.actor, nil, { 300 })
	TAKER = nil
	check(H.se[201] and H.se[201].companion_cannot_dismiss == true, "(the stock wrote them)")
	check(W.CH._leaders()[300] == 500, "and its taker leads it")
end

print("== a companion a status functor writes into the stock table (tasks_agent_rescue): the taker leads it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local ac = H.env.axr_companions
	local before = W.CH.squads_now()
	ac.companion_squads[310] = W.squad(310, 10, 211)
	check(W.CH.claim_since(before, 1) == 1 and W.CH._leaders()[310] == 500, "a squad of this level: its taker is its leader")
	ac.companion_squads[311] = W.squad(311, 10, 212)
	W.CH._leaders()[311] = 501
	check(W.CH.claim_since(before, 1) == 0 and W.CH._leaders()[311] == 501, "a wrapper of the stock claimed it already: it stays")
	before = W.CH.squads_now()
	W.bodies[301] = { name = function() return "comp2" end }
	Mk.env.axr_companions.companion_squads[400] = nil
	ac.companion_squads[400] = W.squads[400]
	local sent = #sent_named(H, "npc.comp_adopt")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "a squad on a map server's level goes there")
	W.CH.claim_since(before, 2)
	check(#sent_named(H, "npc.comp_adopt") == sent + 1, "once")
	pump()
	check(W.CM._leaders()[400] == 501, "the map server leads it")
end

print("== a task lets go of a squad on a map server's level (Hidden Threat: the player left the station)")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local ac = H.env.axr_companions
	local before = W.CH.squads_now()
	Mk.env.axr_companions.companion_squads[400] = nil
	ac.companion_squads[400] = W.squads[400]
	W.CH.claim_since(before, 2)
	pump()
	check(W.CM._leaders()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "(the map server leads it)")
	ac.dismiss_special_squad(W.squads[400])
	pump()
	check(H.dismissed == 400, "the stock runs on the world server")
	check(Mk.dismissed == 400 and Mk.env.axr_companions.companion_squads[400] == nil, "and on the map server, where the NPC is")
	check(W.CM._leaders()[400] == nil, "it has no leader there")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "nor in the save")
	ac.companion_squads[300] = W.squads[300]
	H.dismissed, Mk.dismissed = nil, nil
	local sent = #sent_named(H, "npc.comp_drop")
	ac.dismiss_special_squad(W.squads[300])
	check(H.dismissed == 300 and #sent_named(H, "npc.comp_drop") == sent, "a squad of the host's level: stock alone")
end

print("== a task dismisses a squad that stayed behind offline: the stock leaves the marks, the dismissal stands all the same")
do
	local W = stand()
	local H = W.H
	local L = W.CH._leaders
	local cs = H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	H.objects[201] = nil
	W.bodies[201] = { name = function() return "comp" end }
	H.se[201] = { companion = true, companion_cannot_dismiss = true, companion_cannot_teleport = true }
	W.move(1, 2)
	W.refresh()
	check(L()[300] == 500 and H.teleported == nil, "(it stays with its leader's entry)")
	H.env.axr_companions.dismiss_special_squad(W.squads[300])
	check(H.dismissed == 300 and L()[300] == nil, "the entry goes with it")
	W.refresh()
	check(cs[300] == nil, "the refresh does not bring it back")
	check(not H.se[201].companion and not H.se[201].companion_cannot_dismiss and not H.se[201].companion_cannot_teleport,
		"the marks are gone: the binder and the next load do not make it a companion again")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "nor is it in the save")
end

print("== a task dismisses a squad that waits for its teleport: it does not arrive after that")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	W.CM._leaders()[400] = 501
	W.refresh()
	W.online[301] = true
	W.move(2, 1)
	W.refresh()
	check(H.teleported == nil, "(a member is still online at the map server)")
	H.env.axr_companions.companion_squads[400] = W.squads[400]
	H.env.axr_companions.dismiss_special_squad(W.squads[400])
	W.online[301] = nil
	W.refresh()
	check(H.teleported == nil and W.CH._leaders()[400] == nil, "no teleport, no leader")
end

print("== a member online when the map server takes the squad, a companion of it already")
do
	local W = stand()
	local Mk = W.Mk
	W.CH._leaders()[300] = 500
	W.refresh()
	Mk.add(make_obj(201, 1, 0, 0, { _name = "comp", _info = { npcx_is_companion = true } }))
	W.H.objects[201] = nil
	W.move(1, 2)
	W.refresh()
	check(Mk.env.axr_companions.logic[201] == nil, "no second setup: it would reset his orders")
end

print("== the leaders of a map server's level: into the save, onto a new map server")
do
	local function share_env(M)
		M.share = { up = {}, down = {} }
		M.env.coop_levels_share = {
			up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
	end
	local W = stand({ env = share_env })
	local H, Mk = W.H, W.Mk
	local up, down = "comp_leaders", "comp_leaders"
	check(Mk.share.up[up] ~= nil and H.share.down[down] ~= nil, "both tables are declared")
	local LM = W.CM._leaders
	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 501, "a leader on the map server reaches the save")
	check(H.env.axr_companions.companion_squad_can_teleport(W.squads[400]) == false, "the world server knows it for somebody's")
	Mk.fire("load_state", { coop_npc_leaders = { [300] = 500, [400] = 501 } })
	W.refresh()
	check(LM()[300] == nil, "a map server keeps only the squads of its level")
	local row = Mk.share.up[up].get()
	check(row.l[400] == 501 and row.l[300] == nil, "and reports those")
	LM()[400] = nil
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders == nil, "dismissed there: gone from the save")

	LM()[400] = 501
	H.share.up[up].set(Mk.share.up[up].get(), 2)
	LM()[400] = nil
	Mk.env.axr_companions.companion_squads[400] = nil
	W.comp2:disable_info_portion("npcx_is_companion")
	local given = H.share.down[down].get()
	Mk.share.down[down].set(given)
	check(LM()[400] == 501 and Mk.env.axr_companions.companion_squads[400] ~= nil, "a new map server gets the leaders of its level")
	check(Mk.env.axr_companions.logic[301] ~= nil, "and sets the logic up")
	LM()[400] = 500
	Mk.share.down[down].set(given)
	check(LM()[400] == 500, "the word counts once: what the map server changed since is newer")
end

print("== a level entered together: the squad stayed behind on a level nobody leads, its leader came with the host")
do
	local W = stand()
	W.no_server = true -- l02_garbage is what they left: no map server on it
	local H = W.H
	local cs = H.env.axr_companions.companion_squads
	cs[400] = false -- the stock's table of the save
	W.move(1, 1)
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "the world server teleports it to his body")
	check(W.CH._leaders()[400] == 500 and cs[400] == W.squads[400], "the level of arrival takes it, his leader keeps it")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader, once")
	W.refresh()
	check(W.CH._leaders()[400] == 500, "it stays his")
end

print("== left behind and forbidden to teleport: it stays with its leader's entry, and the save keeps it")
do
	local W = stand()
	W.no_server = true
	local H = W.H
	H.se[301] = { companion_cannot_teleport = true }
	W.move(1, 1)
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "not teleported")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader")
	H.se[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "the mark gone, it goes after him")
end

print("== left behind, its leader's character back in the list a moment after the world: it goes all the same")
do
	local W = stand()
	W.no_server = true
	local H = W.H
	local away = true
	W.move(1, 1)
	local players, peer_of = H.env.coop.players, H.env.coop.peer_of_avatar
	H.env.coop.players = function()
		local list = players()
		for _, p in ipairs(list) do
			if away and p.id == 1 then p.avatar_id = nil end
		end
		return list
	end
	H.env.coop.peer_of_avatar = function(id)
		if away and id == 500 then return nil end
		return peer_of(id)
	end
	H.fire("load_state", { coop_npc_leaders = { [400] = 500 } })
	W.refresh()
	check(H.teleported == nil, "nobody to go to yet")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[400] == 500, "the save has the leader meanwhile")
	away = false
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and W.CH._leaders()[400] == 500, "he is back: it goes")
end

print("== a save with leaders of every level: each process keeps its own")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local saved = { coop_npc_leaders = { [300] = 500, [400] = 501 } }
	H.fire("load_state", saved)
	Mk.fire("load_state", saved)
	W.refresh()
	check(W.CH._leaders()[300] == 500 and W.CH._leaders()[400] == nil, "the world server leads the squads of its level")
	check(W.CM._leaders()[400] == 501 and W.CM._leaders()[300] == nil, "the map server those of its own")
	check(H.teleported == nil, "nobody takes a squad on another level for one left behind")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[300] == 500 and m.coop_npc_leaders[400] == 501, "the next save has them all")
end

print("== a new map server says nothing of its leaders before it sorted the save's out: the word goes on its own timer")
do
	local function share_env(M)
		M.share = { up = {}, down = {} }
		M.env.coop_levels_share = {
			up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
	end
	local W = stand({ env = share_env })
	local H, Mk = W.H, W.Mk
	local saved = { coop_npc_leaders = { [300] = 500, [400] = 501 } }
	H.fire("load_state", saved)
	W.refresh()
	Mk.fire("load_state", saved)
	check(Mk.share.up.comp_leaders.get() == nil, "before the sort: nothing to tell, the leaders of every level are in its hands")
	W.refresh()
	local row = Mk.share.up.comp_leaders.get()
	check(row ~= nil and row.l[400] == 501 and row.l[300] == nil, "after it: those of its level")
	H.share.up.comp_leaders.set(row, 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders[300] == 500 and m.coop_npc_leaders[400] == 501, "the next save has them all")
end

print("== a map server just loaded: its squad's leader stands elsewhere and was never on it, the world server's word says who he is")
do
	local function share_env(M)
		M.share = { up = {}, down = {} }
		M.env.coop_levels_share = {
			up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
	end
	local W = stand({ env = share_env })
	local H, Mk = W.H, W.Mk
	W.move(1, 1)
	local saved = { coop_npc_leaders = { [400] = 500 } }
	H.fire("load_state", saved)
	Mk.fire("load_state", saved)
	W.refresh()
	check(W.CM._leaders()[400] == 500 and #sent_named(Mk, "npc.comp_follow") == 0, "(its session does not know him)")
	Mk.share.down.comp_leaders.set(H.share.down.comp_leaders.get())
	W.refresh()
	check(W.CM._leaders()[400] == 500 and #sent_named(Mk, "npc.comp_follow") == 1,
		"the map server lets it go, its owner kept until the world server takes it")
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and H.teleported.gvid == 10, "the world server teleports it to his body")
	check(W.CH._leaders()[400] == 500, "his level takes it")
	check(W.CM._leaders()[400] == nil, "the map server forgets it then")
end

print("== a squad recruited on a map server: the table of the save does not have it, the stock's mark does")
do
	local W = stand()
	local Mk = W.Mk
	local ac = Mk.env.axr_companions
	ac.companion_squads[400] = nil
	Mk.se[301] = { companion = true }
	Mk.fire("load_state", { coop_npc_leaders = { [400] = 501 } })
	W.refresh()
	check(W.CM._leaders()[400] == 501 and ac.companion_squads[400] == W.squads[400], "it keeps its leader and its place in the table")
	W.CM._leaders()[400] = 501
	ac.companion_squads[400] = nil
	Mk.se[301] = nil
	W.refresh()
	check(W.CM._leaders()[400] == nil, "no mark: a dismissed squad, the entry goes")
end

print("== a map server's companion with no living leader goes to the nearest player, not to the ghost")
do
	local W = stand({ mk_knows_all = true })
	local Mk = W.Mk
	W.refresh()
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 501, "no leader at all: the player of the level")
	W.CM._leaders()[400] = 500 -- a leader who is not here, a squad that may not go
	Mk.se[301] = { companion_cannot_teleport = true }
	W.refresh()
	Mk.beh_actor = nil
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 501, "a leader on another level: the same")
	check(W.CM.follows(W.comp2):id() == 501, "follows answers that player")
	local alone = Mk.add(make_obj(302, 7, 0, 0, { _name = "stranger" }))
	check(W.CM.follows(alone) == nil, "an NPC of no squad of the group: nobody")
	Mk.env.axr_beh.action_beh.execute({ object = alone })
	check(Mk.beh_actor == 0, "stock for it")
	W.proxy_b._alive = false
	Mk.env.coop_npc_players.invalidate()
	Mk.beh_actor = nil
	Mk.env.axr_beh.action_beh.execute({ object = W.comp2 })
	check(Mk.beh_actor == 0, "nobody alive on the level: nothing to go to, stock")
end

print("== the world server: a companion of the host stays the host's, a loaded one is no scripted enemy")
do
	local W = stand()
	local H = W.H
	W.refresh()
	check(W.CH.follows(W.comp) == nil, "the host's own: nobody to follow but him")
	H.env.db.actor._pos = vec(1000, 0, 0)
	H.env.coop_npc_players.invalidate()
	H.env.axr_companions.companion_squads[300] = false -- a loaded squad until its first update
	H.beh_actor = nil
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "actor" } })
	check(H.beh_actor == 0, "its target 'actor' is not the nearest player")
end

print("== task_target_anomaly reads the var of the actor: it runs without the leader's identity")
do
	local W = stand()
	local H = W.H
	W.CH._leaders()[300] = 500
	W.refresh()
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "task_target_anomaly" } })
	check(H.beh_actor == 0, "the target that reads the actor's var: no identity")
	H.env.axr_beh.action_beh.execute({ object = W.comp, st = { target = "actor" } })
	check(H.beh_actor == 500, "any other: its leader")
end

print("== the logic of a companion: 'the actor' is its leader, the infos of a condlist the world's")
do
	local W = stand({ env = logic_env })
	local H, Mk, A, B = W.H, W.Mk, W.A, W.B
	W.LH = load_script(H, "coop_npc_logic")
	W.LM = load_script(Mk, "coop_npc_logic")
	W.LH.on_game_start()
	W.LM.on_game_start()
	W.CH._leaders()[300] = 500
	W.refresh()
	local xl, xc = H.env.xr_logic, H.env.xr_conditions
	local seen
	xc.who = function(actor, npc) seen = { param = actor:id(), db = H.env.db.actor:id() }; return true end
	local function logic(condlist) return { ini = {}, logic = { { name = "on_info", condlist = condlist } } } end
	check(xl.try_switch_to_another_section(W.comp, logic({ { "beh@x", { { "who", 3 } } } }), H.env.db.actor) == true, "the stock switch runs")
	check(seen.param == 500 and seen.db == 500, "its functors get the leader, as parameter and as db.actor")
	check(H.switch_as == 500, "under his identity")
	check(H.env.db.actor:id() == 0, "the identity ends with it")
	local plain = H.add(make_obj(290, 7, 0, 0))
	seen = nil
	xl.try_switch_to_another_section(plain, logic({ { "x", { { "who", 3 } } } }), H.env.db.actor)
	check(seen.param == 0 and seen.db == 0, "an NPC of nobody: stock")

	H.env.db.actor:give_info_portion("world_flag")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@flag", { { "world_flag", 1 } } } }), H.env.db.actor)
	check(H.section == "beh@flag", "an info of the condlist is the world's: a proxy has none of them")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@no", { { "world_flag", 2 } } }, { "beh@second" } }), H.env.db.actor)
	check(H.section == "beh@second", "and its absence: the first line fails, the next one stands")
	W.comp:give_info_portion("npcx_x")
	H.section = nil
	xl.try_switch_to_another_section(W.comp, logic({ { "beh@own", { { "npcx_x", 1, 1 } } } }), H.env.db.actor)
	check(H.section == "beh@own", "an NPC's own flag stays his")

	-- beh_companion.ltx: on_info2 = {-force_started =dist_to_actor_le(3)} %+force_started =force_talk(true)%
	local talk = logic({ { "", { { "force_started", 2 }, { "dist_to_actor_le", 3, { 3 } } }, { { "force_started", 1 }, { "force_talk", 3, { "true" } } } } })
	W.proxy_a._pos = vec(100, 0, 0) -- far from it, the host next to it
	H.env.db.actor._pos = vec(6, 0, 0)
	H.env.coop_npc_players.invalidate()
	local talks = {}
	A.env.db.actor.run_talk_dialog = function(self, npc, brk) talks[#talks + 1] = { npc = npc:id(), brk = brk } end
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 0 and not H.env.db.actor:has_info("force_started"), "dist_to_actor is the leader's: the host next to it counts for nothing")
	check(xc.dist_to_actor_le(H.env.db.actor, W.comp, { 3 }) == true, "[meet] and the rest, outside the scope: the nearest player")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_actor_le, H.env.db.actor, W.comp, { 3 }) == false,
		"asked about the host's actor under the identity: the leader")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_actor_ge, H.env.db.actor, W.comp, { 3 }) == true, "the same for ge")
	W.proxy_a._pos = vec(5, 0, 0)
	H.env.coop_npc_players.invalidate()
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 1 and talks[1].npc == 201 and talks[1].brk == true, "force_talk: the leader's machine opens the talk")
	check(H.stock_talk == nil, "not the host's")
	check(H.env.db.actor:has_info("force_started") and not W.proxy_a:has_info("force_started"), "the latch is the world's info, the proxy has none")
	xl.try_switch_to_another_section(W.comp, talk, H.env.db.actor)
	pump()
	check(#talks == 1, "it latches: once")

	H.env.save_var(H.env.db.actor, "task_target_anomaly", "anomaly_1")
	check(H.env.coop_npc_players.with_identity(W.proxy_a, xc.dist_to_task_target_anomaly_le, W.proxy_a, W.comp, { 15 }) == true,
		"dist_to_task_target_anomaly reads the actor's var under the identity too: the switch to beh@task_target_anomaly stands")

	-- a map server: the same, the nearest player for a companion with no leader
	local xm = Mk.env.xr_logic
	local mtalk = logic({ { "", { { "dist_to_actor_le", 3, { 3 } } }, { { "force_talk", 3, { "false" } } } } })
	B.env.db.actor.run_talk_dialog = function(self, npc, brk) talks[#talks + 1] = { npc = npc:id(), brk = brk } end
	xm.try_switch_to_another_section(W.comp2, mtalk, Mk.env.db.actor)
	pump()
	check(#talks == 2 and talks[2].npc == 301 and talks[2].brk == false, "on a map server force_talk goes to the player it takes for its leader")
	check(Mk.stock_talk == nil, "the ghost talks to nobody")

	-- the host's own companion: stock
	W.CH._leaders()[300] = nil
	W.refresh()
	H.stock_talk = nil
	H.env.xr_effects.force_talk(H.env.db.actor, W.comp, { "true" })
	check(H.stock_talk == 0, "a companion of the host: stock")
end

print("== letting go: the menu's line is the leader's, a story's line anybody's, the story's next recruit gives him back")
do
	local W = stand()
	local H, A, B = W.H, W.A, W.B
	H.env.coop.talk_recent = function() return true end
	W.move(2, 1)
	W.proxy_b._pos = vec(6, 0, 0)
	W.comp_b = B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	local L, cs = W.CH._leaders, H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	local da, db_ = A.env.dialogs_axr_companion, B.env.dialogs_axr_companion
	B.msgs = nil
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "dm_companion_leave", "2")
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "dm_companion_leave of another player: refused")
	check(last(B):find("st_coop_comp_refused_not_yours", 1, true) ~= nil, "he hears why")
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_anomaly_reached", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "the story lets him go by any player's line")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "fanat_training_back_to_village", "1")
	pump()
	check(L()[300] == 500, "the next recruit gives him back to who took him, whoever said the line")

	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_stash_found", "1")
	pump()
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_last_leaders and m.coop_npc_last_leaders[300] == 500, "the save remembers who it was")
	H.fire("load_state", m)
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	check(L()[300] == 500, "and a load does not forget")

	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "dm_companion_leave", "2")
	pump()
	check(L()[300] == nil and cs[300] == nil, "the leader's own dm_companion_leave goes through")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "dm_recruit", "1")
	pump()
	check(L()[300] == 501, "he let him go himself: whoever hires him next leads him")

	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_anomaly_reached", "1")
	pump()
	W.move(2, 2)
	W.refresh()
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	check(L()[300] == 500, "who took him stands on another level: the one who recruits leads, the rule of one level")

	print("-- the host's own talk")
	local dh = H.env.dialogs_axr_companion
	W.move(2, 1)
	W.refresh()
	H.msgs = nil
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "dm_companion_leave", "2")
	check(L()[300] == 500 and cs[300] ~= nil, "his dm_companion_leave of a client's companion: refused")
	check(last(H):find("st_coop_comp_refused_not_yours", 1, true) ~= nil, "he hears why")
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "fanat_training_anomaly_reached", "1")
	check(cs[300] == nil, "a story's line goes through")
	W.refresh()
	check(L()[300] == nil, "(the refresh drops the entry)")
	dh.become_actor_companion(H.env.db.actor, W.comp, "x", "1")
	check(L()[300] == 500, "his recruit in the story gives him back too")
	dh.remove_companions_from_squad(H.env.db.actor, W.comp, "fanat_x", "1")
	W.refresh()
	check(next(L()) == nil, "(gone)")
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	W.CH._leaders()[300] = nil -- the host took him, the stock way
	W.refresh()
	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "fanat_x", "1")
	pump()
	check(cs[300] == nil, "a client's line lets the host's companion go")
	da.become_actor_companion(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	check(L()[300] == nil and cs[300] ~= nil, "and he comes back to the host: who took him")
end

print("== a story's line needs a talk, as a recruit does: a modified client names any dialog")
do
	local W = stand()
	local H, A, B = W.H, W.A, W.B
	local talked = false
	H.env.coop.talk_recent = function(peer, npc_id) return talked and peer == 2 and npc_id == 201 end
	W.move(2, 1)
	W.proxy_b._pos = vec(6, 0, 0)
	W.comp_b = B.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	local L, cs = W.CH._leaders, H.env.axr_companions.companion_squads
	L()[300] = 500
	W.refresh()
	local da, db_ = A.env.dialogs_axr_companion, B.env.dialogs_axr_companion
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "no talk with it: within 15 m he does not send away a companion of somebody else")
	check(W.CH._stats().refused_talk == 1, "the refusal is counted")
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b)
	pump()
	check(L()[300] == 500 and cs[300] ~= nil, "nor with no dialog named")
	talked = true
	db_.remove_companions_from_squad(B.env.db.actor, W.comp_b, "fanat_training_anomaly_reached", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "in a talk the story's line goes through")
	db_.become_actor_companion(B.env.db.actor, W.comp_b, "x", "1")
	pump()
	talked = false
	L()[300] = 500
	W.refresh()
	da.remove_companions_from_squad(A.env.db.actor, W.comp_a, "x", "1")
	pump()
	check(L()[300] == nil and cs[300] == nil, "its leader's own line asks for no talk")
end

print("== last leaders of a map server's level reach the save")
do
	local function share_env(M)
		M.share = { up = {}, down = {} }
		M.env.coop_levels_share = {
			up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
	end
	local W = stand({ env = share_env })
	local H, Mk, B = W.H, W.Mk, W.B
	W.CM._leaders()[400] = 501
	W.refresh()
	B.env.dialogs_axr_companion.remove_companions_from_squad(B.env.db.actor, W.comp2_b, "story_line", "1")
	pump()
	check(W.CM._leaders()[400] == nil, "the map server lets him go")
	H.share.up.comp_leaders.set(Mk.share.up.comp_leaders.get(), 2)
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_last_leaders and m.coop_npc_last_leaders[400] == 501, "the save has who it was")
end

print("== a client's own companions: the stock's list and Useful Idiots' answer from the authority's word, not the stock table")
do
	local NPCS = {}
	local function idiots(M)
		local NPC = {}
		function NPC.getCompanions() return {} end
		function NPC.getTargetCompanion() return nil end
		NPCS[M] = NPC
		M.env.package = { loaded = { ["illish.lib.npc"] = NPC } }
	end
	local W = stand({ env = idiots })
	local H, A, B = W.H, W.A, W.B
	W.CH._leaders()[300] = 500
	W.refresh()
	A.env.axr_companions.companion_squads[300] = false -- loaded: the stock's rebuild (squad_on_first_update) is the host's
	local list = A.env.axr_companions.list_actor_squad_by_id()
	check(#list == 1 and list[1] == 201, "his companion is in his list without aiming at it")
	check(#B.env.axr_companions.list_actor_squad_by_id() == 0, "not in the list of a friend")
	local own = NPCS[A].getCompanions()
	check(#own == 1 and own[1]:id() == 201, "Useful Idiots' wheel and keys see it")
	check(#NPCS[B].getCompanions() == 0, "and not a friend's")
	check(#A.env.axr_companions.companion_squads == 0 and A.env.axr_companions.companion_squads[300] == false,
		"the client writes nothing into the stock table")
	W.CH._leaders()[300] = nil
	H.env.axr_companions.companion_squads[300] = nil
	W.refresh()
	check(#A.env.axr_companions.list_actor_squad_by_id() == 0 and #NPCS[A].getCompanions() == 0, "dismissed: gone from his list")
end

print("== a client leaves a map server's level, a friend stays by his squad: the map server keeps the owner until the world server takes it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true -- B stands next to it: the engine keeps it online at the map server
	W.move(1, 1)
	W.refresh()
	W.refresh()
	check(H.teleported == nil, "(the world server waits: a member is online at the map server)")
	check(#sent_named(Mk, "npc.comp_follow") == 1, "the map server says it once")
	check(LM()[400] == 500 and Mk.env.axr_companions.companion_squads[400] ~= nil, "the map server keeps the owner meanwhile")
	local m = {}
	H.fire("save_state", m)
	check(m.coop_npc_leaders and m.coop_npc_leaders[400] == 500, "a save meanwhile keeps the owner")
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400, "offline: the world server teleports it to him")
	check(W.CH._leaders()[400] == 500, "his level takes it")
	check(LM()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "the map server lets it go then")
	check(Mk.dismissed == nil, "no dismissal on the way")
end

print("== the owner comes back before his squad left: it stays his on its level, the world server does not teleport it")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	W.move(1, 2)
	W.refresh()
	check(LM()[400] == 500, "the map server leads it again")
	W.online[301] = nil
	W.refresh()
	check(H.teleported == nil, "no teleport after all")
	check(W.CM.follows(W.comp2):id() == 500, "it follows him")
end

print("== a save with a squad on its way to its owner: after the load the way goes on")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	local LM = W.CM._leaders
	W.move(1, 2)
	LM()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	local m = {}
	H.fire("save_state", m)
	local saved = m.coop_npc_leaders
	check(saved and saved[400] == 500, "the save has its owner")
	H.fire("load_state", { coop_npc_leaders = saved })
	Mk.fire("load_state", { coop_npc_leaders = saved })
	W.refresh()
	W.online[301] = nil
	W.refresh()
	check(H.teleported and H.teleported.id == 400 and W.CH._leaders()[400] == 500, "it reaches its owner")
end

print("== a pending squad a task dismisses: the map server that still holds it lets it go too")
do
	local W = stand()
	local H, Mk = W.H, W.Mk
	W.move(1, 2)
	W.CM._leaders()[400] = 500
	W.refresh()
	W.online[301] = true
	W.move(1, 1)
	W.refresh()
	H.env.axr_companions.companion_squads[400] = W.squads[400]
	H.env.axr_companions.dismiss_special_squad(W.squads[400])
	pump()
	check(W.CM._leaders()[400] == nil and Mk.env.axr_companions.companion_squads[400] == nil, "gone there")
end

print("== the Fanatic (dialogs_escape): the stock marks him and sets the logic, no line of the table; a client said it: he is that client's")
do
	local function fanat(M)
		local E = M.env
		E.coop.talk_recent = function() return true end
		E.dialogs_escape = {
			set_esc_2_12_stalker_fanat_as_companion = function(a, b)
				local npc = E.dialogs.who_is_npc(a, b)
				local sq = E.get_object_squad(npc)
				for k in sq:squad_members() do
					E.se_save_var(k.id, nil, "companion", true)
					E.se_save_var(k.id, nil, "companion_cannot_dismiss", true)
					E.se_save_var(k.id, nil, "companion_cannot_teleport", true)
					E.axr_companions.setup_companion_logic(npc, nil, false, true)
				end
			end,
		}
	end
	local W = stand({ env = fanat })
	local H, A = W.H, W.A
	H.env.axr_companions.companion_squads[300] = nil
	W.comp:disable_info_portion("npcx_is_companion")
	W.refresh()
	A.env.dialogs_escape.set_esc_2_12_stalker_fanat_as_companion(A.env.db.actor, W.comp_a)
	pump()
	check(H.env.axr_companions.companion_squads[300] == W.squads[300], "a companion of the group, as the stock makes him on the next load")
	check(W.CH._leaders()[300] == 500, "led by the client who said it")
	W.refresh()
	check(W.CH.follows(W.comp):id() == 500, "he follows that client")
	local list = A.env.axr_companions.list_actor_squad_by_id()
	check(#list == 1 and list[1] == 201, "in that client's list")
end

print("== the host's own Fanatic: as before")
do
	local function fanat(M)
		local E = M.env
		E.dialogs_escape = {
			set_esc_2_12_stalker_fanat_as_companion = function(a, b)
				local npc = E.dialogs.who_is_npc(a, b)
				E.se_save_var(npc:id(), nil, "companion", true)
				E.axr_companions.setup_companion_logic(npc, nil, false, true)
			end,
		}
	end
	local W = stand({ env = fanat })
	local H = W.H
	H.env.axr_companions.companion_squads[300] = nil
	W.refresh()
	H.env.dialogs_escape.set_esc_2_12_stalker_fanat_as_companion(H.env.db.actor, W.comp)
	check(H.env.axr_companions.companion_squads[300] == nil and W.CH._leaders()[300] == nil, "the stock's own result")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
