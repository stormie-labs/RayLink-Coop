-- Anomaly Coop test (the operator of a world server goes back to an autosave of the server from the Co-op window, plan
-- 2026-11-12 s.2.3): coop_menu asks coop_restore, parses the server's rows, shows them as the timeline and sends coop_restore <name>
-- after the host's question. The stand-ins are those of test_menu.lua. Not shipped.
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_chronicle.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_chronicle.xml")

-- strings: real ids from the eng table, "%s" kept
STRINGS = {}
do
	-- the option captions of the host's death rules (F3 task 15) are in st_coop_death.xml, next to the texts of coop_death;
	-- those of HUD v2 (compass, its field of view, the ping line) in st_coop_hud.xml; the failures of a restore
	-- (F3 task 17) in st_coop_saves.xml; the net graph's in st_coop_netgraph.xml
	for _, file in ipairs({ "st_coop_menu.xml", "st_coop_death.xml", "st_coop_hud.xml", "st_coop_saves.xml", "st_coop_netgraph.xml" }) do
		local fh = assert(io.open(ROOT .. "configs/text/eng/" .. file, "r"))
		local src = fh:read("*a")
		fh:close()
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	end
end
STRINGS.k00_marsh, STRINGS.l01_escape, STRINGS.l02_garbage, STRINGS.l05_bar = "Swamps", "Cordon", "Garbage", "Bar"
STRINGS.st_faction_stalker = "Loners"
game = { translate_string = function(id) return STRINGS[id] or id end }

-- which layout nodes the script creates (to find a node that nothing uses)
USED_PATHS = {}
do
	local plain_xml = CScriptXmlInit
	function CScriptXmlInit()
		local x = plain_xml()
		for _, fn in ipairs({ "InitFrame", "InitStatic", "InitTextWnd", "Init3tButton", "InitEditBox", "InitScrollView" }) do
			local f = x[fn]
			x[fn] = function(self, path, parent) USED_PATHS[path] = true; return f(self, path, parent) end
		end
		return x
	end
end

-- engine co-op API stand-in
INFO = { phase = "off", active = false, host = false, client = false, live = false, self_id = -1, nick = "winuser",
	max_players = 8, default_port = 27960, players = {} }
