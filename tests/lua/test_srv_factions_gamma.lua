-- Dev 57 G13-5: quest recipients on the world server and the stock GAMMA filters on map servers.
dofile("tests/lua/support/harness_npc.lua")
local modes = dofile("tests/lua/support/modes.lua")

local CORDON, GARBAGE, NORTH = "l01_escape", "l02_garbage", "l10_radar"
local MAPS = { CORDON, GARBAGE, NORTH }
local BRIDGES = { { bridge = 256, level = 1 }, { bridge = 257, level = 2 }, { bridge = 258, level = 3 } }
local EXOS, NORTH_NPCS = "grok_nes", "grok_no_north_faction_in_south"
local MODULE = "coop_srv_factions_gamma"
local PROFILE = "temp/review/corpus/merged/"

local function gamma_source(name)
	local file = io.open(PROFILE .. name .. ".script", "rb")
	if not file then
		local stand = "E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/"
		file = assert(io.open(stand .. name .. ".script", "rb"), "active GAMMA script required: " .. name)
	end
	local source = file:read("*a"):gsub("\r\n", "\n")
	file:close()
	return source
end

local function gamma(M, name, source)
	local env = setmetatable({}, { __index = M.env })
	M.env[name] = env
	setfenv(assert(loadstring(source or gamma_source(name), "@" .. name .. ".script")), env)()
	return env
end

local ceasefire = assert(gamma_source("xr_effects"):match("(function stalker_ceasefire%(%).-\nend)"),
	"GAMMA's Scorcher ceasefire effect was not found")

local function npc(M, id, faction, visual, section)
	local o = M.add(make_obj(id, 0, 0, 0, { _section = section, _comm = faction }))
	function o:get_visual_name() return visual end
	function o:iterate_inventory(f, owner)
		for _, item in ipairs(self._inv) do f(owner, item) end
	end
	function o:set_health_ex(health) self.health = health end
	return o
end

