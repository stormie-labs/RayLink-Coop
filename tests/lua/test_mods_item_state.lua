-- Dev 57 G3-1: real item riders, clone transactions and the merged 3DSS/jamming modules.
-- Co-op: host has the map. Server: world has no map; two map authorities report through it.
-- G3-1c: the engine's part (riders carried by a move, ticks of arrivals and releases) is modelled below and runs always.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")
local CAMO, JAM = "coop_weapon_camo", "coop_weapon_jam"

local function corpus(w, name)
	local file = name .. ".script"
	local f = io.open("temp/review/corpus/merged/" .. file, "r")
	local gamma = os.getenv("GAMMA_SCRIPTS")
	if not f and gamma then f = io.open(gamma .. "/" .. file, "r") end
	assert(f, "real GAMMA script required: " .. file .. " (corpus or GAMMA_SCRIPTS)")
	local src = f:read("*a") f:close()
	local module = setmetatable({}, { __index = w })
	w[name] = module
	local chunk = assert(loadstring(src, "@corpus/" .. name .. ".script"))
	setfenv(chunk, module) chunk()
	return module
end

local function selection(w, id)
	local data = {}
	w.z_3dss_gamma_camo_system.save_state(data)
	return data.z_3dss_gamma_camo_system.selections[id]
end

local function weapon(w, id, parent, name)
	local o = add_item(w, id, "wpn_test", parent)
	if name then w.SE[id].name = function() return name end end
	o.cast_Weapon = function(self) return self end
	o.texture = "base"
	o.get_shaders = function(self) return { [1] = { texture = self.texture, shader = "model" } } end
	o.set_shader = function(self, _, _, texture) self.texture = texture end
	return o
end

-- The engine part (F4 G3-1c, engine/src/xrCoop/coop_item_rider_rules.h) as coop_script.cpp runs it: one counter per
-- process numbers the events reaching its Lua inbox (deliver_later) and the releases of entities there
-- (coop_entities.cpp host_on_entity_released -> script::note_released); coop.event_tick() -> arrival, now;
-- coop.released_after(local id, tick) -> riders::ReleaseBook::released_after.
local function engine(w)
	local e = { now = 0, delivering = nil, released = {} }
	w.ENGINE = e
	w.coop.event_tick = function() return e.delivering or e.now, e.now end
	w.coop.released_after = function(id, tick)
		if type(id) ~= "number" or type(tick) ~= "number" then return false end
		local last = e.released[id]
		return last ~= nil and last > tick
	end
end

local function arrive(w) w.ENGINE.now = w.ENGINE.now + 1 return w.ENGINE.now end
local function release(w, id, keep_instance)
	local tick = arrive(w)
	if not keep_instance then w.ENGINE.released[id] = tick end
end
local function deliver(w, tick, f) w.ENGINE.delivering = tick f() w.ENGINE.delivering = nil end

local function setup(peer, set, mirror)
	local w = make_world(peer)
	engine(w)
	w.coop.is_map_server = function() return BRIDGES[peer] ~= nil end
	w.coop.is_dedicated = function() return peer == 0 and set == "srv_world" end
	w.coop.levels = { map_servers = function()
		local out = {} for b in pairs(BRIDGES) do out[#out + 1] = { bridge = b } end return out
	end }
	w.RemoveTimeEvent = function(ev, key) w.TE[tostring(ev) .. "/" .. tostring(key)] = nil end
	w.ini_sys = { r_string_ex = function() return nil end }
	w.sound_object = setmetatable({ s2d = 1 }, { __call = function() return { play = function() end } end })
	w.itms_manager = { ini_parts = {} }
	w.a_arti_jamming_mcm = { get_config = function() return false end }
	w.key_bindings = setmetatable({}, { __index = function() return 1 end })
	w.db.actor.active_item = function() return w.OBJ[w.INV[1]] end
	load_script(w, "coop_economy_core")
	load_script(w, "coop_economy_mdata")
	w.coop_economy_mdata.on_game_start()
	load_script(w, "coop_mods_core")
	load_script(w, "coop_trust")
	load_script(w, "coop_mode")
	modes.install(w.coop_mode, set, mirror and {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
	} or nil)
	local camo = corpus(w, "z_3dss_gamma_camo_system")
	corpus(w, "arti_jamming")
	-- Like a mod whose on_game_start ran before this adapter: callback held by value.
	w.RegisterScriptCallback("actor_on_weapon_jammed", w.arti_jamming.actor_on_weapon_jammed)
	w.UnregisterScriptCallback = function(name, fn)
		for i = #(w.CB[name] or {}), 1, -1 do if w.CB[name][i] == fn then table.remove(w.CB[name], i) end end
	end
	corpus(w, "npc_camo_drops")
	local configs = assert(w.coop_mods_core.find_local(camo, "config_files"))
	configs[1] = { name = "test.ltx", section_order = { "wpn_test", "wpn_test_green" }, sections = {
		wpn_test = { textures = { body = "base" }, drop_factions = {}, faction_rarities = {}, rarity = 0 },
		wpn_test_green = { textures = { body = "green" }, drop_factions = {}, faction_rarities = {}, rarity = 1 },
	} }
	local f = io.open("gamedata/scripts/coop_mods_item_state.script", "r")
	if f then f:close() load_script(w, "coop_mods_item_state").on_game_start() end
	return w
end

local function worlds(server, same_map)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "next", proxy = 502 } }
	BRIDGES = server and { [257] = { nick = "map one", players = {1} }, [258] = { nick = "map two", players = {2} } } or {}
	if server and same_map then
		BRIDGES[257].players = {1, 2}
		BRIDGES[258] = nil
	end
	POS, QUEUE, WORLDS = {}, {}, {}
	for p in pairs(PLAYERS) do POS[p] = { x = 0, y = 0, z = 0 } end
	for b in pairs(BRIDGES) do POS[b] = { x = 0, y = 0, z = 0 } end
	local h = setup(0, server and "srv_world" or "hostplay")
	local a = setup(1, server and "srv_map" or "hostplay", true)
	local b = setup(2, server and "srv_map" or "hostplay", true)
	for bridge in pairs(BRIDGES) do setup(bridge, "srv_map") end
	for _, w in pairs(WORLDS) do
		for p, info in pairs(PLAYERS) do
			local id = w.coop.to_local_id(info.proxy)
			add_entity(w, id, "coop_player_avatar")
		end
		if server and w == h then
			add_entity(w, 800, "wpn_test", 501) -- ALife knows the item; the world has no online weapon.
		else
			weapon(w, 800, w == a and 0 or 501)
		end
	end
	a.INV = {800}
	tick_all(1100)
	return h, a, b, server and WORLDS[257] or h
