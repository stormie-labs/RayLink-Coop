-- G10-3, Dev 57. Exercise both wire formats. Use the actual RF functions when the review corpus is present.
-- A world's report sender is a transport peer without a playing seat; its world has no inventory to inspect.
local modes = dofile("tests/lua/support/modes.lua")
local total_passed, total_failed = 0, 0
local function read(path, optional)
	local f, err = io.open(path, "r")
	if not f and optional then return nil end
	assert(f, err)
	local s = f:read("*a") f:close() return s
end
local stock = read("temp/review/corpus/merged/item_radio.script", true)
local party = read("gamedata/scripts/coop_quests_party.script")
local function fragment(src, first, after)
	local a = assert(src:find(first, 1, true))
	local b = assert(src:find(after, a + #first, true))
	return src:sub(a, b - 1)
end
local function chunk(src, env)
	local f = assert(loadstring(src)) setfenv(f, env) return f()
end

-- The untracked GAMMA review corpus is absent on a clean checkout.
local function install_stock_fixture(ir)
	function ir.add_target(id, freq, dist, snd)
		ir.RF_targets[id] = { freq = freq or ir.get_random_freq(), dist = dist or 200, snd = snd }
	end
	function ir.clear_target(id)
		if id then ir.RF_targets[id] = nil end
	end
	function ir.init_or_get_stalker_pda_freq(id, defs)
		local se = alife_object(id)
		if not se then return nil end
		local old = ir.stalker_pda_frequencies[id]
		if old then return old.freq end
		defs = defs or ir.get_signal_source(clsid.script_stalker)
		local f = defs.freq[math.random(#defs.freq)] + math.random(1, defs.variance) * (math.random(2) == 1 and 1 or -1)
		f = math.max(1, math.min(999, f))
		ir.stalker_pda_frequencies[id] = { id = id, name = se:name(), freq = f }
		return f
	end
	function ir.load_state(data)
		ir.RF_targets = data.RF_targets or {}
		ir.RF_stashes = data.RF_stashes or {}
		ir.stalker_pda_frequencies = data.stalker_pda_frequencies or {}
	end
	function ir.save_state(data)
		data.RF_targets = ir.RF_targets
		data.RF_stashes = ir.RF_stashes
		data.stalker_pda_frequencies = ir.stalker_pda_frequencies
	end
end

local function setup(name)
	MODE = name == "none" and "sp" or "host"
	dofile("tests/lua/support/stubs_mods.lua")
	make_actor()
	clsid = { script_stalker = 1 }
	if name == "srv_map" then
		coop.is_map_server = function() return true end
		coop.is_client = function() return true end
	end
	if name == "srv_world" then coop.is_dedicated = function() return true end end
	load_script("coop_main") load_script("coop_mode")
	modes.install(coop_mode, name, name == "srv_world" and { seat_plays = function(peer) return peer == 1 or peer == 2 end } or nil)
	load_script("coop_mods_core") load_script("coop_quests_core")
	load_script("coop_trust")
	coop_mods_core.on_game_start()
	axr_main.callback_add("server_entity_on_unregister")
	axr_main.callback_add("npc_on_item_take")
	item_radio = setmetatable({ RF_targets = {}, RF_stashes = {}, stalker_pda_frequencies = {},
		get_random_freq = function() return 150 end, valid_id = function(id) return type(id) == "number" and id > 0 and id < 65535 end,
		vl = function() end, dl = function() end, debug_print_stalker_pdas = function() end,
		rand = function(a, b) return b and math.random(a, b) or math.random(a) end,
		get_signal_source = function() return { freq = { 915 }, variance = 15 } end,
		snd_path_table = {},
	}, { __index = _G })
	if stock then
		for _, spec in ipairs({
			{ "function add_target(", "function create_rf_table(" },
			{ "function get_rnd_freq_from_tbl(", "function new_stalker_contact(" },
			{ "local function load_state(", "local function on_key_hold(" },
		}) do
			local src = fragment(stock, spec[1], spec[2]):gsub("local function load_state", "function load_state")
				:gsub("local function save_state", "function save_state")
			chunk(src, item_radio)
		end
	else
		install_stock_fixture(item_radio)
	end
	item_radio.validate_RF_targets = function() end
	-- The actual legacy quest producer/consumer, installed before the adapter as well as after it below.
	local env = setmetatable({ qc = coop_quests_core, stats = { rf = 0 } }, { __index = _G })
	local src = fragment(party, "local function patch_rf()", "-------------------------------------------------------------------------------\n-- Status, start")
	local install, receive = chunk(src .. "\nreturn patch_rf, client_on_rf", env)
	coop_quests_core.on("rf", receive, "radio-test")
	install()
	load_script("coop_mods_radio") coop_mods_radio.on_game_start()
	RegisterScriptCallback("load_state", item_radio.load_state)
	return item_radio
end

local function tick(ms)
	NOW = NOW + (ms or 2100) SendScriptCallback("actor_on_update")
end
local function source(id, name, section, parent)
	local se, obj = spawn(section or "rf_source", vec3(2, 0, 0), parent, { id = id })
	se._name = name or ("source_" .. id)
	se.name = function(self) return self._name end
	se.clsid = function() return section == "stalker" and clsid.script_stalker or -1 end
	return se, obj
end
local function mirror()
	MODE = "client"
	modes.install(coop_mode, "hostplay", { decides_world = function() return false end,
		leads_here = function() return false end, is_player_mirror = function() return true end,
		decider = function() return "other" end })
end
local function from_world(verb, t)
	coop_main.on_event("mods." .. verb, coop_main.encode(t), 0)
end
local function authority(name)
	MODE = "host"
	modes.install(coop_mode, name == "srv_world" and name or "hostplay",
		{ seat_plays = function(peer) return peer == 0 or peer == 1 or peer == 2 end })
end

for _, name in ipairs(modes.names()) do
	local ir = setup(name)
	print("== RF sources " .. name)
	local npc = source(1200, "stalker_lifetime_one", "stalker")
	local defs = { freq = { 915, 945 }, variance = 15 }
	if name == "none" then
		math.randomseed(1)
		local f1 = ir.init_or_get_stalker_pda_freq(1200, defs)
		ir.stalker_pda_frequencies = {}
		math.randomseed(987)
		local f2 = ir.init_or_get_stalker_pda_freq(1200, defs)
		check(f1 ~= f2, "SP: stock random frequency assignment unchanged")
		local target = source(1210)
		ir.add_target(1210, 155, 200, "radio\\custom")
		target.parent_id = 0 tick()
		check(ir.RF_targets[1210] ~= nil and #SENT == 0, "SP: adapter does not remove targets or send events")
	else
		authority(name)
		ir.stalker_pda_frequencies[1200] = { id = 1200, name = npc:name(), freq = 899 }
		check(ir.init_or_get_stalker_pda_freq(1200, defs) == 899, "m21:8 matching saved frequency retained")
		axr_main.callback_add("server_entity_on_unregister")
		-- Names generated by the engine are section+id: both can be reused, so name alone is not a lifetime token.
		SendScriptCallback("server_entity_on_unregister", npc)
		check(ir.stalker_pda_frequencies[1200] == nil, "m21:8 unregister clears frequency even when next object reuses name and id")
		math.randomseed(1)
		local f1 = ir.init_or_get_stalker_pda_freq(1200, defs)
		check(f1 and f1 >= 1 and f1 <= 999, "m21:8 owner assigns a receiver-range frequency")
		mirror() ir.stalker_pda_frequencies = {} SENT = {}
		math.randomseed(987)
		check(ir.init_or_get_stalker_pda_freq(1200, defs) == nil, "m21:8 mirror waits for owner instead of rolling a frequency")
		local _, request = sent("mods.rf_freq")
		check(request and request.target == 0, "m21:8 missing PDA frequency requested from world owner")
		authority(name)
		ir.stalker_pda_frequencies[1200] = { id = 1200, name = npc:name(), freq = f1 }
		if request then deliver(request, 1) end
		local _, reply = sent("mods.rf_freq_r")
		mirror() ir.stalker_pda_frequencies = {}
		if reply then deliver(reply, 0) end
		check(ir.init_or_get_stalker_pda_freq(1200, defs) == f1, "m21:8 both machines use owner's frequency despite different RNG")
		local mirror_frequencies = ir.stalker_pda_frequencies
		authority(name)
		ir.stalker_pda_frequencies = { [1200] = { id = 1200, name = npc:name(), freq = f1 } }
		SENT = {}
		SendScriptCallback("server_entity_on_unregister", npc)
		local _, invalidation = sent("mods.rf_freq_r")
		mirror()
		-- This mirror never received a local unregister, and the replacement has the same id, section and name.
		ir.stalker_pda_frequencies = mirror_frequencies
		if invalidation then deliver(invalidation, 0) end
		check(ir.init_or_get_stalker_pda_freq(1200, defs) == nil, "m21:8 the world retires a cached frequency before same-name ID reuse on a mirror")
		MODE = "host"
		modes.install(coop_mode, name, name == "srv_world" and { seat_plays = function(peer) return peer == 1 or peer == 2 end } or nil)

		local target = source(1210)
		if name ~= "srv_map" then
			coop_trust.reset_for_test({ default = "log" })
			coop_main.on_event("mods.rf_freq", coop_main.encode({ i = 1210 }), 1)
			check(ir.stalker_pda_frequencies[1210] == nil, "m21:8 a non-stalker request cannot create a saved PDA frequency")
			local before = coop_mods_core.stats.big_in
			coop_main.on_event("mods.rf_big", coop_main.encode({ k = "unexpected", i = 1, n = 1, d = "{}" }), 1)
			check(coop_mods_core.stats.big_in == before, "m21:9 the authority admits no player RF snapshot chunks")
		end
		SENT = {}
		ir.add_target(1210, 155, 200, { "radio\\custom_a", "radio\\custom_b" })
		local _, legacy = sent("quests.rf")
		check(legacy and coop_main.decode(legacy.payload).s ~= nil, "m21:9 quest RF producer includes sound description")
		-- the deciding process sends its diff at once from the add_target hook, not at the next 2 s tick
		local snap, wire = sent("mods.rf")
		if name ~= "srv_map" then
			check(snap and snap.d ~= nil, "m21:9 RF diff includes sound description, sent at once")
			ir.RF_targets[1210].snd[2] = "radio\\changed"
			SENT = {} tick()
			check(sent("mods.rf") ~= nil, "m21:9 sound-only change is broadcast")
		end

		if name == "hostplay" then
			-- Inventory confirmation, not a client-supplied item id. The owner can be the host or a remote player.
			source(500, "client", "actor")
			target.parent_id = 500 SENT = {} tick()
			local removed = sent("mods.rf")
			check(ir.RF_targets[1210] == nil, "m21:7 remote player's confirmed pickup removes ordinary target")
			check(removed and removed.r == "1210", "m21:7 confirmed removal is broadcast")
			local save = {} ir.save_state(save)
			check(save.RF_targets[1210] == nil, "m21:7 Co-op does not save the removed source")
			local own = source(1211) ir.add_target(1211, 160)
			own.parent_id = 0 tick()
			check(ir.RF_targets[1211] == nil, "m21:7 host player's pickup uses the same confirmation path")
			local quick, quick_obj = source(1213)
			ir.add_target(1213, 160)
			tick()
			quick.parent_id = 500
			SendScriptCallback("npc_on_item_take", OBJ[500], quick_obj)
			quick.parent_id = 65535
			tick()
			check(ir.RF_targets[1213] == nil, "m21:7 Co-op remembers a confirmed pickup followed by a drop between polls")
		elseif name == "srv_map" then
			from_world("rf", { a = "1250:177:200", d = coop_mods_core.ser({ [1250] = "radio\\map_wait" }) })
			source(1250) tick()
			check(ir.RF_targets[1250] and ir.RF_targets[1250].snd == "radio\\map_wait", "Server: map reconciles target after delayed object arrival")
			source(500, "client", "actor")
			target.parent_id = 500
			SendScriptCallback("npc_on_item_take", OBJ[500], OBJ[1210])
			target.parent_id = 65535
			tick()
			local facts, factwire = sent("mods.rf_taken")
			check(facts and facts.i == 1210 and factwire.target == 0, "m21:7 map reports only inventory-confirmed pickup to world")
			check(sent("mods.rf") == nil, "Server: map does not broadcast world RF snapshots")
		elseif name == "srv_world" then
			check(ir.RF_targets[1210] ~= nil, "Server: world without player inventory does not infer pickup")
			modes.install(coop_mode, "srv_map")
			source(500, "client", "actor") target.parent_id = 500
			SendScriptCallback("npc_on_item_take", OBJ[500], OBJ[1210])
			target.parent_id = 65535
			SENT = {} tick()
			local fact, factwire = sent("mods.rf_taken")
			check(fact and fact.i == 1210, "Server: capture real map inventory confirmation")
			-- The world replica has no inventory/body, including no online item. Only the map observed the pickup.
			target.parent_id = 65535 OBJ[1210], OBJ[500], SE[500] = nil, nil, nil
			modes.install(coop_mode, name, { seat_plays = function(peer) return peer == 1 or peer == 2 end })
			if factwire then deliver(factwire, 1) end
			check(ir.RF_targets[1210] ~= nil, "m21:7 a player's claim cannot replace map inventory confirmation")
			if factwire then
				local stale = coop_main.decode(factwire.payload) stale.n = "previous_lifetime"
				coop_main.on_event("mods.rf_taken", coop_main.encode(stale), 257)
				check(ir.RF_targets[1210] ~= nil, "m21:7 stale identity cannot retire current RF target")
				ir.RF_targets[1210].snd = "radio\\world_sound_changed"
				deliver(factwire, 257)
			end
			tick()
			check(ir.RF_targets[1210] == nil, "m21:7 world removes target after map confirmation without a player map")
			local save = {} ir.save_state(save)
			check(save.RF_targets[1210] == nil, "m21:7 the server world does not save the removed source")

			-- A quest on the player's map calls item_radio.add_target and later clear_target.
			-- The world has only the offline object, and a listener can join on a different map.
			source(1260, "fate_quest_item")
			modes.install(coop_mode, "srv_map")
			SENT = {}
			ir.add_target(1260, 271, 200, "radio\\map_quest")
			tick()
			local _, registration = sent("mods.rf_target")
			check(registration and registration.target == 0, "m21:9 map registers a quest RF source with the world")
			ir.RF_targets[1260], OBJ[1260] = nil, nil
			modes.install(coop_mode, name, { seat_plays = function(peer) return peer == 1 or peer == 2 end })
			if registration then deliver(registration, 1) end
			check(ir.RF_targets[1260] == nil, "m21:9 a player's registration cannot write the world's RF target")
			if registration then deliver(registration, 257) end
			SENT = {}
			tick(31000)
			local _, across_maps = sent("mods.rf")
			check(ir.RF_targets[1260] and ir.RF_targets[1260].snd == "radio\\map_quest", "m21:9 the world keeps a map-created RF source")
			local world_targets = ir.RF_targets
			local map_entity = SE[1260]
			mirror()
			ir.RF_targets = {}
			SE[1260] = nil
			if across_maps then deliver(across_maps, 0) end
			check(ir.RF_targets[1260] == nil, "m21:9 a listener on another map waits for the source object")
			SE[1260] = map_entity
			tick()
			check(ir.RF_targets[1260] and ir.RF_targets[1260].snd == "radio\\map_quest", "m21:9 a late listener gets the map-created source from the world")
			MODE = "host"
			modes.install(coop_mode, "srv_map")
			SENT = {}
			ir.clear_target(1260)
			tick()
			local _, cancellation = sent("mods.rf_target")
			ir.RF_targets = world_targets
			modes.install(coop_mode, name, { seat_plays = function(peer) return peer == 1 or peer == 2 end })
			if cancellation then deliver(cancellation, 257) end
			check(ir.RF_targets[1260] == nil, "m21:7 map quest cleanup also retires the world source")
			-- The radio adapter hooks add_target itself: with no legacy quest message at all, the map still registers it.
			source(1261, "fate_quest_item_two")
			modes.install(coop_mode, "srv_map")
			local legacy_send = coop_quests_core.send
			coop_quests_core.send = function() end
			SENT = {}
			ir.add_target(1261, 272, 200, "radio\\map_quest")
			tick()
			coop_quests_core.send = legacy_send
			local own, own_raw = sent("mods.rf_target")
			check(own_raw and own_raw.target == 0 and tonumber(own.i) == 1261 and tonumber(own.f) == 272,
				"the radio registers a map quest's RF source by its own hook on add_target")
		end

		-- A later full snapshot repairs a joined player's stale save, including on a different map.
		modes.install(coop_mode, name)
		source(1212)
		ir.add_target(1212, 222, 300, "radio\\late_join")
		SENT = {} tick(31000)
		local full, fullwire = sent("mods.rf")
		if name ~= "srv_map" then
			check(full and full.full == true, "late join gets a complete RF snapshot")
			mirror()
			ir.RF_targets = { [1210] = { freq = 155 } }
			if fullwire then deliver(fullwire, 0) end
			check(ir.RF_targets[1210] == nil, "m21:7 full snapshot clears stale picked-up source on another map")
			check(ir.RF_targets[1212] and ir.RF_targets[1212].snd == "radio\\late_join", "m21:9 late join restores RF sound")
		end
		mirror()
		ir.RF_targets = {}
		if legacy then deliver(legacy, 0) end
		check(ir.RF_targets[1210] and type(ir.RF_targets[1210].snd) == "table"
			and ir.RF_targets[1210].snd[2] == "radio\\custom_b", "m21:9 quest RF consumer restores sound list")
		from_world("rf", { r = "1210" })
		check(ir.RF_targets[1210] == nil, "m21:7 removal clears quest target too")
		ir.RF_targets = {}
		coop_main.on_event("quests.rf", coop_main.encode({ i = 1230, f = 150, d = 200,
			s = coop_mods_core.ser("radio\\delayed") }), 0)
		check(ir.RF_targets[1230] == nil, "quest target waits for its streamed object")
		from_world("rf", { r = "1230" }) source(1230) tick()
		check(ir.RF_targets[1230] == nil, "m21:7 removal also clears pending quest target")
		source(1240)
		from_world("rf", { a = "1240:150:200", d = coop_mods_core.ser({ [1240] = "radio\\first" }) })
		check(ir.RF_targets[1240] and ir.RF_targets[1240].snd == "radio\\first", "RF string sound restored")
		from_world("rf", { a = "1240:150:200", d = coop_mods_core.ser({ [1240] = false }) })
		check(ir.RF_targets[1240] and ir.RF_targets[1240].snd == nil, "sound reset restores default without retaining old sound")
		from_world("rf", { a = "1240:150:200", d = coop_mods_core.ser({ [1240] = "..\\outside" }) })
		check(ir.RF_targets[1240] and ir.RF_targets[1240].snd == nil, "invalid sound path cannot be restored")
		-- A saved owner's frequency can arrive before the NPC streams in.
		from_world("rf_freq_r", { i = 1241, n = "late_npc", c = "stalker", f = 877 })
		source(1241, "late_npc", "stalker")
		check(ir.init_or_get_stalker_pda_freq(1241, defs) == 877, "m21:8 saved owner frequency survives delayed NPC streaming")
		local before = sent_count("mods.rf_freq")
		ir.init_or_get_stalker_pda_freq(1241, defs)
		check(sent_count("mods.rf_freq") == before, "known owner frequency causes no extra request")
		SendScriptCallback("load_state", { RF_freq = 150,
			stalker_pda_frequencies = { [1241] = { id = 1241, name = "late_npc", freq = 888 } } })
		check(ir.init_or_get_stalker_pda_freq(1241, defs) == 888, "load drops older wire frequency cache in favor of loaded owner data")
		if name ~= "srv_map" then
			authority(name)
			ir.RF_targets = {}
			for id = 2000, 2199 do
				source(id)
				ir.RF_targets[id] = { freq = 150, dist = 200, snd = "radio\\" .. string.rep("x", 100) }
			end
			for id = 3000, 6000 do
				ir.stalker_pda_frequencies[id] = { id = id, name = string.rep("stalker_", 10) .. id, freq = 915 }
			end
			SENT = {} tick(31000)
			check(sent_count("mods.rf_big") > 1, "large RF snapshot uses chunked transport")
			local packets = SENT
			for _, packet in ipairs(packets) do check(#packet.payload < 15000, "RF wire packet below 15000 bytes") end
			mirror() ir.RF_targets = {}
			for _, packet in ipairs(packets) do if packet.name == "mods.rf_big" then deliver(packet, 0) end end
			check(ir.RF_targets[2199] and ir.RF_targets[2199].snd == "radio\\" .. string.rep("x", 100),
				"late join restores chunked snapshot including sound")
		end
		check(coop_mods_core.stats.errors == 0, "no adapter errors")
	end
	total_passed, total_failed = total_passed + PASSES, total_failed + FAILS
end
print(string.format("RF sources: %d passed, %d failed", total_passed, total_failed))
if total_failed > 0 then error("RF sources FAILED") end
