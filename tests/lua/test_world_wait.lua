-- Anomaly Coop test: gamedata\scripts\coop_world_wait.script, the waiting window of a world server this game starts (split levels,
-- docs\plans\2026-11-12-split-levels-native.md 3.4, 3.5, stage 6b): the pure view of a server's state, the start of a new world
-- and of a save, the window (connect once, Cancel, Try again), leaving the session and the unattended -coop_world_auto.
-- The engine (coop.*, coop.world_server.*) is a stand-in (support\world_server_stub.lua); the UI kit, the theme and the
-- staging file writer are the real scripts. Not shipped. Run: tools\test_lua.cmd world_wait
dofile("tests/lua/support/menu_stubs.lua")
dofile("tests/lua/support/world_server_stub.lua")
os.execute("mkdir temp\\tests_s6b 2>nul")

XML_FILES["ui_coop_chronicle.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_chronicle.xml")

STRINGS, RUS = {}, {}
local function read_strings(lang, into)
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_menu.xml", "r"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do into[id] = text end
	fh:close()
end
read_strings("eng", STRINGS)
read_strings("rus", RUS)
game = { translate_string = function(id) return STRINGS[id] or id end }
local function T(id) return STRINGS[id] or id end

INFO = { phase = "off", active = false, host = false, client = false, players = {} }
CALLS = {}
coop = {
	is_active = function() return INFO.active end,
	is_host = function() return INFO.host end,
	session_info = function() return INFO end,
	host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end,
	connect = function(a) CALLS[#CALLS + 1] = "connect " .. a; return CONNECT_OK ~= false, CONNECT_WHY end,
	disconnect = function() CALLS[#CALLS + 1] = "disconnect"; INFO.active = false; return true end,
}
install_world_server(coop)
CONSOLE = { coop_nick = "Strelok" }
function get_console_cmd(typ, name) return CONSOLE[name] end
function exec_console_cmd() end
axr_main = { config = config_stub() }
CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx"
function command_line() return CMD end
LEVEL = false
level = { present = function() return LEVEL end }
CB = {}
function RegisterScriptCallback(name, f) CB[name] = f end

local function has_log(pat)
	for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return true end end
	return false
end
local function last_call(list) return list[#list] end

load_module("coop_world_stage_file")
local w = load_module("coop_world_wait")

print("== the strings")
do
	local missing = {}
	for id in pairs(STRINGS) do
		if id:find("^st_coop_world_") and not RUS[id] then missing[#missing + 1] = id end
	end
	for id in pairs(RUS) do
		if id:find("^st_coop_world_") and not STRINGS[id] then missing[#missing + 1] = id end
	end
	check(#missing == 0, "every st_coop_world_* id is in rus and eng (" .. table.concat(missing, ",") .. ")")
end

print("== the view of a server's state")
local NEW = { kind = "new" }
local LOAD = { kind = "load", name = "With Kent" }
local v = w.view(nil, 0, NEW)
check(v.title_id == "st_coop_world_creating" and v.can_cancel == false and v.action == nil, "nothing started yet: creating, nothing to cancel")
v = w.view(ws_state("starting", "starting", { elapsed_ms = 65000 }), 0, NEW)
check(v.key == "starting" and v.title == T("st_coop_world_creating") and v.can_cancel and v.action == nil, "starting: 'Creating the world', Cancel")
check(v.detail:find("1:05", 1, true) ~= nil, "the elapsed time (" .. v.detail .. ")")
v = w.view(ws_state("starting", "world", { wait_text = "loading the level", elapsed_ms = 3000 }), 0, LOAD)
check(v.key == "world" and v.title == T("st_coop_world_opening"):gsub("%%s", "With Kent") and v.detail:find("loading the level", 1, true) ~= nil,
	"world: 'Opening the world <name>', the server's wait text")
v = w.view(ws_state("starting", "session"), 0, NEW)
check(v.key == "session" and v.can_cancel, "session: still waiting")
v = w.view(ws_state("ready", "ready", { port = 27961 }), 0, NEW)
check(v.key == "ready" and v.title_id == "st_coop_world_ready" and v.action == "connect" and not v.can_cancel, "ready: 'The world is ready. Entering', connect")
v = w.view(ws_state("ready", "ready", { port = 27961 }), 0, { kind = "new", connected = true })
check(v.key == "entering" and v.action == nil, "connected: no second connect")
v = w.view(ws_state("ready", "ready", { port = 27961 }), 0, { kind = "new", connect_failed = "the host refused" })
check(v.key == "connect_failed" and v.detail:find("the host refused", 1, true) and v.primary == "st_coop_world_btn_retry"
	and v.secondary == "st_coop_world_btn_close", "connect failed: say so, Try again")
local lines = {}
for i = 1, 20 do lines[i] = "line " .. i end
v = w.view(ws_state("failed", "world", { error = "gave_up", error_text = "gave up waiting", lines = lines }), 0, NEW)
check(v.key == "failed" and v.title_id == "st_coop_world_failed" and v.detail:find("gave up waiting", 1, true) and #v.lines == 20
	and v.primary == "st_coop_world_btn_retry" and v.secondary == "st_coop_world_btn_close" and not v.can_cancel, "failed: error, 20 lines, Try again / Close")
v = w.view(ws_state("failed", "starting", { error = "ready_timeout" }), 0, NEW)
check(v.key == "failed" and v.detail == T("st_coop_world_err_ready_timeout"), "ready_timeout: its own text")
v = w.view(ws_state("crashed", "session", { crashed = true, exited = true, exit_code = 3 }), 0, NEW)
check(v.key == "crashed" and v.title_id == "st_coop_world_crashed" and v.primary == "st_coop_world_btn_open_again", "crashed: closed with an error, Open again")
v = w.view(ws_state("crashed", "saving", { killed = true, error = "killed" }), 0, NEW)
check(v.key == "crashed" and v.detail == T("st_coop_world_err_killed"), "killed: its own text")
v = w.view(ws_state("stopping", "saving", { stopping = true }), 0, NEW)
check(v.key == "stopping" and v.title_id == "st_coop_world_saving" and not v.can_cancel and v.primary == nil, "stopping: 'Saving the world'")
v = w.view(ws_state("down", "down"), 0, { kind = "new", stopping = true })
check(v.key == "down" and v.action == "close", "down after our stop: the window closes")
v = w.view(ws_state("down", "down"), 0, NEW)
check(v.key == "down" and v.action == nil and v.primary == "st_coop_world_btn_open_again", "down by itself: Open again")

print("== the memory lines")
local text, low = w.memory_line({ commit_free_mb = 12000 })
check(text == T("st_coop_world_mem_note") and low == false, "enough memory: the plain note")
text, low = w.memory_line({ commit_free_mb = 3000 })
check(low == true and text == T("st_coop_world_mem_low"):gsub("%%s", "2.9"), "less than 4 GB free: the low line (" .. text .. ")")
text, low = w.memory_line(nil)
check(text == T("st_coop_world_mem_note") and low == false, "no figure: the plain note")
check(w.here_line({ commit_free_mb = 8192 }) == T("st_coop_world_here"):gsub("%%s", "8.0"), "the window's line with the figure")
check(w.here_line(nil) == T("st_coop_world_here_nomem"), "and without it")

print("== starting a new world")
local REC = { id = "6553f1a2-00ff", name = "Strelok", title = "With Kent", faction = "stalker", world = { story = true, routes = false, difficulty = 1, economy = 1 } }
local VALUES = { ["c|coop_split_levels"] = "1" }
local CREATOR = { name = "Strelok", icon = "", loadout = { "wpn_pm" }, money = 500, map = "", bare = false }
ws_reset(); CALLS = {}; INFO.pending_host = 27961
local ok, why = w.start_new(REC, VALUES, CREATOR, 27961, "With Kent")
check(ok == true, "a new world starts (" .. tostring(why) .. ")")
check(last_call(WS.calls) == "start world=new port=27961 stage=true nick=With Kent", "start{ world = new, stage = true, the host's port, the title as nick }")
check(CALLS[#CALLS] == "pending nil" and INFO.pending_host == nil, "the pending host of the Co-op window is cancelled after the start")
do
	local fh = io.open(WS.stage_path, "rb")
	local s = fh and fh:read("*a")
	if fh then fh:close() end
	check(s and s:find("[creator]\nname = Strelok", 1, true) ~= nil and s:find("\"c|coop_split_levels\" = 1", 1, true) ~= nil,
		"the staging file is at stage_file() with [values] and [creator]")
end
check(has_log("[coop-world-wait] start new"), "a log line of the start")

ws_reset(); CALLS = {}; INFO.pending_host = 27961
WS.start_ok, WS.start_why = false, "a world server of this game runs already"
ok, why = w.start_new(REC, VALUES, CREATOR, 27961, "x")
check(ok == false and why:find("runs already", 1, true) and #CALLS == 0 and INFO.pending_host == 27961, "start refused: the reason, the pending host stays")
check(io.open(WS.stage_path, "rb") == nil, "and the staging file is removed")
check(has_log("[coop-world-wait] ! not started"), "a log line of the refusal")
ws_reset(); WS.stage_path = nil
ok, why = w.start_new(REC, VALUES, CREATOR, 27961, "x")
check(ok == false and why == T("st_coop_world_err_no_stage") and #WS.calls == 1, "no stage_file(): refused, nothing started")
WS.stage_path = "temp/tests_s6b/coop_new_world.ltx"
ws_reset()
ok, why = w.start_new({ faction = "bad faction" }, VALUES, CREATOR, 27961, "x")
check(ok == false and why:find("faction", 1, true) and last_call(WS.calls) ~= nil and not last_call(WS.calls):find("^start"), "a record the file cannot hold: refused before start")

print("== starting a save")
ws_reset()
ok, why = w.start_load("coop_auto_g1_1", 27960, "With Kent")
check(ok == true and last_call(WS.calls) == "start world=load save=coop_auto_g1_1 port=27960 nick=With Kent", "start{ world = load, save = stem }")

print("== the window")
MENU = { shown = true }
function MENU:ShowDialog() self.shown = true end
function MENU:HideDialog() self.shown = false end
function MENU:Show(b) self.visible = b end
ws_reset(); CALLS = {}; LOG = {}
ok = w.start_new(REC, VALUES, CREATOR, 27961, "With Kent")
local dlg = w.open(MENU, { kind = "new", name = "With Kent", port = 27961 })
check(dlg ~= nil and dlg.shown and MENU.shown == false, "the window opens over the main menu")
local function frames(n, ms)
	for _ = 1, n do
		NOW = NOW + (ms or 300)
		dlg:Update()
	end
end
frames(1)
check(dlg.title.text == T("st_coop_world_creating") and dlg.here.text:find("11.7", 1, true) ~= nil, "Creating the world, the line with the memory")
check(dlg.btn_secondary.shown and dlg.secondary_text.text == T("st_coop_menu_btn_cancel"), "Cancel is there")
check(has_log("[coop-world-wait] starting"), "the phase is logged")
WS.state.phase, WS.state.wait_text = "world", "the level"
frames(1)
check(dlg.detail.text:find("the level", 1, true) and has_log("[coop-world-wait] world"), "the wait text, the phase change logged")
local nlog = #LOG
frames(3)
check(#LOG == nlog, "no line without a change")
WS.state = ws_state("ready", "ready", { port = 27963 })
frames(1)
check(CALLS[#CALLS] == "connect 127.0.0.1:27963" and has_log("[coop-world-wait] ready"), "ready: connect to 127.0.0.1:<port>")
INFO.active, INFO.phase = true, "connecting"
frames(3)
local n = 0
for _, c in ipairs(CALLS) do if c:find("^connect") then n = n + 1 end end
check(n == 1, "connect only once")
-- the engine refused the client
INFO.active, INFO.phase, INFO.last_error, INFO.last_error_code = false, "off", "the host's mod list differs", "ContentMismatch"
frames(1)
check(dlg.title.text == T("st_coop_world_connect_failed") and dlg.btn_primary.shown and has_log("[coop-world-wait] connect_failed"),
	"the client was refused: said so, Try again")
click(dlg, "btn_ww_primary")
check(CALLS[#CALLS] == "connect 127.0.0.1:27963", "Try again connects again")
INFO.active, INFO.phase, INFO.last_error, INFO.last_error_code = true, "connecting", nil, nil
frames(1)
-- in the world: the actor's first update marks the creator as joined and hides the window
INFO.phase = "live"
LEVEL = true
CB.actor_on_first_update()
check(dlg.shown == false and w.state_of().joined == true, "in the world: the window is gone, the creator has joined")

print("== leaving the session")
LOG = {}
INFO.active, INFO.phase = false, "off"
LEVEL = false
w.on_menu_frame(MENU)
check(last_call(WS.calls) == "stop" and has_log("[coop-world-wait] leave"), "the session ended: the world server is told to save and quit")
dlg = w.window_of()
frames(1)
check(dlg.shown and dlg.title.text == T("st_coop_world_saving") and not dlg.btn_secondary.shown, "'Saving the world' without Cancel")
WS.state = ws_state("down", "down")
WS.running = false
frames(1)
check(dlg.shown == false and MENU.shown == true and has_log("[coop-world-wait] down"), "down: the window closes, the main menu is back")
w.on_menu_frame(MENU)
check(last_call(WS.calls) == "stop" and #WS.calls == 3, "nothing more on the next menu frame")

print("== Cancel while starting")
ws_reset(); CALLS = {}; LOG = {}
w.start_load("coop_auto_g1_1", 27960, "With Kent")
dlg = w.open(MENU, { kind = "load", name = "With Kent", save = "coop_auto_g1_1", port = 27960 })
frames(1)
click(dlg, "btn_ww_secondary")
check(last_call(WS.calls) == "stop" and has_log("[coop-world-wait] cancel"), "Cancel stops the server")
frames(1)
check(dlg.shown and dlg.title.text == T("st_coop_world_saving"), "and waits for it")
WS.state = ws_state("down", "down"); WS.running = false
frames(1)
check(not dlg.shown, "closed when it is down")

print("== a crash while playing")
ws_reset(); CALLS = {}; LOG = {}
w.start_new(REC, VALUES, CREATOR, 27961, "With Kent")
dlg = w.open(MENU, { kind = "new", name = "With Kent", port = 27961 })
WS.state = ws_state("ready", "ready", { port = 27961 })
frames(1)
INFO.active, INFO.phase = true, "live"
CB.actor_on_first_update()
WS.state = ws_state("crashed", "session", { crashed = true, exited = true, lines = { "a", "b" } })
WS.running = false
INFO.active, INFO.phase = false, "off"
w.on_menu_frame(MENU)
dlg = w.window_of()
frames(1)
check(dlg.shown and dlg.title.text == T("st_coop_world_crashed") and dlg.lines_text.text:find("a\\nb", 1, true)
	and dlg.primary_text.text == T("st_coop_world_btn_open_again"), "'The world closed with an error', its lines, Open again")
check(not (last_call(WS.calls) == "stop"), "a crashed server is not stopped")
click(dlg, "btn_ww_primary")
check(last_call(WS.calls) == "start world=load save=last port=27961 nick=With Kent", "Open again: the last save of the world")
click(dlg, "btn_ww_secondary")
check(last_call(WS.calls) == "stop", "and Cancel of that start stops it")

print("== -coop_world_auto")
check(w.parse_auto("x.exe -coop_world_auto new -coop_world_faction bandit").what == "new"
	and w.parse_auto("x.exe -coop_world_auto new -coop_world_faction bandit").faction == "bandit", "new with a faction")
check(w.parse_auto("x.exe -coop_world_auto new").faction == "stalker", "the faction defaults to stalker")
check(w.parse_auto("x.exe -coop_world_auto coop_auto_g1_1 -dbg").what == "coop_auto_g1_1", "a save's stem")
check(w.parse_auto("x.exe -coop_host 1") == nil, "without the key: nothing")
load_module("coop_game_schema")
load_module("coop_game_record")
ws_reset(); CALLS = {}; LOG = {}
w.state_of().auto_done = false -- a new game run
CMD = "x.exe -coop_world_auto new -coop_world_faction bandit"
MENU.shown = true
w.on_menu_frame(MENU)
check(last_call(WS.calls) and last_call(WS.calls):find("^start world=new") and has_log("[coop-world-wait] auto: new world, faction bandit"),
	"auto new: the same start as the screen")
do
	local fh = io.open(WS.stage_path, "rb")
	local s = fh and fh:read("*a") or ""
	if fh then fh:close() end
	check(s:find("faction = bandit", 1, true) and s:find("\"c|coop_split_levels\" = 1", 1, true) and s:find("name = tester", 1, true)
		and s:find("\"c|coop_world_server\" = 1", 1, true)
		and s:find("money = 5000", 1, true) and s:find("bare = 1", 1, true), "the schema's defaults, split on, world server on, tester, bare, 5000")
end
check(w.window_of() and w.window_of().shown, "and the waiting window")
local before = #WS.calls
w.on_menu_frame(MENU)
check(#WS.calls == before, "once per game run")
if w.window_of() then w.window_of():Close() end

print("== continue_plan: a world server only for a world made by the new flow (owner 2026-11-13)")
local SPL, WSV = "c|coop_split_levels", "c|coop_world_server"
local CR = { name = "Strelok" }
check(w.continue_plan(nil) == "local" and w.continue_plan({}) == "local", "no card: local")
check(w.continue_plan({ values = {} }) == "local", "neither: local")
check(w.continue_plan({ values = { [SPL] = "1" } }) == "local", "split levels without the world server (the old mode): local")
check(w.continue_plan({ values = { [SPL] = "1", [WSV] = "0" }, creator = CR }) == "local", "the old mode, world server off: local")
check(w.continue_plan({ values = { [SPL] = "0", [WSV] = "1" } }) == "local", "world server without split levels: local")
check(w.continue_plan({ values = { [SPL] = "1", [WSV] = "1" }, creator = CR }) == "server", "both on: server")
check(w.continue_plan({ values = { [SPL] = true, [WSV] = true }, creator = CR }) == "server", "both on as booleans: server")
check(w.continue_plan({ values = { [SPL] = "1", [WSV] = "1" } }) == "local",
	"both on but no creator (an old world whose setting was switched on later): local, as the world it is")

print("== -coop_world_auto <stem>")
local CARDS = {
	g_old = { values = { [SPL] = "1" }, name = "Old" },
	g_new = { values = { [SPL] = "1", [WSV] = "1" }, creator = CR, name = "New" },
}
coop_game_settings = {
	game_of_save = function(stem) return (stem:match("^coop_auto_(g_%a+)_")) end,
	load_card = function(id) return CARDS[id] end,
}
ws_reset(); CALLS = {}; LOG = {}
w.state_of().auto_done = false
CMD = "x.exe -coop_world_auto coop_auto_g_old_1"
w.on_menu_frame(MENU)
check(#WS.calls == 0 and has_log("[coop-world-wait] auto: ! coop_auto_g_old_1 is not a world-server world and coop_menu.host_save is not there: nothing is done"),
	"an old split world without the Co-op window's script: nothing is done, a log line")
check(not has_log("old split mode"), "no refusal of the old split mode")
-- owner 2026-11-13: the launcher's "Play" of a host's own world: the game hosts it itself (coop_menu.host_save)
local HOSTED
coop_menu = { host_save = function(id, stem, port) HOSTED = { id = id, stem = stem, port = port }; return true end }
ws_reset(); CALLS = {}; LOG = {}
w.state_of().auto_done = false
w.on_menu_frame(MENU)
check(#WS.calls == 0 and HOSTED and HOSTED.id == "g_old" and HOSTED.stem == "coop_auto_g_old_1" and type(HOSTED.port) == "number",
	"an old split world: hosted in this game, no world server")
check(has_log("[coop-world-wait] auto: hosting coop_auto_g_old_1 in this game on port " .. tostring(HOSTED and HOSTED.port)), "and a log line with the port")
coop_menu = { host_save = function() return false, "a session is running" end }
ws_reset(); CALLS = {}; LOG = {}
w.state_of().auto_done = false
w.on_menu_frame(MENU)
check(has_log("[coop-world-wait] auto: ! coop_auto_g_old_1 is not hosted: a session is running"), "a refusal is a log line")
coop_menu = nil
ws_reset(); CALLS = {}; LOG = {}
w.state_of().auto_done = false
CMD = "x.exe -coop_world_auto coop_auto_g_new_1"
w.on_menu_frame(MENU)
check(last_call(WS.calls) and last_call(WS.calls):find("^start world=load save=coop_auto_g_new_1") ~= nil, "a world-server world: started")
coop_game_settings = nil

print(string.format("%d passed, %d failed", PASSES, FAILS))
