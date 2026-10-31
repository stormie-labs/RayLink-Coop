-- Anomaly Coop temp test (W4 menu, window "Chronicle + map" 2026-10-30): coop_menu.script window logic and session handling,
-- modxml_coop_menu.script button injection, coop_menu_options.script options page. Engine and UI are stand-ins (menu_stubs.lua);
-- coop_games, coop_menu_kit and the themes are the real scripts. Not shipped.
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

print("== coop_menu: validation")
local m = load_module("coop_menu")
check(m.check_nick("  Strelok ") == "Strelok", "nick trimmed")
check(m.check_nick("") == nil and m.check_nick(string.rep("a", 33)) == nil, "nick length 1..32")
check(m.check_nick("a;b") == nil and m.check_nick('a"b') == nil and m.check_nick("a|b") == nil, "nick bad characters")
check(m.check_nick("\207\240\232\226\229\242") ~= nil, "cp1251 nick accepted")
check(m.check_port("27960") == 27960 and m.check_port(" 1 ") == 1, "port parse")
check(m.check_port("0") == nil and m.check_port("65536") == nil and m.check_port("12.5") == nil
	and m.check_port("abc") == nil, "port range/int")
check(m.check_address("192.168.1.10") == "192.168.1.10", "ip")
check(m.check_address(" 203.0.113.5:27960 ") == "203.0.113.5:27960", "ip:port trimmed")
check(m.check_address("host.example:5000") == "host.example:5000", "name:port")
check(m.check_address("[::1]:27960") == "[::1]:27960", "ipv6 in brackets")
check(m.check_address("::1") == nil and m.check_address("1.2.3.4:99999") == nil and m.check_address("") == nil
	and m.check_address("a b") == nil and m.check_address("a;b") == nil, "bad addresses")

print("== coop_menu: storage")
check(m.get_port() == 27960, "default port from the engine")
axr_main.config:w_value("options", "coop/coop_player/host_port", 28000)
check(m.get_port() == 28000, "port from [options]: set on the options page")
for _, a in ipairs({ "1.1.1.1", "2.2.2.2:1", "3.3.3.3", "1.1.1.1", "4.4.4.4", "5.5.5.5", "6.6.6.6" }) do
	m.remember_address(a)
end
local r = m.get_recent()
check(#r == 5 and r[1] == "6.6.6.6" and r[4] == "1.1.1.1" and r[5] == "3.3.3.3",
	"recent: newest first, re-used moves up, unique, 5 max (" .. table.concat(r, " ") .. ")")
check(axr_main.config.data["coop_menu&recent"]:find("|", 1, true) ~= nil, "recent stored in [coop_menu]")
check(m.get_nick() == "winuser", "nick falls back to the engine's effective nick")
CONSOLE.coop_nick = "Strelok"
check(m.get_nick() == "Strelok", "nick from the console variable the options page sets")

