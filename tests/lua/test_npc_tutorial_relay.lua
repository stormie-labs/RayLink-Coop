-- R38: a shared restrictor's npc.fx may only change the recipient's own ready HUD.
local modes = dofile("tests/lua/support/modes.lua")
dofile("tests/lua/support/harness_npc.lua")

local PROMPT = "tutorial_sleep"
local SOURCE, OTHER_SOURCE = 120, 121

local function install(M, set, mirror)
	local E = M.env
	E.coop_mode = load_script(M, "coop_mode")
	modes.install(E.coop_mode, set, mirror and {
		actor_is_player = function() return true end,
		decides_world = function() return false end,
		leads_here = function() return false end,
		is_player_mirror = function() return true end,
	} or nil)
	M.hud, M.precache, M.live, M.serial = {}, 0, true, 0
	E.coop.is_live = function() return M.live end
	E.ActorMenu = { get_maingame = function() return M.hud end }
	E.device = function() return { precache_frame = M.precache } end
	E.game.player_hud_ready = function() return M.hud ~= nil and M.precache == 0 and not M.load_held end
	E.game.active_tutorial_name = function() return M.name or "invalid" end
	E.game.active_tutorial_id = function() return M.active or 0 end
	E.game.has_active_tutorial = function() return M.active ~= nil end
	E.game.start_tutorial = function(name)
		M.serial = M.serial + 1
		M.active, M.name = M.serial, name
	end
	-- A handle whose window the HUD rebuild deleted still answers (luabind keeps a raw pointer): nothing in Lua can tell.
	local function monitor_window()
		return { parent = M.hud, IsShown = function(self) return self.parent == M.hud end }
	end
	E.modxml_tutorial_hooks = {
		UIStaticTutorials = monitor_window(),
		actor_on_first_update = function()
			E.modxml_tutorial_hooks.UIStaticTutorials = monitor_window()
		end,
	}
	E.xr_effects = {
		run_tutorial = function(_, _, p)
			M.starts = (M.starts or 0) + 1
			E.game.start_tutorial(p[1])
		end,
		stop_tutorial = function()
			M.stops = (M.stops or 0) + 1
			if M.active and E.modxml_tutorial_hooks.UIStaticTutorials.parent ~= M.hud then
				M.stale_stop = true -- the DXML stop functor would use the deleted text window
			end
			M.active, M.name = nil, nil
		end,
		disable_ui = function() M.locked = true end,
		enable_ui = function() M.unlocks = (M.unlocks or 0) + 1 end,
	}
	E.xr_logic = {
		try_switch_to_another_section = function() return false end,
		pick_section_from_condlist = function(actor, obj, condlist)
			local fx = condlist[1]
			E.xr_effects[fx.name](actor, obj, fx.args)
		end,
		parse_func_params = function(s) return { s } end,
	}
	E.coop_npc_players = load_script(M, "coop_npc_players")
	E.coop_npc_logic = load_script(M, "coop_npc_logic")
	E.coop_npc_logic.on_game_start()
	-- the HUD rebuild of the monitor window moved to the registry of the HUD's life cycle (R38)
	E.coop_hud_lifecycle = load_script(M, "coop_hud_lifecycle")
	E.coop_hud_lifecycle.on_game_start()
	E.coop_npc_players.host_on = function() return not mirror end
end

local function source(M, id, audience)
	local obj = M.add(make_obj(id, 20, 0, 0, { _radius = 2 }))
	M.env.db.storage[id] = { stype = 4, coop_local = false, coop_aud = audience, coop_scene = true }
	return obj
end