end

local function handoff(a, b)
	for _, w in pairs(WORLDS) do
		local parent = w == b and 0 or 502
		w.SE[800].parent_id = parent
		if w.OBJ[800] then w.OBJ[800]._parent = parent end
	end
	a.INV, b.INV = {}, {800}
end

local function settle()
	for _ = 1, 3 do tick_all(1100) for _, w in pairs(WORLDS) do run_time_events(w) end end
end

-- coop_requests.cpp (F4 G3-1c): send_action of a client asks coop_mods_item_state.carry for a weapon leaving its
-- character and appends the text to its ReqDrop / ReqTransfer (riders::carries, riders::text_of); host_move on the process
-- that applies the move (the co-op host; the map server of the player's level, to which the world tunnels the request)
-- hands it to coop_mods_item_state.carried when the requester's character holds the item (riders::judge), then
-- apply_move moves the item. The economy's own se of the same change waits in a Lua inbox meanwhile.
local MAX_CARRY = 4096
local function native_move(a, b, mover)
	local text = a.coop_mods_item_state.carry(800)
	local holds = mover.SE[800] and mover.SE[800].parent_id == PLAYERS[1].proxy
	local taken = nil
	if type(text) == "string" and #text > 0 and #text <= MAX_CARRY and holds then
		taken = mover.coop_mods_item_state.carried(800, 1, text, PLAYERS[1].proxy) -- q.proxy
	end
	handoff(a, b)
	return text, taken
end

-- The process that applies a's moves: the co-op host, or the map server of a's level.
local function mover_of(h, server) return server and WORLDS[257] or h end

local function old_riders(w, a)
	local old_camo, old_jam = a.MDATA[CAMO][800], a.MDATA[JAM][800]
	return CM_ENCODE({ n = 2,
		i1 = 800, k1 = CAMO, d1 = w.coop_economy_core.pack(old_camo), x1 = old_camo.instance,
		i2 = 800, k2 = JAM, d2 = w.coop_economy_core.pack(old_jam), x2 = old_jam.instance,
	})
end

-- The engine cases of G3-1b's report: the move runs before the Lua inbox, and an id is reused under the same name.
local function native_cases(name)
	local server, same_map = name ~= "hostplay", name == "srv_map"
	local h, a, b = worlds(server, same_map)
	local owner_trust = (h.coop_trust.status().item_state_owner or {}).failed or 0
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.arti_jamming.set_jam_status(800, 3)
	-- The native request has already moved the weapon when the Lua inbox runs.
	local text, taken = native_move(a, b, mover_of(h, server))
	check(type(text) == "string" and #text <= MAX_CARRY and taken == true, "the client's move carries both riders and the mover takes them")
	deliver_all()
	fire(b, "actor_on_item_take", b.OBJ[800])
	settle()
	check(b.OBJ[800].texture == "green", "m01:2 transfer before Lua delivery keeps camo")
	check(b.arti_jamming.jammed_guns[800] == 3, "m27:5 transfer before Lua delivery keeps jam")
	local saved_camo, saved_jam = h.MDATA[CAMO] and h.MDATA[CAMO][800], h.MDATA[JAM] and h.MDATA[JAM][800]
	local saved_se = h.MDATA.se_object[800] and h.MDATA.se_object[800][JAM]
	check(type(saved_camo) == "table" and type(saved_camo.state) == "table" and saved_camo.state.section == "wpn_test_green"
		and type(saved_jam) == "table" and saved_jam.state == 3 and type(saved_se) == "table" and saved_se.state == 3,
		"the world save keeps the carried riders")
	if not server then
		local now = (h.coop_trust.status().item_state_owner or {}).failed or 0
		check(now == owner_trust, "the former holder's late copy of a carried rider is no trust failure")
	end
	for _, w in pairs(WORLDS) do check(not w.HANDLER_ERRORS, "no handler errors after a carried move on peer " .. w.PEER) end

	h, a, b = worlds(server, same_map)
	a.arti_jamming.set_jam_status(800, 3) settle()
	a.arti_jamming.set_jam_status(800, nil)
	native_move(a, b, mover_of(h, server))
	deliver_all()
	fire(b, "actor_on_item_take", b.OBJ[800])
	settle()
	check(b.arti_jamming.jammed_guns[800] == nil, "m27:5 transfer before Lua delivery keeps the previous owner's jam clear")
	local cleared = h.MDATA[JAM] and h.MDATA[JAM][800]
	check(type(cleared) == "table" and cleared.state == 0, "the world save keeps the carried clear")

	-- Nothing to carry: an unpainted weapon that never jammed.
	h, a, b = worlds(server, same_map)
	check(a.coop_mods_item_state.carry(800) == nil, "a weapon without riders carries nothing")
	-- The mover checks what a request carried like any rider of a client.
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	local carried = a.coop_mods_item_state.carry(800)
	local mover = mover_of(h, server)
	local trust = mover.coop_trust.status()
	local sent = #mover.SENT
	check(mover.coop_mods_item_state.carried(800, 2, carried, PLAYERS[2].proxy) == false and (trust.item_state_owner or {}).failed == 1,
		"a requester who does not hold the weapon writes no carried rider")
	local other = mover.coop_main.encode({ n = 1, i1 = 801, k1 = CAMO, d1 = mover.coop_economy_core.pack(a.MDATA[CAMO][800]),
		x1 = "wpn_test800" })
	check(mover.coop_mods_item_state.carried(800, 1, other, PLAYERS[1].proxy) == false and (trust.item_state_wire or {}).failed > 0,
		"a carried rider names the moved weapon only")
	check(mover.coop_mods_item_state.carried(800, 1, "garbage") == false
		and mover.coop_mods_item_state.carried(800, 1, mover.coop_main.encode({ n = 9 })) == false
		and mover.coop_mods_item_state.carried(70000, 1, carried) == false,
		"malformed carried text and ids are refused without an error")
	check(mover.coop_mods_item_state.carried(800, 1, carried, 70000) == false,
		"a holder id out of range is refused")
	check(#mover.SENT == sent and not (mover.MDATA[CAMO] and mover.MDATA[CAMO][801]), "refused carried riders are neither kept nor sent")

	-- Old relays wait in a receiver's Lua inbox while its engine releases the weapon and spawns a same-name replacement.
	h, a, b = worlds(server, same_map)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.arti_jamming.set_jam_status(800, 3)
	local arrived = arrive(b)
	release(b, 800) -- b's Lua misses the unregister
	weapon(b, 800, 0)
	b.MDATA.se_object[800] = nil
	fire(b, "game_object_on_net_spawn", b.OBJ[800])
	deliver(b, arrived, function() b.coop_main.on_event("economy.se", old_riders(b, a), 0) end)
	run_time_events(b)
	check(b.OBJ[800].texture == "base", "m01:2 delayed rider cannot paint a same-name replacement after missed unregister")
	check(b.arti_jamming.jammed_guns[800] == nil, "m27:5 delayed rider cannot jam a same-name replacement after missed unregister")
	check(not (b.MDATA[CAMO] and b.MDATA[CAMO][800]) and not (b.MDATA.se_object[800] and b.MDATA.se_object[800][CAMO]),
		"the delayed rider is never kept for the replacement")
	-- A rider that came after the release is the replacement's own.
	deliver(b, arrive(b), function() b.coop_main.on_event("economy.se", old_riders(b, a), 0) end)
	run_time_events(b)
	check(b.OBJ[800].texture == "green" and b.arti_jamming.jammed_guns[800] == 3, "a rider after the release still applies")

	-- What a receiver already held for the old weapon, its unregister missed: the replacement never gets it.
	h, a, b = worlds(server, same_map)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.arti_jamming.set_jam_status(800, 3) settle()
	check(b.OBJ[800].texture == "green" and b.arti_jamming.jammed_guns[800] == 3, "the observer holds the old weapon's riders")
	release(b, 800)
	weapon(b, 800, 501)
	fire(b, "game_object_on_net_spawn", b.OBJ[800]) settle()
	check(b.OBJ[800].texture == "base" and b.arti_jamming.jammed_guns[800] == nil and selection(b, 800) == nil,
		"m01:2/m27:5 held riders of a released weapon never reach its same-name replacement")
	check(not (b.MDATA[CAMO] and b.MDATA[CAMO][800]) and not (b.MDATA.se_object[800] and b.MDATA.se_object[800][CAMO]),
		"the released weapon's saved riders are forgotten")

	-- The owner's local rebuild after a refused upgrade returns the same weapon. Lua misses the unregister.
	h, a, b = worlds(server, same_map)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.arti_jamming.set_jam_status(800, 3) settle()
	release(a, 800, true) -- the rebuild marks this release to be skipped by the engine's ReleaseBook
	weapon(a, 800, 0)
	fire(a, "game_object_on_net_spawn", a.OBJ[800]) settle()
	check(a.OBJ[800].texture == "green", "refused upgrade rebuild keeps the same weapon's camo on its owner")
	check(a.arti_jamming.jammed_guns[800] == 3, "refused upgrade rebuild keeps the same weapon's Lua jam on its owner")

	-- The replacement's own rider arrives after the release and before net spawn. The old unregister was missed.
	h, a, b = worlds(server, same_map)
	a.arti_jamming.set_jam_status(800, 3) settle()
	release(b, 800)
	b.SE[800], b.OBJ[800] = nil, nil
	local stamp = "wpn_test800"
	local replacement_jam = b.coop_economy_core.pack({ instance = stamp, state = 2 })
	deliver(b, arrive(b), function()
		b.coop_main.on_event("economy.imd", CM_ENCODE({ n = 1, i1 = 800, k1 = JAM, d1 = replacement_jam, x1 = stamp }), 0)
	end)
	weapon(b, 800, 501)
	fire(b, "game_object_on_net_spawn", b.OBJ[800]) settle()
	check(b.arti_jamming.jammed_guns[800] == 2, "the replacement's own jam arriving before net spawn is applied")

	-- The world: a client's rider waited in its inbox while the world released the weapon and made a replacement.
	h, a, b = worlds(server, same_map)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	local queued = {}
	for i = #QUEUE, 1, -1 do
		if QUEUE[i].to == 0 and QUEUE[i].from == 1 then table.insert(queued, 1, table.remove(QUEUE, i)) end
	end
	check(#queued > 0, "the client's camo rider is on its way to the world")
	local at = arrive(h)
	release(h, 800)
	if server then add_entity(h, 800, "wpn_test", 501) else weapon(h, 800, 501) end
	sent = #h.SENT
	deliver(h, at, function()
		for _, m in ipairs(queued) do h.coop_main.on_event(m.name, m.payload, m.from) end
	end)
	run_time_events(h)
	check(not (h.MDATA[CAMO] and h.MDATA[CAMO][800]) and not (h.MDATA.se_object[800] and h.MDATA.se_object[800][CAMO]),
		"the world never keeps a rider older than its weapon's release")
	check(#h.SENT == sent, "the world never relays a rider older than its weapon's release")
	check(not h.HANDLER_ERRORS, "no handler errors on the world after a stale rider")
end

for _, name in ipairs(modes.names()) do
	section("item state / " .. name)
	if name == "none" then
		PLAYERS, POS, WORLDS, BRIDGES, QUEUE = { [0] = { proxy = 0 } }, { [0] = {x=0,y=0,z=0} }, {}, {}, {}
		local w = setup(0, "none") w.ACTIVE = false
		local gun = weapon(w, 800, 0) w.INV = {800}
		check(w.z_3dss_gamma_camo_system.select_camo(gun, "test.ltx", "wpn_test_green"), "SP select retains original return")
		w.arti_jamming.set_jam_status(800, 3)
		local npc_gun = weapon(w, 801, 600)
		check(w.z_3dss_gamma_camo_system.assign_drop_camo(npc_gun, "stalker") and npc_gun.texture == "green",
			"SP NPC camo still uses the original choice and visual")
		tick(w, 1100)
		check(selection(w, 800).section == "wpn_test_green" and w.arti_jamming.jammed_guns[800] == 3, "SP live mod tables unchanged")
		check(w.MDATA[CAMO] == nil and w.MDATA[JAM] == nil and #w.SENT == 0, "SP creates no riders or traffic")
		check(w.coop_mods_item_state.carry(800) == nil and w.coop_mods_item_state.carried(800, 1, "x") == false,
			"SP carries nothing with a move")
	else
		local h, a, b, decider = worlds(name ~= "hostplay")
		-- m01:2: concrete-item selection, ownership transfer and real clone rider migration.
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		settle()
		check(selection(b, 800) and selection(b, 800).section == "wpn_test_green", "m01:2 camo reaches observer")
		check(a.MDATA[CAMO] and a.MDATA[CAMO][800], "m01:2 camo is an item rider")
		handoff(a, b)
		fire(b, "actor_on_item_take", b.OBJ[800]) settle()
		check(selection(b, 800) and b.OBJ[800].texture == "green", "m01:2 handover keeps selection and visual")
		b.z_3dss_gamma_camo_system.load_state({ z_3dss_gamma_camo_system = { selections = {} } })
		b.OBJ[800].texture = "base"
		fire(b, "load_state", b.MDATA) run_time_events(b)
		check(selection(b, 800) and b.OBJ[800].texture == "green", "m01:2 load restores the selected camo and visual")
		local em = b.coop_economy_mdata
		local packed = assert(em.clone_export(800))
		check(em.clone_stage(800, 900, "wpn_test900", packed, 0, "clone/900"), "real clone stages riders")
		weapon(b, 900, 0) b.INV = {900}
		check(em.clone_activate(900), "real clone activates adapters")
		em.clone_finish(900, true) run_time_events(b)
		check(selection(b, 900) and b.OBJ[900].texture == "green", "m01:2 clone keeps camo with a new instance")
		check(b.MDATA.se_object[900][CAMO].instance == "clone/900", "clone rebases the se relay as well as the rider")
		-- A later clear must reach a normal weapon, without a focus/showcase callback.
		h, a, b, decider = worlds(name ~= "hostplay")
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green") settle()
		local selections = a.coop_mods_core.find_local(a.z_3dss_gamma_camo_system, "selected_by_weapon")
		selections[800] = nil settle()
		check(selection(b, 800) == nil and b.OBJ[800].texture == "base", "m01:2 selection clear restores the default visual")

		-- A transfer request can leave in the same frame as the camo/jam action.
		h, a, b = worlds(name ~= "hostplay", name == "srv_map")
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		a.arti_jamming.set_jam_status(800, 3)
		deliver_all()
		handoff(a, b)
		fire(b, "actor_on_item_take", b.OBJ[800])
		settle()
		check(b.OBJ[800].texture == "green", "m01:2 camo survives handoff before the next economy tick")
		check(b.arti_jamming.jammed_guns[800] == 3, "m27:5 jam survives handoff before the next economy tick")

		-- m27:5: the next owner and a fresh Lua table get the jam; zero clears old owners too.
		h, a, b, decider = worlds(name ~= "hostplay")
		a.arti_jamming.set_jam_status(800, 3) settle()
		check(b.arti_jamming.jammed_guns[800] == 3, "m27:5 next owner sees double feed")
		check(a.MDATA[JAM] and a.MDATA[JAM][800], "m27:5 jam is an item rider")
		b.arti_jamming.jammed_guns = {}
		fire(b, "load_state", b.MDATA) fire(b, "actor_on_first_update") settle()
		check(b.arti_jamming.jammed_guns[800] == 3, "m27:5 load restores jam into fresh Lua table")
		handoff(a, b)
		b.arti_jamming.set_jam_status(800, nil) settle()
		check(a.arti_jamming.jammed_guns[800] == nil and h.arti_jamming.jammed_guns[800] == nil, "m27:5 clear reaches former owner and save")
		local sent = #a.SENT + #b.SENT settle()
		check(#a.SENT + #b.SENT == sent, "received apply never echoes")
		-- The mod also writes its table directly in local fire/animation callbacks.
		b.arti_jamming.jammed_guns[800] = 2 settle()
		check(a.arti_jamming.jammed_guns[800] == 2, "m27:5 direct jam-table mutation is published")
		b.arti_jamming.jammed_guns[800] = nil settle()
		check(a.arti_jamming.jammed_guns[800] == nil, "m27:5 direct animation clear is published")
		b.arti_jamming.set_jam_status(800, 3)
		b.z_3dss_gamma_camo_system.select_camo(b.OBJ[800], "test.ltx", "wpn_test_green")
		local clone = b.coop_economy_mdata
		local snapshot = assert(clone.clone_export(800, "source/stamp"))
		check(clone.clone_stage(800, 901, "wpn_test901", snapshot, 0, "rejected/901"), "stamped clone prepares rollback")
		weapon(b, 901, 0)
		clone.clone_activate(901) clone.clone_finish(901, false)
		settle()
		check(b.arti_jamming.jammed_guns[800] == 3 and selection(b, 800) ~= nil, "rejected stamped clone preserves source state")
		local good = assert(pcall(b.arti_jamming.unset, nil))
		check(good, "nil unjam id retains the mod's active-weapon fallback")
		check(not b.MDATA[JAM][b.db.actor], "nil unjam never creates a table-valued item id")
		b.arti_jamming.actor_on_weapon_jammed(b.db.actor)
		check(b.MDATA[JAM][800].state == 4, "m27:5 engine jam callback saves the concrete active weapon immediately")
		b.arti_jamming.set_jam_status(800, 3)
		fire(b, "actor_on_weapon_jammed", b.db.actor)
		check(b.MDATA[JAM][800].state == 4, "m27:5 jam callback registered by value also saves immediately")
		check(#b.CB.actor_on_weapon_jammed == 1, "jam callback is replaced once, not duplicated")
		b.arti_jamming.set_jam_status(800, 3)
		-- Existing ordinary clone hook must migrate both riders, not only the visual table.
		weapon(b, 902, 0)
		clone.after_clone(800, 902)
		check(b.arti_jamming.jammed_guns[902] == 3 and selection(b, 902), "ordinary after_clone migrates camo and jam")
		b.arti_jamming.set_jam_status(902, 2)
		b.MDATA.se_object[902] = nil
		weapon(b, 902, 0, "replacement/902")
		clone.after_clone(800, 902)
		check(b.arti_jamming.jammed_guns[902] == 3, "m27:5 ordinary clone ignores the replaced target's old jam")
		b.MDATA.se_object[800] = nil
		weapon(b, 800, 0, "replacement/800")
		local reused = assert(clone.clone_export(800, "replacement/stamped"))
		local riders = b.coop_economy_core.unpack(reused).riders
		check(not riders[JAM] or riders[JAM].state == 0, "m27:5 clone export cannot give a reused source its predecessor's jam")

		h, a, b = worlds(name ~= "hostplay")
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		a.arti_jamming.set_jam_status(800, 3)
		-- Stock alife_clone_weapon releases the source before calling after_clone.
		fire(a, "server_entity_on_unregister", a.SE[800], "se_item_weapon")
		a.MDATA.se_object[800], a.SE[800], a.OBJ[800] = nil, nil, nil
		weapon(a, 903, 0)
		a.coop_economy_mdata.after_clone(800, 903)
		run_time_events(a)
		check(a.arti_jamming.jammed_guns[903] == 3 and a.OBJ[903].texture == "green", "ordinary clone keeps state after unregistering its source")
		weapon(a, 800, 0) -- Same name because the engine generates it from section and ID.
		fire(a, "game_object_on_net_spawn", a.OBJ[800])
		check(a.arti_jamming.jammed_guns[800] == nil and selection(a, 800) == nil, "unregister clears riders before same-name ID reuse")

		-- Stand b57i base_group (2026-11-21): a weapon its authority makes with no rider (a trader's restock) reaches a player's
		-- machine as an EntitySpawn whose clone initial (coop_requests.cpp write_clone_initial: clone_export with a stamp) has
		-- no riders. client_on_spawn (coop_entities.cpp) stages it with trust 2, then clone_activate gives each rider table's
		-- adapter the weapon's value: nil, "no rider" - not an invalid weapon rider ("item 32041: invalid weapon rider").
		h, a, b, decider = worlds(name ~= "hostplay")
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		a.arti_jamming.set_jam_status(800, 3)
		settle()
		weapon(decider, 920, 600)
		if h ~= decider then add_entity(h, 920, "wpn_test", 600) end
		local initial = decider.coop_economy_mdata.clone_export(920, "spawn/920")
		check(type(initial) == "string", "a weapon with no rider has a clone initial")
		for _, w in ipairs({ a, b }) do
			check(type(w.MDATA[CAMO]) == "table" and type(w.MDATA[JAM]) == "table", "rider tables exist before the spawn")
			local em = w.coop_economy_mdata
			local failed = (w.coop_trust.status().item_state_value or {}).failed or 0
			check(em.clone_stage(65535, 920, "wpn_test920", initial, 2, "spawn/920"), "a spawned weapon's initial stages")
			weapon(w, 920, 600)
			check(em.clone_activate(920), "a spawned weapon with no rider activates")
			em.clone_finish(920, true)
			fire(w, "game_object_on_net_spawn", w.OBJ[920]) settle()
			local now = (w.coop_trust.status().item_state_value or {}).failed or 0
			check(now == failed, "a spawned weapon with no rider is no invalid weapon rider (peer " .. tostring(w.PEER) .. ", "
				.. (now - failed) .. " failed)")
			check(selection(w, 920) == nil and w.arti_jamming.jammed_guns[920] == nil and w.OBJ[920].texture == "base",
				"a spawned weapon with no rider gets no camo and no jam")
		end
		check(selection(a, 800) and a.arti_jamming.jammed_guns[800] == 3, "the riders of the player's own weapon stay")

		-- m01:5: only the map authority rolls; data/object order does not change the result.
		h, a, b, decider = worlds(name ~= "hostplay")
		local gun = weapon(decider, 810, 600)
		if h ~= decider then add_entity(h, 810, "wpn_test", 600) end -- world ALife entity, no loaded map/object
		check(decider.z_3dss_gamma_camo_system.assign_drop_camo(gun, "stalker"), "m01:5 map authority chooses NPC camo")
		check(not a.z_3dss_gamma_camo_system.assign_drop_camo(a.OBJ[800], "stalker"), "m01:5 mirror never rolls NPC camo")
		if name ~= "hostplay" then
			check(not h.z_3dss_gamma_camo_system.assign_drop_camo(decider.OBJ[800], "stalker"), "m01:5 world with no player map never rolls camo")
		end
		weapon(a, 810, 600) -- object before the data
		settle()
		weapon(b, 810, 600) -- data before the object
		fire(b, "game_object_on_net_spawn", b.OBJ[810]) settle()
		check(selection(a, 810) and a.OBJ[810].texture == "green", "m01:5 object before data applies identical camo")
		check(selection(b, 810) and b.OBJ[810].texture == "green", "m01:5 data before object applies identical camo")
		check(h.MDATA[CAMO] and h.MDATA[CAMO][810], "m01:5 world save keeps NPC selection without a local map")
		-- Exercise the whole NPC death callback from the corpus, not just its callee.
		local drop = weapon(decider, 811, 601)
		if h ~= decider then add_entity(h, 811, "wpn_test", 601) end
		weapon(a, 811, 601)
		local npc = { character_community = function() return "stalker" end,
			iterate_inventory = function(_, f, context) f(context, drop) end }
		decider.npc_camo_drops.npc_on_death_callback(npc) settle()
		for _ = 1, 35 do tick_all(1100) end
		weapon(b, 811, 601) fire(b, "game_object_on_net_spawn", b.OBJ[811]) settle()
		check(a.OBJ[811].texture == "green" and b.OBJ[811].texture == "green", "m01:5 real NPC death choice survives a late ordinary visual")
		-- The economy still has its old deferred delivery when the new selection arrives.
		local delayed = weapon(decider, 812, 601)
		if h ~= decider then add_entity(h, 812, "wpn_test", 601) end
		decider.z_3dss_gamma_camo_system.assign_drop_camo(delayed, "stalker")
		settle()
		weapon(b, 812, 601)
		fire(b, "game_object_on_net_spawn", b.OBJ[812])
		local clear = b.coop_economy_core.pack({ instance = "wpn_test812", state = false })
		b.coop_main.on_event("economy.se", CM_ENCODE({ n = 1, i1 = 812, k1 = CAMO, d1 = clear, x1 = "wpn_test812" }), 0)
		settle()
		check(selection(b, 812) == nil and b.OBJ[812].texture == "base", "m01:5 a deferred NPC camo cannot undo a newer clear")
		if name ~= "hostplay" then
			check(selection(WORLDS[258], 810) ~= nil or WORLDS[258].MDATA.se_object[810] == nil,
				"second map does not invent camo for an absent object")
			weapon(WORLDS[258], 810, 600) settle()
			check(selection(WORLDS[258], 810) and selection(WORLDS[258], 810).section == "wpn_test_green", "m01:5 state follows weapon to second map")
		end

		-- Identity must be checked again when a pending visual finally gets its object.
		local record = decider.MDATA[CAMO] and decider.MDATA[CAMO][810]
		if record then
			b.OBJ[810], b.SE[810], b.MDATA.se_object[810] = nil, nil, nil
			b.MDATA[CAMO][810] = record
			fire(b, "load_state", b.MDATA)
			weapon(b, 810, 600, "replacement/810")
			fire(b, "game_object_on_net_spawn", b.OBJ[810]) settle()
		end
		check(selection(b, 810) == nil and b.OBJ[810].texture == "base", "pending camo cannot paint a reused id")
		-- A reused id must not inherit the previous weapon's jam either.
		b.arti_jamming.set_jam_status(800, 2)
		b.MDATA.se_object[800] = nil
		weapon(b, 800, 0, "replacement/800") b.INV = {800}
		fire(b, "game_object_on_net_spawn", b.OBJ[800])
		check(b.arti_jamming.jammed_guns[800] == nil, "m27:5 jam cannot follow a reused id")
		local trust = b.coop_trust.status()
		check(trust.item_state_instance and trust.item_state_instance.failed > 0, "instance rejection passes through coop_trust")
		-- The extra receiver retains the economy's sender/owner and bounded-parser gates.
		local before = selection(a, 800)
		a.coop_main.on_event("economy.se", CM_ENCODE({ n = 1, i1 = 800, k1 = CAMO,
			d1 = a.coop_economy_core.pack({ instance = "wpn_test800", state = false }) }), 2)
		check(selection(a, 800) == before and a.coop_trust.status().item_state_sender.failed > 0,
			"raw rider receiver refuses a peer posing as the world")
		a.coop_main.on_event("economy.se", CM_ENCODE({ n = -1 }), 0)
		check(a.coop_trust.status().item_state_batch.failed > 0, "negative wire batch is bounded through trust")
		local current = h.MDATA[JAM] and h.MDATA[JAM][800]
		h.coop_main.on_event("economy.se", CM_ENCODE({ n = 1, i1 = 800, k1 = JAM, d1 = h.coop_economy_core.pack(12) }), 1)
		check((h.MDATA[JAM] and h.MDATA[JAM][800]) == current, "malformed jam record never replaces a canonical rider")
		for _, w in pairs(WORLDS) do check(not w.HANDLER_ERRORS, "no handler errors on peer " .. w.PEER) end

		h, a, b, decider = worlds(name ~= "hostplay")
		a.arti_jamming.set_jam_status(800, 3) settle()
		h.coop_main.on_event("economy.imd", CM_ENCODE({ n = 1, i1 = 800, k1 = JAM, x1 = "wpn_test800",
			d1 = h.coop_economy_core.pack(12) }), 1)
		local saved = h.MDATA[JAM][800]
		check(type(saved) == "table" and saved.state == 3, "malformed item update preserves the canonical jam rider")
		h.arti_jamming.jammed_guns = {}
		fire(h, "load_state", h.MDATA)
		check(h.arti_jamming.jammed_guns[800] == 3, "load still restores jam after an invalid item update")

		h, a, b, decider = worlds(name ~= "hostplay")
		handoff(a, b)
		settle()
		local sent = #b.SENT
		b.coop_main.on_event("economy.se", CM_ENCODE({ n = 1, i1 = 800, k1 = JAM, x1 = "wpn_test800",
			d1 = b.coop_economy_core.pack({ instance = "wpn_test800", state = 2 }) }), 0)
		tick(b, 1100)
		check(b.arti_jamming.jammed_guns[800] == 2 and #b.SENT == sent, "received state of own item never echoes through item_poll")

		if name ~= "hostplay" then
			h, a, b, decider = worlds(true, name == "srv_map")
			for id = 816, 817 do
				local gun = weapon(decider, id, 601)
				weapon(b, id, 601)
				decider.z_3dss_gamma_camo_system.assign_drop_camo(gun, "stalker")
			end
			settle() -- World receives the camo while its ALife entity is absent.
			local function clear_via(id, parent, event, from)
				add_entity(h, id, "wpn_test", parent)
				local stamp = "wpn_test" .. id
				local clear = h.coop_economy_core.pack({ instance = stamp, state = false })
				h.coop_main.on_event(event, CM_ENCODE({ n = 1, i1 = id, k1 = CAMO, d1 = clear, x1 = stamp }), from)
			end
			clear_via(816, 601, "economy.se", 257)
			clear_via(817, 501, "economy.imd", 1)
			settle()
			for id, channel in pairs({ [816] = "SE", [817] = "item rider" }) do
				local saved = h.MDATA.se_object[id][CAMO]
				check(saved and saved.state == false and h.MDATA[CAMO][id].state == false,
					"m01:5 deferred NPC camo cannot overwrite the latest " .. channel .. " value in the world save")
			end
			h.z_3dss_gamma_camo_system.load_state({ z_3dss_gamma_camo_system = { selections = {} } })
			fire(h, "load_state", h.MDATA)
			check(selection(h, 816) == nil and selection(h, 817) == nil
				and b.OBJ[816].texture == "base" and b.OBJ[817].texture == "base",
				"m01:5 world reload and observer agree after deferred SE replay")
		end

		h, a, b = worlds(name ~= "hostplay")
		a.arti_jamming.set_jam_status(800, 3) settle()
		local bad = h.coop_economy_core.pack({ instance = "wpn_test800", state = 99 })
		for _, event in ipairs({ "economy.se", "economy.imd" }) do
			local sent = #h.SENT
			h.coop_main.on_event(event, CM_ENCODE({ n = 1, i1 = 800, k1 = JAM, d1 = bad, x1 = "wpn_test800" }), 1)
			check(h.MDATA.se_object[800][JAM].state == 3 and h.MDATA[JAM][800].state == 3,
				event .. " malformed rider never enters the world save")
			check(#h.SENT == sent, event .. " malformed rider is never relayed by the world")
		end
		local good = h.coop_economy_core.pack({
			instance = "wpn_test800", state = { file = "test.ltx", section = "wpn_test_green" },
		})
		local parts = h.coop_economy_core.pack({ barrel = 85 })
		h.coop_main.on_event("economy.se", CM_ENCODE({ n = 3,
			i1 = 800, k1 = JAM, d1 = bad, x1 = "wpn_test800",
			i2 = 800, k2 = CAMO, d2 = good, x2 = "wpn_test800",
			i3 = 800, k3 = "parts", d3 = parts, x3 = "wpn_test800",
		}), 1)
		settle()
		check(b.OBJ[800].texture == "green" and b.arti_jamming.jammed_guns[800] == 3
			and b.MDATA.se_object[800].parts.barrel == 85,
			"invalid entries do not suppress a valid rider or unrelated economy data in the same batch")

		for id, event in pairs({ [818] = "economy.se", [819] = "economy.imd" }) do
			local stamp = "wpn_test" .. id
			local bad_camo = h.coop_economy_core.pack({ instance = stamp, state = { file = "test.ltx" } })
			local sent = #h.SENT
			h.coop_main.on_event(event, CM_ENCODE({ n = 1, i1 = id, k1 = CAMO, d1 = bad_camo, x1 = stamp }), 1)
			add_entity(h, id, "wpn_test", 501)
			settle()
			check(not h.MDATA.se_object[id] and not h.MDATA[CAMO][id] and #h.SENT == sent,
				event .. " malformed camo never enters the deferred queue or relay")
		end

		add_entity(h, 820, "wpn_test", 502)
		local not_mine = h.coop_economy_core.pack({ instance = "wpn_test820", state = 4 })
		local sent_before, owner_trust = #h.SENT, h.coop_trust.status()
		for _, event in ipairs({ "economy.se", "economy.imd" }) do
			local before = owner_trust.item_state_owner and owner_trust.item_state_owner.failed or 0
			h.coop_main.on_event(event, CM_ENCODE({ n = 1, i1 = 820, k1 = JAM, d1 = not_mine, x1 = "wpn_test820" }), 1)
			check(not h.MDATA[JAM][820] and #h.SENT == sent_before
				and owner_trust.item_state_owner and owner_trust.item_state_owner.failed == before + 1,
				event .. " non-owner is checked through trust and cannot write or relay a weapon rider")
		end
		-- dev66 carry_group: the owner line says what the world holds for the item, so a refusal tells a stale view from
		-- a moved item (the probe of the decider's last carry).
		local owner_lines = {}
		for _, line in ipairs(h.LOG) do
			if line:find("item_state_owner: item 820: sender 1 is not its carrier: [wpn_test] parent 502, root ", 1, true) then
				owner_lines[#owner_lines + 1] = line
			end
		end
		check(#owner_lines == 2 and owner_lines[1]:find(" rider, no carry of it seen here (would be refused", 1, true) ~= nil,
			"the owner line names the item, its parent and root, the rider path and the last carry: " .. tostring(owner_lines[1]))

		native_cases(name)
	end
end
print(string.format("mods item state: %d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then error("mods item state FAILED") end