print("== coop_menu: texts")
check(m.phase_text({ phase = "off" }) == "No session running", "phase off")
check(m.phase_text({ phase = "hosting", port = 27960 }) == "Session open, port 27960", "phase hosting")
check(m.phase_text({ phase = "connecting", address = "1.2.3.4", port = 5 }) == "Connecting to 1.2.3.4:5...", "phase connecting")
check(m.phase_text({ phase = "receiving-world" }) == "Downloading the host's world...", "phase with dash")
local no_text = {}
for _, ph in ipairs({ "off", "hosting", "connecting", "handshaked", "receiving-world", "loading-world", "live" }) do
	if not STRINGS["st_coop_menu_phase_" .. ph:gsub("%-", "_")] then no_text[#no_text + 1] = ph end
end
for _, c in ipairs({ "ProtocolMismatch", "BuildMismatch", "ContentMismatch", "DuplicateKey", "SessionFull",
	"HostNotReady", "Kicked", "Timeout", "Malformed", "lost", "start" }) do
	if not STRINGS["st_coop_menu_reason_" .. c] then no_text[#no_text + 1] = c end
end
check(#no_text == 0, "every engine phase and reason code has a string (" .. table.concat(no_text, ",") .. ")")
check(m.error_text({ active = false, last_error = "host is not in a game", last_error_code = "HostNotReady" })
	== "Error: the host is not in a loaded game (host is not in a game)", "refusal text")
check(m.error_text({ active = false, last_error = "left the session", last_error_code = "left", last_by_user = true })
	== "Session closed.", "own disconnect is not an error")
check(m.error_text({ active = false, last_error = "connect timeout", last_error_code = "lost" })
	== "Error: connection lost (connect timeout)", "lost text")
check(m.error_text({ active = false, last_error = "weird", last_error_code = "Nope" }) == "Error: weird", "unknown code: raw text")
check(m.error_text({ active = true, last_error = "x", last_error_code = "lost" }) == "", "no error while active")
local pl = m.player_rows({ players = {
	{ id = 1, nick = "me", is_self = true, rtt = 0 },
	{ id = 0, nick = "boss", is_host = true, rtt = 44.6 },
	{ id = 2, nick = "new", joined = false, rtt = 80 } } })
check(pl[1].nick == "me" and pl[1].sub == "you" and pl[2].sub == "host, 44 ms" and pl[3].sub == "joining, 80 ms", "player rows: who and the ping")
check(m.player_rows({ players = { { nick = "a%c[red]", is_self = true } } })[1].nick:find("%", 1, true) == nil, "a nick cannot inject text formatting")

print("== coop_menu: status line (kind, texts)")
local two = { { id = 0, nick = "boss", is_self = true, is_host = true, rtt = 0 }, { id = 1, nick = "Guest", rtt = 30 } }
check(m.status_kind({ phase = "off" }) == "idle" and m.status_kind({ phase = "hosting", active = true }) == "live"
	and m.status_kind({ phase = "live", active = true }) == "live", "idle / live kinds")
local waits = {}
for _, ph in ipairs({ "connecting", "handshaked", "receiving-world", "loading-world" }) do
	if m.status_kind({ phase = ph, active = true }) ~= "wait" then waits[#waits + 1] = ph end
end
check(#waits == 0 and m.status_kind({ phase = "off", active = false, pending_host = 27960 }) == "wait",
	"every phase on the way and a pending host are 'wait' (" .. table.concat(waits, ",") .. ")")
local v = m.status_view({ phase = "off", players = {}, max_players = 8 }, nil)
check(v.kind == "idle" and v.title == "No session running" and v.detail == "" and v.dim == false, "no session")
v = m.status_view({ phase = "hosting", active = true, host = true, port = 27960, max_players = 8, players = two }, nil)
check(v.kind == "live" and v.title == "Session open, port 27960"
	and v.detail == "Partner's address: your IP, port 27960 (UDP)  |  Players: 2 of 8", "hosting: address for the partner and the player count")
v = m.status_view({ phase = "live", active = true, client = true, address = "1.2.3.4", port = 5, max_players = 8, players = two }, nil)
check(v.kind == "live" and v.title == "In the host's world (1.2.3.4:5)" and v.detail == "Players: 2 of 8", "client in the world")
v = m.status_view({ phase = "connecting", active = true, client = true, address = "1.2.3.4", port = 5, players = {} }, nil)
check(v.kind == "wait" and v.title == "Connecting to 1.2.3.4:5..." and v.detail == "", "connecting")
v = m.status_view({ phase = "off", active = false, pending_host = 27961, players = {} }, nil)
check(v.kind == "wait" and v.title == "Waiting for the world to load"
	and v.detail == "The session opens on port 27961 as soon as the game is loaded.", "pending host")
v = m.status_view({ phase = "off", active = false, players = {}, last_error = "x", last_error_code = "HostNotReady" }, nil)
check(v.kind == "error" and v.title == "Error: the host is not in a loaded game (x)" and v.detail == "No session running",
	"a refusal is an error: red, with the phase under it")
v = m.status_view({ phase = "off", active = false, players = {}, last_error = "left", last_error_code = "left", last_by_user = true }, nil)
check(v.kind == "idle" and v.dim == true and v.title == "Session closed.", "own disconnect: a plain grey status, not an error")
v = m.status_view({ phase = "off", players = {} }, "Enter the host address: IP or IP:port.")
check(v.kind == "error" and v.title == "Enter the host address: IP or IP:port.", "a local message is an error")

print("== coop_menu: window in the cold-start main menu")
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

local function open_window() MENU.cb["btn_coop#17"].f(MENU.cb["btn_coop#17"].obj) end
local function frames(dlg, n, ms)
	for _ = 1, n do
		NOW = NOW + (ms or 16)
		dlg:Update()
	end
end
local function flat_shown(c) return c.btn.shown and c.list[1].shown end
local function flat_hidden(c) return not c.btn.shown and not c.list[1].shown end

standard_games()
m.on_main_menu_init(MENU)
check(MENU.cb["btn_coop#17"] and MENU.cb["msg_box#30"] and MENU.cb["msg_box#31"], "main menu callbacks registered")
SAVES_LISTED, BLOCK_READS = 0, 0
open_window()
local dlg = MENU.coop_menu_dlg
check(dlg ~= nil and dlg.shown and not MENU.shown, "Co-op opens the window over the hidden main menu")
check(#MISSING_PATHS == 0, "every xml path exists in ui_coop_chronicle.xml (" .. table.concat(MISSING_PATHS, ", ") .. ")")
check(LOG and not log_has("tick failed") and not log_has("refresh failed"), "nothing failed so far")
check(SAVES_LISTED == 1 and BLOCK_READS == 0, "opening reads the folder once and no save: it never stalls")
check(dlg.edit_address.text == "6.6.6.6", "the address field holds the last address")
check(dlg.who.text == "Strelok", "the nick is a small line; it is set on the options page")
check(dlg.games[1].title == "With Kent" and dlg.game.id == "g1", "the newest game is selected")
frames(dlg, 1)
check(BLOCK_READS == 2, "the saves are read a couple per frame")
frames(dlg, 5)
check(BLOCK_READS == 6 and #dlg.saves == 5, "and all of them in a few frames")
check(dlg.rows[1].title.text == "With Kent" and dlg.rows[1].sub.text == "Swamps, 29 Oct, 23:38" and dlg.rows[1].hist_n.text == "5", "a row: title, place and time, the count")
check(dlg.rows[2].title.text:find("24 Oct", 1, true) and dlg.rows[2].hist_n.text == "1", "a game without a title: its date")
check(dlg.rows[1].patch.texture == "ui_mm_faction_stalker" and dlg.rows[2].patch.texture == "ui_mm_faction_dolg", "the patch of the faction")
check(dlg.rows[3].root.shown == false and dlg.add_row.root.shown, "only the rows of the games, and New game under them")
check(dlg.h1.text == "With Kent" and dlg.meta[1].text == "Swamps" and dlg.meta[2].text == "Loners"
	and dlg.meta[3].text == "29 Oct, 23:38" and dlg.meta[4].text == "stormie, kent", "the title and the meta line")
check(dlg.play_text.text == "PLAY" and dlg.btn_play.enabled, "Play")
check(dlg.tile_loc.text == "Swamps" and dlg.tile_count.text == "Saves: 5", "the tile's caption")
check(dlg.hero.layers[dlg.hero.on].tex and dlg.hero.layers[dlg.hero.on].tex:find("k00_marsh", 1, true), "the art of the newest level")
check(dlg.btn_gear.enabled == false and dlg.gear.list[1].shown, "no game settings window yet: the gear stays, disabled")
do
	-- live 2026-10-30: "Bolot." The engine cuts a text unless it is shorter than its window, and these windows are its width.
	local cut = 0
	for _, t in ipairs(dlg.meta) do if t.ellipsis then cut = cut + 1 end end
	check(cut == 0, "the meta line is not cut when it fits")
	-- live 2026-10-30: a grey square at the corner of a button. A 3-state button keeps its template's size for its textures.
	local files = 0
	for _ in pairs(USED_PATHS) do files = files + 1 end
	check(USED_PATHS.tpl_none and not USED_PATHS.tpl_hit, "every hit window is the invisible template")
	dlg.btn_connect.hot = true
	dlg.ui:hover()
	check(dlg.ui.hot[1] ~= nil, "hover is painted by the script")
	dlg.btn_connect.hot = false
	dlg.ui:hover()
end
check(dlg.status_phase.text == "No session running" and dlg.status_dot.tcolor == dlg.ui:color("idle"), "status off: grey dot")
check(flat_shown(dlg.connect) and flat_hidden(dlg.disconnect) and flat_hidden(dlg.cancel), "no session: the way to a friend, no Disconnect, no Cancel")
check(dlg.hint.shown and dlg.hint.text:find("RayLink", 1, true), "Steam lives in the launcher: a hint, no tab")
check(flat_hidden(dlg.host_now) and not dlg.open_hint.shown, "no game loaded: no Open button, no hint")
check(not dlg.tl_block.shown and dlg.clip.shown and dlg.tile_block.shown, "closed: the tile, no timeline")

print("== the map opens, by the clock")
local T = dlg.T
local A = T.anim
click(dlg, "btn_tile")
check(dlg.open and dlg.btn_tile.enabled == false, "the tile opens the map and takes no more clicks")
frames(dlg, 1, A.map_open + A.route + A.route_delay + A.stop_last_delay)
check(dlg.tl_block.shown and dlg.tile_block.shown == false, "the timeline is in, the tile is gone")
check(dlg.tl_rows[1].time.text == "23:38" and dlg.tl_rows[1].loc.text == "Swamps" and dlg.tl_rows[1].tag.text == "latest", "the first row of the chronicle")
check(dlg.tl_rows[5].time.text == "21:45" and dlg.tl_rows[5].loc.text == "Bar" and not dlg.tl_rows[6].root.shown, "the oldest row, and no more")
check(dlg.tl_sub.text == "29 Oct, saves: 5", "under the heading")
check(dlg.note.text == STRINGS.st_coop_menu_note_last and flat_hidden(dlg.roll), "the newest save: nothing to go back to")
check(#dlg.route == 4 and dlg.route[1].level == "l05_bar" and dlg.route[4].level == "k00_marsh", "the route: four stops, oldest first")
check(dlg.stop_w[1].root.shown and dlg.stop_w[4].last and not dlg.stop_w[5].root.shown, "a widget per stop, the last one is the newest")
check(dlg.stop_w[4].patch.texture == "ui_mm_faction_stalker" and dlg.stop_w[4].patch.shown and not dlg.stop_w[4].fill.shown, "the newest stop is the patch of the game")
check(dlg.dots[1].shown and #dlg.dots > 5, "the dots of the route are on the map")
check(dlg.others[1].root.shown and dlg.others[1].id == "g2" and dlg.others[1].patch.texture == "ui_mm_faction_dolg", "another game: a small patch")
click(dlg, "btn_other_1")
check(dlg.game.id == "g2" and dlg.h1.text == dlg.games[2].title, "a click on it picks that game")
click(dlg, "btn_row_1")
check(dlg.game.id == "g1", "and back from the rail")
frames(dlg, 1, 2000)
click(dlg, "btn_stop_3") -- Cordon
check(dlg.pick == 3 and dlg.saves[dlg.pick].level == "l01_escape", "a stop picks its save")
frames(dlg, 1, 1000)
check(dlg.tl_rows[3].bg.tcolor == dlg.ui:color("pick") and dlg.tl_rows[1].bg.tcolor == dlg.ui:color("pick", 0), "and the row lights up")
check(dlg.more.shown and dlg.note.text == "The world goes back to 22:45. Newer saves stay." and flat_shown(dlg.roll), "the row opens: a picture, a note, Go back here")
check(dlg.thumb.texture and dlg.thumb.texture:find("l01_escape", 1, true) and dlg.thumb.trect ~= nil, "the art of that save, cropped")
click(dlg, "btn_tl_5")
check(dlg.pick == 5, "a row picks the save")
frames(dlg, 1, 1000)
check(dlg.stop_w[1].here and not dlg.stop_w[3].here and dlg.stop_w[1].time.text == "21:45", "and its stop: the stop shows the time of that save")
click(dlg, "btn_fold")
frames(dlg, 1, A.map_open + A.timeline_slide)
check(not dlg.open and not dlg.tl_block.shown and dlg.tile_block.shown and dlg.btn_tile.enabled, "Fold closes it; the tile is back")
click(dlg, "btn_hist_1")
check(dlg.open, "the history button of the game on the screen opens the map")
click(dlg, "btn_hist_1")
check(not dlg.open, "and folds it")
click(dlg, "btn_hist_2")
check(dlg.open and dlg.game.id == "g2", "the history button of another game selects it and opens the map")
dlg:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not dlg.open and dlg.shown, "Escape folds the map first")
click(dlg, "btn_row_1")

print("== animations: real time, the theme's numbers")
do
	frames(dlg, 1, 3000)
	click(dlg, "btn_tile")
	frames(dlg, 1, 1)
	-- an exe without SetClipChildren: no opening animation
	check(dlg.has_clip == false and dlg.map_t == 1, "an exe without clipping: the map just appears")
	check(dlg.map_c.trect.x1 == 0 and dlg.map_c.trect.x2 == dlg.tex_w, "the whole texture, the map at its full size")
	click(dlg, "btn_fold")
	frames(dlg, 1, 1)
	check(dlg.map_t == 0 and dlg.map_c.trect.x2 - dlg.map_c.trect.x1 < dlg.tex_w / 2, "closed: the static of the tile shows a part of the texture")
	local tile = dlg.tile_stage
	local kx = dlg.tex_w / (T.map.w * dlg.map_z)
	check(math.abs((dlg.map_c.trect.x2 - dlg.map_c.trect.x1) / kx - tile.w) < 1e-6, "that part is the size of the tile at the scale of the map")
end

print("== a new exe: the clip window, the fonts")
do
	ENGINE_CLIP = true
	local fonts_asked, registered = {}, {}
	local target
	function RegisterFont(name, tex, shader, height) registered[#registered + 1] = name .. "=" .. tex; target = height; check(shader == "font", "the shader is named: nil is not checked"); return true end
	function GetFontByName(name) fonts_asked[name] = true; return name ~= "menu_head" and ("font:" .. name) or nil end
	function GetFontGraffiti22Russian() return "stock:graffiti22" end
	function GetFontLetterica16Russian() return "stock:letterica16" end
	local w = m.UICoopMenu(MENU)
	w:Reset()
	check(w.has_clip == true and w.clip.clip == true, "the map window clips its children")
	check(#registered == 6 and registered[1]:find("menu_title=", 1, true), "the theme's fonts are registered")
	check(w.h1.font == "font:menu_title", "a font by its role")
	check(w.tl_rows[1].time.font == "font:menu_time", "another role")
	check(w.play_text.font == "stock:graffiti22", "a font the engine does not have: the stock one of the role")
	check(target == 1080 * w.L.s, "the fonts are asked for the height of the stage, not of the screen")
	check(w.modal_root.flush == true and w.modal_root.clip == nil, "the dialog sends the queued text out first")
	frames(w, 1, 3000)
	local a = T.anim
	local tile_w = w.clip.w
	check(math.abs(tile_w - w.L:w(T.layout.tile.w)) < 1e-6 and w.clip.shown, "closed: the clip window is the tile")
	click(w, "btn_tile")
	frames(w, 1, a.map_open / 2)
	local mid = w.clip.w
	check(mid > tile_w and mid < 1024, "half way the window is between the tile and the screen (" .. mid .. ")")
	check(w.map_t > .5 and w.map_t < .95, "the swing curve is ahead of a straight line (" .. w.map_t .. ")")
	frames(w, 1, a.map_open / 2 + 1)
	check(math.abs(w.clip.w - 1024) < 1e-6 and math.abs(w.clip.h - 768) < 1e-6, "open: the whole screen")
	check(w.map_z < 1, "the real distances: the map zooms out until the route fits (" .. w.map_z .. ")")
	local lo, hi = 1e9, -1e9
	for _, st in ipairs(w.route) do
		local y = w.cam.y1 + st.y
		lo, hi = math.min(lo, y), math.max(hi, y)
	end
	check(hi - lo <= T.map.fit.h + 1e-6, "from the first stop to the last it fits the free part of the screen")
	check(lo > w.view.top, "the oldest stop is on the screen (" .. lo .. ".." .. hi .. ")")
	local cx = w.layer.pos.x
	check(math.abs(w.map_c.pos.x - cx) < 1e-6 and math.abs(w.map_c.pos.y - w.layer.pos.y) < 1e-6, "the map and its markers move together as the camera")
	check(math.abs(w.layer.pos.x - w.L:w(w.cam.x1)) < 1e-6, "the camera ends on the route")
	click(w, "btn_fold")
	frames(w, 1, a.map_close / 2)
	check(w.map_t > 0 and w.map_t < 1, "closing takes its own time")
	frames(w, 1, a.map_close / 2 + 1)
	check(math.abs(w.clip.w - tile_w) < 1e-6, "and folds back, no slower than it opened")
	check(dlg ~= nil and a.map_close <= a.map_open, "closing is never slower than opening")
	-- the rows come one after another, 50 ms apart
	click(w, "btn_tile")
	local t0 = NOW
	NOW = t0 + a.tl_delay + a.tl_rise / 2
	w:Update()
	local alpha1, alpha4 = w.tl_rows[1].time.talpha, w.tl_rows[4].time.talpha
	check(alpha1 > alpha4, "the rows of the chronicle appear in steps (" .. alpha1 .. " > " .. alpha4 .. ")")
	check(w.tl_rows[1].time.color == w.ui:color("text"), "a fade leaves the colour alone: SetTextAlpha, no reparse")
	NOW = t0 + a.route_delay + a.route / 2
	w:Update()
	local on, off = 0, 0
	for i = 1, #w.dot_list do if w.dots[i].shown then on = on + 1 else off = off + 1 end end
	check(on > 0 and off > 0, "the dots of the route appear in order (" .. on .. " of " .. #w.dot_list .. ")")
	check(w.dots[1].shown and not w.dots[#w.dot_list].shown, "from its start")
	NOW = t0 + a.stop_delay + 10
	w:Update()
	check(math.floor(w.stop_w[1].line.tcolor / 16777216) < 255, "a stop fades in")
	NOW = t0 + 5000
	w:Update()
	check(math.floor(w.stop_w[1].line.tcolor / 16777216) == 255, "and is there")
	-- the art drifts while it is on the screen: its texture rectangle moves
	click(w, "btn_fold")
	NOW = NOW + 5000
	w:Update()
	local r1 = w.hero.layers[w.hero.on].w.trect
	NOW = NOW + 5000
	w:Update()
	local r2 = w.hero.layers[w.hero.on].w.trect
	check(r1 and r2 and r1.x1 ~= r2.x1, "the art drifts")
	ENGINE_CLIP = nil
	RegisterFont, GetFontByName, GetFontGraffiti22Russian, GetFontLetterica16Russian = nil, nil, nil, nil
end

print("== motion off: every state at once")
do
	local real = coop_menu_theme_base.load
	coop_menu_theme_base.load = function()
		local t = real()
		t.motion = false
		t.layout.tile.x = 1400
		t.colors.accent = { 1, 2, 3 }
		return t
	end
	ENGINE_CLIP = true
	local w = m.UICoopMenu(MENU)
	w:Reset()
	frames(w, 1, 16)
	click(w, "btn_tile")
	frames(w, 1, 1)
	check(w.map_t == 1 and w.tl_block.shown, "the map is open at once")
	check(w.ui:color("accent") == GetARGB(255, 1, 2, 3), "the window takes its colours from the theme")
	click(w, "btn_fold")
	frames(w, 1, 1)
	check(math.abs(w.tile_block.pos.x - w.L:x(1400, 1)) < 1e-6, "and its layout: a pack moves the tile without touching the logic")
	coop_menu_theme_base.load = real
	ENGINE_CLIP = nil
end

print("== aspects: the window on other screens")
do
	for _, sc in ipairs({ { 1024, 768 }, { 1680, 1050 }, { 2560, 1080 } }) do
		SCREEN = { w = sc[1], h = sc[2] }
		local w = m.UICoopMenu(MENU)
		w:Reset()
		frames(w, 8, 16)
		local L = w.L
		local p = w.rows[1].patch
		check(math.abs(p.w * sc[1] / 1024 - p.h * sc[2] / 768) < 1e-6, sc[1] .. "x" .. sc[2] .. ": a patch is square on the screen")
		local bar = w.bar_block
		check(math.abs(bar.pos.x) < 1e-6 and math.abs(bar.w - 1024) < 1e-6 and math.abs(bar.pos.y + bar.h - 768) < 1e-6, "the bar stands on the whole bottom edge")
		check(math.abs(w.rail_block.pos.y - L:h(T.layout.rail.y)) < 1e-6, "the rail keeps to the top")
		local tl = w.tl_block
		check(math.abs(tl.pos.y) < 1e-6 and math.abs(tl.h + L:h(T.layout.bar.h) - 768) < 1e-6, "the timeline runs from the top to the bar")
		click(w, "btn_tile")
		frames(w, 1, 4000)
		check(math.abs(w.tl_block.pos.x + tl.w - 1024) < 1e-6 or tl.pos.x + tl.w <= 1024 + 1e-6, "open, the timeline ends at the right edge")
		local first = w.open_shade[1].w
		check(math.abs(first.pos.x - L:x(0)) < 1e-6 and math.abs(first.w - L:w(1920)) < 1e-6, "the open shade lies over the stage: the lit part is the same everywhere")
		check(#w.open_shade == (L.ox > 0 and 4 or 2), "with bands beside it when the screen is wider")
		check(w.cam.x1 <= T.map.lit.x1 and w.cam.x1 + T.map.w * w.map_z >= T.map.lit.x2, "the lit part shows the map itself, never its mirrored copy")
	end
	SCREEN = { w = 1920, h = 1080 }
end

print("== a long meta line ends in dots at the edge of its block, and only then")
do
	standard_games()
	CARDS[1].faction = "stalker"
	BLOCKS.coop_auto_g1_1.at.players = { string.rep("very_long_nick", 30) }
	open_window()
	frames(dlg, 8)
	check(dlg.meta[4].ellipsis == true and dlg.meta[1].ellipsis == false, "the list of players is cut, the place is not")
	check(dlg.meta[4].pos.x + dlg.meta[4].w <= dlg.L:w(T.layout.title.w) + 1e-6, "and it stays inside the block")
end

print("== hover: a veil of the theme over the whole control")
do
	standard_games()
	open_window()
	frames(dlg, 8)
	dlg.btn_connect.hot = true
	frames(dlg, 1)
	dlg.btn_connect.hot = false
	frames(dlg, 1)
	dlg.btn_connect.enabled = false
	dlg.btn_connect.hot = true
	frames(dlg, 1)
	check(pcall(dlg.ui.hover, dlg.ui), "a disabled control has no hover")
	dlg.btn_connect.hot = false
	dlg.btn_connect.enabled = true
end

print("== the art does not flicker when the window opens again")
do
	standard_games()
	open_window()
	frames(dlg, 8)
	local tex = dlg.hero.tex
	check(tex and tex:find("k00_marsh", 1, true), "the art of the game")
	dlg:Close()
	open_window()
	check(dlg.hero.tex == tex, "opening again keeps it while the saves are being read")
	frames(dlg, 8)
	check(dlg.hero.tex == tex, "and after")
end

print("== Play and going back, outside a session")
standard_games()
open_window()
frames(dlg, 8)
EXEC, CALLS, RINGS = {}, {}, {}
MENU.calls = {}
click(dlg, "btn_play")
check(CALLS[#CALLS] == "pending 28000", "Play: the host waits for the level")
check(RINGS[#RINGS] == "g1", "the autosaves are told the game before the host waits")
check(EXEC[#EXEC - 1] == "main_menu off" and EXEC[#EXEC] == "start server(coop_auto_g1_1/single/alife/load) client(localhost)", "and the newest save of the game loads")
check(not dlg.shown and MENU.shown, "the window is closed")
INFO.pending_host = nil
open_window()
frames(dlg, 8)
click(dlg, "btn_tile")
click(dlg, "btn_tl_3")
EXEC, CALLS, RINGS = {}, {}, {}
click(dlg, "btn_roll")
check(CALLS[#CALLS] == "pending 28000" and EXEC[#EXEC] == "start server(coop_auto_g1_3/single/alife/load) client(localhost)", "Go back here: the picked save")
check(RINGS[#RINGS] == "g1", "and the ring of the game")
INFO.pending_host = nil
ALIFE = {}
open_window()
frames(dlg, 8)
EXEC = {}
click(dlg, "btn_play")
check(#EXEC == 1 and EXEC[1] == "load coop_auto_g1_1", "with a world running: the stock load")
ALIFE = nil
INFO.pending_host = nil

print("== a save that cannot be loaded")
standard_games()
SAVES[#SAVES].size = 100 -- the newest save of g1 was cut short
SAVES[#SAVES - 1].size = 100
open_window()
frames(dlg, 8)
EXEC = {}
click(dlg, "btn_play")
check(EXEC[#EXEC]:find("coop_auto_g1_3", 1, true), "Play passes over damaged saves")
INFO.pending_host = nil
standard_games()
for _, s in ipairs(SAVES) do s.size = 100 end
open_window()
frames(dlg, 8)
frames(dlg, 1, 300)
check(dlg.btn_play.enabled == false, "nothing to load: Play is off")
click(dlg, "btn_tile")
check(dlg.tl_rows[1].tag.text == "damaged" and dlg.note.text == STRINGS.st_coop_menu_note_damaged and flat_hidden(dlg.roll), "and the row says why")
click(dlg, "btn_fold")
do -- a click before the scan is done still gets the right save
	standard_games()
	open_window()
	EXEC = {}
	click(dlg, "btn_play")
	check(EXEC[#EXEC]:find("coop_auto_g1_1", 1, true) ~= nil, "Play right after the opening finishes the reading itself")
	INFO.pending_host = nil
end

print("== new game: a name, then the stock screen")
standard_games()
open_window()
frames(dlg, 8)
MENU.calls, CALLS = {}, {}
click(dlg, "btn_add")
check(dlg.modal == "new" and dlg.modal_root.shown and dlg.edit_title.enabled and dlg.edit_title.shown, "a small dialog with a field")
check(dlg.modal_title.text == "New game" and #MENU.calls == 0, "nothing starts yet")
click(dlg, "btn_modal_no")
check(not dlg.modal and not dlg.modal_root.shown and dlg.edit_title.enabled == false, "Cancel closes it; the hidden field takes nothing")
click(dlg, "btn_add")
do
	-- live 2026-10-30: the edit box of the dialog takes the keys when it has the focus; the dialog comes first
	local base = CUIScriptWnd.OnKeyboard
	CUIScriptWnd.OnKeyboard = function() return true end
	dlg:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
	check(not dlg.modal and dlg.shown, "Escape closes the dialog at once, not the window, even with the field in focus")
	click(dlg, "btn_add")
	dlg.edit_title.text = ""
	local n = #MENU.calls
	dlg:OnKeyboard(DIK_keys.DIK_RETURN, ui_events.WINDOW_KEY_PRESSED)
	CUIScriptWnd.OnKeyboard = base
	check(#MENU.calls == n + 1 and MENU.calls[#MENU.calls] == "new", "Enter in the field goes on")
	coop_games.take_new_title()
	INFO.pending_host = nil
	open_window()
end
click(dlg, "btn_add")
dlg.edit_title.text = "  Into the Zone  "
RINGS = {}
click(dlg, "btn_modal_ok")
check(CALLS[#CALLS] == "pending 28000" and MENU.calls[#MENU.calls] == "new", "the name, then pending host + the stock new game screen")
check(RINGS[#RINGS] == "", "a new game has no id yet: the old ring until its record is in force")
check(coop_games.take_new_title() == "Into the Zone", "the title waits for the record of the new game")
check(not dlg.shown and MENU.shown, "window closed, main menu back")
INFO.pending_host = nil
open_window()
click(dlg, "btn_add")
dlg.edit_title.text = ""
click(dlg, "btn_modal_ok")
check(MENU.calls[#MENU.calls] == "new" and coop_games.take_new_title() == nil, "an empty name is allowed")
INFO.pending_host = nil

print("== empty state: no games")
reset_world()
open_window()
frames(dlg, 8)
check(#dlg.games == 0 and dlg.game == nil, "no games")
check(dlg.h1.text == STRINGS.st_coop_menu_empty_title and dlg.empty_text.text == STRINGS.st_coop_menu_empty_text, "the screen says what to do")
check(dlg.play_text.text == STRINGS.st_coop_menu_empty_btn and dlg.btn_play.enabled, "a clear call to create the first game")
check(dlg.btn_play.w >= dlg.play_text.w + dlg.L:w(T.layout.title.play_pad * 2), "the button is as wide as its caption (live 2026-10-30: it stuck out)")
check(not dlg.tile_block.shown and not dlg.clip.shown and not dlg.tl_block.shown, "the map stays closed")
check(dlg.rows[1].root.shown == false and dlg.add_row.root.shown, "the rail has only New game")
click(dlg, "btn_play")
check(dlg.modal == "new", "the call opens the dialog of a new game")
click(dlg, "btn_modal_no")
click(dlg, "btn_tile")
check(not dlg.open, "nothing to open")

print("== connect: the way to a friend")
standard_games()
open_window()
frames(dlg, 8)
check(flat_shown(dlg.recent_toggle) and not dlg.recent_pop.shown, "recent addresses are folded under the field")
click(dlg, "btn_recent_toggle")
check(dlg.recent_pop.shown and dlg.recent_row[1].text.text == "6.6.6.6" and dlg.recent_row[2].text.text == "5.5.5.5", "the list of the last addresses")
click(dlg, "btn_recent_3")
check(dlg.edit_address.text == "4.4.4.4" and not dlg.recent_pop.shown, "a click fills the address and folds the list")
check(dlg.btn_recent_1 == nil and dlg.recent_btn[1].enabled == false, "the hidden list takes no clicks")
dlg.edit_address.text = "not an address"
click(dlg, "btn_connect")
check(dlg.local_error == "Enter the host address: IP or IP:port." and dlg.status_error.text == dlg.local_error, "bad address refused")
check(dlg.status_error.shown and not dlg.status_phase.shown and dlg.status_dot.tcolor == dlg.ui:color("error"), "a real error: red text, red dot")
dlg.edit_address.text = "10.0.0.7:28001"
CONSOLE.coop_nick = "bad;nick"
click(dlg, "btn_connect")
check(dlg.local_error == STRINGS.st_coop_menu_err_nick and CALLS[#CALLS] ~= "connect 10.0.0.7:28001", "an unusable nick refused: the error says where to set it")
check(STRINGS.st_coop_menu_err_nick:find("options", 1, true) ~= nil, "on the options page")
CONSOLE.coop_nick = "Mechenyi"
click(dlg, "btn_connect")
check(CALLS[#CALLS] == "connect 10.0.0.7:28001", "connect")
check(m.get_recent()[1] == "10.0.0.7:28001", "address remembered")
INFO = { phase = "connecting", active = true, client = true, address = "10.0.0.7", port = 28001, nick = "Mechenyi",
	max_players = 8, players = {} }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Connecting to 10.0.0.7:28001..." and dlg.status_dot.tcolor == dlg.ui:color("wait")
	and not dlg.status_error.shown, "status connecting: amber dot")
check(dlg.btn_connect.enabled == false and dlg.edit_address.enabled == false and flat_shown(dlg.disconnect)
	and dlg.btn_disconnect ~= nil or dlg.disconnect.btn.enabled, "busy: inputs locked, Disconnect appears")
check(flat_hidden(dlg.connect) and not dlg.edit_address.shown and not dlg.hint.shown, "the way to a friend is gone")
dlg:OnConnect()
check(dlg.local_error:find("Disconnect from the current session") ~= nil, "second connect refused")
dlg.local_error = nil
-- refused by the host
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {},
	last_error = "the host's mod list differs", last_error_code = "ContentMismatch" }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_error.text:find("your mod list differs") ~= nil and dlg.status_error.shown and dlg.status_dot.tcolor == dlg.ui:color("error")
	and flat_hidden(dlg.disconnect), "refusal shown in red, no Disconnect without a session")
-- the player closed it himself: a plain grey status
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {},
	last_error = "left the session", last_error_code = "left", last_by_user = true }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Session closed." and dlg.status_phase.shown and dlg.status_phase.color == dlg.ui:color(T.text.status_sub.color)
	and not dlg.status_error.shown and dlg.status_dot.tcolor == dlg.ui:color("idle"), "'Session closed.' is a grey status, not an error")

print("== pending host: Cancel")
standard_games()
INFO.pending_host = 27961
open_window()
check(dlg.status_phase.text == "Waiting for the world to load" and dlg.status_detail.text
	== "The session opens on port 27961 as soon as the game is loaded." and dlg.status_dot.tcolor == dlg.ui:color("wait"), "pending shown: amber dot")
check(flat_shown(dlg.cancel) and flat_hidden(dlg.disconnect) and flat_shown(dlg.connect), "pending: Cancel, no Disconnect, a friend can still be joined")
coop.host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end
click(dlg, "btn_cancel_pending")
check(CALLS[#CALLS] == "pending nil" and flat_hidden(dlg.cancel) and dlg.status_dot.tcolor == dlg.ui:color("idle"), "cancel pending")

print("== window in game (host this game)")
standard_games()
LEVEL = true
ALIVE = true
db.actor = { alive = function() return ALIVE end }
open_window()
frames(dlg, 8)
check(flat_shown(dlg.host_now) and dlg.btn_host_now.enabled and not dlg.open_hint.shown, "level loaded: the Open button appears")
HOST_RESULT, HOST_WHY = false, "could not host on port 28000 (is it used by another program?), see the log"
click(dlg, "btn_host_now")
check(CALLS[#CALLS] == "host 28000" and dlg.status_error.text:find("used by another program") ~= nil, "host failure shown")
HOST_RESULT = true
RINGS, ENSURE = {}, "g1"
click(dlg, "btn_host_now")
check(RINGS[#RINGS] == "g1", "a world opened to partners: its record, made now if it has none, names the ring")
ENSURE = nil
RINGS = {}
INFO.pending_host = nil
dlg:OnHostNow()
check(RINGS[#RINGS] == "", "no record can be made: the old ring")
ENSURE = "g1"
RUNNING = "g1"
INFO = { phase = "hosting", active = true, host = true, port = 28000, nick = "Mechenyi", self_id = 0, max_players = 8,
	players = { { id = 0, nick = "Mechenyi", is_self = true, is_host = true, rtt = 0, joined = true },
		{ id = 1, nick = "Guest", rtt = 35, joined = true } } }
dlg.local_error = nil
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Session open, port 28000" and dlg.status_dot.tcolor == dlg.ui:color("live"), "hosting status: green dot")
check(dlg.status_detail.text == "Partner's address: your IP, port 28000 (UDP)  |  Players: 2 of 8", "address for the partner and the players")
check(flat_shown(dlg.disconnect) and flat_hidden(dlg.host_now) and flat_hidden(dlg.connect) and flat_hidden(dlg.play), "a session is open: Disconnect appears, Open and Play are gone")
check(dlg.rows[1].title.text == "Mechenyi" and dlg.rows[1].sub.text == "you, host" and dlg.rows[2].title.text == "Guest" and dlg.rows[2].sub.text == "35 ms", "the rail shows the players with their ping")
check(dlg.rows[1].btn.enabled == false and not dlg.rows[1].patch.shown and not dlg.add_row.root.shown and dlg.btn_add.enabled == false, "and is not a list of games any more")
INFO.players[2].rtt = 80
NOW = NOW + 1000
dlg:Update()
check(dlg.rows[2].sub.text == "80 ms", "the ping follows")

print("== a session belongs to the running game")
do
	standard_games()
	LEVEL, ALIVE = true, true
	db.actor = { alive = function() return true end }
	open_window()
	frames(dlg, 8)
	click(dlg, "btn_row_2")
	check(dlg.game.id == "g2", "another game is on the screen")
	RUNNING = "g1"
	INFO = { phase = "hosting", active = true, host = true, port = 28000, nick = "x", max_players = 8, players = two }
	frames(dlg, 1, 300)
	check(dlg.game.id == "g1" and dlg.h1.text == "With Kent", "the session opens: the window goes to the game that runs, its saves are the ones to go back to")
	click(dlg, "btn_tile")
	frames(dlg, 1, 3000)
	check(dlg.others[1].id == "g2", "the patch of another game is still on the map")
	click(dlg, "btn_other_1")
	check(dlg.game.id == "g1", "but in a session a click on it changes nothing")
	-- a world without a card: nothing to go back to here
	RUNNING = "not_in_the_list"
	open_window()
	frames(dlg, 8)
	check(dlg.game == nil and not dlg.title_block.shown and not dlg.clip.shown, "a host whose world has no card sees no other game's saves")
	RUNNING = "g1"
	INFO = { phase = "off", active = false, nick = "x", max_players = 8, players = {} }
	LEVEL = false
	db.actor = nil
end
standard_games()
LEVEL = true
ALIVE = true
db.actor = { alive = function() return ALIVE end }
RUNNING = "g1"
INFO = { phase = "hosting", active = true, host = true, port = 28000, nick = "Mechenyi", self_id = 0, max_players = 8,
	players = { { id = 0, nick = "Mechenyi", is_self = true, is_host = true, rtt = 0, joined = true },
		{ id = 1, nick = "Guest", rtt = 35, joined = true } } }
open_window()
frames(dlg, 8)

print("== the timeline in a session: the host goes back, with a question")
click(dlg, "btn_tile")
frames(dlg, 1, 3000)
check(dlg.tl_block.shown, "the host has the timeline")
click(dlg, "btn_tl_2")
frames(dlg, 1, 1000)
check(flat_shown(dlg.roll), "and can go back")
RESTORED, HOLD, RINGS = {}, {}, {}
click(dlg, "btn_roll")
check(dlg.modal == "confirm" and #RESTORED == 0, "a question first")
check(dlg.modal_text.text:find("22:53", 1, true) and not dlg.edit_title.shown, "it names the save; no field")
check(HOLD[#HOLD] == true, "the autosaves wait")
local held = #HOLD
frames(dlg, 2)
check(#HOLD == held + 2, "as long as the question stands")
click(dlg, "btn_modal_no")
check(HOLD[#HOLD] == false and #RESTORED == 0, "No: nothing happens, the autosaves go on")
click(dlg, "btn_roll")
RESTORE_RESULT = "damaged"
click(dlg, "btn_modal_ok")
check(RESTORED[#RESTORED] == "coop_auto_g1_2|g1" and dlg.local_error == STRINGS.st_coop_saves_restore_failed_damaged, "a refused restore says why")
dlg.local_error = nil
RESTORE_RESULT = true
click(dlg, "btn_roll")
RINGS = {}
click(dlg, "btn_modal_ok")
check(RESTORED[#RESTORED] == "coop_auto_g1_2|g1" and not dlg.shown, "yes: coop_saves.restore of that save; the load closes the menu, nothing of ours stays")
check(RINGS[#RINGS] == "g1", "going back keeps the ring of the game")
dlg.shown = true
dlg.modal = nil
-- a client: no timeline, no game of his own
standard_games()
LEVEL, RUNNING = false, nil
INFO = { phase = "live", active = true, client = true, host = false, address = "10.0.0.7", port = 28001, nick = "Mechenyi", max_players = 8, players = two }
open_window()
frames(dlg, 8)
check(not dlg.title_block.shown and not dlg.clip.shown and not dlg.tile_block.shown, "a client: no game on the screen, no map")
check(dlg.rows[1].title.text == "boss" and dlg.status_phase.text == "In the host's world (10.0.0.7:28001)", "the players and the address")
check(flat_shown(dlg.disconnect) and not dlg.edit_address.shown, "Disconnect")
click(dlg, "btn_disconnect")
check(CALLS[#CALLS] == "disconnect", "Disconnect leaves the session")
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {} }
-- dead actor
standard_games()
LEVEL, ALIVE = true, false
open_window()
check(flat_hidden(dlg.host_now) and dlg.open_hint.shown and dlg.open_hint.text:find("dead", 1, true), "dead actor: no Open button, the hint says why")
ALIVE = true
dlg:Refresh()
check(flat_shown(dlg.host_now) and not dlg.open_hint.shown, "alive again: the Open button is back")
LEVEL = false
db.actor = nil
-- quit wrappers
INFO.active = true
MENU.cb["msg_box#30"].f(MENU)
check(CALLS[#CALLS] == "disconnect" and MENU.calls[#MENU.calls] == "quit_game", "quit game leaves the session first")
local nc = #CALLS
INFO.active = false
MENU.cb["msg_box#31"].f(MENU)
check(#CALLS == nc and MENU.calls[#MENU.calls] == "quit_win", "quit to windows without a session: stock only")
-- F3: a session that started under the window ends the old in-game menu
standard_games()
LEVEL = true
db.actor = { alive = function() return true end }
open_window()
INFO = { phase = "hosting", active = true, host = true, port = 28000, nick = "x", max_players = 8, players = {} }
EXEC = {}
dlg:Close()
check(EXEC[#EXEC] == "main_menu off", "a session started while the in-game menu was open: the old menu ends with the window")
LEVEL = false
db.actor = nil
INFO = { phase = "off", active = false, nick = "x", max_players = 8, players = {} }
-- escape closes
open_window()
dlg:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not dlg.shown and MENU.shown, "Escape closes the window")

print("== wheel: long lists")
reset_world()
for i = 1, 12 do CARDS[i] = { id = "g" .. i, name = "S", title = "Game " .. i, created = "2026-10-29 20:31" } end
for i = 1, 30 do add_save("g1", "s" .. i, "k00_marsh", string.format("29/10/2026 20:%02d", i)) end
open_window()
frames(dlg, 20)
check(dlg.rows[#dlg.rows].title.text == "Game " .. #dlg.rows, "the rail shows what fits")
dlg:OnMouse(50, 300, ui_events.WINDOW_MOUSE_WHEEL_DOWN)
check(dlg.rows[1].title.text == "Game 2", "the wheel over the rail scrolls the games")
check(dlg:OnMouse(50, 300, ui_events.WINDOW_MOUSE_WHEEL_UP) == false and dlg.rows[1].title.text == "Game 1", "and back")
dlg:OnMouse(50, 300, ui_events.WINDOW_MOUSE_WHEEL_UP)
check(dlg.rows[1].title.text == "Game 1", "it stops at the end")
click(dlg, "btn_tile")
frames(dlg, 1, 3000)
check(dlg.tl_more.text:find("more", 1, true) ~= nil, "a long chronicle says there is more")
local first = dlg.tl_rows[1].time.text
dlg:OnMouse(1000, 300, ui_events.WINDOW_MOUSE_WHEEL_DOWN)
check(dlg.tl_rows[1].time.text ~= first, "the wheel over the chronicle scrolls it")
dlg:PickSave(30)
check(dlg.tl_first > 1 and dlg.tl_rows[dlg.tl_slots].i == 30, "a save picked on the map comes into view")
SAVES = {}
dlg:SetOpen(false)

print("== the timeline: the day between rows")
do
	local mk = function(day, hm) return { name = "s" .. day .. hm, stamp = day .. "/10/2026 " .. hm, t = hm, level = "k00_marsh", level_text = "Swamps" } end
	local keep_saves, keep_first, keep_pick = dlg.saves, dlg.tl_first, dlg.pick
	dlg.saves = { mk(30, "19:21"), mk(29, "23:38"), mk(29, "23:28"), mk(29, "22:53"), mk(28, "21:00") }
	dlg.tl_first, dlg.pick = 1, 1
	dlg:BindTimeline()
	local rows = dlg.tl_rows
	check(rows[1].gap_on == false, "nothing over the newest row: the header has its day")
	check(dlg.tl_sub.text:find("30 Oct", 1, true) ~= nil, "the header keeps the newest save's date")
	check(rows[2].gap_on == true and rows[2].gap.text == "29 Oct", "the older day over its first row, the save's own date")
	check(rows[3].gap_on == false, "ten minutes: nothing")
	check(rows[4].gap_on == true and rows[4].gap.text == "35 min without saves", "a long time without saves")
	check(rows[5].gap_on == true and rows[5].gap.text == "28 Oct", "the next day")
	dlg:AnimTimeline(NOW)
	local B = dlg.T.layout.timeline
	local L = dlg.L
	check(math.abs(rows[2].root.pos.y - rows[1].root.pos.y - L:h(B.row_h + B.gap_h)) < .01, "the line takes its room")
	check(math.abs(rows[3].root.pos.y - rows[2].root.pos.y - L:h(B.row_h)) < .01, "a row without one none")

	local many = {}
	for i = 1, 30 do many[i] = mk(30 - math.floor((i - 1) / 2), string.format("%02d:00", 20 - (i % 2))) end
	dlg.saves = many
	dlg.tl_first, dlg.pick = 1, 1
	dlg:BindTimeline()
	local room = dlg.tl_room
	local used = 0
	for slot = 1, dlg.tl_slots do used = used + B.row_h + (rows[slot].gap_on and B.gap_h or 0) end
	check(used <= room, "the rows and their lines fit the same room: " .. used .. " of " .. room)
	dlg:PickSave(30, NOW)
	check(rows[dlg.tl_slots].i == 30, "the last save comes into view")
	check(rows[1].gap_on == true and rows[1].gap.text ~= "", "the top row of a scrolled list says its day")
	dlg.tl_first = 40
	dlg:BindTimeline()
	check(dlg.tl_first + dlg.tl_slots - 1 == 30, "no scrolling past the end")
	dlg.saves, dlg.tl_first, dlg.pick = keep_saves, keep_first, keep_pick
	dlg:BindTimeline()
end

print("== modxml_coop_menu: button injection into ui_mm_main_16.xml")
-- minimal dxml xml_obj over the stock file
local function parse_dom(file)
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
	fh:close()
	local root = { el = "!doc", kids = {} }
	local stack = { root }
	for close, tag, attrs, selfclose in src:gmatch("<(/?)([%w_]+)([^>]-)(/?)>") do
		if close == "/" then
			table.remove(stack)
		else
			local el = "<" .. tag
			for k, v in attrs:gmatch('([%w_]+)="([^"]*)"') do el = el .. " " .. k .. "=" .. v end
			local node = { el = el, kids = {}, parent = stack[#stack] }
			table.insert(stack[#stack].kids, node)
			if selfclose ~= "/" then stack[#stack + 1] = node end
		end
	end
	return root
end
local function xml_obj_over(root)
	local o = {}
	local function walk(n, name, out)
		for _, k in ipairs(n.kids) do
			if k.el:match("^<([%w_]+)") == name then out[#out + 1] = k end
			walk(k, name, out)
		end
		return out
	end
	function o:query(name) return walk(root, name, {}) end
	function o:iterateChildren(el, cb) for i, v in ipairs(el.kids) do if cb(v, i) then return end end end
	function o:getElement(v)
		local name, rest = v.el:match("^<([%w_]+)(.*)$")
		local attr = {}
		for k, val in rest:gmatch("([%w_]+)=(%S+)") do attr[k] = val end
		return { name = name, attr = attr }
	end
	function o:insertElement(args, where, pos)
		local el = "<" .. args.name
		for k, v in pairs(args.attr) do el = el .. " " .. k .. "=" .. v end
		pos = pos or #where.kids + 1
		table.insert(where.kids, pos, { el = el, kids = {}, parent = where })
	end
	return o
end
local function names(list_node, o)
	local out = {}
	for _, k in ipairs(list_node.kids) do out[#out + 1] = o:getElement(k).attr.name end
	return table.concat(out, ",")
end
XML_CB, MM_CB = nil, nil
XML_CBS = {}
function RegisterScriptCallback(name, f)
	if name == "on_xml_read" then
		XML_CBS[#XML_CBS + 1] = f
		XML_CB = XML_CBS[1]
	elseif name == "main_menu_on_init" then
		MM_CB = f
	end
end
OPT_INSTALLED = 0
coop_menu_options = { install = function() OPT_INSTALLED = OPT_INSTALLED + 1 end }
local mx = load_module("modxml_coop_menu")
mx.on_xml_read()
check(XML_CB == mx.inject_button and MM_CB == mx.main_menu_init and OPT_INSTALLED == 1, "seams registered")
-- W5: the chat key binding entry is added here (cold-start main menu too), once
check(XML_CBS[2] == mx.inject_keybinding, "key binding seam registered")
do
	local inserted = {}
	local xobj = {
		query = function(_, q)
			if q == "group[name=kb_grp_common]" then return { { kids = { 1, 2 } } } end
			if q == "command[id=kb_coop_chat]" then return inserted end
			return {}
		end,
		insertFromXMLString = function(_, s) inserted[#inserted + 1] = s end,
	}
	mx.inject_keybinding([[ui\ui_keybinding.xml]], xobj)
	mx.inject_keybinding([[ui\ui_keybinding.xml]], xobj)
	mx.inject_keybinding([[ui\something.xml]], xobj)
	check(#inserted == 1 and inserted[1]:find('exe="chat"', 1, true) ~= nil, "chat key binding entry added once")
end
local dom = parse_dom(REF .. "configs/ui/ui_mm_main_16.xml")
local xo = xml_obj_over(dom)
mx.inject_button([[ui\ui_mm_main_16.xml]], xo)
mx.inject_button([[ui\ui_mm_main_16.xml]], xo) -- second pass (ui_mm_main.xml includes it): no duplicate
check(names(xo:query("menu_main")[1], xo) == "btn_newgame,btn_load,btn_lastsave,btn_coop,btn_options,btn_originals,btn_quit",
	"menu_main: before btn_options, once")
check(names(xo:query("menu_main_single")[1], xo):find("btn_save,btn_coop,btn_options", 1, true) ~= nil, "in game list")
check(names(xo:query("menu_main_single_dead")[1], xo):find("btn_coop", 1, true) ~= nil, "dead list")
check(names(xo:query("menu_main_mm")[1], xo):find("btn_coop", 1, true) == nil, "multiplayer list untouched")
check(names(xo:query("menu_main_logout")[1], xo):find("btn_coop", 1, true) == nil, "logout list untouched")
local before = names(xo:query("menu_main")[1], xo)
mx.inject_button([[ui\ui_options.xml]], xo)
check(names(xo:query("menu_main")[1], xo) == before, "other files ignored")
local saved = coop
coop = nil
XML_CB = nil
mx.on_xml_read()
check(XML_CB == nil, "vanilla exe: nothing registered")
coop = saved

print("== coop_menu_options: page")
ui_options = { options = {} }
function ui_options.init_opt_base() ui_options.options = { { id = "video" }, { id = "sound" } } end
local mo = load_module("coop_menu_options")
mo.install()
mo.install()
ui_options.init_opt_base()
local ids = {}
for _, t in ipairs(ui_options.options) do ids[#ids + 1] = t.id end
check(table.concat(ids, ",") == "video,sound,coop", "page appended once after the stock tree (" .. table.concat(ids, ",") .. ")")
ui_options.init_opt_base()
check(#ui_options.options == 3, "rebuild: still one page")
local page = ui_options.options[3]
local p = page.gr[1]
-- game settings (T4): the host's rules are a game's settings, the page is the player's group only
check(p.id == "coop_player" and p.sh and #page.gr == 1, "one group: the player's")
local keys = {}
for _, g in ipairs(page.gr) do
	for _, o in ipairs(g.gr) do
		if o.type ~= "slide" and o.type ~= "desc" then
			keys[#keys + 1] = "ui_mm_coop_" .. g.id .. "_" .. o.id
		elseif o.text then
			keys[#keys + 1] = o.text
		end
		if o.type == "list" then
			-- the stock UIOptions:GetContent: a table, or { f } -> f() (build 10: coop_death_share)
			local content = type(o.content[1]) == "function" and o.content[1]() or o.content
			for _, c in ipairs(content) do keys[#keys + 1] = c[2] end
		end
	end
end
local missing = {}
for _, k in ipairs(keys) do if not STRINGS[k] then missing[#missing + 1] = k end end
check(#missing == 0, "every option caption has a string (" .. table.concat(missing, ",") .. ")")
local miss_desc = {}
for _, k in ipairs(keys) do
	if k:find("^ui_mm_coop_") and not STRINGS[k .. "_desc"] then miss_desc[#miss_desc + 1] = k end
end
check(#miss_desc == 0, "every option has a description (" .. table.concat(miss_desc, ",") .. ")")
-- tree built before install (another addon called init_opt_base early)
ui_options = { options = { { id = "video" } } }
function ui_options.init_opt_base() ui_options.options = { { id = "video" } } end
local mo2 = load_module("coop_menu_options")
mo2.install()
check(#ui_options.options == 2 and ui_options.options[2].id == "coop", "early tree gets the page at install")

-- every string id used by coop_menu.script exists
print("== strings")
local fh = assert(io.open(ROOT .. "scripts/coop_menu.script", "r"))
local src = fh:read("*a")
fh:close()
local fg = assert(io.open(ROOT .. "scripts/coop_games.script", "r"))
local gsrc = fg:read("*a")
fg:close()
local fk = assert(io.open(ROOT .. "scripts/coop_ui_kit.script", "r"))
src = src .. fk:read("*a")
fk:close()
local used, absent = 0, {}
for id in (src .. gsrc):gmatch('"(st_coop_[%w_]+)"') do
	if id:sub(-1) ~= "_" then -- prefixes completed at run time are checked by the texts tests
		used = used + 1
		if not STRINGS[id] then absent[#absent + 1] = id end
	end
end
check(used > 10 and #absent == 0, used .. " ids used by coop_menu.script and coop_games.script exist (" .. table.concat(absent, ",") .. ")")
for mo = 1, 12 do check(STRINGS["st_coop_menu_month_" .. mo] ~= nil, "month " .. mo) end
local fx = assert(io.open(ROOT .. "configs/ui/ui_coop_chronicle.xml", "r"))
local xsrc = fx:read("*a")
fx:close()
local unused = {}
for path in pairs(XML_FILES["ui_coop_chronicle.xml"]) do
	if path:find("^tpl_[%w_]+$") and not USED_PATHS[path] then unused[#unused + 1] = path end
end
table.sort(unused)
check(#unused == 0, "every template of ui_coop_chronicle.xml is used by the script (" .. table.concat(unused, ", ") .. ")")
for tpl in src:gmatch('"(tpl_[%w_]+)"') do
	if tpl:sub(-1) ~= "_" then check(XML_FILES["ui_coop_chronicle.xml"][tpl], "template " .. tpl .. " exists") end
end
for _, tpl in ipairs({ "tpl_text_l", "tpl_text_c", "tpl_text_r", "tpl_text_m" }) do
	check(XML_FILES["ui_coop_chronicle.xml"][tpl], "template " .. tpl .. " exists")
end
-- every texture id of the window and of the themes is in the atlas description (tools\make_menu_icons.py)
local fd = assert(io.open(ROOT .. "configs/ui/textures_descr/ui_coop_menu.xml", "r"))
local dsrc = fd:read("*a")
fd:close()
local atlas = {}
for id in dsrc:gmatch('<texture id="([^"]+)"') do atlas[id] = true end
local no_tex = {}
local look = src
for _, file in ipairs({ ROOT .. "scripts/coop_menu_theme_base.script", ROOT .. "scripts/coop_menu_theme.script", "gamedata_gamma/scripts/coop_menu_theme.script" }) do
	local ft = assert(io.open(file, "r"))
	look = look .. ft:read("*a")
	ft:close()
end
for id in look:gmatch('"(coop_menu_[%w_]+)"') do
	if id ~= "coop_menu_white" and not atlas[id] and not id:find("^coop_menu_theme") and id ~= "coop_menu_kit" then no_tex[#no_tex + 1] = id end
end
for id in xsrc:gmatch(">(coop_menu_[%w_]+)<") do
	if not atlas[id] and not (atlas[id .. "_e"] and atlas[id .. "_d"] and atlas[id .. "_t"] and atlas[id .. "_h"]) then no_tex[#no_tex + 1] = id end
end
check(#no_tex == 0 and atlas.coop_menu_white, "every coop_menu_* texture is in the atlas (" .. table.concat(no_tex, ",") .. ")")
-- rus has the same ids
local rus = {}
for _, file in ipairs({ "st_coop_menu.xml", "st_coop_death.xml", "st_coop_hud.xml", "st_coop_saves.xml", "st_coop_netgraph.xml" }) do
	local fr = assert(io.open(ROOT .. "configs/text/rus/" .. file, "rb"))
	local rsrc = fr:read("*a")
	fr:close()
	for id in rsrc:gmatch('<string id="([^"]+)">') do rus[id] = true end
end
local diff = {}
for id in pairs(STRINGS) do
	if id:find("^st_coop") or id:find("^ui_") then
		if not rus[id] then diff[#diff + 1] = id end
	end
end
for id in pairs(rus) do if not STRINGS[id] then diff[#diff + 1] = id end end
check(#diff == 0, "rus and eng tables have the same ids (" .. table.concat(diff, ",") .. ")")

print("== a record made after the list was read")
standard_games()
INFO = { phase = "off", active = false, nick = "x", max_players = 8, players = {} }
open_window()
frames(dlg, 8)
CARDS[#CARDS + 1] = { id = "g3", name = "Stalker", title = "Fresh", faction = "stalker", created = "2026-10-30 20:00", last_played = "2026-10-30 20:00" }
RUNNING = "g3"
INFO = { phase = "hosting", active = true, host = true, port = 28000, nick = "x", max_players = 8, players = {} }
frames(dlg, 1, 300)
check(dlg.game ~= nil and dlg.game.id == "g3" and dlg.guest == false, "open to partners made a record: the window shows its game")
RUNNING = nil
INFO = { phase = "off", active = false, nick = "x", max_players = 8, players = {} }

print("== closing shows the menu whatever happens to the art")
standard_games()
open_window()
frames(dlg, 8)
do
	local owner = dlg.owner
	local dialog, show = owner.ShowDialog, owner.Show
	local got = {}
	owner.coop_view = { take_art = function() error("no art") end }
	owner.ShowDialog = function() got.dialog = true end
	owner.Show = function() got.show = true end
	dlg:Close()
	check(got.dialog and got.show, "a failure of the art leaves the menu on the screen")
	owner.coop_view, owner.ShowDialog, owner.Show = nil, dialog, show
end

print("== a hover outlasts the fade of the frame")
standard_games()
open_window()
frames(dlg, 60)
dlg.btn_tile.hot = true
frames(dlg, 3)
check(dlg.tile_lines[1].tcolor == dlg.ui:color("accent"), "the outline of the tile stays accented")
dlg.btn_tile.hot = false
frames(dlg, 3)
check(dlg.tile_lines[1].tcolor == dlg.ui:color("tile_line"), "and goes back")
click(dlg, "btn_tile")
frames(dlg, 1, 3000)
dlg:OnTimelineRow(3)
frames(dlg, 60)
dlg.btn_roll.hot = true
frames(dlg, 3)
check(dlg.roll.list[1].tcolor == dlg.ui:color("accent_hi"), "the go back button lights up")
dlg.btn_roll.hot = false
frames(dlg, 3)
check(dlg.roll.list[1].tcolor == dlg.ui:color("accent"), "and goes back")
dlg:Close()

print("== a title lives as long as its start")
standard_games()
coop_games.set_new_title("Abandoned")
open_window()
check(coop_games.take_new_title() == nil, "opening the window forgets a title of a start that never came")
do
	local keep = coop.host_when_ready
	coop.host_when_ready = function() return false, "busy" end
	dlg:OnNewGame()
	dlg.edit_title:SetText("Typed")
	dlg:OnModalOk()
	check(coop_games.take_new_title() == nil, "a start that failed leaves no title")
	coop.host_when_ready = keep
end
dlg:Close()

print("== Play reads no more than it needs")
standard_games()
open_window()
do
	local reads = BLOCK_READS
	dlg:OnPlay()
	check(BLOCK_READS - reads < 5, "the save is found before the end of the folder (" .. (BLOCK_READS - reads) .. ")")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
