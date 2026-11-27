-- Unit I (2026-11-27), both modes: a player's machine never sends the item rider (camo, jam) of a weapon it does not carry.
-- The stand (dev66b feed_server, dev66 carry_group) logged "[coop-trust] ! item_state_owner: item 19226: sender 2 is not its carrier:
-- [wpn_svu] parent 19224, root 19224 [sim_default_ecolog_1] ... se rider, no carry of it seen here": a player's copy echoed the rider
-- of an NPC's weapon back to the world. The path: a roster repair (coop_roster.cpp client_on_roster, "repair 0x01") makes the
-- decider send the holder's subtree again; the weapon, already here, is a repeat (coop_entities.cpp client_on_spawn Known::Repeat ->
-- coop_requests_clone.cpp stage_clone_initial, existing -> coop_economy_mdata.script clone_adopt), and clone_adopt queued every
-- se var of it for the next flush (se_queue), the riders the save gave this copy included: not this player's to write.
-- The fix: on a player's mirror clone_adopt resends only what this machine may write (mine_to_write, the rule carry_release
-- follows: his own item, or a world flag on an entity no other player holds). His own weapon's riders still go (control below).
-- Real G.A.M.M.A. scripts (arti_jamming, z_3dss_gamma_camo_system) and the real coop scripts.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")
local CAMO = "coop_weapon_camo"

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

local function weapon(w, id, parent)
	local o = add_item(w, id, "wpn_test", parent)
	o.cast_Weapon = function(self) return self end
	o.texture = "base"
	o.get_shaders = function(self) return { [1] = { texture = self.texture, shader = "model" } } end
	o.set_shader = function(self, _, _, texture) self.texture = texture end
	return o
end

local function setup(peer, set, mirror, bridge)
	local w = make_world(peer)
	w.coop.event_tick = function() return 0, 0 end
	w.coop.released_after = function() return false end
	w.coop.is_map_server = function() return bridge == true end
	w.coop.is_dedicated = function() return set == "srv_world" end
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

local NPC, NPC_GUN, OWN_GUN = 600, 800, 900
local STAMP = "wpn_test800/800/4242" -- the decider's stamp of the NPC's weapon (replacement::token "<name>/<host id>/<nonce>")
local OWN_STAMP = "wpn_test900/900/4343"
local function record(instance, sec) return { instance = instance, state = { file = "test.ltx", section = sec } } end

-- Both modes: the decider (the co-op host, or the map server of the level under the world server), the player 1 who carries the
-- weapon 900, the player 2 who only looks at the NPC 600 and its weapon 800.
local function worlds(mode)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 }, [2] = { nick = "next", proxy = 502 } }
	POS, QUEUE, WORLDS = {}, {}, {}
	BRIDGES = mode == "srv" and { [257] = { nick = "map one", players = {1, 2} } } or {}
	for p in pairs(PLAYERS) do POS[p] = { x = 0, y = 0, z = 0 } end
	for b in pairs(BRIDGES) do POS[b] = { x = 0, y = 0, z = 0 } end
	local h = setup(0, mode == "srv" and "srv_world" or "hostplay")
	local a = setup(1, mode == "srv" and "srv_map" or "hostplay", true)
	local b = setup(2, mode == "srv" and "srv_map" or "hostplay", true)
	local m = mode == "srv" and setup(257, "srv_map", false, true) or h
	for _, w in pairs(WORLDS) do
		for _, info in pairs(PLAYERS) do add_entity(w, w.coop.to_local_id(info.proxy), "coop_player_avatar") end
		add_entity(w, NPC, "sim_default_ecolog_1")
		if w == h and mode == "srv" then
			add_entity(w, NPC_GUN, "wpn_test", NPC) -- the world server's ALife only
			add_entity(w, OWN_GUN, "wpn_test", 501)
		else
			weapon(w, NPC_GUN, NPC)
			weapon(w, OWN_GUN, w == a and 0 or 501)
		end
		-- What the save gave every copy: the NPC's camo (the decider's npc_camo_drops) under the decider's stamp, and the
		-- player 1's camo of his weapon.
		w.MDATA[CAMO] = { [NPC_GUN] = record(STAMP, "wpn_test_green"), [OWN_GUN] = record(OWN_STAMP, "wpn_test") }
		w.MDATA.se_object[NPC_GUN] = { name = "wpn_test800", _coop_instance = STAMP, [CAMO] = record(STAMP, "wpn_test_green") }
		w.MDATA.se_object[OWN_GUN] = { name = "wpn_test900", _coop_instance = OWN_STAMP, [CAMO] = record(OWN_STAMP, "wpn_test") }
	end
	a.INV = {OWN_GUN}
	tick_all(1100)
	return h, a, b, m