CALLS = {}
coop = {
	is_active = function() return INFO.active end,
	is_host = function() return INFO.host end,
	is_client = function() return INFO.client end,
	session_info = function() return INFO end,
	host = function(port) CALLS[#CALLS + 1] = "host " .. tostring(port); return HOST_RESULT ~= false, HOST_WHY end,
	host_when_ready = function(port) CALLS[#CALLS + 1] = "pending " .. tostring(port)
		INFO.pending_host = port; return true end,
	connect = function(a) CALLS[#CALLS + 1] = "connect " .. a; return true end,
	disconnect = function() CALLS[#CALLS + 1] = "disconnect"; local was = INFO.active; INFO.active = false; return was end,
}
CONSOLE = { coop_nick = "" }
function get_console_cmd(typ, name) return CONSOLE[name] end
EXEC = {}
function exec_console_cmd(cmd) EXEC[#EXEC + 1] = cmd end
axr_main = { config = config_stub() }
LEVEL = false
level = { present = function() return LEVEL end }
db = {}
ALIFE = nil
function alife() return ALIFE end
function ini_file() return ini_over(REF .. "configs/game_maps_single.ltx") end

-- the saves folder and the textures
FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 5 }
function bit_or(a, b) return a + b end
SAVES, SAVES_LISTED = {}, 0
EXIST = {}
for _, name in ipairs({ "k00_marsh_1", "k00_marsh_3", "l01_escape_1", "l02_garbage_2", "l05_bar_1" }) do
	EXIST["intro\\intro_" .. name .. ".dds"] = true
end
function getFS()
	return {
		file_list_open_ex = function(_, alias, flags, mask)
			SAVES_LISTED = SAVES_LISTED + 1
			local items = {}
			for _, s in ipairs(SAVES) do items[#items + 1] = s end
			local list = {}
			function list:Size() return #items end
			function list:Sort(mode) table.sort(items, function(a, b) return a.modif > b.modif end) end
			function list:GetAt(i)
				local s = items[i + 1]
				return { NameFull = function() return s.file end, ModifDigitOnly = function() return s.stamp end,
					Size = function() return s.size end }
			end
			return list
		end,
		exist = function(_, alias, name) return EXIST[name] end,
	}
end

-- a save costs 1.5 ms: a frame's share is a couple of them
function profile_timer()
	local spent = 0
	return { start = function() end, stop = function() spent = spent + 1500 end, time = function() return spent end }
end

-- the games: cards and the blocks of the saves, as coop_game_settings gives them
CARDS, BLOCKS, BLOCK_READS, RUNNING = {}, {}, 0, nil
RINGS, ENSURE = {}, nil -- every coop_game_settings.autosave_game(id), what ensure_record answers
coop_game_settings = {
	list_games = function() return CARDS end,
	running_id = function() return RUNNING end,
	autosave_game = function(id) RINGS[#RINGS + 1] = id or ""; return true end,
	ensure_record = function() return ENSURE end,
	game_of_save = function(stem)
		BLOCK_READS = BLOCK_READS + 1
		local b = BLOCKS[stem]
		if not b then return nil end
		return b.id, b
	end,
}
RESTORED, HOLD = {}, {}
RESTORE_RESULT = true
coop_saves = {
	text = function(key) return STRINGS["st_coop_saves_" .. key] or key end,
	details = function(e) return e end,
	hold = function(on) HOLD[#HOLD + 1] = on end,
	restore = function(name, id)
		RESTORED[#RESTORED + 1] = name .. "|" .. tostring(id)
		if RESTORE_RESULT == true then return true end
		return false, RESTORE_RESULT
	end,
}

-- a save of a game: a .scop in the folder and its block
local CLOCK = 1000
function add_save(id, name, level_name, stamp, extra)
	CLOCK = CLOCK + 1
	SAVES[#SAVES + 1] = { file = name .. ".scop", modif = extra and extra.modif or CLOCK, stamp = stamp, size = extra and extra.size or 5000000 }
	BLOCKS[name] = { id = id, at = level_name and { level = level_name, game_time = "15/03/2012 07:05", real_time = CLOCK, players = { "stormie", "kent" } } or nil }
end

function reset_world()
	CARDS, BLOCKS, SAVES = {}, {}, {}
	RUNNING = nil
	INFO = { phase = "off", active = false, host = false, client = false, nick = "winuser", max_players = 8, default_port = 27960, players = {} }
end

function standard_games()
	reset_world()
	CARDS = {
		{ id = "g1", name = "Stalker", title = "With Kent", faction = "stalker", created = "2026-10-29 20:31", last_played = "2026-10-29 23:38" },
		{ id = "g2", name = "Stalker", faction = "dolg", created = "2026-10-24 10:00", last_played = "2026-10-27 22:10" },
	}
	add_save("g2", "coop_auto_g2_1", "l01_escape", "27/10/2026 22:10")
	add_save("g1", "coop_auto_g1_5", "l05_bar", "29/10/2026 21:45")
	add_save("g1", "coop_auto_g1_4", "l02_garbage", "29/10/2026 22:15")
	add_save("g1", "coop_auto_g1_3", "l01_escape", "29/10/2026 22:45")
	add_save("g1", "coop_auto_g1_2", "k00_marsh", "29/10/2026 22:53")
	add_save("g1", "coop_auto_g1_1", "k00_marsh", "29/10/2026 23:38")
end

MENU = { calls = {} }
function MENU:ShowDialog() self.shown = true end
function MENU:HideDialog() self.shown = false end
function MENU:Show(b) self.visible = b end
function MENU:ShowFactionUI() self.calls[#self.calls + 1] = "new" end
function MENU:OnMessageQuitGame() self.calls[#self.calls + 1] = "quit_game" end
function MENU:OnMessageQuitWin() self.calls[#self.calls + 1] = "quit_win" end
MENU.cb = {}
function MENU:AddCallback(n, ev, f, obj) self.cb[n .. "#" .. ev] = { f = f, obj = obj } end
MENU.shown = true


print("== coop_menu: the world server's autosaves for its operator (plan 2026-11-12 s.2.3)")
local m = load_module("coop_menu")
local function open_window() MENU.cb["btn_coop#17"].f(MENU.cb["btn_coop#17"].obj) end
local function frames(d, n, ms)
	for _ = 1, n do
		NOW = NOW + (ms or 16)
		d:Update()
	end
end
local function flat_shown(c) return c.btn.shown and c.list[1].shown end

check(type(m.parse_restore_lines) == "function" and type(m.on_restore_answer) == "function", "the operator's functions are there")
local ROWS = {
	"[coop]    1 coop_auto_w_3 2026-11-13 21:45",
	"[coop]    2 coop_auto_w_2 2026-11-13 21:30",
	"[coop]    3 coop_auto_w_1 2026-11-13 20:10",
}
local L = m.parse_restore_lines({ ROWS[2], ROWS[1], "junk", "[coop]    4 bad name 2026-11-13 21:00", "[coop]    5 a;b 2026-11-13 21:00" })
check(#L == 2 and L[1].name == "coop_auto_w_3" and L[1].stamp == "2026-11-13 21:45" and L[2].name == "coop_auto_w_2",
	"the server's rows: newest first, a row that is not one is left out")
check(#m.parse_restore_lines({ "[coop] no autosaves in this folder" }) == 0, "no autosaves: an empty list")

standard_games() -- this machine has saves of its own games: none of them may show as the world's
m.on_main_menu_init(MENU)
LEVEL = true
db.actor = { alive = function() return true end }
OPS, OP_RESULT = {}, true
RIGHTS = true
coop.has_host_rights = function() return RIGHTS end
coop.operator_command = function(line)
	OPS[#OPS + 1] = line
	if OP_RESULT == true then return true end
	return false, OP_RESULT
end
local function operator_session()
	INFO = { phase = "live", active = true, host = false, client = true, live = true, nick = "Creator", self_id = 1, max_players = 8,
		players = { { id = 0, nick = "server", is_host = true, rtt = 1, joined = true }, { id = 1, nick = "Creator", is_self = true, rtt = 0, joined = true } } }
end
operator_session()
open_window()
local dlg = MENU.coop_menu_dlg
frames(dlg, 8)
check(OPS[1] == "coop_restore" and #OPS == 1, "the window asks the server for its autosaves, once")
check(dlg.game ~= nil and dlg.game.operator == true and dlg.guest == false, "the operator's window shows the world of the server")
check(#dlg.saves == 0, "no save of this machine is shown as the world's")
check(dlg.tl_sub.text == STRINGS.st_coop_menu_op_loading, "while the list is coming it says so")
check(m.on_restore_answer(true, ROWS) == true, "the answer is taken by the waiting window")
frames(dlg, 3, 300)
check(#dlg.saves == 3 and dlg.saves[1].name == "coop_auto_w_3" and dlg.saves[1].t == "21:45", "the server's autosaves are the timeline")
check(m.on_restore_answer(true, ROWS) == false, "an answer nobody waits for goes to the chat")
click(dlg, "btn_tile")
frames(dlg, 1, 3000)
check(dlg.tl_block.shown, "the operator has the timeline")
click(dlg, "btn_tl_2")
frames(dlg, 1, 1000)
check(flat_shown(dlg.roll), "and can go back")
click(dlg, "btn_roll")
check(dlg.modal == "confirm" and #OPS == 1, "a question first, nothing sent")
check(dlg.modal_text.text:find("21:30", 1, true) ~= nil, "it names the save")
click(dlg, "btn_modal_no")
check(#OPS == 1, "No: nothing is sent")
click(dlg, "btn_roll")
click(dlg, "btn_modal_ok")
check(OPS[#OPS] == "coop_restore coop_auto_w_2" and #RESTORED == 0, "Yes: the server goes back to that save; nothing is loaded here")
dlg:Close()

print("== a refusal and a failed send are said")
OPS = {}
operator_session()
open_window()
dlg = MENU.coop_menu_dlg
frames(dlg, 4)
m.on_restore_answer(false, { "! [coop] coop_restore: only the host of a session can do this" })
frames(dlg, 3, 300)
check(#dlg.saves == 0 and dlg.tl_sub.text:find("only the host of a session", 1, true) ~= nil, "the server's refusal is shown with its reason")
dlg:Close()
OP_RESULT = "not the operator"
open_window()
dlg = MENU.coop_menu_dlg
frames(dlg, 4)
check(#dlg.saves == 0 and dlg.tl_sub.text:find("not the operator", 1, true) ~= nil, "a line that did not leave is said too")
OP_RESULT = true
dlg:Close()

print("== a client without the rights: nothing changes")
OPS = {}
RIGHTS = false
operator_session()
open_window()
dlg = MENU.coop_menu_dlg
frames(dlg, 4)
check(#OPS == 0 and dlg.game == nil and dlg.guest == true, "no question to the server, the guest's window")
dlg:Close()
RIGHTS = true
coop.has_host_rights, coop.operator_command = nil, nil

print(string.format("%d passed, %d failed", PASSES, FAILS))
