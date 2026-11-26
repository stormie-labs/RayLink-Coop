-- coop_mods_item_state: the per-frame walk of the player's inventory. Every item is observed (the first sight of one
-- restores its saved rider), and only an item with a rider in the mod's table or in the storage is captured: the mod's
-- table is read once per frame, not once per item. A Core script: runs under every answer set.
dofile("tests/lua/support/harness_economy.lua")
local modes = dofile("tests/lua/support/modes.lua")
local JAM = "coop_weapon_jam"

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

local function weapon(w, id)
	local o = add_item(w, id, "wpn_test", 0)
	o.cast_Weapon = function(self) return self end
	o.texture = "base"
	o.get_shaders = function(self) return { [1] = { texture = self.texture, shader = "model" } } end
	o.set_shader = function(self, _, _, texture) self.texture = texture end
	return o
end

-- A player's machine: his actor (id 0) holds the items, the facade says the actor is a player.
local function setup(set)
	PLAYERS = { [0] = { nick = "host", proxy = 0 }, [1] = { nick = "owner", proxy = 501 } }
	POS, QUEUE, WORLDS, BRIDGES = { [0] = { x = 0, y = 0, z = 0 }, [1] = { x = 0, y = 0, z = 0 } }, {}, {}, {}
	local w = make_world(1)
	w.coop.event_tick = function() return 0, 0 end
	w.coop.released_after = function() return false end
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
	modes.install(w.coop_mode, set, set ~= "none" and {
		leads_here = function() return false end, decides_world = function() return false end,
		actor_is_player = function() return true end, is_player_mirror = function() return true end,
	} or nil)
	corpus(w, "z_3dss_gamma_camo_system")
	corpus(w, "arti_jamming")
	load_script(w, "coop_mods_item_state").on_game_start()
	return w
end

-- How often the camo mod's table is read during one frame: the walk reads it once, a capture once more.
local function reads_in_a_frame(w)
	local camo = w.z_3dss_gamma_camo_system
	local save_state, n = camo.save_state, 0
	camo.save_state = function(...) n = n + 1 return save_state(...) end
	tick(w, 16)
	camo.save_state = save_state
	return n
end

for _, name in ipairs(modes.names()) do
	section("item state walk / " .. name)
	local w = setup(name)
	if name == "none" then w.ACTIVE = false end
	weapon(w, 800)
	w.INV = { 800 }
	tick(w, 1100)
	if name == "none" then
		w.arti_jamming.jammed_guns[800] = 2
		tick(w, 16)
		check(w.MDATA[JAM] == nil and #w.SENT == 0, "single player: the walk keeps and sends nothing")
	else
		local one = reads_in_a_frame(w)
		for id = 900, 919 do weapon(w, id) w.INV[#w.INV + 1] = id end
		tick(w, 16) -- the first sight of the new items
		local many = reads_in_a_frame(w)
		check(one == 1 and many == 1, string.format("the mod's table is read once a frame, whatever the inventory holds (%d, %d)",
			one, many))

		-- A direct write of the mod's table (no wrapped function ran) is captured by the walk.
		w.arti_jamming.jammed_guns[905] = 2
		tick(w, 16)
		local record = w.MDATA[JAM] and w.MDATA[JAM][905]
		check(type(record) == "table" and record.state == 2 and record.instance == "wpn_test905",
			"a jam written straight into the mod's table is captured with the weapon's instance")
		check(w.MDATA.se_object[905] and type(w.MDATA.se_object[905][JAM]) == "table"
			and w.MDATA.se_object[905][JAM].state == 2, "the captured jam goes to the weapon's SE copy")
		-- A camo selection written straight into the mod's table: that item, and only that one, is captured each frame
		-- (one more read of the table).
		local snapshot = {}
		w.z_3dss_gamma_camo_system.save_state(snapshot)
		snapshot.z_3dss_gamma_camo_system.selections[906] = { file = "test.ltx", section = "wpn_test_green" }
		local reads = reads_in_a_frame(w)
		local camo = w.MDATA.coop_weapon_camo and w.MDATA.coop_weapon_camo[906]
		check(reads == 2 and type(camo) == "table" and camo.instance == "wpn_test906" and camo.state.section == "wpn_test_green",
			string.format("a camo selection written straight into the mod's table is captured (%d reads)", reads))

		-- Cleared in the mod's table: the stored rider is captured as a stamped clear, not dropped.
		w.arti_jamming.jammed_guns[905] = nil
		tick(w, 16)
		record = w.MDATA[JAM] and w.MDATA[JAM][905]
		check(type(record) == "table" and record.state == 0 and record.instance == "wpn_test905",
			"a jam cleared in the mod's table is captured as a stamped clear")

		-- An item seen for the first time gets the rider saved in its SE copy, though nothing else names it.
		weapon(w, 930)
		w.MDATA.se_object[930] = { [JAM] = { instance = "wpn_test930", state = 3 } }
		w.INV[#w.INV + 1] = 930
		tick(w, 16)
		check(w.arti_jamming.jammed_guns[930] == 3, "the walk restores an item's saved rider on its first sight")
		check(w.MDATA[JAM] and type(w.MDATA[JAM][930]) == "table" and w.MDATA[JAM][930].state == 3,
			"the restored rider is kept in the storage")

		-- Items without a rider stay without one.
		local none = true
		for id = 900, 919 do
			if id ~= 905 and w.MDATA[JAM] and w.MDATA[JAM][id] ~= nil then none = false end
		end
		check(none and w.arti_jamming.jammed_guns[910] == nil, "an item without a rider gets none from the walk")
		check(not w.HANDLER_ERRORS, "no handler errors")
	end
end
print(string.format("mods item state walk: %d passed, %d failed", CHECKS - FAILS, FAILS))
if FAILS > 0 then error("mods item state walk FAILED") end
