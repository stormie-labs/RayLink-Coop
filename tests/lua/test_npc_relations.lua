-- Dev 57 G13-2: real mod functions, explicit characters, both mode answer sets.
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local function read(path)
	local f = assert(io.open(path, "r")); local s = f:read("*a"); f:close(); return s
end
local function module(name, source)
	local m = {}; setmetatable(m, { __index = _G }); _G[name] = m
	local f = assert(loadstring(source, "@" .. name .. ".script")); setfenv(f, m); f(); return m
end
local function function_source(path, first, following)
	local s = read(path)
	local a = assert(s:find(first, 1, true)); local b = assert(s:find(following, a + #first, true))
	return s:sub(a, b - 1)
end
local corpus = "temp/review/corpus/merged/"
local stock = "D:/Projects/ForEverything/anomaly-ref/unpacked/scripts/game_relations.script"
local real_squad = function_source(corpus .. "sim_squad_scripted.script",
	"function sim_squad_scripted:set_squad_relation(relation)", "local function reset_animation")
local real_remove = function_source(corpus .. "sim_squad_scripted.script",
	"function sim_squad_scripted:remove_squad()", "function sim_squad_scripted:remove_npc(")
local real_reset = function_source(stock, "function reset_goodwill (", "function is_relation_allowed (")
local real_set = function_source(stock, "function set_npcs_relation(", "function get_npc_sympathy(")
local real_sky = read(corpus .. "tasks_skyfall.script")
-- Regression (build 57): G.A.M.M.A.'s configs\unlocalizers\emission_fix_task_defense_mdata.ltx ([tasks_defense] MDATA)
-- has the engine (script_storage.cpp) turn the file local MDATA into a module field before the script compiles
-- ("local MDATA" becomes "MDATA = nil"). Load tasks_defense in that shape, as the game does.
local DEFENSE_UNLOCAL = { MDATA = true }
local function unlocalize(src, unlocals)
	local out = {}
	for line in (src .. "\n"):gmatch("([^\n]*)\n") do
		local l = line:gsub("\r$", "")
		local rest = l:match("^local[ \t]+(.*)$")
		if rest and not rest:match("^function[ \t]") then
			local body = rest:gsub("%-%-.*$", "")
			local has_value = body:find("=", 1, true) ~= nil
			for v in (body:match("^([^=]*)") or ""):gmatch("[^,]+") do
				if unlocals[v:match("^%s*(.-)%s*$")] then
					l = rest
					if not has_value then
						local code, comment = l:match("^(.-)(%-%-.*)$")
						l = code and (code .. "= nil " .. comment) or (l .. " = nil")
					end
					break
				end
			end
		end
		out[#out + 1] = l
	end
	return table.concat(out, "\n")
end
local real_defense = unlocalize(read(corpus .. "tasks_defense.script"), DEFENSE_UNLOCAL)
local original_random = math.random
local names = modes.names()

for _, role in ipairs(names) do
	print("== NPC relations " .. role)
	MODE = role == "none" and "sp" or "host"
	coop.is_map_server = function() return role == "srv_map" end
	coop.is_dedicated = function() return role == "srv_world" end
	coop.is_client = function() return role == "srv_map" end
	coop.is_host = function() return role ~= "srv_map" and role ~= "none" end
	OBJ, SE, SENT, TIMEEV, LOG = {}, {}, {}, {}, {}
	local factions = { [0] = "stalker", [500] = "greh", [600] = "freedom", [700] = "dolg", [800] = "stalker" }
	local registry = { { id = 0, avatar_id = 0, is_self = true }, { id = 1, avatar_id = 500 }, { id = 2, avatar_id = 600 } }
	coop.players = function() return registry end
	coop.members = function()
		if role == "srv_map" then return {} end
		return { { id = 500 }, { id = 600 }, { id = 700 }, { id = 800 } }
	end
	coop.avatar_of = function(peer) for _, p in ipairs(registry) do if p.id == peer then return p.avatar_id end end end
	coop.peer_of_avatar = function(id) for _, p in ipairs(registry) do if p.avatar_id == id then return p.id end end end
	local actor = make_actor()
	local _, a = spawn("coop_player_avatar", nil, nil, { id = 500, kind = "stalker" })
	local _, b = spawn("coop_player_avatar", nil, nil, { id = 600, kind = "stalker" })
	local _, npc = spawn("stalker", nil, nil, { id = 101, kind = "stalker" })
	spawn("stalker", nil, nil, { id = 102, offline = true })
	spawn("coop_player_avatar", nil, nil, { id = 700, offline = true })
	spawn("coop_player_avatar", nil, nil, { id = 800, offline = true })
	local writes, goodwill, gw_reads, tips = {}, {}, {}, {}
	local info_hold, info_leaks = 0, 0
	coop.story_hold_infos = function(on) info_hold = info_hold + (on and 1 or -1); return true end
	local GO = getmetatable(actor)
	function GO:character_community() return self._disguise or ("actor_" .. (factions[self:id()] or "stalker")) end
	function GO:force_set_goodwill(value, target)
		assert(type(target) ~= "number", "online setter must receive an object")
		writes[self:id() .. ":" .. target:id()] = value
	end
	function GO:has_info(info) return self._infos and self._infos[info] or false end
	function GO:give_info_portion(info)
		if MODE == "client" and info_hold == 0 then info_leaks = info_leaks + 1 end
		self._infos = self._infos or {}; self._infos[info] = true
	end
	function GO:disable_info_portion(info)
		if MODE == "client" and info_hold == 0 then info_leaks = info_leaks + 1 end
		self._infos = self._infos or {}; self._infos[info] = nil
	end
	for id, se in pairs(SE) do
		function se:force_set_goodwill(value, target)
			assert(type(target) == "number")
			if SE[target] then writes[self.id .. ":" .. target] = value end
		end
		function se:community() return factions[self.id] or "stalker" end
	end
	function character_community(o) return o:character_community() end
	function get_actor_true_community() return factions[0] end
	local personal
	coop_tasks = {
		personal_character = function() return personal end,
		character_of = function(peer) return coop.avatar_of(peer) end,
		peer_for_character = function(id) return coop.peer_of_avatar(id) end,
		with_character = function(id, fn, ...)
			local previous = personal; personal = id
			local result = { pcall(fn, ...) }; personal = previous
			if not result[1] then error(result[2]) end
			return unpack(result, 2)
		end,
	}
	coop_faction = {
		faction_of_character = function(id) return factions[id] end,
		faction_of = function(peer) return factions[coop.avatar_of(peer)] end,
		group_faction = function() return factions[0] end,
	}
	local reset_enabled = true
	ui_options = { get = function() return reset_enabled end }
	relation_registry = {
		community_relation = function(f, to)
			f = f:gsub("^actor_", "")
			if (f == "dolg" or f == "greh") and to == "freedom" then return -2000 end
			if f == "bandit" and to == "army" then return -2000 end
			return 0
		end,
		community_goodwill = function(f, id) return goodwill[f .. ":" .. (personal or id)] or 0 end,
		set_community_goodwill = function(f, id, value) goodwill[f .. ":" .. (id == 0 and personal or id)] = value end,
	}
	coop_reputation = { goodwill_of = function(f, id)
		gw_reads[#gw_reads + 1] = id; return goodwill[f .. ":" .. id] or 0
	end }
	game_relations = module("game_relations", real_reset .. real_set)
	game_relations.ENEMIES = -1000
	game_relations.is_factions_enemies = function(f, to) return relation_registry.community_relation(f, to) <= -1000 end
	is_squad_monster = {}
	local class_env = module("sim_squad_scripted", "sim_squad_scripted = {}\n" .. real_squad .. real_remove)
	local class = class_env.sim_squad_scripted
	SIMBOARD = { squads = {}, assign_squad_to_smart = function() end }
	safe_release_manager = { release = function(se) SE[se.id], OBJ[se.id] = nil, nil end }
	local function squad(id, members)
		local q = setmetatable({ id = id, player_id = "stalker", relationship = "enemy" }, { __index = class })
		function q:squad_members()
			local i = 0; return function() i = i + 1; local mid = members[i]; if mid then return { id = mid, object = SE[mid] } end end
		end
		function q:name() return "ambush" end
		function q:unregister_member() end
		function q:hide() end
		SE[id] = q; return q
	end
	local q = squad(200, {101, 102})
	task_status_functor, task_functor, xr_effects, xr_conditions = {}, {}, {}, {}
	local sky_src = real_sky
	if role ~= "none" then
		local compat = load_script("coop_npc_compat")
		sky_src = assert(compat.rewrite_text(sky_src, compat._rewrites().tasks_skyfall))
	end
	tasks_skyfall = module("tasks_skyfall", sky_src)
	grok_sin_allied_to_mutants = module("grok_sin_allied_to_mutants", read(corpus .. "grok_sin_allied_to_mutants.script"))
	grok_sin_allied_to_mutants.load_state({})
	utils_data = { CTime_to_table = function(t) return t.days end,
		CTime_from_table = function(days) return { days = days } end }
	dynamic_news_helper = { send_tip = function(text) tips[#tips + 1] = { text = text, id = db.actor:id() } end }
	axr_task_manager = { ongoing_tasks = {} }
	local day = 0
	game.get_game_time = function() return { days = day, diffSec = function(_, other) return (day - (other.days or 0)) * 86400 end } end
	level.get_start_time = function() return { days = 0 } end
	tasks_defense = module("tasks_defense", real_defense)
	tasks_defense.load_state({})
	check(type(rawget(tasks_defense, "MDATA")) == "table", role .. " m09 unlocalized tasks_defense keeps MDATA as a module field")
	local faction_fn = game_relations.is_factions_enemies
	load_script("coop_main"); load_script("coop_mods_core"); load_script("coop_npc_players"); load_script("coop_mode")
	local set = modes.install(coop_mode, role, { seat_plays = function(peer)
		return peer >= 0 and peer < 16 and (peer ~= 0 or role == "hostplay")
	end })
	load_script("coop_trust"); coop_trust.reset_for_test({ default = "refuse" })
	coop_main.on_game_start()
	AddScriptCallback("on_enemy_eval")
	AddScriptCallback("physic_object_on_hit_callback")
	if role ~= "srv_map" then tasks_skyfall.on_game_start() end
	if role == "hostplay" or role == "srv_world" then load_script("coop_mods_nta").on_game_start() end
	-- A missing adapter gives real behavioural red failures, not a missing-file exception.
	local f = io.open("gamedata/scripts/coop_npc_relations.script", "r")
	local adapter = {}
	if f then f:close(); adapter = load_script("coop_npc_relations"); adapter.on_game_start() end
	if role == "srv_map" then tasks_skyfall.on_game_start() end
	local leads = role == "hostplay" or role == "srv_map"
	local active = role ~= "none"
	local function clear() for k in pairs(writes) do writes[k] = nil end end
	local function has(src, cid, value) return writes[src .. ":" .. cid] == value end

	-- m07: explicit audience includes offline recipients and late participants.
	q:set_squad_relation("friend")
	if active then
		check(has(101, 500, 1000) and has(102, 500, 1000), role .. " m07 online/offline members target client")
		check(not has(101, 0, 1000) or role == "hostplay", role .. " m07 ghost excluded")
		factions[900] = "stalker"; registry[#registry + 1] = { id = 3, avatar_id = 900 }
		if adapter.update then adapter.update() end
		check(not has(102, 900, 1000), role .. " m07 roster precedes the recipient ALife entity")
		spawn("coop_player_avatar", nil, nil, { id = 900, kind = "stalker" })
		if adapter.update then adapter.update() end
		SendScriptCallback("actor_on_update")
		check(has(101, 900, 1000) and has(102, 900, 1000), role .. " m07 late join replays offline member relation")
		local mixed = squad(203, {101, 700})
		clear(); mixed:set_squad_relation("friend")
		check(not has(700, 500, 1000), role .. " m07 stored player proxy is not an NPC member")
	else check(has(101, 0, 1000) and has(102, 0, 1000) and not has(101, 500, 1000), "none m07 original unchanged") end
	clear()
	if active then
		if adapter.set_squad_relation_for then adapter.set_squad_relation_for(q, "enemy", 600) else q:set_squad_relation("enemy") end
		check(has(102, 600, -1000) and not has(102, 500, -1000), role .. " m07 explicit audience does not leak to another player")
		local saved = {}; if adapter.save_state then adapter.save_state(saved) end
		check(type(saved.coop_npc_relations_v1) == "table", role .. " m07 relation policy saved for late participants")
		clear()
		if adapter.load_state then adapter.load_state(saved); adapter.update() end
		check(has(102, 600, -1000) and has(102, 500, 1000), role .. " m07 load restores default audience plus explicit override")
		if leads then
			local online = OBJ[600]; OBJ[600] = nil
			if adapter.set_squad_relation_for then adapter.set_squad_relation_for(q, "neutral", 600) end
			check(has(101, 600, 0), role .. " m07 online NPC uses offline recipient for another map")
			OBJ[600] = online
		end
		if role == "srv_map" then
			local connected = registry
			registry = { connected[1], connected[2] }
			clear()
			coop_main.on_event("mods.npcrel_policy", coop_main.encode({ s = 200, c = 600, r = "friend" }), 0)
			registry = connected
			if adapter.update then adapter.update() end
			check(has(102, 600, 1000), "srv_map m07 remembers a world policy before the recipient reaches the roster")
		end
	end
	clear()

	-- m19: explicit goodwill bypasses another reward recipient, with the same faction.
	goodwill["army:500"] = -1500; goodwill["army:0"] = 0
	personal = 600
	local enemy = tasks_skyfall.is_enemies_with_military(a)
	personal = nil
	if active then
		check(enemy and gw_reads[#gw_reads] == 500, role .. " m19 one explicit character bypasses reward context")
		personal = 600
		local scoped_ok, scoped_enemy = coop_mods_core.as_player(a, tasks_skyfall.is_enemies_with_military)
		check(scoped_ok and scoped_enemy and gw_reads[#gw_reads] == 500,
			role .. " m19 no-argument task check reads the scoped actor, even during another player's reward")
		personal = nil
		b._disguise = "actor_bandit"
		check(tasks_skyfall.is_enemies_with_military(b), role .. " m19 current community still affects cover")
		b._disguise = nil
		if role ~= "hostplay" then
			local reads = #gw_reads
			check(not tasks_skyfall.is_enemies_with_military() and #gw_reads == reads,
				role .. " m19 unscoped ghost does not silently borrow a participant")
		end
		check(not tasks_skyfall.is_enemies_with_military(65534), role .. " m19 unknown character excluded")
		if role ~= "hostplay" then check(not tasks_skyfall.is_enemies_with_military(actor), role .. " m19 ghost excluded") end
		if role == "hostplay" or role == "srv_world" then
			SendScriptCallback("actor_on_first_update")
			local reads = #gw_reads
			check(not tasks_skyfall.is_enemies_with_military() and #gw_reads - reads == (role == "hostplay" and 1 or 0),
				role .. " m19 late NTA wrapper does not substitute another player for the selected actor")
		end
	else check(not enemy, "none m19 original unchanged") end

	-- Use the real hit callback and its delayed closure, with the legacy proxy rewrite.
	tasks_skyfall.load_state({ skyfall_task_data = { static_heli_id = 101, barrels_ids = {} } })
	local exposed, blasts = {}, 0
	tasks_skyfall.blow_cover = function() exposed[#exposed + 1] = db.actor:id() end
	tasks_skyfall.blow_static_heli = function() blasts = blasts + 1 end
	local function hit(who)
		SendScriptCallback("physic_object_on_hit_callback", npc, 1, nil, who, 0)
	end
	if leads then
		local reads = #gw_reads
		personal = 600
		hit(a)
		check(#gw_reads == reads, role .. " m19 hit defers the shooter relation lookup")
		run_time_events(200)
		check(#exposed == 0 and #gw_reads == reads + 1 and gw_reads[#gw_reads] == 500,
			role .. " m19 hit timer keeps the already-hostile shooter's personal goodwill")
		personal = nil

		goodwill["army:500"] = 0
		a._disguise = "actor_bandit"
		hit(a)
		run_time_events(200)
		check(#exposed == 0 and gw_reads[#gw_reads] == 500,
			role .. " m19 hit timer uses the shooter's current faction")
		a._disguise = nil

		goodwill["army:0"] = -1500
		hit(a)
		run_time_events(200)
		check(#exposed == 1 and exposed[1] == 500 and db.actor:id() == 0 and gw_reads[#gw_reads] == 500,
			role .. " m19 hit timer exposes the friendly shooter even with a hostile scene actor")
		goodwill["army:0"], goodwill["army:500"] = 0, -1500

		for _ = 1, 16 do hit(a) end
		run_time_events(200)
		check(blasts == 1 and #exposed == 1, role .. " m19 hit timer keeps the original blast threshold")
	end
	if not coop_mode.actor_is_player() then
		hit(actor)
		check(TIMEEV["0:counting_hits"] == nil, role .. " m19 ghost cannot start a hit timer")
	elseif not active then
		hit(a)
		hit(actor)
		run_time_events(200)
		check(#exposed == 1 and exposed[1] == 0, "none m19 stock hit timer still exposes the actor")
	end

	-- s36: every stored real character, both sides of a war, unrelated faction preserved.
	for _, cid in ipairs({0, 500, 600, 700, 800}) do goodwill["dolg:" .. cid] = 70; goodwill["freedom:" .. cid] = 90 end
	game_relations.reset_goodwill("actor_freedom", "dolg")
	if active and role ~= "srv_map" then
		check(goodwill["dolg:600"] == 0 and goodwill["freedom:700"] == 0, role .. " s36 opposite sides incl stored offline proxy")
		check(goodwill["dolg:800"] == 70 and goodwill["dolg:0"] == 70, role .. " s36 no truthy-or reset of unrelated player/ghost")
	elseif role == "srv_map" then
		check(sent_count("mods.npcrel_reset") == 1 and goodwill["dolg:600"] == 70, "srv_map s36 forwards to world without local reset")
	else check(goodwill["dolg:0"] == 0, "none s36 original unchanged") end
	reset_enabled = false
	game_relations.reset_goodwill("freedom", "dolg")
	check(goodwill["dolg:800"] == 70, role .. " s36 option disabled preserves goodwill")
	reset_enabled = true
	if role == "srv_world" then
		local event = coop_main.encode({ a = "freedom", b = "dolg", o = "map1:war1" })
		goodwill["dolg:600"] = 45
		coop_main.on_event("mods.npcrel_reset", event, 257)
		check(goodwill["dolg:600"] == 0, "srv_world s36 map fact reaches world owner")
		goodwill["dolg:600"] = 25
		coop_main.on_event("mods.npcrel_reset", event, 257)
		check(goodwill["dolg:600"] == 25, "srv_world s36 repeated operation cannot erase newly earned goodwill")
	end

	-- m33: use the mod's own pact table at the mutant's behaviour authority.
	local _, mutant = spawn("dog", nil, nil, { id = 301, kind = "monster" })
	local pack = squad(202, {301, 302})
	function get_object_squad(o) return o:id() == 301 and pack or nil end
	grok_sin_allied_to_mutants.on_game_start()
	SendScriptCallback("monster_on_before_hit", mutant, { draftsman = a }, 0, {})
	local pact = {}; grok_sin_allied_to_mutants.save_state(pact)
	if active then
		check((pact.grok_sin_allied_to_mutants[301] == true) == leads
			and (pact.grok_sin_allied_to_mutants[302] == true) == leads, role .. " m33 registered Sin shooter breaks mutant pack pact at level owner")
	else check(not pact.grok_sin_allied_to_mutants[301], "none m33 original client ignored") end
	if role == "hostplay" then
		grok_sin_allied_to_mutants.load_state({}); factions[0] = "greh"; actor._disguise = "greh"
		grok_sin_allied_to_mutants.monster_on_before_hit(mutant, { draftsman = actor }, 0, {})
		local saved = {}; grok_sin_allied_to_mutants.save_state(saved)
		check(saved.grok_sin_allied_to_mutants[301] == true, "hostplay m33 host normalized greh breaks pact")
		factions[0] = "stalker"
	end
	if leads then
		local flags = { override = true, result = false }
		SendScriptCallback("on_enemy_eval", mutant, a, flags)
		check(flags.override == false, role .. " m33 broken pact lets mutant evaluate aggression")
		grok_sin_allied_to_mutants.load_state({})
		grok_sin_allied_to_mutants.monster_on_before_hit(mutant, { draftsman = npc }, 0, {})
		local saved = {}; grok_sin_allied_to_mutants.save_state(saved)
		check(not saved.grok_sin_allied_to_mutants[301], role .. " m33 ordinary NPC does not count as a Sin player")
		if role == "srv_map" then
			grok_sin_allied_to_mutants.monster_on_before_hit(mutant, { draftsman = actor }, 0, {})
			saved = {}; grok_sin_allied_to_mutants.save_state(saved)
			check(not saved.grok_sin_allied_to_mutants[301], "srv_map m33 ghost shooter excluded")
		end
	end

	-- m09: original probability/cooldowns, true group faction, addressed announcements.
	day = 30
	factions[0] = "stalker"; actor._disguise = "actor_dolg"
	math.random = function() return 1 end
	local available = tasks_defense.barrier_defense_available("barrier_defense_monolith", b)
	if active then check(available, role .. " m09 eligible real participant survives ghost/disguise")
	else check(not available, "none m09 original disguised actor remains ineligible") end
	-- clear last_check from the availability probe, then exercise the real callback and timer.
	tasks_defense.load_state({})
	if role == "srv_world" then OBJ[500], OBJ[600], OBJ[900] = nil, nil, nil end
	tasks_defense.actor_on_first_update()
	run_time_events(21000)
	if active and role ~= "srv_map" then
		local received = sent("mods.npcrel_offer")
		check(received and received.tid == "barrier_defense_monolith", role .. " m09 sends defense offer to eligible character")
		local hostile = false
		for _, event in ipairs(SENT) do if event.name == "mods.npcrel_offer" and event.target == 2 then hostile = true end end
		check(hostile, role .. " m09 freedom player addressed")
		local sent_hostile = false
		for _, event in ipairs(SENT) do
			if event.name == "mods.npcrel_offer" and event.target == 1 then sent_hostile = true end
		end
		check(sent_hostile == (role == "hostplay"), role .. " m09 true group faction in co-op, separate eligibility on server")
		if role == "hostplay" then
			check(actor:has_info("barrier_defense_monolith_announced"), "hostplay m09 local host gets same offer directly")
		end
		-- The first-update callback and the roster refresh can both run before the 20s timer.
		tasks_defense.load_state({}); SENT, TIMEEV = {}, {}
		actor._infos = nil
		local rolls = 0
		math.random = function() rolls = rolls + 1; return 1 end
		tasks_defense.actor_on_first_update()
		local late_seat = table.remove(registry)
		if adapter.update then adapter.update() end
		registry[#registry + 1] = late_seat
		check(rolls == 1, role .. " m09 pending offer does not spend another defense check on roster refresh")
		math.random = function() return 1 end
		run_time_events(21000)
		-- Players who change faction during the delay no longer qualify.
		tasks_defense.load_state({}); SENT, TIMEEV = {}, {}
		tasks_defense.actor_on_first_update()
		local was = factions[600]; factions[600] = "dolg"
		run_time_events(21000)
		local wrong = false
		for _, event in ipairs(SENT) do if event.name == "mods.npcrel_offer" and event.target == 2 then wrong = true end end
		check(wrong == (role == "hostplay"), role .. " m09 delayed offer rechecks current true faction")
		factions[600] = was
		-- A player can become hostile after receiving the offer: expiry still reaches him.
		tasks_defense.load_state({ defense_task_data = { barrier_defense_monolith = { last_msg_time = 28 }, barrier_defense_zombie = {} } })
		factions[600] = "dolg"; SENT, TIMEEV = {}, {}
		tasks_defense.actor_on_first_update()
		local expired = false
		for _, event in ipairs(SENT) do
			if event.name == "mods.npcrel_offer" and event.target == 2 and coop_main.decode(event.payload).expire then expired = true end
		end
		check(expired, role .. " m09 expiry also addresses a former eligible participant")
		factions[600] = was
		-- World startup may happen before any player has joined.
		if role == "srv_world" then
			tasks_defense.load_state({}); SENT, TIMEEV = {}, {}
			local initial = registry
			tasks_defense.actor_on_first_update()
			registry = {}
			run_time_events(21000)
			local state = {}; tasks_defense.save_state(state)
			check(sent_count("mods.npcrel_offer") == 0 and not state.defense_task_data.barrier_defense_monolith.last_msg_time,
				"srv_world m09 undelivered offer does not consume the week's cooldown")
			registry = initial
			tasks_defense.load_state({}); SENT, TIMEEV = {}, {}
			local connected = registry; registry = {}
			tasks_defense.actor_on_first_update()
			if adapter.update then adapter.update() end
			registry = connected
			NOW = NOW + 1000 -- the adapter's next update comes a second later: the player list of a new frame
			if adapter.update then adapter.update() end
			run_time_events(21000)
			check(sent_count("mods.npcrel_offer") > 0, "srv_world m09 participant joining after world startup gets an offer")
		end
	elseif role == "srv_map" then
		check(sent_count("mods.npcrel_offer") == 0, "srv_map m09 world owns defense scheduling")
	end
	check(game_relations.is_factions_enemies == faction_fn, role .. " wrappers do not replace global faction rules")
	if active then
		local before = goodwill["dolg:800"]
		coop_main.on_event("mods.npcrel_reset", coop_main.encode({ a = "stalker", b = "dolg", o = "forged", from = 257 }), 1)
		check(goodwill["dolg:800"] == before, role .. " wire sender comes from transport, player cannot forge world reset")
		local malformed = pcall(coop_main.on_event, "mods.npcrel_policy", coop_main.encode({ s = "nan", c = -1, r = "%s" }), 257)
		check(malformed, role .. " malformed policy is bounded and cannot become a format string")
		clear()
		if role ~= "hostplay" then
			coop_main.on_event("mods.npcrel_policy", coop_main.encode({ s = 200, c = 500, r = "neutral" }), role == "srv_map" and 0 or 258)
			check(has(102, 500, 0), role .. " wire authoritative policy reaches a second map/world")
		end
		coop_trust.reset_for_test({ default = "log" })
		if role ~= "srv_map" then
			goodwill["dolg:800"] = 62
			coop_main.on_event("mods.npcrel_reset", coop_main.encode({ a = "stalker", b = "dolg", o = "player" }), 1)
			local sender_check = coop_trust.status().npcrel_reset_sender
			check(goodwill["dolg:800"] == 62 and sender_check and sender_check.failed == 1,
				role .. " s36 player traffic cannot supply authority facts in log mode")
		end
		coop_main.on_event("mods.npcrel_policy", coop_main.encode({ s = -4, c = 1e9, r = "%s" }), 1)
		check(not log_has("event mods.npcrel_policy"), role .. " diagnostic trust mode still parses malformed fields safely")
		q:remove_squad()
		local reused = squad(200, {104}); spawn("stalker", nil, nil, { id = 104, kind = "stalker" })
		clear(); if adapter.update then adapter.update() end
		check(next(writes) == nil, role .. " m07 removed squad policy cannot affect reused ALife id")
		local after_remove = {}; if adapter.save_state then adapter.save_state(after_remove) end
		check(after_remove.coop_npc_relations_v1 and not after_remove.coop_npc_relations_v1[200], role .. " m07 removed audience is absent from save")
		-- The same adapter on a player's mirror: host numbering differs from local actor 0.
		MODE, SELF = "client", 1
		coop.is_client = function() return true end; coop.is_host = function() return false end
		coop.is_map_server = function() return false end; coop.is_dedicated = function() return false end
		registry = { { id = 1, avatar_id = 0, is_self = true }, { id = 2, avatar_id = 600 } }
		if role == "hostplay" then registry[#registry + 1] = { id = 0, avatar_id = 500 } end
		modes.install(coop_mode, role, { actor_is_player = function() return true end,
			leads_here = function() return false end, decides_world = function() return false end,
			is_player_mirror = function() return true end,
			seat_plays = function(peer) return peer >= 0 and peer < 16 and (peer ~= 0 or role == "hostplay") end })
		clear(); q:set_squad_relation("enemy")
		check(next(writes) == nil, role .. " mirror cannot decide squad relations")
		check(tasks_skyfall.is_enemies_with_military() and gw_reads[#gw_reads] == 500,
			role .. " m19 mirror defaults to its own explicit host-numbered character")
		if role ~= "hostplay" then
			local before_reads = #gw_reads
			check(not tasks_skyfall.is_enemies_with_military(0) and #gw_reads == before_reads, role .. " m19 mirror excludes world ghost id 0")
		end
		coop_main.on_event("mods.npcrel_offer", coop_main.encode({ tid = "barrier_defense_monolith" }), 0)
		check(actor:has_info("barrier_defense_monolith_announced"), role .. " m09 addressed offer shows on player's own machine")
		coop_main.on_event("mods.npcrel_offer", coop_main.encode({ tid = "barrier_defense_monolith", expire = true }), 0)
		check(not actor:has_info("barrier_defense_monolith_announced") and tips[#tips] and tips[#tips].text == "barrier_defense_monolith_end_announce",
			role .. " m09 expiration clears local offer and retains the mod's ending news")
		check(info_leaks == 0 and info_hold == 0, role .. " m09 personal offer info does not leak into shared story and hold is balanced")
		actor.give_info_portion = function() error("injected info failure") end
		coop_main.on_event("mods.npcrel_offer", coop_main.encode({ tid = "barrier_defense_monolith" }), 0)
		check(info_hold == 0, role .. " m09 story hold is released after a failed personal info write")
	end
	math.random = original_random
end
done("npc_relations")
