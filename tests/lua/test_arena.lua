-- The Bar arena and the totalizator in a session (coop_arena): who goes in, whose gear moves where, what comes back.
-- A host (peer 0) and a client (peer 1, the host's proxy 500) share one world of items; the stock functions below follow
-- xr_effects.script (bar_arena_teleport, bar_arena_teleport_2, bar_arena_weapon_slot, teleport_for_totaliz_out) and
-- dialogs_mlr.script (teleport_for_totaliz) of Anomaly 1.5.3 line by line where items and positions are concerned.
-- Run: tools\test_lua.cmd arena
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local PROXY = 500
local BRIDGE = 0x101
-- coop_debug (coop_debug_server.debug_on): off unless a test turns it on
ARENA_DEBUG = false
coop_debug_server = { debug_on = function() return ARENA_DEBUG end }
local BOX1, BOX2, TRIG, MANAGER, COMMENT, TOTAL, OPPONENT, BODY = 900, 901, 910, 920, 911, 912, 300, 777
local SR, SPAM = 913, 914 -- Arnie's monster fight (the old arena): restrictors bar_arena_sr and bar_arena_spam
local THIRD = 501 -- a third player's character (group entry)
local AWAY = 502 -- a fourth player, on another map (split levels)
local ARENA = "l05_bar"
local IN_ARENA = vec(153, -19, 103) -- where the cutscene puts the fighter
local DOOR = vec(150, 0.4, 75) -- t_walk_2
local BET_SPOT_X, BET_OUT_X = 139.61517333984, 150.249435424805
local KITS = {
	[1] = { "novice_outfit", "wpn_pm", "ammo_9x18_pmm", "ammo_9x18_pmm" },
	[3] = { "stalker_outfit", "wpn_bm16", "ammo_12x70_buck", "ammo_12x70_buck" },
}

local W -- the world: items (host ids; a client sees the same ids, his own character swapped 0 <-> 500)
START_AS_IS = false
local H, Cm, HA, CA -- machines and their coop_arena

local function new_item(section, parent, by)
	W.next_id = W.next_id + 1
	local it = make_obj(W.next_id, 0, 0, 0, { _section = section, _parent = parent })
	function it:parent() return W.holders[self._parent] end
	W.items[it._id] = it
	H.objects[it._id] = it
	if Cm then Cm.objects[it._id] = it end
	W.created[#W.created + 1] = { section = section, parent = parent, by = by }
	return it
end

-- An object that holds items: host_id is whose items they are in the world (the client's own actor holds the proxy's).
local function holder(M, o, host_id)
	o._host_id = host_id
	if (host_id == PROXY or host_id == THIRD) and not M.mirror and not o._section then
		o._section = "coop_player_avatar"
		o._spawn_ini = make_ini({ coop = { { "key", string.format("%064x", host_id) } } })
	end
	function o:inventory_for_each(f)
		local list = {}
		for _, it in pairs(W.items) do if it._parent == host_id then list[#list + 1] = it end end
		table.sort(list, function(a, b) return a._id < b._id end)
		for _, it in ipairs(list) do f(it) end
	end
	function o:iterate_inventory(f) self:inventory_for_each(function(it) f(nil, it) end) end
	function o:iterate_inventory_box(f, arg) self:inventory_for_each(function(it) f(arg, it) end) end
	function o:transfer_item(item, to)
		if M.mirror then
			-- a client's own move is a request the host checks (reach, rate): the test counts it, the world does not change
			M.requests = (M.requests or 0) + 1
			return
		end
		W.moves = W.moves + 1
		-- a lagging client still sees the item where it was until the move reaches him
		if W.lagging and W.client_seen[item._id] == nil then W.client_seen[item._id] = item._parent end
		item._parent = to._host_id
	end
	function o:set_actor_direction() end
	function o:activate_slot(n) self._slot = n end
	if not M.mirror then W.holders[host_id] = o end
	return o
end

local function owned(id)
	local list = {}
	for iid, it in pairs(W.items) do if it._parent == id then list[#list + 1] = iid end end
	table.sort(list)
	return list
end

local function same(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function sections_of(id)
	local list = {}
	for _, iid in ipairs(owned(id)) do list[#list + 1] = W.items[iid]._section end
	table.sort(list)
	return table.concat(list, ",")
end

local function created_by(by, parent)
	local n = 0
	for _, c in ipairs(W.created) do if c.by == by and (parent == nil or c.parent == parent) then n = n + 1 end end
	return n
end

-- The stock functions of this machine (Anomaly 1.5.3).
local function stock(M)
	local E = M.env
	M.ran, M.hud_hidden, M.pp = {}, 0, {}
	local function note(s) M.ran[#M.ran + 1] = s end
	E.actor_effects = { disable_effects_timer = function() end }
	E.hide_hud_all = function() M.hud_hidden = M.hud_hidden + 1 end
	E.se_save_var = function() end
	E.level.add_pp_effector = function(name) M.pp[#M.pp + 1] = name end
	E.patrol = function() return { point = function() return DOOR end } end
	E.xr_effects = {}
	local xe = E.xr_effects
	-- xr_effects.disable_ui: this machine's UI off (the trigger's sr_idle@wait_N; the group's start)
	function xe.disable_ui() M.ui_off = (M.ui_off or 0) + 1 end
	-- sr_idle.action_idle:update: the trigger's on_timer 1000 runs here
	E.sr_idle = { action_idle = { update = function(self) M.idle_updates = (M.idle_updates or 0) + 1 end } }
	-- xr_effects.script:5984
	function xe.bar_arena_teleport(actor, npc)
		note("in")
		E.actor_effects.disable_effects_timer(100)
		E.hide_hud_all()
		local box = E.get_story_object("bar_arena_inventory_box")
		if box then E.db.actor:inventory_for_each(function(item) E.db.actor:transfer_item(item, box) end) end
		for n, kit in pairs(KITS) do
			if E.has_alife_info("bar_arena_fight_" .. n) then
				for _, sec in ipairs(kit) do
					local se = E.alife_create(sec, E.db.actor:position(), E.db.actor:level_vertex_id(), E.db.actor:game_vertex_id(), E.AC_ID)
					E.se_save_var(se.id, se:name(), "unpatched", true)
				end
			end
		end
	end
	function xe.bar_arena_weapon_slot(actor, npc, p)
		note("slot")
		E.db.actor:activate_slot(tonumber(p[1]) or 1)
	end
	-- xr_effects.script:6086
	function xe.bar_arena_teleport_2(actor, npc)
		note("out")
		E.hide_hud_all()
		local box = E.get_story_object("bar_arena_inventory_box_2")
		if box then E.db.actor:inventory_for_each(function(item) E.db.actor:transfer_item(item, box) end) end
		E.xr_zones.purge_arena_items("bar_arena")
		E.level.add_pp_effector("blink.ppe", 234, false)
		E.db.actor:set_actor_position(E.patrol("t_walk_2"):point(0))
		local box1 = E.get_story_object("bar_arena_inventory_box")
		if box1 then box1:iterate_inventory_box(function(b, item) b:transfer_item(item, E.db.actor) end, box1) end
	end
	-- xr_effects.script:348
	function xe.teleport_for_totaliz_out()
		note("bet out")
		local box = E.get_story_object("bar_arena_inventory_box_2")
		if box then E.db.actor:inventory_for_each(function(item) E.db.actor:transfer_item(item, box) end) end
		E.xr_zones.purge_arena_items("bar_arena")
		E.level.add_pp_effector("fade_in.ppe", 200, false)
		E.db.actor:set_actor_position(vector():set(BET_OUT_X, 0.43, 72.13))
		local box1 = E.get_story_object("bar_arena_inventory_box")
		if box1 then box1:iterate_inventory_box(function(b, item) b:transfer_item(item, E.db.actor) end, box1) end
	end
	-- dialogs_mlr.script:1431
	E.dialogs_mlr = {}
	function E.dialogs_mlr.teleport_for_totaliz()
		note("bet in")
		local box = E.get_story_object("bar_arena_inventory_box")
		if box then
			E.db.actor:inventory_for_each(function(item) E.db.actor:transfer_item(item, box) end)
			E.level.add_pp_effector("fade_in.ppe", 200, false)
			E.db.actor:set_actor_position(vector():set(BET_SPOT_X, -13.39, 100.86), 37564, 1710)
		end
		if E.has_alife_info("totaliz_money_has_gone") then E.alife_create_item("wpn_binoc", E.db.actor) end
	end
	-- news_manager.script:39: the line shows on this machine's screen
	M.tips, M.stock_tips = {}, 0
	E.news_manager = {
		send_tip = function(actor, news_id, timeout, sender, showtime, sender_id)
			if news_id == nil then return false end
			M.tips[#M.tips + 1] = { id = news_id, to = timeout, s = sender, st = showtime, sid = sender_id }
			return true
		end,
	}
	-- xr_effects.script:5888-5975, the old arena (Arnie's monster fights): its lines, and the infos it gives
	local function counted(f) return function(...) M.stock_tips = M.stock_tips + 1 return f(...) end end
	xe.bar_arena_introduce = counted(function(actor, npc)
		local a = E.db.actor
		if a:has_info("bar_arena_pseudodog_choosen") then
			E.news_manager.send_tip(a, "bar_arena_fight_pseudodog", nil, "arena", 24000, nil)
		elseif a:has_info("bar_arena_snork_choosen") then
			E.news_manager.send_tip(a, "bar_arena_fight_snork", nil, "arena", 30000, nil)
		elseif a:has_info("bar_arena_bloodsucker_choosen") then
			E.news_manager.send_tip(a, "bar_arena_fight_bloodsucker", nil, "arena", 30000, nil)
		elseif a:has_info("bar_arena_burer_choosen") then
			E.news_manager.send_tip(a, "bar_arena_fight_burer", nil, "arena", 52000, nil)
		elseif a:has_info("bar_arena_savage_choosen") then
			E.news_manager.send_tip(a, "bar_arena_fight_savage", nil, "arena", 34000, nil)
		end
	end)
	xe.bar_arena_fight_begin = counted(function(actor, npc)
		if E.db.actor:has_info("bar_arena_actor_lose") or E.db.actor:has_info("bar_arena_actor_victory") then return end
		E.news_manager.send_tip(E.db.actor, "bar_arena_fight_begin", nil, "arena")
	end)
	for n = 10, 90, 10 do
		xe["bar_arena_fight_" .. n] = counted(function(actor, npc)
			E.news_manager.send_tip(E.db.actor, "bar_arena_fight_" .. n, nil, "arena")
		end)
	end
	xe.bar_arena_check_lose = counted(function(actor, npc)
		local a = E.db.actor
		if a:has_info("bar_arena_100_p") then
			if a:has_info("bar_arena_fight_30") then
				a:give_info_portion("bar_arena_actor_lose")
				E.news_manager.send_tip(actor, "bar_arena_fight_timeout", nil, "arena")
			end
			return
		end
		if a:has_info("bar_arena_50_p") then
			if a:has_info("bar_arena_fight_90") then
				a:give_info_portion("bar_arena_actor_lose")
				E.news_manager.send_tip(actor, "bar_arena_fight_timeout", nil, "arena")
			end
			return
		end
	end)
	xe.bar_arena_after_fight = counted(function(actor, npc)
		local a = E.db.actor
		if a:has_info("bar_arena_actor_lose") or a:has_info("bar_arena_actor_victory") then return end
		if not a:has_info("bar_arena_actor_lose") then
			a:give_info_portion("bar_arena_actor_victory")
			E.news_manager.send_tip(actor, "bar_arena_fight_victory", nil, "arena")
		else
			E.news_manager.send_tip(actor, "bar_arena_fight_lose", nil, "arena")
		end
		a:give_info_portion("bar_arena_start_introduce")
	end)
	xe.bar_arena_actor_afraid = counted(function(actor, npc)
		E.news_manager.send_tip(E.db.actor, "bar_arena_actor_afraid", nil, "arena")
	end)
	xe.bar_arena_actor_dead = counted(function(actor, npc)
		E.news_manager.send_tip(E.db.actor, "bar_arena_fight_dead", nil, "arena")
	end)
	-- xr_zones.arena_zone_binder: what walked into the zone is released by the purge
	local cls = {}
	function cls.purge_items(self) for id in pairs(self.saved_obj) do M.released[#M.released + 1] = id end end
	function cls.net_spawn() return true end
	-- the pit's zone: a script_zone named bar_arena in all.spawn (here a ball; real_zones below gives it its real box)
	M.zone = setmetatable({ saved_obj = {}, object = make_obj(930, IN_ARENA.x, IN_ARENA.y, IN_ARENA.z, { _radius = 20, _name = "bar_arena" }) },
		{ __index = cls })
	M.released, M.purges = {}, 0
	E.xr_zones = {
		arena_zone_binder = cls,
		purge_arena_items = function(name)
			M.purges = M.purges + 1
			if name == "bar_arena" then M.zone:purge_items() end
		end,
	}
	-- sr_cutscene.action_cutscene: zone_enter teleports and locks the screen, the callback signals the end
	local cut = {}
	function cut.zone_enter(self)
		M.cut_in = (M.cut_in or 0) + 1
		E.db.actor:set_actor_position(IN_ARENA)
		self.motion = true
	end
	function cut.update(self)
		if self.motion and self.ended then
			self.motion = nil
			self:cutscene_callback()
		end
		E.xr_logic.try_switch_to_another_section(self.object, self.st, E.db.actor)
	end
	function cut.cutscene_callback(self)
		self.st.signals = self.st.signals or {}
		self.st.signals.cameff_end = true
	end
	E.sr_cutscene = { action_cutscene = cut }
	function M.new_cut() return setmetatable({ object = M.objects[TRIG], st = { signals = {} } }, { __index = cut }) end
	E.xr_logic = {
		try_switch_to_another_section = function(_, st)
			if st.signals and st.signals.cameff_end and not st.done then
				st.done = true
				M.switched = (M.switched or 0) + 1
			end
		end,
	}
end

local function env(M, level_name)
	local E = M.env
	E.has_alife_info = function(i) return W.infos[i] == true end
	E.get_story_object_id = function(s) if s == "bar_arena_manager" then return MANAGER end end
	E.get_story_object = function(s)
		if s == "bar_arena_inventory_box" then return M.objects[BOX1] end
		if s == "bar_arena_inventory_box_2" then return M.objects[BOX2] end
	end
	M.level_name = level_name or ARENA
	E.level.name = function() return M.level_name end
	E.alife_object = function(id)
		local o = W.holders[id]
		if o then
			return { id = id, section_name = function() return o:section() end, spawn_ini = function() return o:spawn_ini() end }
		end
	end
	M.keys, M.key_sends = {}, 0
	E.coop_economy_mdata = {
		register_player_key = function(k, f) M.keys[k] = f end,
		send_player_keys = function() M.key_sends = M.key_sends + 1 end,
	}
	-- audience_of: the players a restrictor's condlist is for (M.logic_aud: who walked into bar_arena_waiter; bar_arena_spam
	-- names no player, so everybody)
	E.coop_npc_logic = { add_audience_rule = function(f) M.rule = f end, audience_of = function() return M.logic_aud end }
	if not M.env.coop_trust then load_script(M, "coop_trust") end
	E.coop_npc_players = load_script(M, "coop_npc_players")
	local facade = load_script(M, "coop_mode")
	modes.live(facade, function(name) return load_script(M, name) end)
	E.coop_mods_core = load_script(M, "coop_mods_core")
	-- ui_dyn_msg_box.msg_box_ui: the box (yes = ok, no = cancel). In the game it is a luabind class (stock ui_dyn_msg_box.script:3
	-- `class "msg_box_ui" (CUIScriptWnd)`): type() answers "userdata", calling it makes the window. Modelled as a plain function
	-- it hid that the arena looked it up as a function and showed no button to anybody (owner, live 2026-11-15: "no vote window").
	local box_class = newproxy(true)
	getmetatable(box_class).__call = function(_, typ, show, text, ok, cancel)
		local b = { txt = text, typ = typ }
		b.ok = function() ok(b) end
		b.cancel = function() if cancel then cancel(b) end end
		b.message_box = { HideDialog = function() if M.BOX == b then M.BOX = nil end end }
		M.BOX = b
		return b
	end
	E.ui_dyn_msg_box = { msg_box_ui = box_class }
	E.level.map_add_object_spot = function(id, typ, hint) M.spot = { id = id, typ = typ, hint = hint } end
	E.level.map_remove_object_spot = function(id, typ) if M.spot and M.spot.id == id then M.spot = nil end end
	stock(M)
end

local function host_alife(M)
	M.env.alife_create = function(sec, _, _, _, parent)
		local it = new_item(sec, parent, "host")
		return { id = it._id, name = function() return sec .. it._id end }
	end
	M.env.alife_create_item = function(sec, obj) return M.env.alife_create(sec, nil, 0, 0, obj:id()) end
end

-- F2 T12b: a client's own new item is made by the host, in his character there (the proxy).
local function client_alife(M)
	M.env.alife_create = function(sec, _, _, _, parent)
		local it = new_item(sec, parent == 0 and PROXY or parent, "client")
		return { id = it._id, name = function() return sec .. it._id end }
	end
	M.env.alife_create_item = function(sec, obj) return M.env.alife_create(sec, nil, 0, 0, obj:id()) end
end

local function client_machine()
	local M = machine("client", 1, { [0] = PROXY, [1] = 0 })
	M.mirror = true
	local function swap(id) if id == 0 then return PROXY elseif id == PROXY then return 0 end return id end
	M.to_host, M.to_local = swap, swap
	holder(M, M.env.db.actor, PROXY)
	M.add(make_obj(PROXY, 100, 0, 100, { _name = "host_avatar" })) -- the host's character on the client
	M.add(make_obj(TRIG, 152.9, 0.5, 70.5, { _name = "bar_arena_triger" }))
	holder(M, M.add(make_obj(BOX1, 149, 1, 72, { _name = "box1" })), BOX1)
	holder(M, M.add(make_obj(BOX2, 139, -13.4, 90.2, { _name = "box2" })), BOX2)
	for id, it in pairs(W.items) do M.objects[id] = it end
	-- an item as the client sees it: in his own hands (local id 0) what the world puts in his character
	local views = {}
	local object_by_id = M.env.level.object_by_id
	M.env.level.object_by_id = function(id)
		local it = W.items[id]
		if not it then return object_by_id(id) end
		local v = views[id]
		if not v then
			v = setmetatable({}, { __index = it })
			function v:parent()
				local at = W.client_seen[id] or W.items[id]._parent
				if at == PROXY then return M.env.db.actor end
				return M.objects[at]
			end
			views[id] = v
		end
		return v
	end
	env(M)
	client_alife(M)
	return M
end

local function setup(opts)
	opts = opts or {}
	reset_world()
	NOW = NOW + 1000000
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {}, client_seen = {} }
	local map = opts.answer == "srv_map"
	local avatars = { [1] = PROXY }
	if not map then avatars[0] = 0 end
	if opts.third then avatars[2] = THIRD end
	if opts.away then avatars[3] = AWAY end -- a player of the session on another map: no character on this one
	H = machine(map and "client" or "host", map and BRIDGE or 0, avatars)
	if map then
		H.env.coop.is_map_server = function() return true end
		H.env.coop.is_mirror = function() return false end
	end
	Cm = nil
	holder(H, H.env.db.actor, 0)
	H.env.db.actor._pos = vec(100, 0, 100)
	-- the client's character on the Bar, 25 m from Arnie (outside GATHER_RADIUS; nearer than the host)
	holder(H, H.add(make_obj(PROXY, 130, 0, 90, { _name = "proxy1" })), PROXY)
	if opts.third then holder(H, H.add(make_obj(THIRD, 120, 0, 100, { _name = "proxy2" })), THIRD) end
	START_AS_IS = opts.start_as_is == true
	H.add(make_obj(TRIG, 152.9, 0.5, 70.5, { _name = "bar_arena_triger" }))
	H.add(make_obj(MANAGER, 149, 1, 74, { _name = "arnie" }))
	H.add(make_obj(COMMENT, 150, 0, 70, { _name = "bar_arena_comment_fight_1" }))
	H.add(make_obj(TOTAL, 150, 0, 70, { _name = "bar_arena_totalizator" }))
	H.add(make_obj(SR, 150, -13, 95, { _name = "bar_arena_sr" }))
	H.add(make_obj(SPAM, 150, 0, 70, { _name = "bar_arena_spam" }))
	H.add(make_obj(OPPONENT, 153, -19, 104, { _section = "bar_arena_stalker_3_1" }))
	holder(H, H.add(make_obj(BOX1, 149, 1, 72, { _name = "box1" })), BOX1)
	holder(H, H.add(make_obj(BOX2, 139, -13.4, 90.2, { _name = "box2" })), BOX2)
	holder(H, H.add(make_obj(BODY, 153, -19, 103, { _name = "body" })), BODY)
	env(H)
	host_alife(H)
	H.env.coop.talk_recent = function(peer, npc, ms)
		local t = W.talked[peer]
		return npc == MANAGER and t ~= nil and NOW - t <= ms
	end
	-- the gear: the host's and the client's (in his character on the host)
	for _, s in ipairs({ "exo_outfit", "wpn_ak74", "helm_sphere", "medkit", "bread" }) do new_item(s, 0, "start") end
	for _, s in ipairs({ "stalker_outfit", "wpn_abakan", "helm_tactic", "ammo_5.45x39_fmj", "bandage", "detector_bear" }) do
		new_item(s, PROXY, "start")
	end
	W.created = {}
	Cm = client_machine()
	HA = load_script(H, "coop_arena")
	CA = load_script(Cm, "coop_arena")
	if opts.before_start then opts.before_start() end
	HA.on_game_start()
	CA.on_game_start()
	-- the level loads: the arena zone's binder spawns (coop_arena keeps it); zone_before: it spawned before coop_arena's wrapper
	if not opts.zone_before then H.zone:net_spawn() end
	return H, Cm
end

-- The starter of a held fight holds the use key at Arnie (owner 2026-11-24, TZ R88): coop_hud_arena calls
-- coop_arena.start_pressed on his machine; the host player's own goes straight in, a client's is his arena.start, and on a map
-- server it comes through the world server (from 0, with the player's _peer).
local NEAR_ARNIE = vec(148, 1, 76) -- 2.2 m from Arnie (149, 1, 74)
local function press_start(A)
	local f = A and A.start_pressed
	if type(f) == "function" then f() end
end
local function relay_start(peer)
	for _, f in ipairs(H.handlers["arena.start"] or {}) do f(H.env.coop_main.encode({ _peer = peer }), 0) end
end
local function hold_start(id)
	if id == 0 then
		H.env.db.actor._pos = vector():set(NEAR_ARNIE)
		press_start(HA)
	elseif H.peer == 0 and id == PROXY then
		H.objects[id]._pos = vector():set(NEAR_ARNIE)
		Cm.env.db.actor._pos = vector():set(NEAR_ARNIE)
		press_start(CA)
	else
		H.objects[id]._pos = vector():set(NEAR_ARNIE)
		relay_start(id == PROXY and 1 or 2)
	end
	pump()
end

-- The host's trigger: the dialog gave fight n; sr_idle@idle -> sr_idle@wait_n (%=disable_ui%: the audience rule), on_timer
-- 1000 -> sr_cutscene@fight_n (%=bar_arena_teleport%), whose section reaches every machine (its cutscene).
-- START_AS_IS: only the trigger's sr_idle@wait_N (its audience); else the starter of a held fight walks up to Arnie and holds
-- the use key there (hold_start).
local function start(n)
	W.infos["bar_arena_fight_" .. n], W.infos.bar_arena_fight = true, true
	local aud = H.rule(H.objects[TRIG])
	pump()
	if START_AS_IS then return aud end
	local f = HA._state().fight
	if f and f.hold then
		hold_start(f.id)
		aud = H.rule(H.objects[TRIG])
	end
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	H.cut, Cm.cut = H.new_cut(), Cm.new_cut()
	H.cut:zone_enter()
	Cm.cut:zone_enter()
	if (Cm.cut_in or 0) > 0 then
		H.objects[PROXY]._pos = vector():set(Cm.env.db.actor:position())
	end
	return aud
end

local function ledger_for(A, id)
	for _, rec in pairs(A._state().ledger) do
		if rec.id == id then return rec end
	end
end

local function win(n)
	W.infos["bar_arena_fight_" .. n .. "_done"] = true
	H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
	pump()
end

local function tick(M, ms)
	NOW = NOW + (ms or 1000)
	M.env.coop_npc_players.invalidate()
	M.fire("actor_on_update")
end

local function at(o, v) return o._pos:distance_to(v) < 0.01 end

local function released(M, id)
	for _, r in ipairs(M.released) do if r == id then return true end end
	return false
end

-- The Bar's real arena zones (all.spawn of the stand, R88): two script_zones with [arena_zone], bar_arena (the pit, a box
-- 35.76 x 3.73 x 59.61 at 153.25 -19.46 103.67) and bar_old_arena (the old monster cage, a box 17.1 x 10.08 x 19.33 at 157.0
-- 0.1 95.13, after the pit in the file). t_way, where the cutscene puts a fighter, is in the pit's box only.
local T_WAY = vec(151.82, -21.06, 75.3)
local function boxed(o, cx, cy, cz, sx, sy, sz)
	function o:inside(p)
		return math.abs(p.x - cx) <= sx / 2 and math.abs(p.y - cy) <= sy / 2 and math.abs(p.z - cz) <= sz / 2
	end
	return o
end
-- The zones' real boxes; the level spawns their binders again in the order of all.spawn (the pit, then the cage), or the other.
local function real_zones(M, cage_first)
	boxed(M.zone.object, 153.25, -19.46, 103.67, 35.76, 3.73, 59.61)
	local cls = M.env.xr_zones.arena_zone_binder
	local cage_obj = boxed(make_obj(931, 157.0, 0.1, 95.13, { _name = "bar_old_arena" }), 157.0, 0.1, 95.13, 17.1, 10.08, 19.33)
	local cage = setmetatable({ saved_obj = {}, object = cage_obj }, { __index = cls })
	if cage_first then
		cage:net_spawn()
		M.zone:net_spawn()
	else
		M.zone:net_spawn()
		cage:net_spawn()
	end
end

-------------------------------------------------------------------------------
print("== a client fights, the host watches (the report of 2026-11-07)")
do
	setup()
	local host_gear, client_gear = owned(0), owned(PROXY)
	local host_pos = H.env.db.actor._pos
	W.talked[0], W.talked[1] = NOW - 30000, NOW - 1000
	local aud = start(3)
	check(aud and aud[PROXY] == true and aud[0] == nil, "the fighter is the one who talked to Arnie last: the trigger's effects are his alone")
	check(same(owned(0), host_gear) and at(H.env.db.actor, host_pos), "the host keeps his gear and his place")
	check((H.cut_in or 0) == 0 and H.cut.coop_still ~= nil, "the host's cutscene stands still: he is not taken into the arena")
	check(same(owned(BOX1), client_gear) and #owned(BOX1) == 6, "the client's whole gear is in box 1, moved by the host")
	check((Cm.requests or 0) == 0, "the client asked for no move of his own: the stock loops over the boxes are hidden on his machine")
	check(Cm.ran[1] == "in" and created_by("client", PROXY) == 4 and created_by("host") == 0, "the kit is made by his own stock call, into his character")
	check(sections_of(PROXY) == "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_bm16", "he holds the fight's kit and nothing else")
	check(Cm.cut_in == 1 and at(Cm.env.db.actor, IN_ARENA), "his cutscene takes him into the arena")
	check(#H.ran == 0, "no stock call on the host for another player")
	check(CA._state().mine == "fight" and Cm.keys.coop_arena_gear() == true and Cm.key_sends >= 1, "his flag: the host hears at once")
	check(ledger_for(HA, PROXY) and #ledger_for(HA, PROXY).items == 6, "the host's ledger holds his six items")

	H.cut:update()
	check((H.switched or 0) == 0, "the host waits for the fighter's cutscene")
	Cm.cut.ended = true
	Cm.cut:update()
	pump()
	H.cut:update()
	check(H.switched == 1, "his cutscene ended: the host's trigger goes on (sr_idle@fight)")

	H.env.xr_effects.bar_arena_weapon_slot(H.env.db.actor, H.objects[TRIG], { "2" })
	pump()
	check(Cm.env.db.actor._slot == 2 and H.env.db.actor._slot == nil, "the weapon slot is the fighter's")

	-- the fight: he picks up an opponent's knife; the zone counted him and the opponent
	new_item("wpn_knife", PROXY, "world")
	H.zone.saved_obj = { [PROXY] = true, [OPPONENT] = true }
	win(3)
	check(same(owned(PROXY), client_gear), "won: exactly his own gear comes back, nothing more, nothing less")
	check(#owned(BOX1) == 0 and #owned(BOX2) == 5, "box 1 is empty, the kit and the knife are in box 2")
	check(released(H, OPPONENT) and not released(H, PROXY), "the purge takes the opponent, never a player's character")
	check(same(owned(0), host_gear), "the host's gear never moved")
	check(Cm.ran[#Cm.ran] == "out" and at(Cm.env.db.actor, DOOR), "he is at the arena's door")
	check(Cm.purges == 0 and H.purges == 1, "the purge is the host's alone")
	check(CA._state().mine == false and Cm.keys.coop_arena_gear() == nil, "his flag is gone")
	check(ledger_for(HA, PROXY) == nil and HA._state().fight == nil, "the ledger and the fight are clean")
	local total = 0
	for _ in pairs(W.items) do total = total + 1 end
	check(total == 5 + 6 + 4 + 1, "no item was made or lost on the way: 5 + 6 + the kit + the knife")
end

print("== the host fights, the client watches")
do
	setup()
	local host_gear, client_gear = owned(0), owned(PROXY)
	local client_pos = Cm.env.db.actor._pos
	W.talked[0] = NOW
	local aud = start(1)
	check(aud and aud[0] == true and aud[PROXY] == nil, "the host talked to Arnie: he fights")
	check(same(owned(BOX1), host_gear), "the host's gear is in box 1")
	check(created_by("host", 0) == 4 and created_by("client") == 0, "his kit is his own stock call's")
	check(H.cut_in == 1 and at(H.env.db.actor, IN_ARENA), "his cutscene takes him into the arena")
	check((Cm.cut_in or 0) == 0 and at(Cm.env.db.actor, client_pos), "the client's cutscene stands still: he stays where he is")
	local touched = 0
	for _, s in ipairs(sent_named(H, "arena.go")) do
		if H.env.coop_main.decode(s.payload).f ~= "gather" then touched = touched + 1 end
	end
	check(same(owned(PROXY), client_gear) and touched == 0, "the client is not touched (but invited, and the invitation taken back)")
	H.cut.ended = true
	H.cut:update()
	check(H.switched == 1 and #sent_named(Cm, "arena.cut") == 0, "the host's own cutscene ends the stock way")
	H.zone.saved_obj = { [OPPONENT] = true, [PROXY] = true }
	win(1)
	check(same(owned(0), host_gear) and sections_of(BOX2) == "ammo_9x18_pmm,ammo_9x18_pmm,novice_outfit,wpn_pm", "won: his gear back, the kit in box 2")
	check(at(H.env.db.actor, DOOR) and same(owned(PROXY), client_gear), "he is at the door, the client still has his gear")
	check(released(H, OPPONENT) and not released(H, PROXY), "the client's character is not purged")
end

print("== a client falls in the fight and respawns")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	-- he dies: his body keeps the kit (coop death), he respawns with nothing
	for _, id in ipairs(owned(PROXY)) do W.items[id]._parent = BODY end
	Cm.fire("coop_respawned", "camp")
	pump()
	check(same(owned(PROXY), client_gear), "respawned: his gear comes back")
	check(#owned(BOX1) == 0 and #owned(BOX2) == 0, "nothing of his is left in the boxes")
	check(at(Cm.env.db.actor, DOOR) and CA._state().mine == false, "at the arena's door, his flag gone")
	check(HA._state().fight == nil, "his fight forgets its fighter (ending it is coop_encounters' rule, tested there)")
	local moves = W.moves
	Cm.fire("coop_respawned", "camp")
	pump()
	check(W.moves == moves and #sent_named(Cm, "arena.out") == 1, "once")
end

print("== the host falls in the fight and respawns")
do
	setup()
	local host_gear = owned(0)
	W.talked[0] = NOW
	start(1)
	for _, id in ipairs(owned(0)) do W.items[id]._parent = BODY end
	H.fire("coop_respawned", "camp")
	check(same(owned(0), host_gear) and at(H.env.db.actor, DOOR), "respawned: his gear back, at the door")
end

print("== live 2026-11-15 (G.A.M.M.A., split levels): a fighter who falls keeps nothing of the arena's")
do
	local STASH = 778
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	H.objects[PROXY]._pos = vec(IN_ARENA.x, IN_ARENA.y, IN_ARENA.z) -- the authority sees his character in the pit
	-- in the fight the kit's weapon gets its scope: the game makes another weapon of it, an id the kit's list never held;
	-- and he takes an opponent's rifle
	for _, id in ipairs(owned(PROXY)) do
		if W.items[id]._section == "wpn_bm16" then W.items[id]._parent = nil end
	end
	new_item("wpn_bm16_scope", PROXY, "world")
	new_item("wpn_ak74_of_an_opponent", PROXY, "world")
	tick(H)
	check(#owned(BOX2) == 0 and #owned(PROXY) == 5, "alive in the pit: nothing is taken from him")
	H.env.coop.life_of = function(id) return id == PROXY and "wounded" or "alive" end
	tick(H)
	check(#owned(PROXY) == 5, "down, not dead: he keeps what he holds (a teammate may raise him)")
	-- he dies. The death's rule (drop) put the two boxes of his backpack into a stash at the body; what he wears stays on him
	holder(H, H.add(make_obj(STASH, IN_ARENA.x, IN_ARENA.y, IN_ARENA.z, { _section = "coop_death_stash" })), STASH)
	for _, id in ipairs(owned(PROXY)) do
		if W.items[id]._section == "ammo_12x70_buck" then W.items[id]._parent = STASH end
	end
	H.env.coop.life_of = function(id) return id == PROXY and "dead" or "alive" end
	H.fire("coop_death_marker", PROXY, STASH, "drop")
	tick(H)
	check(#owned(PROXY) == 0, "dead in the pit: everything he held there is the arena's, at once")
	check(#owned(STASH) == 0, "the stash his death left in the pit is emptied too")
	check(sections_of(BOX2) == "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_ak74_of_an_opponent,wpn_bm16_scope",
		"the kit, the weapon the kit became and the opponent's rifle are in box 2")
	check(same(owned(BOX1), client_gear), "his own gear still waits in box 1")
	-- he respawns at his camp on the Bar and asks for his gear
	H.env.coop.life_of = function() return "alive" end
	H.objects[PROXY]._pos = vec(150, 0, 72)
	Cm.fire("coop_respawned", "camp")
	pump()
	check(same(owned(PROXY), client_gear), "respawned: exactly his own gear, nothing of the arena's")
	check(#owned(BOX1) == 0 and #owned(BOX2) == 5, "box 1 is empty, the arena's things stay in box 2")
	local moves = W.moves
	tick(H)
	tick(H)
	check(W.moves == moves, "nothing moves after that")

	-- the host player falls in his own fight: the same
	setup()
	local host_gear = owned(0)
	W.talked[0] = NOW
	start(1)
	H.env.db.actor._pos = vec(IN_ARENA.x, IN_ARENA.y, IN_ARENA.z)
	new_item("wpn_knife_of_an_opponent", 0, "world")
	tick(H)
	H.env.coop.life_of = function(id) return id == 0 and "dead" or "alive" end
	tick(H)
	check(#owned(0) == 0 and #owned(BOX2) == 5, "the host player dead in the pit: the kit and the knife are the arena's")
	H.env.coop.life_of = function() return "alive" end
	H.env.db.actor._pos = vec(150, 0, 72)
	H.fire("coop_respawned", "camp")
	check(same(owned(0), host_gear), "respawned: his own gear alone")

	-- a record whose player walks free (seen alive outside the arena after the pit: a rejoin somewhere else) is no custody:
	-- a death there takes nothing for the arena, the late give back takes the kit by its ids as before
	setup()
	W.talked[1] = NOW
	start(3)
	H.objects[PROXY]._pos = vec(IN_ARENA.x, IN_ARENA.y, IN_ARENA.z)
	tick(H)
	H.objects[PROXY]._pos = vec(0, 0, 0)
	tick(H)
	local found = new_item("bread", PROXY, "world")
	H.env.coop.life_of = function(id) return id == PROXY and "dead" or "alive" end
	H.fire("coop_death_marker", PROXY, STASH, "drop")
	tick(H)
	check(#owned(PROXY) == 5 and #owned(BOX2) == 0, "dead far from the arena with an open record: nothing is taken there")
	H.env.coop.life_of = function() return "alive" end
	Cm.fire("coop_respawned", "camp")
	pump()
	local kept = false
	for _, id in ipairs(owned(PROXY)) do kept = kept or id == found._id end
	check(kept and #owned(BOX2) == 4, "his late give back: the kit by its ids, what he found stays his")
end

print("== a client leaves in the fight; it is won without him; he rejoins")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	-- he leaves: his character is out of the world
	local proxy = H.objects[PROXY]
	H.objects[PROXY] = nil
	H.env.coop_npc_players.invalidate()
	win(3)
	check(same(owned(BOX1), client_gear), "won without him: his gear waits in box 1")
	check(ledger_for(HA, PROXY) ~= nil and HA._state().fight == nil, "his ledger stays, the fight is over")
	-- the host saves and loads the world meanwhile
	local md = {}
	H.fire("save_state", md)
	H.fire("load_state", md)
	check(ledger_for(HA, PROXY) and #ledger_for(HA, PROXY).items == 6, "the ledger comes back with the host's world")
	-- he rejoins: his Lua state is new, his flag comes from the world he loads (a per-player key)
	H.objects[PROXY] = proxy
	Cm = client_machine()
	CA = load_script(Cm, "coop_arena")
	CA.on_game_start()
	Cm.fire("load_state", { coop_arena_gear = true, coop_arena = md.coop_arena })
	check(CA._state().mine == "fight" and next(CA._state().ledger) == nil, "his flag is back; the host's ledger is not his")
	Cm.fire("actor_on_first_update")
	pump()
	check(same(owned(PROXY), client_gear) and #owned(BOX1) == 0, "back on the Bar with no fight: his gear comes back")
	check(sections_of(BOX2) == "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_bm16", "the kit he still held went to box 2")
end

print("== a rejoin on another map: the gear waits for the Bar")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	W.infos.bar_arena_fight_3, W.infos.bar_arena_fight_begin = nil, nil -- the rule ended the fight
	HA.fight_over()
	Cm = client_machine()
	Cm.level_name = "l01_escape"
	CA = load_script(Cm, "coop_arena")
	CA.on_game_start()
	Cm.fire("load_state", { coop_arena_gear = true })
	Cm.fire("actor_on_first_update")
	pump()
	check(same(owned(BOX1), client_gear), "on another map: nothing yet")
	Cm.level_name = ARENA
	Cm.fire("actor_on_first_update")
	pump()
	check(same(owned(PROXY), client_gear) and at(Cm.env.db.actor, DOOR), "on the Bar: his gear back, at the door")
	W.infos.bar_arena_fight_1 = true
	Cm.fire("load_state", { coop_arena_gear = true })
	local outs = #sent_named(Cm, "arena.out")
	Cm.fire("actor_on_first_update")
	check(#sent_named(Cm, "arena.out") == outs, "a fight runs: he stays in it, nothing is asked")
end

print("== a client bets at the totalizator")
do
	setup()
	local host_gear, client_gear = owned(0), owned(PROXY)
	local host_pos = H.env.db.actor._pos
	W.infos.totaliz_money_has_gone = true
	Cm.env.dialogs_mlr.teleport_for_totaliz(Cm.env.db.actor, nil)
	pump()
	check(same(owned(BOX1), client_gear) and ledger_for(HA, PROXY).kind == "bet", "his gear is in box 1, as a bet")
	check(sections_of(PROXY) == "wpn_binoc" and created_by("client", PROXY) == 1, "his binoculars are his stock call's")
	check(math.abs(Cm.env.db.actor._pos.x - BET_SPOT_X) < 0.01 and (Cm.requests or 0) == 0, "he stands at the spectators' place, no move of his own asked")
	check(same(owned(0), host_gear) and at(H.env.db.actor, host_pos), "the host is not touched")
	H.zone.saved_obj = { [PROXY] = true }
	H.env.xr_effects.teleport_for_totaliz_out(H.env.db.actor, H.objects[TOTAL])
	pump()
	check(same(owned(PROXY), client_gear) and sections_of(BOX2) == "wpn_binoc", "the fight is over: his gear back, the binoculars in box 2")
	check(same(owned(0), host_gear) and #H.ran == 0, "the host's inventory stays his (b-L10: it went into box 2 before)")
	check(math.abs(Cm.env.db.actor._pos.x - BET_OUT_X) < 0.01 and not released(H, PROXY), "the bettor is out, his character not purged")
	check(CA._state().mine == false and ledger_for(HA, PROXY) == nil, "flag and ledger clean")
end

print("== the host and a client bet at once")
do
	setup()
	local host_gear, client_gear = owned(0), owned(PROXY)
	W.infos.totaliz_money_has_gone = true
	H.env.dialogs_mlr.teleport_for_totaliz(H.env.db.actor, nil)
	Cm.env.dialogs_mlr.teleport_for_totaliz(Cm.env.db.actor, nil)
	pump()
	check(#owned(BOX1) == 11 and sections_of(0) == "wpn_binoc" and sections_of(PROXY) == "wpn_binoc", "both gears in box 1, both have binoculars")
	check(math.abs(H.env.db.actor._pos.x - BET_SPOT_X) < 0.01, "the host stands at the spectators' place too")
	H.env.xr_effects.teleport_for_totaliz_out(H.env.db.actor, H.objects[TOTAL])
	pump()
	check(same(owned(0), host_gear) and same(owned(PROXY), client_gear), "each gets exactly his own gear back")
	check(#owned(BOX1) == 0 and #owned(BOX2) == 2, "box 1 empty, two binoculars in box 2")
end

print("== a client fights while the host bets")
do
	setup()
	local host_gear, client_gear = owned(0), owned(PROXY)
	W.talked[1] = NOW
	start(3)
	W.infos.totaliz_money_has_gone = true
	H.env.dialogs_mlr.teleport_for_totaliz(H.env.db.actor, nil)
	H.env.xr_effects.teleport_for_totaliz_out(H.env.db.actor, H.objects[TOTAL])
	pump()
	check(same(owned(0), host_gear), "the totalizator's end: the host's gear back")
	check(same(owned(BOX1), client_gear), "the fighter's gear stays in box 1: the bet's end is not his")
	win(3)
	check(same(owned(PROXY), client_gear) and #owned(BOX1) == 0, "his fight won: his gear back")
end

print("== the way in waits until his old gear has left his machine")
do
	setup()
	W.lagging = true
	W.talked[1] = NOW
	start(3)
	check(created_by("client") == 0 and CA._state().fighting == true, "his old gear is still on his machine: no kit yet, he is the fighter")
	check(Cm.cut_in == 1, "his cutscene plays meanwhile")
	Cm.fire("actor_on_update")
	check(created_by("client") == 0, "still there: still waiting")
	W.lagging, W.client_seen = false, {}
	Cm.fire("actor_on_update")
	check(created_by("client", PROXY) == 4 and Cm.ran[1] == "in", "the moves came: the stock way in, the kit")
	setup()
	W.lagging = true
	W.talked[1] = NOW
	start(3)
	NOW = NOW + 3000
	Cm.fire("actor_on_update")
	check(created_by("client", PROXY) == 4, "moves lost: after 3 s the way in goes on")
	Cm.fire("actor_on_update")
	check(created_by("client", PROXY) == 4, "once")
end

print("== no box 1 in the world: nothing of his moves")
do
	setup()
	local client_gear = owned(PROXY)
	H.objects[BOX1] = nil
	W.talked[1] = NOW
	start(3)
	check(#HA._state().ledger == 0 and next(HA._state().ledger) == nil, "no box: no ledger")
	win(3)
	check(at(Cm.env.db.actor, DOOR), "no box: a fighter who reached the pit can still leave it after the win")
	local kept = 0
	for _, id in ipairs(owned(PROXY)) do for _, g in ipairs(client_gear) do if g == id then kept = kept + 1 end end end
	check(kept == 6 and #owned(BOX2) == 0, "won: his own gear never went into box 2 (stock would have put it there)")

	setup()
	client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	local box = H.objects[BOX1]
	H.objects[BOX1] = nil -- box 1 is not online (the host stands on another part of the world)
	win(3)
	check(same(owned(BOX1), client_gear) and ledger_for(HA, PROXY) ~= nil, "box 1 is not here: his ledger waits, nothing is lost")
	check(sections_of(PROXY) == "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_bm16", "and nothing of his went to box 2")
	H.objects[BOX1] = box
	tick(H, 20000)
	pump()
	check(same(owned(PROXY), client_gear), "box 1 is back: his gear comes back")
end

print("== the cutscene message is lost: the host goes on by itself")
do
	setup()
	W.talked[1] = NOW
	start(3)
	tick(H, 20000)
	H.cut:update()
	check((H.switched or 0) == 0, "20 s: still waiting")
	NOW = NOW + 11000
	H.cut:update()
	check(H.switched == 1, "30 s: the trigger goes on")
end

print("== a mod (GAMMA's magazines) wraps the way in after coop")
do
	local function mags(M)
		local E = M.env
		local inner = E.xr_effects.bar_arena_teleport
		E.xr_effects.bar_arena_teleport = function(actor, npc)
			inner(actor, npc)
			E.alife_create("mag_bm16", E.db.actor:position(), 1, 2, E.AC_ID)
		end
	end
	setup()
	mags(H)
	mags(Cm)
	tick(H)
	tick(Cm)
	check(HA._state().stats.rewrapped == 6 and CA._state().stats.rewrapped == 6, "our wrapper is put outside the mod again")
	W.talked[1] = NOW
	start(3)
	check(created_by("client", PROXY) == 5 and created_by("host") == 0, "the mod's magazine is made on the fighter's machine, for him, never on the host")
	check(sections_of(PROXY):find("mag_bm16", 1, true) ~= nil, "he holds it")
end

print("== a stray call on a client (no fight of his) does nothing")
do
	setup()
	local client_gear = owned(PROXY)
	Cm.env.xr_effects.bar_arena_teleport(Cm.env.db.actor, nil)
	Cm.env.xr_effects.bar_arena_teleport_2(Cm.env.db.actor, nil)
	Cm.env.xr_effects.teleport_for_totaliz_out(Cm.env.db.actor, nil)
	pump()
	check(same(owned(PROXY), client_gear) and #Cm.ran == 0 and #W.created == 0, "no kit, no move, no stock call")
end

print("== his ask never came (sent before his game was live): the host gives his gear back by itself")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	tick(H, 20000)
	check(same(owned(BOX1), client_gear), "his fight runs: nothing, however long it lasts")
	-- the rule ends the fight while he is down; he respawns, his ask is lost
	W.infos.bar_arena_fight_3, W.infos.bar_arena_fight_begin = nil, nil
	HA.fight_over()
	for _, id in ipairs(owned(PROXY)) do W.items[id]._parent = BODY end
	H.env.LIFE = H.env.LIFE or {}
	H.env.coop.life_of = function(id) return id == PROXY and "wounded" or "alive" end
	tick(H)
	check(same(owned(BOX1), client_gear), "he is down: his gear waits")
	H.env.coop.life_of = function() return "alive" end
	tick(H)
	pump()
	check(same(owned(PROXY), client_gear) and at(Cm.env.db.actor, DOOR), "he stands: the host gives it back, he is at the door")
	check(CA._state().mine == false and ledger_for(HA, PROXY) == nil, "flag and ledger clean")

	setup()
	client_gear = owned(PROXY)
	W.infos.totaliz_money_has_gone, W.infos.begin_the_battle = true, true
	Cm.env.dialogs_mlr.teleport_for_totaliz(Cm.env.db.actor, nil)
	pump()
	tick(H, 20000)
	check(same(owned(BOX1), client_gear), "a totalizator battle runs: the bet waits")
	W.infos.begin_the_battle = nil
	tick(H)
	pump()
	check(same(owned(PROXY), client_gear) and sections_of(BOX2) == "wpn_binoc", "no battle and no end came to him: his gear back, the binoculars in box 2")
end

print("== a give back in the middle of another player's fight does not purge it")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	W.infos.bar_arena_fight_3, W.infos.bar_arena_fight_begin = nil, nil
	HA.fight_over() -- the rule ended his fight
	tick(Cm) -- his machine sees no fight running
	NOW = NOW + 1000
	W.talked[0], W.talked[1] = NOW, nil
	start(1) -- the host fights now
	H.zone.saved_obj = { [OPPONENT] = true }
	local purges = H.purges
	Cm.fire("coop_respawned", "camp")
	pump()
	check(same(owned(PROXY), client_gear), "the client respawned: his gear back")
	check(H.purges == purges and not released(H, OPPONENT), "the host's opponents stay: no purge during his fight")
	win(1)
	check(released(H, OPPONENT), "the host's fight ends: now the arena is purged")
end

print("== a late give back keeps what he found since; in the arena everything he holds is the arena's")
do
	setup()
	local client_gear = owned(PROXY)
	W.talked[1] = NOW
	start(3)
	check(#ledger_for(HA, PROXY).kit == 4, "his machine told the host what the arena gave him")
	-- he falls and keeps his inventory (the keep setting), respawns outside, picks something up, his ask comes late
	tick(H)
	Cm.env.db.actor._pos = vec(0, 0, 0)
	H.objects[PROXY]._pos = vec(0, 0, 0)
	local found = new_item("bread", PROXY, "world")
	Cm.fire("coop_respawned", "camp")
	pump()
	local mine_now = owned(PROXY)
	check(#mine_now == 7 and sections_of(BOX2) == "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_bm16", "the kit goes to box 2, his gear comes back")
	local kept = false
	for _, id in ipairs(mine_now) do kept = kept or id == found._id end
	check(kept, "what he found outside stays his")

	setup()
	W.talked[1] = NOW
	start(3)
	-- he rejoins standing in the arena, with the kit and a knife he took there
	new_item("wpn_knife", PROXY, "world")
	H.objects[PROXY]._pos = vec(IN_ARENA.x, IN_ARENA.y, IN_ARENA.z)
	HA.fight_over()
	W.infos.bar_arena_fight_3 = nil
	Cm.fire("coop_respawned", "camp")
	pump()
	check(#owned(BOX2) == 5, "standing in the arena: the kit and the knife go to box 2, as stock")
end

print("== a fighter cannot bet his kit away")
do
	setup()
	W.talked[1] = NOW
	start(3)
	W.infos.totaliz_money_has_gone = true
	Cm.env.dialogs_mlr.teleport_for_totaliz(Cm.env.db.actor, nil)
	pump()
	check(ledger_for(HA, PROXY).kind == "fight" and #ledger_for(HA, PROXY).items == 6, "his ledger stays the fight's")
	check(#owned(BOX1) == 6 and sections_of(PROXY):find("wpn_binoc", 1, true) == nil, "nothing more went in, no bet")
end

print("== split levels: the Bar's ledger outlives its map server")
do
	reset_world()
	NOW = NOW + 1000000
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {}, client_seen = {} }
	local function share_stub(M)
		M.ups, M.downs = {}, {}
		-- Capture what the facade registers for the server to carry.
		M.env.coop_quests_core = {
			share_up = function(n, get, set) M.ups[n] = { get = get, set = set } end,
			share_down = function(n, get, set) M.downs[n] = { get = get, set = set } end,
		}
	end
	-- The world server keeps the ledger in its save.
	local Wd = machine("host", 0, { [1] = PROXY })
	Wd.env.coop.is_dedicated = function() return true end
	Cm = nil
	H = Wd
	holder(Wd, Wd.env.db.actor, 0)
	env(Wd, "fake_start")
	host_alife(Wd)
	share_stub(Wd)
	local WA = load_script(Wd, "coop_arena")
	WA.on_game_start()
	-- the map server of the Bar
	local function map_server()
		local Mk = machine("client", BRIDGE, { [1] = PROXY })
		Mk.env.coop.is_map_server = function() return true end
		Mk.env.coop.is_mirror = function() return false end
		holder(Mk, Mk.env.db.actor, 0)
		holder(Mk, Mk.add(make_obj(PROXY, 148, 1, 72)), PROXY)
		Mk.add(make_obj(TRIG, 152.9, 0.5, 70.5, { _name = "bar_arena_triger" }))
		Mk.add(make_obj(MANAGER, 149, 1, 74))
		holder(Mk, Mk.add(make_obj(BOX1, 149, 1, 72)), BOX1)
		holder(Mk, Mk.add(make_obj(BOX2, 139, -13.4, 90.2)), BOX2)
		for id, it in pairs(W.items) do Mk.objects[id] = it end
		env(Mk)
		host_alife(Mk)
		share_stub(Mk)
		local A = load_script(Mk, "coop_arena")
		A.on_game_start()
		Mk.zone:net_spawn()
		return Mk, A
	end
	local Mk, MA = map_server()
	H = Mk
	for _, s in ipairs({ "stalker_outfit", "wpn_abakan", "helm_tactic" }) do Mk.objects[new_item(s, PROXY, "start")._id] = W.items[W.next_id] end
	local gear = owned(PROXY)
	W.infos.bar_arena_fight_3 = true
	Mk.env.xr_effects.bar_arena_teleport(Mk.env.db.actor, Mk.objects[TRIG])
	check(same(owned(BOX1), gear), "his gear in box 1 on the map server")
	local up = Mk.ups.arena_ledger.get()
	check(up and up.based == false and #up.list == 1, "the map server tells the world server its ledger (before it heard the world's copy)")
	Wd.ups.arena_ledger.set(up, 2)
	local first_echo = Wd.downs.arena_ledger.get()
	local md = {}
	Wd.fire("save_state", md)
	check(md.coop_arena and md.coop_arena.split and #md.coop_arena.split == 1, "the world server keeps it in its save")
	-- the Bar empties, its map server stops; the world is saved and loaded; a new map server leads the Bar
	Wd.fire("load_state", md)
	MACHINES[BRIDGE] = nil
	local Mk2, MA2 = map_server()
	H = Mk2
	check(next(MA2._state().ledger) == nil, "a new map server knows nothing")
	Mk2.downs.arena_ledger.set(Wd.downs.arena_ledger.get())
	check(ledger_for(MA2, PROXY) and #ledger_for(MA2, PROXY).items == 3, "it takes the world's copy")
	Mk2.downs.arena_ledger.set({ list = {} })
	check(ledger_for(MA2, PROXY) ~= nil, "a later copy does not undo it")
	for _, f in ipairs(Mk2.handlers["arena.out"] or {}) do f(Mk2.env.coop_main.encode({ _peer = 1 }), 0) end
	check(same(owned(PROXY), gear), "he comes back: his gear from box 1")
	local up2 = Mk2.ups.arena_ledger.get()
	check(up2 and up2.based == true and #up2.list == 0, "the empty ledger goes up as the truth")
	Wd.ups.arena_ledger.set(up2, 2)
	check(#WA._state().world_copy == 0, "the world server's copy is empty again")

	-- V3: an arena return before the Bar receives its first echo. The flush and the delayed echo
	-- must both preserve the deletion, even though the first up already advertised the row.
	local Mk3, MA3 = map_server()
	H = Mk3
	Mk3.env.xr_effects.bar_arena_teleport(Mk3.env.db.actor, Mk3.objects[TRIG])
	Wd.ups.arena_ledger.set(Mk3.ups.arena_ledger.get(), 2)
	local stale = Wd.downs.arena_ledger.get()
	for _, f in ipairs(Mk3.handlers["arena.out"] or {}) do f(Mk3.env.coop_main.encode({ _peer = 1 }), 0) end
	local flushed = Mk3.ups.arena_ledger.get()
	check(flushed ~= nil, "V3: the flush can send a return even before the first down share")
	if flushed then Wd.ups.arena_ledger.set(flushed, 2) end
	check(#Wd.downs.arena_ledger.get().list == 0, "V3: the world copy has no row after the return is flushed")
	local sent_before = #sent_named(Mk3, "arena.go")
	Mk3.downs.arena_ledger.set(stale)
	tick(Mk3, 16000)
	check(next(MA3._state().ledger) == nil and #sent_named(Mk3, "arena.go") == sent_before and same(owned(PROXY), gear),
		"V3: a delayed echo cannot give back the same gear or send a second way out")

	-- V4: model W6 applying the Bar's save_state before load_state on the next map server.
	local Mk4, MA4 = map_server()
	H = Mk4
	Mk4.env.xr_effects.bar_arena_teleport(Mk4.env.db.actor, Mk4.objects[TRIG])
	local kit = new_item("wpn_bm16", PROXY, "client")
	for _, f in ipairs(Mk4.handlers["arena.kit"] or {}) do
		f(Mk4.env.coop_main.encode({ _peer = 1, i = tostring(kit._id) }), 0)
	end
	Mk4.objects[PROXY]._pos = IN_ARENA
	tick(Mk4)
	Mk4.objects[PROXY]._pos = vec(146, 1, 70)
	tick(Mk4)
	local carried = {}
	Mk4.fire("save_state", carried)
	local Mk5, MA5 = map_server()
	H = Mk5
	Mk5.objects[PROXY]._pos = IN_ARENA
	Mk5.fire("load_state", carried)
	Mk5.downs.arena_ledger.set(first_echo)
	tick(Mk5, 16000)
	check(MA5._state().fight ~= nil and same(owned(BOX1), gear) and #sent_named(Mk5, "arena.go") == 0,
		"V4: a carried running fight stays active after the map restarts")
	Mk5.objects[PROXY]._pos = vec(146, 1, 70)
	local outside = new_item("bread", PROXY, "trader")
	W.infos.bar_arena_fight_3_done = true
	Mk5.env.xr_effects.bar_arena_teleport_2(Mk5.env.db.actor, nil)
	check(outside._parent == PROXY and kit._parent == BOX2 and #owned(BOX1) == 0,
		"V4: restored custody returns the kit and preserves an outside pickup when the fight ends")

	W.infos.bar_arena_fight_3_done = nil
	Mk5.env.xr_effects.bar_arena_teleport(Mk5.env.db.actor, Mk5.objects[TRIG])
	local before_retire = Mk5.ups.arena_ledger.get()
	Wd.ups.arena_ledger.set(before_retire, 2)
	Wd.fire("server_entity_on_unregister", Wd.env.alife_object(PROXY), "se_stalker")
	W.holders[PROXY] = nil
	check(#Wd.downs.arena_ledger.get().list == 0, "V5: the world server clears the retired character from its copy")
	Wd.ups.arena_ledger.set(before_retire, 2)
	check(#Wd.downs.arena_ledger.get().list == 0, "V5: an old Bar share cannot recreate the ledger of a released character")
end

-------------------------------------------------------------------------------
-- Arnie's monster fight (the old arena: dialog bar_arena_manager_game gives bar_arena_start; bar_arena_sr lets the fighter in
-- through bar_arena_waiter, bar_arena_spam counts). Its effects run on the host and show lines (news_manager.send_tip):
-- they are the fighter's alone; the infos they give stay the host's world's.
-------------------------------------------------------------------------------
local function tip_ids(M)
	local list = {}
	for _, t in ipairs(M.tips) do list[#list + 1] = t.id end
	return table.concat(list, ",")
end

local function countdown(xe, A, from, to)
	for n = from, to, 10 do xe["bar_arena_fight_" .. n](A, H.objects[SPAM]) end
end

print("== Arnie's monster fight: a client fights, the arena's lines are his alone")
do
	setup()
	local A, xe = H.env.db.actor, H.env.xr_effects
	A:give_info_portion("bar_arena_snork_choosen")
	A:give_info_portion("bar_arena_50_p")
	W.talked[1] = NOW
	H.logic_aud = { [PROXY] = true } -- he walked into bar_arena_waiter
	xe.bar_arena_introduce(A, H.objects[SR])
	H.logic_aud = { [0] = true, [PROXY] = true }
	xe.bar_arena_fight_begin(A, H.objects[SPAM])
	countdown(xe, A, 10, 50)
	pump()
	check(tip_ids(Cm) == "bar_arena_fight_snork,bar_arena_fight_begin,bar_arena_fight_10,bar_arena_fight_20,bar_arena_fight_30,bar_arena_fight_40,bar_arena_fight_50",
		"the fighter gets every line: the introduction, \"the fight begins\", the countdown")
	check((Cm.tips[1] or {}).s == "arena" and (Cm.tips[1] or {}).st == 30000 and (Cm.tips[2] or {}).s == "arena", "with the stock icon and time")
	check(#H.tips == 0, "the host's screen shows none of them")
	check(H.stock_tips == 7 and Cm.stock_tips == 0, "the stock effects run on the host alone")
	xe.bar_arena_after_fight(A, H.objects[SPAM])
	pump()
	check((Cm.tips[#Cm.tips] or {}).id == "bar_arena_fight_victory" and #H.tips == 0, "\"victory\" is his too")
	check(A:has_info("bar_arena_actor_victory") and A:has_info("bar_arena_start_introduce"), "the infos are the host's world's")
	check(next(Cm.env.db.actor._info) == nil, "the client's own actor is given none")
	check(HA._state().pit == nil, "the fight is over: its fighter is forgotten")
end

print("== Arnie's monster fight: time is up for the client")
do
	setup()
	local A, xe = H.env.db.actor, H.env.xr_effects
	A:give_info_portion("bar_arena_bloodsucker_choosen")
	A:give_info_portion("bar_arena_50_p")
	W.talked[1] = NOW
	H.logic_aud = { [PROXY] = true }
	xe.bar_arena_introduce(A, H.objects[SR])
	H.logic_aud = { [0] = true, [PROXY] = true }
	xe.bar_arena_fight_begin(A, H.objects[SPAM])
	countdown(xe, A, 10, 90)
	A:give_info_portion("bar_arena_fight_90") -- the ltx's +bar_arena_fight_90 before =bar_arena_check_lose
	xe.bar_arena_check_lose(A, H.objects[SPAM])
	pump()
	check((Cm.tips[#Cm.tips] or {}).id == "bar_arena_fight_timeout" and #Cm.tips == 12, "\"time is up\" is the fighter's, after the whole countdown")
	check(#H.tips == 0, "the host sees none")
	check(A:has_info("bar_arena_actor_lose") and next(Cm.env.db.actor._info) == nil, "the loss is the host's world's info")
	xe.bar_arena_after_fight(A, H.objects[SPAM]) -- the monster dies later: lost, stock says nothing
	pump()
	check(#Cm.tips == 12 and #H.tips == 0 and HA._state().pit == nil, "nothing more is said, the fighter is forgotten")
end

print("== Arnie's monster fight: the host fights, the client sees none of it")
do
	setup()
	local A, xe = H.env.db.actor, H.env.xr_effects
	-- a client's fight that never ended (he fell, no end came): its fighter must not stick
	W.talked[1] = NOW
	H.logic_aud = { [PROXY] = true }
	xe.bar_arena_introduce(A, H.objects[SR])
	pump()
	check(HA._state().pit and HA._state().pit.id == PROXY, "the client walked in: he is the fighter")
	NOW = NOW + 120000
	A:give_info_portion("bar_arena_pseudodog_choosen")
	H.logic_aud = { [0] = true }
	xe.bar_arena_introduce(A, H.objects[SR])
	H.logic_aud = { [0] = true, [PROXY] = true }
	xe.bar_arena_fight_begin(A, H.objects[SPAM])
	countdown(xe, A, 10, 10)
	xe.bar_arena_actor_dead(A, H.objects[SR])
	pump()
	check(tip_ids(H) == "bar_arena_fight_pseudodog,bar_arena_fight_begin,bar_arena_fight_10,bar_arena_fight_dead",
		"the host walked in: every line is on his screen, \"dead\" too")
	check(#Cm.tips == 0, "the client sees none of them")
	check(#sent_named(H, "arena.go") == 0, "nothing is sent for the host's own fight")
	check(HA._state().pit == nil, "he is dead: the fight forgets him")
end

print("== nobody walked in: \"you are afraid\" goes to the one who talked to Arnie")
do
	setup()
	local A, xe = H.env.db.actor, H.env.xr_effects
	H.env.db.actor._pos = vec(149, 1, 75) -- the host stands at Arnie, the client talked to him
	W.talked[1] = NOW
	H.logic_aud = {} -- bar_arena_sr's 60 s timer: nobody is inside
	xe.bar_arena_actor_afraid(A, H.objects[SR])
	pump()
	check(tip_ids(Cm) == "bar_arena_actor_afraid" and #H.tips == 0, "the client who asked for the fight hears it, the host does not")
end

print("== a line with no fighter known (a load in the middle): the player in the arena")
do
	setup()
	local A, xe = H.env.db.actor, H.env.xr_effects
	H.env.db.actor._pos = vec(149, 1, 75) -- the host is the nearest to Arnie
	H.objects[PROXY]._pos = vec(IN_ARENA.x, IN_ARENA.y, IN_ARENA.z) -- the client fights in the arena
	H.logic_aud = { [0] = true, [PROXY] = true }
	xe.bar_arena_fight_30(A, H.objects[SPAM])
	pump()
	check(tip_ids(Cm) == "bar_arena_fight_30" and #H.tips == 0, "the player standing in the arena gets it")
end

print("== the same on the real Bar: the monster fight is in the cage (bar_arena_sr), not in the pit's zone")
do
	setup()
	real_zones(H)
	local A, xe = H.env.db.actor, H.env.xr_effects
	H.env.db.zone_by_name.bar_arena_sr = boxed(H.objects[SR], 157.19, 0, 95.27, 17.33, 12.23, 20.86) -- all.spawn
	H.env.db.actor._pos = vec(149, 1, 75) -- the host is the nearest to Arnie
	H.objects[PROXY]._pos = vec(157, 0.5, 96) -- the client fights a monster in the cage
	H.logic_aud = { [0] = true, [PROXY] = true }
	xe.bar_arena_fight_30(A, H.objects[SPAM])
	pump()
	check(tip_ids(Cm) == "bar_arena_fight_30" and #H.tips == 0, "the player standing in the cage gets it")
end

print("== a mod replaces a line's effect after coop: the line still goes to the fighter")
do
	setup()
	local A = H.env.db.actor
	-- its own version, loaded after coop (no call to the one before)
	H.env.xr_effects.bar_arena_fight_begin = function(actor, npc)
		H.modded = true
		H.env.news_manager.send_tip(H.env.db.actor, "st_mod_odds", nil, "arena") -- a line of the mod's own
		H.env.news_manager.send_tip(H.env.db.actor, "bar_arena_fight_begin", nil, "arena")
	end
	tick(H)
	W.talked[1] = NOW
	H.logic_aud = { [PROXY] = true }
	H.env.xr_effects.bar_arena_introduce(A, H.objects[SR])
	H.env.xr_effects.bar_arena_fight_begin(A, H.objects[SPAM])
	pump()
	check(H.modded and tip_ids(Cm) == "bar_arena_fight_begin", "the mod runs, the arena's line is the client's")
	check(tip_ids(H) == "st_mod_odds", "a line that is not the arena's goes on as it would (the news relay judges it)")
end

-------------------------------------------------------------------------------
-- Arnie's monster fight: the fighter's death. bar_arena_sr in sr_idle@fight: on_info2 = {=actor_dead} sr_idle@nil
-- %=bar_arena_actor_dead +bar_arena_actor_dead +bar_arena_start_introduce%. xr_conditions.actor_dead reads db.actor, the
-- host's own character, and in a session nobody dies for the engine (a fallen player stays alive at 1 % health): no
-- fighter's death ever ended the fight, and the branch it would take ends in sr_idle@nil, for good (single player reloads).
-------------------------------------------------------------------------------
local MONSTER = 941
local IN_PIT = vec(150, -13, 95) -- bar_arena_sr's zone in this world

local function pit_setup()
	setup({ before_start = function()
		for _, M in ipairs({ H, Cm }) do
			M.cond_stock = 0
			M.env.xr_conditions = {
				actor_dead = function() M.cond_stock = M.cond_stock + 1; return not M.env.db.actor:alive() end,
			}
		end
		H.env.LIFE = {}
		H.env.coop.life_of = function(id) return H.env.LIFE[id] or "alive" end
		H.objects[SR]._radius = 8
		H.env.db.zone_by_name.bar_arena_sr = H.objects[SR]
		H.env.db.zone_by_name.bar_arena_spam = H.objects[SPAM]
		H.env.db.storage[SR] = { active_section = "sr_idle@fight",
			ini = make_ini({ ["sr_idle@idle"] = {}, ["sr_idle@wait_actor"] = {}, ["sr_idle@fight"] = {}, ["sr_idle@nil"] = {} }) }
		H.env.db.storage[SPAM] = { active_section = "sr_idle@notiming",
			ini = make_ini({ ["sr_idle@introduce"] = {}, ["sr_idle@notiming"] = {}, ["sr_idle@reset"] = {} }) }
		H.switched = {}
		H.env.xr_logic.switch_to_section = function(obj, _, s)
			H.switched[obj:id()] = s
			H.env.db.storage[obj:id()].active_section = s
			return true
		end
		H.given = {}
		H.env.give_info = function(i) W.infos[i] = true; H.given[#H.given + 1] = i end
		H.env.disable_info = function(i) W.infos[i] = nil end
		H.env.get_story_object_id = function(s)
			if s == "bar_arena_manager" then return MANAGER end
			if s == "bar_arena_snork" and H.monster then return MONSTER end
		end
		H.env.alife_object = function(id) return id == MONSTER and H.monster and { id = id } or nil end
		H.env.alife_release_id = function(id) H.monster_released = id; H.monster = nil end
	end })
	H.monster = true
	W.infos.bar_arena_start, W.infos.bar_arena_snork_choosen, W.infos.bar_arena_state_1 = true, true, true
	W.infos.bar_arena_50_p = true
end

-- The stock branch of bar_arena_sr's death, as the host runs it.
local function death_branch()
	H.env.xr_effects.bar_arena_actor_dead(H.env.db.actor, H.objects[SR])
	W.infos.bar_arena_actor_dead, W.infos.bar_arena_start_introduce = true, true
	H.env.db.storage[SR].active_section = "sr_idle@nil"
	pump()
end

local function pit_dead()
	return H.env.xr_conditions.actor_dead(H.env.db.actor, H.objects[SR])
end

print("== Arnie's monster fight: the host falls elsewhere while a client fights: the fight goes on")
do
	pit_setup()
	H.objects[PROXY]._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	check(pit_dead() == false, "the client fights in the arena")
	H.env.LIFE[0] = "dead"
	H.env.db.actor._alive = false -- the host's own character dead even for the engine
	NOW = NOW + 10000
	H.env.coop_npc_players.invalidate()
	check(pit_dead() == false and H.cond_stock == 0, "the host is dead elsewhere: not the fighter, the fight goes on")
	check(HA._state().pit and HA._state().pit.id == PROXY, "the player seen fighting in the arena is the fight's")
	H.env.db.actor._alive = true
	tick(H)
	check(H.switched[SR] == nil, "nothing to reset")
end

print("== a client fighter falls in the arena: down is not dead; his death ends the fight; the arena is back at its start")
do
	pit_setup()
	H.objects[PROXY]._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	check(pit_dead() == false, "he fights")
	H.env.LIFE[PROXY] = "wounded"
	NOW = NOW + 10000
	check(pit_dead() == false, "down: not dead yet")
	H.env.LIFE[PROXY] = "dead"
	NOW = NOW + 1000
	check(pit_dead() == false, "dead a moment ago: not yet (a teleport, a load)")
	NOW = NOW + 5000
	check(pit_dead() == true, "dead for 5 s: his death ends the fight, as in single player")
	death_branch()
	check(tip_ids(Cm) == "bar_arena_fight_dead" and #H.tips == 0, "\"dead\" is his line, not the host's")
	tick(H)
	check(H.switched[SR] == "sr_idle@idle" and H.switched[SPAM] == "sr_idle@introduce", "the arena is back at its start, not stuck in sr_idle@nil")
	check(H.monster_released == MONSTER, "the monster of that fight goes")
	check(H.given[1] == "bar_old_arena_reset" and W.infos.bar_arena_state_1 == nil, "the fight's infos are reset the stock way (bar_old_arena_reset)")
	check(not (W.infos.bar_arena_start or W.infos.bar_arena_snork_choosen or W.infos.bar_arena_actor_dead or W.infos.bar_arena_50_p),
		"and taken off one by one too, as dialogs_bar's arena_give_reward does (its cascade is known not to fire)")
	check(HA._state().pit == nil, "the fight forgets its fighter")
	H.switched = {}
	tick(H)
	check(next(H.switched) == nil and #H.given == 1, "once")
end

print("== a client fighter leaves the session in the middle: the fight ends")
do
	pit_setup()
	H.objects[PROXY]._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	check(pit_dead() == false, "he fights")
	H.objects[PROXY] = nil
	H.env.coop_npc_players.invalidate()
	NOW = NOW + 2000
	check(pit_dead() == false, "gone a moment ago: not yet")
	NOW = NOW + 4000
	check(pit_dead() == true, "gone for 5 s: the fight ends")
end

print("== the host fights and dies in the arena: the same")
do
	pit_setup()
	H.env.db.actor._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	check(pit_dead() == false, "the host fights")
	H.env.LIFE[0] = "dead"
	NOW = NOW + 6000
	check(pit_dead() == true, "his death ends it")
	death_branch()
	check(tip_ids(H) == "bar_arena_fight_dead" and #Cm.tips == 0, "\"dead\" on the host's screen")
	tick(H)
	check(H.switched[SR] == "sr_idle@idle", "the arena is back at its start")
end

print("== a load in the middle of the fight: the fighter is found in the arena, his death still ends it")
do
	pit_setup()
	H.objects[PROXY]._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	H.env.db.actor._pos = vec(149, 1, 75) -- the host stands at Arnie
	H.fire("load_state", {})
	check(HA._state().pit == nil, "after a load nothing is known")
	check(pit_dead() == false and HA._state().pit and HA._state().pit.id == PROXY, "the player in the arena is the fighter again")
	H.env.xr_effects.bar_arena_fight_30(H.env.db.actor, H.objects[SPAM])
	pump()
	check(tip_ids(Cm) == "bar_arena_fight_30" and #H.tips == 0, "the countdown is his")
	local md = {}
	H.fire("save_state", md)
	H.fire("load_state", md)
	check(HA._state().pit and HA._state().pit.id == PROXY, "the fighter is kept in the host's save")
	H.env.LIFE[PROXY] = "dead"
	pit_dead()
	NOW = NOW + 6000
	check(pit_dead() == true, "his death ends the fight")
end

print("== a new fight counts from its own start")
do
	pit_setup()
	H.objects[PROXY]._pos = vec(IN_PIT.x, IN_PIT.y, IN_PIT.z)
	H.env.db.storage[SR].activation_time = NOW
	check(pit_dead() == false, "the first fight: he is there")
	-- it ends (the monster dies); minutes later a new one starts, and its first look finds nobody in the zone yet
	NOW = NOW + 180000
	H.env.db.storage[SR].activation_time = NOW
	H.objects[PROXY]._pos = vec(152, 0, 80)
	H.env.coop_npc_players.invalidate()
	check(pit_dead() == false, "the old fight's last look does not count for the new one")
	NOW = NOW + 6000
	check(pit_dead() == true, "nobody for 5 s in the new one: over")
end

print("== a world saved with the old arena broken (sr_idle@nil after a death, before this fix) is repaired")
do
	pit_setup()
	H.env.db.storage[SR].active_section = "sr_idle@nil"
	tick(H)
	check(next(H.switched) == nil and #H.given == 0, "sr_idle@nil that no death led to: not ours, left alone")
	W.infos.bar_arena_actor_dead = true
	tick(H)
	check(H.switched[SR] == "sr_idle@idle" and H.switched[SPAM] == "sr_idle@introduce" and H.given[1] == "bar_old_arena_reset", "the arena is back at its start")
end

print("== another restrictor asking actor_dead: stock")
do
	pit_setup()
	H.env.db.actor._alive = false
	check(H.env.xr_conditions.actor_dead(H.env.db.actor, H.objects[TRIG]) == true and H.cond_stock == 1, "stock answers")
	H.env.db.actor._alive = true
	check(H.env.xr_conditions.actor_dead(H.env.db.actor, nil) == false and H.cond_stock == 2, "no restrictor: stock")
end

print("== single player: stock, untouched")
do
	reset_world()
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {} }
	H = machine("single", 9, {})
	Cm = nil
	holder(H, H.env.db.actor, 0)
	holder(H, H.add(make_obj(BOX1, 149, 1, 72)), BOX1)
	holder(H, H.add(make_obj(BOX2, 139, -13.4, 90.2)), BOX2)
	env(H)
	host_alife(H)
	for _, s in ipairs({ "exo_outfit", "wpn_ak74" }) do new_item(s, 0, "start") end
	local gear = owned(0)
	H.env.xr_conditions = { actor_dead = function() return not H.env.db.actor:alive() end }
	local sr = H.add(make_obj(SR, 150, -13, 95, { _name = "bar_arena_sr", _radius = 8 }))
	H.env.db.zone_by_name.bar_arena_sr = sr
	H.env.db.storage[SR] = { active_section = "sr_idle@nil", ini = make_ini({ ["sr_idle@fight"] = {}, ["sr_idle@nil"] = {} }) }
	H.env.xr_logic.switch_to_section = function() H.sp_switched = true end
	HA = load_script(H, "coop_arena")
	HA.on_game_start()
	H.env.db.actor._alive = false
	check(H.env.xr_conditions.actor_dead(H.env.db.actor, sr) == true, "the old arena's death condition is stock")
	H.env.db.actor._alive = true
	W.infos.bar_arena_actor_dead = true
	H.fire("actor_on_update")
	check(H.sp_switched == nil, "and its sr_idle@nil stays: single player reloads")
	W.infos.bar_arena_actor_dead = nil
	W.infos.bar_arena_fight_1 = true
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, nil)
	check(H.ran[1] == "in" and same(owned(BOX1), gear) and #owned(0) == 4, "the way in is stock: gear in box 1, the kit on him")
	H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, nil)
	check(same(owned(0), gear) and #owned(BOX2) == 4 and H.purges == 1, "the way out is stock")
	local A = H.env.db.actor
	A:give_info_portion("bar_arena_snork_choosen")
	H.env.xr_effects.bar_arena_introduce(A, nil)
	H.env.xr_effects.bar_arena_fight_begin(A, nil)
	H.env.xr_effects.bar_arena_after_fight(A, nil)
	check(tip_ids(H) == "bar_arena_fight_snork,bar_arena_fight_begin,bar_arena_fight_victory" and #H.sent == 0,
		"the monster fight's lines are stock, on his screen")
	check(A:has_info("bar_arena_actor_victory"), "and its infos")
end

print("== split levels: the Bar's map server is the authority")
do
	reset_world()
	NOW = NOW + 1000000
	local BRIDGE = 0x101
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {} }
	H = machine("client", BRIDGE, { [1] = PROXY })
	H.env.coop.is_map_server = function() return true end
	H.env.coop.is_mirror = function() return false end
	Cm = nil
	holder(H, H.env.db.actor, 0) -- its ghost
	H.env.db.actor._pos = vec(149, 1, 74) -- right at Arnie: a ghost is nobody
	holder(H, H.add(make_obj(PROXY, 148, 1, 72)), PROXY)
	H.add(make_obj(TRIG, 152.9, 0.5, 70.5, { _name = "bar_arena_triger" }))
	H.add(make_obj(MANAGER, 149, 1, 74))
	holder(H, H.add(make_obj(BOX1, 149, 1, 72)), BOX1)
	holder(H, H.add(make_obj(BOX2, 139, -13.4, 90.2)), BOX2)
	env(H)
	host_alife(H)
	for _, s in ipairs({ "stalker_outfit", "wpn_abakan" }) do new_item(s, PROXY, "start") end
	local gear = owned(PROXY)
	HA = load_script(H, "coop_arena")
	HA.on_game_start()
	W.infos.bar_arena_fight_3 = true
	local aud = H.rule(H.objects[TRIG])
	check(aud and aud[PROXY] == true and aud[0] == nil, "the map server picks the player at Arnie, never its ghost")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	local go = sent_named(H, "arena.go")
	check(same(owned(BOX1), gear) and #go == 1 and go[1].target == 1, "his gear in box 1 there, the way in sent to him")
	-- his respawn: the world server passes his request on to the map server of his level
	QUEUE = {}
	for _, f in ipairs(H.handlers["arena.out"] or {}) do f(H.env.coop_main.encode({ _peer = 1 }), 0) end
	check(same(owned(PROXY), gear), "his request through the world server: his gear back on the Bar's map server")
	-- Arnie's monster fight on the map server: its lines go to the player, never to the ghost's screen
	H.add(make_obj(SR, 150, -13, 95, { _name = "bar_arena_sr" }))
	H.env.db.actor:give_info_portion("bar_arena_snork_choosen")
	H.logic_aud = { [PROXY] = true }
	QUEUE = {}
	H.sent = {}
	H.env.xr_effects.bar_arena_introduce(H.env.db.actor, H.objects[SR])
	local tips = sent_named(H, "arena.go")
	local t = tips[1] and H.env.coop_main.decode(tips[1].payload) or {}
	check(#tips == 1 and tips[1].target == 1 and t.f == "tip" and t.a == "bar_arena_fight_snork" and t.st == 30000,
		"the line goes to the fighter's peer")
	check(#H.tips == 0, "the map server's ghost shows nothing")
end

-------------------------------------------------------------------------------
-- Live 2026-11-07 (host + one client): "the host took the fight, the client was sent in". The fighter is the one who talked
-- to Arnie last (coop.talk_recent, coop_dialog.cpp); the host's own talk was never remembered when it ended (its window
-- closed, dialogs.break_dialog right after the fight was taken), so a client who talked to Arnie in the last 60 s won.
print("== the host's own talk with Arnie is remembered like a client's (engine: coop_dialog.cpp)")
do
	local f = io.open("engine/src/xrGame/coop/coop_dialog.cpp", "rb")
	local src = f and f:read("*a")
	if f then f:close() end
	if not src then
		print("  note: engine/src/xrGame/coop/coop_dialog.cpp not found, the talk memory is not cross-checked")
	else
		src = src:gsub("\r\n", "\n")
		local function body(name) return src:match("\n[%w_:]+ " .. name .. "%([^)]*%)\n(%b{})") end
		local _, left_from = src:find("\nvoid on_peer_left%([^)]*%)\n")
		local left = body("on_peer_left") or ""
		local left_to = left_from and left_from + #left or -1
		-- every lock that ends goes to the memory (note_ended) in the block that drops it; a player who leaves takes his
		-- memory with him (on_peer_left)
		local drops, silent = 0, {}
		for pos in src:gmatch("()g_locks%.erase%(") do
			if not (left_from and pos > left_from and pos < left_to) then
				drops = drops + 1
				local head = src:sub(1, pos)
				local open = head:match(".*(){") or 1
				if not head:sub(open):find("note_ended(", 1, true) then
					local line = select(2, head:gsub("\n", "")) + 1
					silent[#silent + 1] = "line " .. line
				end
			end
		end
		check(drops >= 5, "coop_dialog.cpp drops locks in five places at least (" .. drops .. ")")
		check(#silent == 0, "every dropped talk lock is remembered (note_ended), the host's own too; silent: " .. table.concat(silent, ", "))
		check((body("on_talk_window_closed") or ""):find("note_ended(kHostPeer", 1, true) ~= nil,
			"the host's talk window closes: his talk is remembered (kHostPeer)")
		check((body("host_frame") or ""):find("note_ended(kHostPeer", 1, true) ~= nil,
			"the host's talk ends without the window: remembered as well")
		check(left:find("g_recent.erase(id)", 1, true) ~= nil, "a player who leaves takes his talks with him")
	end
end

print("== the host took the fight from Arnie; the client is nearer and talked to him 30 s ago: the host fights")
do
	-- the engine before the fix: the host's ended talk was not there; the client's was -> the client (the live report)
	setup()
	W.talked[0], W.talked[1] = nil, NOW - 30000
	local aud = start(1)
	check(aud and aud[PROXY] == true and aud[0] == nil, "model of the old engine: the client goes in (the report)")
	-- the engine now: the host's talk ended half a second ago, the client's 30 s ago
	setup()
	local client_gear = owned(PROXY)
	W.talked[0], W.talked[1] = NOW - 500, NOW - 30000
	check(H.env.db.actor._pos:distance_to(H.objects[MANAGER]._pos) > H.objects[PROXY]._pos:distance_to(H.objects[MANAGER]._pos),
		"the client stands nearer to Arnie")
	aud = start(1)
	check(aud and aud[0] == true and aud[PROXY] == nil, "the host talked last: he fights, not the nearer client")
	check(H.cut_in == 1 and (Cm.cut_in or 0) == 0 and same(owned(PROXY), client_gear), "the host goes in, the client keeps his gear")
	-- and the swap: the client talked last, the host stands nearer
	setup()
	H.env.db.actor._pos = vec(149, 1, 73)
	W.talked[0], W.talked[1] = NOW - 30000, NOW - 500
	aud = start(1)
	-- the host stands at Arnie and the taker is in: everybody on the Bar is there, both go in (group entry); the taker is the client
	check(aud and aud[PROXY] == true and HA._state().fight.id == PROXY, "the client talked last: he takes the fight, not the nearer host")
end

-------------------------------------------------------------------------------
-- Live 2026-11-07: a client fighter lost reputation for killing his arena opponent (attempt 2: the host took fight 2, the
-- client fought it), and did not in attempt 5 (he took the fight himself). A player's kill is counted by his own machine:
-- its actor killed the NPC there (coop_remote.cpp on_host_death: KillEntity with the local killer), so stock runs the actor
-- branch there, game_statistics.increment_reputation, which spares him while that machine has bar_arena_fight (the world's
-- info, the host's copy synced). Stock takes bar_arena_fight off when Arnie's prize is collected
-- (dialogs_bar.new_arena_give_reward), in single player always after the fight; in a session anybody may collect a waiting
-- prize while another player fights. The host's NPC branch for the client's character (increment_npc_reputation on the
-- proxy) never reaches the client: coop_story.cpp progress_frame puts the client's own value back on the proxy.
-- game_statistics.script:194-219, 284-345, dialogs.script:1823, dialogs_bar.script:48-120, 166-199 of Anomaly 1.5.3, ported
-- (the faction pick of a kill fixed to neutral: actor_stalker -> arena_enemy is 0 in game_relations.ltx; the elseif chains
-- of the prizes as loops).
local function stock_statistics(M)
	local E = M.env
	local gs = {
		actor_statistics = {
			killed_stalkers = { count = 0, rank = 0, rept = 0 },
			killed_stalkers_n = { count = 0, rank = 0, rept = -75 },
			arena_battles = { count = 0, rank = 0, rept = 0 },
		},
		npc_statistics = {
			killed_stalkers = { save = true, rank = 0, rept = 0 },
			killed_stalkers_n = { save = false, rank = 0, rept = -75 },
		},
	}
	E.game_statistics = gs
	E.IsStalker = function() return true end
	E.alife_object = function() return nil end
	function gs.increment_rank(value)
		local a = E.db.actor
		a:set_character_rank(a:character_rank() + (value or 0))
	end
	function gs.increment_npc_rank(npc, value)
		if (not npc) then return end
		npc:set_character_rank(npc:character_rank() + (value or 0))
	end
	function gs.increment_reputation(value)
		-- Fix for arena causing reputation changes
		if E.has_alife_info("bar_arena_fight") then
			return
		end
		local a = E.db.actor
		a:set_character_reputation(a:character_reputation() + (value or 0))
		if (a:character_reputation() < -4000) then a:set_character_reputation(-4000) end
		if (a:character_reputation() > 4000) then a:set_character_reputation(4000) end
	end
	function gs.increment_npc_reputation(npc, value)
		if (not npc) then return end
		npc:set_character_reputation(npc:character_reputation() + (value or 0))
	end
	function gs.increment_statistic(value, custom_rank, custom_rept)
		local statistic = value and gs.actor_statistics[value] or nil
		if (statistic and statistic.count and statistic.rank and statistic.rept) then
			statistic.count = statistic.count + 1
			gs.increment_rank(custom_rank or statistic.rank)
			gs.increment_reputation(custom_rept or statistic.rept)
		end
	end
	function gs.increment_npc_statistic(npc, value, custom_rank, custom_rept)
		local statistic = value and gs.npc_statistics[value] or nil
		if (npc and E.IsStalker(npc) and npc:alive() and statistic and statistic.rank and statistic.rept) then
			gs.increment_npc_rank(npc, custom_rank or statistic.rank)
			gs.increment_npc_reputation(npc, custom_rept or statistic.rept)
		end
	end
	function gs.npc_on_death_callback(victim, killer)
		if not (killer and victim) then return end
		local id = killer:id()
		local stat = "killed_stalkers_n"
		if (id == E.AC_ID) then
			gs.increment_statistic("killed_stalkers")
			gs.increment_statistic(stat)
		else
			gs.increment_npc_statistic(killer, "killed_stalkers")
			gs.increment_npc_statistic(killer, stat)
		end
	end
	return gs
end

local PRIZE = { 1000, 2000, 3000, 4000, 6000, 8000, 10000, 10000 }

local function stock_prizes(M)
	local E = M.env
	local A = E.db.actor
	A._money = A._money or 0
	-- the actor's infos are the world's (W.infos: the sync is not what is tested here)
	function A:give_info_portion(i) W.infos[i] = true end
	function A:disable_info_portion(i) W.infos[i] = nil end
	E.give_info = function(i) W.infos[i] = true end
	E.disable_info = function(i) W.infos[i] = nil end
	E.dialogs = {
		relocate_money_to_actor = function(first_speaker, second_speaker, num)
			E.db.actor._money = E.db.actor._money + num
		end,
	}
	E.dialogs_bar = {}
	function E.dialogs_bar.new_arena_give_reward(first_speaker, second_speaker)
		local m = 0
		for n = 1, 8 do
			if E.has_alife_info("bar_arena_fight_" .. n .. "_reward") then m = PRIZE[n] break end
		end
		E.dialogs.relocate_money_to_actor(first_speaker, second_speaker, m)
		E.db.actor:give_info_portion("bar_arena_reset")
		for n = 1, 8 do E.db.actor:disable_info_portion("bar_arena_fight_" .. n .. "_reward") end
		E.db.actor:disable_info_portion("bar_arena_fight")
		E.db.actor:disable_info_portion("bar_arena_fight_begin")
		E.game_statistics.increment_statistic("arena_battles")
	end
	function E.dialogs_bar.arena_give_reward(first_speaker, second_speaker)
		local m = 0
		for _, mon in ipairs({ "pseudodog", "snork", "bloodsucker", "burer", "savage" }) do
			if E.has_alife_info("bar_arena_" .. mon .. "_defeated") then m = m + 1000 end
		end
		local p = 0
		if E.has_alife_info("bar_arena_20_p") then p = 1.5 elseif E.has_alife_info("bar_arena_50_p") then p = 2
		elseif E.has_alife_info("bar_arena_100_p") then p = 3 end
		E.dialogs.relocate_money_to_actor(first_speaker, second_speaker, m * p)
		E.db.actor:give_info_portion("bar_old_arena_reset")
		for _, i in ipairs({ "bar_arena_start", "bar_arena_20_p", "bar_arena_50_p", "bar_arena_100_p", "bar_arena_actor_victory" }) do
			E.db.actor:disable_info_portion(i)
		end
		E.game_statistics.increment_statistic("arena_battles")
	end
end

-- reputation and rank on an object of the test world
local function traits(o, rep)
	o._rep, o._rank = rep or 0, o._rank or 0
	function o:character_reputation() return self._rep end
	function o:set_character_reputation(v) self._rep = v end
	function o:character_rank() return self._rank end
	function o:set_character_rank(v) self._rank = v end
	return o
end

-- the host ledger's money for a client's character (coop.money_grant): what it got
local function grants(M)
	M.granted = {}
	M.env.coop.money_grant = function(peer, n)
		M.granted[#M.granted + 1] = { peer = peer, n = n }
		return true
	end
	M.env.get_console = function() return { get_integer = function(_, k) if k == "coop_share_rewards" then return M.share or 0 end end } end
end

local function granted_to(M, peer)
	local n = 0
	for _, g in ipairs(M.granted) do if g.peer == peer then n = n + g.n end end
	return n
end

local function stats_setup()
	local gs, cgs
	setup({ before_start = function()
		gs = stock_statistics(H)
		cgs = stock_statistics(Cm)
		stock_prizes(H)
		stock_prizes(Cm)
		grants(H)
	end })
	traits(H.env.db.actor, 100)
	traits(H.objects[PROXY], 200)
	traits(H.objects[OPPONENT], 0)
	traits(Cm.env.db.actor, 200)
	return gs, cgs
end

-- fight n, its fighter the host (0) or the client (1); won: the trigger gave its prize
local function fought(n, who)
	W.talked[0], W.talked[1] = nil, nil
	W.talked[who] = NOW
	start(n)
	W.infos["bar_arena_fight_" .. n .. "_done"] = true
	H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
	pump()
	W.infos["bar_arena_fight_" .. n .. "_reward"] = true
end

print("== live attempt 2: the host took fight 2, the client fights it, fight 1's prize is collected meanwhile")
do
	local _, cgs = stats_setup()
	fought(1, 0) -- attempt 1: the host won fight 1, its prize waits
	W.talked[0], W.talked[1] = NOW - 30000, NOW
	start(2) -- the client fights fight 2
	W.infos.bar_arena_fight_begin = true -- his cutscene ended (sr_cutscene@fight_2: +bar_arena_fight_begin)
	check(W.infos.bar_arena_fight == true, "fight 2 runs: bar_arena_fight is on")
	local host_money = H.env.db.actor._money
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, H.objects[MANAGER]) -- the host, free at Arnie, collects
	pump()
	check(W.infos.bar_arena_fight == true and W.infos.bar_arena_fight_begin == true,
		"a prize collected during another player's fight keeps that fight's bar_arena_fight and bar_arena_fight_begin")
	check(W.infos.bar_arena_fight_1_reward == nil, "fight 1's prize is gone")
	check(H.env.db.actor._money == host_money + 1000, "fight 1 was the host's: its 1000 are his")
	cgs.npc_on_death_callback(H.objects[OPPONENT], Cm.env.db.actor) -- his own machine counts his kill
	check(Cm.env.db.actor._rep == 200, "the client's kill in fight 2 costs him nothing (" .. Cm.env.db.actor._rep .. ")")
end

print("== live attempt 5: the client took the fight himself, no prize collected meanwhile: no loss (control)")
do
	local _, cgs = stats_setup()
	fought(4, 0)
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, H.objects[MANAGER]) -- fight 4's prize before fight 5
	pump()
	W.talked[0], W.talked[1] = nil, NOW
	start(5)
	cgs.npc_on_death_callback(H.objects[OPPONENT], Cm.env.db.actor)
	check(Cm.env.db.actor._rep == 200, "no reputation change (" .. Cm.env.db.actor._rep .. ")")
	-- after the fight and its prize the exemption is off, as in stock: a kill costs again
	W.infos.bar_arena_fight_5_done, W.infos.bar_arena_fight_5_reward = true, true
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, H.objects[MANAGER])
	pump()
	check(W.infos.bar_arena_fight == nil, "no fight runs: the prize takes bar_arena_fight off (stock)")
	cgs.npc_on_death_callback(H.objects[OPPONENT], Cm.env.db.actor)
	check(Cm.env.db.actor._rep == 125, "outside the arena fight his kill is stock: -75 (" .. Cm.env.db.actor._rep .. ")")
end

print("== the prize is the fighter's: the host collects a client's prize")
do
	local gs, cgs = stats_setup()
	fought(1, 1)
	local host_money = H.env.db.actor._money
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, H.objects[MANAGER])
	pump()
	check(H.env.db.actor._money == host_money, "the host gets nothing of it")
	check(granted_to(H, 1) == 1000, "the client's character gets 1000 through the host ledger (" .. granted_to(H, 1) .. ")")
	check(cgs.actor_statistics.arena_battles.count == 1 and gs.actor_statistics.arena_battles.count == 0,
		"the arena battle counts for the fighter, on his machine")
	check(W.infos.bar_arena_fight_1_reward == nil and W.infos.bar_arena_fight == nil, "the prize is gone, the next fight is open")
end

print("== the prize is the fighter's: a client collects the host's prize")
do
	local gs, cgs = stats_setup()
	fought(2, 0)
	local host_money, client_money = H.env.db.actor._money, Cm.env.db.actor._money
	Cm.env.dialogs_bar.new_arena_give_reward(Cm.env.db.actor, nil) -- his dialog runs on his machine
	pump()
	check(Cm.env.db.actor._money == client_money and granted_to(H, 1) == 0, "the client gets nothing of it")
	check(H.env.db.actor._money == host_money + 2000, "the host gets his 2000")
	check(gs.actor_statistics.arena_battles.count == 1 and cgs.actor_statistics.arena_battles.count == 0,
		"the arena battle counts for the host")
	check(W.infos.bar_arena_fight_2_reward == nil, "the prize is gone: the next fight is open")
end

print("== a prize of two fighters goes by the setting coop_share_rewards")
for _, c in ipairs({ { 0, 3000, 0 }, { 1, 1500, 1500 }, { 2, 1500, 1500 }, { 3, 3000, 3000 } }) do
	stats_setup()
	H.share = c[1]
	fought(3, 0)
	HA._state().prizes[3] = { 0, PROXY } -- a fight both went into
	local host_money = H.env.db.actor._money
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, H.objects[MANAGER])
	pump()
	check(H.env.db.actor._money - host_money == c[2] and granted_to(H, 1) == c[3],
		string.format("coop_share_rewards %d: the host (who collects) %d, the client %d (%d, %d)", c[1], c[2], c[3],
			H.env.db.actor._money - host_money, granted_to(H, 1)))
end

print("== Arnie's monster fight: its bet prize is the fighter's")
do
	stats_setup()
	W.talked[1] = NOW
	H.env.db.actor:give_info_portion("bar_arena_snork_choosen")
	H.logic_aud = { [PROXY] = true }
	H.env.xr_effects.bar_arena_introduce(H.env.db.actor, H.objects[SR])
	W.infos.bar_arena_snork_defeated, W.infos.bar_arena_50_p = true, true
	H.env.xr_effects.bar_arena_after_fight(H.env.db.actor, H.objects[SR])
	pump()
	local host_money = H.env.db.actor._money
	H.env.dialogs_bar.arena_give_reward(H.env.db.actor, H.objects[MANAGER])
	pump()
	check(H.env.db.actor._money == host_money and granted_to(H, 1) == 2000,
		"the client fought the snork: his 1000 x 2 (" .. granted_to(H, 1) .. ")")
end

print("== coop_debug off: no reputation line during an arena fight, the stock call stays unwrapped")
do
	local _, cgs = stats_setup()
	local stock = cgs.increment_reputation
	W.talked[1] = NOW
	start(3)
	W.infos.bar_arena_fight = nil
	Cm.log = {}
	cgs.npc_on_death_callback(H.objects[OPPONENT], Cm.env.db.actor)
	Cm.env.db.actor._rep = 175
	tick(Cm)
	local any = false
	for _, l in ipairs(Cm.log) do if l:find("reputation", 1, true) then any = true end end
	check(not any and cgs.increment_reputation == stock, "no line, game_statistics.increment_reputation is the stock's")
end

print("== coop_debug on: a reputation change of a player during an arena fight goes into his log with its source")
ARENA_DEBUG = true
do
	local _, cgs = stats_setup()
	W.talked[1] = NOW
	start(3)
	W.infos.bar_arena_fight = nil -- whatever took it off: the line says so
	Cm.log = {}
	cgs.npc_on_death_callback(H.objects[OPPONENT], Cm.env.db.actor)
	local line
	for _, l in ipairs(Cm.log) do if l:find("increment_reputation(-75)", 1, true) then line = l end end
	check(line ~= nil and line:find("bar_arena_fight off", 1, true) ~= nil and line:find("200 -> 125", 1, true) ~= nil,
		"the client's log: increment_reputation(-75), bar_arena_fight off, 200 -> 125")
	-- a change by the engine (an attack counted by the host, RelReputationDelta), not by game_statistics
	Cm.log = {}
	Cm.env.db.actor._rep = 175
	tick(Cm)
	line = nil
	for _, l in ipairs(Cm.log) do if l:find("125 -> 175", 1, true) then line = l end end
	check(line ~= nil and line:find("not game_statistics", 1, true) ~= nil, "a change from elsewhere: the log says it was not game_statistics")
	Cm.log = {}
	tick(Cm)
	local any = false
	for _, l in ipairs(Cm.log) do if l:find("reputation", 1, true) then any = true end end
	check(not any, "no change: no line")
end
ARENA_DEBUG = false

print("== the arena's prizes and reputation lines: single player is stock")
do
	reset_world()
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = { bar_arena_fight = true, bar_arena_fight_1_reward = true },
		talked = {}, created = {} }
	H = machine("single", 9, {})
	Cm = nil
	holder(H, H.env.db.actor, 0)
	env(H)
	local gs = stock_statistics(H)
	stock_prizes(H)
	traits(H.env.db.actor, 0)
	HA = load_script(H, "coop_arena")
	HA.on_game_start()
	H.env.dialogs_bar.new_arena_give_reward(H.env.db.actor, nil)
	check(H.env.db.actor._money == 1000 and W.infos.bar_arena_fight == nil and gs.actor_statistics.arena_battles.count == 1,
		"single player: the prize is stock")
	H.log = {}
	gs.increment_reputation(-75)
	check(H.env.db.actor._rep == -75 and #H.log == 0, "single player: reputation is stock, no line")
end

-------------------------------------------------------------------------------
-- Group entry (owner 2026-11-24, TZ R88 / 6.19, in place of the boxes and the vote of 2026-11-07: "the accept window as at a
-- transition: people walk up, and the one who decided to start holds F to go with those near"). A fight taken with other players
-- on the map waits (the trigger's sr_idle@wait_N holds, nobody's UI is taken). Every player on the map is told his part: the
-- starter at Arnie "lead" (the board and the key), away from Arnie "lead_far"; another player within 10 m of Arnie "with" (the
-- board, no key: step away not to go), farther "invite" (a reminder, a tip, a spot on Arnie). The starter holds the use key
-- (coop_hud_arena -> coop_arena.start_pressed -> arena.start): whoever stands within 10 m of Arnie then goes in, the starter
-- first. No window, no vote, never by itself: one who walked away (or never came) is not taken (the complaint: "it took the
-- one who pressed No"). Nobody else on the map: at once, as in single player.
local function view(A) return A.gather_view and A.gather_view() or nil end
-- the last "gather" the authority sent to `peer` (a player with no machine in the model), decoded
local function gather_sent(peer)
	local last
	for _, s in ipairs(H.sent) do
		if s.name == "arena.go" and s.target == peer then
			local t = H.env.coop_main.decode(s.payload)
			if t.f == "gather" then last = t end
		end
	end
	return last
end
local function no_window() return H.BOX == nil and Cm.BOX == nil end
local function ids_text(f) return table.concat(f and f.ids or {}, ",") end
local function idle_runs()
	H.idle_updates = 0
	H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = {} })
	return H.idle_updates
end
local function log_has(M, text)
	for _, line in ipairs(M.log) do if line:find(text, 1, true) then return true end end
	return false
end

print("== group entry (co-op): nobody else in the session: the fight starts at once, as in single player")
do
	setup({ start_as_is = true })
	local proxy = H.objects[PROXY]
	H.objects[PROXY] = nil -- his character is not on the Bar
	W.talked[0] = NOW
	local aud = start(1)
	check(aud and aud[0] == true and not HA._state().fight.hold, "no hold: the host's trigger effects are his at once")
	check(idle_runs() == 1, "the trigger's sr_idle@wait runs its timer (stock 1 s)")
	check(no_window() and view(HA) == nil, "no window, no board")
	H.objects[PROXY] = proxy
end

print("== group entry (co-op): three players; the host takes the fight at Arnie, the client stands 8 m from Arnie, the third 30 m away")
do
	setup({ start_as_is = true, third = true })
	local host_gear, client_gear, third_gear = owned(0), owned(PROXY), owned(THIRD)
	H.env.db.actor._pos = vec(149, 1, 76) -- 2 m from Arnie
	H.objects[PROXY]._pos = vec(149, 1, 82) -- 8 m
	Cm.env.db.actor._pos = vec(149, 1, 82)
	H.objects[THIRD]._pos = vec(149, 1, 104) -- 30 m
	W.talked[0] = NOW
	local aud = start(1)
	local f = HA._state().fight
	check(f and f.hold == true and aud and next(aud) == nil, "held: the trigger's disable_ui goes to nobody")
	tick(H)
	pump()
	check(no_window(), "no window for anybody (the boxes 'start alone' / 'start without the others' are gone)")
	local hv, cv, tv = view(HA), view(CA), gather_sent(2)
	check(hv and hv.a == "lead" and hv.n == 1 and hv.c == 2 and hv.t == 3,
		"the host at Arnie: the board with the key, 2 of 3 near (" .. tostring(hv and hv.a) .. ")")
	check(cv and cv.a == "with" and cv.w == "p0" and cv.n == 1, "the client 8 m from Arnie: the board 'you go with p0', no key")
	check(tv and tv.a == "invite" and tv.w == "p0", "the third, 30 m away: invited (" .. tostring(tv and tv.a) .. ")")
	check(hv and #hv.near == 2 and hv.near[1] == 0 and hv.near[2] == 1 and #hv.far == 1 and hv.far[1] == 2,
		"the board's rows: near the host (first) and the client, far the third")
	for _ = 1, 30 do tick(H) end
	pump()
	check(HA._state().fight.hold == true and idle_runs() == 0 and (H.cut_in or 0) == 0 and #owned(BOX1) == 0,
		"30 s later nothing started by itself: only the starter's key starts it")
	press_start(HA)
	pump()
	f = HA._state().fight
	check(not f.hold and ids_text(f) == "0," .. PROXY, "the host held the key: he and the client go in, the third stays (" .. ids_text(f) .. ")")
	check(view(HA) == nil and view(CA) == nil and (gather_sent(2) or {}).a == "off", "the boards and the invitation are gone")
	check(H.ui_off == 1 and Cm.ui_off == 1, "both fighters lose the UI (stock disable_ui)")
	check(idle_runs() == 1, "the trigger goes on (its 1 s timer is long over: the cutscene at once)")
	aud = H.rule(H.objects[TRIG])
	check(aud[0] == true and aud[PROXY] == true and aud[THIRD] == nil, "the trigger's effects (enable_ui) are the two fighters'")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	check(#owned(BOX1) == #host_gear + #client_gear and same(owned(THIRD), third_gear), "both fighters' gear in box 1, the third's untouched")
	check(created_by("host", 0) == 4 and created_by("client", PROXY) == 4, "each fighter's kit is made by his own machine")
	check(#sent_named(H, "arena.go") > 0 and HA._state().fight.ids[1] == 0, "the starter is the first fighter")
end

print("== group entry (co-op): everybody at Arnie and nobody holds the key: no fight (the 'No' complaint)")
do
	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(146, 1, 70)
	Cm.env.db.actor._pos = vec(146, 1, 70)
	W.talked[0] = NOW
	start(1)
	for _ = 1, 20 do tick(H) end
	pump()
	local f = HA._state().fight
	check(f and f.hold == true and f.ids == nil, "taken with everybody at Arnie: it waits for the key, nobody goes by himself")
	check(idle_runs() == 0 and (Cm.cut_in or 0) == 0 and #owned(BOX1) == 0, "nobody's gear moved, no cutscene")
	check(no_window(), "no window, no vote")
end

print("== group entry (co-op): who steps away before the key is not taken; who comes after the start is not either")
do
	setup({ start_as_is = true, third = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(149, 1, 82)
	Cm.env.db.actor._pos = vec(149, 1, 82)
	H.objects[THIRD]._pos = vec(149, 1, 104)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	check(view(CA) and view(CA).a == "with", "the client at 8 m goes with the host")
	H.objects[PROXY]._pos = vec(149, 1, 85) -- 11 m: he walks away while the host holds the key
	Cm.env.db.actor._pos = vec(149, 1, 85)
	tick(H)
	pump()
	check(view(CA) and view(CA).a == "invite" and view(HA) and view(HA).c == 1, "11 m from Arnie: he is not near any more (the board says it)")
	press_start(HA)
	pump()
	local f = HA._state().fight
	check(not f.hold and ids_text(f) == "0", "the key: the host goes in alone (" .. ids_text(f) .. ")")
	H.objects[PROXY]._pos = vec(149, 1, 75)
	H.objects[THIRD]._pos = vec(149, 1, 73)
	tick(H)
	pump()
	check(ids_text(HA._state().fight) == "0" and view(CA) == nil, "the two who come after the start are not taken")
end

print("== group entry (co-op): only the starter's key starts it; a starter who is gone or down passes it to the one nearest to Arnie")
do
	setup({ start_as_is = true, third = true })
	H.env.db.actor._pos = vec(149, 1, 79) -- 5 m
	H.objects[PROXY]._pos = vec(149, 1, 76) -- the client took it, 2 m
	Cm.env.db.actor._pos = vec(149, 1, 76)
	H.objects[THIRD]._pos = vec(149, 1, 82) -- 8 m
	W.talked[1] = NOW
	start(2)
	tick(H)
	pump()
	check(view(CA) and view(CA).a == "lead" and view(HA) and view(HA).a == "with", "the client took it: he has the key, the host goes with him")
	press_start(HA)
	relay_start(2)
	pump()
	check(HA._state().fight.hold == true and log_has(H, "is not its starter"), "the host's and the third's key do nothing: they are not its starter")
	local proxy = H.objects[PROXY]
	H.objects[PROXY] = nil -- the starter leaves the session (his character goes off the map)
	tick(H)
	pump()
	check(HA._state().fight.id == 0 and view(HA) and view(HA).a == "lead" and view(HA).passed == true,
		"the starter is gone: the host, nearest to Arnie, can start it now (" .. tostring(HA._state().fight.id) .. ")")
	check(log_has(H, "can start it now"), "one line in the log says who took the key over")
	H.objects[PROXY] = proxy
	local life = { [0] = "wounded" }
	H.env.coop.life_of = function(id) return life[id] or "alive" end
	tick(H)
	pump()
	check(HA._state().fight.id == PROXY or HA._state().fight.id == THIRD, "the host is down: the key goes on to one standing at Arnie")
	local starter = HA._state().fight.id
	if starter == PROXY then press_start(CA) else relay_start(2) end
	pump()
	local f = HA._state().fight
	check(not f.hold and f.ids[1] == starter and f.ids[2] ~= 0 and #f.ids == 2, "the new starter's key: the two standing at Arnie go in, not the one who is down (" .. ids_text(f) .. ")")
	H.env.coop.life_of = nil
end

print("== group entry (co-op): the starter away from Arnie has no key, the board tells him to come back")
do
	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 104) -- 30 m
	H.objects[PROXY]._pos = vec(149, 1, 76)
	Cm.env.db.actor._pos = vec(149, 1, 76)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	check(view(HA) and view(HA).a == "lead_far" and view(CA) and view(CA).a == "with", "the host far from Arnie: 'come back', the client near: 'with'")
	press_start(HA)
	pump()
	check(HA._state().fight.hold == true and log_has(H, "not at Arnie"), "his key away from Arnie does nothing")
	H.env.db.actor._pos = vec(149, 1, 76)
	tick(H)
	pump()
	check(view(HA) and view(HA).a == "lead", "back at Arnie: the key")
end

print("== group entry (co-op): the invited player gets one tip and the spot on Arnie; both go when the fight starts")
do
	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	local tips = #Cm.tips
	check(Cm.spot ~= nil and Cm.spot.id == MANAGER and tips == 1 and Cm.tips[1].id:find("p0", 1, true) ~= nil,
		"the client is invited: a tip with the host's nick and a map spot on Arnie")
	H.objects[PROXY]._pos = vec(149, 1, 90) -- he walks around, still away
	tick(H)
	pump()
	H.env.db.actor._pos = vec(149, 1, 104) -- the host steps away from Arnie and back: the client's board is told again
	tick(H)
	pump()
	H.env.db.actor._pos = vec(149, 1, 76)
	tick(H)
	pump()
	check(#Cm.tips == 1 and view(CA) and view(CA).c == 1, "one tip a fight, not one a message (" .. #Cm.tips .. ")")
	-- the review of R88: he walks up to Arnie ("with") and away again ("invite") three times; each way back was a new tip
	for _ = 1, 3 do
		H.objects[PROXY]._pos = vec(149, 1, 82) -- 8 m
		Cm.env.db.actor._pos = vec(149, 1, 82)
		tick(H)
		pump()
		check(view(CA) and view(CA).a == "with" and Cm.spot == nil, "at Arnie: he goes with the host, no spot")
		H.objects[PROXY]._pos = vec(149, 1, 90) -- 16 m
		Cm.env.db.actor._pos = vec(149, 1, 90)
		tick(H)
		pump()
	end
	check(view(CA) and view(CA).a == "invite" and Cm.spot ~= nil and Cm.spot.id == MANAGER,
		"away again: invited, the spot on Arnie is back")
	check(#Cm.tips == 1, "one tip a fight: walking away from Arnie and back gives none (" .. #Cm.tips .. ")")
	press_start(HA)
	pump()
	check(Cm.spot == nil and view(CA) == nil, "the spot and the reminder go at the start")
end

print("== group entry (co-op): two fighters, each his kit, his spot, his gear back; one falls, the other fights on")
do
	setup({ start_as_is = true })
	local host_gear, client_gear = owned(0), owned(PROXY)
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(146, 1, 70)
	Cm.env.db.actor._pos = vec(146, 1, 70)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	press_start(HA)
	pump()
	local f = HA._state().fight
	check(not f.hold and ids_text(f) == "0," .. PROXY, "the key: both go in, the taker first")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	H.cut, Cm.cut = H.new_cut(), Cm.new_cut()
	H.cut:zone_enter()
	Cm.cut:zone_enter()
	H.objects[PROXY]._pos = vector():set(Cm.env.db.actor:position())
	check(#owned(BOX1) == #host_gear + #client_gear, "both gears are in box 1")
	check(created_by("host", 0) == 4 and created_by("client", PROXY) == 4, "each his own kit, made by his own machine")
	check(H.cut_in == 1 and Cm.cut_in == 1, "both cutscenes play")
	check(at(H.env.db.actor, IN_ARENA) and not at(Cm.env.db.actor, IN_ARENA) and Cm.env.db.actor._pos:distance_to(IN_ARENA) < 4,
		"each at a spot of his own in the pit")
	check(HA._state().prizes[1] and #HA._state().prizes[1] == 2, "the fight's prize is both fighters'")
	H.env.xr_effects.bar_arena_weapon_slot(H.env.db.actor, H.objects[TRIG], { "2" })
	pump()
	check(H.env.db.actor._slot == 2 and Cm.env.db.actor._slot == 2, "the weapon slot is both fighters'")
	H.zone.saved_obj = { [OPPONENT] = true, [PROXY] = true }
	win(1)
	check(same(owned(0), host_gear) and same(owned(PROXY), client_gear), "won: each has exactly his own gear back")
	check(at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR), "both at the door")

	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(146, 1, 70)
	W.talked[0] = NOW
	start(1)
	tick(H)
	press_start(HA)
	pump()
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	check(#HA._state().fight.ids == 2, "two fighters")
	for _, fn in ipairs(H.handlers["arena.out"] or {}) do fn(H.env.coop_main.encode({}), 1) end
	pump()
	f = HA._state().fight
	check(f and ids_text(f) == "0", "the client falls and respawns: the fight goes on with the host")
	HA.fight_over()
	check(HA._state().fight == nil, "over")
end

print("== group entry (co-op): a load while the group gathers keeps it waiting for the key")
do
	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	W.talked[0] = NOW
	start(1)
	tick(H)
	local saved = {}
	H.fire("save_state", saved)
	H.fire("load_state", saved)
	tick(H)
	pump()
	local f = HA._state().fight
	check(f and f.hold == true and idle_runs() == 0 and view(HA) and view(HA).a == "lead", "after the load: held, the board and the key are back")
end

print("== group entry (co-op): no vote and no window module is asked")
do
	local asked, subj = nil, nil
	setup({ start_as_is = true, third = true, before_start = function()
		H.env.coop_economy_group = { subject = function(name) subj = name end, propose = function() asked = true return true end }
	end })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(149, 1, 82)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	press_start(HA)
	pump()
	check(subj == nil and asked == nil and no_window(), "coop_economy_group is not asked: no 'arena' vote, no window")
end

print("== group entry (server): the map server of the Bar gathers its own players; the key comes through the world server")
do
	local asked, subj = nil, nil
	setup({ answer = "srv_map", start_as_is = true, third = true, away = true, before_start = function()
		H.env.coop_economy_group = { subject = function(name) subj = name end, propose = function() asked = true return true end }
	end })
	H.objects[PROXY]._pos = vec(149, 1, 76) -- the taker at Arnie
	H.objects[THIRD]._pos = vec(149, 1, 82) -- 8 m
	W.talked[1] = NOW
	start(3)
	tick(H)
	pump()
	local f = HA._state().fight
	local mine, third, away = gather_sent(1), gather_sent(2), gather_sent(3)
	check(f and f.hold == true and f.id == PROXY, "held on the map server, the client took it")
	check(mine and mine.a == "lead" and mine.c == 2 and mine.t == 2, "the taker's board: the key, 2 of the 2 on the Bar near")
	check(third and third.a == "with", "the third at 8 m goes with him")
	check(away == nil, "the player on another map is not on the board and is not asked")
	relay_start(2)
	check(HA._state().fight.hold == true, "the third's key does nothing: he is not the starter")
	relay_start(1)
	f = HA._state().fight
	check(not f.hold and ids_text(f) == PROXY .. "," .. THIRD, "the taker's key through the world server: he and the third go in (" .. ids_text(f) .. ")")
	check(subj == nil and asked == nil, "no vote at the world server: coop_economy_group is not asked")
	local proposals = 0
	for _, s in ipairs(H.sent) do if tostring(s.name):find("propose", 1, true) then proposals = proposals + 1 end end
	check(proposals == 0, "nothing goes to the world server about the start")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	check(ledger_for(HA, PROXY) and ledger_for(HA, THIRD), "both fighters' gear stowed by the map server")
end

print("== group entry (server): who steps away before the key is not taken; one alone on the Bar starts at once")
do
	setup({ answer = "srv_map", start_as_is = true, third = true })
	H.objects[PROXY]._pos = vec(149, 1, 76)
	H.objects[THIRD]._pos = vec(149, 1, 82)
	W.talked[1] = NOW
	start(3)
	tick(H)
	H.objects[THIRD]._pos = vec(149, 1, 85) -- 11 m
	tick(H)
	relay_start(1)
	check(ids_text(HA._state().fight) == tostring(PROXY), "11 m from Arnie at the key: the third stays")

	setup({ answer = "srv_map", start_as_is = true })
	W.talked[1] = NOW
	local aud = start(3)
	check(aud and aud[PROXY] == true and not HA._state().fight.hold and gather_sent(1) == nil, "alone on the Bar: at once, no board")
end

print("== group entry (server): the world server has no Bar: a key that reaches it does nothing, nobody is told anything")
do
	reset_world()
	NOW = NOW + 1000000
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {}, client_seen = {} }
	local Wd = machine("host", 0, { [1] = PROXY })
	Wd.env.coop.is_dedicated = function() return true end
	Cm = nil
	H = Wd
	holder(Wd, Wd.env.db.actor, 0)
	env(Wd, "fake_start")
	host_alife(Wd)
	local WA = load_script(Wd, "coop_arena")
	WA.on_game_start()
	W.infos.bar_arena_fight_1, W.infos.bar_arena_fight = true, true -- a fight runs on the Bar's map server
	for _, f in ipairs(Wd.handlers["arena.start"] or {}) do f(Wd.env.coop_main.encode({}), 1) end
	tick(Wd)
	pump()
	check(WA._state().fight == nil and #sent_named(Wd, "arena.go") == 0 and view(WA) == nil,
		"no fight, no board, no message on the world server")
end

print("== the arena's strings: eng and rus, every id coop_arena and its board (coop_hud_arena) use")
do
	local function read(path)
		local f = io.open(path, "rb")
		local s = f and f:read("*a")
		if f then f:close() end
		return s
	end
	local board = read("gamedata/scripts/coop_hud_arena.script")
	check(board ~= nil, "the arena's board is its own script, coop_hud_arena")
	local src = (read("gamedata/scripts/coop_arena.script") or "") .. (board or "")
	local eng = read("gamedata/configs/text/eng/st_coop_arena.xml") or ""
	local rus = read("gamedata/configs/text/rus/st_coop_arena.xml") or ""
	local ids, n = {}, 0
	for id in src:gmatch('"(st_coop_arena_[%w_]+)"') do
		if not ids[id] then ids[id] = true n = n + 1 end
	end
	check(n >= 12, "coop_arena and its board name their strings (" .. n .. ")")
	check(not src:find('"st_coop_arena_vote_', 1, true) and not src:find('"st_coop_arena_solo"', 1, true)
		and not src:find('"st_coop_arena_without"', 1, true), "the vote's and the old buttons' strings are not used any more")
	local missing = {}
	for id in pairs(ids) do
		if not (eng:find('id="' .. id .. '"', 1, true) and rus:find('id="' .. id .. '"', 1, true)) then missing[#missing + 1] = id end
	end
	check(#missing == 0, "each is in st_coop_arena.xml, eng and rus: missing " .. table.concat(missing, ", "))
	check(rus:find('encoding="windows-1251"', 1, true) ~= nil and eng:find("\r\n", 1, true) ~= nil and rus:find("\r\n", 1, true) ~= nil,
		"rus is windows-1251, both CRLF")
end

print("== the rank gate after fights 3 and 6 reads the player who talks to Arnie (else the one nearest to him)")
do
	local xc = {}
	setup({ before_start = function()
		xc.bar_actor_rank_stalker = function() return H.env.db.actor:character_rank() > 1499 end
		xc.bar_actor_rank_veteran = function() return H.env.db.actor:character_rank() > 2999 end
		H.env.xr_conditions = xc
	end })
	H.env.db.actor.character_rank = function() return 100 end
	H.objects[PROXY].character_rank = function() return 2000 end
	H.env.coop.talk_holder = function(id) return id == MANAGER and 1 or nil end
	check(xc.bar_actor_rank_stalker(H.env.db.actor, H.objects[SR]) == true, "the client talks to Arnie: his rank 2000 is a stalker's")
	check(xc.bar_actor_rank_veteran(H.env.db.actor, H.objects[SR]) == false, "and not a veteran's")
	H.env.coop.talk_holder = function() return nil end
	H.env.db.actor._pos = vec(149, 1, 75)
	H.objects[PROXY]._pos = vec(130, 0, 90)
	check(xc.bar_actor_rank_stalker(H.env.db.actor, H.objects[SR]) == false, "nobody talks: the one nearest to Arnie (the host, 100)")
	H.objects[PROXY]._pos = vec(149, 1, 74)
	H.env.db.actor._pos = vec(120, 0, 100)
	check(xc.bar_actor_rank_stalker(H.env.db.actor, H.objects[SR]) == true, "the client nearest: his rank")
end

local function stage_fighter(answer, third)
	setup({ answer = answer, third = third })
	W.talked[1] = NOW
	W.infos.bar_arena_fight_3 = true
	-- The Bar authority stows his gear. Deliberately leave the "in" event in flight.
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
end

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" or answer == "srv_map" then
		print("== " .. answer .. ": give-back after a refused box-2 move")
		local fighter, parent, bout
		if answer == "hostplay" then
			setup()
			W.talked[0] = NOW
			start(1)
			fighter, parent, bout = 0, PROXY, 1
		else
			stage_fighter(answer, true)
			fighter, parent, bout = PROXY, THIRD, 3
			H.objects[fighter]._pos = IN_ARENA
		end
		local rec = assert(ledger_for(HA, fighter))
		local iid = rec.items[1]
		local item = W.items[iid]
		item._parent = fighter -- the online inventory still shows the item with the fighter
		local alife_object = H.env.alife_object
		H.env.alife_object = function(id)
			if id == iid then
				return { id = iid, parent_id = parent, section_name = function() return item:section() end }
			end
			return alife_object(id)
		end
		local owner = H.objects[fighter]
		local transfer_item = owner.transfer_item
		local refused = false
		function owner:transfer_item(it, to)
			if it:id() == iid and to:id() == BOX2 then -- server ownership already changed
				refused = true
				return
			end
			transfer_item(self, it, to)
		end
		H.zone.saved_obj = { [iid] = true, [OPPONENT] = true }
		win(bout)
		check(refused and released(H, OPPONENT), answer .. ": the refused transfer is followed by the arena purge")
		check(not released(H, iid), answer .. ": the purge leaves the other player's item intact")
		local detail = false
		for _, line in ipairs(H.log) do
			if line:find("item " .. iid .. " of ", 1, true) and line:find("not given back", 1, true)
				and line:find(item:section(), 1, true) and line:find("parent " .. parent, 1, true) then detail = true end
		end
		check(detail, answer .. ": the give-back line names the section and current server parent")
	end
end

local function load_travel(M)
	load_script(M, "coop_economy_core")
	load_script(M, "coop_economy_group")
	local travel = load_script(M, "coop_economy_travel")
	travel.on_game_start()
	return travel
end

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" or answer == "srv_map" then
		print("== R32 arena under " .. answer .. ": V1, win and group travel")
		stage_fighter(answer, true)
		check(HA._state().fight and HA._state().fight.id == PROXY and CA._state().mine == false,
			"V1: the authority lists the fighter before his machine sees arena.in")
		local travel = load_travel(H)
		load_travel(Cm)
		local trip = { x = 250, y = 0, z = 250 }
		local origin = H.env.db.actor:position()
		H.sent = {}
		travel.group_teleport(trip, nil, origin, -1, "travel")
		local offers = sent_named(H, "economy.tp")
		if answer == "hostplay" then
			check(#offers == 1 and offers[1].target == 2, "V1: only the unlisted player gets a trip offer")
		else
			check(#offers == 0, "V1: the map authority issues no group travel offer")
		end
		local bread = new_item("bread", PROXY, "trader")
		local after_offer = #sent_named(H, "arena.go")
		win(3)
		check(bread._parent == PROXY, "V1: a win leaves the never-inside fighter's bread with him")
		local events = sent_named(H, "arena.go")
		check(#events == after_offer + 1 and H.env.coop_main.decode(events[#events].payload).f == "none",
			"V1: the never-inside fighter gets his gear back without a way-out teleport")

		if answer == "hostplay" then
			setup()
			travel = load_travel(H)
			load_travel(Cm)
			travel.group_teleport(trip, nil, H.env.db.actor:position(), -1, "travel")
			pump()
			local offer = Cm.BOX
			check(offer ~= nil, "V1: the player can receive an offer before he is listed")
			W.talked[1] = NOW
			start(3)
			if offer then offer.ok() end
			check(at(Cm.env.db.actor, IN_ARENA), "V1: a trip offer already open cannot move him out of the pit")
		end

		stage_fighter(answer)
		local kit = new_item("wpn_bm16", PROXY, "client")
		local payload = H.env.coop_main.encode({ i = tostring(kit._id), _peer = 1 })
		for _, handler in ipairs(H.handlers["arena.kit"] or {}) do handler(payload, answer == "srv_map" and 0 or 1) end
		H.objects[PROXY]._pos = IN_ARENA
		tick(H)
		H.objects[PROXY]._pos = vec(146, 1, 70)
		tick(H)
		bread = new_item("bread", PROXY, "trader")
		win(3)
		check(kit._parent == BOX2 and bread._parent == PROXY, "V1: a loose fighter returns his kit and keeps his outside pickup")

		stage_fighter(answer)
		H.objects[PROXY]._pos = IN_ARENA -- position is already inside, even before the first tick
		local knife = new_item("wpn_knife", PROXY, "world")
		win(3)
		check(knife._parent == BOX2, "V1: a fighter in the pit still returns everything he holds there")

		-- gate WP16: his machine made the kit (its "in" came) but he never reached the pit: the kit is the arena's all the same
		for _, way in ipairs({ "win", "heal" }) do
			stage_fighter(answer)
			local own = owned(BOX1)
			local made = new_item("wpn_bm16", PROXY, "client")
			local tell = H.env.coop_main.encode({ i = tostring(made._id), _peer = 1 })
			for _, handler in ipairs(H.handlers["arena.kit"] or {}) do handler(tell, answer == "srv_map" and 0 or 1) end
			H.objects[PROXY]._pos = vec(146, 1, 70)
			tick(H)
			local found = new_item("bread", PROXY, "trader")
			if way == "win" then win(3) else tick(H, 16000) end
			check(made._parent == BOX2 and found._parent == PROXY and #owned(BOX1) == 0 and #owned(PROXY) == #own + 1,
				"gate WP16 (" .. way .. "): a never-inside fighter's kit goes back by its ids, his pickup stays, his gear comes back")
		end

		print("== R32 arena under " .. answer .. ": V2, a never-inside death and recovery")
		stage_fighter(answer)
		local gear = owned(BOX1)
		local medkit = new_item("medkit", PROXY, "friend")
		local bandage = new_item("bandage", BODY, "friend")
		tick(H)
		H.env.coop.life_of = function(id) return id == PROXY and "dead" or "alive" end
		H.fire("coop_death_marker", PROXY, BODY, "drop")
		tick(H)
		check(medkit._parent == PROXY, "V2: a never-inside death leaves held items with the fighter")
		check(bandage._parent == BODY, "V2: a never-inside death leaves the contents of his death stash alone")
		H.env.coop.life_of = function() return "alive" end
		tick(H, 20000)
		check(#gear == 6 and #owned(BOX1) == 0 and #owned(PROXY) == #gear + 1 and HA._state().fight == nil,
			"V2: the authority returns his stowed gear after the grace period, even with the fight info and no client ask")

		print("== R32 arena under " .. answer .. ": V5, retirement and a reused avatar id")
		stage_fighter(answer)
		local retired = H.env.alife_object(PROXY)
		H.fire("server_entity_on_unregister", retired, "se_stalker")
		H.objects[PROXY], W.holders[PROXY] = nil, nil
		local after_retire = {}
		H.fire("save_state", after_retire)
		check(not after_retire.coop_arena or #after_retire.coop_arena.ledger == 0,
			"V5: releasing the retired character clears the ledger immediately")

		stage_fighter(answer)
		local old = H.env.alife_object(PROXY)
		local saved = {}
		H.fire("save_state", saved)
		H.add(make_obj(PROXY, 146, 1, 70, { _section = "coop_player_avatar",
			_spawn_ini = make_ini({ coop = { { "key", string.rep("a", 64) } } }) }))
		holder(H, H.objects[PROXY], PROXY)
		H.fire("load_state", saved)
		HA.fight_over()
		tick(H, 16000)
		check(#owned(PROXY) == 0 and #owned(BOX1) == 6, "V5: a second character using the same avatar id cannot claim the first one's gear")
		H.fire("server_entity_on_unregister", old, "se_stalker")
		saved = {}
		H.fire("save_state", saved)
		check(not saved.coop_arena or #saved.coop_arena.ledger == 0, "V5: the retired character's ledger is gone from the save")

		stage_fighter(answer)
		saved = {}
		H.fire("save_state", saved)
		saved.coop_arena.ledger[1].character = nil -- the former save schema recorded only the avatar id
		H.env.coop_economy_mdata.player_value = function() return true end -- legacy gear flag was keyed by that same id
		QUEUE = {} -- packets from before the load belong to the old session
		H.fire("load_state", saved)
		win(3)
		check(#owned(PROXY) == 6 and #owned(BOX1) == 0 and ledger_for(HA, PROXY) == nil,
			"gate WP16: an id-only row of an older save is the character's under that id: his gear comes back")

		-- gate WP16: the same row on a heal after a load, with the fight over (his own ask came before the load)
		stage_fighter(answer)
		saved = {}
		H.fire("save_state", saved)
		saved.coop_arena.ledger[1].character = nil
		saved.coop_arena.fight = nil
		QUEUE = {}
		H.fire("load_state", saved)
		tick(H)
		local adopted = ledger_for(HA, PROXY)
		check(adopted and adopted.character ~= nil, "gate WP16: the first tick after the load gives the older row its character")
		local up_rows = {}
		H.fire("save_state", up_rows)
		check(up_rows.coop_arena and up_rows.coop_arena.ledger[1] and up_rows.coop_arena.ledger[1].character == adopted.character,
			"gate WP16: the adopted row is saved under its character")
		tick(H, 16000)
		check(#owned(PROXY) == 6 and #owned(BOX1) == 0 and ledger_for(HA, PROXY) == nil,
			"gate WP16: the heal gives an adopted row back once its player stands on the Bar")

		-- gate WP16: an id-only row whose id named no player character at the load (a retirement released it) is an orphan for
		-- good: a later character under that id, the same player's included, never gets it, and the save keeps it so
		stage_fighter(answer)
		saved = {}
		H.fire("save_state", saved)
		saved.coop_arena.ledger[1].character = nil
		saved.coop_arena.fight = nil
		H.objects[PROXY], W.holders[PROXY] = nil, nil
		QUEUE = {}
		H.fire("load_state", saved)
		tick(H)
		H.add(make_obj(PROXY, 146, 1, 70, { _section = "coop_player_avatar",
			_spawn_ini = make_ini({ coop = { { "key", string.format("%064x", PROXY) } } }) }))
		holder(H, H.objects[PROXY], PROXY)
		tick(H, 16000)
		local kept = {}
		H.fire("save_state", kept)
		check(#owned(PROXY) == 0 and #owned(BOX1) == 6 and kept.coop_arena and kept.coop_arena.ledger[1]
			and kept.coop_arena.ledger[1].orphan == true and kept.coop_arena.ledger[1].character == nil,
			"gate WP16: an orphan id-only row goes to nobody who takes the id later, and stays an orphan in the save")
		QUEUE = {}
		H.fire("load_state", kept)
		tick(H, 16000)
		check(#owned(PROXY) == 0 and #owned(BOX1) == 6, "gate WP16: after the next load the orphan still goes to nobody")

		if answer == "hostplay" then
			setup()
			W.talked[0] = NOW
			start(1)
			tick(H)
			H.fire("coop_host_new_character", 0)
			check(ledger_for(HA, 0) == nil and HA._state().mine == false and HA._state().fight == nil,
				"V5: the host's retirement clears his gear record although the actor id stays the same")
		end
	end
end

-------------------------------------------------------------------------------
-- R88 (owner 2026-11-24, b62): "the others who accepted had their own gear (not sure)" and "no way back when you kill the
-- opponent". The Bar has two script_zones with [arena_zone] (all.spawn of the stand): bar_arena, the pit, a box 35.76 x 3.73 x
-- 59.61 at (153.25, -19.46, 103.67), and bar_old_arena, the old monster cage 20 m above it, a box 17.1 x 10.08 x 19.33 at
-- (157.0, 0.1, 95.13), later in the file; xr_zones binds arena_zone_binder to both. coop_arena kept the last one spawned (the
-- cage): a fighter in the pit stood "outside the arena", so the heal gave his own gear back 15 s into the fight and took the kit
-- (RL-WJ2J-FCJW: "never entered the pit: the kit by its ids", "waited: given back"), and the win sent him "none": no way out.
-- The cutscene puts a fighter at t_way (151.82, -21.06, 75.3), inside the pit's box. The test world's zone was one ball that
-- t_way is not in (27.8 m from its centre), which hid it.
-------------------------------------------------------------------------------
local function lines_with(M, text)
	local n = 0
	for _, line in ipairs(M.log) do if line:find(text, 1, true) then n = n + 1 end end
	return n
end
local function last_go_to(peer)
	local last
	for _, s in ipairs(H.sent) do
		if s.name == "arena.go" and s.target == peer then last = H.env.coop_main.decode(s.payload).f end
	end
	return last
end
local function aside(v, k) return vec(v.x + k * 1.5, v.y, v.z) end

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" then
		for _, cage_first in ipairs({ false, true }) do
			print("== R88 co-op: two fighters stand in the pit at t_way; arena zones bar_arena and bar_old_arena"
				.. (cage_first and " (the cage spawns first)" or " (as in all.spawn: the cage spawns last)"))
			setup({ start_as_is = true })
			real_zones(H, cage_first)
			local host_gear, client_gear = owned(0), owned(PROXY)
			H.env.db.actor._pos = vec(149, 1, 76)
			H.objects[PROXY]._pos = vec(146, 1, 70)
			W.talked[0] = NOW
			start(3)
			tick(H)
			press_start(HA)
			pump()
			check(ids_text(HA._state().fight) == "0," .. PROXY, "co-op: the host and the client go in")
			H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
			pump()
			H.env.db.actor._pos = vector():set(T_WAY)
			H.objects[PROXY]._pos = aside(T_WAY, 1)
			Cm.env.db.actor._pos = aside(T_WAY, 1)
			local kit_host, kit_client = sections_of(0), sections_of(PROXY)
			for _ = 1, 16 do tick(H) end
			pump()
			check(ledger_for(HA, 0) and ledger_for(HA, PROXY) and lines_with(H, "waited: given back") == 0
				and lines_with(H, "never entered the pit") == 0, "co-op: 16 s into the fight in the pit: nobody's gear came back")
			check(sections_of(0) == kit_host and sections_of(PROXY) == kit_client and kit_client:find("wpn_bm16", 1, true) ~= nil,
				"co-op: both still hold the arena's kit (" .. kit_client .. ")")
			check(HA.print_status():find("zone bar_arena", 1, true) ~= nil, "co-op: the status names the zone it reads: bar_arena")
			H.zone.saved_obj = { [OPPONENT] = true }
			win(3)
			check(last_go_to(1) == "out", "co-op: the win sends the client the way out (" .. tostring(last_go_to(1)) .. ")")
			check(at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR), "co-op: both fighters are at the arena's door")
			check(same(owned(0), host_gear) and same(owned(PROXY), client_gear), "co-op: each has exactly his own gear back")
			check(sections_of(BOX2) == "ammo_12x70_buck,ammo_12x70_buck,ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,stalker_outfit,wpn_bm16,wpn_bm16",
				"co-op: both kits are in box 2 (" .. sections_of(BOX2) .. ")")
		end

		print("== R88 co-op: no zone named bar_arena here: a fighter whose cutscene ended is in the arena's custody all the same")
		setup({ before_start = function() H.zone.object._name = "some_other_zone" end })
		local client_gear = owned(PROXY)
		W.talked[1] = NOW
		start(3)
		Cm.cut.ended = true
		Cm.cut:update()
		pump()
		H.objects[PROXY]._pos = vector():set(T_WAY)
		for _ = 1, 16 do tick(H) end
		pump()
		check(ledger_for(HA, PROXY) ~= nil and lines_with(H, "waited: given back") == 0, "co-op: the zone unknown: the heal leaves a fighter in the fight alone")
		check(HA.print_status():find("zone -", 1, true) ~= nil and lines_with(H, "some_other_zone") > 0,
			"co-op: a zone of another name is not taken, the log says so")
		win(3)
		check(last_go_to(1) == "out" and at(Cm.env.db.actor, DOOR) and same(owned(PROXY), client_gear),
			"co-op: the win: the way out, his own gear (" .. tostring(last_go_to(1)) .. ")")
	elseif answer == "srv_map" then
		for _, cage_first in ipairs({ false, true }) do
			print("== R88 server: two fighters stand in the pit at t_way on the Bar's map server; zones bar_arena and bar_old_arena"
				.. (cage_first and " (the cage spawns first)" or " (as in all.spawn)"))
			setup({ answer = answer, start_as_is = true, third = true })
			real_zones(H, cage_first)
			local client_gear = owned(PROXY)
			H.objects[PROXY]._pos = vec(149, 1, 76)
			H.objects[THIRD]._pos = vec(146, 1, 70)
			W.talked[1] = NOW
			start(3)
			tick(H)
			relay_start(1)
			check(ids_text(HA._state().fight) == PROXY .. "," .. THIRD, "server: the client and the third go in")
			H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
			pump()
			H.objects[PROXY]._pos = vector():set(T_WAY)
			H.objects[THIRD]._pos = aside(T_WAY, 1)
			for _ = 1, 16 do tick(H) end
			pump()
			check(ledger_for(HA, PROXY) and ledger_for(HA, THIRD) and lines_with(H, "waited: given back") == 0
				and lines_with(H, "never entered the pit") == 0, "server: 16 s into the fight in the pit: nobody's gear came back")
			check(sections_of(PROXY) == "", "server: the client's own gear is still in box 1 (his kit is his machine's)")
			win(3)
			check(last_go_to(1) == "out" and last_go_to(2) == "out",
				"server: the win sends both fighters the way out (" .. tostring(last_go_to(1)) .. ", " .. tostring(last_go_to(2)) .. ")")
			check(same(owned(PROXY), client_gear) and #owned(BOX1) == 0, "server: the client has exactly his own gear back")
		end
	end
end

-------------------------------------------------------------------------------
-- R88, the review of 2026-11-24: the starter's character leaves the world while the group gathers (a hardcore death and a new
-- character: the host's coop_host_new_character, a client's avatar unregistered; or his ask arena.out after a respawn) and
-- nobody stands at Arnie. remove_fighter found no fighter left and ended the fight record (fight_over), the trigger's
-- sr_idle@wait_N was let go, its 1 s timer called %=bar_arena_teleport%, and route_in took the player picked anew (the one
-- nearest to Arnie) into the pit alone: without his key ("it took the one who did not want to"). The gathering waits: the key
-- goes to the one who stands at Arnie (pass_key), else it waits for him.
-------------------------------------------------------------------------------
-- The trigger's sr_idle@wait_N: its timer runs unless coop_arena holds it; when it runs, its on_timer calls %=bar_arena_teleport%
-- (stock bar_arena_triger.ltx). -> how many times it ran.
local function trigger_timer()
	local runs = idle_runs()
	if runs > 0 then
		H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
		pump()
	end
	return runs
end
local AWAY_FROM_ARNIE = vec(149, 1, 104) -- 30 m

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" then
		print("== R88 co-op: the host, the starter, takes a new character while the group gathers; nobody at Arnie: it waits for his key")
		setup({ start_as_is = true })
		local host_gear, client_gear = owned(0), owned(PROXY)
		H.env.db.actor._pos = vec(149, 1, 76)
		W.talked[0] = NOW
		start(1)
		tick(H)
		pump()
		check(HA._state().fight.hold == true and view(CA) and view(CA).a == "invite", "co-op: held, the client 25 m away is invited")
		H.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE) -- his new life starts away from Arnie
		H.fire("coop_host_new_character", 0)
		pump()
		for _ = 1, 3 do tick(H) end
		pump()
		local f = HA._state().fight
		local runs = trigger_timer()
		check(f ~= nil and f.hold == true and f.id == 0, "co-op: the gathering goes on, its starter is the host's character (" .. tostring(f and f.id) .. ")")
		check(runs == 0 and (H.cut_in or 0) == 0 and (Cm.cut_in or 0) == 0, "co-op: the trigger's timer stays held: nobody's cutscene")
		check(#owned(BOX1) == 0 and same(owned(0), host_gear) and same(owned(PROXY), client_gear) and not H.ui_off and not Cm.ui_off,
			"co-op: nobody is taken without his key: both keep their gear and their UI")
		check(view(HA) and view(HA).a == "lead_far" and view(CA) and view(CA).a == "invite", "co-op: the host is told to come back to Arnie")
		hold_start(0)
		check(ids_text(HA._state().fight) == "0", "co-op: back at Arnie, his own key: he goes in, the client stays (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 co-op: the client, the starter, leaves the world while the group gathers (his avatar is retired); the host is away")
		setup({ start_as_is = true })
		host_gear = owned(0)
		H.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		H.objects[PROXY]._pos = vec(149, 1, 76)
		Cm.env.db.actor._pos = vec(149, 1, 76)
		W.talked[1] = NOW
		start(1)
		tick(H)
		pump()
		check(view(CA) and view(CA).a == "lead" and view(HA) and view(HA).a == "invite", "co-op: the client has the key, the host 30 m away is invited")
		H.fire("server_entity_on_unregister", H.env.alife_object(PROXY), "se_stalker")
		H.objects[PROXY] = nil
		pump()
		for _ = 1, 3 do tick(H) end
		pump()
		f = HA._state().fight
		runs = trigger_timer()
		check(f ~= nil and f.hold == true and runs == 0 and (H.cut_in or 0) == 0,
			"co-op: the gathering waits, the trigger stays held (fight " .. tostring(f and f.n) .. ", timer ran " .. runs .. ")")
		check(#owned(BOX1) == 0 and same(owned(0), host_gear) and not H.ui_off, "co-op: the host, away from Arnie, is not taken")
		H.env.db.actor._pos = vec(149, 1, 76)
		tick(H)
		pump()
		check(HA._state().fight.id == 0 and view(HA) and view(HA).a == "lead" and view(HA).passed == true,
			"co-op: the host walks up to Arnie: the key is his now")
		hold_start(0)
		check(ids_text(HA._state().fight) == "0", "co-op: his own key: he goes in (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 co-op: the starter's ask for his gear (arena.out, a respawn) while the group gathers does not end it")
		setup({ start_as_is = true })
		H.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		H.objects[PROXY]._pos = vec(149, 1, 76)
		Cm.env.db.actor._pos = vec(149, 1, 76)
		W.talked[1] = NOW
		start(1)
		tick(H)
		for _, fn in ipairs(H.handlers["arena.out"] or {}) do fn(H.env.coop_main.encode({}), 1) end
		pump()
		tick(H)
		pump()
		f = HA._state().fight
		runs = trigger_timer()
		check(f ~= nil and f.hold == true and f.id == PROXY and runs == 0 and #owned(BOX1) == 0,
			"co-op: still held, the client still its starter, nobody taken (timer ran " .. runs .. ")")
	elseif answer == "srv_map" then
		print("== R88 server: the starter's avatar is retired on the Bar's map server while the group gathers; the third is away")
		setup({ answer = answer, start_as_is = true, third = true })
		local third_gear = owned(THIRD)
		H.objects[PROXY]._pos = vec(149, 1, 76)
		H.objects[THIRD]._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(3)
		tick(H)
		pump()
		check((gather_sent(1) or {}).a == "lead" and (gather_sent(2) or {}).a == "invite", "server: the client has the key, the third is invited")
		H.fire("server_entity_on_unregister", H.env.alife_object(PROXY), "se_stalker")
		H.objects[PROXY] = nil
		pump()
		for _ = 1, 3 do tick(H) end
		pump()
		local f = HA._state().fight
		local runs = trigger_timer()
		check(f ~= nil and f.hold == true and runs == 0,
			"server: the gathering waits, the trigger stays held (fight " .. tostring(f and f.n) .. ", timer ran " .. runs .. ")")
		check(ledger_for(HA, THIRD) == nil and same(owned(THIRD), third_gear) and #owned(BOX1) == 0,
			"server: the third, away from Arnie, is not taken")
		H.objects[THIRD]._pos = vec(149, 1, 76)
		tick(H)
		pump()
		local told = gather_sent(2) or {}
		check(HA._state().fight.id == THIRD and told.a == "lead" and told.p == 1, "server: the third walks up to Arnie: the key is his now")
		relay_start(2)
		pump()
		check(ids_text(HA._state().fight) == tostring(THIRD), "server: his own key: he goes in (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 server: the starter's ask for his gear (arena.out, a respawn) while the group gathers does not end it")
		setup({ answer = answer, start_as_is = true, third = true })
		H.objects[PROXY]._pos = vec(149, 1, 76)
		H.objects[THIRD]._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(3)
		tick(H)
		for _, fn in ipairs(H.handlers["arena.out"] or {}) do fn(H.env.coop_main.encode({ _peer = 1 }), 0) end
		pump()
		tick(H)
		pump()
		f = HA._state().fight
		runs = trigger_timer()
		check(f ~= nil and f.hold == true and f.id == PROXY and runs == 0 and ledger_for(HA, THIRD) == nil,
			"server: still held, the client still its starter, nobody taken (timer ran " .. runs .. ")")
	end
end

-------------------------------------------------------------------------------
-- R88, the review of 2026-11-24: branches of the change no test held (the reviewer's mutants lived): the host fighter's own
-- cutscene end (rec.cut) and its save; a fall and a death stash after a cutscene's end with no pit zone known; the boards'
-- "off" when the gathering ends unstarted and to a player who left the Bar; the passed key's chat line; the zone taken at a
-- purge (a binder that spawned before coop_arena's wrapper).
-------------------------------------------------------------------------------
local STASH_R88 = 779
local function no_pit_zone() H.zone.object._name = "some_other_zone" end
local function dies_at(id, pos)
	holder(H, H.add(make_obj(STASH_R88, pos.x, pos.y, pos.z, { _section = "coop_death_stash" })), STASH_R88)
	for _, iid in ipairs(owned(id)) do
		if W.items[iid]._section == "ammo_12x70_buck" then W.items[iid]._parent = STASH_R88 end
	end
	H.env.coop.life_of = function(x) return x == id and "dead" or "alive" end
	H.fire("coop_death_marker", id, STASH_R88, "drop")
	tick(H)
	pump()
	H.env.coop.life_of = function() return "alive" end
end
local function zones_before_wrapper()
	boxed(H.zone.object, 153.25, -19.46, 103.67, 35.76, 3.73, 59.61)
	local cls = H.env.xr_zones.arena_zone_binder
	local cage = setmetatable({ saved_obj = {},
		object = boxed(make_obj(931, 157.0, 0.1, 95.13, { _name = "bar_old_arena" }), 157.0, 0.1, 95.13, 17.1, 10.08, 19.33) },
		{ __index = cls })
	local before = HA.print_status():find("zone -", 1, true) ~= nil
	cage:purge_items()
	local cage_not = HA.print_status():find("zone -", 1, true) ~= nil
	H.zone:purge_items()
	return before, cage_not, HA.print_status():find("zone bar_arena", 1, true) ~= nil
end
local KIT3 = "ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,wpn_bm16"

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" then
		print("== R88 co-op: no pit zone known: the host fighter's own cutscene end is his custody, kept in a save; the win takes him out")
		setup({ before_start = no_pit_zone })
		local host_gear = owned(0)
		W.talked[0] = NOW
		start(3)
		check(ids_text(HA._state().fight) == "0", "co-op: the host goes in alone (" .. ids_text(HA._state().fight) .. ")")
		H.cut.ended = true
		H.cut:update()
		pump()
		local rec = ledger_for(HA, 0)
		check(rec ~= nil and rec.cut == true, "co-op: his own cutscene's end is in his record")
		local saved = {}
		H.fire("save_state", saved)
		H.fire("load_state", saved)
		rec = ledger_for(HA, 0)
		check(rec ~= nil and rec.cut == true, "co-op: and in the save")
		H.env.db.actor._pos = vector():set(T_WAY)
		for _ = 1, 16 do tick(H) end
		pump()
		check(ledger_for(HA, 0) ~= nil and lines_with(H, "waited: given back") == 0, "co-op: 16 s on, his gear still waits in box 1")
		win(3)
		check(at(H.env.db.actor, DOOR) and same(owned(0), host_gear), "co-op: the win: the host's way out, his own gear")

		print("== R88 co-op: no pit zone known: a client fighter whose cutscene ended dies in the pit; the arena takes what he held")
		setup({ before_start = no_pit_zone })
		local client_gear = owned(PROXY)
		W.talked[1] = NOW
		start(3)
		Cm.cut.ended = true
		Cm.cut:update()
		pump()
		H.objects[PROXY]._pos = vector():set(T_WAY)
		tick(H)
		dies_at(PROXY, T_WAY)
		check(#owned(PROXY) == 0 and #owned(STASH_R88) == 0 and sections_of(BOX2) == KIT3,
			"co-op: the kit he held and the stash his death left go into box 2 (" .. sections_of(BOX2) .. ")")
		check(same(owned(BOX1), client_gear), "co-op: his own gear still waits in box 1")

		print("== R88 co-op: the gathering ends without a start (the arena reset): the boards and the spot go")
		setup({ start_as_is = true })
		H.env.db.actor._pos = vec(149, 1, 76)
		W.talked[0] = NOW
		start(1)
		tick(H)
		pump()
		check(view(HA) and view(CA) and view(CA).a == "invite" and Cm.spot ~= nil, "co-op: the host's board, the client's reminder and spot")
		HA.fight_over()
		pump()
		check(view(HA) == nil and view(CA) == nil and Cm.spot == nil, "co-op: reset while the group gathers: no board, no spot")

		print("== R88 co-op: the key passed to a player is one line in his chat")
		setup({ start_as_is = true })
		local said = {}
		Cm.env.coop_core_chat = { system = function(s) said[#said + 1] = s end }
		H.env.db.actor._pos = vec(149, 1, 76)
		H.objects[PROXY]._pos = vec(149, 1, 80)
		Cm.env.db.actor._pos = vec(149, 1, 80)
		W.talked[0] = NOW
		start(1)
		tick(H)
		pump()
		check(view(CA) and view(CA).a == "with" and #said == 0, "co-op: the client goes with the host, nothing in his chat")
		H.env.coop.life_of = function(x) return x == 0 and "wounded" or "alive" end
		for _ = 1, 3 do tick(H) end
		pump()
		check(view(CA) and view(CA).a == "lead" and view(CA).passed == true and #said == 1,
			"co-op: the host is down: the key is the client's, one line in his chat (" .. #said .. ")")
		H.env.coop.life_of = nil

		print("== R88 co-op: the zones spawned before coop_arena's wrapper: a purge takes the pit's zone by its name, not the cage")
		setup({ start_as_is = true, zone_before = true })
		local before, cage_not, pit = zones_before_wrapper()
		check(before and cage_not and pit, "co-op: no zone, the cage's purge: still none, the pit's purge: bar_arena")
	elseif answer == "srv_map" then
		print("== R88 server: no pit zone known on the map server: a fighter whose cutscene ended dies in the pit; the arena takes it")
		setup({ answer = answer, before_start = no_pit_zone })
		local client_gear = owned(PROXY)
		W.talked[1] = NOW
		start(3)
		check(ids_text(HA._state().fight) == tostring(PROXY), "server: the client fights alone on the Bar")
		for _, fn in ipairs(H.handlers["arena.cut"] or {}) do fn(H.env.coop_main.encode({ _peer = 1 }), 0) end
		pump()
		local rec = ledger_for(HA, PROXY)
		check(rec ~= nil and rec.cut == true, "server: his cutscene's end (arena.cut through the world server) is in his record")
		local carried = {}
		H.fire("save_state", carried)
		H.fire("load_state", carried)
		rec = ledger_for(HA, PROXY)
		check(rec ~= nil and rec.cut == true, "server: and in what the map server carries")
		-- what his machine made of the kit is on him (the map server's model makes no kit: put it there)
		for _, s in ipairs({ "stalker_outfit", "wpn_bm16", "ammo_12x70_buck", "ammo_12x70_buck" }) do new_item(s, PROXY, "client") end
		H.objects[PROXY]._pos = vector():set(T_WAY)
		tick(H)
		dies_at(PROXY, T_WAY)
		check(#owned(PROXY) == 0 and #owned(STASH_R88) == 0 and sections_of(BOX2) == KIT3,
			"server: what he held and the stash his death left go into box 2 (" .. sections_of(BOX2) .. ")")
		check(same(owned(BOX1), client_gear), "server: his own gear still waits in box 1")

		print("== R88 server: a player who leaves the Bar loses his reminder; the gathering's end without a start takes the boards")
		setup({ answer = answer, start_as_is = true, third = true })
		H.objects[PROXY]._pos = vec(149, 1, 76)
		H.objects[THIRD]._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(3)
		tick(H)
		pump()
		check((gather_sent(2) or {}).a == "invite", "server: the third is invited")
		H.objects[THIRD] = nil -- he walks to another map: his character leaves the Bar's map server
		tick(H)
		pump()
		check((gather_sent(2) or {}).a == "off", "server: the third left the Bar: his reminder goes (" .. tostring((gather_sent(2) or {}).a) .. ")")
		HA.fight_over()
		pump()
		check((gather_sent(1) or {}).a == "off", "server: reset while the group gathers: the starter's board goes")

		print("== R88 server: the zones spawned before coop_arena's wrapper: a purge takes the pit's zone by its name, not the cage")
		setup({ answer = answer, start_as_is = true, zone_before = true })
		local before, cage_not, pit = zones_before_wrapper()
		check(before and cage_not and pit, "server: no zone, the cage's purge: still none, the pit's purge: bar_arena")
	end
end

-------------------------------------------------------------------------------
-- R88, the second review of 2026-11-24: the gathering is the Bar's, at Arnie. A co-op level change is a new Lua state and a load:
-- the held fight came back with its hold, and gather_tick told every player of the next map his part with no Arnie there
-- ("<nick> waits for you at Arnie" on Agroprom, a new tip and the spot on Arnie after every level change; only going back to the
-- Bar and starting the fight took it away). Off the Bar, and on the Bar with Arnie not here, the gathering rests: the fight stays
-- held, nobody is told anything, who was told hears "off"; back on the Bar the boards and the key come back.
-- Also: a save of a build before R88 made while the group gathered (its fight saved with neither ids nor hold) waits for a key, as
-- the gathering did; the trigger found waiting in sr_idle@wait_N with no record (a new map server of the Bar: it writes nothing
-- into the save) makes it anew, and waits while nobody is on the map; the starter's id taken by a non-player object (X-Ray reuses
-- ids) still passes the key.
-------------------------------------------------------------------------------
local AGROPROM = "l03_agroprom"
-- "gather" messages the authority sent after `from` (its own player's are played on its machine, not sent)
local function gathers_since(from)
	local n = 0
	for i = from + 1, #H.sent do
		local s = H.sent[i]
		if s.name == "arena.go" and H.env.coop_main.decode(s.payload).f == "gather" then n = n + 1 end
	end
	return n
end
-- the trigger's sr_idle@wait_N as xr_logic keeps it (the section in the scheme's storage): one update; -> how many times its 1 s
-- timer ran (with its %=bar_arena_teleport%)
local function wait_timer(n)
	H.idle_updates = 0
	H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = { section = "sr_idle@wait_" .. n, signals = {} } })
	local runs = H.idle_updates
	if runs > 0 then
		H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
		pump()
	end
	return runs
end
-- a player's message to this machine's coop_arena (the authority's arena.go)
local function to_client(t)
	for _, fn in ipairs(Cm.handlers["arena.go"] or {}) do fn(Cm.env.coop_main.encode(t), 0) end
end
-- the session forgets the player of `peer` (he left it); his avatar id goes to an object of the world (X-Ray reuses ids)
local function id_reused(peer, id)
	local players, by_avatar = H.env.coop.players, H.env.coop.peer_of_avatar
	H.env.coop.players = function()
		local out = {}
		for _, p in ipairs(players()) do if p.id ~= peer then out[#out + 1] = p end end
		return out
	end
	H.env.coop.peer_of_avatar = function(x) if x == id then return nil end return by_avatar(x) end
	H.objects[id] = make_obj(id, 120, 0, 120, { _name = "a_stalker_of_the_world" })
end

for _, answer in ipairs(modes.names()) do
	if answer == "hostplay" then
		print("== R88 co-op: the group leaves the Bar while the gathering waits: on another map no board, no reminder, no tip, no spot")
		setup({ start_as_is = true })
		H.env.db.actor._pos = vec(149, 1, 76)
		W.talked[0] = NOW
		start(1)
		tick(H)
		pump()
		check(view(HA) and view(HA).a == "lead" and view(CA) and view(CA).a == "invite" and #Cm.tips == 1 and Cm.spot ~= nil,
			"co-op: on the Bar: the host's board, the client's reminder, one tip and the spot on Arnie")
		-- the group's transition: every machine loads the next map; the host's new Lua state restores its save, the client's new
		-- state was told nothing yet (his old board and spot went with the old state)
		local saved = {}
		H.fire("save_state", saved)
		local arnie = H.objects[MANAGER]
		H.level_name, Cm.level_name = AGROPROM, AGROPROM
		H.objects[MANAGER] = nil -- Arnie is not on this map
		H.env.db.actor._pos = vec(10, 0, 10)
		H.objects[PROXY]._pos = vec(12, 0, 10)
		Cm.env.db.actor._pos = vec(12, 0, 10)
		to_client({ f = "gather", a = "off" })
		local tips = #Cm.tips
		H.fire("load_state", saved)
		local sent = #H.sent
		for _ = 1, 60 do tick(H) end
		pump()
		local f = HA._state().fight
		check(f ~= nil and f.hold == true and f.n == 1, "co-op: on Agroprom the fight stays held (" .. tostring(f and f.hold) .. ")")
		check(f ~= nil and next(f.board or {}) == nil and gathers_since(sent) == 0,
			"co-op: nobody on Agroprom is told anything (" .. gathers_since(sent) .. " message(s))")
		check(view(HA) == nil and view(CA) == nil, "co-op: no board, no reminder on Agroprom (host " .. tostring(view(HA) and view(HA).a)
			.. ", client " .. tostring(view(CA) and view(CA).a) .. ")")
		check(#Cm.tips == tips and Cm.spot == nil, "co-op: no new tip, no spot on Arnie (" .. (#Cm.tips - tips) .. " tip(s))")
		check(#owned(BOX1) == 0 and (H.cut_in or 0) == 0 and not H.ui_off and not Cm.ui_off, "co-op: nobody is taken")
		-- an invitation that reaches a player on another map all the same (sent before the level change) shows nothing there
		to_client({ f = "gather", a = "invite", n = 1, w = "p0", s = 0, c = 1, t = 2, r = "0", o = "1", m = MANAGER })
		check(view(CA) == nil and #Cm.tips == tips and Cm.spot == nil, "co-op: an invitation on another map: no reminder, no tip, no spot")

		print("== R88 co-op: back on the Bar the gathering goes on: the boards and the key")
		local back = {}
		H.fire("save_state", back)
		H.level_name, Cm.level_name = ARENA, ARENA
		H.objects[MANAGER] = arnie
		H.env.db.actor._pos = vec(149, 1, 76)
		H.objects[PROXY]._pos = vec(149, 1, 82) -- 8 m
		Cm.env.db.actor._pos = vec(149, 1, 82)
		to_client({ f = "gather", a = "off" })
		H.fire("load_state", back)
		tick(H)
		pump()
		check(view(HA) and view(HA).a == "lead" and view(CA) and view(CA).a == "with",
			"co-op: back on the Bar: the host's board with the key, the client goes with him (" .. tostring(view(HA) and view(HA).a) .. ", "
			.. tostring(view(CA) and view(CA).a) .. ")")
		check(idle_runs() == 0, "co-op: the trigger is still held")
		press_start(HA)
		pump()
		check(ids_text(HA._state().fight) == "0," .. PROXY and idle_runs() == 1,
			"co-op: the host's key: both go in, the trigger goes on (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 co-op: a save of a build before R88 made while the group gathered (no ids, no hold) waits for a key")
		setup({ start_as_is = true })
		local client_gear = owned(PROXY)
		H.env.db.actor._pos = vec(149, 1, 76) -- the host at Arnie
		H.objects[PROXY]._pos = vector():set(AWAY_FROM_ARNIE) -- the client, who took it, 30 m away
		Cm.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		W.infos.bar_arena_fight_1, W.infos.bar_arena_fight = true, true
		H.fire("load_state", { coop_arena = { ledger = {}, fight = { id = PROXY, n = 1 } } })
		local runs = wait_timer(1)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and f.id == PROXY, "co-op: held, its taker the starter (timer ran " .. runs .. ")")
		check(#owned(BOX1) == 0 and same(owned(PROXY), client_gear) and ledger_for(HA, PROXY) == nil, "co-op: nobody is taken")
		tick(H)
		pump()
		check(view(CA) and view(CA).a == "lead_far" and view(HA) and view(HA).a == "with", "co-op: the client is told to come to Arnie, the host goes with him")
		-- its taker is not on the map, the host is alone there: not "the taker alone at once" (nobody's fight), it waits for a key
		setup({ start_as_is = true })
		local away = H.objects[PROXY]
		H.objects[PROXY] = nil
		H.env.coop_npc_players.invalidate()
		H.env.db.actor._pos = vec(149, 1, 76)
		W.infos.bar_arena_fight_1, W.infos.bar_arena_fight = true, true
		H.fire("load_state", { coop_arena = { ledger = {}, fight = { id = PROXY, n = 1 } } })
		runs = wait_timer(1)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and #owned(BOX1) == 0, "co-op: its taker away, the host alone: held (timer ran " .. runs .. ")")
		tick(H)
		pump()
		check(HA._state().fight.id == 0 and view(HA) and view(HA).a == "lead", "co-op: the host at Arnie can start it")
		H.objects[PROXY] = away
		-- a fight of a save before 2026-11-07 that ran (one fighter, no ids; its trigger is past sr_idle@wait_N) keeps its fighter
		setup({ start_as_is = true })
		W.infos.bar_arena_fight_1, W.infos.bar_arena_fight = true, true
		H.fire("load_state", { coop_arena = { ledger = { { id = PROXY, kind = "fight", items = {} } }, fight = { id = PROXY, n = 1 } } })
		H.idle_updates = 0
		H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = { section = "sr_idle@fight", signals = {} } })
		f = HA._state().fight
		check(H.idle_updates == 1 and f ~= nil and not f.hold and f.id == PROXY and HA.blocks_trip(PROXY) == true,
			"co-op: a fight that ran keeps its fighter: no gathering, its trigger goes on")

		print("== R88 co-op: the trigger waits in sr_idle@wait_N with no record (a save with none): it gathers by a key")
		setup({ start_as_is = true })
		H.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		W.infos.bar_arena_fight_2, W.infos.bar_arena_fight = true, true
		H.fire("load_state", {})
		runs = wait_timer(2)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and f.n == 2 and #owned(BOX1) == 0,
			"co-op: two players on the Bar: the fight is held for a key, nobody taken (timer ran " .. runs .. ")")
		-- the host alone takes a fight now (no client: nobody asks the audience rule; its timer not due yet): at once, as stock
		setup({ start_as_is = true })
		local proxy = H.objects[PROXY]
		H.objects[PROXY] = nil
		H.env.coop_npc_players.invalidate()
		W.infos.bar_arena_fight_2, W.infos.bar_arena_fight = true, true
		H.env.db.storage[TRIG] = { activation_time = NOW }
		runs = wait_timer(2)
		f = HA._state().fight
		check(runs == 1 and f ~= nil and not f.hold and ids_text(f) == "0", "co-op: the host alone takes it now: at once, as stock (" .. ids_text(f) .. ")")
		-- the host alone, the trigger's timer due long ago (a save with no record): who took it is not known, it waits for a key
		setup({ start_as_is = true })
		H.objects[PROXY] = nil
		H.env.coop_npc_players.invalidate()
		H.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		W.infos.bar_arena_fight_2, W.infos.bar_arena_fight = true, true
		H.fire("load_state", {})
		H.env.db.storage[TRIG] = { activation_time = NOW - 120000 }
		runs = wait_timer(2)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and f.id == 0 and #owned(BOX1) == 0 and log_has(H, "taken anew"),
			"co-op: the host alone, the timer due: held for his key (timer ran " .. runs .. ")")
		hold_start(0)
		check(ids_text(HA._state().fight) == "0" and idle_runs() == 1, "co-op: his key at Arnie starts it (" .. ids_text(HA._state().fight) .. ")")
		H.objects[PROXY] = proxy

		print("== R88 co-op: the starter's id taken by a non-player object (X-Ray reuses ids): the key passes all the same")
		setup({ start_as_is = true })
		H.env.db.actor._pos = vec(149, 1, 76)
		H.objects[PROXY]._pos = vector():set(AWAY_FROM_ARNIE)
		Cm.env.db.actor._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(1)
		tick(H)
		pump()
		check(view(HA) and view(HA).a == "with", "co-op: the client took it, the host at Arnie goes with him")
		id_reused(1, PROXY)
		for _ = 1, 2 do tick(H) end
		pump()
		check(HA._state().fight.id == 0 and view(HA) and view(HA).a == "lead" and view(HA).passed == true,
			"co-op: the client left, a stalker got his id: the key is the host's (" .. tostring(HA._state().fight.id) .. ")")
	elseif answer == "srv_map" then
		print("== R88 server: Arnie is not here on the Bar's map server while the group gathers: the boards go, the fight waits")
		setup({ answer = answer, start_as_is = true, third = true })
		H.objects[PROXY]._pos = vec(149, 1, 76)
		H.objects[THIRD]._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(3)
		tick(H)
		pump()
		check((gather_sent(1) or {}).a == "lead" and (gather_sent(2) or {}).a == "invite", "server: the client has the key, the third is invited")
		local arnie = H.objects[MANAGER]
		H.objects[MANAGER] = nil
		tick(H)
		pump()
		local f = HA._state().fight
		check(f ~= nil and f.hold == true and (gather_sent(1) or {}).a == "off" and (gather_sent(2) or {}).a == "off",
			"server: no Arnie: both hear 'off', the fight stays held (" .. tostring((gather_sent(1) or {}).a) .. ", "
			.. tostring((gather_sent(2) or {}).a) .. ")")
		local sent = #H.sent
		for _ = 1, 10 do tick(H) end
		pump()
		local runs = trigger_timer()
		check(gathers_since(sent) == 0 and runs == 0 and ledger_for(HA, PROXY) == nil and ledger_for(HA, THIRD) == nil,
			"server: nobody is told anything more, nobody is taken (" .. gathers_since(sent) .. " message(s), timer ran " .. runs .. ")")
		H.objects[MANAGER] = arnie
		tick(H)
		pump()
		check((gather_sent(1) or {}).a == "lead" and (gather_sent(2) or {}).a == "invite", "server: Arnie is back: the boards are back")
		relay_start(1)
		pump()
		check(ids_text(HA._state().fight) == tostring(PROXY), "server: the starter's key: he goes in (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 server: a new map server of the Bar finds the trigger waiting with no record: held, nobody taken without a key")
		setup({ answer = answer, start_as_is = true, third = true })
		local third_gear = owned(THIRD)
		H.objects[PROXY]._pos = vec(149, 1, 76)
		H.objects[THIRD]._pos = vector():set(AWAY_FROM_ARNIE)
		W.talked[1] = NOW
		start(3)
		tick(H)
		pump()
		-- the Bar empties and its map server stops (it writes nothing into the save); a new one starts from the world save: no
		-- record of the fight there, the trigger's logic (coop_levels_logic) is back at sr_idle@wait_3, its timer long over
		local proxy, third = H.objects[PROXY], H.objects[THIRD]
		H.objects[PROXY], H.objects[THIRD] = nil, nil
		H.fire("load_state", {})
		NOW = NOW + 600000
		H.env.db.storage[TRIG] = { activation_time = NOW - 590000 } -- the trigger's old activation time came back with its logic
		H.env.coop_npc_players.invalidate()
		runs = wait_timer(3)
		check(runs == 0 and HA._state().fight == nil, "server: nobody on the Bar: the trigger's timer waits (timer ran " .. runs .. ")")
		-- the third, who never took it, comes back first and alone
		H.objects[THIRD] = third
		H.objects[THIRD]._pos = vec(149, 1, 100) -- 26 m
		H.env.coop_npc_players.invalidate()
		runs = wait_timer(3)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and f.n == 3 and f.id == THIRD,
			"server: the third alone on the Bar: not at once, the fight is held for his key (timer ran " .. runs .. ", starter "
			.. tostring(f and f.id) .. ")")
		check(ledger_for(HA, THIRD) == nil and same(owned(THIRD), third_gear) and #owned(BOX1) == 0, "server: the third is not taken")
		check(log_has(H, "taken anew"), "server: one line in the map server's log says the record was made anew")
		H.objects[PROXY] = proxy
		H.objects[PROXY]._pos = vector():set(AWAY_FROM_ARNIE) -- 30 m
		H.objects[THIRD]._pos = vec(149, 1, 76)
		tick(H)
		pump()
		check((gather_sent(2) or {}).a == "lead" and (gather_sent(1) or {}).a == "invite", "server: at Arnie the third has the key, the client is invited")
		relay_start(2)
		pump()
		check(ids_text(HA._state().fight) == tostring(THIRD) and ledger_for(HA, PROXY) == nil,
			"server: his key: he goes in alone, the client 30 m away stays (" .. ids_text(HA._state().fight) .. ")")

		print("== R88 server: a carried state of a build before R88 made while the group gathered (no ids, no hold) waits for a key")
		setup({ answer = answer, start_as_is = true, third = true })
		H.objects[PROXY]._pos = vector():set(AWAY_FROM_ARNIE)
		H.objects[THIRD]._pos = vec(149, 1, 76)
		W.infos.bar_arena_fight_1, W.infos.bar_arena_fight = true, true
		H.fire("load_state", { coop_arena = { ledger = {}, fight = { id = PROXY, n = 1 } } })
		runs = wait_timer(1)
		f = HA._state().fight
		check(runs == 0 and f ~= nil and f.hold == true and ledger_for(HA, PROXY) == nil and ledger_for(HA, THIRD) == nil,
			"server: held, nobody taken (timer ran " .. runs .. ")")

		print("== R88 server: the starter's id taken by a non-player object (X-Ray reuses ids): the key passes all the same")
		setup({ answer = answer, start_as_is = true, third = true })
		H.objects[PROXY]._pos = vector():set(AWAY_FROM_ARNIE)
		H.objects[THIRD]._pos = vec(149, 1, 76)
		W.talked[1] = NOW
		start(3)
		tick(H)
		pump()
		check((gather_sent(1) or {}).a == "lead_far" and (gather_sent(2) or {}).a == "with", "server: the client took it, the third at Arnie goes with him")
		id_reused(1, PROXY)
		for _ = 1, 2 do tick(H) end
		pump()
		local told = gather_sent(2) or {}
		check(HA._state().fight.id == THIRD and told.a == "lead" and told.p == 1,
			"server: the client left, a stalker got his id: the key is the third's (" .. tostring(HA._state().fight.id) .. ")")
	end
end

-------------------------------------------------------------------------------
-- R88, the way out that never came (owner 2026-11-24: "no way back when you kill the opponent"). After a win the way out is the
-- commentator's: bar_arena_comment_fight_1.ltx waits for bar_arena_fight_N_done, plays bar_arena_fight_N_end and on its
-- sound_end runs %=bar_arena_teleport_2 -bar_arena_fight_N% (route_out). A sound_end that never comes (a map server's silent
-- sound core, the commentator offline) left the fighters in the pit with the kit and their own gear in box 1: the heal leaves the
-- fighters of a running record alone, only a death or a rejoin got them out. The authority of the Bar takes that way out itself,
-- once, a fight's wait after it saw the win (fight 3: 10 s, fight 1: 13 s), and takes off what the commentator's line takes off.
-- A sound_end that came first leaves it nothing to do; a death in the pit is as before (his gear waits for his respawn); a save
-- or a carried state of the map server brings the record back and the wait counts from then. A line of the commentator that
-- ends late is not the way out of the record of a fight taken since.
-------------------------------------------------------------------------------
do
	local LATE = { [1] = 13, [3] = 10 }
	local BOTH_KITS = "ammo_12x70_buck,ammo_12x70_buck,ammo_12x70_buck,ammo_12x70_buck,stalker_outfit,stalker_outfit,wpn_bm16,wpn_bm16"
	-- arena.go "out" the authority sent to `peer`
	local function outs_to(peer)
		local n = 0
		for _, s in ipairs(H.sent) do
			if s.name == "arena.go" and s.target == peer and H.env.coop_main.decode(s.payload).f == "out" then n = n + 1 end
		end
		return n
	end
	-- the stock calls this machine ran for its own player ("out": bar_arena_teleport_2)
	local function ran(M, what)
		local n = 0
		for _, r in ipairs(M.ran) do if r == what then n = n + 1 end end
		return n
	end
	local function never_came(n) return lines_with(H, "the commentator's end never came: the way out after " .. LATE[n] .. " s") end
	local function wait_s(s)
		for _ = 1, s do tick(H) end
		pump()
	end
	-- the opponents are dead (bar_arena_fight_N_done: their logic, the trigger's sr_idle@wait_finish); the commentator's sound_end
	-- does not come. The authority's next tick sees the win.
	local function won_silent(n)
		W.infos["bar_arena_fight_" .. n .. "_done"] = true
		wait_s(1)
	end
	-- fight n: two fighters by the starter's key at Arnie, at t_way in the pit (co-op: the host and the client; server: the client
	-- and the third on the Bar's map server). -> the host's and the client's own gear before it
	local function pit_two(answer, n)
		if answer == "hostplay" then setup({ start_as_is = true }) else setup({ answer = answer, start_as_is = true, third = true }) end
		local host_gear, client_gear = owned(0), owned(PROXY)
		real_zones(H, false)
		H.env.disable_info = function(i) W.infos[i] = nil end
		local b
		if answer == "hostplay" then
			b = PROXY
			H.env.db.actor._pos = vec(149, 1, 76)
			H.objects[PROXY]._pos = vec(146, 1, 70)
			W.talked[0] = NOW
		else
			b = THIRD
			H.objects[PROXY]._pos = vec(149, 1, 76)
			H.objects[THIRD]._pos = vec(146, 1, 70)
			W.talked[1] = NOW
		end
		start(n)
		tick(H)
		if answer == "hostplay" then press_start(HA) else relay_start(1) end
		pump()
		H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
		pump()
		if answer == "hostplay" then
			H.env.db.actor._pos = vector():set(T_WAY)
			Cm.env.db.actor._pos = aside(T_WAY, 1)
		else
			H.objects[PROXY]._pos = vector():set(T_WAY)
		end
		H.objects[b]._pos = aside(T_WAY, 1)
		wait_s(3)
		return host_gear, client_gear
	end

	for _, answer in ipairs(modes.names()) do
		if answer == "hostplay" then
			print("== R88 co-op: the win, the commentator's sound_end never comes: the way out after 10 s, once")
			local host_gear, client_gear = pit_two(answer, 3)
			check(ids_text(HA._state().fight) == "0," .. PROXY and ledger_for(HA, 0) and ledger_for(HA, PROXY) and #owned(BOX1) == 11,
				"co-op: the host and the client fight in the pit, their gear in box 1 (" .. ids_text(HA._state().fight) .. ")")
			won_silent(3)
			wait_s(9)
			check(never_came(3) == 0 and outs_to(1) == 0 and ran(H, "out") == 0 and ledger_for(HA, 0) and ledger_for(HA, PROXY)
				and at(H.env.db.actor, T_WAY), "co-op: 9 s after the win the commentator may still speak: both still in the pit")
			wait_s(1)
			check(never_came(3) == 1, "co-op: 10 s after the win: one line in the host's log (" .. never_came(3) .. ")")
			check(outs_to(1) == 1 and ran(H, "out") == 1 and ran(Cm, "out") == 1, "co-op: each fighter's way out ran once (client "
				.. outs_to(1) .. ", host " .. ran(H, "out") .. ")")
			check(at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR), "co-op: both fighters are at the arena's door")
			check(same(owned(0), host_gear) and same(owned(PROXY), client_gear) and #owned(BOX1) == 0,
				"co-op: each has exactly his own gear back, box 1 is empty")
			check(sections_of(BOX2) == BOTH_KITS, "co-op: both kits are in box 2 (" .. sections_of(BOX2) .. ")")
			check(HA._state().fight == nil and W.infos.bar_arena_fight_3 == nil and W.infos.bar_arena_fight_3_done == true,
				"co-op: the record is over, bar_arena_fight_3 is taken off as the commentator's line does (its _done stays)")
			local box2 = owned(BOX2)
			wait_s(60)
			check(never_came(3) == 1 and outs_to(1) == 1 and ran(H, "out") == 1 and ran(Cm, "out") == 1,
				"co-op: a minute on: no second way out")
			H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
			pump()
			check(outs_to(1) == 1 and ran(H, "out") == 1 and same(owned(0), host_gear) and same(owned(PROXY), client_gear)
				and same(owned(BOX2), box2), "co-op: the commentator's line ends late after all: nothing moves, nobody is moved")

			print("== R88 co-op: the commentator's sound_end comes 5 s after the win: one way out, no other")
			host_gear, client_gear = pit_two(answer, 3)
			won_silent(3)
			wait_s(4)
			H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
			pump()
			check(outs_to(1) == 1 and ran(H, "out") == 1 and at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR),
				"co-op: the commentator's way out: both at the door")
			wait_s(60)
			check(never_came(3) == 0 and outs_to(1) == 1 and ran(H, "out") == 1 and ran(Cm, "out") == 1,
				"co-op: a minute on: no second way out, no line (" .. never_came(3) .. ")")
			check(same(owned(0), host_gear) and same(owned(PROXY), client_gear) and sections_of(BOX2) == BOTH_KITS,
				"co-op: each has his own gear, both kits in box 2, once")

			print("== R88 co-op: a save and a load while the fighters wait for the commentator: the wait counts from the load")
			host_gear, client_gear = pit_two(answer, 3)
			won_silent(3)
			wait_s(4)
			local saved = {}
			H.fire("save_state", saved)
			H.fire("load_state", saved)
			check(ids_text(HA._state().fight) == "0," .. PROXY, "co-op: the load brings the fight's record back")
			wait_s(9)
			check(never_came(3) == 0 and outs_to(1) == 0 and ran(H, "out") == 0, "co-op: 9 s after the load: still in the pit")
			wait_s(2)
			check(never_came(3) == 1 and outs_to(1) == 1 and ran(H, "out") == 1 and at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR)
				and same(owned(0), host_gear) and same(owned(PROXY), client_gear) and #owned(BOX1) == 0,
				"co-op: then the way out, once: both at the door with their own gear")

			print("== R88 co-op: fight 1 waits 13 s; a fighter dead in the pit is not moved, his gear waits for his respawn")
			host_gear, client_gear = pit_two(answer, 1)
			H.env.coop.life_of = function(x) return x == PROXY and "dead" or "alive" end
			wait_s(1)
			won_silent(1)
			wait_s(12)
			check(never_came(1) == 0 and ran(H, "out") == 0, "co-op: fight 1, 12 s after the win: the host still in the pit")
			wait_s(1)
			check(never_came(1) == 1 and ran(H, "out") == 1 and at(H.env.db.actor, DOOR) and same(owned(0), host_gear),
				"co-op: 13 s: the host's way out, his own gear")
			check(outs_to(1) == 0 and same(owned(BOX1), client_gear) and ledger_for(HA, PROXY) ~= nil and lines_with(H, "is dead") == 1,
				"co-op: the dead client is not moved, his gear waits in box 1")
			H.env.coop.life_of = nil
			Cm.fire("coop_respawned")
			pump()
			check(outs_to(1) == 1 and same(owned(PROXY), client_gear) and #owned(BOX1) == 0, "co-op: his respawn: his own gear back, as before")

			print("== R88 co-op: the fight is lost (its fighter dies in the pit): nothing new")
			setup()
			client_gear = owned(PROXY)
			H.env.disable_info = function(i) W.infos[i] = nil end
			W.talked[1] = NOW
			start(3)
			check(ids_text(HA._state().fight) == tostring(PROXY), "co-op: the client fights alone")
			H.objects[PROXY]._pos = vector():set(IN_ARENA)
			H.env.coop.life_of = function(x) return x == PROXY and "dead" or "alive" end
			wait_s(60)
			check(never_came(3) == 0 and outs_to(1) == 0 and same(owned(BOX1), client_gear) and W.infos.bar_arena_fight_3 == true,
				"co-op: a minute on: no way out, his gear waits in box 1, the fight's info stays")
			H.env.coop.life_of = nil

			print("== R88 co-op: a won fight's record off the Bar (a load elsewhere): no way out there; back on the Bar it comes")
			host_gear, client_gear = pit_two(answer, 3)
			won_silent(3)
			H.level_name, Cm.level_name = AGROPROM, AGROPROM
			wait_s(60)
			check(never_came(3) == 0 and outs_to(1) == 0 and ran(H, "out") == 0 and ids_text(HA._state().fight) == "0," .. PROXY,
				"co-op: a minute on Agroprom: no way out, the record stays")
			H.level_name, Cm.level_name = ARENA, ARENA
			wait_s(10)
			check(never_came(3) == 0 and outs_to(1) == 0, "co-op: back on the Bar the wait counts from there: not 9 s on")
			wait_s(1)
			check(never_came(3) == 1 and outs_to(1) == 1 and ran(H, "out") == 1 and same(owned(0), host_gear) and same(owned(PROXY), client_gear),
				"co-op: then the way out, each his own gear")

			print("== R88 co-op: after the way out without the commentator the group takes fight 4; fight 3's line ends late: not fight 4's")
			pit_two(answer, 3)
			won_silent(3)
			wait_s(10)
			check(never_came(3) == 1 and outs_to(1) == 1, "co-op: fight 3's way out came without the commentator")
			H.env.db.actor._pos = vec(149, 1, 76)
			H.objects[PROXY]._pos = vec(120, 0, 100)
			Cm.env.db.actor._pos = vec(120, 0, 100)
			W.infos.bar_arena_fight_4 = true
			H.rule(H.objects[TRIG])
			pump()
			wait_s(1)
			local f = HA._state().fight
			check(f ~= nil and f.n == 4 and f.hold == true and view(CA) and view(CA).a == "invite", "co-op: fight 4 gathers, the client is invited")
			local host_now, client_now = owned(0), owned(PROXY)
			H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
			pump()
			f = HA._state().fight
			check(f ~= nil and f.n == 4 and f.hold == true and view(HA) ~= nil and view(CA) and view(CA).a == "invite",
				"co-op: fight 3's late line: fight 4 still gathers, the boards stay")
			check(outs_to(1) == 1 and ran(H, "out") == 1 and same(owned(0), host_now) and same(owned(PROXY), client_now),
				"co-op: nobody is moved, no gear moves")
		elseif answer == "srv_map" then
			print("== R88 server: the win on the Bar's map server, the commentator's sound_end never comes: the way out after 10 s, once")
			local _, client_gear = pit_two(answer, 3)
			check(ids_text(HA._state().fight) == PROXY .. "," .. THIRD and ledger_for(HA, PROXY) and ledger_for(HA, THIRD)
				and same(owned(BOX1), client_gear), "server: the client and the third fight in the pit, the client's gear in box 1 ("
				.. ids_text(HA._state().fight) .. ")")
			won_silent(3)
			wait_s(9)
			check(never_came(3) == 0 and outs_to(1) == 0 and outs_to(2) == 0 and ledger_for(HA, PROXY) and same(owned(BOX1), client_gear),
				"server: 9 s after the win: both still in the pit")
			wait_s(1)
			check(never_came(3) == 1 and outs_to(1) == 1 and outs_to(2) == 1,
				"server: 10 s: one line in the map server's log, each fighter's way out once (" .. outs_to(1) .. ", " .. outs_to(2) .. ")")
			check(same(owned(PROXY), client_gear) and #owned(BOX1) == 0 and ledger_for(HA, PROXY) == nil and ledger_for(HA, THIRD) == nil,
				"server: the client has exactly his own gear back, box 1 is empty")
			check(HA._state().fight == nil and W.infos.bar_arena_fight_3 == nil, "server: the record is over, bar_arena_fight_3 is taken off")
			wait_s(60)
			H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
			pump()
			check(never_came(3) == 1 and outs_to(1) == 1 and outs_to(2) == 1 and same(owned(PROXY), client_gear),
				"server: a minute on, and the commentator's late line: no second way out")

			print("== R88 server: the commentator's sound_end comes 5 s after the win: one way out, no other")
			_, client_gear = pit_two(answer, 3)
			won_silent(3)
			wait_s(4)
			H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, H.objects[COMMENT])
			pump()
			check(outs_to(1) == 1 and outs_to(2) == 1 and same(owned(PROXY), client_gear) and #owned(BOX1) == 0,
				"server: the commentator's way out for both")
			wait_s(60)
			check(never_came(3) == 0 and outs_to(1) == 1 and outs_to(2) == 1 and same(owned(PROXY), client_gear),
				"server: a minute on: no second way out, no line")

			print("== R88 server: the map server's state is carried while the fighters wait: the wait counts from then")
			_, client_gear = pit_two(answer, 3)
			won_silent(3)
			wait_s(4)
			local carried = {}
			H.fire("save_state", carried)
			H.fire("load_state", carried)
			check(ids_text(HA._state().fight) == PROXY .. "," .. THIRD, "server: the carried state brings the fight's record back")
			wait_s(9)
			check(never_came(3) == 0 and outs_to(1) == 0 and outs_to(2) == 0, "server: 9 s after it: still in the pit")
			wait_s(2)
			check(never_came(3) == 1 and outs_to(1) == 1 and outs_to(2) == 1 and same(owned(PROXY), client_gear) and #owned(BOX1) == 0,
				"server: then the way out, once, the client's own gear back")

			print("== R88 server: fight 1 waits 13 s; the third dead in the pit is not moved, his record waits for his respawn")
			_, client_gear = pit_two(answer, 1)
			H.env.coop.life_of = function(x) return x == THIRD and "dead" or "alive" end
			wait_s(1)
			won_silent(1)
			wait_s(12)
			check(never_came(1) == 0 and outs_to(1) == 0, "server: fight 1, 12 s after the win: the client still in the pit")
			wait_s(1)
			check(never_came(1) == 1 and outs_to(1) == 1 and same(owned(PROXY), client_gear), "server: 13 s: the client's way out, his own gear ("
				.. never_came(1) .. " line(s), " .. outs_to(1) .. " way(s) out, fight " .. tostring(HA._state().fight and HA._state().fight.n) .. ")")
			check(outs_to(2) == 0 and ledger_for(HA, THIRD) ~= nil and lines_with(H, "is dead") == 1,
				"server: the dead third is not moved, his record waits")
			H.env.coop.life_of = nil

			print("== R88 server: the fight is lost (its fighter dies in the pit): nothing new")
			setup({ answer = answer })
			client_gear = owned(PROXY)
			H.env.disable_info = function(i) W.infos[i] = nil end
			W.talked[1] = NOW
			start(3)
			check(ids_text(HA._state().fight) == tostring(PROXY), "server: the client fights alone")
			H.objects[PROXY]._pos = vector():set(IN_ARENA)
			H.env.coop.life_of = function(x) return x == PROXY and "dead" or "alive" end
			wait_s(60)
			check(never_came(3) == 0 and outs_to(1) == 0 and same(owned(BOX1), client_gear) and W.infos.bar_arena_fight_3 == true,
				"server: a minute on: no way out, his gear waits in box 1")
			H.env.coop.life_of = nil
		end
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
