-- Co-op debug, package 2 (docs\DEBUG_DESIGN.md B.4-B.7, C.2): the world server's Lua. Requests of the five coop.dbg.* handlers,
-- the checks in the design's order, where a command runs (the world server, the authority of the player's level, a map server
-- by coop.dbg.run), the announcement to everybody, the server console coop_dbg, and P.player of coop_npc_players.
-- The engine side (coop.debug, coop.sync) is stubbed by the contract of the design (package 1).
-- Run: tools\test_lua.cmd debug_server
dofile("tests/lua/support/harness_npc.lua")

local MK = 0x101
local LEVEL_HOST, LEVEL_MK = 1, 2

local function spy(M, key)
	M[key] = {}
	return function(...)
		local list = M[key]
		list[#list + 1] = { ... }
		return true
	end
end

local ITEMS = {
	wpn_ak74 = { { "class", "WP_AK74" } },
	medkit = { { "class", "II_MEDKI" } },
	sim_squad_bandit = { { "class", "ON_OFF_S" } },
	zone_mosquito_bald = { { "class", "ZS_MBALD" } },
}

-- The engine stand-ins every process of a session has, by the contract of the design (package 1) and the engine as it is.
local function engine(M, o)
	local E = M.env
	E.vector = vector
	E.ini_sys = make_ini(ITEMS)
	E.IsStalker = function(obj) return obj and obj._stalker == true end
	E.IsMonster = function(obj) return obj and obj._monster == true end
	E.coop.is_world_server = function() return o.ws == true end
	E.coop.is_map_server = function() return o.mk == true end
	E.coop.is_dedicated = function() return o.dedicated == true end
	E.coop.is_player = function() return o.player ~= false end
	M.life = {}
	E.coop.life_of = function(id) return M.life[id] or "alive" end
	M.dbg = { on = o.debug ~= false, flags = {}, said = {} }
	E.coop.debug = {
		state = function() return { on = M.dbg.on, source = M.dbg.on and 2 or 0, serial = 1 } end,
		is_operator = function() return o.ws == true end,
		flags = function(peer) return M.dbg.flags[peer] or 0 end,
		set_flags = function(peer, t)
			M.dbg.set = M.dbg.set or {}
			M.dbg.set[#M.dbg.set + 1] = { peer = peer, t = t }
			return true
		end,
		say = function(line) M.dbg.said[#M.dbg.said + 1] = line end,
	}
	M.sync_handlers, M.sync_limits = {}, {}
	E.coop.sync = {
		handler = function(name, f)
			if o.ws ~= true and not o.single then return false, "host only" end
			M.sync_handlers[name] = f
			return true
		end,
		limit = function(name, burst, per_sec)
			M.sync_limits[name] = { burst, per_sec }
			return true
		end,
	}
	M.verts = {}
	E.level.vertex_position = function(lv) return M.verts[lv] or vector() end
	E.level.change_game_time = spy(M, "time_jumps")
	E.level.set_weather = spy(M, "weathers")
	E.level.set_time_factor = spy(M, "factors")
	E.level.get_time_hours = function() return 10 end
	E.level.get_time_minutes = function() return 0 end
	M.forced = 0
	E.level_weathers = { get_weather_manager = function() return { forced_weather_change = function() M.forced = M.forced + 1 end } end }
	M.next_id = 9000
	M.created = {}
	E.alife_create_item = function(sec, t, props)
		M.next_id = M.next_id + 1
		M.created[#M.created + 1] = { sec = sec, t = t, id = M.next_id }
		return { id = M.next_id }
	end
	E.alife_create = function(sec, pos, lv, gv)
		M.next_id = M.next_id + 1
		M.created[#M.created + 1] = { sec = sec, pos = pos, lv = lv, gv = gv, id = M.next_id, object = true }
		return { id = M.next_id, squad_members = function() return function() return nil end end, create_npc = function() end }
	end
	E.alife_object = function(id) return M.objects[id] and { id = id, position = M.objects[id]._pos } or nil end
	E.alife_release_id = spy(M, "released")
	M.infos = {}
	E.has_alife_info = function(i) return M.infos[i] == true end
	E.give_info = function(i) M.infos[i] = true end
	E.disable_info = function(i) M.infos[i] = nil end
	E.coop.money_grant = spy(M, "grants")
	E.coop.money_of = function() return 100 end
	E.coop_mods_core = { teleport = spy(M, "teleports") }
	M.orders = {}
	E.coop_quests_far = {
		level_of_id = function(id) return (M.obj_level or {})[id] or LEVEL_HOST end,
		order = function(id, verb, a, b, c)
			M.orders[#M.orders + 1] = { id = id, verb = verb, a = a, b = b, c = c }
			return true
		end,
	}
	E.coop.levels = {
		split = function() return o.split == true end,
		my_level = function() return o.my_level or LEVEL_HOST end,
		level_of_player = function(peer) return (o.levels or {})[peer] or LEVEL_HOST end,
		led_by_host_process = function(level) return level == LEVEL_HOST end,
		bridge_of_player = function(peer)
			local l = (o.levels or {})[peer] or LEVEL_HOST
			return (o.split and l == LEVEL_MK and o.ws) and MK or nil
		end,
		map_servers = function() return { { bridge = MK, level = LEVEL_MK } } end,
		players_on = function() return 1 end,
	}
end

-- The world server: the host's process, the host player peer 0 (character 0), a client peer 3 (proxy 503 here).
local function world(o)
	o = o or {}
	reset_world()
	local avatars = o.dedicated and { [3] = 503 } or { [0] = 0, [3] = 503 }
	local H = machine("host", 0, avatars)
	o.ws = true
	o.player = not o.dedicated
	engine(H, o)
	H.add(make_obj(503, 10, 0, 0, { _stalker = true }))
	H.add(make_obj(700, 20, 0, 0, { _stalker = true, _name = "bandit_1" }))
	load_script(H, "coop_npc_players")
	load_script(H, "coop_debug_cmds")
	local S = load_script(H, "coop_debug_server")
	S.on_game_start()
	return H, S
end

local function ask(H, name, peer, args)
	local f = H.sync_handlers[name]
	if not f then return nil, "no handler" end
	return f(peer, args)
end

local function sent(M, name)
	local list = {}
	for _, s in ipairs(M.sent) do
		if s.name == name then list[#list + 1] = { target = s.target, t = M.env.coop_main.decode(s.payload) } end
	end
	return list
end

print("== the five handlers and their limits (B.5)")
do
	local H = world()
	local LIMITS = {
		["coop.dbg.view"] = { 30, 10 }, ["coop.dbg.world"] = { 5, 0.5 }, ["coop.dbg.self"] = { 10, 2 },
		["coop.dbg.spawn"] = { 10, 2 }, ["coop.dbg.target"] = { 10, 2 },
	}
	for name, l in pairs(LIMITS) do
		check(type(H.sync_handlers[name]) == "function", name .. " is a handler on the world server")
		local got = H.sync_limits[name]
		check(got ~= nil and got[1] == l[1] and got[2] == l[2], name .. " limit " .. l[1] .. " / " .. l[2])
	end
	local n = 0
	for _ in pairs(H.sync_handlers) do n = n + 1 end
	check(n == 5, "five handlers, no more (they share 256 with the mods)")

	reset_world()
	local C = machine("client", 1, { [0] = 500, [1] = 0 })
	engine(C, {})
	load_script(C, "coop_npc_players")
	load_script(C, "coop_debug_cmds")
	load_script(C, "coop_debug_server").on_game_start()
	local any = false
	for _ in pairs(C.sync_handlers) do any = true end
	check(not any, "a client registers no handler")
end

print("== debug off: only view passes (B.5, the engine gate's twin)")
do
	local H = world({ debug = false })
	local cases = {
		{ "coop.dbg.world", { v = 1, cmd = "time_add", h = 6 } },
		{ "coop.dbg.self", { v = 1, cmd = "money", a = 100 } },
		{ "coop.dbg.spawn", { v = 1, cmd = "spawn_item", sec = "wpn_ak74" } },
		{ "coop.dbg.target", { v = 1, cmd = "kill", t = 700 } },
	}
	for _, c in ipairs(cases) do
		local ok, why = ask(H, c[1], 3, c[2])
		check(ok == false and why == "debug_off", c[1] .. " " .. c[2].cmd .. ": debug_off")
	end
	check(#H.time_jumps == 0 and #H.created == 0 and #H.grants == 0, "nothing changed")
	local ok, r = ask(H, "coop.dbg.view", 3, { v = 1, cmd = "obj_info", t = 700 })
	check(ok == true and type(r) == "table" and r.section ~= nil, "view obj_info passes while off")
end

print("== the order of the checks")
do
	local H = world()
	local ok, why = ask(H, "coop.dbg.world", 3, { cmd = "time_add", h = 6 })
	check(ok == false and why == "old_client", "no v: old_client")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 2, cmd = "time_add", h = 6 })
	check(ok == false and why == "old_client", "v = 2: old_client")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "no_such" })
	check(ok == false and why == "unknown_cmd", "an unknown command")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "money", a = 100 })
	check(ok == false and why == "unknown_cmd", "a self command on the world handler: unknown_cmd")
	ok, why = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "lua", code = "x = 1" })
	check(ok == false and why == "unknown_cmd", "lua from a player: unknown_cmd (operator only)")
	ok, why = ask(H, "coop.dbg.self", 5, { v = 1, cmd = "money", a = 100 })
	check(ok == false and why == "no_player", "peer 5 is no player: no_player")
	ok, why = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = "lots" })
	check(ok == false and why == "bad_args", "money a = 'lots': bad_args")
