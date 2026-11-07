-- The Bar arena and the totalizator in a session (coop_arena): who goes in, whose gear moves where, what comes back.
-- A host (peer 0) and a client (peer 1, the host's proxy 500) share one world of items; the stock functions below follow
-- xr_effects.script (bar_arena_teleport, bar_arena_teleport_2, bar_arena_weapon_slot, teleport_for_totaliz_out) and
-- dialogs_mlr.script (teleport_for_totaliz) of Anomaly 1.5.3 line by line where items and positions are concerned.
-- Run: tools\test_lua.cmd arena
dofile("tests/lua/support/harness_npc.lua")

local PROXY = 500
local BOX1, BOX2, TRIG, MANAGER, COMMENT, TOTAL, OPPONENT, BODY = 900, 901, 910, 920, 911, 912, 300, 777
local ARENA = "l05_bar"
local IN_ARENA = vec(153, -19, 103) -- where the cutscene puts the fighter
local DOOR = vec(150, 0.4, 75) -- t_walk_2
local BET_SPOT_X, BET_OUT_X = 139.61517333984, 150.249435424805
local KITS = {
	[1] = { "novice_outfit", "wpn_pm", "ammo_9x18_pmm", "ammo_9x18_pmm" },
	[3] = { "stalker_outfit", "wpn_bm16", "ammo_12x70_buck", "ammo_12x70_buck" },
}

local W -- the world: items (host ids; a client sees the same ids, his own character swapped 0 <-> 500)
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
	E.coop_npc_logic = { add_audience_rule = function(f) M.rule = f end }
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.coop_mods_core = load_script(M, "coop_mods_core")
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
	H = machine("host", 0, { [0] = 0, [1] = PROXY })
	Cm = nil
	holder(H, H.env.db.actor, 0)
	H.env.db.actor._pos = vec(100, 0, 100)
	holder(H, H.add(make_obj(PROXY, 148, 1, 72, { _name = "proxy1" })), PROXY)
	H.add(make_obj(TRIG, 152.9, 0.5, 70.5, { _name = "bar_arena_triger" }))
	H.add(make_obj(MANAGER, 149, 1, 74, { _name = "arnie" }))
	H.add(make_obj(COMMENT, 150, 0, 70, { _name = "bar_arena_comment_fight_1" }))
	H.add(make_obj(TOTAL, 150, 0, 70, { _name = "bar_arena_totalizator" }))
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
local function start(n)
	W.infos["bar_arena_fight_" .. n], W.infos.bar_arena_fight = true, true
	local aud = H.rule(H.objects[TRIG])
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
	check(same(owned(PROXY), client_gear) and #sent_named(H, "arena.go") == 0, "the client is not touched")
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
	HA = load_script(H, "coop_arena")
	HA.on_game_start()
	W.infos.bar_arena_fight_1 = true
	H.env.xr_effects.bar_arena_teleport(H.env.db.actor, nil)
	check(H.ran[1] == "in" and same(owned(BOX1), gear) and #owned(0) == 4, "the way in is stock: gear in box 1, the kit on him")
	H.env.xr_effects.bar_arena_teleport_2(H.env.db.actor, nil)
	check(same(owned(0), gear) and #owned(BOX2) == 4 and H.purges == 1, "the way out is stock")
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
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