local function run(set)
	reset_world()
	local server = set ~= "hostplay"
	local authority = machine("host", server and 0x101 or 0, { [1] = 501, [2] = 502 })
	local client = machine("client", 1, { [1] = 0 })
	local other = machine("client", 2, { [2] = 0 })
	install(authority, server and "srv_map" or set, false)
	install(client, set, true)
	install(other, set, true)
	local A, C = authority.env, client.env
	authority.add(make_obj(501, 20, 0, 0))
	local zone = source(authority, SOURCE, { [501] = true })
	local other_zone = source(authority, OTHER_SOURCE, { [501] = true })
	source(client, SOURCE)
	source(client, OTHER_SOURCE)

	local function deliver(name, obj, args)
		local next_packet = #QUEUE + 1
		A.xr_logic.pick_section_from_condlist(A.db.actor, obj or zone, { { name = name, args = args } })
		local packet = table.remove(QUEUE, next_packet)
		assert(packet and packet.name == "npc.fx" and packet.target == 1)
		-- A map server's packet arrives on the player connection from the world server, peer 0.
		local sender = server and 0 or packet.from
		local recipient = assert(MACHINES[packet.target])
		for _, handle in ipairs(recipient.handlers[packet.name]) do handle(packet.payload, sender) end
	end

	local function start() deliver("run_tutorial", zone, { PROMPT }) end
	local function stop(obj) deliver("stop_tutorial", obj) end

	C.game.start_tutorial("local_intro")
	client.live, client.precache = false, 3
	client.hud = {} -- Lua still holds the old monitor while the level HUD changes
	stop()
	check(client.name == "local_intro" and not client.stops and not client.stale_stop, set .. ": joining client ignores orphan stop")
	start()
	check(not client.starts, set .. ": joining client skips relayed start")
	deliver("disable_ui")
	check(not client.locked, set .. ": joining client skips relayed UI lock")

	client.live, client.precache = true, 0
	client.load_held = true
	start()
	check(not client.starts, set .. ": live transport still waits for the held loading screen")
	client.load_held = false
	client.hud = nil
	start()
	check(not client.starts, set .. ": live session still needs a HUD")
	client.hud = {}
	client.fire("on_screen_resolution_changed")
	check(C.modxml_tutorial_hooks.UIStaticTutorials.parent == client.hud, set .. ": HUD rebuild replaces the monitor window")
	stop()
	check(client.name == "local_intro" and not client.stops, set .. ": ready client keeps a local tutorial of another source")
	client.active, client.name = nil, nil
	start()
	check(client.starts == 1 and client.name == PROMPT and not other.starts, set .. ": only the addressed player starts")
	stop(other_zone)
	check(client.name == PROMPT and not client.stops, set .. ": another source cannot stop the prompt")
	C.game.start_tutorial(PROMPT)
	stop()
	check(client.name == PROMPT and not client.stops, set .. ": a local restart with the same name has a different identity")
	client.active, client.name = nil, nil
	start()
	client.hud = {} -- CHUDManager::OnScreenResolutionChanged rebuilds the HUD and then sends the callback
	client.fire("on_screen_resolution_changed")
	stop()
	check(client.stops == 1 and not client.active and not client.stale_stop, set .. ": a stop after a HUD rebuild uses the rebuilt monitor")
	start()
	client.precache = 2
	stop()
	check(client.stops == 1 and client.active, set .. ": an owned stop waits through precache")
	client.precache = 0
	client.fire("actor_on_update")
	check(client.stops == 2 and not client.active, set .. ": the owned stop runs once when the HUD returns")
	start()
	client.precache = 2
	stop()
	C.game.start_tutorial(PROMPT)
	client.precache = 0
	NOW = NOW + 250
	client.fire("actor_on_update")
	check(client.stops == 2 and client.active, set .. ": deferred stop cannot close a replacement tutorial")
	check(not authority.stops and not authority.starts, set .. ": remote audience does not touch the authority's HUD")
	-- An unlock is never dropped: the lock it ends may have come while the HUD was ready (vid_restart precache, R38 review).
	client.precache = 2
	deliver("enable_ui")
	check(client.unlocks == 1, set .. ": a relayed unlock runs while the HUD precaches")
	client.precache = 0
	-- The same source starts again after the stop it deferred (out of the zone and back): the start is its last word.
	client.active, client.name = nil, nil
	start()
	local stops_before = client.stops
	client.precache = 2
	stop()
	client.precache = 0
	start()
	NOW = NOW + 250
	client.fire("actor_on_update")
	check(client.active and client.name == PROMPT and client.stops == stops_before,
		set .. ": a start of the same source after its deferred stop keeps the prompt")
	client.precache = 2
	stop()
	start()
	client.precache = 0
	NOW = NOW + 250
	client.fire("actor_on_update")
	check(client.active and client.stops == stops_before,
		set .. ": a start during the HUD wait cancels its source's deferred stop")
	stop()
	check(client.stops == stops_before + 1 and not client.active, set .. ": the next stop of that source still closes it")
	if server then
		A.xr_effects.run_tutorial(A.db.actor, nil, { PROMPT })
		A.xr_effects.disable_ui(A.db.actor)
		check(not authority.starts and not authority.locked, set .. ": a map server has a ghost, even for a scheme's own call")
		A.xr_effects.enable_ui(A.db.actor, nil, {})
		check(not authority.unlocks, set .. ": a map server never runs an unlock, \"always\" included")
		local world = machine("host", 0, {})
		install(world, "srv_world", false)
		world.env.xr_effects.stop_tutorial()
		check(not world.stops, set .. ": the world server never stops a local tutorial")
	else
		A.db.storage[SOURCE].coop_aud = { [0] = true }
		A.xr_logic.pick_section_from_condlist(A.db.actor, zone, { { name = "run_tutorial", args = { PROMPT } } })
		A.xr_logic.pick_section_from_condlist(A.db.actor, zone, { { name = "stop_tutorial" } })
		check(authority.starts == 1 and authority.stops == 1, "hostplay: the host plays its own paired tutorial")
		local before = authority.unlocks or 0
		authority.precache = 2
		A.xr_effects.enable_ui(A.db.actor, nil, {})
		check((authority.unlocks or 0) == before + 1, "hostplay: the host's own unlock runs while its HUD precaches")
		authority.precache = 0
	end
end

for _, set in ipairs(modes.names()) do
	if set == "none" then
		reset_world()
		local single = machine("single", 0, {})
		install(single, set, false)
		single.env.xr_effects.run_tutorial(nil, nil, { PROMPT })
		single.env.xr_effects.stop_tutorial()
		check(single.starts == 1 and single.stops == 1, "single player's stock tutorial start and stop")
		single.precache = 2
		single.env.xr_effects.enable_ui(nil, nil, {})
		check(single.unlocks == 1, "single player's stock unlock")
		single.precache = 0
		single.hud = {}
		single.fire("on_screen_resolution_changed")
		check(single.env.modxml_tutorial_hooks.UIStaticTutorials.parent == single.hud,
			"single player: a HUD rebuild replaces GAMMA's prompt window (its old one went with the old HUD)")
	else
		run(set)
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS > 0 and 1 or 0)
