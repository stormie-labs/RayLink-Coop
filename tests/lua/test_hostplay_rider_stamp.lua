-- TZ 6.28 (P99, review R2, 2026-11-26), Coop mode: an unstamped holder's item riders (jam, camo) and se vars of his weapon reach
-- the host and the other player after an onlooker's repair stamped the host's copy.
-- The co-op host stamps its copy of a magazined weapon on any spawn it writes (coop_requests.cpp -> write_clone_initial ->
-- clone_export), a repair sent to one client included: the host and that client (clone_adopt) hold the stamp, the holder's copy
-- (the save's weapon) holds none, its instance is the weapon's name. Before R2 the host's strict instance checks refused what the
-- holder sent (coop_mods_item_state.script dispatch_riders -> matches_instance "weapon instance changed"; coop_economy_mdata.script
-- on_se / on_imd). R2 (Core, no mode check; the server mode's test: test_srv_rider_stamp.lua): another stamp of the same item, or
-- its bare name, names the same instance (coop_economy_mdata.same_item / item_alias: the same name, and in a stamp the item's host
-- id); the holder check and a value for another item under the id are refused as before.
-- Real G.A.M.M.A. scripts (arti_jamming, z_3dss_gamma_camo_system) and the real coop scripts under the "hostplay" answer set.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")
local CAMO, JAM = "coop_weapon_camo", "coop_weapon_jam"
-- an addon's item rider that only the imd lane carries, no se var behind it (Powered Exos, 3DSS marks, pouches ...): what on_imd and
-- imd_release_held take is seen on its own here, not through the se lane's copy of the jam
local TEST_RIDER = "coop_test_rider"

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

local function weapon(w, id, parent)
	local o = add_item(w, id, "wpn_test", parent)
	o.cast_Weapon = function(self) return self end
	o.texture = "base"
	o.get_shaders = function(self) return { [1] = { texture = self.texture, shader = "model" } } end
	o.set_shader = function(self, _, _, texture) self.texture = texture end
	return o
end

-- The engine's rider ticks (coop.event_tick, coop.released_after) as test_mods_item_state.lua models them: no release here.
local function engine(w)
	w.coop.event_tick = function() return 0, 0 end
	w.coop.released_after = function() return false end
end

-- The co-op host (0) plays on the map with both players; a client is a player mirror of it.
local function setup(peer, mirror)
	local w = make_world(peer)
	engine(w)
	w.coop.is_map_server = function() return false end
	w.coop.is_dedicated = function() return false end
	w.coop.levels = { map_servers = function() return {} end }
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
	w.coop_economy_mdata.declare_item_key(TEST_RIDER)
	load_script(w, "coop_mods_core")
	load_script(w, "coop_trust")
	load_script(w, "coop_mode")
	modes.install(w.coop_mode, "hostplay", mirror and {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
	} or nil)
	local camo = corpus(w, "z_3dss_gamma_camo_system")
	corpus(w, "arti_jamming")
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
	load_script(w, "coop_mods_item_state").on_game_start()
	return w
end

-- The host (0), two players on its map (1 holds the weapon 800, 2 looks on); every process has the weapon online.
local function worlds()
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "next", proxy = 502 } }
	BRIDGES = {}
	POS, QUEUE, WORLDS = {}, {}, {}
	for p in pairs(PLAYERS) do POS[p] = { x = 0, y = 0, z = 0 } end
	local h = setup(0)
	local a = setup(1, true)
	local b = setup(2, true)
	for _, w in pairs(WORLDS) do
		for _, info in pairs(PLAYERS) do add_entity(w, w.coop.to_local_id(info.proxy), "coop_player_avatar") end
		weapon(w, 800, w == a and 0 or 501)
	end
	a.INV = {800}
	tick_all(1100)
	return h, a, b
end

local function settle()
	for _ = 1, 3 do tick_all(1100) for _, w in pairs(WORLDS) do run_time_events(w) end end
end

local function stamp_of(w, id) return w.MDATA.se_object[id] and w.MDATA.se_object[id]._coop_instance end
-- what the rider admission (coop_mods_item_state.script dispatch_riders -> matches_instance) refused for the instance: the log
-- says "item_state_instance: item 800: weapon instance changed"
local function refused(w, what)
	local c = w.coop_trust.status()[what or "item_state_instance"]
	return c and c.failed or 0
