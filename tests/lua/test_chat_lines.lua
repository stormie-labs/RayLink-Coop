-- Anomaly Coop test: whose chat line it is, and where the world server's answer to its operator goes. Real coop_core_chat;
-- the engine is tests/lua/support/stubs.lua + stubs.d/roster.lua (coop.self_id: 0 on the host, 1 on a client).
--   own line: the engine names the sender's peer (coop_main.on_chat from; our own line: Manager::send_chat passes self()), so a
--   line is ours when from is our peer id, whatever the nick; only a line without a sender falls back to the nick;
--   coop.op.answer: a command a window waits for (coop_game_set -> coop_settings, coop_restore -> coop_menu) is shown by that
--   window alone when it took the answer; an answer nobody took goes to the chat.
-- Run: tools\test_lua.cmd chat_lines
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
coop.stash_set = function(k, v) STASH = STASH or {}; STASH[k] = v; return true end
coop.stash_get = function() return nil end
coop_main = { encode = function(t) return t end, decode = function(t) return t end }

local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_script_file("coop_mode"), load_script_file)
local chat = load_script_file("coop_core_chat")
local SYS = {}
chat.system = function(t) SYS[#SYS + 1] = tostring(t) end

-- the last line of the history as the chat stored it: nick, text, kind ("self" | "other" | "sys")
local function last_line()
	local t = STASH and STASH.coop_core_chat
	local n = t and t.n or 0
	return t and { nick = t["n" .. n], text = t["t" .. n], kind = t["k" .. n] } or {}
end

local function set_roster(mode, roster, operator)
	MODE, ROSTER, OPERATOR = mode, roster, operator
end

-------------------------------------------------------------------------------
section("own line: decided by the sender's peer, not by the nick", function()
	set_roster("host", nil, false)
	chat.on_line("host", "my line", 0)
	check(last_line().kind == "self", "the host's own line (from = its peer 0) is its own")
	chat.on_line("host", "I took the host's nick", 1)
	check(last_line().kind == "other" and last_line().nick == "host",
		"a client who took the host's nick: another player's line, kept under his nick (" .. tostring(last_line().kind) .. ")")
	chat.on_line("client", "hi", 1)
	check(last_line().kind == "other", "a client's line on the host: another player's")

	set_roster("client", nil, false)
	chat.on_line("client", "my line", 1)
	check(last_line().kind == "self", "a client's own line (from = its peer 1) is its own")
	chat.on_line("client", "same nick, the host's seat", 0)
	check(last_line().kind == "other" and last_line().nick == "client",
		"the host with the client's nick: the host's line, not ours (" .. tostring(last_line().kind) .. ")")

	set_roster("client", "world", true)
	chat.on_line("client", "the server's console", 0)
	check(last_line().kind == "other" and last_line().nick == "World",
		"a world server's line under this client's nick: the World's, not ours (" .. tostring(last_line().nick) .. ")")
	chat.on_line("client", "the operator's own line", 1)
	check(last_line().kind == "self" and last_line().nick == "client", "the operator's own line stays his")
end)

section("a line without a sender: the nick decides", function()
	set_roster("host", nil, false)
	chat.on_line("host", "no sender")
	check(last_line().kind == "self", "our nick and no peer: ours")
	chat.on_line("client", "no sender")
	check(last_line().kind == "other", "another nick and no peer: another player's")
end)

-------------------------------------------------------------------------------
section("the server's answer: a window that took it shows it alone", function()
	set_roster("client", "world", true)
	local GOT = {}
	coop_settings = { on_operator_answer = function(good, lines) GOT[#GOT + 1] = { good = good, lines = lines }; return true end }
	SYS = {}
	chat.on_op_answer({ cmd = "coop_game_set", ok = true, text = "[coop] coop_game_set: o|alife/event/emission_frequency = 12" }, 0)
	check(#GOT == 1 and GOT[1].good == true and GOT[1].lines[1]:find("= 12", 1, true) ~= nil, "coop_game_set: the settings take it")
	check(#SYS == 0, "and the chat leaves it out (" .. #SYS .. " chat lines)")
	SYS = {}
	chat.on_op_answer({ cmd = "coop_game_set", ok = false, text = "! [coop] coop_game_set: refused: not a value" }, 0)
	check(#GOT == 2 and GOT[2].good == false and #SYS == 0, "a refusal too: the settings' hint only")

	local WAITING = true
	coop_menu = { on_restore_answer = function() return WAITING end }
	SYS = {}
	chat.on_op_answer({ cmd = "coop_restore", ok = true, text = "a\nb" }, 0)
	check(#SYS == 0, "coop_restore with the Co-op window waiting: the window alone")
	WAITING = false
	chat.on_op_answer({ cmd = "coop_restore", ok = true, text = "a\nb" }, 0)
	check(#SYS == 2, "coop_restore nobody waits for (the operator typed it): the chat shows it")

	coop_settings = { on_operator_answer = function() error("boom") end }
	SYS = {}
	chat.on_op_answer({ cmd = "coop_game_set", ok = true, text = "line" }, 0)
	check(#SYS == 1 and SYS[1] == "line", "a window that failed took nothing: the chat shows it")
	coop_settings = nil
	SYS = {}
	chat.on_op_answer({ cmd = "coop_game_set", ok = true, text = "line" }, 0)
	check(#SYS == 1, "no settings script loaded: the chat shows it")
	coop_menu = nil
end)

print(string.format("%d passed, %d failed", PASSES, FAILS))
os.exit(FAILS == 0 and 0 or 1)
