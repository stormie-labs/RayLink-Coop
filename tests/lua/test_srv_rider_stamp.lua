-- TZ 6.28 (P99, review D1, 2026-11-26), Server mode only: a weapon's item riders (jam, camo) under the stamp its map server gave it
-- are taken by the world server once the world's copy has taken that stamp.
-- The map server of a player's level answers his repair alone (srv/coop_mapserver_rules.h answered_by_his_map_server); its spawn
-- stamps a magazined weapon the world never stamped (loaded from the save) with the map server's instance (write_clone_initial ->
-- clone_export), and the player takes it (client_on_spawn -> stage_clone_initial, existing -> clone_adopt). The world did not: its
-- strict rider lane refused his jam and camo (coop_mods_item_state.script dispatch_riders -> matches_instance, "weapon instance
-- changed"; behind it coop_economy_mdata.script on_imd; an unstamped copy's instance is the weapon's name). Now the world's trunk
-- takes the stamp from that spawn on its way up (coop_trunk.cpp trunk_host_on_tunnel -> requests::adopt_spawn_stamp ->
-- clone_take_stamp, the stamp alone; review R1: not clone_adopt, whose purge dropped the weapon's held changes at the world): the
-- engine's part is native (not built here); its Lua end, clone_take_stamp with the map server's clone initial, is what this test
-- calls on the world. Real G.A.M.M.A. scripts (arti_jamming, z_3dss_gamma_camo_system) and the real coop scripts.
-- Review R2 (Core, both modes; the co-op's own test: test_hostplay_rider_stamp.lua): copies of one weapon still hold different
-- stamps or none (a copy the map server's spawn never reached, a world that stamped the weapon itself). The rider admission and
-- the se / imd instance checks now take another stamp of the same item, or its bare name, as the same instance
-- (coop_economy_mdata.same_item / item_alias, coop_mods_item_state matches_instance: the same name, and in a stamp the item's
-- host id); a value for another item under the id (another name, another host id) is still refused.
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

local function setup(peer, set, mirror)
	local w = make_world(peer)
	engine(w)
	w.coop.is_map_server = function() return BRIDGES[peer] ~= nil end
	w.coop.is_dedicated = function() return peer == 0 end
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
	w.coop_economy_mdata.declare_item_key(TEST_RIDER)
	load_script(w, "coop_mods_core")
	load_script(w, "coop_trust")
	load_script(w, "coop_mode")
	modes.install(w.coop_mode, set, mirror and {
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

-- The world server (0, no map, the weapon in its ALife only), the map server of the level (257), two players on it (1 holds the
-- weapon 800, 2 looks on).
local function worlds()
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "next", proxy = 502 } }
	BRIDGES = { [257] = { nick = "map one", players = {1, 2} } }
	POS, QUEUE, WORLDS = {}, {}, {}
	for p in pairs(PLAYERS) do POS[p] = { x = 0, y = 0, z = 0 } end
	for b in pairs(BRIDGES) do POS[b] = { x = 0, y = 0, z = 0 } end
	local h = setup(0, "srv_world")
	local a = setup(1, "srv_map", true)
	local b = setup(2, "srv_map", true)
	setup(257, "srv_map")
	for _, w in pairs(WORLDS) do
		for _, info in pairs(PLAYERS) do add_entity(w, w.coop.to_local_id(info.proxy), "coop_player_avatar") end
		if w == h then
			add_entity(w, 800, "wpn_test", 501) -- the world's ALife knows the weapon; no game object there
		else
			weapon(w, 800, w == a and 0 or 501)
		end
	end
	a.INV = {800}
	tick_all(1100)
	return h, a, b, WORLDS[257]
end

local function settle()
	for _ = 1, 3 do tick_all(1100) for _, w in pairs(WORLDS) do run_time_events(w) end end
end

local function stamp_of(w, id) return w.MDATA.se_object[id] and w.MDATA.se_object[id]._coop_instance end
-- what the rider admission (coop_mods_item_state.script dispatch_riders -> matches_instance) refused for the instance: on the world
-- its log says "item_state_instance: item 800: weapon instance changed"
local function refused(w)
	local c = w.coop_trust.status().item_state_instance
	return c and c.failed or 0
end
local function saved_jam(w) return w.MDATA[JAM] and w.MDATA[JAM][800] and w.MDATA[JAM][800].state end
local function saved_camo(w)
	local v = w.MDATA[CAMO] and w.MDATA[CAMO][800]
	return type(v) == "table" and type(v.state) == "table" and v.state.section or nil
end
local function no_errors()
	for _, w in pairs(WORLDS) do check(not w.HANDLER_ERRORS, "no handler errors on peer " .. w.PEER) end
end

-- The map server's spawn of the weapon (its answer to a repair, or its spawn to all its players) carries the clone initial under
-- the stamp it gives it now (the engine's replacement::token: "<name>/<host id>/<nonce>"); a player who gets it takes it as a known
-- copy does (client_on_spawn Known::Repeat -> stage_clone_initial, existing -> clone_adopt).
local MAP_STAMP = "wpn_test800/800/4242"
local function map_server_spawn(m)
	local initial = m.coop_economy_mdata.clone_export(800, MAP_STAMP)
	check(type(initial) == "string", "the map server exports the weapon's clone initial under its stamp")
	check(stamp_of(m, 800) == MAP_STAMP, "the map server keeps the stamp it gave (clone_export)")
	return initial
end
local function player_gets(w, initial, label)
	check(w.coop_economy_mdata.clone_adopt(800, initial), label .. " takes the map server's stamp from its spawn")
	check(stamp_of(w, 800) == MAP_STAMP, label .. "'s copy holds the map server's stamp")
end
-- coop_trunk.cpp trunk_host_on_tunnel -> requests::adopt_spawn_stamp -> clone_take_stamp (the fix; review R1: the stamp alone)
local function world_takes(h, initial)
	check(h.coop_economy_mdata.clone_take_stamp(800, initial), "the world takes the stamp of the map server's spawn on its way up")
	check(stamp_of(h, 800) == MAP_STAMP, "the world's copy holds the map server's stamp")
end

-- The copy of the holder names another item under the id 800 (his copy is another weapon there: another name, or a stamp of
-- another host id): what he sends of it is not this weapon's.
local function holder_names(w, stamp)
	w.MDATA.se_object[800] = w.MDATA.se_object[800] or { name = "wpn_test800" }
	w.MDATA.se_object[800]._coop_instance = stamp
end
local function se_var(w) return w.MDATA.se_object[800] and w.MDATA.se_object[800].coop_test_var end
-- the instance this process keeps the weapon's rider `key` under (coop_mods_item_state records)
local function kept_under(w, key)
	local v = w.MDATA[key] and w.MDATA[key][800]
	return type(v) == "table" and v.instance or nil
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
-- The weapon passes from a to b (his ReqTransfer applied by the map server, b picks it up): its parent on every process.
local function handoff(a, b)
	for _, w in pairs(WORLDS) do
		local parent = w == b and 0 or PLAYERS[b.PEER].proxy
		w.SE[800].parent_id = parent
		if w.OBJ[800] then w.OBJ[800]._parent = parent end
	end
	a.INV, b.INV = {}, {800}
end
-- The world drops what the peer sent after it took him for joining again (P6: his trip).
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
-- The world's save as a player loads it: the world's records of the weapon (its stamp included), nothing of his machine.
local function save_of(h)
	local copy = h.coop_economy_core.copy
	local save = { se_object = {}, game_object = {} }
	for id, e in pairs(h.MDATA.se_object) do save.se_object[id] = copy(e) end
	for _, key in ipairs({ JAM, CAMO, TEST_RIDER }) do save[key] = copy(h.MDATA[key]) end
	return save
end
-- His machine loads the next world: a new Lua state (setup), the session stash stays, the save is the world's
-- (test_economy_trip_carry).
local function reload(old, save, epoch)
	local stash = old.STASH
	local w = setup(old.PEER, "srv_map", true)
	w.STASH = stash
	for _, info in pairs(PLAYERS) do add_entity(w, w.coop.to_local_id(info.proxy), "coop_player_avatar") end
	weapon(w, 800, 0)
	w.INV = {800}
	w.coop.world_epoch = function() return epoch end
	w.MDATA = save
	w.alife_storage_manager.on_before_load_state()
	return w
end

section("P99 D1 / R2, server: before the world takes the stamp, his rider under it is taken there (same item, D1 defect gone)")
do
	local h, a, b, m = worlds()
	player_gets(a, map_server_spawn(m), "he")
	check(stamp_of(h, 800) == nil, "the world never stamped the weapon (loaded from the save)")
	local before = refused(h)
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(refused(h) == before and saved_jam(h) == 3,
		"his jam under the map server's stamp is taken by the world whose copy holds the weapon's name (refused "
		.. (refused(h) - before) .. ", saved " .. tostring(saved_jam(h)) .. ")")
	check(b.arti_jamming.jammed_guns[800] == 3, "and the other player's unstamped copy takes the relayed jam")
	check(h.coop_economy_mdata._stats().imd_alias + h.coop_economy_mdata._stats().se_alias >= 1,
		"the world counts a rider taken under another stamp of the same item")
	no_errors()
end

section("P99 D1, server: the world takes the stamp from the map server's spawn, his riders under it are taken and relayed")
do
	local h, a, b, m = worlds()
	local initial = map_server_spawn(m)
	player_gets(a, initial, "he")
	player_gets(b, initial, "the other player") -- the map server's spawn to all its players (or his own repair)
	world_takes(h, initial)
	local before = refused(h)
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	settle()
	check(refused(h) == before, "the world refuses none of his riders (" .. (refused(h) - before) .. " refused)")
	check(saved_jam(h) == 3, "the world saves his jam (got " .. tostring(saved_jam(h)) .. ")")
	check(saved_camo(h) == "wpn_test_green", "the world saves his camo (got " .. tostring(saved_camo(h)) .. ")")
	check(b.arti_jamming.jammed_guns[800] == 3, "the other player's copy under the same stamp is jammed")
	check(selection(b, 800) and selection(b, 800).section == "wpn_test_green" and b.OBJ[800].texture == "green",
		"the other player sees the camo")
	-- the same stamp again (his next repair, another player's answer): taken again, nothing changes
	check(h.coop_economy_mdata.clone_take_stamp(800, m.coop_economy_mdata.clone_export(800, "wpn_test800/800/4243")),
		"a later spawn of the weapon under the same stamp is taken again")
	check(stamp_of(h, 800) == MAP_STAMP and stamp_of(m, 800) == MAP_STAMP, "the stamp stays the map server's first one")
	check(saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green", "and the world keeps his riders")
	no_errors()
end

section("P99 D1 / R2, server: a weapon the world stamped otherwise keeps the world's stamp, his rider under the map's is taken")
do
	local h, a, b, m = worlds()
	local world_stamp = "wpn_test800/800/17"
	check(type(h.coop_economy_mdata.clone_export(800, world_stamp)) == "string" and stamp_of(h, 800) == world_stamp,
		"the world stamped the weapon itself (its own answer while the map server was not connected)")
	local initial = map_server_spawn(m)
	player_gets(a, initial, "he")
	check(h.coop_economy_mdata.clone_take_stamp(800, initial) == false, "the world refuses the map server's other stamp")
	check(stamp_of(h, 800) == world_stamp, "and keeps its own")
	local before = refused(h)
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(refused(h) == before and saved_jam(h) == 3,
		"his rider under the map server's stamp is taken there: another stamp of the same item (R2; was the known limit)")
	check(stamp_of(h, 800) == world_stamp and stamp_of(a, 800) == MAP_STAMP, "no process rewrote its own stamp")
	check(b.arti_jamming.jammed_guns[800] == 3, "and the other player's unstamped copy takes it from the world")
	no_errors()
end

-- R2 (was the known limit of D1): every copy need not hold the same stamp. A copy that still holds the save's weapon (no stamp: its
-- instance is the weapon's name) takes a rider under the map server's stamp, and the world that took that stamp takes that copy's
-- own rider under the weapon's name. A value for another item under the id is still refused.
section("P99 D1 / R2, server: a copy the map server's spawn never reached holds no stamp - its riders still go both ways")
do
	local h, a, b, m = worlds()
	local initial = map_server_spawn(m)
	player_gets(a, initial, "he")
	world_takes(h, initial)
	local b_before = refused(b)
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(saved_jam(h) == 3, "the world takes his jam under the map server's stamp")
	check(b.arti_jamming.jammed_guns[800] == 3 and refused(b) == b_before,
		"the other player's copy, never stamped, takes the relayed jam (the weapon's name names the same item)")
	-- the holder never got the map server's spawn of his own weapon, another player's repair did: the world took the stamp
	h, a, b, m = worlds()
	initial = map_server_spawn(m)
	player_gets(b, initial, "the other player")
	world_takes(h, initial)
	check(stamp_of(a, 800) == nil, "the holder's copy holds the save's weapon (no stamp)")
	local before = refused(h)
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	a.se_save_var(800, nil, "coop_test_var", 7) -- any se var of the weapon, not only its riders
	a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } } -- and another addon's item rider (the imd lane alone)
	settle()
	check(rider(h) == "red" and rider(b) == "red", "the world takes another addon's item rider of the weapon under its name and "
		.. "relays it (" .. tostring(rider(h)) .. ", " .. tostring(rider(b)) .. ")")
	check(refused(h) == before and saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green",
		"the world takes the holder's jam and camo under the weapon's name once it took the map server's stamp (refused "
		.. (refused(h) - before) .. ", jam " .. tostring(saved_jam(h)) .. ", camo " .. tostring(saved_camo(h)) .. ")")
	check(se_var(h) == 7, "and his se var of the weapon (got " .. tostring(se_var(h)) .. ")")
	check(b.arti_jamming.jammed_guns[800] == 3 and b.OBJ[800].texture == "green" and se_var(b) == 7,
		"the other player's copy under the map server's stamp gets his jam, camo and se var")
	check(stamp_of(h, 800) == MAP_STAMP and stamp_of(a, 800) == nil and stamp_of(b, 800) == MAP_STAMP,
		"no process rewrote its own stamp")
	-- the same without the world's stamp: the world, unstamped too, takes the holder's jam (as before D1)
	h, a, b, m = worlds()
	player_gets(b, map_server_spawn(m), "the other player")
	before = refused(h)
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(refused(h) == before and saved_jam(h) == 3, "without the world's stamp the unstamped holder's jam is taken")
	no_errors()
end

section("P99 R2, server: a value for another item under the id is still refused (another name, another host id)")
do
	for _, other in ipairs({ "wpn_other800/800/9", "wpn_test800/801/9", "wpn_other800" }) do
		local h, a, b, m = worlds()
		local initial = map_server_spawn(m)
		player_gets(b, initial, "the other player")
		world_takes(h, initial)
		holder_names(a, other)
		local before, se_before = refused(h), h.coop_economy_mdata._stats().se_refused
		a.arti_jamming.set_jam_status(800, 3)
		a.se_save_var(800, nil, "coop_test_var", 7)
		a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } }
		settle()
		check(refused(h) > before and saved_jam(h) == nil,
			"the world refuses a jam sent for " .. other .. " (refused " .. (refused(h) - before) .. ")")
		check(se_var(h) == nil and h.coop_economy_mdata._stats().se_refused > se_before,
			"and an se var sent for " .. other)
		check(rider(h) == nil, "and another addon's item rider sent for " .. other)
		check(b.arti_jamming.jammed_guns[800] == nil and se_var(b) == nil and rider(b) == nil,
			"the other player hears of none of them")
		check(stamp_of(h, 800) == MAP_STAMP, "the world keeps its stamp")
	end
	no_errors()
end

-- Review R1: the world takes the stamp alone. A player's change of a weapon not in the world's ALife yet waits there (host_holds:
-- se_hold / imd_hold) and goes on with the world's next Lua tick; the weapon's spawn can pass the trunk between its registration
-- and that tick. clone_adopt's purge (clone_purge) dropped such a held change, and every pending change of the weapon in se_out;
-- clone_take_stamp keeps them. The contrast runs clone_adopt at the world as the first D1 code did.
section("P99 D1 R1, server: the stamp alone - a change the world holds for the weapon survives the take")
do
	local function held(h)
		local st = h.coop_economy_mdata._stats()
		return st.imd_held + st.se_held
	end
	for _, take in ipairs({ "clone_take_stamp", "clone_adopt" }) do
		local h, a, b, m = worlds()
		local entity = h.SE[800]
		h.SE[800] = nil -- not registered at the world yet
		local initial = map_server_spawn(m)
		player_gets(a, initial, "he")
		player_gets(b, initial, "the other player")
		local before = held(h)
		a.arti_jamming.set_jam_status(800, 3)
		for _ = 1, 4 do
			if held(h) > before then break end
			tick_all(1100)
		end
		check(held(h) > before and saved_jam(h) == nil, take .. ": the world holds his jam while it has no such weapon")
		h.SE[800] = entity -- registered now; its spawn passes the trunk before the world's next Lua tick
		check(h.coop_economy_mdata[take](800, initial), take .. ": the world takes the map server's stamp")
		check(stamp_of(h, 800) == MAP_STAMP, take .. ": the world's copy holds it")
		local s0 = h.coop_economy_mdata._stats()
		local in0, refused0 = s0.imd_in + s0.se_in, s0.imd_refused + s0.se_refused
		settle()
		local s1 = h.coop_economy_mdata._stats()
		local taken, refused_now = s1.imd_in + s1.se_in - in0, s1.imd_refused + s1.se_refused - refused0
		if take == "clone_take_stamp" then
			check(taken >= 2 and refused_now == 0, "both held changes (rider and SE lane) go on with the world's next tick (taken "
				.. taken .. ", refused " .. refused_now .. ")")
			check(saved_jam(h) == 3, "the world saves the held jam (got " .. tostring(saved_jam(h)) .. ")")
			check(b.arti_jamming.jammed_guns[800] == 3, "and it reaches the other player under the same stamp")
		else
			check(taken == 0 and refused_now == 0 and saved_jam(h) == nil,
				"before R1: clone_adopt's purge dropped the held changes, neither taken nor refused (taken " .. taken .. ")")
		end
	end
	no_errors()
end

-- Review R2 (finding 1): the economy takes another stamp of the item only when the stamp's name is the item's own (item_alias). A
-- clone transaction's stamp names the clone's SOURCE (coop_requests.cpp replacement::token of prepare_local_clone / host_replace):
-- two transactions into one id are two items, and the source's bare name is another item.
section("P99 R2, server: a clone target's stamp names its source - another transaction's stamp, the source's name: refused")
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
			"the world refuses an se var and an item rider sent for " .. other .. " (refused " .. (refused_values(h) - before) .. ")")
		check(se_var(b) == nil and rider(b) == nil, "the other player hears of neither")
	end
	no_errors()
end

-- Review R2 (finding 1a): coop_mods_item_state observe (actor_on_item_take -> sync_item, and every look of the holder's inventory,
-- capture_inventory) drops a rider of another item from the mod's table. The other player's copy holds the map server's stamp, the
-- riders he got came under the weapon's name: once the weapon is his, they are his weapon's.
section("P99 R2, server: the unstamped holder hands his weapon to the stamped other player - jam and camo stay with it")
do
	local h, a, b, m = worlds()
	local initial = map_server_spawn(m)
	player_gets(b, initial, "the other player")
	world_takes(h, initial)
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	settle()
	check(b.arti_jamming.jammed_guns[800] == 3 and b.OBJ[800].texture == "green", "the other player sees his jam and camo")
	check(kept_under(b, JAM) == "wpn_test800", "the other player keeps them under the weapon's name")
	-- his ReqTransfer: his client's carry (coop_requests.cpp send_action); the map server of his level applies the move
	-- (host_move -> carried) under its own stamp, then the weapon is the other player's
	local text = a.coop_mods_item_state.carry(800)
	check(type(text) == "string" and m.coop_mods_item_state.carried(800, 1, text, PLAYERS[1].proxy) == true,
		"the map server writes the riders his move carried under the weapon's name")
	handoff(a, b)
	deliver_all()
	fire(b, "actor_on_item_take", b.OBJ[800])
	settle()
	check(b.arti_jamming.jammed_guns[800] == 3 and b.OBJ[800].texture == "green",
		"the other player, holding it now, keeps the jam and the camo (jam " .. tostring(b.arti_jamming.jammed_guns[800]) .. ")")
	check(saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green",
		"the world keeps them: the new holder sent no clear (jam " .. tostring(saved_jam(h)) .. ", camo " .. tostring(saved_camo(h)) .. ")")
	check(a.arti_jamming.jammed_guns[800] == 3 and a.OBJ[800].texture == "green", "and the former holder still sees them")
	check(kept_under(b, JAM) == MAP_STAMP, "the new holder keeps them under his own stamp now (one more send, same state)")
	no_errors()
end

-- Review R2 (finding 1b), as section R1 but under the weapon's name: the holder's copy never got the map server's spawn.
section("P99 R2, server: his changes held while the world had no such weapon go on under its name once it took the map's stamp")
do
	local h, a, b, m = worlds()
	local entity = h.SE[800]
	h.SE[800] = nil -- not registered at the world yet
	local initial = map_server_spawn(m)
	player_gets(b, initial, "the other player")
	local before = held(h)
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	a.MDATA[TEST_RIDER] = { [800] = { mark = "red" } }
	for _ = 1, 4 do
		if held(h) >= before + 4 then break end
		tick_all(1100)
	end
	check(held(h) >= before + 4 and saved_jam(h) == nil and se_var(h) == nil and rider(h) == nil,
		"the world holds his jam (both lanes), se var and item rider while it has no such weapon (held " .. (held(h) - before) .. ")")
	h.SE[800] = entity -- registered now; its spawn passes the trunk before the world's next Lua tick
	world_takes(h, initial)
	local refused_before = refused_values(h)
	settle()
	check(saved_jam(h) == 3, "the world takes his held jam under the weapon's name (got " .. tostring(saved_jam(h)) .. ")")
	check(se_var(h) == 7, "and his held se var (se_release_held; got " .. tostring(se_var(h)) .. ")")
	check(rider(h) == "red", "and his held item rider (imd_release_held; got " .. tostring(rider(h)) .. ")")
	check(refused_values(h) == refused_before, "nothing of it refused (" .. (refused_values(h) - refused_before) .. ")")
	check(b.arti_jamming.jammed_guns[800] == 3 and se_var(b) == 7 and rider(b) == "red", "the other player gets all three")
	no_errors()
end

-- Review R2 (finding 1c): the world's load (restore_all -> observe / restore) with riders kept under the weapon's name while its
-- copy holds the map server's stamp.
section("P99 R2, server: the world's load keeps the jam and camo it took under the weapon's name")
do
	local h, a, b, m = worlds()
	local initial = map_server_spawn(m)
	player_gets(b, initial, "the other player")
	world_takes(h, initial)
	a.arti_jamming.set_jam_status(800, 3)
	a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
	settle()
	check(kept_under(h, JAM) == "wpn_test800" and stamp_of(h, 800) == MAP_STAMP,
		"the world keeps his riders under the weapon's name, its copy holds the map server's stamp")
	h.arti_jamming.jammed_guns = {}
	h.z_3dss_gamma_camo_system.load_state({ z_3dss_gamma_camo_system = { selections = {} } })
	fire(h, "load_state", h.MDATA)
	settle()
	check(saved_jam(h) == 3 and saved_camo(h) == "wpn_test_green", "the world's load keeps them (jam " .. tostring(saved_jam(h)) .. ")")
	check(h.arti_jamming.jammed_guns[800] == 3 and selection(h, 800) and selection(h, 800).section == "wpn_test_green",
		"and restores them into the mods' tables")
	no_errors()
end

-- Review R2 (finding 1d): GAMMA's alife_clone_weapon (a scope, a kit) on the holder moves the riders to the clone (after_clone; the
-- stock order releases the source first: unregister_item keeps its riders for after_clone). The map server's spawn stamps his copy;
-- if he clones in that frame, before his next look moved his riders to the stamp, they are still under the weapon's name.
section("P99 R2, server: his GAMMA clone right after the map server's spawn stamped his copy keeps the jam and camo")
do
	for _, order in ipairs({ "after_clone", "unregister first" }) do
		local h, a, b, m = worlds()
		a.arti_jamming.set_jam_status(800, 3)
		a.z_3dss_gamma_camo_system.select_camo(a.OBJ[800], "test.ltx", "wpn_test_green")
		settle()
		player_gets(a, map_server_spawn(m), "he")
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

-- Review R2 (finding 1d, clone_export): a process that stamps a weapon it holds no stamp of (write_clone_initial -> clone_export
-- with a stamp) moves the riders it keeps of that weapon to the stamp before it exports them (coop_mods_item_state's wrapper):
-- also those under another stamp of the same item. A world that did not take the map server's stamp (an engine before D1) keeps
-- his riders under it; then it answers a repair itself (its map server not connected) with its own stamp.
section("P99 R2, server: the world's own stamp - the riders it kept under the map server's stamp move to it and go with its spawn")
do
	local h, a, b, m = worlds()
	player_gets(a, map_server_spawn(m), "he")
	a.arti_jamming.set_jam_status(800, 3)
	settle()
	check(saved_jam(h) == 3 and kept_under(h, JAM) == MAP_STAMP and stamp_of(h, 800) == nil,
		"the unstamped world keeps his jam under the map server's stamp")
	local world_stamp = "wpn_test800/800/17"
	local initial = h.coop_economy_mdata.clone_export(800, world_stamp)
	check(stamp_of(h, 800) == world_stamp and kept_under(h, JAM) == world_stamp,
		"the world stamps its copy; the jam it kept under another stamp of the weapon moves to its stamp (" .. tostring(kept_under(h, JAM)) .. ")")
	local riders = type(initial) == "string" and h.coop_economy_core.unpack(initial).riders or {}
	check(type(riders[JAM]) == "table" and riders[JAM].instance == world_stamp and riders[JAM].state == 3,
		"its spawn carries the jam under the stamp it gives")
	no_errors()
end

-- Review R2 (finding 1, carry_release): what a player sent just before his trip (the world drops what he sends between his trip
-- request and his rejoin, P6) comes back with him from the session stash (Build 57). The save he loads is the world's: his copy
-- holds the world's stamp after it, what he kept went under the weapon's name (same_instance).
section("P99 R2, server: what he sent under the weapon's name before his trip comes back with him under the world's stamp")
do
	local h, a, b, m = worlds()
	local initial = map_server_spawn(m)
	player_gets(b, initial, "the other player")
	world_takes(h, initial)
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	tick(a, 1100)
	check(drop_from(1) >= 2, "the world drops his se and rider batches (P6)")
	a.coop.world_epoch = function() return 1 end
	fire(a, "coop_on_world_leaving", 1) -- the same epoch: the world goes on, only he comes into it anew
	local save = save_of(h)
	check(save.se_object[800]._coop_instance == MAP_STAMP and saved_jam(h) == nil and se_var(h) == nil,
		"the world's save holds the map server's stamp of the weapon, not his jam or se var")
	local a2 = reload(a, save, 1)
	check(stamp_of(a2, 800) == MAP_STAMP, "his copy holds the world's stamp after the load")
	settle()
	check(saved_jam(h) == 3 and se_var(h) == 7, "the world has his jam and se var now (jam " .. tostring(saved_jam(h)) .. ", var "
		.. tostring(se_var(h)) .. ")")
	check(a2.arti_jamming.jammed_guns[800] == 3, "his machine shows the jam he left with")
	check(b.arti_jamming.jammed_guns[800] == 3 and se_var(b) == 7, "and the other player gets them")
	no_errors()
end

-- Review R2 (finding 1, se_wait and the item riders' se listener): a map server's word on a weapon the world has not registered
-- yet waits at the world (se_wait: a map server's value is not held as a player's is) and is stored once the weapon is there; the
-- map's copy holds its stamp, the world's (the save's weapon) none. A newer word of the holder, held meanwhile, comes first then:
-- the map's older jam replayed from the wait must not replace it (coop_mods_item_state on_se_value keeps the last admitted one).
section("P99 R2, server: the map server's word waiting for the weapon at the world is taken under the map's stamp, a newer one wins")
do
	local h, a, b, m = worlds()
	local entity = h.SE[800]
	h.SE[800] = nil -- not registered at the world yet
	player_gets(b, map_server_spawn(m), "the other player")
	m.se_save_var(800, nil, "coop_test_var", 9) -- the map server's own word on the weapon
	m.se_save_var(800, nil, JAM, { instance = MAP_STAMP, state = 2 }) -- and its record of the jam, as its carried writes one
	tick_all(1100)
	check(se_var(h) == nil and h.coop_economy_mdata._stats().se_pending >= 1, "the world has no such weapon: the map's words wait")
	a.arti_jamming.set_jam_status(800, 3) -- his newer jam, under the weapon's name: held at the world
	for _ = 1, 4 do
		if held(h) >= 2 then break end
		tick_all(1100)
	end
	h.SE[800] = entity -- registered now, never stamped here
	local function jams()
		local se_jam = h.MDATA.se_object[800] and h.MDATA.se_object[800][JAM]
		return saved_jam(h), type(se_jam) == "table" and se_jam.state or nil
	end
	-- the world's next se flush (300 ms) releases what it held and what waited, before its next look at the riders (1 s), which
	-- would bring his jam once more from the imd lane: what the world keeps and relays in between is the se lane's
	tick(h, 400)
	local rider_jam, se_jam = jams()
	check(se_var(h) == 9, "the map's word under its stamp is taken: another stamp of the same weapon (got " .. tostring(se_var(h)) .. ")")
	check(rider_jam == 3 and se_jam == 3, "his newer jam stays: the map's older one from the wait does not replace it (rider "
		.. tostring(rider_jam) .. ", se " .. tostring(se_jam) .. ")")
	settle()
	rider_jam, se_jam = jams()
	check(rider_jam == 3 and se_jam == 3 and b.arti_jamming.jammed_guns[800] == 3, "and stays after the next looks (rider "
		.. tostring(rider_jam) .. ", se " .. tostring(se_jam) .. ")")
	no_errors()
end

-- Review R2 (finding 2): a player's clone (GAMMA scope attach / detach, kits) reaches the authority of his level, the map server
-- (ReqSpawn is Scope::Map), as host_replace -> clone_stage(..., trust 1, ...). His snapshot comes from clone_export(source) with no
-- stamp. Before: refused (Reason::NotAllowed) whenever his copy and the map server's held different stamps or one held none.
section("P99 R2, server: his clone (a scope) is staged by the map server whichever of the two copies holds a stamp")
do
	local token = "wpn_test800/902/77" -- replacement::token of his transaction: the source's name, the target, a nonce
	local function clone_at(m, a, label)
		local snapshot = a.coop_economy_mdata.clone_export(800)
		check(type(snapshot) == "string" and a.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snapshot, 0, token),
			label .. ": his machine stages the clone")
		check(m.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snapshot, 1, token),
			label .. ": the map server stages it (was Reason::NotAllowed)")
		weapon(m, 902, PLAYERS[1].proxy)
		check(m.coop_economy_mdata.clone_activate(902), label .. ": the map server activates the clone's metadata")
		m.coop_economy_mdata.clone_finish(902, true)
		check(m.MDATA.se_object[902] and m.MDATA.se_object[902].coop_test_var == 7, label .. ": the clone has his se var there")
		check(m.MDATA[JAM] and m.MDATA[JAM][902] and m.MDATA[JAM][902].state == 3 and m.arti_jamming.jammed_guns[902] == 3,
			label .. ": and his jam")
		check(m.coop_economy_mdata._stats().clone_alias == 1, label .. ": the map server counts one clone source taken under another stamp")
	end
	-- the map server's spawn reached the other player only: the map server's copy holds its stamp, his none
	local h, a, b, m = worlds()
	player_gets(b, map_server_spawn(m), "the other player")
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	settle()
	clone_at(m, a, "map stamped, he not")
	-- the world answered his repair (its stamp on him), the map server's copy is the save's (fixture p99_srv case 3)
	h, a, b, m = worlds()
	local world_stamp = "wpn_test800/800/17"
	check(a.coop_economy_mdata.clone_adopt(800, h.coop_economy_mdata.clone_export(800, world_stamp)) and stamp_of(a, 800) == world_stamp,
		"he takes the world's stamp from its answer to his repair")
	a.arti_jamming.set_jam_status(800, 3)
	a.se_save_var(800, nil, "coop_test_var", 7)
	settle()
	check(stamp_of(m, 800) == nil, "the map server's copy holds no stamp")
	clone_at(m, a, "he stamped by the world, the map server not")
	-- his copy under the id is another item: refused as before
	for _, other in ipairs({ "wpn_other800/800/9", "wpn_test800/801/9", "wpn_other800" }) do
		h, a, b, m = worlds()
		player_gets(b, map_server_spawn(m), "the other player")
		holder_names(a, other)
		local snap = a.coop_economy_mdata.clone_export(800)
		check(m.coop_economy_mdata.clone_stage(800, 902, "wpn_test902", snap, 1, token) == false and m.MDATA.se_object[902] == nil,
			"the map server refuses a clone whose source is " .. other)
	end
	no_errors()
end

print(("%d passed, %d failed"):format(CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