end
local function saved_jam(w) return w.MDATA[JAM] and w.MDATA[JAM][800] and w.MDATA[JAM][800].state end
-- the instance this process keeps the weapon's rider `key` under (coop_mods_item_state records)
local function kept_under(w, key)
	local v = w.MDATA[key] and w.MDATA[key][800]
	return type(v) == "table" and v.instance or nil
end
local function saved_camo(w)
	local v = w.MDATA[CAMO] and w.MDATA[CAMO][800]
	return type(v) == "table" and type(v.state) == "table" and v.state.section or nil
end
local function se_var(w) return w.MDATA.se_object[800] and w.MDATA.se_object[800].coop_test_var end
local function no_errors()
	for _, w in pairs(WORLDS) do check(not w.HANDLER_ERRORS, "no handler errors on peer " .. w.PEER) end
end

-- The host's spawn of the weapon for one client (a repair: client_on_spawn Known::Repeat): the host stamps its own copy
-- (write_clone_initial -> clone_export, the engine's replacement::token "<name>/<host id>/<nonce>"), the client takes the stamp
-- (stage_clone_initial, existing -> clone_adopt).
local HOST_STAMP = "wpn_test800/800/5150"
local function repair_for(h, w, label)
	local initial = h.coop_economy_mdata.clone_export(800, HOST_STAMP)
	check(type(initial) == "string" and stamp_of(h, 800) == HOST_STAMP, "the host stamps its copy on the spawn it writes for " .. label)
	check(w.coop_economy_mdata.clone_adopt(800, initial) and stamp_of(w, 800) == HOST_STAMP, label .. " takes the host's stamp")
end

-- The holder's copy names another item under the id 800 (another weapon there: another name, or a stamp of another host id).
local function holder_names(w, stamp)
	w.MDATA.se_object[800] = w.MDATA.se_object[800] or { name = "wpn_test800" }
	w.MDATA.se_object[800]._coop_instance = stamp
end

local function rider(w) return w.MDATA[TEST_RIDER] and w.MDATA[TEST_RIDER][800] and w.MDATA[TEST_RIDER][800].mark end
local function held(w)
	local st = w.coop_economy_mdata._stats()
	return st.imd_held + st.se_held
end
local function refused_values(w)
	local st = w.coop_economy_mdata._stats()
	return st.se_refused + st.imd_refused
end
-- The weapon passes from a to b (his ReqTransfer applied, b picks it up): its parent on every process.
local function handoff(a, b)
	for _, w in pairs(WORLDS) do
		local parent = w == b and 0 or PLAYERS[b.PEER].proxy
		w.SE[800].parent_id = parent
		if w.OBJ[800] then w.OBJ[800]._parent = parent end
	end
	a.INV, b.INV = {}, {800}
end
-- The host drops what the peer sent after its go (host_prepare of a group transition).
local function drop_from(peer)
	local n = 0
	for i = #QUEUE, 1, -1 do
		if QUEUE[i].from == peer and QUEUE[i].to == 0 then
			table.remove(QUEUE, i)
			n = n + 1
		end
	end
	return n
end
-- The host's save as a client loads it: the host's records of the weapon (its stamp included), nothing of the client's machine.
local function save_of(h)
	local copy = h.coop_economy_core.copy
	local save = { se_object = {}, game_object = {} }
	for id, e in pairs(h.MDATA.se_object) do save.se_object[id] = copy(e) end
	for _, key in ipairs({ JAM, CAMO, TEST_RIDER }) do save[key] = copy(h.MDATA[key]) end
	return save
end
-- The client loads the next world: a new Lua state (setup), the session stash stays, the save is the host's (test_economy_trip_carry).
local function reload(old, save, epoch)
	local stash = old.STASH
	local w = setup(old.PEER, true)
	w.STASH = stash
	for _, info in pairs(PLAYERS) do add_entity(w, w.coop.to_local_id(info.proxy), "coop_player_avatar") end
	weapon(w, 800, 0)
	w.INV = {800}
	w.coop.world_epoch = function() return epoch end
	w.MDATA = save
	w.alife_storage_manager.on_before_load_state()
	return w
end

section("P99 R2, co-op: an onlooker's repair stamped the host's copy; the unstamped holder's jam, camo and se var still reach all")
do
	local h, a, b = worlds()
	repair_for(h, b, "the onlooker")
	check(stamp_of(a, 800) == nil, "the holder's copy holds the save's weapon (no stamp: its instance is the weapon's name)")
	local before, b_before = refused(h), refused(b)
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.se_save_var(800, nil, "coop_test_var", 7) -- any se var of the weapon, not only its riders
	a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } } -- and another addon's item rider (the imd lane alone)
	settle()
	check(refused(h) == before, "the host refuses none of his riders (" .. (refused(h) - before) .. " refused)")
	check(rider(h) == "red" and rider(b) == "red", "the host takes another addon's item rider of the weapon under its name and relays it ("
		.. tostring(rider(h)) .. ", " .. tostring(rider(b)) .. ")")
	check(saved_jam(h) == 3 and h.arti_jamming.jammed_guns[800] == 3,
		"the host saves and shows his jam (saved " .. tostring(saved_jam(h)) .. ")")
	check(saved_camo(h) == "wpn_test_green" and h.OBJ[800].texture == "green",
		"the host saves and shows his camo (saved " .. tostring(saved_camo(h)) .. ")")
	check(se_var(h) == 7, "the host stores his se var of the weapon (got " .. tostring(se_var(h)) .. ")")
	check(refused(b) == b_before and b.arti_jamming.jammed_guns[800] == 3, "the onlooker's copy under the host's stamp is jammed")
	check(selection(b, 800) and selection(b, 800).section == "wpn_test_green" and b.OBJ[800].texture == "green",
		"the onlooker sees the camo")
	check(se_var(b) == 7, "the onlooker gets the se var (got " .. tostring(se_var(b)) .. ")")
	check(stamp_of(h, 800) == HOST_STAMP and stamp_of(a, 800) == nil and stamp_of(b, 800) == HOST_STAMP,
		"no process rewrote its own stamp")
	local st = h.coop_economy_mdata._stats()
	check(st.imd_alias >= 1 and st.se_alias >= 1, "the host counts riders and se vars taken under the weapon's name (imd "
		.. st.imd_alias .. ", se " .. st.se_alias .. ")")
	-- he clears the jam later: the clear goes the same way
	a.arti_jamming.unset(800) -- the unjam animation ended
	settle()
	check(saved_jam(h) == 0 and h.arti_jamming.jammed_guns[800] == nil and b.arti_jamming.jammed_guns[800] == nil,
		"his unjam reaches the host and the onlooker (saved " .. tostring(saved_jam(h)) .. ")")
	no_errors()
