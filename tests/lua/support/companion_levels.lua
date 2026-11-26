-- Companions in Server: the world service actor, map servers on Cordon and Garbage, and two players (peers 1 and 2).
-- In Co-op, the host plays on the same map as the clients. The authority for the map decides who controls a squad.
-- Shared fixtures for the co-op and server companion-level tests.
dofile("tests/lua/support/harness_npc.lua")
dofile("tests/lua/support/luabind_like.lua")
local modes = dofile("tests/lua/support/modes.lua")

local BRIDGE, CORDON = 0x101, 0x102
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

-- Server starts the players on separate maps. Co-op runs the nearby and host-player cases.
local function stand(opts)
	assert(opts.dedicated == true or opts.split == false)
	reset_world()
	local W = { bodies = {}, squads = {}, tables = {}, level_of = { [1] = 1, [2] = opts.dedicated and 2 or 1 },
		split = opts.split ~= false, online = {}, not_yet = {} }
	local host_avatars = { [1] = 500, [2] = 501 }
	if not opts.dedicated then W.level_of[0], host_avatars[0] = 1, 0 end
	local H = machine("host", 0, host_avatars)
	if opts.dedicated then
		H.env.coop.is_dedicated = function() return true end
		H.env.level.name = function() return "fake_start" end
	end
	local mk_avatars = opts.mk_knows_all and { [1] = 500, [2] = 501 } or { [2] = 501 }
	local Mk = opts.dedicated and machine("client", BRIDGE, mk_avatars) or nil
	local cordon_avatars = { [1] = 500 }
	local K = opts.dedicated and machine("client", CORDON, cordon_avatars) or nil
	W.K = K
	local a_avatars, b_avatars = { [1] = 0, [2] = 501 }, { [1] = 500, [2] = 0 }
	if not opts.dedicated then a_avatars[0], b_avatars[0] = 500, 501 end
	local A = machine("client", 1, a_avatars)
	local B = machine("client", 2, b_avatars)
	A.to_host, A.to_local = swap(0, 500), swap(0, 500)
	B.to_host, B.to_local = swap(0, 501), swap(0, 501)
	W.H, W.Mk, W.A, W.B = H, Mk, A, B
	W.mk_avatars = mk_avatars
	-- The world server's AvatarList: who plays each character in the world. A map server is a client of the world and takes it
	-- (coop_join.cpp send_owners -> to_bridges, bridge_takes(AvatarList); client_on_avatar_list -> world::client_set_owners), so its
	-- coop.peer_of_avatar knows the players of every level, while its own session (coop.players) lists only the players of its
	-- level. A player who left the world is in no row: a test removes him here.
	W.owners = { [1] = 500, [2] = 501 }
	local function world_owner(id)
		for p, av in pairs(W.owners) do
			if av == id then return p end
		end
		return nil
	end
	-- The tunnel delivers map-server replies to players with the world server as sender.
	local function map_server(M, level_id)
		M.env.coop.is_map_server = function() return true end
		M.env.coop.is_mirror = function() return false end
		M.env.coop.peer_of_avatar = world_owner
		M.env.level.name = function() return NAMES[level_id] end
		local send = M.env.coop.send_event
		M.env.coop.send_event = function(name, payload, target)
			if type(target) == "number" and target > 0 and target < 0x100 then
				M.sent[#M.sent + 1] = { name = name, payload = payload, target = target }
				QUEUE[#QUEUE + 1] = { from = 0, name = name, payload = payload, target = target }
				return true
			end
			return send(name, payload, target)
		end
	end
	if K then
		map_server(K, 1)
		map_server(Mk, 2)
	end
	local function levels_for(M)
		return {
			split = function() return W.split end,
			level_of_player = function(peer) return W.split and W.level_of[peer] or 1 end,
			level_name = function(id) return NAMES[id] end,
			my_level = opts.dedicated and function()
				if M == H then return 3 end
				if M == Mk then return 2 end
				if M == K then return 1 end
				return W.level_of[M.peer]
			end or nil,
			bridge_of_player = function(peer)
				if M == H and W.split then
					if W.level_of[peer] == 2 then return BRIDGE end
					if K and W.level_of[peer] == 1 then return CORDON end
				end
				return nil
			end,
			online_at_server = function(id) return W.online[id] == true end,
			map_servers = function()
				local list = {}
				if M == H and W.split then
					if not W.no_server then list[1] = { bridge = BRIDGE, level = 2 } end
					if K and not W.no_cordon then list[#list + 1] = { bridge = CORDON, level = 1 } end
				end
				return list
			end,
		}
	end
	local machines = { H, A, B }
	if K then
		machines[#machines + 1] = K
		machines[#machines + 1] = Mk
	end
	for _, M in ipairs(machines) do
		M.env.coop_npc_players = load_script(M, "coop_npc_players")
		stock(M, W)
		M.env.coop.levels = levels_for(M)
		-- Capture the registrations so the save/share cases can drive the up and down messages.
		M.share = { up = {}, down = {} }
		M.env.coop_quests_core = {
			share_up = function(name, get, set) M.share.up[name] = { get = get, set = set } end,
			share_down = function(name, get, set) M.share.down[name] = { get = get, set = set } end,
		}
		local players = M.env.coop.players
		M.env.coop.players = function()
			local list = players()
			for _, p in ipairs(list) do
				p.level = W.level_of[p.id]
				p.elsewhere = W.split and not p.is_self and M ~= H and M ~= Mk and M ~= K and p.level ~= W.level_of[M.peer] or nil
				if p.elsewhere and opts.far_no_avatar then p.avatar_id = nil end
			end
			return list
		end
		if opts.env then opts.env(M) end
	end
	W.proxy_a = make_obj(500, 5, 0, 0, { _name = "proxy_a" })
	if opts.dedicated then
		W.bodies[500] = { id = 500, position = vec(5, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = 10 }
		W.bodies[501] = { id = 501, position = vec(6, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = 20 }
		K.add(W.proxy_a)
	else
		H.add(W.proxy_a)
	end
	local garbage = Mk or H
	W.proxy_b = garbage.add(make_obj(501, 6, 0, 0, { _name = "proxy_b" }))
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
	local cordon = K or H
	W.comp = cordon.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	W.comp_a = A.add(make_obj(201, 7, 0, 0, { _name = "comp" }))
	if Mk then W.comp2 = Mk.add(make_obj(301, 7, 0, 0, { _name = "comp2" })) end
	W.comp2_b = B.add(make_obj(301, 7, 0, 0, { _name = "comp2" }))
	for _, M in ipairs(machines) do
		load_script(M, "coop_trust")
		local mode = load_script(M, "coop_mode")
		mode.on_game_start()
		load_script(M, "coop_npc_companions").on_game_start()
		load_script(M, "coop_srv_companions").on_game_start()
		modes.live(mode, function(name) return load_script(M, name) end)
	end
	W.CH = H.env.coop_npc_companions
	W.CA, W.CB = A.env.coop_npc_companions, B.env.coop_npc_companions
	if K then W.CK, W.CM = K.env.coop_npc_companions, Mk.env.coop_npc_companions end
	W.comp:give_info_portion("npcx_is_companion")
	cordon.env.axr_companions.companion_squads[300] = W.squads[300]
	if Mk then
		W.comp2:give_info_portion("npcx_is_companion")
		Mk.env.axr_companions.companion_squads[400] = W.squads[400]
	end
	function W.refresh()
		NOW = NOW + 3000
		for _, M in ipairs(machines) do
			M.env.coop_npc_players.invalidate()
			M.fire("actor_on_update")
		end
		pump()
	end
	-- a player moves: the engine's table says so, the character leaves one process and comes to the other, the session of the map server
	-- loses him or gets him (coop_trunk server_on_map: virtual_leave, virtual_join)
	function W.move(peer, level)
		assert(K and Mk, "only a Server player can move between independent maps")
		W.level_of[peer] = level
		local id = PROXY[peer]
		W.mk_avatars[peer] = level == 2 and id or nil
		local obj = cordon.objects[id] or Mk.objects[id]
		cordon.objects[id], Mk.objects[id] = nil, nil
		cordon_avatars[peer] = level == 1 and id or nil
		local M = level == 1 and cordon or Mk
		if obj then M.objects[id] = obj end
		W.bodies[id] = { position = vec(1, 0, 0), m_level_vertex_id = 7, m_game_vertex_id = level == 1 and 10 or 20, id = id }
		-- the engine's player list changes between frames: the next frame reads it (coop_util.players keeps one per frame)
		NOW = NOW + 1
		for _, each in ipairs(machines) do each.env.coop_npc_players.invalidate() end
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

return { stand = stand, logic_env = logic_env, last = last, ask = ask, BRIDGE = BRIDGE, CORDON = CORDON }
