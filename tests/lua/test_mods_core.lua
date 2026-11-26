MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== core (host)")
make_actor(vec3(0, 0, 0))
start_all()
local C = coop_mods_core
local modes = dofile("tests/lua/support/modes.lua")

-- serializer
local v = { a = 1, b = -2.5, c = "x;y=z%\n:{}", d = true, e = false, n = { 1, 2, { deep = "yes" } }, [7] = "seven",
	big = 3000000000, tiny = 1e-9, inf = math.huge, f = function() end }
local s = C.ser(v)
local back = C.deser(s)
check(type(s) == "string" and back ~= nil, "ser/deser round trip runs")
check(back.a == 1 and back.b == -2.5 and back.c == v.c and back.d == true and back.e == false, "scalars survive")
check(back.n[3].deep == "yes" and back[7] == "seven", "nested tables and number keys survive")
check(back.big == 3000000000 and math.abs(back.tiny - 1e-9) < 1e-20 and back.inf == math.huge, "large/small/inf numbers survive")
check(back.f == nil, "functions are skipped")
check(C.deser("s5:abc") == nil, "short string rejected")
check(C.deser("{s1:a") == nil, "unterminated table rejected")
check(C.deser("n1;x") == nil, "trailing data rejected")
check(C.deser("return os.exit()") == nil, "code is never loaded")
local deep = string.rep("{s1:k", 20) .. "t" .. string.rep("}", 20)
check(C.deser(deep) == nil, "too deep rejected")
local tbl = {}
local cur = tbl
for i = 1, 15 do cur.k = {}; cur = cur.k end
check(C.ser(tbl) == "{}" or C.ser(tbl) ~= nil, "a too deep branch is dropped, the rest serializes")

-- modules
check(C.mod("no_such_mod_xyz") == nil and rawget(_G, "no_such_mod_xyz") == nil, "absent mod: nil, _G untouched")
fake_mod_a = { f = function() return 1 end }
check(C.mod("fake_mod_a") == fake_mod_a, "present mod found")
local ok, orig = C.wrap(fake_mod_a, "f", "fake_mod_a.f", function(o) return function() return o() + 1 end end)
check(ok and orig ~= nil and fake_mod_a.f() == 2, "wrap keeps and calls the original")