end

section("P99 R2, co-op: a repair for the holder stamped him and the host; the unstamped onlooker takes the relayed riders")
do
	local h, a, b = worlds()
	repair_for(h, a, "the holder")
	check(stamp_of(b, 800) == nil, "the onlooker's copy holds no stamp")
	local b_before = refused(b)
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(saved_jam(h) == 3, "the host takes his jam under the shared stamp")
	check(b.arti_jamming.jammed_guns[800] == 3 and refused(b) == b_before,
		"the onlooker's unstamped copy takes the relayed jam (refused " .. (refused(b) - b_before) .. ")")
	no_errors()
end

section("P99 R2, co-op: the other guards stay - another item under the id, a rider of a weapon the sender does not hold")
do
	for _, other in ipairs({ "wpn_other800/800/9", "wpn_test800/801/9", "wpn_other800" }) do
		local h, a, b = worlds()
		repair_for(h, b, "the onlooker")
		holder_names(a, other)
		local before, se_before = refused(h), h.coop_economy_mdata._stats().se_refused
		a.arti_jamming.set_jam_status(800, 3)
		a.se_save_var(800, nil, "coop_test_var", 7)
		a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } }
		settle()
		check(refused(h) > before and saved_jam(h) == nil and h.arti_jamming.jammed_guns[800] == nil,
			"the host refuses a jam sent for " .. other .. " (refused " .. (refused(h) - before) .. ")")
		check(se_var(h) == nil and h.coop_economy_mdata._stats().se_refused > se_before, "and an se var sent for " .. other)
		check(rider(h) == nil, "and another addon's item rider sent for " .. other)
		check(b.arti_jamming.jammed_guns[800] == nil and se_var(b) == nil and rider(b) == nil, "the onlooker hears of none of them")
		check(stamp_of(h, 800) == HOST_STAMP, "the host keeps its stamp")
	end
	-- the onlooker (unstamped here, the weapon is not his) writes a rider under the weapon's name: the holder check refuses it
	local h, a, b = worlds()
	repair_for(h, a, "the holder")
	local owner_before = refused(h, "item_state_owner")
	b.se_save_var(800, nil, JAM, { instance = "wpn_test800", state = 2 })
	settle()
	check(refused(h, "item_state_owner") > owner_before and saved_jam(h) == nil,
		"a rider from a player who does not hold the weapon is refused under its name too (holder check)")
	check(a.arti_jamming.jammed_guns[800] == nil, "and the holder never hears of it")
	no_errors()
