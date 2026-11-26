-- The context line of the log, for the launcher's error reports (coop_main.context_line): what it says and what it must not.
-- Run: tools\test_lua.cmd context_line
MODE = "host"
dofile("tests/lua/support/stubs.lua")
dofile("tests/lua/support/modes.lua").live(load_script_file("coop_mode"))
load_coop_main()
local m = coop_main

local line = m.context_line({ role = "host", level = "l01_escape", players = 2, split = true, protocol = 25, quests = { "a_task", "b_task" } })
check(line == "[coop] context: role=host level=l01_escape players=2 split=1 protocol=25 quests=a_task,b_task", "the whole line")

line = m.context_line({ role = "mapserver", level = "k00_marsh", players = 1, split = false, protocol = 25, quests = {} })
check(line == "[coop] context: role=mapserver level=k00_marsh players=1 split=0 protocol=25 quests=", "a map server has no quests")

local many = {}
for i = 1, 12 do many[i] = "t" .. i end
line = m.context_line({ role = "client", level = "x", players = 3, split = true, protocol = 25, quests = many })
check(line:find("quests=t1,t2,t3,t4,t5,t6,t7,t8$") ~= nil, "at most eight quests")

print("== the line in a session: once, then only when something changed")
local LINES = {}
local stock_printf = printf
printf = function(fmt, ...)
	local s = string.format(fmt, ...)
	if s:find("[coop] context", 1, true) then LINES[#LINES + 1] = s end
end
coop.protocol = function() return 25 end
coop.players = function() return { { id = 0, nick = "secret_nick", is_self = true }, { id = 1, nick = "other_nick" } } end
level = level or {}
level.name = function() return "l01_escape" end
task_manager = { get_task_manager = function() return { task_info = { zed = {}, alpha = {} } } end }
m.on_game_start()
SendScriptCallback("actor_on_update")
check(#LINES == 1 and LINES[1]:find("role=host level=l01_escape players=2 split=0", 1, true), "co-op context at the start of a level")
check(LINES[1] and LINES[1]:find("quests=alpha,zed", 1, true) ~= nil, "the quests of the task manager, sorted")
check(LINES[1] and not LINES[1]:find("nick", 1, true), "no nicks")
SendScriptCallback("actor_on_update")
NOW = NOW + 61000
SendScriptCallback("actor_on_update")
check(#LINES == 1, "a minute later, nothing changed: no line")
level.name = function() return "k00_marsh" end
SendScriptCallback("actor_on_update")
check(#LINES == 1, "before the minute is over: no line")
NOW = NOW + 61000
SendScriptCallback("actor_on_update")
check(#LINES == 2 and LINES[2]:find("level=k00_marsh", 1, true) ~= nil, "after it: the new one")
printf = stock_printf

print(string.format("%d passed, %d failed", PASSES, FAILS))