-- attachment points: an adapter that does not find the function of its mod says so once, in the log and in coop_status
do
	local function same(o) return o end
	local function lines(text)
		local n = 0
		for _, line in ipairs(LOG) do
			if line:find(text, 1, true) then n = n + 1 end
		end
		return n
	end
	local function status_lines(text)
		LOG = {}
		C.print_status()
		return lines(text)
	end
	local LOUD = "[coop-mods] [core] ! "
	check(#C.unattached == 0, "nothing is missed before an adapter misses")

	LOG = {}
	check(C.wrap(fake_mod_a, "missing", "fake_mod_a.missing", same) == false and fake_mod_a.missing == nil,
		"wrap of a missing function attaches nothing")
	local miss = "mod fake_mod_a changed: no function missing, the adapter did not attach (fake_mod_a.missing)"
	check(lines(LOUD .. miss) == 1, "a mod without the wrapped function says so in the log")
	local e = C.unattached[1]
	check(#C.unattached == 1 and e.label == "fake_mod_a.missing" and e.key == "missing" and e.waits == nil,
		"and the point is kept for coop_status")

	-- an adapter that installs from a timer tries the same point again and again
	for _ = 1, 500 do C.wrap(fake_mod_a, "missing", "fake_mod_a.missing", same) end
	check(lines(miss) == 1, "a repeated miss is one line in the log, however often it is tried")
	check(#C.unattached == 1, "and one entry")
	check(status_lines(LOUD .. miss) == 1, "coop_status prints the adapter that did not attach, once")

	LOG = {}
	check(C.wrap(nil, "f", "absent_mod.f", same) == false and #LOG == 0 and #C.unattached == 1,
		"a mod that is not installed is no news: no line, no entry")

	fake_mod_r = { new_name = function() return 1 end }
	LOG = {}
	for _ = 1, 3 do C.wrap(fake_mod_r, "old_name", "fake_mod_r.old_name", same) end
	check(lines(LOUD .. "mod fake_mod_r changed: no function old_name, the adapter did not attach (fake_mod_r.old_name)") == 1
		and #C.unattached == 2, "a renamed function is said once")

	-- the list is as long as the attachment points, not as the tries or the tables tried
	LOG = {}
	for _ = 1, 200 do C.wrap({}, "hit", "an adapter's own slot", same) end
	check(#C.unattached == 3 and lines("did not attach") == 1, "one entry per attachment point, whatever table each try brings")

	-- a later try finds the function: the entry goes and the line is taken back
	fake_mod_a.missing = function() return 5 end
	LOG = {}
	check(C.wrap(fake_mod_a, "missing", "fake_mod_a.missing", function(o) return function() return o() + 1 end end) == true
		and fake_mod_a.missing() == 6, "a later try attaches")
	check(#C.unattached == 2 and C.unattached[1].label == "fake_mod_r.old_name", "and its entry goes")
	check(lines("[coop-mods] [core] mod fake_mod_a: function missing is there now, the adapter attached (fake_mod_a.missing)") == 1,
		"the log takes the line back")
	check(status_lines(miss) == 0, "coop_status no longer names it")

	-- A function a mod adds to another script's table (xr_effects, task_status_functor): the adapter names the mod's script.
	-- These three scripts are on the disk and not loaded; no_such_mod_xyz is not installed.
	local real_fs = getFS
	local ON_DISK = { ["fake_late_a.script"] = true, ["fake_late_b.script"] = true, ["fake_late_c.script"] = true }
	getFS = function()
		local fs = real_fs()
		local exist = fs.exist
		fs.exist = function(self, alias, file)
			if alias == "$game_scripts$" and ON_DISK[file] then return {} end
			return exist(self, alias, file)
		end
		return fs
	end
	fake_shared = {}
	LOG = {}
	check(C.wrap(fake_shared, "added", "fake_shared.added", same, "no_such_mod_xyz") == false and #LOG == 0 and #C.unattached == 2,
		"the mod that adds the function is not installed: no line, no entry")

	-- its script is not loaded yet: the adapter waits, nothing is said aloud
	LOG = {}
	for _ = 1, 50 do C.wrap(fake_shared, "late_a", "fake_shared.late_a", same, "fake_late_a") end
	check(#LOG == 0, "a miss while the mod's script is not loaded is not said aloud")
	check(#C.unattached == 3 and C.unattached[3].waits == "fake_late_a", "it is one entry that waits for the script")
	check(status_lines("[coop-mods] [core] waiting for script fake_late_a: function late_a (fake_shared.late_a)") == 1
		and lines("fake_late_a changed") == 0, "coop_status says what the adapter waits for")
	fake_late_a = {}
	fake_shared.late_a = function() return "a" end
	LOG = {}
	check(C.wrap(fake_shared, "late_a", "fake_shared.late_a", same, "fake_late_a") == true and #C.unattached == 2 and #LOG == 0,
		"the script came with the function: attached, the entry goes, there was no line to take back")

	-- the script came without the function: the mod changed
	LOG = {}
	C.wrap(fake_shared, "late_b", "fake_shared.late_b", same, "fake_late_b")
	check(#LOG == 0 and C.unattached[3].waits == "fake_late_b", "the second point waits as well")
	fake_late_b = {}
	for _ = 1, 3 do C.wrap(fake_shared, "late_b", "fake_shared.late_b", same, "fake_late_b") end
	local changed = "mod fake_late_b changed: no function late_b, the adapter did not attach (fake_shared.late_b)"
	check(lines(LOUD .. changed) == 1 and #C.unattached == 3 and C.unattached[3].waits == nil,
		"the script is there and the function is not: said once, and the line names the mod's script")

	-- the adapter stops waiting: a try without the script is its last word
	LOG = {}
	C.wrap(fake_shared, "late_c", "fake_shared.late_c", same, "fake_late_c")
	check(#LOG == 0 and #C.unattached == 4 and C.unattached[4].waits == "fake_late_c", "the third point waits")
	for _ = 1, 3 do C.wrap(fake_shared, "late_c", "fake_shared.late_c", same) end
	check(lines(LOUD .. "mod fake_late_c changed: no function late_c, the adapter did not attach (fake_shared.late_c)") == 1
		and #C.unattached == 4 and C.unattached[4].waits == nil, "an adapter that gives up says so once")
	getFS = real_fs
end

-- upvalue helpers
local hidden = { 5 }
fake_mod_b = { get = function() return hidden end }
local val, holder, idx = C.find_local(fake_mod_b, "hidden")
check(val == hidden and holder ~= nil, "find_local finds a file local through a module function")

-- identity
spawn("coop_player_avatar", vec3(10, 0, 0), nil, { id = 500 })
OBJ[500]._kind = "stalker"
local real = db.actor
local seen_peer, seen_actor
local okc, r = C.as_player(OBJ[500], function(x)
	seen_peer, seen_actor = C.identity_peer(), db.actor
	return x * 2
end, 21)
check(okc and r == 42 and seen_actor == OBJ[500] and seen_peer == 1, "as_player swaps db.actor and knows the peer")
check(db.actor == real and C.identity_peer() == nil, "db.actor restored")
okc = C.as_player(OBJ[500], function() error("boom") end)
check(okc == false and db.actor == real, "db.actor restored after an error")

-- players
check(C.is_remote_player(500) and not C.is_remote_player(0) and C.is_player(0), "player checks")
local near, d = C.nearest_player(vec3(9, 0, 0))
check(near == OBJ[500] and d == 1, "nearest player is the avatar")
check(C.nick_of(1) == "joiner", "nick lookup")

-- network: host-side handler, rate limit, side checks
local got = {}
C.on("t1", function(t, from) got[#got + 1] = { t = t, from = from } end, "host")
coop_main.on_event("mods.t1", coop_main.encode({ x = 1 }), 1)
check(#got == 1 and got[1].t.x == 1 and got[1].from == 1, "host handler gets decoded payload and sender")
coop_main.on_event("mods.t1", coop_main.encode({ x = 2 }), 0)
check(#got == 1, "host-side handler ignores events from the host itself")
C.set_limit("t1", 3, 0)
for i = 1, 10 do coop_main.on_event("mods.t1", "", 1) end
check(#got == 1 + 3, "rate limit: burst of 3 then dropped")
C.on("t2", function() got.client = true end, "client")
coop_main.on_event("mods.t2", "", 0)
check(got.client == nil, "client-side handler does not run on the host")
C.on("t3", function() error("handler bug") end)
coop_main.on_event("mods.t3", "", 1)
check(C.stats.errors >= 1, "handler error caught and counted")

-- chunked strings
local big = string.rep("ab;=%cdefgh", 3000) -- 33000 bytes, many characters encode escapes
local got_big
C.on_big("b1", function(str, from) got_big = { str = str, from = from } end, "host")
SENT = {}
check(C.send_big("b1", big, 0), "send_big queued")
check(#SENT == math.ceil(#big / 4800), "split into pieces (" .. #SENT .. ")")
local maxp = 0
for _, e in ipairs(SENT) do maxp = math.max(maxp, #e.payload) end
check(maxp <= 16 * 1024, "every encoded piece fits the engine limit (" .. maxp .. " bytes)")
local pieces = {}
for i = #SENT, 1, -1 do pieces[#pieces + 1] = SENT[i] end
deliver(pieces[1], 1)
for _, e in ipairs(pieces) do deliver(e, 1) end
check(got_big and got_big.str == big and got_big.from == 1, "reassembled out of order with a duplicate")
check(C.send_big("b1", string.rep("x", 300 * 1024), 0) == false, "oversize refused")

-- host gift into a player's character
INI.medkit = { inv_name = "x" }
CREATED = {}
check(C.give(1, "medkit", 0.5) and CREATED[1].parent == 500 and CREATED[1].cond == 0.5, "give creates the item in the player's character")
check(C.give(1, "no_such_section") == false, "give refuses unknown sections")

-- teleport and effects
SENT = {}
C.teleport(1, vec3(1, 2, 3))
local tp = sent("mods.tp")
check(tp and tp.x == 1 and tp.z == 3 and SENT[1].target == 1, "teleport of a client goes to that client")
-- the host player goes the way of a client (docs\DEBUG_DESIGN.md A.2 p. 3, C.2): an order to his machine, which is this Lua (an
-- event to 0 comes back to the host's Lua from 0); nothing moves his actor directly
SENT = {}
db.actor._tp = nil
check(C.teleport(0, vec3(4, 5, 6)) == true, "teleport of the host player is sent")
local tp0, s0 = sent("mods.tp")
check(tp0 and tp0.x == 4 and s0.target == 0 and db.actor._tp == nil, "teleport of the host player: an order to peer 0, no direct move")
deliver(s0, 0)
check(db.actor._tp and db.actor._tp.x == 4 and db.actor._tp.z == 6, "the order back from 0: the host player's machine moves his actor")
db.actor._tp = nil
deliver(s0, 1)
check(db.actor._tp == nil, "an order from a client moves nobody")
-- The actor and world answers come from the facade, even if the transport still looks like the host.
check(C.is_world_server == nil and C.is_bridge == nil, "the adapters' core keeps no role question of its own")
local real_levels = coop.levels
coop.levels = { map_servers = function() return { { bridge = 1, level = 2 } } end } -- the engine's list is not what answers
for _, name in ipairs(modes.names()) do
	modes.install(coop_mode, name)
	-- who decides the world, and whether a sender is the process of a level: an adapter asks the facade
	check(coop_mode.decides_world() == (name == "hostplay" or name == "srv_world"), name .. ": the facade says who decides the world")
	check(coop_mode.from_level(0x101) == (name == "srv_world") and coop_mode.from_level(1) == false and coop_mode.from_level(0) == false,
		name .. ": the facade knows a level's process from a player")
	local playing = name == "hostplay" or name == "none"
	check(C.is_player(0) == playing, name .. ": actor 0 is a player only when the mode says it plays")
	local listed = false
	for _, entry in ipairs(C.player_objects()) do
		if rawequal(entry.obj, db.actor) then listed = true end
	end
	check(listed == playing, name .. ": player objects include only a playing actor")
	db.actor._tp = nil
	deliver(s0, 0)
	check((db.actor._tp ~= nil) == (name == "hostplay"), name .. ": peer 0 order moves only a playing session seat")
end
coop.levels = real_levels
modes.live(coop_mode, load_script)
SENT = {}
check(C.teleport(nil, vec3(1, 1, 1)) == false and #SENT == 0, "no peer: nothing sent (not a broadcast)")
C.fx_sound("ambient\\boom")
check(sent("mods.fx") ~= nil, "fx sound broadcast")
SENT = {}
C.fx_sound("..\\..\\evil")
check(#SENT == 0, "path with .. refused")

-- status line hook
coop_main.print_status()
check(log_has("[coop-mods] [core] role host") ~= nil, "status appended to coop_status")

-- coop_status prints the list of the wrapped functions. The engine's log ends the process on a line of over 4 KB with nothing
-- written, so a status line is a kilobyte at most.
do
	local before = #C.wrapped
	for i = 1, 400 do C.wrapped[#C.wrapped + 1] = "some_module_of_a_mod.a_function_number_" .. i end
	LOG = {}
	C.print_status()
	local longest, seen = 0, 0
	for _, line in ipairs(LOG) do
		if #line > longest then longest = #line end
		for _ in line:gmatch("a_function_number_%d+") do seen = seen + 1 end
	end
	check(longest <= 1000, "no status line is longer than a kilobyte (" .. longest .. ")")
	check(seen == 400, "and every wrapped function is still named (" .. seen .. ")")
	check(log_has("a_function_number_400") ~= nil and log_has("[coop-mods] [core] ") ~= nil, "each piece carries the tag")
	for i = #C.wrapped, before + 1, -1 do C.wrapped[i] = nil end
end

-- ids: one validator with each caller's bounds
check(C.object_id(1) == 1 and C.object_id(65534) == 65534, "object_id: 1..65534")
check(C.object_id(0) == nil and C.object_id(0, true) == 0, "object_id: 0 only with allow_zero")
check(C.object_id(65535) == nil and C.object_id(-1, true) == nil and C.object_id(1.5) == nil, "object_id: out of range or a fraction")
check(C.object_id(0 / 0) == nil and C.object_id(math.huge) == nil and C.object_id(-math.huge, true) == nil, "object_id: NaN and inf")
check(C.object_id("12") == nil and C.object_id("12", false, true) == 12 and C.object_id("x", false, true) == nil,
	"object_id: a string only with coerce")
check(C.wire_id(12) == 12 and C.wire_id(0) == nil and C.wire_id("12") == nil and C.wire_id(65535) == nil, "wire_id: 1..65534")

-- pack and near
local pk = C.pack(1, nil, 3, nil)
check(pk.n == 4 and pk[1] == 1 and pk[2] == nil and pk[3] == 3, "pack keeps the count with nils")
local a_obj, b_obj = { position = function() return vec3(0, 0, 0) end }, { position = function() return vec3(3, 4, 0) end }
check(C.near(a_obj, b_obj, 5) == true and C.near(a_obj, b_obj, 4.9) == false and C.near(a_obj, nil, 100) == false,
	"near: within the distance; a missing object is not near")

-- install: a fault is counted and reported, the start goes on
local errors_before = C.stats.errors
LOG = {}
local ok_i, r_i = C.install("t", "good step", function(x) return x * 2 end, 21)
local bad_i = C.install("t", "bad step", function() error("boom", 0) end)
check(ok_i == true and r_i == 42 and bad_i == false, "install runs the step and returns its result")
check(C.stats.errors == errors_before + 1 and log_has("[coop-mods] [t] ! bad step failed (#1): boom") ~= nil,
	"install reports a fault through the error counter")

-- the flood guard keeps a sender's buckets only while he is in the session
do
	C.set_limit("p32_limit", 1, 0)
	local got = 0
	C.on("p32_limit", function() got = got + 1 end, "host")
	local function from(peer)
		SENT = {}
		C.to_all("p32_limit", { a = 1 })
		local s = SENT[1]
		SENT = {}
		deliver(s, peer)
	end
	if coop_mode.decides_world() or coop_mode.leads_here() then
		from(1); from(1)
		check(got == 1, "the limit holds a sender to his burst")
		local real = coop.players
		coop.players = function() return {} end -- peer 1 left
		from(7) -- the first word of a new sender drops the buckets of those who left
		coop.players = real
		from(1)
		check(got == 3, "a sender who left starts with a full burst (his bucket went with him)")
	end
end

-- single player: everything inert
MODE = "sp"
check(C.active() == false and not coop_mode.decides_world() and not coop_mode.leads_here(), "sp: inactive")
SENT = {}
check(C.send("x", { a = 1 }) == false and #SENT == 0, "sp: nothing is sent")
check(C.give(1, "medkit") == false, "sp: no gifts")
done("CORE")
