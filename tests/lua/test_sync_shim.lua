-- Anomaly Coop Lua test (F2 T14): coop.sync between machines (tests\lua\support\fake_sync.lua, the engine's rules in
-- Lua) and scripts\coop_sync.script, which keeps the host's world / player / object scopes in its save. Not shipped.
MODE = "host"
dofile("tests/lua/support/stubs.lua")
dofile("tests/lua/support/fake_sync.lua")

AddScriptCallback("save_state") -- the stock axr_main has it; the stub knows only a few callbacks
local shim = load_script_file("coop_sync")
local vector = fake_sync.vector

local function as(m, fn, ...) return fake_sync.as(m, fn, ...) end
local function get(m, scope, key) return as(m, function() return coop.sync.get(scope, key) end) end
local function set(m, scope, key, value) return as(m, function() return coop.sync.set(scope, key, value) end) end

-- ---------------------------------------------------------------- sync_shim_persist_roundtrip
-- export -> marshal -> import gives back world, player and object; the session scope is not saved and stays.
do
	print("sync_shim_persist_roundtrip")
	fake_sync.reset()
	local host, client = fake_sync.machines()
	as(host, shim.on_game_start)
	fake_sync.spawn(100, 0)
	check(set(host, "world", "a", 1) == true, "host sets world a")
	check(set(host, "world", "t", { x = 1, [1] = "one", [2] = false, v = vector(1, 2, 3) }) == true, "a flat table with an array part and a vector")
	check(set(host, "player", "p", "mine") == true, "the host's own player scope")
	check(set(host, "object:100", "o", true) == true, "an object's scope")
	check(set(host, "session", "s", 5) == true, "the session scope")

	local m_data = {}
	as(host, function() SendScriptCallback("save_state", m_data) end)
	check(type(m_data.coop_sync) == "table", "save_state puts coop.sync.export() into m_data.coop_sync")
	local blob = fake_sync.marshal.encode(m_data)
	check(type(blob) == "string", "marshal encodes the saved table")

	-- The next world: on_game_start forgets the old one (a new game has no load_state), load_state takes the save.
	as(host, shim.on_game_start)
	check(get(host, "world", "a") == nil, "a new world starts empty")
	check(get(host, "session", "s") == 5, "the session scope stays while the session goes on")
	local loaded = fake_sync.marshal.decode(blob)
	as(host, function() SendScriptCallback("load_state", loaded) end)
	check(get(host, "world", "a") == 1, "world a is back")
	local t = get(host, "world", "t")
	check(type(t) == "table" and t.x == 1 and t[1] == "one" and t[2] == false, "the table is back with its array part")
	check(t and fake_sync.is_vector(t.v) and t.v.x == 1 and t.v.y == 2 and t.v.z == 3, "a vector stays a vector")
	check(get(host, "player", "p") == "mine", "player p is back")
	check(get(host, "object:100", "o") == true, "the object's scope is back")
	check(get(host, "session", "s") == 5, "import keeps the session scope")
	check(m_data.coop_sync.scopes == 3, "the save holds world, player, object, not the session")

	-- A client keeps only what the host sends: it neither saves nor loads coop.sync.
	local cm = {}
	as(client, function() SendScriptCallback("save_state", cm) end)
	check(cm.coop_sync == nil, "client: save_state leaves m_data alone")
	as(client, function() SendScriptCallback("load_state", loaded) end)
	check(get(client, "world", "a") == nil, "client: load_state imports nothing")

	-- A broken save changes nothing and says so.
	local ok, why = as(host, function() return coop.sync.import({ format = 1, data = "\255garbage" }) end)
	check(ok == false and why == "bad data", "bad saved data is refused")
	check(get(host, "world", "a") == 1, "the store is as it was after a refused import")
end

