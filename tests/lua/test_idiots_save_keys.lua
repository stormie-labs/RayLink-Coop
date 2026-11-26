-- G12-2: exercise the actual Useful Idiots callbacks with game objects and its Lua libraries stubbed.
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function stock(name)
	local sources = { "temp/review/corpus/merged", os.getenv("GAMMA_SCRIPTS") }
	for _, path in ipairs(sources) do
		local chunk = loadfile(path .. "/" .. name .. ".script")
		if chunk then
			local env = setmetatable({}, { __index = _G })
			setfenv(chunk, env)()
			return env
		end
	end
	error("Useful Idiots script missing from corpus and GAMMA_SCRIPTS: " .. name)
end

local function copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = type(v) == "table" and copy(v) or v end
	return out
end

dup_table = copy
function table.keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	return keys
end

local owners, visible, moves, states = {}, {}, {}, {}
local NPC = {
	DEFAULT_STATE = { movement = { follow = true, wait = false }, combat = { guard = false }, jobs = { loot_artifacts = false } },
	ACTIONS = {}, ACTIONS_KEYED = { movement = { cycle = true }, combat = {}, jobs = {} },
	SELECTED_IDS = {}, LOOT_SHARED_ITEMS = {}, LOOT_SHARING_NPCS = {},
}
NPC.GLOBAL_STATE = copy(NPC.DEFAULT_STATE)
function NPC.getCompanions() return visible end
function NPC.isCompanion(o) return o and owners[o:id()] ~= nil end
function NPC.getCompanion(id) return level.object_by_id(id) end
function NPC.getActiveState() end
function NPC.isStateful(g, a) return NPC.DEFAULT_STATE[g] and NPC.DEFAULT_STATE[g][a] ~= nil end
function NPC.moveToPoint(o, pos) moves[#moves + 1] = { id = o:id(), x = pos.x } end
function NPC.getAllStates(o) return copy(o and states[o:id()] or NPC.GLOBAL_STATE) end
function NPC.setStates(o, t) states[o:id()] = copy(t) end
function NPC.setState(o, g, a, v)
	local target = o and states[o:id()] or NPC.GLOBAL_STATE
	if target[g][a] == v then return end
	if NPC.ACTIONS_KEYED[g].cycle then
		if not v then return end
		for action in pairs(target[g]) do target[g][action] = action == a end
	else
		target[g][a] = v
	end
	if not o then
		for _, npc in ipairs(visible) do NPC.setState(npc, g, a, v) end
	end
end

package.loaded["illish.lib.npc"] = NPC
package.loaded["illish.lib.table"] = { merge = function(a, b)
	for k, v in pairs(b) do a[k] = v end
	return a
end }
package.loaded["illish.lib.beh"] = {
	saveStorage = function(id, dest) dest[id] = copy(db.storage[id].beh) end,
	loadStorage = function(id, src) if src and src[id] then db.storage[id].beh = copy(src[id]) end end,
}
package.loaded["illish.lib.weapon"] = {}
a_idiots_config = { DATA_KEY = "USEFUL_IDIOTS", DATA_VER = "1.0", DATA_STALE_KEYS = {} }
local opts = { ["idiots/options/artifacts"] = true }
local held, double = false, false
ui_mcm = {
	get = function(key) return opts[key] end,
	get_mod_key = function() return true end,
	key_hold = function() return held end,
	double_tap = function() return double end,
}
local function key_mode(value)
	opts["idiots/keybinds/point/move_key"] = 42
	opts["idiots/keybinds/point/move_mode"] = value
end
level.get_target_pos = function() return vec3(12, 4, 8) end
particles_object = function() return {} end
idiots_ui = {}
save_var = function() end
local messages = 0
a_idiots_mdata = stock("a_idiots_mdata")
idiots_keybinds = stock("idiots_keybinds")
idiots_keybinds.showMessage = function() messages = messages + 1 end
idiots_keybinds.playParticle = function() end
local function load(m) alife_storage_manager.CALifeStorageManager_load(m) end
local function save()
	local m = alife_storage_manager.get_state()
	SendScriptCallback("save_state", m)
	return m
end
local function hit(verb, t, from)
	coop_main.on_event("mods." .. verb, coop_main.encode(t), from)
end
local function payload(ids, wait, guard)
	return { ids = ids, x = 12, y = 4, z = 8, autoWait = wait, autoGuard = guard }
end
local function share_packet(name, rows, from)
	local payload = coop_main.encode({ k = name, s = 1, i = 1, n = 1, d = coop_quests_core.ser(rows) })
	coop_main.on_event("coop_share", payload, from)
end

axr_companions = { companion_squads = {} }
axr_task_manager = { hostages_by_id = {} }
local function companion(id, owner)
	local _, obj = spawn("stalker", vec3(0, 0, 0), nil, { id = id })
	obj.has_info = function() return false end
	owners[id] = owner
	states[id] = copy(NPC.DEFAULT_STATE)
	db.storage[id] = { object = obj, beh = { target = "actor", keepType = "from-map-" .. id } }
	axr_companions.companion_squads[id + 1000] = {
		commander_id = function() return id end,
		squad_members = function()
			local member = { id = id }
			return function() local out = member; member = nil; return out end
		end,
	}
	return obj
end
coop_npc_companions = { owner_character = function(o) return o and owners[o:id()] end }
coop_npc_players = {
	send = function(name, t, target) return coop.send_event(name, coop_main.encode(t), target) end,
}

for _, mode in ipairs(modes.names()) do
	MODE = mode == "none" and "sp" or "host"
	local facade = load_script("coop_mode")
	-- the world server here has two map servers (coop.levels.map_servers below): both are levels it hears from
	modes.install(facade, mode, mode == "srv_world" and {
		from_level = function(from) return from == 0x101 or from == 0x102 end,
	} or nil)
	coop.is_host = function() return MODE == "host" and mode ~= "srv_map" end
	coop.is_map_server = function() return mode == "srv_map" end
	coop.is_dedicated = function() return mode == "srv_world" end
	coop.levels = {
		split = function() return mode == "srv_world" or mode == "srv_map" end,
		map_servers = function() return { { bridge = 0x101, level = 4 }, { bridge = 0x102, level = 7 } } end,
	}
	make_actor()
	spawn("coop_player_avatar", vec3(0, 0, 0), nil, { id = 500 })
	local own = companion(101, 0)
	local first, second = companion(201, 500), companion(202, 500)
	visible = { own }
	AddScriptCallback("on_key_hold")
	AddScriptCallback("on_key_release")
	AddScriptCallback("npc_on_net_spawn")
	a_idiots_mdata.on_game_start()
	idiots_keybinds.on_game_start()
	RegisterScriptCallback("on_key_press", function(dik)
		if dik == 42 and MODE == "client" then coop_npc_players.send("npc.comp_go", { x = 12, y = 4, z = 8 }, 0) end
	end)
	load_script("coop_main")
	local adapter = load_script("coop_npc_idiots")
	if adapter.on_game_start then adapter.on_game_start() end
	local file = io.open("gamedata/scripts/coop_srv_idiots.script", "r")
	if file then
		file:close()
		load_script("coop_srv_idiots").on_game_start()
	end
	if coop.levels.split() then load_script("coop_srv_levels_share").on_game_start() end
	load({})

	if mode == "hostplay" then
		states[201].movement = { follow = false, wait = true }
		local m = save()
		check(m.USEFUL_IDIOTS.companionStates[101] and m.USEFUL_IDIOTS.companionStates[201]
			and m.USEFUL_IDIOTS.companionStates[202], "m21:1 co-op save includes companions outside the host's UI list")
		check(m.USEFUL_IDIOTS.beh[201] and m.USEFUL_IDIOTS.beh[201].keepType == "from-map-201",
			"m21:1 co-op persists another player's behaviour storage")
		states[201] = copy(NPC.DEFAULT_STATE)
		load(m)
		SendScriptCallback("npc_on_net_spawn", first)
		check(states[201].movement.wait == true, "m21:1 co-op spawn restores saved live companion state")

		hit("idiots_point", payload("201,101", true, true), 1)
		check(#moves == 0 and (coop_trust.status().idiots_point_owner or {}).failed == 1,
			"m21:3 mixed ownership refuses the entire command through trust")
		hit("idiots_point", payload("201", true, false), 1)
		check(#moves == 1 and moves[1].id == 201 and states[201].movement.wait and not states[201].combat.guard
			and not states[202].movement.wait, "m21:3 decider applies sender's options to only the chosen companion")
		hit("idiots_point", payload("202,202", true, true), 1)
		check(#moves == 1 and (coop_trust.status().idiots_point_args or {}).failed == 1,
			"m21:3 duplicate IDs are checked and cannot repeat a move")
		hit("idiots_template", { group = "combat", action = "guard", enabled = true }, 1)
		NPC.GLOBAL_STATE.combat.guard = false
		m = save()
		check(m.coop_idiots_templates and m.coop_idiots_templates[500] and m.coop_idiots_templates[500].combat.guard
			and m.coop_idiots_templates[0] and not m.coop_idiots_templates[0].combat.guard,
			"m21:1 co-op saves independent templates under stable character IDs")
		local fresh = companion(203, 500)
		SendScriptCallback("npc_on_net_spawn", fresh)
		check(states[203].combat.guard and not NPC.GLOBAL_STATE.combat.guard,
			"m21:1 a companion with no saved state inherits only its leader's template")

		key_mode(0)
		SendScriptCallback("on_key_press", 42)
		check(#moves == 2 and moves[2].id == 101 and sent_count("mods.idiots_point") == 0,
			"m21:3 the co-op host's own key uses the same decider directly")

		MODE, SELF = "client", 1
		modes.install(facade, "hostplay", {
			leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end, decider = function() return "other" end,
		})
		load(m)
		check(NPC.GLOBAL_STATE.combat.guard, "m21:1 a client restores its personal template from the world save")
		visible, NPC.SELECTED_IDS = { first, second }, { [201] = true }
		key_mode(2)
		opts["idiots/options/autoWait"] = false
		opts["idiots/options/autoGuard"] = true
		SendScriptCallback("on_key_press", 42)
		SendScriptCallback("on_key_hold", 42)
		check(sent_count("mods.idiots_point") == 0 and sent_count("npc.comp_go") == 0,
			"m21:3 a press and an unqualified hold never issue a command or use the legacy bridge")
		held = true
		SendScriptCallback("on_key_hold", 42)
		local t = sent("mods.idiots_point")
		check(t and t.ids == "201" and t.autoWait == false and t.autoGuard == true and #moves == 2,
			"m21:3 a qualified hold sends selected host IDs and options, with no local NPC move")
		key_mode(1)
		SendScriptCallback("on_key_press", 42)
		check(sent_count("mods.idiots_point") == 1 and sent_count("npc.comp_go") == 0,
			"m21:3 the first tap does not send a double-tap command")
		double = true
		NPC.SELECTED_IDS = {}
		SendScriptCallback("on_key_press", 42)
		t = sent("mods.idiots_point")
		check(sent_count("mods.idiots_point") == 2 and t and t.ids == "201,202",
			"m21:3 the second tap with no selection sends the explicit list of own companions")
		check((sent("mods.idiots_template") or {}).action == "guard",
			"m21:1 the move-all template change is sent to the world authority")
	elseif mode == "srv_map" then
		local t = payload("201", false, true)
		t._peer = 1
		hit("idiots_point", t, 0)
		check(#moves == 1 and moves[1].id == 201 and states[201].combat.guard and not states[201].movement.wait,
			"m21:3 the map server applies options using the transport-relayed player identity")
		coop_srv_levels_share._test.tick()
		local t = sent("coop_share")
		local rows = t and t.k == "idiots_state" and coop_quests_core.des(t.d)
		check(rows and rows[201] and rows[201].states.combat.guard and rows[202] and rows[202].beh.keepType == "from-map-202",
			"m21:1 the map report contains every local companion even with a filtered UI list")
		share_packet("idiots_templates", { [500] = { movement = { follow = false, wait = true } } }, 0)
		local fresh = companion(203, 500)
		SendScriptCallback("npc_on_net_spawn", fresh)
		check(states[203].movement.wait and NPC.GLOBAL_STATE.movement.follow,
			"m21:1 the map uses the leader's world template for a companion with no saved row")
		local saved = rows and rows[201] or {}
		load({ USEFUL_IDIOTS = { VER = "1.0", companionStates = { [201] = saved.states },
			beh = { [201] = saved.beh } } })
		states[201] = copy(NPC.DEFAULT_STATE)
		db.storage[201].beh = {}
		SendScriptCallback("npc_on_net_spawn", first)
		check(states[201].combat.guard and db.storage[201].beh.keepType == "from-map-201",
			"m21:1 a reloaded map restores both halves of the world save's NPC record")

		db.storage[202].beh = nil
		t = payload("201,202", true, true)
		t._peer = 1
		hit("idiots_point", t, 0)
		check(#moves == 1 and not states[201].movement.wait,
			"m21:3 an unavailable companion makes the selection invalid before any move")
	elseif mode == "srv_world" then
		share_packet("idiots_state", { [201] = { states = { movement = { wait = true } }, beh = { keepType = "first map" } } }, 0x101)
		share_packet("idiots_state", { [301] = { states = { combat = { guard = true } }, beh = { keepType = "second map" } } }, 0x102)
		share_packet("idiots_state", { [201] = { states = { movement = { wait = false } } } }, 0x103)
		local m = save()
		check(m.USEFUL_IDIOTS.companionStates[201] and m.USEFUL_IDIOTS.companionStates[201].movement.wait
			and m.USEFUL_IDIOTS.companionStates[301] and m.USEFUL_IDIOTS.companionStates[301].combat.guard,
			"m21:1 the world save merges companions from two map servers")
		check(m.USEFUL_IDIOTS.beh[201] and m.USEFUL_IDIOTS.beh[201].keepType == "first map"
			and m.USEFUL_IDIOTS.beh[301] and m.USEFUL_IDIOTS.beh[301].keepType == "second map",
			"m21:1 both registered map servers' behaviour rows reach the world save")
		local t = payload("201", true, true)
		hit("idiots_point", t, 1)
		t = sent("mods.idiots_point")
		check(t and t._peer == 1 and t.ids == "201" and #moves == 0, "m21:3 the world forwards the move to the player's map")
	else
		key_mode(0)
		opts["idiots/options/autoWait"] = true
		SendScriptCallback("on_key_press", 42)
		local m = save()
		check(#moves == 1 and moves[1].id == 101 and states[101].movement.wait and messages == 1,
			"single-player point key follows stock behaviour")
		check(m.USEFUL_IDIOTS.companionStates[101] and not m.coop_idiots_templates and #SENT == 0,
			"single-player save follows stock list and format")
	end
end

done("idiots_save_keys")