end

print("== items to oneself: the parent is the requester's character (C.2)")
do
	local H = world()
	local ok, r = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == true and type(r) == "table" and type(r.msg) == "string", "peer 3: ok with a message")
	local c = H.created[1]
	check(c and c.sec == "wpn_ak74" and type(c.t) == "table" and c.t[4] == 503, "peer 3: the parent is his proxy 503")
	check(c and c.t[4] ~= 0, "peer 3: never the host's actor")
	check(c and c.t[1].x == 10 and c.t[2] == 7 and c.t[3] == 8, "the stock {pos, lvid, gvid, id} of his character")
	ok = ask(H, "coop.dbg.spawn", 0, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	c = H.created[2]
	check(ok == true and c and c.t[4] == 0, "peer 0 (the host player): his character 0")
	ok = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "medkit", n = 5, at = "inv" })
	check(ok == true and #H.created == 7, "n = 5: five items")
	local says = sent(H, "coop.dbg.say")
	check(#says == 3 and says[1].target == -1, "every spawn is announced to everybody")
	check(says[1] and says[1].t.nick == "p3" and says[1].t.cmd == "spawn_item", "the line names who and what")
	check(H.dbg.said[1] ~= nil, "and goes to the server console")
end

print("== a point by the stock formula, checked by the authority (B.5 step 7)")
do
	local H = world()
	H.verts[77] = vec(40, 0, 0)
	local ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 40.5, y = 0, z = 0, lv = 77 })
	local c = H.created[1]
	check(ok == true and c and c.t[4] == nil and c.t[2] == 77 and c.t[3] == 8, "a good point: on the ground, lv of the client, gvid of the character")
	H.verts[78] = vec(400, 0, 0)
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 400, y = 0, z = 0, lv = 78 })
	check(ok == false and why == "too_far", "390 m from him: too_far")
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 60, y = 0, z = 0, lv = 77 })
	check(ok == false and why == "bad_vertex", "20 m from its vertex: bad_vertex")
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "point", x = 30, y = 0, z = 0, lv = 99 })
	check(ok == false and why == "bad_vertex", "no such vertex: bad_vertex")
	check(#H.created == 1, "nothing made for the refused points")
	H.life[503] = "wounded"
	ok, why = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == false and why == "not_standing", "a player who is down: not_standing")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = 100 })
	check(ok == true, "money still works for him")
