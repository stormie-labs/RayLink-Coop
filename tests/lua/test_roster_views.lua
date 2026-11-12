-- Anomaly Coop, plan 2026-11-12 stage 4: the views of the players' list without the world server's seat.
-- An ordinary host (row 0 has the host's badge, nothing changes), a client of a world server that is its operator (no row 0, his own
-- row has the badge, the ping from coop.server_link, /go goes as an operator command), a client that is not the operator (no rights,
-- /go refused here). Real coop_core_chat, coop_hud_netgraph, coop_core_hud (views), coop_testplan; the engine is
-- tests/lua/support/stubs.lua + stubs.d/roster.lua.
-- Run: tools\test_lua.cmd roster_views
MODE = "host"
dofile("tests/lua/support/stubs.lua")

local function section(name, fn)
	print("== " .. name)
	local ok, err = pcall(fn)
	if not ok then
		FAILS = FAILS + 1
		print("  FAIL section '" .. name .. "' crashed: " .. tostring(err))
	end
end

-- luabind "class" stand-in: class "Name" (Base) defines Name in the calling environment
function class(name)
	local env = getfenv(2)
	return function(base)
		local c = setmetatable({}, { __index = base })
		c.__index = c
		env[name] = c
	end
end
CUIScriptWnd = {}
game.translate_string = function(id) return id end -- tr() falls back to the English text
coop.is_dedicated = function() return false end
coop.stash_set = function(k, v) STASH = STASH or {}; STASH[k] = v; return true end
coop.stash_get = function() return nil end
coop_main = { encode = function(t) return t end, decode = function(t) return t end }
level.object_by_id = function() return nil end -- no avatars here: /players shows no distance

local function set_roster(mode, roster, operator)
	MODE, ROSTER, OPERATOR = mode, roster, operator
	OPS = {}
end

