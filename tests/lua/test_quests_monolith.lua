-- G14-1. Real Monolith starts and guide timer over the Lua quest transport and S4 role answers.
dofile("tests/lua/support/harness_quests.lua")
local modes = dofile("tests/lua/support/modes.lua")

local STARTS = {
	{ "give_task_esc_military_docs_poisk", "esc_military_docs_task", "military_escape_docs" },
	{ "cs_story_task0", "cs_story_task0", "cs_anom_pribor" },
	{ "barmen_task1", "barmen_task1", "bar_case", once = true },
	{ "ohotnik_task1", "ohotnik_task1", "wpn_bm16_ohotnik", once = true },
	{ "dolg_story_task_1_dop", "dolg_story_task_1_dop", "freon!", once = true },
	{ "dolg_story_task_3", "dolg_story_task_3", "shmatko!,sim_default_duty_1!,sim_default_duty_2!", once = true },
	{ "dolg_story_task_4", "dolg_story_task_4", "pinya!,sim_default_military_5!,sim_default_military_5!", once = true },
	{ "dolg_story_task_5", "dolg_story_task_5", "barbos!,tango!,tribun!", once = true },
}
local MAP = { [1] = "l01_escape", [2] = "l02_garbage", [3] = "l03_agroprom", [4] = "l05_bar", [9] = "fake_start" }

-- The game's way: G.A.M.M.A.'s unlocalizers make tasks_guide's guid / curr_guid module fields (support\unlocalize.lua).
local unlocalize = dofile("tests/lua/support/unlocalize.lua")
local function load_mod(m, name)
	local file = name .. ".script"
	local source = unlocalize.loadfile("temp/review/corpus/merged/" .. file)
	if not source then source = assert(unlocalize.loadfile("E:/RayLinkGames/GAMMA/game-dev/gamedata/scripts/" .. file)) end
	local module = setmetatable({}, { __index = m.env })
	m.env[name] = module
	setfenv(source, module)()
	return module
end

