-- Anomaly Coop temp test (W4 menu, window redesign 2026-10-23): coop_menu.script window logic, modxml_coop_menu.script
-- button injection, coop_menu_options.script options page. Engine and UI are stand-ins (menu_stubs.lua). Not shipped.
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_menu.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu.xml")

-- strings: real ids from the eng table, "%s" kept
STRINGS = {}
do
	-- the option captions of the host's death rules (F3 task 15) are in st_coop_death.xml, next to the texts of coop_death;
	-- those of HUD v2 (compass, its field of view, the ping line) in st_coop_hud.xml; the Restore caption of the window
	-- (F3 task 17) in st_coop_saves.xml
	for _, file in ipairs({ "st_coop_menu.xml", "st_coop_death.xml", "st_coop_hud.xml", "st_coop_saves.xml" }) do
		local fh = assert(io.open(ROOT .. "configs/text/eng/" .. file, "r"))
		local src = fh:read("*a")
		fh:close()
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	end
end
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
function exec_console_cmd(cmd)
	EXEC[#EXEC + 1] = cmd
	local n = cmd:match("^coop_nick (.+)$")
	if n then CONSOLE.coop_nick = n end
end
axr_main = { config = config_stub() }
LEVEL = false
level = { present = function() return LEVEL end }
db = {}

-- the saves folder, as the stock "last save" reads it (ui_main_menu.script: file_list_open_ex, newest first), and the
-- coop_saves module (the autosave list, the details of one save)
FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 5 }
function bit_or(a, b) return a + b end
SAVES, SAVES_LISTED = {}, 0
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
	}
