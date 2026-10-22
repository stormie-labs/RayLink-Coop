-- Anomaly Coop temp test (W4 menu): coop_menu.script window logic, modxml_coop_menu.script button injection,
-- coop_menu_options.script options page. Engine and UI are stand-ins (menu_stubs.lua). Not shipped.
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_menu.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu.xml")

-- strings: real ids from the eng table, "%s" kept
STRINGS = {}
do
	local fh = assert(io.open(ROOT .. "configs/text/eng/st_coop_menu.xml", "r"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
game = { translate_string = function(id) return STRINGS[id] or id end }

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
check(m.phase_text({ phase = "off" }) == "no session", "phase off")
check(m.phase_text({ phase = "hosting", port = 27960 }) == "you host on port 27960", "phase hosting")
check(m.phase_text({ phase = "connecting", address = "1.2.3.4", port = 5 }) == "connecting to 1.2.3.4:5...", "phase connecting")
check(m.phase_text({ phase = "receiving-world" }) == "downloading the host's world...", "phase with dash")
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
	== "The session was closed.", "own disconnect is not an error")
check(m.error_text({ active = false, last_error = "connect timeout", last_error_code = "lost" })
	== "Error: connection lost (connect timeout)", "lost text")
check(m.error_text({ active = false, last_error = "weird", last_error_code = "Nope" }) == "Error: weird", "unknown code: raw text")
check(m.error_text({ active = true, last_error = "x", last_error_code = "lost" }) == "", "no error while active")
local pl = m.player_lines({ players = {
	{ id = 1, nick = "me", is_self = true, rtt = 0 },
	{ id = 0, nick = "boss", is_host = true, rtt = 44.6 },
	{ id = 2, nick = "new", joined = false, rtt = 80 } } })
check(pl[1] == "me (you)" and pl[2] == "boss (host)  -  44 ms" and pl[3] == "new (joining)  -  80 ms", "player lines")

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
MENU.cb["btn_coop#17"].f(MENU.cb["btn_coop#17"].obj)
local dlg = MENU.coop_menu_dlg
check(dlg ~= nil and dlg.shown and not MENU.shown, "Co-op opens the window over the hidden main menu")
check(#MISSING_PATHS == 0, "every xml path exists in ui_coop_menu.xml (" .. table.concat(MISSING_PATHS, ", ") .. ")")
check(dlg.edit_nick.text == "Strelok" and dlg.edit_port.text == "28000" and dlg.edit_address.text == "6.6.6.6", "fields from storage")
check(dlg.tabs.steam.enabled == false, "Steam tab disabled")
check(dlg.tab == "host" and dlg.btn_host_now.enabled == false and dlg.btn_host_load.enabled, "no level: host now disabled, load enabled")
check(dlg.host_info.text:find("No game is loaded") ~= nil, "host info for the main menu")
check(dlg.status_phase.text == "Status: no session", "status off")
check(dlg.btn_disconnect.enabled == false, "disconnect disabled without a session")
check(dlg.recent_btn[1].shown == false, "recent rows hidden on the host tab")
click(dlg, "tab_join")
check(dlg.tab == "join" and dlg.recent_btn[1].shown and dlg.recent_btn[5].shown and dlg.edit_address.shown
	and not dlg.edit_port.shown, "join tab shows its controls")
check(dlg.recent_btn[2].text == "5.5.5.5", "recent button text")
click(dlg, "btn_recent_3")
check(dlg.edit_address.text == "4.4.4.4", "recent click fills the address")

-- connect: bad address, bad nick, good
dlg.edit_address.text = "not an address"
click(dlg, "btn_connect")
check(dlg.local_error == "Enter the host address: IP or IP:port." and dlg.status_error.text == dlg.local_error, "bad address refused")
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
check(dlg.status_phase.text == "Status: connecting to 10.0.0.7:28001...", "status connecting")
check(dlg.btn_connect.enabled == false and dlg.edit_nick.enabled == false and dlg.btn_disconnect.enabled, "busy: inputs locked")
click(dlg, "btn_connect")
check(dlg.local_error:find("Disconnect from the current session") ~= nil, "second connect refused")
-- refused by the host
INFO = { phase = "off", active = false, client = false, nick = "Mechenyi", max_players = 8, players = {},
	last_error = "the host's mod list differs", last_error_code = "ContentMismatch" }
dlg.local_error = nil
NOW = NOW + 1000
dlg:Update()
check(dlg.status_error.text:find("your mod list differs") ~= nil, "refusal shown")

-- host tab: pending host via "Load a save"
click(dlg, "tab_host")
dlg.edit_port.text = "abc"
click(dlg, "btn_host_load")
check(dlg.local_error == "The port is a number from 1 to 65535." and #MENU.calls == 0, "bad port refused")
dlg.edit_port.text = "27961"
click(dlg, "btn_host_load")
check(CALLS[#CALLS] == "pending 27961" and MENU.calls[1] == "load", "load a save: pending host + stock load dialog")
check(not dlg.shown and MENU.shown and MENU.visible, "window closed, main menu back")
check(m.get_port() == 27961, "port remembered")
-- reopen: pending shown, cancel
MENU.cb["btn_coop#17"].f(MENU)
INFO.pending_host = 27961
dlg:Refresh()
check(dlg.pending_text.text == "The session opens on port 27961 as soon as the game is loaded." and dlg.btn_cancel_pending.shown,
	"pending shown with cancel")
check(dlg.btn_disconnect.enabled, "disconnect also cancels a pending host")
coop.host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end
click(dlg, "btn_cancel_pending")
check(CALLS[#CALLS] == "pending nil" and dlg.pending_text.text == "", "cancel pending")
click(dlg, "btn_host_new")
check(MENU.calls[#MENU.calls] == "new" and CALLS[#CALLS] == "pending 27961", "new game: pending + stock new game screen")
MENU.cb["btn_coop#17"].f(MENU)
click(dlg, "btn_host_last")
check(MENU.calls[#MENU.calls] == "last", "last save: stock last save")

print("== coop_menu: window in game (host this game)")
INFO = { phase = "off", active = false, nick = "Mechenyi", max_players = 8, players = {} }
LEVEL = true
ALIVE = true
db.actor = { alive = function() return ALIVE end }
MENU.cb["btn_coop#17"].f(MENU)
check(dlg.btn_host_now.enabled and dlg.host_info.text:find("UDP port 27961") ~= nil, "level loaded: host now enabled, port in the hint")
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
check(dlg.status_phase.text == "Status: you host on port 27961", "hosting status")
check(dlg.status_players.text == "Players 2 / 8:" and #dlg.status_scroll.children == 2
	and dlg.status_scroll.children[2].text == "Guest  -  35 ms", "players with ping")
local rows_before = dlg.status_scroll.children
NOW = NOW + 1000
dlg:Update()
check(dlg.status_scroll.children == rows_before, "player rows not rebuilt when nothing changed")
ALIVE = false
INFO = { phase = "off", active = false, nick = "Mechenyi", max_players = 8, players = {} }
dlg:Refresh()
check(dlg.btn_host_now.enabled == false and dlg.host_info.text:find("dead") ~= nil, "dead actor: host now disabled")
ALIVE = true
-- quit wrappers
INFO.active = true
MENU.cb["msg_box#30"].f(MENU)
check(CALLS[#CALLS] == "disconnect" and MENU.calls[#MENU.calls] == "quit_game", "quit game leaves the session first")
local nc = #CALLS
INFO.active = false
MENU.cb["msg_box#31"].f(MENU)
check(#CALLS == nc and MENU.calls[#MENU.calls] == "quit_win", "quit to windows without a session: stock only")
-- escape closes
dlg:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not dlg.shown and MENU.shown, "Escape closes the window")

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
local p, s = page.gr[1], page.gr[2]
check(p.id == "coop_player" and s.id == "coop_session" and p.sh and s.sh, "two groups")
local keys = {}
for _, g in ipairs(page.gr) do
	for _, o in ipairs(g.gr) do
		if o.type ~= "slide" and o.type ~= "desc" then
			keys[#keys + 1] = "ui_mm_coop_" .. g.id .. "_" .. o.id
		elseif o.text then
			keys[#keys + 1] = o.text
		end
		if o.type == "list" then for _, c in ipairs(o.content) do keys[#keys + 1] = c[2] end end
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
-- rus has the same ids
local rus = {}
local fr = assert(io.open(ROOT .. "configs/text/rus/st_coop_menu.xml", "rb"))
local rsrc = fr:read("*a")
fr:close()
for id in rsrc:gmatch('<string id="([^"]+)">') do rus[id] = true end
local diff = {}
for id in pairs(STRINGS) do if not rus[id] then diff[#diff + 1] = id end end
for id in pairs(rus) do if not STRINGS[id] then diff[#diff + 1] = id end end
check(#diff == 0, "rus and eng tables have the same ids")

print(string.format("%d passed, %d failed", PASSES, FAILS))