local function setup(role, peer, answer, map, map_by_peer, players)
	local m = machine(role, peer)
	local e = m.env
	m.map, m.view, m.players, m.tips, m.spawns = map, map, {}, 0, {}
	m.active = answer ~= "none"
	for _, id in ipairs(players) do
		m.players[#m.players + 1] = { id = id, is_self = id == peer, avatar_id = id == 0 and 0 or 100 + id,
			level = map_by_peer and map_by_peer[id] }
		if id ~= 0 and id ~= peer then m.new_obj(100 + id, "coop_player_avatar") end
	end
	if map_by_peer and map_by_peer[1] == 2 then
		e.coop.levels = {
			level_of_player = function(id) return map_by_peer[id] end,
			map_servers = function() return { { bridge = 0x101, level = 2 }, { bridge = 0x102, level = 3 } } end,
		}
		e.coop.is_dedicated = function() return answer == "srv_world" end
		e.coop.is_map_server = function() return answer == "srv_map" end
	end
	local facade = load_script(m, "coop_mode")
	modes.install(facade, answer, role == "client" and answer ~= "srv_map" and {
		actor_is_player = function() return true end,
		decides_world = function() return false end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
	} or answer == "srv_map" and {
		where = function(id) return map_by_peer[id] == map and "here" or "away" end,
	} or answer == "srv_world" and {
		-- the world server's layer knows a map server by its link in coop.levels.map_servers: both maps' servers here
		from_level = function(from) return from == 0x101 or from == 0x102 end,
	} or nil)
	e.level.name = function() return MAP[m.view] end
	e.level.map_add_object_spot_ser = function() end
	e.level.map_remove_object_spot = function() end
	m.npc = m.new_obj(700, "guide", vec(5, 0, 0), { _commander = 700 })
	m.npc.has_info = function() return false end
	m.npc.relation = function(_, actor)
		return m.candidate and actor:id() == m.candidate_player and 0 or e.game_object.enemy
	end
	e.game_object = { enemy = 1 }
	e.get_object_squad = function(npc) return npc and npc:id() == 700 and e.alife_object(701) or nil end
	m.new_obj(701, "guide_squad", nil, { _commander = 700 })
	e.dialogs.who_is_npc = function(a, b) return a:id() == e.AC_ID and b or a end
	e.db.OnlineStalkers = map ~= 9 and { 700 } or {}
	e.axr_companions = { companion_squads = {} }
	e.character_community = function() return "stalker" end
	e.dialogs_axr_companion = { is_not_hostage_task_giver = function() return true end }
	e.xr_conditions.is_squad_commander = function() return true end
	e.coop.talk_recent = function(_, id) return id == 700 end
	e.news_manager.send_tip = function() m.tips = m.tips + 1 end
	e.item_device = { is_pda_charged = function() return m.charged == true end }
	e.game = { translate_string = function(key) return key == "st_jg_14" and "%s %s %s" or key end }
	e.dynamic_news_helper = { GetPointDescription = function() return "crossroads" end }
	e.game_graph = function() return { vertex = function(_, id) return { level_id = function() return id end } end } end
	e.SIMBOARD = { smarts_by_names = { road = { id = 800, m_game_vertex_id = 4 } }, smarts = {} }
	e.simulation_objects = { available_by_id = { [800] = true } }
	local sim = {
		level_name = function(_, id) return MAP[id] end,
		create = function(_, section)
			if role == "client" then return nil end
			local i = #m.spawns + 1
			m.spawns[i] = section
			return { on_death = function() m.spawns[i] = section .. "!" end }
		end,
	}
	e.alife = function() return sim end
	local stock = load_mod(m, "tasks_guide")
	stock.g_start_timer = function() m.retries = (m.retries or 0) + 1 end
	stock.is_not_quest_npc = function() return true end
	stock.go_poisk = function()
		m.searched_map = e.level.name()
		if m.view ~= 9 then return MAP[4], 2 end
	end
	load_mod(m, "operacia_monolith")
	load_script(m, "coop_mods_core")
	load_script(m, "coop_npc_players")
	load_script(m, "coop_trust")
	local core = load_script(m, "coop_quests_core")
	if answer == "srv_world" then
		-- Engine boundary: the world process can read the far NPC only in the player's level view.
		local local_object = e.level.object_by_id
		e.level.object_by_id = function(id)
			if id == 700 and m.view == 9 then return nil end
			return local_object(id)
		end
		core.with_level_of = function(from, f, ...)
			local previous = m.view
			m.view = map_by_peer[from] or map
			local results = { pcall(f, ...) }
			m.view = previous
			if not results[1] then error(results[2], 0) end
			return unpack(results, 2)
		end
		core.with_target = function(_, _, _, f, ...)
			return core.with_level_of(m.guide_peer or 1, f, ...)
		end
		core.is_far_peer = function() return false end
	end
	e.coop_tasks = {
		with_recipient = function(from, fn, ...)
			m.recipient = from
			return fn(...)
		end,
		run_as = function(_, fn, ...) return fn(...) end,
	}
	core.on_game_start()
	load_script(m, "coop_quests_missions").on_game_start()
	fire(m, "actor_on_first_update")
	return m
end

local function reset()
	MACHINES, QUEUE, NOW = {}, {}, 100000
end

local function finish_task(world, task_id)
	local task = world.engine_tasks[task_id]
	if not task then return false end
	task.state = "complete"
	world.env.task_manager.task_callback(task, world.env.task.completed)
	return world.tm.task_info[task_id] == nil
end

local function start_cases(world, client, label)
	for _, entry in ipairs(STARTS) do
		local fn, task_id, spawns = unpack(entry)
		local start = client.env.operacia_monolith[fn]
		local before = #world.spawns
		local ok = pcall(start, client.actor, client.npc)
		pump()
		check(ok and not client.on_init[task_id] and #client.spawns == 0
			and world.on_init[task_id] == 1 and world.recipient == client.self_peer
			and table.concat(world.spawns, ",", before + 1) == spawns, label .. " relays " .. fn .. " with every spawn")
		NOW = NOW + 1500
		pcall(start, client.actor, client.npc)
		pump()
		check(world.on_init[task_id] == 1 and table.concat(world.spawns, ",", before + 1) == spawns,
			label .. " ignores a repeated " .. fn)
		if entry.once then
			local finished = finish_task(world, task_id)
			world.log = {}
			NOW = NOW + 1500
			start(client.actor, client.npc)
			pump()
			check(finished and world.on_init[task_id] == 1 and table.concat(world.spawns, ",", before + 1) == spawns
				and has_log(world, "relay 'operacia_monolith." .. fn .. "' from #" .. client.self_peer .. " refused: not due now"),
				label .. " refuses a late " .. fn .. " after task cleanup")
		end
	end