end
AUTOS, AUTOS_LISTED, DETAILED, LEVEL_NAMES = {}, 0, {}, {}
coop_saves = {
	text = function(key) return STRINGS["st_coop_saves_" .. key] or key end,
	list_autosaves = function() AUTOS_LISTED = AUTOS_LISTED + 1; return AUTOS end,
	details = function(e) DETAILED[#DETAILED + 1] = e.name; e.level_text = LEVEL_NAMES[e.name]; return e end,
}

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
m.set_port(28000)
check(m.get_port() == 28000 and axr_main.config.data["options&coop/coop_player/host_port"] == "28000", "port stored in [options]")
for _, a in ipairs({ "1.1.1.1", "2.2.2.2:1", "3.3.3.3", "1.1.1.1", "4.4.4.4", "5.5.5.5", "6.6.6.6" }) do
	m.remember_address(a)
end
local r = m.get_recent()
check(#r == 5 and r[1] == "6.6.6.6" and r[4] == "1.1.1.1" and r[5] == "3.3.3.3",
	"recent: newest first, re-used moves up, unique, 5 max (" .. table.concat(r, " ") .. ")")
check(axr_main.config.data["coop_menu&recent"]:find("|", 1, true) ~= nil, "recent stored in [coop_menu]")
check(m.get_nick() == "winuser", "nick falls back to the engine's effective nick")
check(m.set_nick("Strelok") and CONSOLE.coop_nick == "Strelok" and EXEC[#EXEC] == "cfg_save", "nick -> coop_nick + cfg_save")
local n_exec = #EXEC
m.set_nick("Strelok")
check(#EXEC == n_exec, "same nick: no console writes")

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
local pl = m.player_lines({ players = {
	{ id = 1, nick = "me", is_self = true, rtt = 0 },
	{ id = 0, nick = "boss", is_host = true, rtt = 44.6 },
	{ id = 2, nick = "new", joined = false, rtt = 80 } } })
check(pl[1] == "me (you)" and pl[2] == "boss (host)  -  44 ms" and pl[3] == "new (joining)  -  80 ms", "player lines")

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
local v = m.status_view({ phase = "off", players = {}, max_players = 8 }, nil, "host")
check(v.kind == "idle" and v.title == "No session running" and v.detail == "the partner's address appears here"
	and v.dim == false, "no session, host tab: placeholder for the partner's address")
v = m.status_view({ phase = "off", players = {}, max_players = 8 }, nil, "join")
check(v.kind == "idle" and v.detail == "", "no session, join tab: no address placeholder")
v = m.status_view({ phase = "hosting", active = true, host = true, port = 27960, max_players = 8, players = two }, nil, "host")
check(v.kind == "live" and v.title == "Session open, port 27960"
	and v.detail == "Partner's address: your IP, port 27960 (UDP)  |  Players: 2 of 8", "hosting: address for the partner and the player count")
v = m.status_view({ phase = "live", active = true, client = true, address = "1.2.3.4", port = 5, max_players = 8, players = two },
	nil, "join")
check(v.kind == "live" and v.title == "In the host's world (1.2.3.4:5)" and v.detail == "Players: 2 of 8", "client in the world")
v = m.status_view({ phase = "connecting", active = true, client = true, address = "1.2.3.4", port = 5, players = {} }, nil, "join")
check(v.kind == "wait" and v.title == "Connecting to 1.2.3.4:5..." and v.detail == "", "connecting")
v = m.status_view({ phase = "off", active = false, pending_host = 27961, players = {} }, nil, "host")
check(v.kind == "wait" and v.title == "Waiting for the world to load"
	and v.detail == "The session opens on port 27961 as soon as the game is loaded.", "pending host")
v = m.status_view({ phase = "off", active = false, players = {}, last_error = "x", last_error_code = "HostNotReady" }, nil, "join")
check(v.kind == "error" and v.title == "Error: the host is not in a loaded game (x)" and v.detail == "No session running",
	"a refusal is an error: red, with the phase under it")
v = m.status_view({ phase = "off", active = false, players = {}, last_error = "left", last_error_code = "left", last_by_user = true },
	nil, "host")
check(v.kind == "idle" and v.dim == true and v.title == "Session closed.", "own disconnect: a plain grey status, not an error")
v = m.status_view({ phase = "off", players = {} }, "Enter the host address: IP or IP:port.", "join")
check(v.kind == "error" and v.title == "Enter the host address: IP or IP:port.", "a local message is an error")

print("== coop_menu: last save (stock lookup)")
check(m.format_save_time("23/10/2026 16:46", 2026) == "23.10, 16:46", "this year: day.month, time")
check(m.format_save_time("05/01/2025 09:03", 2026) == "05.01.2025, 09:03", "another year keeps the year")
check(m.format_save_time("garbage", 2026) == "garbage", "an unknown format is shown as it is")
SAVES = {}
check(m.find_last_save() == nil, "no saves: nil")
SAVES = {
	{ file = "quicksave.scop", modif = 100, stamp = "20/10/2026 10:00", size = 5000000 },
	{ file = "coop_auto_2.scop", modif = 300, stamp = "23/10/2026 16:46", size = 4200000 },
	{ file = "old.scop", modif = 200, stamp = "21/10/2026 10:00", size = 5000000 },
}
LEVEL_NAMES = { coop_auto_2 = "Cordon" }
DETAILED = {}
local ls = m.find_last_save()
check(ls and ls.name == "coop_auto_2" and ls.file_time == "23/10/2026 16:46" and ls.level_text == "Cordon" and not ls.damaged,
	"the newest .scop of the saves folder (like the stock Last save), its level from coop_saves.details")
check(#DETAILED == 1 and DETAILED[1] == "coop_auto_2", "only the newest save is opened for its details")
DETAILED = {}
ls = m.find_last_save()
check(#DETAILED == 0 and ls.level_text == "Cordon" and not ls.damaged, "the same newest save is not opened again")
SAVES[2].stamp = "23/10/2026 17:00"
ls = m.find_last_save()
check(#DETAILED == 1 and ls.file_time == "23/10/2026 17:00", "a save written since is read again")
SAVES[2].stamp = "23/10/2026 16:46"
SAVES[2].size = 100
DETAILED = {}
ls = m.find_last_save()
check(ls and ls.damaged == true and #DETAILED == 0, "a file below the smallest plausible size is damaged and never opened")
SAVES = {}

print("== coop_menu: window in the cold-start main menu")
MENU = { calls = {} }
function MENU:ShowDialog() self.shown = true end
function MENU:HideDialog() self.shown = false end
function MENU:Show(b) self.visible = b end
function MENU:OnButton_load_clicked() self.calls[#self.calls + 1] = "load" end
function MENU:OnButton_last_save() self.calls[#self.calls + 1] = "last" end
function MENU:ShowFactionUI() self.calls[#self.calls + 1] = "new" end
function MENU:OnMessageQuitGame() self.calls[#self.calls + 1] = "quit_game" end
function MENU:OnMessageQuitWin() self.calls[#self.calls + 1] = "quit_win" end
MENU.cb = {}
function MENU:AddCallback(n, ev, f, obj) self.cb[n .. "#" .. ev] = { f = f, obj = obj } end
MENU.shown = true

m.on_main_menu_init(MENU)
check(MENU.cb["btn_coop#17"] and MENU.cb["msg_box#30"] and MENU.cb["msg_box#31"], "main menu callbacks registered")
SAVES_LISTED = 0
MENU.cb["btn_coop#17"].f(MENU.cb["btn_coop#17"].obj)
local dlg = MENU.coop_menu_dlg
local pal = m.palette()
check(dlg ~= nil and dlg.shown and not MENU.shown, "Co-op opens the window over the hidden main menu")
check(#MISSING_PATHS == 0, "every xml path exists in ui_coop_menu.xml (" .. table.concat(MISSING_PATHS, ", ") .. ")")
check(dlg.edit_nick.text == "Strelok" and dlg.edit_port.text == "28000" and dlg.edit_address.text == "6.6.6.6", "fields from storage")
check(dlg.subtitle.text == "The Zone for two - and more: up to 8 players", "subtitle: the player limit is the engine's")

-- the mode switch: segments, not buttons
check(dlg.tabs.steam.enabled == false and dlg.tabs.host.enabled and dlg.tabs.join.enabled, "Steam segment disabled")
check(dlg.seg.host.bar.shown and not dlg.seg.join.bar.shown and not dlg.seg.steam.bar.shown, "the chosen segment has the sand bar")
check(dlg.seg.host.f.tcolor == pal.seg_on and dlg.seg.join.f.tcolor == pal.seg_off and dlg.seg.steam.f.tcolor == pal.seg_off,
	"the chosen segment is lighter")
check(dlg.seg.host.f.color == pal.text and dlg.seg.join.f.color == pal.grey and dlg.seg.steam.f.color == pal.off,
	"caption colours: chosen / other / Steam (off)")

-- the port is folded away
check(dlg.edit_port.shown == false and dlg.cap_port.shown == false, "the port field is folded away")
check(dlg.port_toggle.text == "+ Advanced: port 28000" and dlg.port_toggle.shown, "the fold shows the port number")
click(dlg, "btn_port_toggle")
check(dlg.edit_port.shown and dlg.cap_port.shown and dlg.port_toggle.text == "- Advanced", "a click unfolds the port field")
click(dlg, "btn_port_toggle")
check(not dlg.edit_port.shown and not dlg.cap_port.shown and dlg.port_toggle.text == "+ Advanced: port 28000", "and folds it again")
dlg.edit_port.text = "29000"
dlg:Refresh()
check(dlg.port_toggle.text == "+ Advanced: port 29000", "the fold follows the typed port")
dlg.edit_port.text = "28000"
dlg:Refresh()

-- "How to start": three tiles; nothing saved yet
check(SAVES_LISTED == 1, "the saves folder is read once when the window opens")
check(dlg.btn_host_new.enabled and dlg.btn_host_load.enabled, "new game and load are available")
check(dlg.btn_host_last.enabled == false, "Continue is inactive without saves")
check(dlg.tile.last.desc.text == STRINGS.st_coop_menu_tile_last_none and dlg.tile.last.desc.text:find("No saves yet", 1, true),
	"and says why")
check(dlg.tile.last.title.color == pal.off and dlg.tile.last.b.tcolor == pal.border_off and dlg.tile.last.f.tcolor == pal.tile_off,
	"an inactive tile is dimmed")
check(dlg.tile.new.title.color == pal.sand and dlg.tile.new.b.tcolor == pal.sand_dim and dlg.tile.new.strip.shown
	and dlg.tile.new.badge.shown and dlg.tile.new.f.tcolor == pal.tile_new, "New game: the main tile (sand frame, bar, badge)")
check(dlg.tile.load.title.color == pal.text and dlg.tile.load.b.tcolor == pal.border and not dlg.tile.load.badge, "Load: a plain tile")

-- "Open it to partners" and "Restore" exist only when they apply
local function flat_shown(g) return g.b.shown and g.f.shown and g.btn.shown end
local function flat_hidden(g) return not g.b.shown and not g.f.shown and not g.btn.shown end
check(flat_hidden(dlg.flat.btn_host_now) and not dlg.open_hint.shown, "no game loaded: no Open button, no hint")
check(flat_hidden(dlg.flat.btn_restore), "no session: no Restore button")
check(flat_hidden(dlg.flat.btn_disconnect) and flat_hidden(dlg.flat.btn_cancel_pending) and flat_shown(dlg.flat.btn_close),
	"no session: only Close in the status line")

-- the status line and the box under the tiles
check(dlg.status_phase.text == "No session running" and dlg.status_phase.shown and not dlg.status_error.shown
	and dlg.status_phase.color == pal.text, "status off")
check(dlg.status_dot.tcolor == pal.dot_idle, "status off: grey dot")
check(dlg.status_detail.text == "the partner's address appears here", "status off: placeholder for the address")
check(dlg.info_title.text == "What happens next" and dlg.info_line[1].text:find("opens by itself", 1, true)
	and dlg.info_line[2].text:find("UDP port 28000", 1, true) and dlg.info_line[3].text:find("Only the host saves", 1, true)
	and dlg.info_line[1].shown and not dlg.status_scroll.shown, "the box says what happens next (host)")
check(dlg.recent_btn[1].shown == false and not dlg.btn_connect.shown, "join controls hidden on the host tab")

click(dlg, "tab_join")
check(dlg.tab == "join" and dlg.seg.join.bar.shown and not dlg.seg.host.bar.shown and dlg.seg.join.f.tcolor == pal.seg_on
	and dlg.seg.host.f.tcolor == pal.seg_off, "the segment bar follows the tab")
check(dlg.recent_btn[1].shown and dlg.recent_btn[5].shown and dlg.edit_address.shown and dlg.btn_connect.shown
	and not dlg.edit_port.shown and not dlg.port_toggle.shown, "join tab shows its controls, the port fold is a host thing")
-- Live 2026-10-24 (build 12): "I cannot type the host's address". The engine hands a click to every ENABLED child under
-- the cursor, shown or not (CUIWindow::OnMouseAction checks IsEnabled only), and an edit box passes the click on: the
-- hidden host tiles (28.5,198 - 643.5,322) lie over the address field and took it. A hidden control is never enabled.
check(dlg.edit_address.enabled and dlg.btn_host_new.enabled == false and dlg.btn_host_load.enabled == false
	and dlg.btn_host_last.enabled == false and dlg.btn_port_toggle.enabled == false and dlg.edit_port.enabled == false,
	"join tab: the hidden host tiles, the port fold and the port field take no clicks")
click(dlg, "tab_host")
check(dlg.edit_address.enabled == false and dlg.recent_btn[1].enabled == false and dlg.btn_connect.enabled == false
	and dlg.btn_host_new.enabled and dlg.btn_port_toggle.enabled, "host tab: the hidden join controls take no clicks")
click(dlg, "tab_join")
check(not dlg.btn_host_new.shown and not dlg.tile.new.f.shown and not dlg.tile.new.ico.shown and not dlg.open_hint.shown,
	"host controls are gone on the join tab")
check(dlg.info_line[1].text:find("connect to the host's address", 1, true) and dlg.info_line[3].text:find("host's world", 1, true),
	"the box says what happens next (join)")
check(dlg.recent_btn[2].text == "5.5.5.5", "recent button text")
check(dlg.status_detail.text == "", "join tab: no address placeholder")
click(dlg, "btn_recent_3")
check(dlg.edit_address.text == "4.4.4.4", "recent click fills the address")

-- connect: bad address, bad nick, good
dlg.edit_address.text = "not an address"
click(dlg, "btn_connect")
check(dlg.local_error == "Enter the host address: IP or IP:port." and dlg.status_error.text == dlg.local_error, "bad address refused")
check(dlg.status_error.shown and dlg.status_error.color == pal.error and not dlg.status_phase.shown
	and dlg.status_dot.tcolor == pal.dot_error, "a real error: red text, red dot")
dlg.edit_address.text = "10.0.0.7:28001"
dlg.edit_nick.text = ""
click(dlg, "btn_connect")
check(dlg.local_error:find("nickname") ~= nil and CALLS[#CALLS] ~= "connect 10.0.0.7:28001", "empty nick refused")
dlg.edit_nick.text = "Mechenyi"
click(dlg, "btn_connect")
check(CALLS[#CALLS] == "connect 10.0.0.7:28001" and CONSOLE.coop_nick == "Mechenyi", "connect with nick")
check(m.get_recent()[1] == "10.0.0.7:28001", "address remembered")
INFO = { phase = "connecting", active = true, client = true, address = "10.0.0.7", port = 28001, nick = "Mechenyi",
	max_players = 8, players = {} }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Connecting to 10.0.0.7:28001..." and dlg.status_dot.tcolor == pal.dot_wait
	and not dlg.status_error.shown, "status connecting: amber dot")
check(dlg.btn_connect.enabled == false and dlg.edit_nick.enabled == false and flat_shown(dlg.flat.btn_disconnect)
	and dlg.btn_disconnect.enabled, "busy: inputs locked, Disconnect appears")
click(dlg, "btn_connect")
check(dlg.local_error:find("Disconnect from the current session") ~= nil, "second connect refused")
dlg.local_error = nil
-- refused by the host
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {},
	last_error = "the host's mod list differs", last_error_code = "ContentMismatch" }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_error.text:find("your mod list differs") ~= nil and dlg.status_error.shown and dlg.status_dot.tcolor == pal.dot_error
	and flat_hidden(dlg.flat.btn_disconnect), "refusal shown in red, no Disconnect without a session")
-- the player closed it himself: a plain grey status
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {},
	last_error = "left the session", last_error_code = "left", last_by_user = true }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Session closed." and dlg.status_phase.shown and dlg.status_phase.color == pal.grey
	and not dlg.status_error.shown and dlg.status_dot.tcolor == pal.dot_idle, "'Session closed.' is a grey status, not an error")

-- host tab: pending host via "Load..."
click(dlg, "tab_host")
dlg.edit_port.text = "abc"
click(dlg, "btn_host_load")
check(dlg.local_error == "The port is a number from 1 to 65535." and #MENU.calls == 0, "bad port refused")
check(dlg.edit_port.shown and dlg.cap_port.shown, "a bad port unfolds the field so it can be fixed")
dlg.edit_port.text = "27961"
click(dlg, "btn_host_load")
check(CALLS[#CALLS] == "pending 27961" and MENU.calls[1] == "load", "load a save: pending host + stock load dialog")
check(not dlg.shown and MENU.shown and MENU.visible, "window closed, main menu back")
check(m.get_port() == 27961, "port remembered")
-- reopen: pending shown, cancel
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.port_toggle.text == "+ Advanced: port 27961" and not dlg.edit_port.shown, "the window opens with the port folded")
INFO.pending_host = 27961
dlg:Refresh()
check(dlg.status_phase.text == "Waiting for the world to load" and dlg.status_detail.text
	== "The session opens on port 27961 as soon as the game is loaded." and dlg.status_dot.tcolor == pal.dot_wait,
	"pending shown: amber dot")
check(flat_shown(dlg.flat.btn_cancel_pending) and flat_hidden(dlg.flat.btn_disconnect), "pending: Cancel in the status line, no Disconnect")
coop.host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end
click(dlg, "btn_cancel_pending")
check(CALLS[#CALLS] == "pending nil" and flat_hidden(dlg.flat.btn_cancel_pending) and dlg.status_dot.tcolor == pal.dot_idle,
	"cancel pending")
click(dlg, "btn_host_new")
check(MENU.calls[#MENU.calls] == "new" and CALLS[#CALLS] == "pending 27961", "new game: pending + stock new game screen")
MENU.cb["btn_coop#17"].f(MENU)
click(dlg, "btn_host_last")
check(MENU.calls[#MENU.calls] == "last", "last save: stock last save")

print("== coop_menu: Continue tile with saves")
local year = os.date("%Y")
SAVES = {
	{ file = "quicksave.scop", modif = 100, stamp = "20/10/" .. year .. " 10:00", size = 5000000 },
	{ file = "coop_auto_2.scop", modif = 300, stamp = "23/10/" .. year .. " 16:46", size = 4200000 },
}
LEVEL_NAMES = { coop_auto_2 = "Cordon" }
INFO = { phase = "off", active = false, nick = "Mechenyi", max_players = 8, players = {} }
SAVES_LISTED = 0
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.btn_host_last.enabled and dlg.tile.last.desc.text == "coop_auto_2  -  Cordon\\n23.10, 16:46",
	"Continue: name, level and date of the newest save")
check(dlg.tile.last.title.color == pal.text and dlg.tile.last.b.tcolor == pal.border and dlg.tile.last.f.tcolor == pal.tile,
	"an active tile is drawn normally")
NOW = NOW + 1000
dlg:Update()
dlg:Update()
check(SAVES_LISTED == 1, "polling does not read the saves folder again")
SAVES[2].file = "a_very_long_save_name_of_the_player_2026.scop"
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.tile.last.desc.text:find("a_very_long_save_name...", 1, true) ~= nil, "a long name is cut")
SAVES[2].file = "coop%c[red]x.scop"
MENU.cb["btn_coop#17"].f(MENU)
check(not dlg.tile.last.desc.text:find("%", 1, true), "a save name cannot inject text formatting into the tile")
SAVES[2].file = "coop_auto_2.scop"
SAVES[2].size = 100 -- cut short by a crash
DETAILED = {}
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.btn_host_last.enabled == false and dlg.tile.last.desc.text == STRINGS.st_coop_menu_tile_last_bad and #DETAILED == 0,
	"a damaged newest save: inactive tile, the reason, the file is not opened")
SAVES = {}
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.btn_host_last.enabled == false, "back to no saves")
INFO = { phase = "hosting", active = true, host = true, port = 27961, nick = "Mechenyi", max_players = 8, players = {} }
SAVES = { { file = "coop_auto_2.scop", modif = 300, stamp = "23/10/" .. year .. " 16:46", size = 4200000 } }
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.btn_host_last.enabled == false and dlg.btn_host_new.enabled == false and dlg.btn_host_load.enabled == false
	and dlg.tile.new.b.tcolor == pal.border_off, "in a running session the three tiles are inactive")
INFO = { phase = "off", active = false, nick = "Mechenyi", max_players = 8, players = {} }
SAVES = {}

print("== coop_menu: window in game (host this game)")
LEVEL = true
ALIVE = true
db.actor = { alive = function() return ALIVE end }
MENU.cb["btn_coop#17"].f(MENU)
check(flat_shown(dlg.flat.btn_host_now) and dlg.btn_host_now.enabled and dlg.open_hint.shown
	and dlg.open_hint.text == "Is a game loaded right now?", "level loaded: the Open button and its hint appear")
check(dlg.info_line[2].text:find("UDP port 27961", 1, true), "the port in the box follows the settings")
HOST_RESULT, HOST_WHY = false, "could not host on port 27961 (is it used by another program?), see the log"
click(dlg, "btn_host_now")
check(CALLS[#CALLS] == "host 27961" and dlg.status_error.text:find("used by another program") ~= nil, "host failure shown")
HOST_RESULT = true
click(dlg, "btn_host_now")
INFO = { phase = "hosting", active = true, host = true, port = 27961, nick = "Mechenyi", self_id = 0, max_players = 8,
	players = { { id = 0, nick = "Mechenyi", is_self = true, is_host = true, rtt = 0, joined = true },
		{ id = 1, nick = "Guest", rtt = 35, joined = true } } }
NOW = NOW + 1000
dlg:Update()
check(dlg.status_phase.text == "Session open, port 27961" and dlg.status_dot.tcolor == pal.dot_live and dlg.status_phase.color == pal.text,
	"hosting status: green dot")
check(dlg.status_detail.text == "Partner's address: your IP, port 27961 (UDP)  |  Players: 2 of 8", "address for the partner and the players")
check(flat_shown(dlg.flat.btn_disconnect) and flat_hidden(dlg.flat.btn_host_now) and not dlg.open_hint.shown,
	"a session is open: Disconnect appears, Open is gone")
check(dlg.info_title.text == "Players: 2 of 8" and dlg.status_scroll.shown and not dlg.info_line[1].shown,
	"the box shows the players instead of the steps")
check(#dlg.status_scroll.children == 2 and dlg.status_scroll.children[2].text == "Guest  -  35 ms", "players with ping")
local rows_before = dlg.status_scroll.children
NOW = NOW + 1000
dlg:Update()
check(dlg.status_scroll.children == rows_before, "player rows not rebuilt when nothing changed")
-- Restore: the host of a running session, and only with autosaves
AUTOS, AUTOS_LISTED = {}, 0
INFO.host = false
dlg:Refresh()
INFO.host = true
dlg:Refresh()
check(flat_hidden(dlg.flat.btn_restore), "host, no autosaves: no Restore button")
AUTOS = { { name = "coop_auto_3" }, { name = "coop_auto_2" }, { name = "coop_auto_1" } }
INFO.host = false
dlg:Refresh()
INFO.host = true
dlg:Refresh()
check(flat_shown(dlg.flat.btn_restore) and dlg.btn_restore.enabled and dlg.btn_restore.text == STRINGS.st_coop_saves_btn_restore .. " (3)",
	"host with autosaves: 'Restore an autosave (3)'")
local listed = AUTOS_LISTED
NOW = NOW + 1000
dlg:Update()
dlg:Update()
check(AUTOS_LISTED == listed, "polling does not list the autosaves again")
INFO.host, INFO.client = false, true
dlg:Refresh()
check(flat_hidden(dlg.flat.btn_restore), "a client never sees Restore")
INFO.host, INFO.client = true, false
dlg:Refresh()
click(dlg, "tab_join")
check(flat_hidden(dlg.flat.btn_restore), "Restore is hidden on the join tab")
click(dlg, "tab_host")
check(flat_shown(dlg.flat.btn_restore), "and back on the host tab")
AUTOS = {}
-- end of the session
ALIVE = false
INFO = { phase = "off", active = false, nick = "Mechenyi", max_players = 8, players = {} }
dlg:Refresh()
check(flat_hidden(dlg.flat.btn_host_now) and dlg.open_hint.shown and dlg.open_hint.text:find("dead", 1, true),
	"dead actor: no Open button, the hint says why")
ALIVE = true
dlg:Refresh()
check(flat_shown(dlg.flat.btn_host_now), "alive again: the Open button is back")
check(dlg.info_title.text == "What happens next" and dlg.info_line[1].shown and not dlg.status_scroll.shown, "steps are back without a session")
-- quit wrappers
INFO.active = true
MENU.cb["msg_box#30"].f(MENU)
check(CALLS[#CALLS] == "disconnect" and MENU.calls[#MENU.calls] == "quit_game", "quit game leaves the session first")
local nc = #CALLS
INFO.active = false
MENU.cb["msg_box#31"].f(MENU)
check(#CALLS == nc and MENU.calls[#MENU.calls] == "quit_win", "quit to windows without a session: stock only")
-- disconnect from the status line
INFO = { phase = "live", active = true, client = true, address = "10.0.0.7", port = 28001, nick = "Mechenyi", max_players = 8,
	players = two }
dlg:Refresh()
click(dlg, "btn_disconnect")
check(CALLS[#CALLS] == "disconnect", "Disconnect leaves the session")
-- escape closes
dlg:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not dlg.shown and MENU.shown, "Escape closes the window")
LEVEL = false

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
local used, absent = 0, {}
for id in src:gmatch('"(st_coop_[%w_]+)"') do
	if id:sub(-1) ~= "_" then -- prefixes completed at run time are checked by the texts tests
		used = used + 1
		if not STRINGS[id] then absent[#absent + 1] = id end
	end
end
check(used > 10 and #absent == 0, used .. " ids used by coop_menu.script exist (" .. table.concat(absent, ",") .. ")")
local fx = assert(io.open(ROOT .. "configs/ui/ui_coop_menu.xml", "r"))
local xsrc = fx:read("*a")
fx:close()
absent = {}
for id in xsrc:gmatch(">(st_coop_[%w_]+)<") do if not STRINGS[id] then absent[#absent + 1] = id end end
check(#absent == 0, "ids in ui_coop_menu.xml exist (" .. table.concat(absent, ",") .. ")")
local unused = {}
for path in pairs(XML_FILES["ui_coop_menu.xml"]) do
	if (path == "coop_shade" or path:find("^coop_menu:[%w_]+$")) and not USED_PATHS[path] then unused[#unused + 1] = path end
end
table.sort(unused)
check(#unused == 0, "every node of ui_coop_menu.xml is created by the script (" .. table.concat(unused, ", ") .. ")")
-- the 16:9 layout: the engine loads ui_coop_menu_16.xml on a wide screen (ui_core::get_xml_name). Made from the 4:3 one by
-- tools\make_menu_layout_16.py: the same nodes, x and width times 0.75 (the window centred), y and height as they are
local wide_file = ROOT .. "configs/ui/ui_coop_menu_16.xml"
local fw = assert(io.open(wide_file, "r"), "no ui_coop_menu_16.xml")
local wsrc = fw:read("*a")
fw:close()
local wide_paths, diff_nodes = xml_paths(wide_file), {}
for pth in pairs(wide_paths) do if not XML_FILES["ui_coop_menu.xml"][pth] then diff_nodes[#diff_nodes + 1] = "+" .. pth end end
for pth in pairs(XML_FILES["ui_coop_menu.xml"]) do if not wide_paths[pth] then diff_nodes[#diff_nodes + 1] = "-" .. pth end end
check(#diff_nodes == 0, "ui_coop_menu_16.xml has the same nodes as the 4:3 file (" .. table.concat(diff_nodes, ", ") .. ")")
local function rects(src)
	local t = {}
	for tag, attrs in src:gsub("<!%-%-.-%-%->", ""):gmatch("<([%w_]+)(%s[^>]*)>") do
		local x, y, w, h = attrs:match('x="([-%d.]+)"%s+y="([-%d.]+)"%s+width="([-%d.]+)"%s+height="([-%d.]+)"')
		if x then t[#t + 1] = { tag = tag, x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } end
	end
	return t
end
local r43, r169, off = rects(xsrc), rects(wsrc), {}
check(#r43 > 80 and #r43 == #r169, "both layouts have the same rectangles (" .. #r43 .. " / " .. #r169 .. ")")
for i, a in ipairs(r43) do
	local b = r169[i]
	if not b or a.tag ~= b.tag or a.y ~= b.y or a.h ~= b.h then
		off[#off + 1] = a.tag
	elseif a.tag == "coop_shade" then
		if a.x ~= b.x or a.w ~= b.w then off[#off + 1] = a.tag end
	elseif a.tag == "coop_menu" then
		if math.abs(b.w - a.w * 0.75) > 0.011 or math.abs(b.x - (1024 - b.w) / 2) > 0.011 then off[#off + 1] = a.tag end
	elseif math.abs(b.x - a.x * 0.75) > 0.011 or math.abs(b.w - a.w * 0.75) > 0.011 then
		off[#off + 1] = a.tag
	end
end
check(#off == 0, "16:9: x and width times 0.75, the window centred, y and height kept (" .. table.concat(off, ", ") .. ")")
-- the captions the layout carries itself (the stubs do not read them): node -> English text of its string id
local function node_text(name)
	local id = xsrc:match("<" .. name .. "%s[^>]*>%s*<text[^>]*>([^<]*)</text>")
	return id and STRINGS[id]
end
local captions = {
	cap = "CO-OP", seg_host = "Host a game", seg_join = "Join a game", seg_steam = "Steam - soon",
	cap_nick = "Your nickname", nick_hint = "this is how partners see you", cap_start = "How to start",
	tile_new_title = "New game", tile_new_badge = "recommended", tile_last_title = "Continue", tile_load_title = "Load...",
	btn_host_now = "Open it to partners", btn_connect = "Connect", btn_disconnect = "Disconnect", btn_cancel_pending = "Cancel",
	btn_close = "Close", cap_address = "Host address", cap_recent = "Recent", cap_port = "Port UDP",
}
local wrong = {}
for node, want in pairs(captions) do
	if node_text(node) ~= want then wrong[#wrong + 1] = node .. "=" .. tostring(node_text(node)) end
end
check(#wrong == 0, "captions of the layout nodes (" .. table.concat(wrong, ", ") .. ")")
check(node_text("tile_new_desc"):find("faction", 1, true) and node_text("tile_load_desc"):find("Any save", 1, true),
	"descriptions of the New game and Load tiles")
-- the texture ids of the layout are in the atlas description (tools\make_menu_icons.py)
local fd = assert(io.open(ROOT .. "configs/ui/textures_descr/ui_coop_menu.xml", "r"))
local dsrc = fd:read("*a")
fd:close()
local atlas = {}
for id in dsrc:gmatch('<texture id="([^"]+)"') do atlas[id] = true end
local no_tex = {}
for id in xsrc:gmatch(">(coop_menu_[%w_]+)<") do
	if not atlas[id] and not (atlas[id .. "_e"] and atlas[id .. "_d"] and atlas[id .. "_t"] and atlas[id .. "_h"]) then
		no_tex[#no_tex + 1] = id
	end
end
check(#no_tex == 0 and atlas.coop_menu_white, "every coop_menu_* texture of the layout is in the atlas (" .. table.concat(no_tex, ",") .. ")")
-- rus has the same ids
local rus = {}
for _, file in ipairs({ "st_coop_menu.xml", "st_coop_death.xml", "st_coop_hud.xml", "st_coop_saves.xml" }) do
	local fr = assert(io.open(ROOT .. "configs/text/rus/" .. file, "rb"))
	local rsrc = fr:read("*a")
	fr:close()
	for id in rsrc:gmatch('<string id="([^"]+)">') do rus[id] = true end
end
local diff = {}
for id in pairs(STRINGS) do if not rus[id] then diff[#diff + 1] = id end end
for id in pairs(rus) do if not STRINGS[id] then diff[#diff + 1] = id end end
check(#diff == 0, "rus and eng tables have the same ids")

print(string.format("%d passed, %d failed", PASSES, FAILS))
