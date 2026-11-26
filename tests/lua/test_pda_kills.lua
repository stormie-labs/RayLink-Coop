-- PDA info stays local and one observed death gives one personal kill.
local modes = dofile("tests/lua/support/modes.lua")
local EVENT = "mods.pda_stat"
local PROXY, PEER, BRIDGE = 500, 1, 0x101
local STALKER_KEYS = { "killed_stalkers_f", "killed_stalkers_e", "killed_stalkers_n" }
local passed, failed = 0, 0

local function check(ok, name)
	if ok then passed = passed + 1 else
		failed = failed + 1
		print("  FAIL " .. name)
	end
end

local function load_in(path, env)
	return setfenv(assert(loadfile(path)), env)()
end

local function new_machine(role, set)
	local e = setmetatable({}, { __index = _G })
	e._G = e
	local m = { env = e, sent = {}, own = {}, npc = {}, legacy = {}, observed = 0 }
	local active = role ~= "single"
	local host = role == "host" or role == "world"
	local mirror = role == "player"
	local map = role == "map"
	e.printf = function() end
	e.time_global = function() return 1000 end
	e.coop = {
		is_active = function() return active end,
		is_host = function() return host end,
		is_client = function() return mirror or map end,
		is_map_server = function() return map end,
		is_dedicated = function() return role == "world" end,
		self_id = function() return mirror and PEER or (map and BRIDGE or 0) end,
		players = function() return {} end,
		send_event = function(name, payload, target)
			m.sent[#m.sent + 1] = { name = name, payload = payload, target = target }
			return true
		end,
	}
	local function obj(id) return { id = function() return id end } end
	m.actor, m.proxy, m.stalker = obj(0), obj(PROXY), obj(700)
	e.db = { actor = m.actor }
	e.level = { object_by_id = function() return m.proxy end }
	e.coop_npc_players = {
		active = e.coop.is_active,
		is_host = function() return host or map end,
		self_peer = e.coop.self_id,
		peer_of = function(id)
			if type(id) == "table" then id = id:id() end
			if (host or map) and id == PROXY then return PEER end
		end,
		with_identity = function(_, fn, ...) return fn(...) end,
	}
	e.coop_tasks = {
		character_of = function() return PROXY end,
		with_character = function(_, _, _, _, key) m.legacy[key] = (m.legacy[key] or 0) + 1 end,
	}
	e.game_statistics = {
		increment_statistic = function(key) m.own[key] = (m.own[key] or 0) + 1 end,
		increment_npc_statistic = function(npc, key, rank, reputation)
			m.npc[key] = { npc, rank, reputation }
			return "stock"
		end,
	}
	-- The stock binder branches on the remapped killer ID. Guard only its counter and keep the death callback.
	e.bind_monster = { generic_object_binder = { death_callback = function(_, _, killer)
		if killer:id() == 0 then
			e.game_statistics.increment_statistic("killed_monsters")
		else
			e.game_statistics.increment_npc_statistic(killer, "killed_monsters")
		end
		m.observed = m.observed + 1
	end } }
	local function load(name)
		local module = setmetatable({}, { __index = e })
		e[name] = module
		local path = "gamedata/scripts/" .. name .. ".script"
		local f = io.open(path, "rb")
		if not f then return end
		f:close()
		load_in(path, module)
		return module
	end
	load("coop_util") -- the engine loads it on the first use of its name
	load("coop_route") -- coop_main takes the router when it loads
	load("coop_world_events") -- and asks the world-only event list on every event
	load("coop_main")
	load("coop_mode")
	local answers = mirror and {
		actor_is_player = function() return true end,
		decides_world = function() return false end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
		decider = function() return "other" end,
	} or nil
	modes.install(e.coop_mode, set, answers)
	load("coop_mods_core")
	load("coop_credit")
	load("coop_reputation")
	local pda = load("coop_pda_kills")
	if pda then
		pda.on_game_start()
		pda.on_game_start()
	end
	e.coop_reputation.on_game_start()
	m.death = function(killer) e.bind_monster.generic_object_binder.death_callback(nil, nil, killer) end
	m.stat = e.game_statistics.increment_npc_statistic
	m.receive = function(t, from) e.coop_main.on_event(EVENT, e.coop_main.encode(t), from) end
	return m, load
end

local function parity_info(m, load)
	local e, written = m.env
	e.alife = function()
		return { iterate_info = function(_, _, emit)
			for _, name in ipairs({ "ui_pda", "ui_pda_hide", "ui_pda_hide_quest" }) do emit(0, name) end
		end }
	end
	e.getFS = function() return { update_path = function(_, _, path) return path end } end
	e.io = { open = function()
		return { write = function(_, text) written = text end, close = function() end }
	end }
	load("coop_util")
	local probe = load("coop_parity")
	probe.dump("pda_close")
	check(written and not written:find("infos\tui_pda_hide\t", 1, true), "PDA close stays out of the parity dump")
	check(written and written:find("infos\tui_pda_hide_quest\t1", 1, true), "similarly named story info remains in the dump")
end

local function personal_kills(set, authority)
	local decider, load = new_machine(authority, set)
	local player = new_machine("player", set)
	decider.env.coop_trust = { pass = function(_, ok) return ok end }
	local progress = load("coop_progress_check")
	parity_info(decider, load)
	for _, key in ipairs(STALKER_KEYS) do
		-- Stock gives one total and one faction bucket per stalker death.
		decider.stat(decider.proxy, "killed_stalkers")
		decider.stat(decider.proxy, key)
		progress.note(PROXY, "kill", 1, { kind = "stalker" })
		decider.death(decider.proxy)
		progress.note(PROXY, "kill", 1, { kind = "monster" })
		player.death(player.actor)
	end
	check(player.own.killed_monsters == nil and player.observed == 3, "mirrored deaths run without PDA credit")
	check(#decider.sent == 9, "decider emits one credit per counter increment")
	check(next(decider.own) == nil and next(decider.npc) == nil and next(decider.legacy) == nil,
		"remote kills bypass the decider's actor, NPC and legacy reward counters")
	for _, msg in ipairs(decider.sent) do
		local payload = decider.env.coop_main.decode(msg.payload)
		check(msg.name == EVENT and msg.target == PEER, "credit targets only the responsible player")
		-- The engine forwards a map server's message as peer 0 and preserves ordinary player senders.
		player.receive(payload, 0)
	end
	check(player.own.killed_stalkers == 3, "three observed stalker deaths give three total kills")
	for _, key in ipairs(STALKER_KEYS) do
		check(player.own[key] == 1, key .. " receives one kill")
	end
	check(player.own.killed_monsters == decider.observed, "reported mutant kills equal the decider's observed deaths")
	local _, reasons = progress.check(PROXY, PEER, "game_statistics", {}, { actor_statistics = player.own })
	check(#reasons == 0, "F5 accepts the PDA counters against the observed deaths")
	player.receive({ k = "killed_monsters", from = 0 }, 2)
	player.receive({ k = "tasks_completed" }, 0)
	player.receive({ k = 42 }, 0)
	player.receive({}, 0)
	check(player.own.killed_monsters == 3 and player.own.tasks_completed == nil and player.own[42] == nil,
		"forged sender and invalid keys cannot increase the counters")
	check(decider.stat(decider.stalker, "killed_monsters", 8, -4) == "stock"
		and decider.npc.killed_monsters[1] == decider.stalker
		and decider.npc.killed_monsters[2] == 8 and decider.npc.killed_monsters[3] == -4,
		"ordinary NPC statistics keep the stock call and return value")
	decider.stat(decider.proxy, "helicopters_downed")
	check(decider.legacy.helicopters_downed == 1 and #decider.sent == 9, "other player rewards keep their existing route")
	if authority == "host" then
		decider.death(decider.actor)
		check(decider.own.killed_monsters == 1 and #decider.sent == 9, "host player's kill keeps the stock counter")
	end
end

for _, set in ipairs(modes.names()) do
	if set == "hostplay" then
		personal_kills(set, "host")
	elseif set == "srv_map" then
		personal_kills(set, "map")
	elseif set == "srv_world" then
		local world = new_machine("world", set)
		world.stat(world.proxy, "killed_stalkers")
		world.receive({ k = "killed_stalkers" }, 0)
		check(#world.sent == 0 and next(world.own) == nil and next(world.legacy) == nil and next(world.npc) == nil,
			"world without the player's map does not award or consume a kill")
	else
		local sp = new_machine("single", set)
		sp.death(sp.actor)
		sp.death(sp.stalker)
		check(sp.own.killed_monsters == 1 and sp.npc.killed_monsters[1] == sp.stalker and #sp.sent == 0,
			"single-player deaths keep both stock paths")
	end
end
print(string.format("%d passed, %d failed", passed, failed))