local function boot(role, peer, map, roster, legacy_first)
	local M = machine(role == "none" and "single" or role == "map" and "client" or "host", peer,
		{ [0] = 0, [1] = 501, [2] = 502, [3] = 503 })
	local e = M.env
	M.roster, M.factions = roster or {}, {}
	M.relations, M.news, M.timers = {}, {}, {}
	M.ghost_faction = "army"
	e.coop.players = function() return M.roster end
	e.coop.is_map_server = function() return role == "map" end
	e.coop.is_dedicated = function() return role == "world" end
	e.coop.levels = {
		split = function() return role == "map" or role == "world" end,
		map_servers = function() return BRIDGES end,
	}
	e.level.name = function() return assert(map, "world server has no player map") end
	local ghost = { m_game_vertex_id = 1 }
	e.alife = function()
		return {
			level_name = function(_, id) return MAPS[id] end,
			actor = function() return ghost end,
			object = function(_, id) return M.objects[id] end,
			release = function(_, obj) if obj then M.objects[obj:id()] = nil end end,
		}
	end
	e.game_graph = function() return { vertex = function() return { level_id = function()
		for id, name in ipairs(MAPS) do if name == map then return id end end
	end } end } end
	e.get_actor_true_community = function() return M.ghost_faction end
	e.IsStalker = function() return true end
	e.character_community = function(o) return o:character_community() end
	e.get_object_story_id = function(id) local o = M.objects[id]; return o and o._story end
	e.get_object_squad = function(o) return o._squad end
	e.demonized_time_events = { CreateTimeEvent = e.CreateTimeEvent }
	local inis = {
		["creatures\\grok_nes_models_capture.ltx"] = { exo = { { "model_path", "exo.ltx" } } },
		["creatures\\grok_nes_bone_profiles.ltx"] = { exo = { { "bone_profile", "body_damage_035" } } },
		["exo.ltx"] = { bone_protection = { { "bones_protection_sect", "exo" } } },
	}
	e.ini_file = function(name) return make_ini(inis[name] or {}) end
	e.alife_storage_manager = { get_state = function() return { coop_faction = { chars = M.factions } } end }
	e.game_relations = {
		is_factions_enemies = function(_, f) return f ~= "ecolog" end,
		save_relation = function(a, b, value) M.relations[#M.relations + 1] = { a, b, value } end,
		send_news = function(a, b, id) M.news[#M.news + 1] = { a, b, id } end,
	}
	gamma(M, "xr_effects", ceasefire)
	M.stock_ceasefire = e.xr_effects.stalker_ceasefire
	if map then
		gamma(M, EXOS).on_game_start()
		gamma(M, NORTH_NPCS).on_game_start()
	end
	load_script(M, "coop_mode")
	modes.live(e.coop_mode, function(name) return load_script(M, name) end)
	for _, name in ipairs({ "coop_mods_core", "coop_npc_players", "coop_core_world_news", "coop_tasks",
		"coop_faction", "coop_srv_faction", "coop_quests_core", "coop_srv_levels_share" }) do load_script(M, name) end
	e.coop_srv_faction.on_game_start()
	e.coop_srv_levels_share.on_game_start()
	if legacy_first == true then load_script(M, "coop_srv_tasks").on_game_start() end
	-- The red run exercises the installed GAMMA scripts before the G13-5 adapter exists.
	local f = io.open("gamedata/scripts/" .. MODULE .. ".script", "rb")
	if f then
		f:close()
		load_script(M, MODULE).on_game_start()
	end
	if legacy_first == false then load_script(M, "coop_srv_tasks").on_game_start() end
	return M
end

local function update(M, object)
	M.fire("npc_on_update", object)
	NOW = NOW + 1200
	M.fire("npc_on_update", object)
	for _, timer in ipairs(M.timers) do timer.f(unpack(timer.p)) end
	M.timers = {}
end

local function tick()
	NOW = NOW + 1500
	for _, M in pairs(MACHINES) do M.env.coop_srv_levels_share._test.tick() end
	pump()
end

local function row(peer, map, elsewhere)
	return { id = peer, avatar_id = 500 + peer, level = map, elsewhere = elsewhere }
end

local function relations(M)
	local counts = {}
	for _, change in ipairs(M.relations) do
		local key = change[1] .. "/" .. change[2] .. "/" .. change[3]
		counts[key] = (counts[key] or 0) + 1
	end
	return counts
end

print("== ceasefire_uses_each_task_recipient_faction_once")
do
	reset_world()
	local M = boot("world", 0, nil, { row(1, 1) })
	local e = M.env
	-- 502 and 503 are saved characters who were task recipients and are now offline.
	M.factions = { [501] = { f = "freedom" }, [502] = { f = "dolg" }, [503] = { f = "freedom" },
		[504] = { f = "bandit" }, [505] = { f = "monolith" }, [506] = { f = "zombied" },
		[507] = { f = "army" }, [508] = { f = "ecolog" }, [509] = { f = "killer" } }
	e.coop_tasks.with_participants({ 0, 501, 502, 503, 504, 505, 506, 507, 508 }, 1, e.xr_effects.stalker_ceasefire)
	local changed = relations(M)
	for _, f in ipairs({ "freedom", "dolg" }) do
		check(changed["stalker/" .. f .. "/2000"] == 1 and changed["actor_stalker/" .. f .. "/2000"] == 1
			and changed["stalker/actor_" .. f .. "/2000"] == 1, "three stock relation pairs, once for " .. f)
	end
	check(#M.news == 2 and M.news[1][3] == "st_relations_cease_fire" and M.news[2][3] == "st_relations_cease_fire",
		"one stock ceasefire announcement for each affected faction")
	check(#M.relations == 6, "blacklisted, non-hostile and non-recipient factions are excluded")
end

print("== ceasefire_single_recipient_and_ghost")
do
	reset_world()
	local M = boot("world", 0)
	local e = M.env
	M.factions = { [501] = { f = "dolg" } }
	M.ghost_faction = "killer"
	e.coop_tasks.with_character(501, e.xr_effects.stalker_ceasefire)
	check(relations(M)["stalker/dolg/2000"] == 1 and #M.relations == 3, "single recipient uses his saved true faction")
	e.xr_effects.stalker_ceasefire()
	e.coop_tasks.with_character(0, e.xr_effects.stalker_ceasefire)
	check(#M.relations == 3, "a world call without a player recipient cannot change the ghost's relations")
end

print("== ceasefire_chains_with_the_server_task_wrapper")
for _, legacy_first in ipairs({ true, false }) do
	reset_world()
	local M = boot("world", 0, nil, { row(1, 1) }, legacy_first)
	local e = M.env
	M.factions = { [501] = { f = "freedom" }, [502] = { f = "dolg" } }
	e.coop_tasks.with_participants({ 501, 502 }, 1, e.xr_effects.stalker_ceasefire)
	check(#M.relations == 6 and #M.news == 2 and e.get_actor_true_community() == "army",
		"S5 installed " .. (legacy_first and "before" or "after") .. " G13-5: both factions changed, getter restored")
end

print("== south_filters_use_world_factions_per_map")
do
	reset_world()
	local W = boot("world", 0, nil, { row(1, 1), row(2, 1), row(3, 2) })
	local A = boot("map", 256, CORDON, { row(1, 1), row(2, 1), row(3, 2, true) })
	local B = boot("map", 257, GARBAGE, { row(1, 1, true), row(2, 1, true), row(3, 2) })
	A.ghost_faction, B.ghost_faction = "stalker", "monolith"
	W.factions = { [501] = { f = "stalker" }, [502] = { f = "monolith" }, [503] = { f = "stalker" } }

	local early = npc(A, 600, "monolith", "plain")
	update(A, early)
	check(A.objects[600] == early and early.health == 1, "defer deletion before the world snapshot")
	tick()

	for i, kind in ipairs({ { "monolith", "plain" }, { "killer", "exo" } }) do
		local id = 600 + i
		local ally = npc(A, id, unpack(kind))
		local ordinary = npc(B, id, unpack(kind))
		update(A, ally)
		update(B, ordinary)
		check(A.objects[id] == ally and ally.health == 1, "mixed map keeps " .. kind[2] .. " NPCs")
		check(B.objects[id] == nil and ordinary.health == 0, "northern player elsewhere does not exempt " .. kind[2] .. " NPCs")
	end

	-- A faction change requires no new connection or client claim.
	W.factions[502] = { f = "freedom" }
	tick()
	local generic = npc(A, 620, "monolith", "plain")
	update(A, generic)
	check(A.objects[620] == nil, "changing the last northern player's faction resumes filtering")

	local proxy = npc(A, 501, "stalker", "exo", "coop_player_avatar")
	local story = npc(A, 621, "monolith", "exo")
	story._story = "story_actor"
	local companion = npc(A, 622, "monolith", "exo")
	companion:give_info_portion("npcx_is_companion")
	for _, o in ipairs({ proxy, story, companion }) do
		update(A, o)
		check(A.objects[o:id()] == o and o.health == 1, "protected NPC callback target " .. o:id() .. " stays alive")
	end

	A.roster[#A.roster + 1] = row(4, 1)
	local pending = npc(A, 623, "monolith", "plain")
	update(A, pending)
	check(A.objects[623] == pending, "a new arrival without a matching world row defers deletion")
	W.roster[#W.roster + 1] = row(4, 1)
	W.factions[504] = { f = "isg" }
	tick()
	update(A, pending)
	check(A.objects[623] == pending, "new northern arrival is exempt after sync")
end

print("== single_player_and_coop_keep_stock")
for _, role in ipairs({ "none", "co-op" }) do
	reset_world()
	local M = boot(role, 0, CORDON)
	local e = M.env
	M.ghost_faction = "killer"
	check(e.xr_effects.stalker_ceasefire == M.stock_ceasefire and next(e.coop_quests_core.shared().down) == nil,
		role .. ": no G13-5 registrations")
	e.xr_effects.stalker_ceasefire()
	check(relations(M)["stalker/killer/2000"] == 1, role .. ": original local faction applies")
	local ordinary = npc(M, 630, "monolith", "plain")
	update(M, ordinary)
	check(M.objects[630] == nil, role .. ": original south rule applies")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
