-- Anomaly Coop F3 task 17 temp test: nobody saves or loads by hand in a co-op session, the stock save modes are
-- neutralized, the host restores from the emergency autosaves coop_auto_N.
-- Real scripts: coop_saves, coop_core_player, coop_menu; real layouts ui_coop_menu.xml / ui_coop_saves.xml; real string
-- tables st_coop_saves.xml. The engine, the stock game_autosave_new / ui_main_menu and the file system are stand-ins
-- (menu_stubs.lua). Not shipped. Run: tools\test_lua.cmd saves
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_menu.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_menu.xml")
XML_FILES["ui_coop_saves.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_saves.xml")

local function read_file(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local s = fh:read("*a")
	fh:close()
	return s
end

local function strings_of(path)
	local t, n = {}, 0
	local src = read_file(path)
	if src then
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do
			t[id] = text
			n = n + 1
		end
	end
	return t, n
end

-- strings: the real eng tables of the menu and of the saves
STRINGS = strings_of(ROOT .. "configs/text/eng/st_coop_menu.xml")
local SAVES_EN, SAVES_EN_N = strings_of(ROOT .. "configs/text/eng/st_coop_saves.xml")
for k, v in pairs(SAVES_EN) do STRINGS[k] = v end
STRINGS.l01_escape = "Cordon"
STRINGS.l02_garbage = "Garbage"
game = { translate_string = function(id) return STRINGS[id] or id end }

-- ------------------------------------------------------------------ session stand-in
MODE = "off"
INFO = {}
local function set_mode(m)
	MODE = m
	INFO = { phase = m == "off" and "off" or (m == "host" and "hosting" or "live"), active = m ~= "off", host = m == "host",
		client = m == "client", live = m ~= "off", nick = "me", max_players = 8, default_port = 27960, players = {} }
end
set_mode("off")
coop = {
	is_active = function() return MODE ~= "off" end,
	is_host = function() return MODE == "host" end,
	is_client = function() return MODE == "client" end,
	is_live = function() return MODE ~= "off" end,
	session_info = function() return INFO end,
}

-- ------------------------------------------------------------------ callbacks, time events, console
CB = {}
function RegisterScriptCallback(n, f)
	CB[n] = CB[n] or {}
	for _, g in ipairs(CB[n]) do if g == f then return end end -- set semantics, like axr_main.callback_set
	table.insert(CB[n], f)
end
function UnregisterScriptCallback() end
function SendScriptCallback(n, ...) for _, f in ipairs(CB[n] or {}) do f(...) end end
TE, RESETS = {}, {}
function CreateTimeEvent(ev, act, timer, f) TE[ev .. ":" .. act] = { f = f, timer = timer } end
function ResetTimeEvent(ev, act, timer) RESETS[#RESETS + 1] = ev .. ":" .. act end
EXEC = {}
function exec_console_cmd(cmd) EXEC[#EXEC + 1] = cmd end
local function exec_has(prefix)
	for _, c in ipairs(EXEC) do if c:sub(1, #prefix) == prefix then return true end end
	return false
end
HUD = {}
actor_menu = { set_msg = function(_, text) HUD[#HUD + 1] = text end }
LEVEL = true
level = { present = function() return LEVEL end }
db = { actor = { alive = function() return true end } }
axr_main = { config = config_stub() }
CONSOLE = {}
function get_console_cmd(typ, name) return CONSOLE[name] end

-- ------------------------------------------------------------------ the saves folder
FS = { FS_ListFiles = 1, FS_RootOnly = 2, FS_sort_by_modif_down = 5 }
function bit_or(a, b) return a + b end
-- file name (with .scop) -> { modif = sort key, stamp = "dd/mm/yyyy hh:mm", level =, h, mi, d, m, y, bad = true if the header is bad }
SAVES = {}
local function add_save(file, modif, extra)
	local s = { file = file, modif = modif, stamp = string.format("23/10/2026 01:%02d", modif % 60), level = "l01_escape",
		y = 2012, m = 3, d = 15, h = 7, mi = 5 }
	for k, v in pairs(extra or {}) do s[k] = v end
	SAVES[#SAVES + 1] = s
	return s
end
local function save_named(file)
	for _, s in ipairs(SAVES) do if s.file == file then return s end end
end
SORTED = 0
function getFS()
	return {
		file_list_open_ex = function(_, alias, flags, mask)
			local items = {}
			for _, s in ipairs(SAVES) do items[#items + 1] = s end
			local list = {}
			function list:Size() return #items end
			function list:Sort(mode)
				SORTED = SORTED + 1
				if mode == FS.FS_sort_by_modif_down then
					table.sort(items, function(a, b) return a.modif > b.modif end)
				end
			end
			function list:GetAt(i)
				local s = items[i + 1]
				return { NameFull = function() return s.file end, ModifDigitOnly = function() return s.stamp end }
			end
			return list
		end,
	}
end
function valid_saved_game(name)
	local s = save_named(name .. ".scop")
	return s ~= nil and not s.bad
end
WRAPPED = {}
function CSavedGameWrapper(name)
	WRAPPED[#WRAPPED + 1] = name
	local s = assert(save_named(name .. ".scop"), "R_ASSERT: no saved game " .. name)
	local o = {}
	function o:level_name() return s.level end
	function o:game_time()
		return { get = function(_, y, m, d, h, mi, sec, ms) return s.y, s.m, s.d, s.h, s.mi, 0, 0 end }
	end
	return o
end

-- ------------------------------------------------------------------ stock modules: ui_main_menu, game_autosave_new
MM = {}
ui_main_menu = { main_menu = {} }
MENU_MSG = {}
ui_main_menu.main_menu.SetMsg = function(self, text, sec) MENU_MSG[#MENU_MSG + 1] = text end
ui_main_menu.main_menu.OnButton_load_clicked = function(self) MM[#MM + 1] = "load" end
ui_main_menu.main_menu.OnButton_last_save = function(self) MM[#MM + 1] = "last" end
ui_main_menu.main_menu.OnButton_save_clicked = function(self) MM[#MM + 1] = "save" end
local STOCK_MM = { load = ui_main_menu.main_menu.OnButton_load_clicked, last = ui_main_menu.main_menu.OnButton_last_save }

OPT = { ["other/autosave_timer_new"] = 1 }
ui_options = { get = function(k) return OPT[k] end }
function user_name() return "Strelok" end

-- game_autosave_new.script of the stock Anomaly 1.5.3 (anomaly-ref\unpacked\scripts), verbatim
local STOCK_AUTOSAVE = [[
function on_game_start()
	RegisterScriptCallback("actor_on_first_update",actor_on_first_update)
end

local last_save
function actor_on_first_update()
	last_save = time_global()
	CreateTimeEvent("actor","autosave_new",60,autosave)
end

function option_updated()
	if level.present() then
		last_save = time_global()
	end
end

function autosave()
	local timer = tonumber(ui_options.get("other/autosave_timer_new"))

	if timer and timer >= 1 then
		if (time_global() - last_save) > (timer * 60 * 1000) then
			exec_console_cmd("save " .. (user_name() or "") .. " - tempsave")
			last_save = time_global()
		end
	end

	ResetTimeEvent("actor","autosave_new",60)
	return false
end
]]
local function load_text_module(name, src)
	local header = 'local this = {} ' .. name .. ' = this setmetatable(this, {__index = _G}) setfenv(1, this) '
	assert(loadstring(header .. src, "@" .. name .. ".script"))()
	return _G[name]
end
load_text_module("game_autosave_new", STOCK_AUTOSAVE)
local STOCK_AUTOSAVE_FN = game_autosave_new.autosave

-- coop_main stand-in for coop_core_player (event handlers by name)
HANDLERS = {}
coop_main = {
	add_event_handler = function(name, f) HANDLERS[name] = f end,
	encode = function(t) return t end,
	decode = function(s) return s end,
}

-------------------------------------------------------------------------------
print("== files exist")
local saves = load_module("coop_saves")
check(type(saves) == "table", "coop_saves loads")
check(type(saves.list_autosaves) == "function" and type(saves.restore) == "function", "list_autosaves and restore exist")
saves.on_game_start()
saves.on_game_start() -- a second game start in the same Lua state: nothing doubles
check(#(CB.on_before_save_input or {}) == 1 and #(CB.on_before_load_input or {}) == 1, "one save handler and one load handler")

-------------------------------------------------------------------------------
print("== save_input_refused_host_and_client")
for _, who in ipairs({ "host", "client" }) do
	set_mode(who)
	local want = STRINGS["st_coop_saves_auto_" .. who]
	check(want ~= nil and want ~= "", "string st_coop_saves_auto_" .. who .. " exists")
	for _, typ in ipairs({ 1, 2, 3 }) do
		HUD = {}
		local flags = { ret = false }
		SendScriptCallback("on_before_save_input", flags, typ, "Save")
		check(flags.ret == true, who .. ": save input type " .. typ .. " refused")
		check(#HUD == 1 and HUD[1] == want, who .. ": type " .. typ .. " shows st_coop_saves_auto_" .. who)
	end
end

print("== load_input_refused")
for _, who in ipairs({ "host", "client" }) do
	set_mode(who)
	HUD = {}
	local flags = { ret = false }
	SendScriptCallback("on_before_load_input", 65, 33, flags)
	check(flags.ret == true, who .. ": quick load refused")
	check(#HUD == 1 and HUD[1] == STRINGS["st_coop_saves_load_" .. who] and HUD[1] ~= "st_coop_saves_load_" .. who,
		who .. ": the hint is st_coop_saves_load_" .. who)
end

print("== main menu entries refuse in a session")
for _, who in ipairs({ "host", "client" }) do
	set_mode(who)
	MM, HUD, MENU_MSG = {}, {}, {}
	ui_main_menu.main_menu:OnButton_load_clicked()
	ui_main_menu.main_menu:OnButton_last_save()
	ui_main_menu.main_menu:OnButton_save_clicked()
	check(#MM == 1 and MM[1] == "save", who .. ": Load and Last save of an old menu do nothing (the stock Save checks the gate itself)")
	check(#MENU_MSG == 2 and MENU_MSG[1] == STRINGS["st_coop_saves_load_" .. who] and #HUD == 0,
		who .. ": and say why, on the menu's own message line (the HUD is not drawn under the menu)")
end

print("== hint goes where the player looks")
set_mode("host")
HUD, MENU_MSG = {}, {}
-- F5 pressed in the open in-game menu: main_menu:OnKeyboard sends main_menu_on_keyboard first
SendScriptCallback("main_menu_on_keyboard", 63, 1, ui_main_menu.main_menu, true)
SendScriptCallback("on_before_save_input", { ret = false }, 2, "Save")
check(#MENU_MSG == 1 and MENU_MSG[1] == STRINGS.st_coop_saves_auto_host and #HUD == 0, "F5 in the menu: the hint is on the menu's line")
NOW = NOW + 1000
SendScriptCallback("on_before_save_input", { ret = false }, 2, "Save")
check(#MENU_MSG == 1 and #HUD == 1 and HUD[1] == STRINGS.st_coop_saves_auto_host, "F5 in the game, a second later: the hint is over the game")
-- a menu without SetMsg falls back to the HUD
HUD = {}
SendScriptCallback("main_menu_on_keyboard", 63, 1, {}, true)
SendScriptCallback("on_before_save_input", { ret = false }, 3, "Save")
check(#HUD == 1, "a menu without SetMsg: the HUD hint")

print("== no_session_untouched")
set_mode("off")
HUD, MM = {}, {}
local f1, f2 = { ret = false }, { ret = false }
SendScriptCallback("on_before_save_input", f1, 2, "Save")
SendScriptCallback("on_before_load_input", 65, 33, f2)
check(f1.ret == false and f2.ret == false and #HUD == 0, "no session: flags untouched, no hint")
ui_main_menu.main_menu:OnButton_load_clicked()
ui_main_menu.main_menu:OnButton_last_save()
check(#MM == 2 and MM[1] == "load" and MM[2] == "last", "no session: the stock Load / Last save run")
-- a flags table that already says ret = true is not touched either
local f3 = { ret = true }
SendScriptCallback("on_before_save_input", f3, 2, "Save")
check(f3.ret == true, "no session: ret stays as another script set it")
-- pending host (host_when_ready) is not a session: the stock load must work for "host after load"
INFO = { active = false, pending_host = 27960, host = false, client = false }
local f4 = { ret = false }
SendScriptCallback("on_before_load_input", 65, 33, f4)
check(f4.ret == false, "a pending host (nothing active yet) may still load")

print("== autosave_new_neutralized")
check(game_autosave_new.autosave ~= STOCK_AUTOSAVE_FN and type(game_autosave_new.autosave) == "function", "autosave is wrapped")
local wrapper = game_autosave_new.autosave
saves.on_game_start()
check(game_autosave_new.autosave == wrapper, "wrapped once")
-- the way the stock script starts its tick (the function value is taken when the event is created, after our wrap)
local function tick_after(ms)
	TE, RESETS, EXEC = {}, {}, {}
	NOW = 100000
	game_autosave_new.actor_on_first_update()
	NOW = NOW + ms
	return TE["actor:autosave_new"].f()
end
set_mode("host")
local r = tick_after(61000)
check(TE["actor:autosave_new"].f == wrapper, "the time event holds the wrapper")
check(not exec_has("save"), "host: timer expired, no save command")
check(r == false and #RESETS == 1 and RESETS[1] == "actor:autosave_new", "host: the tick is rescheduled like the stock one")
set_mode("client")
tick_after(61000)
check(not exec_has("save"), "client: timer expired, no save command")
set_mode("off")
tick_after(30000)
check(not exec_has("save"), "no session: timer not expired yet, no save")
tick_after(61000)
check(exec_has("save Strelok - tempsave"), "no session: the stock autosave still works")
OPT["other/autosave_timer_new"] = 0
tick_after(61000 * 5)
check(not exec_has("save"), "no session, timer 0: nothing")
OPT["other/autosave_timer_new"] = 1
-- no game_autosave_new in this build: no error, and a log line
do
	local keep = _G.game_autosave_new
	_G.game_autosave_new = nil
	local ok = pcall(saves.on_game_start)
	check(ok, "no game_autosave_new: on_game_start survives")
	_G.game_autosave_new = keep
end

print("== client_quicksave_request_gone")
local cp = load_module("coop_core_player")
cp.on_game_start()
check(cp.request_quicksave == nil, "coop_core_player has no request_quicksave")
check(HANDLERS["core.save_req"] == nil and HANDLERS["core.save_res"] == nil, "the events core.save_req / core.save_res are not handled")
check(type(HANDLERS["core.moving"]) == "function", "the level-move event is still handled")
check(pcall(cp.print_status), "print_status still works")
local opts = load_module("coop_menu_options")
local have_quicksave = false
for _, g in ipairs(opts.build_page().gr) do
	for _, o in ipairs(g.gr) do if o.id == "client_quicksave" then have_quicksave = true end end
end
check(not have_quicksave, "the options page has no client_quicksave check box")
local src_cp = read_file(ROOT .. "scripts/coop_core_player.script")
check(not src_cp:find("save_req", 1, true) and not src_cp:find("request_quicksave", 1, true) and not src_cp:find("core/client_quicksave", 1, true),
	"coop_core_player.script: no save request code left")

-------------------------------------------------------------------------------
print("== restore_list")
SAVES = {}
add_save("coop_auto_1.scop", 100)
add_save("quicksave.scop", 400)
add_save("Strelok - quicksave_1.scop", 450)
add_save("coop_auto_2.scop", 300, { level = "l02_garbage", h = 21, mi = 40 })
add_save("coop_auto_x.scop", 500)
add_save("coop_auto_03.scop", 510)
add_save("Coop_Auto_4.scop", 520)
add_save("coop_auto_5.scop.bak", 530)
add_save("coop_auto_6.scop", 540, { bad = true })
set_mode("host")
WRAPPED, SORTED = {}, 0
local list = saves.list_autosaves()
check(SORTED >= 1, "the folder is asked newest first")
local names = {}
for i, e in ipairs(list) do names[i] = e.name end
check(table.concat(names, ",") == "coop_auto_2,coop_auto_1", "coop_auto_2 (newer), coop_auto_1; quicksave, other names and bad headers left out (" .. table.concat(names, ",") .. ")")
check(list[1].level == "l02_garbage" and list[1].level_text == "Garbage" and list[1].game_time_str == "21:40 03/15/2012"
	and list[1].file_time == "23/10/2026 01:00" and list[1].slot == 2, "entry fields: level, level_text, game_time_str, file_time, slot")
check(list[2].level == "l01_escape" and list[2].level_text == "Cordon" and list[2].game_time_str == "07:05 03/15/2012", "second entry")
check(#WRAPPED == 2, "the save is opened only for what is listed (" .. #WRAPPED .. ")")
SAVES = {}
check(#saves.list_autosaves() == 0, "no autosave at all (the engine module is not there yet): an empty list, no error")
add_save("quicksave.scop", 1)
check(#saves.list_autosaves() == 0, "only a quicksave: still empty")

print("== restore")
SAVES = {}
add_save("coop_auto_1.scop", 100)
add_save("coop_auto_2.scop", 300)
add_save("quicksave.scop", 400)
set_mode("host")
EXEC = {}
local ok, why = saves.restore("coop_auto_2")
check(ok == true and EXEC[#EXEC] == "load coop_auto_2", "host: load coop_auto_2")
EXEC = {}
for _, bad in ipairs({ "quicksave", "coop_auto_9", "coop_auto_2 ; quit", "coop_auto_02", "", 5 }) do
	ok, why = saves.restore(bad)
	check(ok == false and #EXEC == 0, "restore refuses '" .. tostring(bad) .. "' (" .. tostring(why) .. ")")
end
set_mode("client")
ok, why = saves.restore("coop_auto_2")
check(ok == false and why == "not_host" and #EXEC == 0, "client: restore refused")
set_mode("off")
ok, why = saves.restore("coop_auto_2")
check(ok == false and why == "not_host" and #EXEC == 0, "no session: restore refused")

-------------------------------------------------------------------------------
print("== Restore button and window")
MENU = { calls = {} }
function MENU:ShowDialog() self.shown = true end
function MENU:HideDialog() self.shown = false end
function MENU:Show(b) self.visible = b end
MENU.cb = {}
function MENU:AddCallback(n, ev, f, obj) self.cb[n .. "#" .. ev] = { f = f, obj = obj } end
MENU.shown = true
local cm = load_module("coop_menu")
local function open_window()
	MENU.shown = true
	cm.on_main_menu_init(MENU)
	MENU.cb["btn_coop#17"].f(MENU)
	return MENU.coop_menu_dlg
end

set_mode("off")
local dlg = open_window()
check(dlg ~= nil and dlg.btn_restore ~= nil, "the window has a Restore button")
check(dlg.btn_restore.enabled == false, "no session: Restore disabled")
check(dlg.btn_restore.text == STRINGS.st_coop_saves_btn_restore and dlg.btn_restore.text ~= "", "Restore caption comes from st_coop_saves")
click(dlg, "btn_restore")
check(dlg.shown and dlg.restore_dlg == nil, "no session: clicking Restore opens nothing")
check(dlg.status_error.text == STRINGS.st_coop_saves_restore_failed_not_host, "and says why")
set_mode("client")
dlg:Refresh()
check(dlg.btn_restore.enabled == false, "client: Restore disabled")
set_mode("host")
dlg:Refresh()
check(dlg.btn_restore.enabled == true, "host in a session: Restore enabled")
check(dlg.btn_restore.shown, "Restore is on the host tab")
click(dlg, "tab_join")
check(dlg.btn_restore.shown == false, "Restore hidden on the join tab")
click(dlg, "tab_host")
check(dlg.btn_restore.shown, "Restore back on the host tab")

-- open the list
SAVES = {}
add_save("coop_auto_1.scop", 100)
add_save("quicksave.scop", 400)
add_save("coop_auto_2.scop", 300, { level = "l02_garbage" })
EXEC, WRAPPED = {}, {}
click(dlg, "btn_restore")
local rd = dlg.restore_dlg
check(rd ~= nil and rd.shown, "the restore window opens")
check(not dlg.shown, "over the Co-op window")
check(#MISSING_PATHS == 0, "every xml path exists (" .. table.concat(MISSING_PATHS, ", ") .. ")")
check(rd.rows[1].shown and rd.rows[2].shown and not rd.rows[3].shown, "two rows, newest first")
check(rd.rows[1].text:find("coop_auto_2", 1, true) and rd.rows[1].text:find("Garbage", 1, true)
	and rd.rows[2].text:find("coop_auto_1", 1, true) and rd.rows[2].text:find("Cordon", 1, true), "row text: name, level")
check(rd.empty.shown == false, "the empty note is hidden")
check(rd.btn_confirm.enabled == false and rd.confirm.text == "", "nothing selected: no confirm")
click(rd, "btn_confirm")
check(#EXEC == 0, "confirm without a selection loads nothing")
click(rd, "btn_row_2")
check(rd.btn_confirm.enabled == true and rd.confirm.text:find("coop_auto_1", 1, true) ~= nil, "a selected row asks for confirmation")
check(#EXEC == 0, "selecting alone loads nothing")
click(rd, "btn_row_1")
check(rd.confirm.text:find("coop_auto_2", 1, true) ~= nil and rd.confirm.text:find("Garbage", 1, true) ~= nil
	and rd.confirm.text:find("07:05 03/15/2012", 1, true) ~= nil, "the confirmation names the chosen save, its level and time")
-- back
click(rd, "btn_back")
check(not rd.shown and dlg.shown and dlg.visible ~= false, "Back returns to the Co-op window")
-- open again, confirm
click(dlg, "btn_restore")
rd = dlg.restore_dlg
click(rd, "btn_row_1")
click(rd, "btn_confirm")
check(#EXEC == 1 and EXEC[1] == "load coop_auto_2", "confirm: load coop_auto_2")
check(not rd.shown, "the restore window is closed after the load")

-- the file is gone / the session ended between the list and the confirm
set_mode("host")
click(dlg, "btn_restore")
rd = dlg.restore_dlg
click(rd, "btn_row_1")
SAVES = {}
EXEC = {}
click(rd, "btn_confirm")
check(#EXEC == 0 and rd.confirm.text == STRINGS.st_coop_saves_restore_failed_missing, "a vanished file: no load, the reason shown")
check(rd.shown, "the window stays open")
add_save("coop_auto_2.scop", 300)
set_mode("client")
click(rd, "btn_confirm")
check(#EXEC == 0 and rd.confirm.text == STRINGS.st_coop_saves_restore_failed_not_host, "session turned into a client: refused")
click(rd, "btn_back")

-- no autosaves yet
set_mode("host")
SAVES = {}
dlg:Refresh()
click(dlg, "btn_restore")
rd = dlg.restore_dlg
check(rd.empty.shown and not rd.rows[1].shown and rd.btn_confirm.enabled == false, "no autosaves yet: the note, no rows")
check(rd.empty.text ~= "" or STRINGS.st_coop_saves_restore_none ~= nil, "the empty note has a string")
-- escape goes back
rd:OnKeyboard(DIK_keys.DIK_ESCAPE, ui_events.WINDOW_KEY_PRESSED)
check(not rd.shown and dlg.shown, "Escape in the restore window goes back")

print("== window closes the stale menu when the session started while it was open")
set_mode("off")
dlg = open_window()
set_mode("host")
EXEC = {}
MENU.shown = false
dlg:Close()
check(exec_has("main_menu off") and MENU.shown == false, "session started under the open menu: Close ends the menu, not back to the old list")
set_mode("host")
dlg = open_window() -- the menu was opened inside a session: its list is already right
EXEC = {}
MENU.shown = false
dlg:Close()
check(not exec_has("main_menu off") and MENU.shown == true, "menu opened inside the session: Close goes back to it")
set_mode("off")
dlg = open_window()
EXEC = {}
MENU.shown = false
dlg:Close()
check(not exec_has("main_menu off") and MENU.shown == true, "no session: Close goes back as before")

-------------------------------------------------------------------------------
print("== strings and layout")
local HEADER = '<?xml version="1.0" encoding="windows-1251"?>'
local eng_ids, rus_ids = {}, {}
for _, lang in ipairs({ "eng", "rus" }) do
	local path = ROOT .. "configs/text/" .. lang .. "/st_coop_saves.xml"
	local raw = read_file(path)
	check(raw ~= nil, lang .. ": st_coop_saves.xml exists")
	if raw then
		check(raw:sub(1, #HEADER) == HEADER, lang .. ": windows-1251 header")
		check(not raw:gsub("\r\n", ""):find("\n", 1, true), lang .. ": CRLF line ends only")
		local t, n = strings_of(path)
		check(n == 14, lang .. ": " .. n .. " strings")
		for id, text in pairs(t) do
			(lang == "eng" and eng_ids or rus_ids)[id] = true
			if text:find("^%s*$") then check(false, lang .. ": " .. id .. " is empty") end
			if lang == "rus" then
				if not text:find("[\192-\255]") or text:find("[\208\209][\128-\191]") then
					check(false, "rus: " .. id .. " is not cp1251 Cyrillic")
				end
			elseif text:find("[\128-\255]") then
				check(false, "eng: " .. id .. " has non-ASCII bytes")
			end
		end
	end
end
local diff = {}
for id in pairs(eng_ids) do if not rus_ids[id] then diff[#diff + 1] = id end end
for id in pairs(rus_ids) do if not eng_ids[id] then diff[#diff + 1] = id end end
check(#diff == 0, "rus and eng have the same ids (" .. table.concat(diff, ",") .. ")")
local rus_raw = read_file(ROOT .. "configs/text/rus/st_coop_saves.xml") or ""
check(rus_raw:find("\202\238\238\239\229\240\224\242\232\226", 1, true) ~= nil, "rus: the hints start with the cp1251 word for Co-op")

-- every id the scripts and layouts use
local used = {}
local function collect(path, pat, prefix)
	local src = read_file(path) or ""
	for key in src:gmatch(pat) do used[(prefix or "") .. key] = path end
end
collect(ROOT .. "scripts/coop_saves.script", 'text%("([%w_]+)"', "st_coop_saves_")
collect(ROOT .. "scripts/coop_saves.script", 'hint%("([%w_]+)"', "st_coop_saves_")
collect(ROOT .. "scripts/coop_saves.script", '"(st_coop_saves_[%w_]+)"')
collect(ROOT .. "configs/ui/ui_coop_saves.xml", ">(st_coop_[%w_]+)<")
collect(ROOT .. "configs/ui/ui_coop_menu.xml", ">(st_coop_saves_[%w_]+)<")
collect(ROOT .. "scripts/coop_menu.script", 'text%("([%w_]+)"', "st_coop_saves_")
local absent, n_used = {}, 0
for id, where in pairs(used) do
	n_used = n_used + 1
	if not eng_ids[id] and not (strings_of(ROOT .. "configs/text/eng/st_coop_menu.xml"))[id] then absent[#absent + 1] = id .. " (" .. where .. ")" end
end
check(n_used >= 6 and #absent == 0, n_used .. " ids used by the scripts and layouts exist (" .. table.concat(absent, ", ") .. ")")
-- the failure reasons restore() can give all have a string
for _, why in ipairs({ "not_host", "bad_name", "missing" }) do
	check(eng_ids["st_coop_saves_restore_failed_" .. why], "string for the restore failure '" .. why .. "'")
end

print("== domains")
local dom = ini_over(ROOT .. "configs/coop_domains_checkpoints.ltx")
check(dom:line_exist("view", "coop_saves"), "coop_saves is a view script (runs on every machine)")

print("== engine: the menu list")
local engine_src = read_file("engine/src/xrGame/ui/UIMMShniaga.cpp")
if engine_src then
	check(engine_src:find("coop::mgr().active()", 1, true) ~= nil, "UIMMShniaga.cpp asks the co-op session")
	for _, name in ipairs({ "btn_save", "btn_load", "btn_lastsave" }) do
		check(engine_src:find('"' .. name .. '"', 1, true) ~= nil, "UIMMShniaga.cpp hides " .. name)
	end
	check(engine_src:find("btn_originals", 1, true) == nil and engine_src:find("btn_options", 1, true) == nil,
		"and only the save and load entries")
else
	print("  (engine sources not found: skipped)")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
