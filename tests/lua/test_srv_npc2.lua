-- World and map authority over the arena and encounters, plus a map's per-player fight list.
dofile("tests/lua/support/harness_world.lua")
local modes = dofile("tests/lua/support/modes.lua")

do
	reset_world()
	local W = machine("host", 0, { [1] = 500 })
	local E = W.env
	local function load(name) return load_script(W, name) end
	E.coop.is_dedicated = function() return true end
	E.level.name = function() return "fake_start" end
	E.has_alife_info = function() return false end
	E.get_console_cmd = function() return "checkpoint" end
	local prizes = 0
	E.dialogs_bar = { new_arena_give_reward = function() prizes = prizes + 1 end }
	W.set_session(false)
	modes.live(load("coop_mode"), load)
	load("coop_npc_players")
	load("coop_trust")
	load("coop_mods_core")
	local quests = load("coop_quests_core")
	quests.share = nil -- registrations must reach the facade's registry even before the legacy wrapper is available
	local arena = load("coop_arena")
	arena.on_game_start()
	load("coop_encounters").on_game_start()
	load("coop_npc_companions").on_game_start()
	load("coop_srv_companions").on_game_start()

	local shared = quests.shared()
	check(shared.up.arena_ledger ~= nil and shared.down.arena_ledger ~= nil, "the world can load the arena ledger before its share transport starts")
	check(shared.down.encounters ~= nil and shared.down.encounters.get().on == false, "the checkpoint rule waits for the world session")
	check(shared.up.comp_leaders ~= nil and shared.down.comp_leaders ~= nil, "the world keeps companion owners before its share transport starts")
	W.set_session(true)
	check(shared.down.encounters ~= nil and shared.down.encounters.get().on == true, "the running world tells its map servers that encounters use checkpoint rules")
	E.dialogs_bar.new_arena_give_reward(E.db.actor, nil)
	check(prizes == 0 and #sent_named(W, "arena.prize") == 0, "the world actor neither claims a stock prize nor sends a player's request")
end

do
	reset_world()
	local M = machine("client", 0x101, { [1] = 500 })
	local E = M.env
	local function load(name) return load_script(M, name) end
	local map_server, where = true, "l05_bar"
	E.coop.is_map_server = function() return map_server end
	E.coop.levels = { split = function() return true end }
	E.level.name = function() return where end
	local purged = 0
	E.xr_zones = { purge_arena_items = function() purged = purged + 1 end }
	modes.live(load("coop_mode"), load)
	load("coop_npc_players")
	local trust = load("coop_trust")
	trust.reset_for_test({ default = "log" })
	load("coop_mods_core")
	load("coop_quests_core")
	load("coop_arena")
	load("coop_encounters").on_game_start()
	local function tell(from, t)
		for _, handle in ipairs(M.handlers["mods.enc_arena"] or {}) do
			handle(E.coop_main.encode(t), from)
		end
	end
	tell(1, { n = 3, _peer = 0 })
	tell(0, { n = 9 })
	check(purged == 0, "only the transport's world server can roll back a numbered Bar fight")
	where = "l02_garbage"
	tell(0, { n = 3 })
	check(purged == 0, "a world rollback cannot purge a map outside the Bar in log mode")
	where = "l05_bar"
	map_server = false
	tell(0, { n = 3 })
	check(purged == 0, "a world rollback cannot purge the Bar on a server player's machine")
	map_server = true
	tell(0, { n = 3 })
	check(purged == 1, "a valid world rollback clears the Bar arena")
	tell(0, {})
	check(purged == 2, "a world rollback can omit the round")
	local audit = trust.status().enc_arena
	check(audit and audit.checked == 6 and audit.failed == 4 and audit.refused == 0,
		"the sender, round, map and recipient refusals all reach the trust audit in log mode")

	local arena = load("coop_arena")
	arena.on_game_start()
	local key = string.format("%064x", 500)
	M.add(make_obj(500, 0, 0, 0, { _section = "coop_player_avatar",
		_spawn_ini = make_ini({ coop = { { "key", key } } }) }))
	local row = { items = {}, kit = {} }
	arena._state().ledger["500:" .. key] = row
	local function tell_kit(i, from, peer)
		for _, handle in ipairs(M.handlers["arena.kit"]) do
			handle(E.coop_main.encode({ i = i, _peer = peer }), from)
		end
	end
	tell_kit("701,65534", 0, 1)
	check(table.concat(row.kit, ",") == "701,65534", "the Bar accepts a kit relayed by the world for the player")
	tell_kit("703", 1, 1)
	check(table.concat(row.kit, ",") == "701,65534", "a player cannot impersonate the world's relay to change the kit")
	tell_kit("702,65535", 0, 1)
	check(table.concat(row.kit, ",") == "701,65534", "the Bar drops a relayed kit atomically when it includes the reserved ID")
	local kit_audit = trust.status()["arena.kit"]
	check(kit_audit and kit_audit.checked == 2 and kit_audit.failed == 1 and kit_audit.refused == 0,
		"the Bar audits both relayed kits in log mode")
end

do
	local M, C = world_pair()
	local api = M.env.coop
	api.is_map_server = function() return true end
	api.self_id = function() return 0x101 end
	C.env.coop.levels = { split = function() return true end }
	local present = true
	local players = api.players
	api.players = function() return present and players() or {} end
	for _, machine in ipairs({ M, C }) do
		local function load(name) return load_script(machine, name) end
		modes.live(load("coop_mode"), load)
		load("coop_trust").reset_for_test({ default = "log" })
		machine.env.xr_combat_ignore = { fighting_with_actor_npcs = {} }
		load("coop_world_fight").on_game_start()
	end
	M.add(make_obj(500, 0, 0, 0))
	M.add(make_obj(700, 10, 0, 0))
	M.env.coop_npc_combat = { _state = function() return { fighting = { [700] = { [500] = true } } } end }
	api.sync.set("session", "world.fight.1", { 701 })
	local latest_target
	local broadcast = api.sync.broadcast
	api.sync.broadcast = function(name, args, opts)
		latest_target = opts.to
		return broadcast(name, args, opts)
	end
	local function tick()
		NOW = NOW + 1100
		M.fire("actor_on_update")
		world_pump()
		C.fire("actor_on_update")
	end
	local fights = C.env.xr_combat_ignore.fighting_with_actor_npcs
	tick()
	check(latest_target == 1 and M.sync_sets == 1, "the map server addresses the player through sync.broadcast")
	check(fights[700] == true and fights[701] == nil, "the server player reads the map's fight list")
	C.effects["world.fight"]({ 701 }, 2)
	tick()
	check(fights[700] == true and fights[701] == nil, "a player cannot supply another player's fight list")
	local oversized = {}
	for i = 1, 1366 do oversized[i] = i end
	local invalid_lists = {
		{ { 701, 65535 }, "reserved ID" }, { { 701, 0 }, "zero ID" }, { { 701, 65536 }, "out-of-range ID" },
		{ { 701, -1 }, "negative ID" }, { { 701, 1.5 }, "fractional ID" }, { { 701, "702" }, "numeric string" },
		{ { 701, math.huge }, "non-finite number" }, { { 701, 0 / 0 }, "NaN" },
		{ { 701, true }, "boolean ID" }, { { 701, {} }, "nested table" }, { { [2] = 701 }, "sparse list" },
		{ { 701, extra = 702 }, "named key" }, { { [1.5] = 701 }, "fractional index" },
		{ "701", "non-table payload" }, { nil, "missing payload" }, { oversized, "oversized list" },
	}
	for _, invalid in ipairs(invalid_lists) do
		C.effects["world.fight"]({ 700 }, 0)
		tick()
		C.effects["world.fight"](invalid[1], 0)
		tick()
		check(next(fights) == 700 and fights[700] == true and next(fights, 700) == nil,
			"the server player keeps the old list after " .. invalid[2])
	end
	local audit = C.env.coop_trust.status()["world.fight"]
	check(audit and audit.checked == 2 * #invalid_lists + 2 and audit.failed == #invalid_lists + 1 and audit.refused == 0,
		"the server player audits the wrong sender and malformed fight lists in log mode")
	C.effects["world.fight"]({ 1, 65534 }, 0)
	tick()
	check(fights[1] and fights[65534] and not fights[700], "the server player accepts both valid ID endpoints")
	present = false
	tick()
	present = true
	tick()
	check(M.casts == 2, "a player who returns hears even an unchanged fight list")
	M.objects[700]._alive = false
	tick()
	check(next(fights) == nil, "the map server clears a fight that ended")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