end

-- Review R2 (finding 1): the economy takes another stamp of the item only when the stamp's name is the item's own (item_alias). A
-- clone transaction's stamp names the clone's SOURCE (coop_requests.cpp replacement::token of prepare_local_clone / host_replace):
-- two transactions into one id are two items, and the source's bare name is another item.
section("P99 R2, co-op: a clone target's stamp names its source - another transaction's stamp, the source's name: refused")
do
	for _, other in ipairs({ "wpn_src700/800/5", "wpn_src700" }) do
		local h, a, b = worlds()
		h.MDATA.se_object[800] = { name = "wpn_test800", _coop_instance = "wpn_src700/800/77" } -- the target of transaction 77
		holder_names(a, other)
		local before = refused_values(h)
		a.se_save_var(800, nil, "coop_test_var", 7)
		a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } }
		settle()
		check(se_var(h) == nil and rider(h) == nil and refused_values(h) >= before + 2,
			"the host refuses an se var and an item rider sent for " .. other .. " (refused " .. (refused_values(h) - before) .. ")")
		check(se_var(b) == nil and rider(b) == nil, "the onlooker hears of neither")
	end
	no_errors()
end

-- Review R2 (finding 1a): coop_mods_item_state observe (actor_on_item_take -> sync_item, and every look of the holder's inventory,
-- capture_inventory) drops a rider of another item from the mod's table. The onlooker's copy holds the host's stamp, the riders
-- he got came under the weapon's name: once the weapon is his, they are his weapon's.
section("P99 R2, co-op: the unstamped holder hands his weapon to the stamped onlooker - jam and camo stay with it")
do
	local h, a, b = worlds()
	repair_for(h, b, "the onlooker")
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	settle()
	check(b.arti_jamming.jammed_guns[800] == 3 and b.OBJ[800].texture == "green", "the onlooker sees his jam and camo")
	check(kept_under(b, JAM) == "wpn_test800", "the onlooker keeps them under the weapon's name")
	-- his ReqTransfer: his client's carry (coop_requests.cpp send_action); the host applies the move (host_move -> carried) under
	-- its own stamp, then the weapon is the onlooker's
	local text = a.coop_mods_item_state.carry(800)
	check(type(text) == "string" and h.coop_mods_item_state.carried(800, 1, text, PLAYERS[1].proxy) == true,
		"the host writes the riders his move carried under the weapon's name")
	handoff(a, b)
	deliver_all()
	fire(b, "actor_on_item_take", b.OBJ[800])
	settle()
	check(b.arti_jamming.jammed_guns[800] == 3 and b.OBJ[800].texture == "green",
		"the onlooker, holding it now, keeps the jam and the camo (jam " .. tostring(b.arti_jamming.jammed_guns[800]) .. ")")
	check(saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green",
		"the host keeps them: the new holder sent no clear (jam " .. tostring(saved_jam(h)) .. ", camo " .. tostring(saved_camo(h)) .. ")")
	check(a.arti_jamming.jammed_guns[800] == 3 and a.OBJ[800].texture == "green", "and the former holder still sees them")
	check(kept_under(b, JAM) == HOST_STAMP, "the new holder keeps them under his own stamp now (one more send, same state)")
	no_errors()
end

