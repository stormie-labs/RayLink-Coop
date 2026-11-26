-- Exercise the shipped functions against a map-spot and transport harness.
local modes = dofile("tests/lua/support/modes.lua")
local role = modes.names()[1]
MODE = role == "none" and "sp" or "host"
dofile("tests/lua/support/stubs_mods.lua")
if role == "srv_map" then coop.is_map_server = function() return true end end
if role == "srv_world" then coop.is_dedicated = function() return true end end

local merged = "temp/review/corpus/merged/"
local function source(name, path)
	local env = setmetatable({}, { __index = _G })
	_G[name] = env
	local chunk = assert(loadfile(path))
	setfenv(chunk, env)()
	return env
end

local spots, all_removed, map = {}, 0, "l01_escape"
local function add(id, name, hint)
	spots[id] = spots[id] or {}
	spots[id][name] = hint or ""
end
local function remove(id, name)
	if spots[id] then spots[id][name] = nil end
end
local function has(id, name)
	return spots[id] and spots[id][name] ~= nil
end
level.name = function() return map end
level.map_add_object_spot = add
level.map_remove_object_spot = remove
level.map_has_object_spot = function(id, name) return has(id, name) and 1 or 0 end
level.map_change_spot_hint = function(id, name, hint) if has(id, name) then add(id, name, hint) end end
level.map_remove_all_object_spots = function(id) all_removed = all_removed + 1; spots[id] = nil end
game = { translate_string = function(s) return s end }
coop.spot_is_local = function(s) return s:sub(1, 5) == "coop_" end

local actor = make_actor()
actor.item_in_slot = function(self, slot) return slot == 8 and self.pda or nil end
local pda = { section = function() return "device_pda_milspec" end }
actor.pda, actor.unlocked, actor.kills = pda, true, true
item_milpda = {
	actor_pda_can_see_mapspot = function(comm) return db.actor.pda ~= nil and db.actor.unlocked and comm == "bandit" end,
	validated_faction = function(comm) return comm end,
	actor_can_see_killspots = function() return db.actor.pda ~= nil and db.actor.kills end,
}
simulation_objects = { is_on_the_same_level = function(_, squad) return squad.map == map end }
function game_graph()
	return { valid_vertex_id = function(_, id) return id == 1 or id == 2 end,
		vertex = function(_, id) return { level_id = function() return id end } end }
end
local get_alife = alife
function alife()
	local sim = get_alife()
	sim.level_name = function(_, id) return id == 1 and "l01_escape" or "l02_garbage" end
	sim.actor = function() return SE[AC_ID] end
	return sim
end
is_squad_monster = {}
sim_squad_warfare = { squad_icons = { bandit = "warfare_bandit_spot" } }

local squad_class = {
	hide = function() end,
	on_unregister = function(self) SE[self.id] = nil end,
}
sim_squad_scripted = { sim_squad_scripted = squad_class }
local mil = source("zzz_sim_squad_scripted_milpda", merged .. "zzz_sim_squad_scripted_milpda.script")
mil.show_squadmate_mapspots = true
local function make_squad(id, commander, map_name)
	local squad = setmetatable({ id = id, player_id = "bandit", map = map_name,
		m_game_vertex_id = map_name == "l01_escape" and 1 or 2 }, { __index = squad_class })
	function squad:commander_id() return commander end
	function squad:get_squad_community() return "bandit" end
	function squad:get_squad_props() return "squad tooltip" end
	-- The game iterator yields the member record as its first value.
	squad.squad_members = function()
		local members = { { id = commander }, { id = commander + 1 } }
		local i = 0
		return function() i = i + 1; return members[i] end
	end
	SE[id] = squad
	return squad
end
local function make_npc(id, map_name)
	local npc = { id = function() return id end, alive = function() return true end,
		general_goodwill = function(_, viewer) return viewer.goodwill or 0 end }
	OBJ[id] = npc
	SE[id] = { online = true, m_game_vertex_id = map_name == "l01_escape" and 1 or 2,
		visible_for_map = function(self, value) self.map_visible = value end }
	return npc
end
local stock = "temp/stock_scripts/scripts/stalker_generic.script"
local f = io.open(stock, "r")
if f then f:close() else stock = "D:/Projects/ForEverything/anomaly-ref/unpacked/scripts/stalker_generic.script" end
source("stalker_generic", stock)
xr_logic = { pick_section_from_condlist = function(_, _, list) return list end }
local function assign(npc, name)
	local st = { section_logic = "logic", ini = { r_string_to_condlist = function(_, section, key)
		if section == "logic" and key == "level_spot" then return name end
		if section == "active" and key == "show_spot" then return "false" end
	end } }
	stalker_generic.reset_show_spot(npc, "walker", st, "active")
end

utils_catspaw_common = { dlog = function() end, vlog = function() end, valid_id = function(id) return id ~= nil end }
utils_catspaw_text = {}
utils_catspaw_mapspots = { add_mapspot = add, remove_mapspot = remove, safe_remove_all_mapspots = level.map_remove_all_object_spots }
local task_target
utils_catspaw_taskmonitor = { is_id_task_target = function(id) return id == task_target end }
local open_ini = ini_file
function ini_file(path)
	if path == [[items\settings\mutant_loot.ltx]] then return { r_float_ex = function() return 7200 end } end
	return open_ini(path)