end

print("== another level: coop.dbg.run to its map server (B.6, B.10)")
do
	local H = world({ split = true, levels = { [3] = LEVEL_MK } })
	local ok, r = ask(H, "coop.dbg.spawn", 3, { v = 1, cmd = "spawn_item", sec = "wpn_ak74", at = "inv" })
	check(ok == true and r == "forwarded", "the answer is forwarded")
	check(#H.created == 0, "the world server made nothing itself")
	local runs = sent(H, "coop.dbg.run")
	check(#runs == 1 and runs[1].target == MK, "one coop.dbg.run to the bridge of his level")
	check(runs[1] and runs[1].t._peer == 3 and type(runs[1].t._rid) == "number" and runs[1].t._c == "spawn_item", "with _peer, _rid, the command")
	check(runs[1] and runs[1].t.sec == "wpn_ak74" and runs[1].t.at == "inv", "and its checked arguments")

	-- the map server of that level: player 3's character is 900 there
	local K = machine("client", MK, { [3] = 900 })
	engine(K, { mk = true, split = true, my_level = LEVEL_MK, levels = { [3] = LEVEL_MK } })
	K.add(make_obj(900, 5, 0, 5, { _stalker = true }))
	load_script(K, "coop_npc_players")
	load_script(K, "coop_debug_cmds")
	load_script(K, "coop_debug_server").on_game_start()
	pump()
	local c = K.created[1]
	check(c and c.sec == "wpn_ak74" and c.t[4] == 900, "the map server makes it, the parent is his character there")
	local notes = sent(H, "coop.dbg.note")
	check(#notes == 1 and notes[1].target == 3 and notes[1].t.ok == true, "the world server tells him how it ended (coop.dbg.note)")
	check(#sent(H, "coop.dbg.say") == 1, "and announces it to everybody")

	-- a coop.dbg.run that does not come from the world server is not taken
	QUEUE[#QUEUE + 1] = { from = 3, target = MK, name = "coop.dbg.run",
		payload = H.env.coop_main.encode({ _c = "spawn_item", _peer = 3, _rid = 99, sec = "wpn_ak74", at = "inv", n = 1 }) }
	pump()
	check(#K.created == 1, "a map server takes coop.dbg.run only from the world (from 0)")
end

print("== world commands run once, on the world server (C.1 A16, K35)")
do
	local H = world()
	local ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "time_add", h = 6 })
	check(ok == true and #H.time_jumps == 1, "time_add: change_game_time once")
	local j = H.time_jumps[1]
	check(j and j[1] == 0 and j[2] == 6 and j[3] == 0, "with (0, 6, 0)")
	check(H.forced == 1, "and the stock forced_weather_change")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "time_to", h = 6 })
	j = H.time_jumps[2]
	check(ok == true and j and j[1] == 0 and j[2] == 20 and j[3] == 0, "time_to 06:00 at 10:00: forward 20 h (coop_time)")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "weather", w = "w_storm1" })
	check(ok == true and H.weathers[1][1] == "w_storm1" and H.weathers[1][2] == true, "weather: level.set_weather(w, true)")
	ok = ask(H, "coop.dbg.world", 3, { v = 1, cmd = "info", k = "give", i = "test_info" })
	check(ok == true and H.infos.test_info == true, "info give on the world server")