-- Review R2 (finding 1b): a client's change of a weapon the host has not made yet is held there (se_hold / imd_hold: a leased
-- create, live 2026-11-08) and checked when the weapon is there (se_release_held, imd_release_held). The host's answer stamps its
-- copy (write_clone_initial on the spawn it writes); his copy keeps the name his changes went under.
section("P99 R2, co-op: his changes held while the host had no such weapon go on under its name once the host stamped it")
do
	local h, a, b = worlds()
	local entity, obj = h.SE[800], h.OBJ[800]
	h.SE[800], h.OBJ[800] = nil, nil -- his weapon under an id the host lent him: the host makes it when it answers
	local before = held(h)
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } }
	for _ = 1, 4 do
		if held(h) >= before + 4 then break end
		tick_all(1100)
	end
	check(held(h) >= before + 4 and saved_jam(h) == nil and se_var(h) == nil and rider(h) == nil,
		"the host holds his jam (both lanes), se var and item rider while it has no such weapon (held " .. (held(h) - before) .. ")")
	h.SE[800], h.OBJ[800] = entity, obj
	check(type(h.coop_economy_mdata.clone_export(800, HOST_STAMP)) == "string" and stamp_of(h, 800) == HOST_STAMP,
		"the host makes the weapon and stamps it on the spawn it writes")
	local refused_before = refused_values(h)
	settle()
	check(saved_jam(h) == 3 and h.arti_jamming.jammed_guns[800] == 3, "the host takes his held jam (got " .. tostring(saved_jam(h)) .. ")")
	check(se_var(h) == 7, "and his held se var (se_release_held; got " .. tostring(se_var(h)) .. ")")
	check(rider(h) == "red", "and his held item rider (imd_release_held; got " .. tostring(rider(h)) .. ")")
	check(refused_values(h) == refused_before, "nothing of it refused (" .. (refused_values(h) - refused_before) .. ")")
	check(b.arti_jamming.jammed_guns[800] == 3 and se_var(b) == 7 and rider(b) == "red", "the onlooker gets all three")
	no_errors()
end

-- Review R2 (finding 1c): the host's load (restore_all -> observe / restore) with riders kept under the weapon's name while its copy
-- holds its stamp.
section("P99 R2, co-op: the host's load keeps the jam and camo it took under the weapon's name")
do
	local h, a = worlds()
	repair_for(h, WORLDS[2], "the onlooker")
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	settle()
	check(kept_under(h, JAM) == "wpn_test800" and stamp_of(h, 800) == HOST_STAMP,
		"the host keeps his riders under the weapon's name, its copy holds its stamp")
	h.arti_jamming.jammed_guns = {}
	h.z_3dss_gamma_camo_system.load_state({ z_3dss_gamma_camo_system = { selections = {} } })
	fire(h, "load_state", h.MDATA)
	settle()
	check(h.arti_jamming.jammed_guns[800] == 3 and selection(h, 800) and selection(h, 800).section == "wpn_test_green",
		"the host's load shows them again")
	check(saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green", "and its save keeps them (jam " .. tostring(saved_jam(h)) .. ")")
	no_errors()
end

-- Review R2 (finding 1d): GAMMA's alife_clone_weapon (a scope, a kit) on the holder moves the riders to the clone (after_clone; the
-- stock order releases the source first: unregister_item keeps its riders for after_clone). A repair for him stamps his copy; if
-- he clones in that frame, before his next look moved his riders to the stamp, they are still under the weapon's name.
section("P99 R2, co-op: his GAMMA clone right after a repair stamped his copy keeps the jam and camo kept under the name")
do
	for _, order in ipairs({ "after_clone", "unregister first" }) do
		local h, a = worlds()
		a.arti_jamming.set_jam_status(800, 3)
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		settle()
		repair_for(h, a, "the holder")
		check(kept_under(a, JAM) == "wpn_test800" and kept_under(a, CAMO) == "wpn_test800",
			order .. ": his riders are still under the weapon's name")
		if order == "unregister first" then
			fire(a, "server_entity_on_unregister", a.SE[800], "se_item_weapon")
			a.MDATA.se_object[800], a.SE[800], a.OBJ[800] = nil, nil, nil
		end
		weapon(a, 902, 0)
		a.coop_economy_mdata.after_clone(800, 902)
		run_time_events(a)
		check(a.arti_jamming.jammed_guns[902] == 3 and selection(a, 902) and selection(a, 902).section == "wpn_test_green",
			order .. ": the clone keeps his jam and camo (jam " .. tostring(a.arti_jamming.jammed_guns[902]) .. ")")
	end
	no_errors()
