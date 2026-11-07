-- The Bar arena and the totalizator in a session (coop_arena): who goes in, whose gear moves where, what comes back.
-- A host (peer 0) and a client (peer 1, the host's proxy 500) share one world of items; the stock functions below follow
-- xr_effects.script (bar_arena_teleport, bar_arena_teleport_2, bar_arena_weapon_slot, teleport_for_totaliz_out) and
-- dialogs_mlr.script (teleport_for_totaliz) of Anomaly 1.5.3 line by line where items and positions are concerned.
-- Run: tools\test_lua.cmd arena
dofile("tests/lua/support/harness_npc.lua")

local PROXY = 500
local BOX1, BOX2, TRIG, MANAGER, COMMENT, TOTAL, OPPONENT, BODY = 900, 901, 910, 920, 911, 912, 300, 777
local SR, SPAM = 913, 914 -- Arnie's monster fight (the old arena): restrictors bar_arena_sr and bar_arena_spam
local THIRD = 501 -- a third player's character (group entry)
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
	M.zone = setmetatable({ saved_obj = {}, object = make_obj(930, IN_ARENA.x, IN_ARENA.y, IN_ARENA.z, { _radius = 20 }) }, { __index = cls })
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
	M.keys, M.key_sends = {}, 0
	E.coop_economy_mdata = {
		register_player_key = function(k, f) M.keys[k] = f end,
		send_player_keys = function() M.key_sends = M.key_sends + 1 end,
	}
	-- audience_of: the players a restrictor's condlist is for (M.logic_aud: who walked into bar_arena_waiter; bar_arena_spam
	-- names no player, so everybody)
	E.coop_npc_logic = { add_audience_rule = function(f) M.rule = f end, audience_of = function() return M.logic_aud end }
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.coop_mods_core = load_script(M, "coop_mods_core")
	-- ui_dyn_msg_box.msg_box_ui: the box (yes = ok, no = cancel)
	E.ui_dyn_msg_box = { msg_box_ui = function(typ, show, text, ok, cancel)
		local b = { txt = text, typ = typ }
		b.ok = function() ok(b) end
		b.cancel = function() if cancel then cancel(b) end end
		b.message_box = { HideDialog = function() if M.BOX == b then M.BOX = nil end end }
		M.BOX = b
		return b
	end }
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
	local avatars = { [0] = 0, [1] = PROXY }
	if opts.third then avatars[2] = THIRD end
	H = machine("host", 0, avatars)
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
	H.zone:net_spawn() -- the level loads: the arena zone's binder spawns (coop_arena keeps it)
	return H, Cm
end