end

local function guide(m)
	return m.env.coop_mods_core.find_local(m.env.tasks_guide, "guid") or rawget(m.env.tasks_guide, "guid")
end

local function guide_dialog(m)
	return m.env.tasks_guide.prec_1(m.actor, m.npc)
end

for _, name in ipairs(modes.names()) do
	reset()
	if name == "hostplay" then
		local world = setup("host", 0, name, 1, {}, { 0, 1, 2 })
		local client = setup("client", 1, name, 1, {}, { 0, 1, 2 })
		local flat = setup("client", 2, name, 1, {}, { 0, 1, 2 })
		client.env.coop_quests_core.request_host_action("rly", { f = "operacia_monolith.barmen_task1", n = 65535 })
		pump()
		check(has_log(world, "g14_start_npc") and not world.on_init.barmen_task1,
			"co-op checks an out-of-range Monolith NPC through trust before dropping it")
		start_cases(world, client, "co-op")
		world.env.operacia_monolith.barmen_task1(world.actor, world.npc)
		check(world.on_init.barmen_task1 == 1, "playing host shares the Monolith one-shot guard")

		world.candidate, world.candidate_player, client.charged = true, 101, true
		world.env.tasks_guide.prepare_follower()
		tick(world)
		pump()
		check(guide(world).squad_id == 701 and world.searched_map == MAP[1],
			"co-op generates for a client on the loaded map with a flat host PDA")
		check(world.tips == 0 and client.tips == 1 and flat.tips == 0,
			"co-op sends guide news only to the player with a charged PDA")
		check(guide_dialog(flat), "co-op uncharged player can ask about an existing offer")
		check(world.env.AC_ID == 0 and world.env.db.actor:id() == 0, "guide scan restores the playing host's identity")

		reset()
		world = setup("host", 0, name, 1, {}, { 0, 1, 2 })
		client = setup("client", 1, name, 1, {}, { 0, 1, 2 })
		flat = setup("client", 2, name, 1, {}, { 0, 1, 2 })
		world.env.operacia_monolith.barmen_task1(world.actor, world.npc)
		check(world.on_init.barmen_task1 == 1 and world.recipient == 0 and world.spawns[1] == "bar_case",
			"playing host starts Monolith through the same guard")
		local finished = finish_task(world, "barmen_task1")
		client.env.operacia_monolith.barmen_task1(client.actor, client.npc)
		pump()
		check(finished and world.on_init.barmen_task1 == 1 and #world.spawns == 1 and world.tm.task_info.barmen_task1 == nil,
			"client cannot restart a task finished by the playing host")
		for _, m in ipairs({ world, client, flat }) do
			m.env.coop_main.add_level_handler = m.env.coop_main.add_event_handler
			m.env.coop.route = { of = function(_, f)
				return "host", debug.getinfo(f, "S").source:match("([%w_]+)%.script$")
			end }
			local route = load_script(m, "coop_route") -- the tick service the news tick runs on
			load_script(m, "coop_core_world_news").on_game_start()
			route.on_game_start()
		end
		world.candidate, world.candidate_player, world.charged, client.charged = true, 0, true, true
		world.env.tasks_guide.prepare_follower()
		tick(world)
		pump()
		check(count_sent(world, "core.news") == 0 and world.tips == 1 and client.tips == 1 and flat.tips == 0,
			"co-op charged host and client each get one tip through the chained news wrappers")
	elseif name == "srv_world" then
		for _, second_map in ipairs({ 2, 3 }) do
			reset()
			local maps, peers = { [1] = 2, [2] = second_map }, { 1, 2 }
			local label = second_map == 2 and "server same map" or "server two maps"
			local world = setup("host", 0, name, 9, maps, peers)
			local first = setup("client", 1, name, 2, maps, peers)
			local second = setup("client", 2, name, second_map, maps, peers)
			local first_map = setup("client", 0x101, "srv_map", 2, maps, peers)
			local candidate_map = second_map == 2 and first_map or setup("client", 0x102, "srv_map", 3, maps, peers)
			start_cases(world, second, label)
			check(#candidate_map.spawns == 0, label .. " leaves Monolith creation to the world owner")
			second.env.coop_mods_core.to_host("g14_guide_map", { p = 2, l = second_map, n = 700 })
			pump()
			check(has_log(world, "g14_guide_map"), label .. " checks client-supplied map facts through trust")
			candidate_map.candidate, candidate_map.candidate_player = true, 102
			second.charged, world.guide_peer = true, 2
			tick(candidate_map)
			check(count_sent(candidate_map, "mods.g14_guide_map") == 1, label .. " reports a live candidate from its map")
			pump()
			-- A map server's fact about a player who has just left its level (his level change in flight: the stand, build
			-- 57, 1 of 15): dropped, counted, with no "[coop-trust] !" line; a client's packet as above keeps its line
			local function loud_lines()
				local n = 0
				for _, l in ipairs(world.log) do if tostring(l):find("! g14_guide_map", 1, true) then n = n + 1 end end
				return n
			end
			local loud = loud_lines()
			candidate_map.env.coop_mods_core.publish("g14_guide_map", { p = 2, l = 77, n = 700 })
			pump()
			local stale = world.env.coop_trust.status().g14_guide_map_stale
			check(loud_lines() == loud and stale and stale.failed == 1,
				label .. " a map server's stale guide fact is dropped and counted, with no trust line")
			world.env.tasks_guide.prepare_follower()
			tick(world)
			pump()
			check(guide(world).squad_id == 701 and world.searched_map == MAP[second_map],
				label .. " computes an offer from the occupied map's NPCs")
			check(world.tips == 0 and first.tips == 0 and second.tips == 1,
				label .. " delivers news using each player's PDA")
			check(guide_dialog(first), label .. " preserves the dialogue for an uncharged player")
			-- Build 57 stand: an error inside the far scope ("prepare guide: _g.script:2062 ...") left the stock offer
			-- timer stopped (check_timers stops it before the call), so no guide offer came for the rest of the session
			-- and the save. Stock re-arms in 15 game minutes on every failed search; the wrapper does the same on an error.
			local retries = world.retries or 0
			local squad_of = world.env.get_object_squad
			world.env.get_object_squad = function() error("a stock error in the far scope") end
			world.env.tasks_guide.prepare_follower()
			world.env.get_object_squad = squad_of
			check(has_log(world, "prepare guide") and (world.retries or 0) == retries + 1,
				label .. " re-arms the stock offer timer after an error in the far scope")
		end
	elseif name == "srv_map" then
		local m = setup("client", 0x101, name, 2, { [1] = 2 }, { 1 })
		m.candidate, m.candidate_player = true, 101
		m.env.tasks_guide.prepare_follower()
		check(not guide(m).squad_id and m.searched_map == nil and m.retries == nil,
			"map server only supplies guide facts")
	else
		local m = setup("host", 0, name, 1, {}, { 0 })
		m.env.operacia_monolith.barmen_task1(m.actor, m.npc)
		check(m.on_init.barmen_task1 == 1 and m.spawns[1] == "bar_case", "single-player Monolith uses the original call")
		m.candidate, m.candidate_player = true, 0
		m.env.tasks_guide.prepare_follower()
		check(m.retries == 1 and not guide(m).squad_id, "single-player flat PDA retains the original timer retry")
		m.charged = true
		m.env.tasks_guide.prepare_follower()
		check(guide(m).squad_id == 701 and m.tips == 1, "single-player charged PDA retains the original offer and tip")
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then os.exit(1) end