-- ---------------------------------------------------------------- sync_shim_join_save (T14 review I1)
-- The world save the host writes for a joining player goes to that client whole: coop.sync stays out of it (other
-- players' scopes; the client gets his own copy as SyncFull). m_data lives between saves in the stock storage manager:
-- the key of the last normal save must not ride along either.
do
	print("sync_shim_join_save")
	fake_sync.reset()
	local host = fake_sync.machines()
	as(host, shim.on_game_start)
	set(host, "world", "a", 1)
	set(host, "player", "p", "mine")
	local m_data = {}
	as(host, function() SendScriptCallback("save_state", m_data) end)
	check(type(m_data.coop_sync) == "table", "a normal save holds coop.sync")
	fake_sync.saving_for_join(true)
	as(host, function() SendScriptCallback("save_state", m_data) end)
	fake_sync.saving_for_join(false)
	check(m_data.coop_sync == nil, "the save for a joining player holds no coop.sync, not even the last save's")
	as(host, function() SendScriptCallback("save_state", m_data) end)
	check(type(m_data.coop_sync) == "table" and m_data.coop_sync.scopes == 2, "the next normal save holds it again")
end

-- ---------------------------------------------------------------- sync_shim_handler_result
-- A client's request gets the host handler's ok, result; a handler error is ok = false there, not an error.
do
	print("sync_shim_handler_result")
	fake_sync.reset()
	local host, client = fake_sync.machines()
	as(host, function()
		check(coop.sync.handler("t.op", function(peer, args) return true, { got = args.x, from = peer } end) == true,
			"host registers a handler")
		coop.sync.handler("t.err", function() error("boom") end)
	end)
	local ok, why = as(client, function() return coop.sync.handler("t.op", function() end) end)
	check(ok == false and why == "host only", "a client cannot register a handler")

	local answers = {}
	local function cb(name) return function(ok2, result) answers[name] = { ok = ok2, result = result } end end
	as(client, function()
		check(coop.sync.request("t.op", { x = 5 }, cb("op")) == true, "client requests t.op")
		check(coop.sync.request("t.err", nil, cb("err")) == true, "client requests t.err")
		check(coop.sync.request("t.none", 1, cb("none")) == true, "client requests a name nobody handles")
	end)
	check(answers.op == nil, "no answer before the messages travel")
	fake_sync.pump()
	check(answers.op and answers.op.ok == true and answers.op.result.got == 5 and answers.op.result.from == client.peer,
		"the handler's ok, result reach the client")
	check(answers.err and answers.err.ok == false and answers.err.result == "handler error", "a handler error: ok = false")
	check(client.stats.lua_errors == 0, "no Lua error on the client")
	check(host.stats.lua_errors == 1 and host.stats.handler_errors == 1, "the host counts the handler's error")
	check(answers.none and answers.none.ok == false and answers.none.result == "no handler", "no handler: ok = false")

	-- The host's own request runs the same handler, answered in a later frame.
	local mine
	as(host, function() coop.sync.request("t.op", { x = 7 }, function(o, r) mine = { o, r } end) end)
	check(mine == nil, "the host's own answer comes in a frame, not inside request")
	fake_sync.pump()
	check(mine and mine[1] == true and mine[2].got == 7 and mine[2].from == 0, "the host's own request: peer 0")

	-- 20 in a row per (player, name), then 10 per second (coop.sync.limit changes it).
	local refused = 0
	fake_sync.advance(10000) -- the buckets of the requests above are full again
	as(client, function()
		for _ = 1, 25 do
			coop.sync.request("t.op", {}, function(o, r) if not o and r == "rate limited" then refused = refused + 1 end end)
		end
	end)
	fake_sync.pump()
	check(refused == 5, "the 21st request in a row is rate limited (" .. refused .. " of 25)")
	fake_sync.advance(100)
	local again
	as(client, function() coop.sync.request("t.op", {}, function(o) again = o end) end)
	fake_sync.pump()
	check(again == true, "one more after 100 ms")
end

-- ---------------------------------------------------------------- sync_object_scope_follows_owner (Review Focus 5)
-- The holder of an item writes its object scope; after it changes hands the old one is refused, the new one is not;
-- after the item is destroyed its keys are gone everywhere.
do
	print("sync_object_scope_follows_owner")
	fake_sync.reset()
	local host, a, b = fake_sync.machines(3)
	fake_sync.spawn(7, a.peer)
	check(set(a, "object:7", "ammo", 30) == true, "the holder writes the item's scope")
	check(get(a, "object:7", "ammo") == 30, "his own change shows at once")
	check(get(b, "object:7", "ammo") == nil, "the others see it once it travelled")
	fake_sync.pump()
	check(get(host, "object:7", "ammo") == 30 and get(b, "object:7", "ammo") == 30, "everybody has it")
	local ok, why = set(b, "object:7", "ammo", 1)
	check(ok == false and why == "not allowed", "a player who does not hold it is refused")

	fake_sync.give(7, b.peer)
	ok, why = set(a, "object:7", "ammo", 29)
	check(ok == false and why == "not allowed", "the old holder: not allowed")
	check(set(b, "object:7", "ammo", 28) == true, "the new holder: ok")
	fake_sync.pump()
	check(get(host, "object:7", "ammo") == 28 and get(a, "object:7", "ammo") == 28, "the new holder's value everywhere")

	-- A change that was sent while he held it, judged by the host after the item moved: refused, his view goes back.
	fake_sync.give(7, a.peer)
	check(set(a, "object:7", "ammo", 27) == true, "a writes while he holds it")
	fake_sync.give(7, b.peer) -- the host moves it before a's change arrives
	fake_sync.pump()
	check(get(a, "object:7", "ammo") == 28, "refused by the host: a shows the host's value again")
	check(a.stats.refused == 1, "a counts the refusal")

	-- The host may always write it; on_change tells everybody.
	local seen = {}
	as(b, function() coop.sync.on_change("object:7", "", function(k, v, old, by) seen[#seen + 1] = { k, v, old, by } end) end)
	check(set(host, "object:7", "note", "x") == true, "the host writes any object")
	fake_sync.pump()
	check(#seen == 1 and seen[1][1] == "note" and seen[1][2] == "x" and seen[1][3] == nil and seen[1][4] == 0,
		"on_change at b: key, value, old, by the host")

	fake_sync.destroy(7)
	fake_sync.pump()
	for _, m in ipairs({ host, a, b }) do
		check(get(m, "object:7", "ammo") == nil, "destroyed: no ammo at #" .. m.peer)
		local keys = as(m, function() return coop.sync.keys("object:7", "") end)
		check(next(keys) == nil, "destroyed: no keys at #" .. m.peer)
	end
	check(#seen == 3, "on_change at b for each key that went")
	ok, why = set(a, "object:7", "ammo", 1)
	check(ok == false and why == "no such object", "a destroyed object takes no change")
end

-- ---------------------------------------------------------------- the rules of the engine (coop_syncstore.h, coop_sync_api.cpp)
do
	print("sync_rules")
	fake_sync.reset()
	local host, client = fake_sync.machines()
	local ok, why = set(client, "world", "w", 1)
	check(ok == false and why == "not allowed", "a client does not write the world")
	ok, why = set(client, "session", "w", 1)
	check(ok == false and why == "not allowed", "a client does not write the session")
	check(set(client, "player", "mine", 1) == true, "a client writes his own player scope")
	ok, why = set(client, "player:0", "x", 1)
	check(ok == false and why == "another player's scope is the host's", "a client cannot name another player")
	check(set(host, "world", string.rep("k", 128), 1) == true, "a key of 128 bytes")
	ok, why = set(host, "world", string.rep("k", 129), 1)
	check(ok == false and why == "bad key (1..128 bytes)", "a key of 129 bytes")
	check(set(host, "world", "big", string.rep("s", 16384 - 3)) == true, "a value of 16384 bytes encoded")
	ok, why = set(host, "world", "big", string.rep("s", 16384 - 2))
	check(ok == false and why == "value too large (16385 > 16384)", "16385 bytes: refused, says how large (" .. tostring(why) .. ")")
	ok, why = set(host, "world", "n", 0 / 0)
	check(ok == false and why == "bad value: a number that is NaN or infinite", "NaN")
	ok, why = set(host, "world", "n", { inner = {} })
	check(ok == false and why == "bad value: a table inside a table (only flat tables)", "a nested table")
	ok, why = set(host, "world", "n", { [1.5] = 1 })
	check(ok == false and why == "bad value: a table index that is not a whole number up to 2^53", "a fractional index")
	ok, why = set(host, "nowhere", "n", 1)
	check(ok == false and why == "bad scope", "an unknown scope")
	ok, why = set(host, "object", "n", 1)
	check(ok == false, "\"object\" without an id only for on_change")

	-- The host's player data goes to its player only.
	fake_sync.pump()
	check(set(host, "player:" .. client.peer, "gift", "x") == true, "the host writes a connected player's scope")
	fake_sync.pump()
	check(get(client, "player", "gift") == "x", "it reaches him as his own")
	check(get(client, "player", "mine") == 1, "his own change is in his scope")
	check(get(host, "player:" .. client.peer, "mine") == 1, "and the host has it under his key")

	-- Ruling F2-31 (review I3): keys coop.* of a player scope are the host's (F3 checkpoints): his player cannot forge them.
	ok, why = set(client, "player", "coop.checkpoint.cur", "forged")
	check(ok == false and why == "not allowed: coop.* keys of a player scope are the host's", "a client cannot write coop.*")
	check(set(host, "player:" .. client.peer, "coop.checkpoint.cur", "real") == true, "the host writes it")
	fake_sync.pump()
	check(get(client, "player", "coop.checkpoint.cur") == "real", "it reaches its player")
	ok, why = set(client, "player", "coop.checkpoint.cur", nil)
	check(ok == false, "he cannot remove it either")

	-- Review I2: a value left out is nil, as everywhere in Lua (the engine took LUA_TNONE for a bad value).
	check(set(client, "player", "mine", 2) == true, "set")
	check(set(client, "player", "mine") == true, "set(scope, key) without a value removes the key")
	fake_sync.pump()
	check(get(host, "player:" .. client.peer, "mine") == nil, "removed at the host")
	local answered
	as(host, function() coop.sync.handler("x.ping", function(peer, args) return args == nil, "pong" end) end)
	check(as(client, function() return coop.sync.request("x.ping") end) == true, "request(name) without args")
	as(client, function() coop.sync.request("x.ping", nil, function(o, r) answered = o and r end) end)
	fake_sync.pump()
	check(answered == "pong", "the handler gets nil args")
	check(as(host, function() return coop.sync.broadcast("fx.none") end) == true, "broadcast(name) without args")

	-- A full copy at join: what goes to him, nothing of the others' player data.
	local late = fake_sync.join()
	check(get(late, "world", "w") == nil and get(late, "world", "big") ~= nil, "the copy has the world")
	check(get(late, "player", "gift") == nil, "nothing of another player's scope")

	-- Effects for everybody, one, or within a radius; only the host broadcasts.
	local got = {}
	for _, m in ipairs({ host, client, late }) do
		as(m, function() coop.sync.on("fx", function(args, from) got[#got + 1] = { m.peer, args, from } end) end)
	end
	ok, why = as(client, function() return coop.sync.broadcast("fx", 1) end)
	check(ok == false and why == "host only", "a client does not broadcast")
	local n
	ok, n = as(host, function() return coop.sync.broadcast("fx", "all") end)
	fake_sync.pump()
	check(ok == true and n == 3 and #got == 3, "to everybody, the host too")
	got = {}
	ok, n = as(host, function() return coop.sync.broadcast("fx", "one", { to = client.peer }) end)
	fake_sync.pump()
	check(n == 1 and #got == 1 and got[1][1] == client.peer and got[1][3] == 0, "to one player")
	got = {}
	fake_sync.place(host.peer, vector(0, 0, 0))
	fake_sync.place(client.peer, vector(10, 0, 0))
	fake_sync.place(late.peer, vector(100, 0, 0))
	ok, n = as(host, function() return coop.sync.broadcast("fx", "near", { pos = vector(0, 0, 0), radius = 20 }) end)
	fake_sync.pump()
	check(n == 2 and #got == 2, "within a radius: the host and the near client")

	-- near / owns / in_container
	fake_sync.spawn(50, client.peer)
	fake_sync.spawn(60, nil, vector(12, 0, 0))
	fake_sync.spawn(61, nil, nil, 60)
	as(host, function()
		check(coop.sync.owns(client.peer, 50) == true and coop.sync.owns(late.peer, 50) == false, "owns")
		check(coop.sync.near(client.peer, 60, 5) == true and coop.sync.near(late.peer, 60, 5) == false, "near")
		check(coop.sync.in_container(client.peer, 61, 60) == true and coop.sync.in_container(late.peer, 61, 60) == false,
			"in_container")
	end)
end

-- ---------------------------------------------------------------- install_sync_stubs (stubs.d\sync.lua)
-- One machine outside a session (single player): the host's rules, nothing travels, callbacks in pump().
do
	print("sync_stubs_single")
	local t = {}
	local m = install_sync_stubs(t)
	check(t.sync == m.sync and m.host and m.single, "a single player machine")
	check(t.sync.set("world", "x", 1) == true and t.sync.get("world", "x") == 1, "set / get")
	local seen
	t.sync.on_change("world", "", function(k, v, old) seen = { k, v, old } end)
	t.sync.set("world", "x", 2)
	check(seen == nil, "on_change runs in a frame, not inside set")
	fake_sync.pump()
	check(seen and seen[1] == "x" and seen[2] == 2 and seen[3] == 1, "on_change after a frame")
	t.sync.handler("h", function(peer, args) return true, args + 1 end)
	local got
	t.sync.request("h", 41, function(ok, r) got = ok and r end)
	fake_sync.pump()
	check(got == 42, "a request to its own handler")
	local ok, n = t.sync.broadcast("fx", 1)
	check(ok == true and n == 1, "a broadcast reaches only this machine")
	local host, c1 = install_sync_stubs(t, { session = true })
	check(t.sync == host.sync and host.host and not host.single and c1 and c1.peer == 1, "a session: the host, then the client")
end

print(string.format("SYNC_SHIM: %d passed, %d failed", PASSES, FAILS))
