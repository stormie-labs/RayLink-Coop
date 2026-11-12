-- Anomaly Coop test: "New game" with "Split levels" on (gamedata\scripts\coop_newgame_modes.script on_start_clicked, plan
-- docs\plans\2026-11-12-split-levels-native.md 3.1, stage 6b). The stock start runs with a trap on main_menu:StartGame
-- (capture_creator): what the stock writes into [character_creation] becomes the [creator] of the staging file and is erased at
-- once, no world starts in this game, the world server is started and the waiting window opens. With the setting off the
-- start is the one of today. The stock screen and the main menu are stand-ins shaped like ui_mm_faction_select.UINewGame;
-- the catalog, the record, the view, the staging file writer and the waiting window are the real scripts; the engine's
-- world server is support\world_server_stub.lua. Not shipped. Run: tools\test_lua.cmd newgame_split
dofile("tests/lua/support/menu_stubs.lua")
dofile("tests/lua/support/world_server_stub.lua")
os.execute("mkdir temp\\tests_s6b 2>nul")

STRINGS = {}
for _, f in ipairs({ "st_coop_menu.xml", "st_coop_newgame.xml" }) do
	local fh = assert(io.open(ROOT .. "configs/text/eng/" .. f, "r"))
	for id, text in fh:read("*a"):gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
	fh:close()
end
game = { translate_string = function(id) return STRINGS[id] or id end }
local function T(id) return STRINGS[id] or id end