end
local tracker = source("ish_kill_tracker", merged .. "ish_kill_tracker.script")

load_script("coop_main")
load_script("coop_mods_core")
local facade = load_script("coop_mode")
modes.install(facade, role)
AddScriptCallback("map_spot_menu_property_clicked")
RegisterScriptCallback("map_spot_menu_property_clicked", tracker.map_spot_menu_property_clicked)
local adapter = coop_pda_marks_local
if adapter then adapter.on_game_start() end
SendScriptCallback("actor_on_first_update") -- the actor of the level spawns

-- DXML dispatches in registration order on the same DOM. Milspec and PAW append their definitions after our script.
local callbacks = {}
local register = RegisterScriptCallback
RegisterScriptCallback = function(name, fn)
	if name ~= "on_xml_read" then return register(name, fn) end
	for _, existing in ipairs(callbacks) do if fn == existing then return end end
	callbacks[#callbacks + 1] = fn
end
local dxml = modxml_coop_pda_marks
if dxml then dxml.on_xml_read(); dxml.on_xml_read() end
local function node(name, art)
	return { el = "<" .. name .. ' hint="original"', kids = { { el = '<level_map spot="' .. art .. '"' } } }
end
local function new_document()
	local root = { kids = { node("ui_pda2_trader_location", "trader_art"), node("warfare_bandit_spot", "bandit_art") } }
	return {
		getRoot = function() return root end,
		getElementName = function(_, el) return el.el:match("^<([^ ]+)") end,
		insertElement = function(_, el) root.kids[#root.kids + 1] = el; return el end,
	}
end
local function xml_count(xml, name)
	local n, found = 0, nil
	for _, el in ipairs(xml:getRoot().kids) do
		if xml:getElementName(el) == name then n, found = n + 1, el end
	end
	return n, found
end
RegisterScriptCallback("on_xml_read", function(_, xml)
	if xml_count(xml, "deadbody_location_whtx") > 0 then return end
	xml:insertElement(node("deadbody_location_whtx", "body_art"))
	xml:insertElement(node("deadbody_location_sdot", "dot_art"))
	xml:insertElement(node("squadmate_bandit_spot", "member_art"))
	xml:insertElement(node("paw_blue_circle", "paw_art"))
end)
local function xml_pass(xml, path)
	for _, callback in ipairs(callbacks) do callback(path, xml) end
end
local xml = new_document()
xml_pass(xml, [[ui\map_spots_16.xml]])
xml_pass(xml, [[ui\map_spots_16.xml]])
local count, body_xml = xml_count(xml, "coop_pda_deadbody_location_whtx")
check(count == 1 and body_xml.kids[1].el == '<level_map spot="body_art"', "DXML aliases late Milspec styles once with the original artwork")
check(xml_count(xml, "coop_pda_ui_pda2_trader_location") == 1 and xml_count(xml, "coop_pda_paw_blue_circle") == 1,
	"DXML aliases service and PAW styles once")
local second = new_document()
xml_pass(second, [[ui\map_spots_219.xml]])
check(xml_count(second, "coop_pda_warfare_bandit_spot") == 1, "DXML registers independently in another aspect-ratio pass")

local ordinary = "coop_pda_warfare_bandit_spot"
local service = "coop_pda_ui_pda2_trader_location"
local member = "coop_pda_squadmate_bandit_spot"
local legacy = "ui_pda2_trader_location"
local leader = make_npc(21, map)
make_npc(22, map)
local squad = make_squad(20, 21, map)
local function frame()
	NOW = NOW + 5000
	SendScriptCallback("actor_on_update")
end

if role == "none" then
	squad:show()
	check(has(20, "warfare_bandit_spot") and not has(20, ordinary), "single player uses the unmodified Milspec spot")
	assign(leader, "trader")
	check(has(21, legacy) and not has(21, service), "single player uses the unmodified NPC service mark")
	tracker.tracked_bodies[80] = { icon = "deadbody_location_whtx", killer_id = AC_ID }
	tracker.add_body_dot(80, "body")
	tracker.remove_dot(80)
	check(all_removed == 1, "single player uses the original tracker cleanup")
else
	local authority = role == "hostplay" and "hostplay" or "srv_map"
	local function as_authority()
		MODE = "host"
		coop.is_map_server = authority == "srv_map" and function() return true end or nil
		coop.is_dedicated = nil
		modes.install(facade, authority)
	end
	local function as_player()
		MODE = "client"
		coop.is_map_server, coop.is_dedicated = nil, nil
		modes.install(facade, authority, { actor_is_player = function() return true end,
			leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end })
	end
	local function request()
		as_player()
		frame()
		local _, msg = sent("mods.pda_marks_q")
		SENT = {}
		if not msg then return {} end
		if authority == "srv_map" then
			MODE = "host"
			coop.is_dedicated = function() return true end
			modes.install(facade, "srv_world")
			deliver(msg, 1)
			local _, forwarded = sent("mods.pda_marks_q")
			check(forwarded and forwarded.target == 0x101 and not sent("mods.pda_marks_r"), "world server forwards the request to the map decider")
			msg = forwarded
			SENT = {}
		end
		as_authority()
		if msg then deliver(msg, authority == "srv_map" and 0 or 1) end
		local replies = SENT
		SENT = {}
		as_player()
		return replies
	end
	local function receive(replies, sender)
		for _, msg in ipairs(replies) do deliver(msg, sender or 0) end
	end

	as_authority()
	actor.pda, actor.unlocked, actor.goodwill = nil, false, -1000
	squad:show()
	frame()
	check(not has(20, ordinary) and not has(20, "warfare_bandit_spot"), "authority with a basic PDA or ghost emits no ordinary map spot")
	if authority == "hostplay" then
		actor.pda, actor.unlocked = pda, true
		frame()
		check(has(20, ordinary) and has(22, member), "co-op host renders a squad and its online squadmate locally")
		spots = {}
	end

	local replies = request()
	check(#replies > 0 and replies[1].target == 1, "request sends unfiltered squad facts only to its requester")
	actor.pda, actor.unlocked = pda, false
	receive(replies)
	check(not has(20, ordinary), "recipient without faction progress does not see the ordinary mark")
	actor.unlocked = true
	frame()
	check(has(20, ordinary) and has(22, member), "unlocked recipient uses the same squad facts with its own PDA and progress")
	actor.pda = nil
	frame()
	check(not has(20, ordinary) and not has(22, member), "unequipping the PDA clears both ordinary spot types")

	as_authority()
	assign(leader, "trader")
	check(SE[21].map_visible == false and not has(21, legacy), "NPC assignment retains world visibility without publishing a shared spot")
	actor.pda, actor.unlocked = pda, true
	local service_reply = request()
	add(21, legacy, "previous shared copy")
	receive(service_reply, 2)
	check(not has(21, service), "a player cannot send another player the authority's service snapshot")
	receive(service_reply)
	check(not has(21, service) and not has(21, legacy), "hostile recipient removes even a previously shared service mark")
	actor.goodwill = 0
	frame()
	check(has(21, service) and not has(20, ordinary), "friendly recipient sees the same NPC assignment and suppresses its duplicate squad mark")
	as_authority()
	stalker_generic.remove_level_spot(21)
	receive(request())
	check(not has(21, service) and has(20, ordinary), "withdrawn NPC assignment clears the service spot and restores the ordinary one")

	if authority == "srv_map" then
		local old_reply = request()
		map = "l02_garbage"
		SendScriptCallback("actor_on_first_update") -- a level change spawns the actor anew
		local other = make_squad(30, 31, map)
		make_npc(31, map)
		make_npc(32, map)
		as_authority()
		other:show()
		receive(request())
		receive(old_reply)
		check(has(30, ordinary) and not has(20, ordinary) and not has(21, service),
			"server map switch displays only the new map's facts and discards a late reply from the previous map")
	end

	as_player()
	actor.pda = pda
	tracker.tracked_bodies[80] = { icon = "deadbody_location_whtx", killer_id = AC_ID, text = "body" }
	tracker.tracked_bodies[81] = { icon = "paw_blue_circle", killer_id = 40, text = "other player's kill" }
	tracker.tracking_mode = 1
	add(80, "storyline_task_location", "task")
	add(80, "another_mod_spot", "other")
	add(80, "deadbody_location_whtx", "legacy tracker")
	tracker.add_body_dot(80, "body")
	tracker.add_body_dot(81, "other player's kill")
	check(has(80, "coop_pda_deadbody_location_whtx") and not has(80, "deadbody_location_whtx"), "tracker uses a local style and retires its legacy style")
	check(not has(81, "coop_pda_paw_blue_circle") and not has(81, "paw_blue_circle"), "tracker filters another player's kill locally")
	SE[80] = { name = function() return "corpse" end }
	add(80, "deadbody", "stock corpse spot")
	SendScriptCallback("map_spot_menu_property_clicked", nil, 80, map, "deadbody")
	check(has(80, "deadbody") and tracker.tracked_bodies[80] ~= nil, "a tracker callback registered before the adapter leaves the stock corpse mark alone")
	task_target = 80
	tracker.remove_dot(80)
	check(not has(80, "coop_pda_deadbody_location_whtx") and has(80, "storyline_task_location") and has(80, "another_mod_spot"),
		"tracker cleanup removes its own mark even when the corpse becomes a task target")
	task_target = nil
	tracker.tracking_mode = 3
	tracker.add_body_dot(81, "other player's kill")
	add(81, "another_mod_spot", "other")
	check(has(81, "coop_pda_paw_blue_circle"), "tracker honors the selected PAW artwork when the filter permits it")
	tracker.clean_slate()
	check(not has(81, "coop_pda_paw_blue_circle") and has(81, "another_mod_spot") and all_removed == 0,
		"clean slate leaves every unrelated mark intact")
end

done("pda marks local " .. role)