-- The host's trigger: the dialog gave fight n; sr_idle@idle -> sr_idle@wait_n (%=disable_ui%: the audience rule), on_timer
-- 1000 -> sr_cutscene@fight_n (%=bar_arena_teleport%), whose section reaches every machine (its cutscene).
-- START_AS_IS: only the trigger's sr_idle@wait_N (its audience); else a held fight is started by its taker alone ("start alone").
local function start(n)
	W.infos["bar_arena_fight_" .. n], W.infos.bar_arena_fight = true, true
	local aud = H.rule(H.objects[TRIG])
	pump()
	if START_AS_IS then return aud end
	local f = HA._state().fight
	if f and f.hold then
		local M = f.id == 0 and H or Cm
		local b = M.BOX
		M.BOX = nil
		if b then b.ok() end
		pump()
		aud = H.rule(H.objects[TRIG])
	end
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	H.cut, Cm.cut = H.new_cut(), Cm.new_cut()
	H.cut:zone_enter()
	Cm.cut:zone_enter()
	return aud
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
	check(HA._state().ledger[PROXY] and #HA._state().ledger[PROXY].items == 6, "the host's ledger holds his six items")

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
	check(HA._state().ledger[PROXY] == nil and HA._state().fight == nil, "the ledger and the fight are clean")
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
	check(HA._state().ledger[PROXY] ~= nil and HA._state().fight == nil, "his ledger stays, the fight is over")
	-- the host saves and loads the world meanwhile
	local md = {}
	H.fire("save_state", md)
	HA._state().ledger[PROXY] = nil
	H.fire("load_state", md)
	check(HA._state().ledger[PROXY] and #HA._state().ledger[PROXY].items == 6, "the ledger comes back with the host's world")
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
	check(same(owned(BOX1), client_gear) and HA._state().ledger[PROXY].kind == "bet", "his gear is in box 1, as a bet")
	check(sections_of(PROXY) == "wpn_binoc" and created_by("client", PROXY) == 1, "his binoculars are his stock call's")
	check(math.abs(Cm.env.db.actor._pos.x - BET_SPOT_X) < 0.01 and (Cm.requests or 0) == 0, "he stands at the spectators' place, no move of his own asked")
	check(same(owned(0), host_gear) and at(H.env.db.actor, host_pos), "the host is not touched")
	H.zone.saved_obj = { [PROXY] = true }
	H.env.xr_effects.teleport_for_totaliz_out(H.env.db.actor, H.objects[TOTAL])
	pump()
	check(same(owned(PROXY), client_gear) and sections_of(BOX2) == "wpn_binoc", "the fight is over: his gear back, the binoculars in box 2")
	check(same(owned(0), host_gear) and #H.ran == 0, "the host's inventory stays his (b-L10: it went into box 2 before)")
	check(math.abs(Cm.env.db.actor._pos.x - BET_OUT_X) < 0.01 and not released(H, PROXY), "the bettor is out, his character not purged")
	check(CA._state().mine == false and HA._state().ledger[PROXY] == nil, "flag and ledger clean")
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
	check(same(owned(BOX1), client_gear) and HA._state().ledger[PROXY] ~= nil, "box 1 is not here: his ledger waits, nothing is lost")
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
	check(CA._state().mine == false and HA._state().ledger[PROXY] == nil, "flag and ledger clean")

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
	check(#HA._state().ledger[PROXY].kit == 4, "his machine told the host what the arena gave him")
	-- he falls and keeps his inventory (the keep setting), respawns outside, picks something up, his ask comes late
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
	check(HA._state().ledger[PROXY].kind == "fight" and #HA._state().ledger[PROXY].items == 6, "his ledger stays the fight's")
	check(#owned(BOX1) == 6 and sections_of(PROXY):find("wpn_binoc", 1, true) == nil, "nothing more went in, no bet")
end

print("== split levels: the Bar's ledger outlives its map server")
do
	reset_world()
	NOW = NOW + 1000000
	local BRIDGE = 0x101
	W = { items = {}, holders = {}, next_id = 2000, moves = 0, infos = {}, talked = {}, created = {}, client_seen = {} }
	local function share_stub(M)
		M.ups, M.downs = {}, {}
		M.env.coop_levels_share = {
			up = function(n, get, set) M.ups[n] = { get = get, set = set } end,
			down = function(n, get, set) M.downs[n] = { get = get, set = set } end,
		}
	end
	-- the world server, on another level
	local Wd = machine("host", 0, { [0] = 0, [1] = PROXY })
	Cm = nil
	H = Wd
	holder(Wd, Wd.env.db.actor, 0)
	env(Wd, "l01_escape")
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
	check(MA2._state().ledger[PROXY] and #MA2._state().ledger[PROXY].items == 3, "it takes the world's copy")
	Mk2.downs.arena_ledger.set({ list = {} })
	check(MA2._state().ledger[PROXY] ~= nil, "a later copy does not undo it")
	for _, f in ipairs(Mk2.handlers["arena.out"] or {}) do f(Mk2.env.coop_main.encode({ _peer = 1 }), 0) end
	check(same(owned(PROXY), gear), "he comes back: his gear from box 1")
	local up2 = Mk2.ups.arena_ledger.get()
	check(up2 and up2.based == true and #up2.list == 0, "the empty ledger goes up as the truth")
	Wd.ups.arena_ledger.set(up2, 2)
	check(#WA._state().world_copy == 0, "the world server's copy is empty again")
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

print("== a reputation change of a player during an arena fight goes into his log with its source")
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
-- Group entry (owner 2026-11-07): a fight taken from Arnie waits for the other players on the Bar. They are invited (a tip and
-- a map spot on Arnie); whoever stands within GATHER_RADIUS of Arnie has one button: alone "start alone", with others but not
-- everybody "start without the others" (a vote among those at Arnie: coop_economy_group.propose). Everybody at Arnie: it
-- starts by itself; nobody else on the Bar: at once (stock's 1 s). Everyone at Arnie at the start goes in, each with his kit
-- and his ledger, at a spot of his own.
local function box_of(M) return M.BOX end
local function press(M, yes)
	local b = M.BOX
	M.BOX = nil
	if b then if yes then b.ok() else b.cancel() end end
	pump()
end

print("== group entry: nobody else on the Bar: the fight starts at once, as in single player")
do
	setup({ start_as_is = true })
	H.objects[PROXY]._pos = vec(300, 0, 300)
	H.objects[PROXY]._level_away = true
	local proxy = H.objects[PROXY]
	H.objects[PROXY] = nil -- his character is on another map
	W.talked[0] = NOW
	local aud = start(1)
	check(aud and aud[0] == true and not HA._state().fight.hold, "no hold: the host's trigger effects are his at once")
	H.idle_updates = 0
	H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = {} })
	check(H.idle_updates == 1, "the trigger's sr_idle@wait runs its timer (stock 1 s)")
	check(box_of(H) == nil, "no button")
	H.objects[PROXY] = proxy
end

print("== group entry: the host takes the fight, the client is on the Bar: the game waits and invites him")
do
	setup({ start_as_is = true })
	W.talked[0] = NOW
	local aud = start(1)
	local f = HA._state().fight
	check(f and f.hold == true and aud and next(aud) == nil, "held: the trigger's disable_ui goes to nobody (the taker can move and press)")
	H.idle_updates = 0
	H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = {} })
	check(H.idle_updates == 0, "the trigger's sr_idle@wait does not run its timer while the group gathers")
	H.env.sr_idle.action_idle.update({ object = H.objects[COMMENT], st = {} })
	check(H.idle_updates == 1, "another sr_idle runs as stock")
	tick(H)
	pump()
	check(box_of(H) and box_of(H).txt:find("alone", 1, true) ~= nil, "the host at Arnie: the button 'start alone' (" .. tostring(box_of(H) and box_of(H).txt) .. ")")
	check(box_of(Cm) == nil and Cm.spot ~= nil and #Cm.tips > 0 and Cm.tips[#Cm.tips].id:find("p0", 1, true) ~= nil,
		"the client is invited: a tip with the host's nick and a map spot on Arnie")
	check((H.cut_in or 0) == 0 and #owned(BOX1) == 0, "nobody went in yet")
	press(H, true)
	f = HA._state().fight
	check(not f.hold and #f.ids == 1 and f.ids[1] == 0, "started alone: the host is the one fighter")
	check(Cm.spot == nil, "the client's spot on Arnie is gone")
	H.idle_updates = 0
	H.env.sr_idle.action_idle.update({ object = H.objects[TRIG], st = {} })
	check(H.idle_updates == 1, "the trigger goes on (its 1 s timer is long over: the cutscene at once)")
	aud = H.rule(H.objects[TRIG])
	check(aud and aud[0] == true and aud[PROXY] == nil, "the trigger's effects are his")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	check(created_by("host", 0) == 4 and created_by("client") == 0, "only the host gets a kit")
end

print("== group entry: the client walks up to Arnie: everybody on the Bar is there, both go in")
do
	setup({ start_as_is = true })
	local host_gear, client_gear = owned(0), owned(PROXY)
	H.env.db.actor._pos = vec(149, 1, 76)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	check(HA._state().fight.hold == true and Cm.spot ~= nil, "held, the client invited")
	H.objects[PROXY]._pos = vec(146, 1, 70) -- he comes
	tick(H)
	pump()
	local f = HA._state().fight
	check(not f.hold and #f.ids == 2 and f.ids[1] == 0 and f.ids[2] == PROXY, "everybody at Arnie: it starts by itself, the taker first")
	check(Cm.spot == nil and box_of(H) == nil, "no spot, no button")
	check(Cm.ui_off == 1 and H.ui_off == 1, "both lose the UI at the start (stock disable_ui)")
	local aud = H.rule(H.objects[TRIG])
	check(aud[0] == true and aud[PROXY] == true, "the trigger's effects (enable_ui) are both fighters'")
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	H.cut, Cm.cut = H.new_cut(), Cm.new_cut()
	H.cut:zone_enter()
	Cm.cut:zone_enter()
	check(#owned(BOX1) == #host_gear + #client_gear, "both gears are in box 1")
	check(created_by("host", 0) == 4 and created_by("client", PROXY) == 4, "each his own kit, made by his own machine")
	check(H.cut_in == 1 and Cm.cut_in == 1, "both cutscenes play")
	check(at(H.env.db.actor, IN_ARENA) and not at(Cm.env.db.actor, IN_ARENA) and Cm.env.db.actor._pos:distance_to(IN_ARENA) < 4,
		"each at a spot of his own in the pit")
	check(HA._state().prizes[1] and #HA._state().prizes[1] == 2, "the fight's prize is both fighters'")
	-- the host's cutscene ends: his trigger goes on; the client's slot and the way out are both fighters'
	H.env.xr_effects.bar_arena_weapon_slot(H.env.db.actor, H.objects[TRIG], { "2" })
	pump()
	check(H.env.db.actor._slot == 2 and Cm.env.db.actor._slot == 2, "the weapon slot is both fighters'")
	H.zone.saved_obj = { [OPPONENT] = true, [PROXY] = true }
	win(1)
	check(same(owned(0), host_gear) and same(owned(PROXY), client_gear), "won: each has exactly his own gear back")
	check(at(H.env.db.actor, DOOR) and at(Cm.env.db.actor, DOOR), "both at the door")
end

print("== group entry: one falls, the fight goes on; it is over when no fighter is left")
do
	setup({ start_as_is = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(146, 1, 70)
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, H.objects[TRIG])
	pump()
	check(#HA._state().fight.ids == 2, "two fighters")
	-- the client falls and respawns: his gear back, the host fights on
	for _, f in ipairs(H.handlers["arena.out"] or {}) do f(H.env.coop_main.encode({}), 1) end
	pump()
	local f = HA._state().fight
	check(f and #f.ids == 1 and f.ids[1] == 0, "the fight goes on with the host")
	HA.fight_over()
	check(HA._state().fight == nil, "over")
end

print("== group entry: three players, two at Arnie: 'start without the others' asks the other one at Arnie")
do
	setup({ start_as_is = true, third = true })
	H.env.db.actor._pos = vec(149, 1, 76)
	H.objects[PROXY]._pos = vec(146, 1, 70)
	H.objects[THIRD]._pos = vec(120, 0, 100) -- on the Bar, far from Arnie
	local asked
	H.env.coop_economy_group = { propose = function(name, from, voters, cb, arg)
		asked = { name = name, from = from, voters = voters, cb = cb, arg = arg }
		return true
	end }
	W.talked[0] = NOW
	start(1)
	tick(H)
	pump()
	check(box_of(H) and box_of(H).txt:find("without", 1, true) ~= nil, "two of three at Arnie: the button 'start without the others'")
	check(box_of(Cm) and box_of(Cm).txt:find("without", 1, true) ~= nil, "the client at Arnie has it too")
	press(H, true)
	check(asked and asked.name == "arena" and asked.from == 0 and asked.voters[1] == true and asked.voters[0] == nil and asked.voters[2] == nil and asked.arg == "1",
		"the host pressed: a vote of the client (the one at Arnie), not of the third player")
	check(HA._state().fight.hold == true, "the vote runs: still waiting")
	asked.cb(false, "no", "p1")
	check(HA._state().fight.hold == true, "a no: the group still waits")
	press(Cm, true)
	check(asked.from == 1 and asked.voters[0] == true, "the client presses: the host is asked")
	asked.cb(true)
	local f = HA._state().fight
	check(not f.hold and #f.ids == 2 and f.ids[1] == 0 and f.ids[2] == PROXY, "yes: the two at Arnie go in, the third stays")
end

print("== group entry: the vote is the economy's (coop_economy_group.subject 'arena' with its lines)")
do
	local subj
	setup({ start_as_is = true, before_start = function()
		H.env.coop_economy_group = { subject = function(name, texts) subj = { name = name, texts = texts } end }
	end })
	check(subj and subj.name == "arena" and subj.texts.ask and subj.texts.no and subj.texts.timeout, "the arena's vote lines are registered")
end

print("== the arena's strings: eng and rus, every id coop_arena uses")
do
	local function read(path)
		local f = io.open(path, "rb")
		local s = f and f:read("*a")
		if f then f:close() end
		return s
	end
	local src = read("gamedata/scripts/coop_arena.script") or ""
	local eng = read("gamedata/configs/text/eng/st_coop_arena.xml") or ""
	local rus = read("gamedata/configs/text/rus/st_coop_arena.xml") or ""
	local ids, n = {}, 0
	for id in src:gmatch('"(st_coop_arena_[%w_]+)"') do
		if not ids[id] then ids[id] = true n = n + 1 end
	end
	check(n >= 6, "coop_arena names its strings (" .. n .. ")")
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

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