INFO = { phase = "off", active = false, host = false, client = false, players = {}, pending_host = 27961 }
CALLS = {}
coop = {
	is_active = function() return INFO.active end,
	is_host = function() return INFO.host end,
	is_client = function() return INFO.client end,
	session_info = function() return INFO end,
	host_when_ready = function(p) CALLS[#CALLS + 1] = "pending " .. tostring(p); INFO.pending_host = p; return true end,
	connect = function(a) CALLS[#CALLS + 1] = "connect " .. a; return true end,
}
install_world_server(coop)
function command_line() return "x.exe" end
function get_console_cmd() return nil end
function exec_console_cmd() end
axr_main = { config = config_stub() }
CFG = axr_main.config.data
level = { present = function() return false end }
function RegisterScriptCallback() end

STAGED = {}
coop_game_settings = {
	defaults = function() return { ["c|coop_death_mode"] = "checkpoint" } end,
	stage_new = function(record) STAGED[#STAGED + 1] = record; return true end,
}
load_module("coop_game_schema")
load_module("coop_game_record")
load_module("coop_game_settings_view")
load_module("coop_world_stage_file")
load_module("coop_world_wait")

XML_FILES["ui_coop_newgame.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_newgame.xml")
XML_FILES["ui_coop_chronicle.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_chronicle.xml")
XML_FILES["stock.xml"] = setmetatable({}, { __index = function() return true end })
local base_xml = CScriptXmlInit
function CScriptXmlInit()
	local x = base_xml()
	local function init(self, path, parent)
		local wnd = window(path)
		wnd.checked = false
		wnd.items = {}
		function wnd:SetCheck(b) self.checked = b and true or false end
		function wnd:GetCheck() return self.checked end
		function wnd:ClearList() self.items = {} end
		function wnd:AddItem(text, id) self.items[#self.items + 1] = { text = text, id = id } end
		function wnd:CurrentID() return self.cur or -1 end
		return wnd
	end
	for _, n in ipairs({ "InitStatic", "InitTextWnd", "Init3tButton", "InitEditBox", "InitScrollView", "InitCheck", "InitComboBox" }) do
		x[n] = init
	end
	return x
end

-- the stock screen: OnStartGame writes what ui_mm_faction_select.script UINewGame:OnStartGame writes, then owner:StartGame()
STOCK_ERROR = nil
class "UINewGame" (CUIScriptWnd)
function UINewGame:__init(owner)
	self.owner = owner
	self.access = true
	self.selected_faction = "bandit"
	self.selected_difficulty, self.selected_economy = "st_diff_2", "st_econ_1"
	self.selected_icon, self.selected_map, self.selected_money = "ui_inGame2_bandit_1", "esc_bandit_start", 1500
	self.kit = { "wpn_pm", "ammo_9x18_fmj", "ammo_9x18_fmj" }
	local xml = CScriptXmlInit()
	xml:ParseFile("stock.xml")
	self.character_name = xml:InitEditBox("input_name", self)
	self.character_name:SetText("Big Boss")
	self.templ_options = xml:InitStatic("templ_options", nil)
	self.ck_story = xml:InitCheck("check_story", self.templ_options)
	self.ck_story:SetCheck(true)
	self.ck_routes = xml:InitCheck("check_routes", self.templ_options)
	self:AddCallback("btn_start", ui_events.BUTTON_CLICKED, self.OnStartGame, self)
end
function UINewGame:OnStartGame()
	if not self.access then return end
	local name = self.character_name:GetText()
	if name == "" then return end
	local c = axr_main.config
	c:w_value("character_creation", "new_game_difficulty", 2)
	c:w_value("character_creation", "new_game_economy", 1)
	c:w_value("character_creation", "new_game_economy_treasure", 1)
	c:w_value("character_creation", "new_game_story_mode", self.ck_story:GetCheck() and true or nil)
	c:w_value("character_creation", "new_game_opened_routes", self.ck_routes:GetCheck() and true or nil)
	if STOCK_ERROR then error(STOCK_ERROR) end
	c:w_value("character_creation", "new_game_character_name", (name:gsub(" ", "_")))
	c:w_value("character_creation", "new_game_faction", self.selected_faction)
	c:w_value("character_creation", "new_game_icon", self.selected_icon)
	c:w_value("character_creation", "new_game_loadout", #self.kit > 0 and table.concat(self.kit, ",") or nil)
	c:w_value("character_creation", "new_game_map", self.selected_map)
	c:w_value("character_creation", "new_game_money", self.selected_money)
	c:save()
	self.owner:StartGame()
end

local MM = {} -- the class ui_main_menu.main_menu; MENU is its instance
function MM:StartGame() self.starts = self.starts + 1 end
function MM:ShowDialog() self.shown = true end
function MM:HideDialog() self.shown = false end
function MM:Show(b) self.visible = b end
MENU = setmetatable({ starts = 0, shown = false }, { __index = MM })
local STOCK_START = MM.StartGame

local m = load_module("coop_newgame_modes")

local function cc_keys()
	local out = {}
	for k in pairs(CFG) do if k:find("^character_creation&") then out[#out + 1] = k end end
	return out
end
local function screen(split)
	local dlg = UINewGame(MENU)
	dlg.shown = true
	m.apply(dlg)
	if split ~= nil then dlg.coop_view:set("c|coop_split_levels", split and 1 or 0) end
	return dlg
end
local function start(dlg) return click(dlg, "btn_start") end
local function stage_text()
	local fh = io.open(WS.stage_path, "rb")
	local s = fh and fh:read("*a") or ""
	if fh then fh:close() end
	return s
end
local function reset()
	ws_reset(); CALLS = {}; LOG = {}; STAGED = {}
	MENU.starts = 0
	INFO.pending_host = 27961
	STOCK_ERROR = nil
	os.remove(WS.stage_path)
	if coop_world_wait.window_of() then coop_world_wait.window_of():Close() end
end

print("== split levels on: the trap, the file, the server")
reset()
local dlg = screen(true)
start(dlg)
check(MENU.starts == 0, "no world starts in this game")
check(rawget(MENU, "StartGame") == nil and MENU.StartGame == STOCK_START, "main_menu:StartGame is the stock one again")
check(#cc_keys() == 0, "[character_creation] is empty: a later single player game takes nothing of it (" .. table.concat(cc_keys(), ",") .. ")")
check(#STAGED == 0, "the record is not staged in this game")
local text = stage_text()
check(text:find("faction = bandit", 1, true) and text:find("\"c|coop_split_levels\" = 1", 1, true), "the staging file: the world's faction, split on")
check(text:find("[creator]\nname = Big Boss\nicon = ui_inGame2_bandit_1\nloadout = wpn_pm,ammo_9x18_fmj,ammo_9x18_fmj\nmoney = 1500\nmap = esc_bandit_start\nbare = 0\n", 1, true),
	"[creator] is what the stock screen wrote")
check(WS.calls[#WS.calls] == "start world=new port=27961 stage=true nick=Big Boss", "start{ world = new, stage = true, the pending host's port }")
check(CALLS[#CALLS] == "pending nil" and INFO.pending_host == nil, "the pending host is cancelled")
check(dlg.shown == false and coop_world_wait.window_of() ~= nil and coop_world_wait.window_of().shown, "the screen is closed, the waiting window is open")
check(log_has("%[coop%-newgame%] split levels: the world server starts"), "a log line")

print("== an empty kit is a choice")
reset()
dlg = screen(true)
dlg.kit = {}
start(dlg)
check(stage_text():find("loadout = \nmoney = 1500\nmap = esc_bandit_start\nbare = 1\n", 1, true), "bare = 1")

print("== the stock does not start (no name)")
reset()
dlg = screen(true)
dlg.character_name:SetText("")
start(dlg)
check(#WS.calls == 0 and MENU.starts == 0 and MENU.StartGame == STOCK_START and dlg.shown and INFO.pending_host == 27961,
	"nothing happens, the screen stays")

print("== the stock fails")
reset()
dlg = screen(true)
STOCK_ERROR = "a mod broke it"
start(dlg)
check(MENU.StartGame == STOCK_START and rawget(MENU, "StartGame") == nil, "StartGame restored after an error")
check(#cc_keys() == 0 and #WS.calls == 0 and dlg.shown and INFO.pending_host == 27961, "keys erased, nothing started, the screen stays")
check(dlg.coop_hint.text:find("a mod broke it", 1, true) ~= nil and log_has("! split levels"), "the player sees why, a log line")

print("== the server refuses")
reset()
dlg = screen(true)
WS.start_ok, WS.start_why = false, "in a co-op session: leave it first"
start(dlg)
check(MENU.starts == 0 and dlg.shown and INFO.pending_host == 27961 and coop_world_wait.window_of() == nil,
	"the screen stays, the pending host stays")
check(dlg.coop_hint.text:find("leave it first", 1, true) ~= nil and #cc_keys() == 0 and io.open(WS.stage_path, "rb") == nil,
	"the reason on the screen, no keys, no staging file")

print("== no staging path")
reset()
WS.stage_path = nil
dlg = screen(true)
start(dlg)
check(MENU.starts == 0 and dlg.coop_hint.text == T("st_coop_world_err_no_stage"), "refused with a text")
WS.stage_path = "temp/tests_s6b/coop_new_world.ltx"

print("== split levels off: as today")
reset()
dlg = screen(false)
start(dlg)
check(MENU.starts == 1 and #STAGED == 1 and #WS.calls == 0 and INFO.pending_host == 27961, "the stock start, the record staged, no world server")
check(CFG["character_creation&new_game_faction"] == "bandit", "the stock's keys stay for its on_game_load")

print("== the memory line under the split setting")
reset()
dlg = screen(nil)
local tab = coop_game_schema.item("c|coop_split_levels").tab
local note = dlg.coop_view.note_text[tab]
check(note ~= nil and note.text == T("st_coop_world_mem_note"), "the note on the tab of the split setting (" .. tostring(tab) .. ")")
WS.memory.commit_free_mb = 2048
dlg = screen(nil)
note = dlg.coop_view.note_text[tab]
check(note.text == (T("st_coop_world_mem_low"):gsub("%%s", "2.0")) and note.color == coop_ui_kit.argb(coop_menu_theme_base.DEFAULTS.colors.wait),
	"low memory: the low line in the warning colour")

print(string.format("%d passed, %d failed", PASSES, FAILS))
