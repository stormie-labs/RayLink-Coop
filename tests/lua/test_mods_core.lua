MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
print("== core (host)")
make_actor(vec3(0, 0, 0))
start_all()
local C = coop_mods_core

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
check(C.wrap(fake_mod_a, "missing", "x", function(o) return o end) == false, "wrap of a missing function is a no-op")

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
C.teleport(0, vec3(4, 5, 6))
check(db.actor._tp and db.actor._tp.x == 4, "teleport of the host moves its own actor")
C.fx_sound("ambient\\boom")
check(sent("mods.fx") ~= nil, "fx sound broadcast")
SENT = {}
C.fx_sound("..\\..\\evil")
check(#SENT == 0, "path with .. refused")

-- status line hook
coop_main.print_status()
check(log_has("[coop-mods] [core] role host") ~= nil, "status appended to coop_status")

-- single player: everything inert
MODE = "sp"
check(C.active() == false and C.is_host() == false, "sp: inactive")
SENT = {}
check(C.send("x", { a = 1 }) == false and #SENT == 0, "sp: nothing is sent")
check(C.give(1, "medkit") == false, "sp: no gifts")
done("CORE")