end

local function settle()
	for _ = 1, 3 do tick_all(1100) for _, w in pairs(WORLDS) do run_time_events(w) end end
end

local function not_carrier(w)
	local c = w.coop_trust.status().item_state_owner
	return c and c.failed or 0
end
local function refusals()
	local n = 0
	for _, w in pairs(WORLDS) do n = n + not_carrier(w) end
	return n
end

for _, mode in ipairs({ "hostplay", "srv" }) do
	section(mode .. ": a roster repair's repeat spawn of an NPC's weapon on an onlooker's copy (clone_adopt)")
	local h, a, b, m = worlds(mode)
	-- The onlooker's copy holds the rider under the bare name (its save came before the decider's stamp; same item, alias).
	b.MDATA.se_object[NPC_GUN][CAMO] = record("wpn_test800", "wpn_test_green")
	b.MDATA[CAMO][NPC_GUN] = record("wpn_test800", "wpn_test_green")
	local before = refusals()
	local initial = m.coop_economy_mdata.clone_export(NPC_GUN, STAMP)
	check(type(initial) == "string", mode .. ": the decider writes the weapon's clone initial (write_clone_initial)")
	check(b.coop_economy_mdata.clone_adopt(NPC_GUN, initial), mode .. ": the onlooker adopts the repeat (stage_clone_initial existing)")
	settle()
	check(refusals() == before, mode .. ": nobody sees the onlooker send the NPC weapon's rider (item_state_owner: "
		.. tostring(refusals() - before) .. " not-carrier line(s), 0 wanted)")
	local kept = h.MDATA[CAMO] and h.MDATA[CAMO][NPC_GUN]
	check(type(kept) == "table" and kept.instance == STAMP, mode .. ": the world keeps the decider's record of the NPC's weapon")

	section(mode .. ": the carrier's own weapon still resends what his copy holds (clone_adopt keeps his riders going)")
	-- What the adopt queues for the next flush (coop_economy_mdata se_out, "<host id> <var>").
	local function queued(w, hid)
		local out = w.coop_mods_core.find_local(w.coop_economy_mdata, "se_out")
		return type(out) == "table" and out[tostring(hid) .. " " .. CAMO] ~= nil
	end
	a.MDATA.se_object[OWN_GUN][CAMO] = record(OWN_STAMP, "wpn_test_green") -- his copy's own newer value
	local own = m.coop_economy_mdata.clone_export(OWN_GUN, OWN_STAMP)
	check(a.coop_economy_mdata.clone_adopt(OWN_GUN, own), mode .. ": the carrier adopts his weapon's repeat")
	check(queued(a, OWN_GUN), mode .. ": the carrier's adopt queues his weapon's camo for the world")
	local again = m.coop_economy_mdata.clone_export(NPC_GUN, STAMP)
	check(b.coop_economy_mdata.clone_adopt(NPC_GUN, again), mode .. ": the onlooker adopts another repeat of the NPC's weapon")
	check(not queued(b, NPC_GUN), mode .. ": the onlooker's adopt queues nothing of the NPC weapon's camo")
	settle()
	check(refusals() == before, mode .. ": still no not-carrier line")
	for _, w in pairs(WORLDS) do check(not w.HANDLER_ERRORS, mode .. ": no handler errors on peer " .. w.PEER) end
end

print(("%d passed, %d failed"):format(CHECKS - FAILS, FAILS))
if FAILS > 0 then os.exit(1) end