local chat = load_script_file("coop_core_chat")
local SYS = {}
chat.system = function(t) SYS[#SYS + 1] = tostring(t) end
local ACCEPTED = 0
coop_core_player = { accept_transition = function() ACCEPTED = ACCEPTED + 1 end }

local function command(text)
	SYS = {}
	chat.run_command(text)
	return SYS
end
local function has(list, s)
	for _, l in ipairs(list) do if l:find(s, 1, true) then return l end end
	return nil
end
local function last_line()
	local t = STASH and STASH.coop_core_chat
	local n = t and t.n or 0
	return t and { nick = t["n" .. n], text = t["t" .. n] } or {}
end

section("an ordinary host: row 0 is the host, nothing changes", function()
	set_roster("host", nil, false)
	check(type(chat.run_command) == "function", "coop_core_chat.run_command exists")
	local out = command("/players")
	check(has(out, "Players: 2") ~= nil, "/players: two players")
	local h = has(out, "host")
	check(h ~= nil and h:find("(host)", 1, true) ~= nil and h:find("(you)", 1, true) ~= nil, "row 0: (host) (you)")
	local c = has(out, "client")
	check(c ~= nil and c:find("(host)", 1, true) == nil, "the client's row: no (host)")
	ACCEPTED = 0
	command("/go")
	check(ACCEPTED == 1 and #OPS == 0, "/go: the host moves the group here")
	chat.on_line("client", "hi")
	check(last_line().nick == "client", "a chat line keeps its nick")
end)

section("an ordinary client: the host's line keeps the host's nick; /go is the host's", function()
	set_roster("client", nil, false)
	chat.on_line("host", "hello")
	check(last_line().nick == "host", "the playing host's nick stays")
	ACCEPTED = 0
	local out = command("/go")
	check(ACCEPTED == 0 and #OPS == 0 and has(out, "Only the host") ~= nil, "/go refused here (as before)")
end)

section("a client of a world server, its operator", function()
	set_roster("client", "world", true)
	local out = command("/players")
	check(has(out, "Players: 2") ~= nil, "/players: the server is not counted")
	check(has(out, "server") == nil, "no row 'server'")
	local me = has(out, "client")
	check(me ~= nil and me:find("(host)", 1, true) ~= nil, "the operator's own row has (host)")
	local other = has(out, "other")
	check(other ~= nil and other:find("(host)", 1, true) == nil, "another player: no (host)")
	ACCEPTED = 0
	command("/go")
	check(ACCEPTED == 0 and #OPS == 1 and OPS[1] == "/go", "/go goes to the world server as an operator command")
	chat.on_line("server", "the world speaks")
	check(last_line().nick == "World", "a line of the server shows the sender World (" .. tostring(last_line().nick) .. ")")
	chat.on_line("other", "hey")
	check(last_line().nick == "other", "a player's line keeps his nick")
end)

section("a client of a world server, not the operator", function()
	set_roster("client", "world", false)
	check(coop.has_host_rights() == false, "no host's rights")
	ACCEPTED = 0
	local out = command("/go")
	check(ACCEPTED == 0 and #OPS == 0 and has(out, "Only the host") ~= nil, "/go refused here, nothing sent")
	out = command("/players")
	check(has(out, "(host)") == nil, "nobody he sees has the host's badge (the operator is not in this stub's list)")
	chat.on_line("server", "x")
	check(last_line().nick == "World", "the server's line: World for him too")
end)

section("the server's answer to an operator command (coop.op.answer)", function()
	set_roster("client", "world", true)
	check(type(chat.on_op_answer) == "function", "coop_core_chat.on_op_answer exists")
	local FEED = {}
	coop_debug_client = { add_line = function(text, kind) FEED[#FEED + 1] = { text = text, kind = kind } end }
	SYS = {}
	chat.on_op_answer({ cmd = "coop_kick", ok = true, text = "[coop] kicked #2 'other'\nsecond line" }, 0)
	check(has(SYS, "kicked #2") ~= nil and has(SYS, "second line") ~= nil and #FEED == 0, "a console command: its lines in the chat")
	SYS = {}
	chat.on_op_answer({ cmd = "coop_dbg", ok = false, text = "! coop_dbg lua: refused" }, 0)
	check(#SYS == 0 and #FEED == 1 and FEED[1].text:find("refused", 1, true) and FEED[1].kind == "err",
		"coop_dbg: in the F7 window's feed, as its other results")
	FEED = {}
	chat.on_op_answer({ cmd = "coop_debug", ok = true, text = "[coop] debug: on" }, 0)
	check(#FEED == 1 and FEED[1].kind == "ok", "coop_debug: the F7 feed too")
	SYS, FEED = {}, {}
	chat.on_op_answer({ cmd = "coop_kick", ok = true, text = "fake" }, 2)
	check(#SYS == 0 and #FEED == 0, "an answer that is not from the server (peer 0): ignored")
	chat.on_op_answer({ cmd = "coop_kick", ok = true, text = "fake" }, nil)
	chat.on_op_answer({ cmd = "coop_kick", ok = true, text = "fake" }, "0")
	check(#SYS == 0 and #FEED == 0, "a sender that is not the number 0: ignored")
	chat.on_op_answer({ cmd = "coop_dbg", ok = true, text = "%c[255,255,0,0]red %s %d" }, 0)
	check(#FEED == 1 and FEED[1].text:find("%c[", 1, true) == nil and FEED[1].text:find("%s %d", 1, true) ~= nil,
		"the feed gets plain text: no colour code, no format", tostring(FEED[1] and FEED[1].text))
	FEED = {}
	chat.on_op_answer({ cmd = "coop_status", ok = true, text = "%c[255,255,0,0]red %s" }, 0)
	check(#SYS == 1 and SYS[1]:find("%c[", 1, true) == nil and SYS[1]:find("%s", 1, true) ~= nil, "the chat too")
	SYS = {}
	chat.on_op_answer({ cmd = "coop_time", ok = true, text = "" }, 0)
	check(#SYS == 1, "an empty answer: one line that it ran")
	coop_debug_client = nil
	SYS = {}
	chat.on_op_answer({ cmd = "coop_dbg", ok = true, text = "coop_dbg money: +500" }, 0)
	check(has(SYS, "+500") ~= nil, "no debug window module: the chat")
end)

-------------------------------------------------------------------------------
local ng = load_script_file("coop_hud_netgraph")
section("the net graph: a client's ping and loss", function()
	set_roster("client", nil, false)
	SERVER_RTT, SERVER_LOSS = 12, 0
	local s = ng.summarize(coop.players(), false, coop.server_link())
	check(s.players == 2 and s.ping == 12 and s.loss == 0, "an ordinary client: the host's link (as row 0 said)")
	local old = ng.summarize({ { id = 0, rtt = 12, loss = 0 }, { id = 1, is_self = true, rtt = 0 } }, false)
	check(old.ping == 12 and old.loss == 0, "an older engine (no server_link): row 0 as before")
	set_roster("client", "world", true)
	SERVER_RTT, SERVER_LOSS = 40, 0.02
	s = ng.summarize(coop.players(), false, coop.server_link())
	check(s.players == 2, "a world server's client: two players, the server not counted")
	check(s.ping == 40 and math.abs((s.loss or -1) - 2) < 1e-6, "the ping and loss of the link to the server (" .. tostring(s.ping) .. ")")
	set_roster("host", nil, false)
	s = ng.summarize(coop.players(), true, nil)
	check(s.ping == 12 and s.players == 2, "the host: the worst client, as before")
	SERVER_RTT, SERVER_LOSS = nil, nil
end)

-------------------------------------------------------------------------------
section("the HUD's group panel: the star", function()
	coop_allies = {
		state_of = function() return "alive", false end,
		slot = function(id) return id end,
		STATUS_STALE_MS = 5000,
	}
	level.object_by_id = function() return nil end
	local hud = load_script_file("coop_core_hud")
	set_roster("client", nil, false)
	local list = hud.views(NOW)
	check(#list == 1 and list[1].peer == 0 and list[1].host == true, "an ordinary client: the host's row has the star")
	set_roster("host", nil, false)
	list = hud.views(NOW)
	check(#list == 1 and list[1].peer == 1 and list[1].host == false, "the host: the client's row has none")
	set_roster("client", "world", false)
	OPERATOR = false
	list = hud.views(NOW)
	check(#list == 1 and list[1].peer == 2 and list[1].host == false, "a world server's client: no server row, nobody starred")
	-- another client sees the operator's row with the star
	local players0 = coop.players
	coop.players = function()
		return { { id = 1, nick = "op", is_self = false, is_host = true }, { id = 2, nick = "me", is_self = true, is_host = false } }
	end
	list = hud.views(NOW)
	check(#list == 1 and list[1].peer == 1 and list[1].host == true, "the operator's row has the star")
	coop.players = players0
end)

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