end

print("== personal flags and money (B.9)")
do
	local H = world()
	local ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "god", on = true })
	local s = H.dbg.set and H.dbg.set[1]
	check(ok == true and s and s.peer == 3 and s.t.god == true, "god: coop.debug.set_flags(3, {god = true})")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = 50000 })
	local g = H.grants[1]
	check(ok == true and g and g[1] == 3 and g[2] == 50000, "money: coop.money_grant(3, 50000)")
	ok = ask(H, "coop.dbg.self", 3, { v = 1, cmd = "money", a = -1000 })
	g = H.grants[2]
	check(ok == true and g and g[2] == -100, "money never below 0: -1000 of 100 takes 100")
	ok = ask(H, "coop.dbg.self", 0, { v = 1, cmd = "tp", x = 1, y = 2, z = 3 })
	local t = H.teleports[1]
	check(ok == true and t and t[1] == 0 and t[2].x == 1, "tp: the owner moves (coop_mods_core.teleport), the host player too")
end

print("== targets (C.1 T2, T3, K24)")
do
	local H = world()
	local ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 503 })
	check(ok == false and why == "player_target", "release of a player: player_target")
	ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 0 })
	check(ok == false and why == "player_target", "release of id 0: player_target")
	ok, why = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 4321 })
	check(ok == false and why == "bad_target", "no such object: bad_target")
	ok = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 700 })
	check(ok == true and H.objects[700]._killed == true, "kill an NPC of the world server's level")
	ok = ask(H, "coop.dbg.target", 3, { v = 1, cmd = "release", t = 700 })
	check(ok == true and H.released[1] and H.released[1][1] == 700, "release: alife_release_id")

	local H2 = world({ split = true })
	H2.obj_level = { [700] = LEVEL_MK }
	ok = ask(H2, "coop.dbg.target", 3, { v = 1, cmd = "kill", t = 700 })
	check(ok == true and H2.orders[1] and H2.orders[1].verb == "kill" and H2.orders[1].id == 700,
		"kill of a map server's object: the far order (quests.far_do)")
	ok = ask(H2, "coop.dbg.target", 3, { v = 1, cmd = "wound", t = 700 })
	local runs = sent(H2, "coop.dbg.run")
	check(ok == true and #runs == 1 and runs[1].target == MK and runs[1].t._c == "wound", "wound there: coop.dbg.run to its bridge")
end

print("== P.player (B.4)")
do
	local H = world()
	local P = H.env.coop_npc_players
	local p = P.player(3)
	check(p and p.peer == 3 and p.nick == "p3" and p.character == 503 and p.level == LEVEL_HOST, "player(3): peer, nick, character, level")
	check(p and p.here == true and p.link == "net" and p.standing == true, "here, net, standing")
	check(p and p.object() == H.objects[503], "object() is his proxy")
	local h = P.player(0)
	check(h and h.character == 0 and h.link == "local" and h.object() == H.env.db.actor, "player(0) on a listen host: the host player")
	check(P.player(5) == nil, "player(5): nobody")
	check(P.player_by_name("@P3") and P.player_by_name("@P3").peer == 3, "by nick, any case")
	check(P.player_by_name("@3") and P.player_by_name("@3").peer == 3, "by number")
	check(P.player_by_name("@#3") and P.player_by_name("@#3").peer == 3, "by #number")
	check(P.player_by_name("@nobody") == nil, "an unknown nick")

	local D = world({ dedicated = true })
	local PD = D.env.coop_npc_players
	check(PD.player(0) == nil, "dedicated: player(0) is nil, the ghost is nobody")
	local ev = PD.everyone()
	local ghost = false
	for _, o in ipairs(ev) do if o:id() == 0 then ghost = true end end
	check(not ghost, "dedicated: everyone() leaves the ghost out")
end

print("== the server console coop_dbg (B.7)")
do
	local D, S = world({ dedicated = true, debug = false })
	local out = S.console("spawn_item @p3 sec=medkit n=5 at=near")
	check(type(out) == "string" and out:find("debug_off", 1, true) ~= nil, "debug off: the console refuses too (like sv_cheats)")
	check(#D.created == 0, "nothing made")
	D.dbg.on = true
	out = S.console("spawn_item @p3 sec=medkit n=5 at=near")
	check(#D.created == 5 and D.created[1].t[4] == nil and D.created[1].t[1].x == 10, "@p3 at=near: five medkits by his character")
	out = S.console("money @P3 a=500")
	check(D.grants[1] and D.grants[1][1] == 3 and D.grants[1][2] == 500, "money @P3 a=500")
	out = S.console("money a=500")
	check(type(out) == "string" and out:find("no_player", 1, true) ~= nil, "a personal command without @player: no_player")
	out = S.console("surge start")
	check(type(out) == "string", "surge start: a stock word as the argument")
	out = S.console("time_to h=6 m=30")
	check(D.time_jumps[1] and D.time_jumps[1][2] == 20 and D.time_jumps[1][3] == 30, "time_to h=6 m=30")
	out = S.console("help")
	check(type(out) == "string" and out:find("spawn_item", 1, true) ~= nil, "help lists the commands")
	out = S.console("help spawn_item")
	check(type(out) == "string" and out:find("sec=", 1, true) ~= nil, "help spawn_item gives its keys")
	S.console("lua coop_dbg_test_value = 41 + 1")
	check(D.env.coop_dbg_test_value == 42 or rawget(_G, "coop_dbg_test_value") == 42, "lua: the operator runs Lua")
	check(#D.dbg.said >= 6, "every answer goes to coop.debug.say")

	local p = S.parse('spawn_item @Bob sec=wpn_ak74 at=inv')
	check(p and p.cmd == "spawn_item" and p.player == "@Bob" and p.args.sec == "wpn_ak74" and p.args.at == "inv", "parse: cmd, @player, key=value")
	p = S.parse('weather w="w_storm1"')
	check(p and p.args.w == "w_storm1", "parse: a quoted value")
	p = S.parse('lua printf("a b")')
	check(p and p.cmd == "lua" and p.args.code == 'printf("a b")', "parse: lua keeps the rest of the line")
end

print("== debug on marks the world as stock does (owner decision 1)")
do
	local H = world({ debug = false })
	H.fire("coop_debug_changed", true, 2)
	check(H.infos.debug_mode_flag_on == true, "debug_mode_flag_on given when debug goes on")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