end

-- Review R2 (finding 1, carry_release): what a client sent just before a load that continues this world (a group transition: the
-- host drops what he sends after its go) comes back with him from the session stash (Build 57). The save he loads is the host's:
-- his copy holds the host's stamp after it, what he kept went under the weapon's name (same_instance).
section("P99 R2, co-op: what he sent under the weapon's name before a group transition comes back with him under the host's stamp")
do
	local h, a, b = worlds()
	repair_for(h, b, "the onlooker")
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	tick(a, 1100)
	check(drop_from(1) >= 2, "the host drops his se and rider batches: they came after its go")
	a.coop.world_epoch = function() return 1 end
	fire(a, "coop_on_world_leaving", 2) -- LoadWait Prepared: the world of the transition has the next epoch
	local save = save_of(h)
	check(save.se_object[800]._coop_instance == HOST_STAMP and saved_jam(h) == nil and se_var(h) == nil,
		"the host's save holds its stamp of the weapon, not his jam or se var")
	local a2 = reload(a, save, 2)
	check(stamp_of(a2, 800) == HOST_STAMP, "his copy holds the host's stamp after the load")
	settle()
	check(saved_jam(h) == 3 and se_var(h) == 7, "the host has his jam and se var now (jam " .. tostring(saved_jam(h)) .. ", var "
		.. tostring(se_var(h)) .. ")")
	check(a2.arti_jamming.jammed_guns[800] == 3, "his machine shows the jam he left with")
	check(b.arti_jamming.jammed_guns[800] == 3 and se_var(b) == 7, "and the onlooker gets them")
	no_errors()
end

-- Review R2 (finding 2): a client's clone (GAMMA scope attach / detach, kits) reaches the host as host_replace -> clone_stage(...,
-- trust 1, ...) (coop_requests.cpp). His snapshot comes from clone_export(source) with no stamp: his unstamped copy's source has
-- none while the host's copy holds its stamp. The host refused it (Reason::NotAllowed): his scope was not attached.
section("P99 R2, co-op: his clone (a scope) of the weapon is staged although his copy holds no stamp and the host's does")
do
	local h, a, b = worlds()
	repair_for(h, b, "the onlooker")
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	settle()
	local token = "wpn_test800/902/77" -- replacement::token of his transaction: the source's name, the target, a nonce
	local snapshot = a.coop_economy_mdata.clone_export(800)
	check(type(snapshot) == "string" and a.coop_economy_core.unpack(snapshot).se._coop_instance == nil,
		"his clone's source carries no stamp (prepare_local_clone)")
	check(a.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snapshot, 0, token), "his machine stages the clone")
	check(h.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snapshot, 1, token),
		"the host stages it: his source under the weapon's name is the source it stamped (was Reason::NotAllowed)")
	weapon(h, 902, PLAYERS[1].proxy)
	check(h.coop_economy_mdata.clone_activate(902), "the host activates the clone's metadata")
	h.coop_economy_mdata.clone_finish(902, true)
	check(h.MDATA.se_object[902] and h.MDATA.se_object[902].coop_test_var == 7, "the clone has his se var on the host")
	check(h.MDATA[JAM] and h.MDATA[JAM][902] and h.MDATA[JAM][902].state == 3 and h.arti_jamming.jammed_guns[902] == 3,
		"and his jam")
	check(h.coop_economy_mdata._stats().clone_alias == 1, "the host counts one clone source taken under another stamp of the item")
	-- his copy under the id is another item: refused as before
	for _, other in ipairs({ "wpn_other800/800/9", "wpn_test800/801/9", "wpn_other800" }) do
		local h2, a2, b2 = worlds()
		repair_for(h2, b2, "the onlooker")
		holder_names(a2, other)
		local snap = a2.coop_economy_mdata.clone_export(800)
		check(h2.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snap, 1, token) == false and h2.MDATA.se_object[902] == nil,
			"the host refuses a clone whose source is " .. other)
	end
	no_errors()
end

print(("%d passed, %d failed"):format(CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
