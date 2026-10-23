-- Anomaly Coop test: the new game screen of a co-op host (gamedata\scripts\coop_newgame_modes.script, its main menu seam
-- modxml_coop_newgame.script, the layout configs\ui\ui_coop_newgame.xml and its _16 twin, the strings
-- configs\text\*\st_coop_newgame.xml): the stock modes are hidden, a block "Game settings" (tabs over the catalog,
-- coop_game_settings_view) takes their place, Start stages the new game (coop_game_settings.stage_new) and remembers the
-- rules. The stock screen (ui_mm_faction_select.UINewGame), the main menu, the engine and the host runtime
-- (coop_game_settings, another task) are stand-ins shaped like the real ones; the catalog (coop_game_schema), the record
-- (coop_game_record) and the view are the real scripts; the field names are checked against the real stock script below.
-- Not shipped. Run: tools\test_lua.cmd newgame_modes
dofile("tests/lua/support/menu_stubs.lua")

-- ------------------------------------------------------------------------------------------------ strings
STRINGS, RUS = {}, {}
local function read_strings(lang, into)
	local fh = assert(io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_newgame.xml", "r"),
		"no configs/text/" .. lang .. "/st_coop_newgame.xml")
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do into[id] = text end
end
read_strings("eng", STRINGS)
read_strings("rus", RUS)
do -- the catalog's strings (the host runtime task writes the file): used when it is there, else the id is the text
	local fh = io.open(ROOT .. "configs/text/eng/st_coop_game.xml", "r")
	if fh then
		local src = fh:read("*a")
		fh:close()
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = STRINGS[id] or text end
	end
end
game = { translate_string = function(id) return STRINGS[id] or id end }

-- ------------------------------------------------------------------------------------------------ engine
INFO = { phase = "off", active = false, host = false, client = false, live = false, players = {} }
coop = {
	is_active = function() return INFO.active end,
	is_host = function() return INFO.host end,
	is_client = function() return INFO.client end,
	session_info = function() return INFO end,
}
CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx -smap2048"
function command_line() return CMD end
CONSOLE = { coop_death_mode = "checkpoint", coop_death_drop = "drop", coop_autosave_interval = "10",
	coop_death_share = "100.00000" } -- a CCC_Float reads back as "%3.5f"
function get_console_cmd(typ, name) return CONSOLE[name] end
EXEC = {}
function exec_console_cmd(cmd)
	EXEC[#EXEC + 1] = cmd
	local name, value = cmd:match("^(%S+)%s+(.+)$")
	if name and CONSOLE[name] ~= nil then CONSOLE[name] = value end
end
axr_main = { config = config_stub() }
CFG = axr_main.config.data
-- ini_file_ex:r_string_ex: no cache, a cleared line (w_value without a value) reads as ""
function axr_main.config:r_string_ex(s, k) return CFG[s .. "&" .. k] end
local function cfg(key) return CFG["character_creation&" .. key] end
local function cfg_options(path) return CFG["options&" .. path] end
local function has_rule_keys()
	for k in pairs(CFG) do if k:find("^options&coop/coop_session/") then return true end end
	return false
end
local function has_other_keys() -- a stock option or an MCM key of the machine
	for k in pairs(CFG) do
		if k:find("^mcm&") or (k:find("^options&") and not k:find("^options&coop/coop_session/")) then return true end
	end
	return false
end
local function copy(t)
	local o = {}
	for k, v in pairs(t) do o[k] = v end
	return o
end
local function T(id) return STRINGS[id] or id end

-- the game settings: the catalog, the record and the view are the real scripts; the host runtime is a stand-in
load_module("coop_game_schema")
load_module("coop_game_record")
load_module("coop_game_settings_view")
local DEFAULTS_BASE = {
	["c|coop_death_mode"] = "checkpoint", ["c|coop_death_drop"] = "drop", ["c|coop_autosave_interval"] = "10",
	["c|coop_death_share"] = "100",
	["o|video/x"] = "1", ["o|gameplay/diff/b"] = "2", ["m|zzz/other"] = "5", -- 2 other options, 1 of an addon
}
DEFAULTS, STAGED, STAGE_OK = copy(DEFAULTS_BASE), {}, true
local function reset_defaults() DEFAULTS = copy(DEFAULTS_BASE) end
coop_game_settings = {
	defaults = function() return DEFAULTS end, -- the table itself: the screen must copy it
	stage_new = function(record)
		STAGED[#STAGED + 1] = record
		return STAGE_OK
	end,
}

-- ------------------------------------------------------------------------------------------------ xml / windows
local function rich_window(path)
	local w = window(path)
	w.checked = false
	w.items = {}
	function w:SetCheck(b) self.checked = b and true or false end
	function w:GetCheck() return self.checked end
	function w:ClearList() self.items = {}; self.cur = nil end
	function w:AddItem(text, id) self.items[#self.items + 1] = { text = text, id = id } end
	function w:CurrentID() return self.cur or -1 end
	return w
end

XML_FILES["ui_mm_faction_select.xml"] = xml_paths(REF .. "configs/ui/ui_mm_faction_select.xml")
XML_FILES["soulslike_ui_mm_gamemode.xml"] = {
	["main_dialog"] = true, ["main_dialog:options"] = true,
	["main_dialog:options:cap_check_soulslike_mode"] = true, ["main_dialog:options:check_soulslike_mode"] = true,
}
XML_FILES["ui_coop_newgame.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_newgame.xml")

local base_xml = CScriptXmlInit
function CScriptXmlInit()
	local x = base_xml()
	local function init(self, path, parent)
		if not self.paths[path] then MISSING_PATHS[#MISSING_PATHS + 1] = self.file .. ": " .. path end
		local w = rich_window(path)
		w.parent = parent
		return w
	end
	for _, n in ipairs({ "InitFrame", "InitStatic", "InitTextWnd", "Init3tButton", "InitEditBox", "InitScrollView",
		"InitCheck", "InitComboBox" }) do
		x[n] = init
	end
	return x
end

-- ------------------------------------------------------------------------------------------------ stock screen
-- the real stock script (ui_mm_faction_select.script): the fields and the registered names this test relies on
local STOCK_FIELDS = {
	{ "ck_story", "check_story" }, { "ck_routes", "check_routes" }, { "list_difficulty", "list_difficulty" },
	{ "list_economy", "list_economy" },
	{ "ck_azazel_mode", "check_azazel_mode" }, { "ck_hardcore", "check_hardcore" },
	{ "list_hardcore_lives", "list_hardcore_lives" }, { "list_hardcore_regen", "list_hardcore_regen" },
	{ "ck_campfire", "check_campfire" }, { "ck_conditions", "check_conditions" }, { "list_timer", "list_timer" },
	{ "ck_survival", "check_survival" }, { "ck_warfare", "check_warfare" },
}
do
	local fh = io.open(REF .. "scripts/ui_mm_faction_select.script", "rb")
	if not fh then
		print("  note: the stock script is not here (" .. REF .. "), field names not checked against it")
	else
		local src = fh:read("*a")
		fh:close()
		local missing = {}
		for _, f in ipairs(STOCK_FIELDS) do
			if not src:find("self%." .. f[1] .. " = xml:Init") then missing[#missing + 1] = f[1] end
			if not src:find("self:Register%(self%." .. f[1] .. ",%s*\"" .. f[2] .. "\"%)") then missing[#missing + 1] = f[2] end
			if not src:find("self%." .. f[1] .. "_cap = xml:InitStatic") then missing[#missing + 1] = f[1] .. "_cap" end
		end
		check(#missing == 0, "the stock script has the fields this test models (" .. table.concat(missing, ",") .. ")")
		for _, key in ipairs({ "new_game_hardcore_mode", "new_game_azazel_mode", "new_game_survival_mode",
			"new_game_campfire_mode", "new_game_conditions_mode", "new_game_opened_routes", "new_game_warfare",
			"new_game_timer_mode", "new_game_story_mode" }) do
			if not src:find('"' .. key .. '"', 1, true) then missing[#missing + 1] = key end
		end
		check(#missing == 0, "and the config keys it writes (" .. table.concat(missing, ",") .. ")")
	end
end

-- the stock layout (ui_mm_faction_select.xml, caption x / y); the check box is 40 left and 1 up
local OPTION_AT = {
	story = { 100, 30 }, azazel_mode = { 100, 60 }, survival = { 100, 90 }, routes = { 100, 120 },
	warfare = { 371, 30 }, hardcore = { 371, 60 }, hardcore_lives = { 406, 90 }, hardcore_regen = { 406, 120 },
	campfire = { 679, 60 }, conditions = { 679, 90 }, timer = { 715, 120 },
}

class "UINewGame" (CUIScriptWnd)
function UINewGame:__init(owner)
	self.owner = owner
	self.access = true
	self.selected_faction = "stalker"
	self.selected_difficulty, self.selected_economy = "st_diff_1", "st_econ_1"
	self.table_hardcore_lives = { { 1, "st_lives" }, { 2, "st_lives" }, { 3, "st_lives" } }
	self.table_hardcore_regen = { { nil, "st_off" }, { 72, "st_days" } }
	self.table_timer = { { nil, "st_off" }, { 10, "st_min" } }
	self.selected_hardcore_lives = self.table_hardcore_lives[1]
	self.selected_hardcore_regen = self.table_hardcore_regen[1]
	self.selected_timer = self.table_timer[1]
	self:Main_Controls()
	self:Main_CallBacks()
end
function UINewGame:Main_Controls()
	local xml = CScriptXmlInit()
	self.xml = xml
	xml:ParseFile("ui_mm_faction_select.xml")
	self.dialog = xml:InitStatic("main_dialog:frame_back", self)
	self.character_name = xml:InitEditBox("main_dialog:input_name", self.dialog)
	self:Register(self.character_name, "input_name")
	self.character_name:SetText("Stalker")
	self.scroll_options = xml:InitScrollView("main_dialog:scroll_options", self.dialog)
	self.templ_options = xml:InitStatic("main_dialog:templ_options", nil)
	self.templ_options:SetWndSize(vector2():set(880, 180))
	local function option(field, id, make, path)
		local cap = xml:InitStatic("main_dialog:options:cap_" .. path, self.templ_options)
		local ctl = make(xml, "main_dialog:options:" .. path, self.templ_options)
		local at = OPTION_AT[id]
		cap:SetWndPos(vector2():set(at[1], at[2]))
		ctl:SetWndPos(vector2():set(at[1] - 40, at[2] - 1))
		self[field .. "_cap"] = cap
		self[field] = ctl
		self:Register(ctl, path)
	end
	local function check_box(x, p, parent) return x:InitCheck(p, parent) end
	local function combo(x, p, parent) return x:InitComboBox(p, parent) end
	self.list_difficulty_cap = xml:InitStatic("main_dialog:list_difficulty_cap", self.dialog)
	self.list_difficulty = xml:InitComboBox("main_dialog:list_difficulty", self.dialog)
	self:Register(self.list_difficulty, "list_difficulty")
	self.list_economy_cap = xml:InitStatic("main_dialog:list_economy_cap", self.dialog)
	self.list_economy = xml:InitComboBox("main_dialog:list_economy", self.dialog)
	self:Register(self.list_economy, "list_economy")
	option("ck_story", "story", check_box, "check_story")
	self.ck_story:SetCheck(true)
	option("ck_hardcore", "hardcore", check_box, "check_hardcore")
	option("ck_azazel_mode", "azazel_mode", check_box, "check_azazel_mode")
	option("ck_survival", "survival", check_box, "check_survival")
	option("ck_warfare", "warfare", check_box, "check_warfare")
	option("ck_campfire", "campfire", check_box, "check_campfire")
	option("ck_routes", "routes", check_box, "check_routes")
	self.ck_routes:SetCheck(true)
	option("ck_conditions", "conditions", check_box, "check_conditions")
	option("list_hardcore_lives", "hardcore_lives", combo, "list_hardcore_lives")
	option("list_hardcore_regen", "hardcore_regen", combo, "list_hardcore_regen")
	option("list_timer", "timer", combo, "list_timer")
	self.ck_states = {
		ck_survival = false, ck_hardcore = false, ck_azazel_mode = false, ck_story = false, ck_campfire = false,
		ck_conditions = false, ck_routes = false, ck_warfare = false, list_difficulty = false, list_economy = false,
		list_hardcore_lives = false, list_hardcore_regen = false, list_timer = false,
	}
end
function UINewGame:Main_CallBacks()
	self:AddCallback("btn_start", ui_events.BUTTON_CLICKED, self.OnStartGame, self)
	self:AddCallback("list_timer", ui_events.LIST_ITEM_SELECT, self.OnSelectTimer, self)
end
function UINewGame:OnSelectTimer() self.selected_timer = self.table_timer[self.list_timer:CurrentID()] end
function UINewGame:OnStartGame()
	if not self.access then return end
	local name = self.character_name:GetText()
	if name == "" then return end
	local regen = self.selected_hardcore_regen[1]
	local timer = self.selected_timer[1]
	local c = axr_main.config
	local function on(ck) return ck and ck:GetCheck() and true or nil end
	c:w_value("character_creation", "new_game_difficulty", 1)
	c:w_value("character_creation", "new_game_hardcore_mode", on(self.ck_hardcore))
	c:w_value("character_creation", "new_game_hardcore_mode_lives", self.ck_hardcore and self.selected_hardcore_lives[1] or nil)
	c:w_value("character_creation", "new_game_hardcore_mode_regenerate", self.ck_hardcore and regen or nil)
	c:w_value("character_creation", "new_game_story_mode", on(self.ck_story))
	c:w_value("character_creation", "new_game_azazel_mode", on(self.ck_azazel_mode))
	c:w_value("character_creation", "new_game_survival_mode", on(self.ck_survival))
	c:w_value("character_creation", "new_game_campfire_mode", on(self.ck_campfire))
	c:w_value("character_creation", "new_game_conditions_mode", on(self.ck_conditions))
	c:w_value("character_creation", "new_game_opened_routes", on(self.ck_routes))
	c:w_value("character_creation", "new_game_warfare", on(self.ck_warfare))
	c:w_value("character_creation", "new_game_timer_mode", timer or nil)
	c:w_value("character_creation", "new_game_character_name", name)
	c:save()
	self.owner:StartGame()
end
ui_mm_faction_select = { UINewGame = UINewGame }

-- GAMMA's Soulslike injector (souslike_gamemode_injector_mcm.script), written the same way: wrappers of the class
-- methods by assignment, a check box that is not in the stock script, the shifted left column
local GAMMA = false
do
	local _controls, _start = UINewGame.Main_Controls, UINewGame.OnStartGame
	function UINewGame.Main_Controls(self, rand)
		_controls(self, rand)
		if not GAMMA then return end
		local function move(ctrl, dx, dy)
			local p = ctrl:GetWndPos()
			ctrl:SetWndPos(vector2():set(p.x + dx, p.y + dy))
		end
		move(self.ck_story_cap, 0, -10); move(self.ck_story, 0, -10)
		move(self.ck_azazel_mode_cap, 0, -15); move(self.ck_azazel_mode, 0, -15)
		move(self.ck_survival_cap, 0, -20); move(self.ck_survival, 0, -20)
		local xml = CScriptXmlInit()
		xml:ParseFile("soulslike_ui_mm_gamemode.xml")
		self.ck_soulslike_mode_cap = xml:InitStatic("main_dialog:options:cap_check_soulslike_mode", self.templ_options)
		self.ck_soulslike_mode = xml:InitCheck("main_dialog:options:check_soulslike_mode", self.templ_options)
		self.ck_soulslike_mode_cap:SetWndPos(vector2():set(100, 95))
		self.ck_soulslike_mode:SetWndPos(vector2():set(60, 94))
		self:Register(self.ck_soulslike_mode, "check_soulslike_mode")
		self.ck_states["ck_soulslike_mode"] = false
	end
	function UINewGame.OnStartGame(self)
		if GAMMA and self.access and self.character_name:GetText() ~= "" then
			axr_main.config:w_value("character_creation", "new_game_soulslike_mode",
				self.ck_soulslike_mode and self.ck_soulslike_mode:GetCheck() and true or nil)
		end
		_start(self)
	end
end
local STOCK_ON_START = UINewGame.OnStartGame

-- the main menu: ShowFactionUI as the stock one (ui_main_menu.script)
ui_main_menu = { main_menu = {} }
local MM = ui_main_menu.main_menu
STARTS = {}
function MM:ShowDialog() end
function MM:HideDialog() end
function MM:Show() end
function MM:StartGame()
	STARTS[#STARTS + 1] = { exec = #EXEC, staged = #STAGED, keys = {} }
	for _, k in ipairs({ "new_game_hardcore_mode", "new_game_timer_mode", "new_game_soulslike_mode" }) do
		STARTS[#STARTS].keys[k] = cfg(k)
	end
end
function MM:ShowFactionUI()
	if self.new_game_dlg == nil then self.new_game_dlg = ui_mm_faction_select.UINewGame(self) end
	self.new_game_dlg:ShowDialog(true)
	self:HideDialog()
	self:Show(false)
end
local STOCK_SHOW = MM.ShowFactionUI
local function new_menu() return setmetatable({}, { __index = MM }) end

-- ------------------------------------------------------------------------------------------------ helpers
local HIDDEN = { "ck_azazel_mode", "ck_hardcore", "list_hardcore_lives", "list_hardcore_regen", "ck_soulslike_mode",
	"ck_campfire", "ck_conditions", "list_timer", "ck_survival", "ck_warfare" }
local KEPT = { "ck_story", "ck_routes", "list_difficulty", "list_economy" }
local CFG_KEYS = { "new_game_hardcore_mode", "new_game_hardcore_mode_regenerate", "new_game_azazel_mode",
	"new_game_survival_mode", "new_game_campfire_mode", "new_game_conditions_mode", "new_game_warfare",
	"new_game_timer_mode", "new_game_soulslike_mode" }

local function is_gone(dlg, field)
	local c, cap = dlg[field], dlg[field .. "_cap"]
	if c == nil then return true end
	return c.shown == false and c.enabled == false and (cap == nil or cap.shown == false)
end
local function is_visible(dlg, field)
	local c, cap = dlg[field], dlg[field .. "_cap"]
	return c ~= nil and c.shown == true and c.enabled == true and cap ~= nil and cap.shown == true
end
local function coop_info() INFO.pending_host = 27960; INFO.host = false; INFO.client = false; INFO.active = false end
local function single_info() INFO.pending_host = nil; INFO.host = false; INFO.client = false; INFO.active = false end
local function reset_console()
	CONSOLE.coop_death_mode, CONSOLE.coop_death_drop, CONSOLE.coop_autosave_interval = "checkpoint", "drop", "10"
	CONSOLE.coop_death_share = "100.00000"
	EXEC = {}
	STAGED, STAGE_OK = {}, true
	reset_defaults()
	for k in pairs(CFG) do
		if k:find("^options&") or k:find("^mcm&") then CFG[k] = nil end
	end
end
local function click_start(dlg)
	local cb = dlg.callbacks["btn_start#" .. ui_events.BUTTON_CLICKED]
	assert(cb, "btn_start has no callback")
	return cb.f(cb.obj)
end
-- picks entry `index` in the combo of the catalog item `key`, as a click in the list does
local function pick_key(dlg, key, index)
	local r = assert(dlg.coop_view:row(key), "no row for " .. key)
	r.list.cur = index
	local cb = dlg.callbacks[r.name .. "#" .. ui_events.LIST_ITEM_SELECT]
	assert(cb, key .. " has no select callback")
	cb.f(cb.obj)
end
local function item_index(key, value) -- position of a value in the catalog item's list
	for i, e in ipairs(coop_game_schema.item(key).values) do
		if e[1] == value then return i end
	end
	error("no value " .. tostring(value) .. " in " .. key)
end
local function shown(dlg, key) return dlg.coop_view:row(key).list.text end
local function clear_cfg()
	for k in pairs(CFG) do if k:find("^character_creation&") then CFG[k] = nil end end
end

print("== module and menu seam")
local m = load_module("coop_newgame_modes")
check(type(m.install) == "function" and type(m.is_coop_new_game) == "function" and type(m.on_game_start) == "function",
	"coop_newgame_modes has install / is_coop_new_game / on_game_start")
local callbacks = {}
function RegisterScriptCallback(name, f) callbacks[name] = f end
local mx = load_module("modxml_coop_newgame")
mx.on_xml_read()
check(callbacks.main_menu_on_init == mx.main_menu_init, "modxml_coop_newgame registers main_menu_on_init (a module function)")
mx.main_menu_init({})
check(MM.ShowFactionUI ~= STOCK_SHOW, "the menu init puts a wrapper on main_menu:ShowFactionUI")
local wrapped = MM.ShowFactionUI
mx.main_menu_init({})
check(MM.ShowFactionUI == wrapped, "a second menu init does not wrap again")
do
	local saved = coop
	coop = nil
	callbacks = {}
	mx.on_xml_read()
	check(next(callbacks) == nil, "an exe without co-op: nothing registered")
	coop = saved
end

print("== which new game is a co-op host's")
single_info(); CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx"
check(m.is_coop_new_game() == false, "plain single player: no")
coop_info()
check(m.is_coop_new_game() == true, "host_when_ready pending (the Co-op window, Host > New game): yes")
single_info(); INFO.host = true; INFO.active = true
check(m.is_coop_new_game() == true, "a hosting session: yes")
single_info(); INFO.client = true; INFO.active = true; INFO.pending_host = 27960
check(m.is_coop_new_game() == false, "a connected client never sets up the group's game: no")
single_info(); CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx -coop_host 27960 -start server(all/single/alife/new) client(localhost)"
check(m.is_coop_new_game() == true, "launched with -coop_host (tools\\launch.ps1 -HostSession): yes")
CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_b.ltx -coop_connect 127.0.0.1"
check(m.is_coop_new_game() == false, "launched with -coop_connect only: no")
CMD = "AnomalyCoopDX11AVX.exe"
do
	local saved = coop
	coop = nil
	coop_info()
	check(m.is_coop_new_game() == false, "an exe without the co-op namespace: no")
	coop = saved
	single_info()
end

print("== single player: the stock screen, untouched")
reset_console(); clear_cfg(); GAMMA = true
local menu = new_menu()
menu:ShowFactionUI()
local sp = menu.new_game_dlg
check(sp ~= nil and sp.coop_modes_applied == nil, "the dialog is the stock one")
local all_shown = true
for _, f in ipairs(HIDDEN) do all_shown = all_shown and is_visible(sp, f) end
for _, f in ipairs(KEPT) do all_shown = all_shown and is_visible(sp, f) end
check(all_shown, "all 14 controls are shown and enabled")
check(sp.ck_story_cap:GetWndPos().y == 20 and sp.ck_routes_cap:GetWndPos().y == 120, "nothing moved (GAMMA's own shift stays)")
check(sp.list_coop_death_mode == nil and sp.coop_hint == nil, "no co-op block")
check(sp.callbacks["btn_start#" .. ui_events.BUTTON_CLICKED].f == STOCK_ON_START, "the start button is the stock handler")
sp.ck_hardcore:SetCheck(true); sp.ck_soulslike_mode:SetCheck(true); sp.ck_campfire:SetCheck(true)
sp.selected_timer = sp.table_timer[2]
click_start(sp)
check(cfg("new_game_hardcore_mode") == "true" and cfg("new_game_soulslike_mode") == "true"
	and cfg("new_game_campfire_mode") == "true" and cfg("new_game_timer_mode") == "10", "a start writes the chosen modes as before")
check(#EXEC == 0, "and writes no console variable")
menu:ShowFactionUI()
check(menu.new_game_dlg == sp, "the cached stock dialog is reused as before")

print("== co-op host: modes hidden and off, four stay")
for _, gamma in ipairs({ true, false }) do
	GAMMA = gamma
	reset_console(); clear_cfg(); coop_info()
	MISSING_PATHS = {}
	local mn = new_menu()
	mn:ShowFactionUI()
	local d = mn.new_game_dlg
	local label = gamma and "GAMMA" or "stock"
	check(d.coop_modes_applied == true, label .. ": the dialog is marked as set up for co-op")
	local bad = {}
	for _, f in ipairs(HIDDEN) do
		if d[f] ~= nil then
			if not is_gone(d, f) then bad[#bad + 1] = f end
			if f:find("^ck_") and d[f]:GetCheck() then bad[#bad + 1] = f .. " checked" end
			if d.ck_states[f] ~= nil then bad[#bad + 1] = f .. " still has a hover hint" end
		elseif gamma or f ~= "ck_soulslike_mode" then
			bad[#bad + 1] = f .. " missing"
		end
	end
	check(#bad == 0, label .. ": the 10 modes are hidden, disabled and unchecked (" .. table.concat(bad, ",") .. ")")
	local kept_ok = {}
	for _, f in ipairs(KEPT) do if not is_visible(d, f) then kept_ok[#kept_ok + 1] = f end end
	check(#kept_ok == 0, label .. ": story, open Zone, difficulty and economy stay shown (" .. table.concat(kept_ok, ",") .. ")")
	check(d.ck_story:GetCheck() == true and d.ck_routes:GetCheck() == true, label .. ": and keep their default ticks")
	check(d.ck_states.ck_story == false and d.ck_states.ck_routes == false and d.ck_states.list_difficulty == false
		and d.ck_states.list_economy == false, label .. ": the four keep their hover hints")
	check(d.selected_timer[1] == nil and d.selected_hardcore_regen[1] == nil, label .. ": timer and extra lives are on 'off'")
	check(d.selected_hardcore_lives == d.table_hardcore_lives[1], label .. ": lives on the first entry")
	local sx, sy = d.ck_story_cap:GetWndPos().x, d.ck_story_cap:GetWndPos().y
	local rx, ry = d.ck_routes_cap:GetWndPos().x, d.ck_routes_cap:GetWndPos().y
	check(sx == 100 and sy == 30 and d.ck_story:GetWndPos().y == 29 and d.ck_story:GetWndPos().x == 60,
		label .. ": story is the first row of its column, no hole")
	check(rx == 100 and ry == 60 and d.ck_routes:GetWndPos().y == 59 and d.ck_routes:GetWndPos().x == 60,
		label .. ": the open Zone is the second row")
	check(#MISSING_PATHS == 0, label .. ": every xml path exists in the layouts (" .. table.concat(MISSING_PATHS, ", ") .. ")")
	check(d.callbacks["btn_start#" .. ui_events.BUTTON_CLICKED].f ~= STOCK_ON_START, label .. ": the start button is ours")
end

print("== co-op host: the game settings block")
GAMMA = true
reset_console(); clear_cfg(); coop_info()
MISSING_PATHS = {}
local mn = new_menu()
mn:ShowFactionUI()
local d = mn.new_game_dlg
check(d.coop_header and d.coop_header.path == "main_dialog:options:cap_gs_header" and d.coop_header.shown ~= false, "the block has its header")
check(d.coop_header.parent == nil or d.coop_header.parent == d.templ_options, "inside the options frame")
check(STRINGS.st_coop_newgame_header == "Game settings" and RUS.st_coop_newgame_header ~= nil, "it is 'Game settings' (the old 'Co-op mode' block is gone)")
check(d.list_coop_death_mode == nil and d.list_coop_death_drop == nil and d.list_coop_death_share == nil and d.list_coop_autosave == nil
	and d.coop_modes == nil, "none of the four lists of the old block is left")
local view = d.coop_view
check(view ~= nil and #view.tabs == 5 and view.tabs[1] == "death" and view.tabs[2] == "party" and view.tabs[3] == "world"
	and view.tabs[4] == "saves" and view.tabs[5] == "other", "tabs: death, party, world, saves, other (difficulty is the stock lists)")
local tab_texts = {}
for _, tab in ipairs(view.tabs) do tab_texts[#tab_texts + 1] = view.buttons[tab].text end
check(table.concat(tab_texts, "|") == "Death|Party|World|Saves|Other", "the strip: " .. table.concat(tab_texts, "|"))
check(view.tab == "death" and view.scrolls.death.shown and not view.scrolls.world.shown, "the first tab is open")
check(#view.rows.death == 12 and #view.rows.party == 15 and #view.rows.world == 15 and #view.rows.saves == 2,
	"rows: 12 / 15 / 15 (no addon) / 2")
check(view.rows.death[1].list.parent == view.rows.death[1].row and d.registered[view.rows.death[1].name] == view.rows.death[1].list,
	"a combo sits in its row and is registered in the dialog")
check(d.coop_hint and d.coop_hint.text == STRINGS.st_coop_newgame_hint and d.coop_hint.shown ~= false, "the hint is under the block")
check(STRINGS.st_coop_newgame_hint:find("Co%-op > Game settings") ~= nil, "and points to Co-op > Game settings")
check(view.values["c|coop_death_mode"] == "checkpoint" and view.values["m|zzz/other"] == "5",
	"the values of the view are those of coop_game_settings.defaults() (a copy of them)")
view.values["c|coop_death_mode"] = "hardcore"
check(DEFAULTS["c|coop_death_mode"] == "checkpoint", "changing the view does not change defaults()'s table")
view.values["c|coop_death_mode"] = "checkpoint"
check(d.coop_snapshot_at ~= nil and d.coop_snapshot_at:find("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$") ~= nil, "the time of the snapshot is taken: " .. tostring(d.coop_snapshot_at))
view:select("other")
check(view.page_text.other.text == string.format(STRINGS.st_coop_newgame_other, "2", "1", d.coop_snapshot_at),
	"'other': the number of other options (2), of the addons' (1) and the time: " .. tostring(view.page_text.other.text))
view:select("saves")
check(view.note_text.saves.text == STRINGS.st_coop_newgame_saves_note, "'saves' ends with its note")
view:select("death")
check(#EXEC == 0 and #STAGED == 0, "opening the screen writes nothing and stages nothing")
check(#MISSING_PATHS == 0, "every xml path of the block exists in the layout (" .. table.concat(MISSING_PATHS, ", ") .. ")")

print("== co-op host: the dynamic anomalies addon, if there is one")
ui_mcm = { check_opt_table = function(path) return path:find("^drx_da/") ~= nil end }
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg; view = d.coop_view
check(#view.rows.world == 18 and view:row("m|drx_da/anomaly_amount_modifier") ~= nil, "ui_mcm has its options: the 3 items are rows (18 in 'world')")
ui_mcm = nil
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(#d.coop_view.rows.world == 15, "without it they are not")

print("== co-op host: Start stages the new game")
ui_mcm = { check_opt_table = function() return true end }
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg; view = d.coop_view
d.selected_faction = "dolg"
d.ck_story:SetCheck(false); d.ck_routes:SetCheck(true)
d.selected_difficulty, d.selected_economy = "st_diff_2", "st_econ_3"
d.character_name:SetText("Strelok")
-- the user (or a mod) switched the hidden modes on, then chose
d.ck_hardcore:SetCheck(true); d.ck_soulslike_mode:SetCheck(true); d.ck_azazel_mode:SetCheck(true)
d.selected_timer = d.table_timer[2]
pick_key(d, "c|coop_death_mode", 2)
pick_key(d, "c|coop_death_drop", item_index("c|coop_death_drop", "keep"))
pick_key(d, "c|coop_autosave_interval", item_index("c|coop_autosave_interval", 0))
pick_key(d, "o|coop/coop_session/party_fast_travel", 2)
pick_key(d, "o|coop/coop_session/gather_radius", item_index("o|coop/coop_session/gather_radius", 50))
pick_key(d, "o|alife/event/emission_state", 2)
pick_key(d, "o|alife/event/emission_frequency", item_index("o|alife/event/emission_frequency", 48))
pick_key(d, "m|drx_da/anomaly_amount_modifier", item_index("m|drx_da/anomaly_amount_modifier", 2))
check(#EXEC == 0 and #STAGED == 0 and not has_rule_keys(), "picking in the lists writes nothing and stages nothing yet")
click_start(d)
local s = STARTS[#STARTS]
check(s ~= nil and #STAGED == 1 and s.staged == 1, "the record was staged before the world start")
local rec = STAGED[1]
check(rec and rec.faction == "dolg", "faction = the dialog's selected faction (dolg)")
check(rec and rec.world and rec.world.story == false and rec.world.routes == true and rec.world.difficulty == 2 and rec.world.economy == 3,
	"world = the stock controls: story off, open Zone on, difficulty 2, economy 3")
check(rec and rec.name == "Strelok" and rec.rev == 0 and rec.v == 1 and type(rec.id) == "string" and rec.id:find("^%x%x%x%x%x%x%x%x%-%x%x%x%x$") ~= nil,
	"name, rev 0, version 1 and an id of the form %08x-%04x: " .. tostring(rec and rec.id))
check(rec.machine_snapshot_at == d.coop_snapshot_at, "the record carries the time of the machine snapshot")
local rv = rec.values
check(rv["c|coop_death_mode"] == "hardcore" and rv["c|coop_death_drop"] == "keep" and rv["c|coop_autosave_interval"] == "0",
	"the console rules of the record are the chosen ones")
check(rv["o|coop/coop_session/party_fast_travel"] == "false" and rv["o|coop/coop_session/gather_radius"] == "50",
	"the session rules too")
check(rv["o|alife/event/emission_state"] == "false" and rv["o|alife/event/emission_frequency"] == "48"
	and rv["m|drx_da/anomaly_amount_modifier"] == "2", "and the world rules, the addon's key too (they live in the record)")
check(rv["c|coop_death_share"] == "100" and rv["c|coop_bleedout"] == "60" and rv["o|alife/general/alife_stalker_pop"] == "0.5"
	and rv["m|drx_da/disable_new_anomalies"] == "false", "everything not chosen holds its default, complete")
check(rv["m|zzz/other"] == "5" and rv["o|video/x"] == "1", "the other options of the machine are in the record as they were")
check(rv["faction"] == nil and rv["w|story"] == nil, "no faction and no world flag among the values (they are fields of the record)")
check(EXEC[1] == "coop_death_mode hardcore" and EXEC[2] == "coop_death_drop keep" and EXEC[3] == "coop_autosave_interval 0"
	and EXEC[4] == "cfg_save" and #EXEC == 4, "the console is written for c|* only, changed ones, then cfg_save (" .. table.concat(EXEC, "; ") .. ")")
check(s and s.exec == 4, "all of it before the start of the world")
check(CONSOLE.coop_death_mode == "hardcore" and CONSOLE.coop_death_drop == "keep" and CONSOLE.coop_autosave_interval == "0",
	"the machine remembers the rules for the next new game")
check(cfg_options("coop/coop_session/party_fast_travel") == "false" and cfg_options("coop/coop_session/gather_radius") == "50",
	"the changed session rules are written to axr [options]")
check(cfg_options("coop/coop_session/travel_time") == nil and cfg_options("coop/coop_session/give_radius") == nil
	and cfg_options("coop/coop_session/sleep_rule") == nil, "and the unchanged ones are not")
check(cfg_options("alife/event/emission_state") == nil and cfg_options("alife/event/emission_frequency") == nil
	and CFG["mcm&drx_da/anomaly_amount_modifier"] == nil and not has_other_keys(), "stock options and MCM keys of the machine are not written")
local left = {}
for _, k in ipairs(CFG_KEYS) do if cfg(k) ~= nil then left[#left + 1] = k end end
check(#left == 0, "none of the 9 hidden modes reaches the config, whatever was ticked (" .. table.concat(left, ",") .. ")")
check(cfg("new_game_story_mode") == nil and cfg("new_game_opened_routes") == "true" and cfg("new_game_difficulty") == "1",
	"the stock start still ran with the stock controls (story off, open Zone on)")
check(cfg("new_game_character_name") == "Strelok", "the name as the stock writes it")
ui_mcm = nil

print("== co-op host: untouched settings stage the machine's values and write nothing")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
click_start(d)
check(#STAGED == 1 and #EXEC == 0, "staged once; no console writes, no cfg_save (" .. table.concat(EXEC, "; ") .. ")")
check(not has_rule_keys() and not has_other_keys(), "and nothing of axr")
check(STAGED[1].faction == "stalker" and STAGED[1].world.story == true and STAGED[1].world.routes == true
	and STAGED[1].world.difficulty == 1 and STAGED[1].world.economy == 1, "the stock defaults: stalker, story, open Zone, 1 / 1")
check(STAGED[1].values["c|coop_death_mode"] == "checkpoint" and STAGED[1].values["c|coop_autosave_interval"] == "10"
	and STAGED[1].values["m|zzz/other"] == "5", "the record holds the values of defaults()")
check(cfg("new_game_character_name") == "Stalker", "the stock start ran")

print("== co-op host: picked and picked back")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
pick_key(d, "c|coop_death_share", 4)
pick_key(d, "c|coop_death_share", item_index("c|coop_death_share", 100))
pick_key(d, "c|coop_death_drop", 4)
pick_key(d, "c|coop_death_drop", 1)
pick_key(d, "o|coop/coop_session/travel_time", 2)
pick_key(d, "o|coop/coop_session/travel_time", 1)
click_start(d)
check(#EXEC == 0 and not has_rule_keys(), "picked back to the machine's values: nothing written (" .. table.concat(EXEC, "; ") .. ")")
check(STAGED[1].values["c|coop_death_share"] == "100" and STAGED[1].values["c|coop_death_drop"] == "drop", "and the record has them")

print("== co-op host: keep and the share")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
pick_key(d, "c|coop_death_share", item_index("c|coop_death_share", 150))
pick_key(d, "c|coop_death_drop", 4)
check(d.coop_view:row("c|coop_death_share").list.enabled == false, "'keep': the share row is greyed (nothing falls)")
click_start(d)
check(EXEC[1] == "coop_death_drop keep" and EXEC[2] == "coop_death_share 150" and EXEC[3] == "cfg_save" and #EXEC == 3,
	"nothing is lost and 150 %: both written, then cfg_save (" .. table.concat(EXEC, "; ") .. ")")
check(CONSOLE.coop_death_drop == "keep" and CONSOLE.coop_death_share == "150", "the console holds keep and 150")
reset_console(); clear_cfg()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
pick_key(d, "c|coop_death_share", 1)
click_start(d)
check(EXEC[1] == "coop_death_share 50" and EXEC[2] == "cfg_save" and #EXEC == 2, "50 % alone: only the share is written (" .. table.concat(EXEC, "; ") .. ")")

print("== co-op host: the machine's values, odd ones too")
reset_console(); clear_cfg(); coop_info()
DEFAULTS["c|coop_death_mode"], DEFAULTS["c|coop_death_drop"], DEFAULTS["c|coop_autosave_interval"] = "hardcore", "corpse", "15"
DEFAULTS["c|coop_death_share"] = "75.00000"
CONSOLE.coop_death_mode, CONSOLE.coop_death_drop, CONSOLE.coop_autosave_interval = "hardcore", "corpse", "15"
CONSOLE.coop_death_share = "75.00000"
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(shown(d, "c|coop_death_mode") == T("st_coop_game_death_mode_hardcore") and shown(d, "c|coop_death_drop") == T("st_coop_game_death_drop_corpse"),
	"hardcore and corpse are shown")
check(shown(d, "c|coop_autosave_interval") == T("st_coop_game_autosave_interval_15") and #d.coop_view:row("c|coop_autosave_interval").list.items == 7,
	"15 min is a list entry")
check(shown(d, "c|coop_death_share") == "75 %" and #d.coop_view:row("c|coop_death_share").list.items == 5,
	"a share from the options page or the console (75) is kept as an entry: " .. shown(d, "c|coop_death_share"))
click_start(d)
check(#EXEC == 0, "and written back unchanged: nothing (" .. table.concat(EXEC, "; ") .. ")")
check(STAGED[1].values["c|coop_death_share"] == "75" and STAGED[1].values["c|coop_autosave_interval"] == "15", "the record keeps them (75, 15)")
reset_defaults()
-- an odd console value shows the default and is not written back
reset_console(); clear_cfg()
CONSOLE.coop_death_share = "300.00000"
DEFAULTS["c|coop_death_share"] = "300.00000"
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(shown(d, "c|coop_death_share") == T("st_coop_game_death_share_100") and #d.coop_view:row("c|coop_death_share").list.items == 4,
	"a share outside 0..200 shows the default, no entry of its own")
click_start(d)
check(#EXEC == 0 and STAGED[1].values["c|coop_death_share"] == "100", "not written to the console; the record has the default")
reset_defaults()

print("== co-op host: a start that does not start")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
pick_key(d, "c|coop_death_mode", 2)
pick_key(d, "o|coop/coop_session/gather_radius", 4)
d.character_name:SetText("")
local starts_before = #STARTS
click_start(d)
check(#STARTS == starts_before and #EXEC == 0 and #STAGED == 0 and not has_rule_keys(),
	"no name: the stock refuses, nothing is staged, no console, no axr")
d.character_name:SetText("Strelok"); d.access = false
click_start(d)
check(#STARTS == starts_before and #EXEC == 0 and #STAGED == 0 and not has_rule_keys(), "a pop-up is open: same")
d.access = true
click_start(d)
check(#STARTS == starts_before + 1 and #STAGED == 1 and EXEC[1] == "coop_death_mode hardcore"
	and cfg_options("coop/coop_session/gather_radius") == "50", "then the start goes through, staged once")
click_start(d)
check(#STAGED == 2, "a second click is a second start (the stock decides what it does with it)")

print("== co-op host: coop_game_settings is missing or fails")
local saved_gs = coop_game_settings
local STAGES_AFTER = { ["missing"] = 0, ["stage false"] = 1, ["stage throws"] = 0, ["defaults throws"] = 1 }
for _, case in ipairs({ "missing", "stage false", "stage throws", "defaults throws" }) do
	reset_console(); clear_cfg(); coop_info(); LOG = {}
	if case == "missing" or case == "defaults throws" then CONSOLE.coop_death_drop = "corpse" end
	if case == "missing" then
		coop_game_settings = nil
	else
		coop_game_settings = {
			defaults = function() if case == "defaults throws" then error("boom") end return copy(DEFAULTS) end,
			stage_new = function(r)
				if case == "stage throws" then error("boom") end
				STAGED[#STAGED + 1] = r
				return case ~= "stage false"
			end,
		}
	end
	mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
	check(d.coop_view ~= nil, case .. ": the block is there")
	if case == "missing" or case == "defaults throws" then
		check(shown(d, "c|coop_death_drop") == T("st_coop_game_death_drop_corpse"), case .. ": it takes the machine's console (corpse)")
		check(shown(d, "c|coop_death_mode") == T("st_coop_game_death_mode_checkpoint"), case .. ": and the catalog's default where the machine has none")
	end
	pick_key(d, "c|coop_death_mode", 2)
	local n_before = #STARTS
	local ok = pcall(click_start, d)
	check(ok and #STARTS == n_before + 1, case .. ": the world start still goes through")
	check(EXEC[1] == "coop_death_mode hardcore" and EXEC[2] == "cfg_save" and #EXEC == 2,
		case .. ": the rules are remembered all the same (" .. table.concat(EXEC, "; ") .. ")")
	check(#STAGED == STAGES_AFTER[case], case .. ": staged " .. STAGES_AFTER[case] .. " time(s)")
	check(log_has("coop%-newgame"), case .. ": and it is logged")
end
coop_game_settings = saved_gs
reset_console(); clear_cfg()

print("== co-op host: the screen follows the kind of game")
reset_console(); clear_cfg(); GAMMA = true
mn = new_menu()
single_info(); mn:ShowFactionUI(); local a = mn.new_game_dlg
coop_info(); mn:ShowFactionUI(); local b = mn.new_game_dlg
check(b ~= a and b.coop_modes_applied == true, "single player -> co-op: a new dialog, set up")
mn:ShowFactionUI(); local c2 = mn.new_game_dlg
check(c2 ~= b and c2.coop_modes_applied == true and c2.coop_view ~= nil,
	"co-op again: built again (the console may have changed meanwhile)")
single_info(); mn:ShowFactionUI(); local e = mn.new_game_dlg
check(e ~= c2 and e.coop_modes_applied == nil and is_visible(e, "ck_hardcore") and e.coop_view == nil,
	"co-op -> single player: the stock dialog again, every mode back")
mn:ShowFactionUI()
check(mn.new_game_dlg == e, "single player again: the cached one")

print("== co-op host: a broken layout does not break the start")
reset_console(); clear_cfg(); coop_info(); LOG = {}
local saved_xml = XML_FILES["ui_coop_newgame.xml"]
XML_FILES["ui_coop_newgame.xml"] = nil
mn = new_menu()
local ok_show = pcall(function() mn:ShowFactionUI() end)
d = mn.new_game_dlg
check(ok_show and d ~= nil, "the screen still opens")
check(log_has("coop%-newgame"), "and the failure is logged")
local still = true
for _, f in ipairs(HIDDEN) do still = still and is_gone(d, f) end
check(still, "the modes are still hidden")
d.ck_hardcore:SetCheck(true)
click_start(d)
check(cfg("new_game_hardcore_mode") == nil and #EXEC == 0 and #STAGED == 0 and d.coop_view == nil,
	"the start still forces them off, no block, no rules written, nothing staged")
XML_FILES["ui_coop_newgame.xml"] = saved_xml

print("== game start: stale modes of a co-op host are cleared")
clear_cfg()
local function stale()
	for _, k in ipairs(CFG_KEYS) do axr_main.config:w_value("character_creation", k, "true") end
	axr_main.config:w_value("character_creation", "new_game_story_mode", true)
	axr_main.config:w_value("character_creation", "new_game_faction", "dolg")
end
stale(); single_info(); CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx -smap2048"
local saves0 = CFG.saves
m.on_game_start()
local remain = 0
for _, k in ipairs(CFG_KEYS) do if cfg(k) ~= nil then remain = remain + 1 end end
check(remain == #CFG_KEYS and CFG.saves == saves0, "single player: the config is not touched")
CMD = "AnomalyCoopDX11AVX.exe -fsltx fsgame_a.ltx -coop_host 27960 -start server(all/single/alife/new) client(localhost)"
m.on_game_start()
remain = 0
for _, k in ipairs(CFG_KEYS) do if cfg(k) ~= nil then remain = remain + 1 end end
check(remain == 0 and CFG.saves == saves0 + 1, "-coop_host: the 9 mode keys are gone and the config is saved")
check(cfg("new_game_story_mode") == "true" and cfg("new_game_faction") == "dolg", "the other keys stay")
m.on_game_start()
check(CFG.saves == saves0 + 1, "nothing left to clear: no second save")
CMD = "AnomalyCoopDX11AVX.exe"
stale(); coop_info()
m.on_game_start()
remain = 0
for _, k in ipairs(CFG_KEYS) do if cfg(k) ~= nil then remain = remain + 1 end end
check(remain == 0, "a host pending after the menu's new game: cleared too")
single_info()


print("== layouts and strings")
-- children of <options>: name -> { x, y, w, h } (the nodes that carry a box)
local function elements(file)
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
	fh:close()
	local out, order = {}, {}
	local body = src:match("<options>(.-)</options>")
	assert(body, file .. ": no <options>")
	for name, x, y, w, h in body:gmatch('<([%w_]+)%s+x="(%-?%d+)"%s+y="(%-?%d+)"%s+width="(%d+)"%s+height="(%d+)"') do
		out[name] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
		order[#order + 1] = name
	end
	return out, order
end
local NAMES = { "cap_gs_header", "btn_gs_tab_1", "btn_gs_tab_2", "btn_gs_tab_3", "btn_gs_tab_4", "btn_gs_tab_5", "gs_tab_mark", "scroll_gs",
	"gs_row", "cap_gs_row", "list_gs_row", "gs_line", "text_gs_line", "text_gs_hint" }
local TABS5 = { "death", "party", "world", "saves", "other" }
local GEOM = {}
for _, lay in ipairs({ { "ui_coop_newgame.xml", 880, 331 }, { "ui_coop_newgame_16.xml", 704, 264 } }) do
	local name, frame_w, col_x = lay[1], lay[2], lay[3]
	local els, order = elements(ROOT .. "configs/ui/" .. name)
	GEOM[name] = els
	local miss, bad = {}, {}
	for _, n in ipairs(NAMES) do
		local e = els[n]
		if not e then
			miss[#miss + 1] = n
		elseif n == "gs_row" or n == "gs_line" or n == "cap_gs_row" or n == "list_gs_row" or n == "text_gs_line" then
			-- a row or a line of text and what is inside: relative to the scroll view / the row, checked below
		elseif e.x < col_x or e.x + e.w > frame_w or e.y < 0 or e.y + e.h > 160 then
			bad[#bad + 1] = n .. string.format(" (%d,%d %dx%d)", e.x, e.y, e.w, e.h)
		end
	end
	check(#miss == 0, name .. ": every element is there (" .. table.concat(miss, ",") .. ")")
	check(#bad == 0, name .. ": inside the options frame (" .. frame_w .. " x 160) and right of the first column (x from " .. col_x
		.. "): " .. table.concat(bad, ", "))
	local hd, t1, sc_, ht = els.cap_gs_header, els.btn_gs_tab_1, els.scroll_gs, els.text_gs_hint
	if hd and t1 and sc_ and ht then
		check(hd.y + hd.h <= t1.y and t1.y + t1.h <= sc_.y and sc_.y + sc_.h <= ht.y and ht.y + ht.h <= 160,
			name .. ": header, tabs, rows, hint: one under the other, the hint ends in the frame")
		local tabs_ok, prev = true, nil
		for i = 1, 5 do
			local t = els["btn_gs_tab_" .. i]
			tabs_ok = tabs_ok and t and t.y == t1.y and t.h == t1.h and (prev == nil or prev.x + prev.w <= t.x)
			prev = t
		end
		check(tabs_ok, name .. ": five tab buttons on one line, left to right, not overlapping")
		local mk = els.gs_tab_mark
		check(mk and mk.y + mk.h == t1.y + t1.h and mk.h >= 1 and mk.h <= 3, name .. ": the bar is a thin line along the lower edge of the tabs")
		check(prev and prev.x + prev.w <= frame_w, name .. ": the last tab ends in the frame")
		local row, cap, list, line, ltext = els.gs_row, els.cap_gs_row, els.list_gs_row, els.gs_line, els.text_gs_line
		check(row.w + 16 <= sc_.w, name .. ": a row leaves room for the scroll bar (" .. row.w .. " + 16 <= " .. sc_.w .. ")")
		check(cap.x + cap.w <= list.x and list.x + list.w <= row.w, name .. ": caption, then combo, inside the row")
		check(cap.y >= 0 and cap.y + cap.h <= row.h and list.y >= 0 and list.y + list.h <= row.h, name .. ": and inside its height")
		check(math.floor(sc_.h / row.h) >= 4, name .. ": at least 4 rows are visible (" .. sc_.h .. " / " .. row.h .. ")")
		check(line.w == row.w and ltext.x >= 0 and ltext.x + ltext.w <= line.w and ltext.y + ltext.h <= line.h,
			name .. ": a text line is as wide as a row, its text inside")
	end
end
do
	local a, oa = elements(ROOT .. "configs/ui/ui_coop_newgame.xml")
	local b, ob = elements(ROOT .. "configs/ui/ui_coop_newgame_16.xml")
	check(table.concat(oa, ",") == table.concat(ob, ","), "4:3 and 16:9 have the same elements in the same order")
	local same_rows, wide_enough = {}, {}
	for _, n in ipairs(oa) do
		if b[n] then
			if a[n].y ~= b[n].y or a[n].h ~= b[n].h then same_rows[#same_rows + 1] = n end
			-- the glyphs keep their width on a wide screen, the 1024-unit space is 4/3 wider: a text that fits W units at 4:3
			-- fits 0.75 * W at 16:9; the stock frame is 0.8 (704 of 880)
			if b[n].w < math.floor(a[n].w * 0.75) then wide_enough[#wide_enough + 1] = n end
		end
	end
	check(#same_rows == 0, "only x and widths differ (" .. table.concat(same_rows, ",") .. ")")
	check(#wide_enough == 0, "no element of the wide layout is narrower than 0.75 of the 4:3 one (" .. table.concat(wide_enough, ",") .. ")")
end

-- The texts fit. Widths are measured with the glyph table of the fonts GAMMA plays with (tests/lua/support/font_letterica.lua:
-- Tactical Fonts for Anomaly 1k), in the units of the 4:3 layout; the wide layout is checked above to be never narrower than 0.75
-- of it, which is what the same text takes there. The stock Anomaly font is not measured (expect it wider): what would not fit a
-- font 20 % wider is only listed.
local font = dofile("tests/lua/support/font_letterica.lua")
local ARROW, STOCK = 26, 1.2 -- room the combo box keeps for its arrow; how much wider the stock font is guessed to be
local function fits(text, tbl, box) return font.width(tbl, text) <= box end
local function tight(text, tbl, box) return font.width(tbl, text) * STOCK > box end
local SHOWN_BY_T4 = {} -- the DAO captions said «(Dynamic Anomalies Overhaul)»: shortened to «(DAO)», they must fit now
local tight_list = {}
for _, lang in ipairs({ { "eng", STRINGS }, { "rus", RUS } }) do
	local tbl = lang[2]
	local g = GEOM["ui_coop_newgame.xml"]
	check(fits(tbl.st_coop_newgame_header, font.W18, g.cap_gs_header.w), lang[1] .. ": the header fits")
	local bad = {}
	for i, tab in ipairs(TABS5) do
		local label = tbl["st_coop_newgame_tab_" .. tab]
		local box = g["btn_gs_tab_" .. i].w - 12
		if not label then
			bad[#bad + 1] = tab .. " (no string)"
		elseif not fits(label, font.W16, box) then
			bad[#bad + 1] = tab .. "=" .. label
		elseif tight(label, font.W16, box) then
			tight_list[#tight_list + 1] = lang[1] .. " tab " .. label
		end
	end
	check(#bad == 0, lang[1] .. ": the tab labels fit their buttons (" .. table.concat(bad, ", ") .. ")")
	check(fits(tbl.st_coop_newgame_hint, font.W16, g.text_gs_hint.w), lang[1] .. ": the hint is one line ("
		.. font.width(font.W16, tbl.st_coop_newgame_hint) .. " of " .. g.text_gs_hint.w .. " units)")
	if tight(tbl.st_coop_newgame_hint, font.W16, g.text_gs_hint.w) then tight_list[#tight_list + 1] = lang[1] .. " hint" end
	local other = string.format(tbl.st_coop_newgame_other, "123", "456", "2026-10-23 20:50")
	local lines = font.lines(font.W16, other, g.text_gs_line.w)
	local room = math.floor(g.scroll_gs.h / 20)
	check(lines <= room, lang[1] .. ": the text of 'other' takes " .. lines .. " lines of " .. room)
	local note_lines = font.lines(font.W16, tbl.st_coop_newgame_saves_note, g.text_gs_line.w)
	check(note_lines <= 2, lang[1] .. ": the note of 'saves' takes " .. note_lines .. " lines (two at most, with the two rows above it)")
end
-- the catalog's strings (st_coop_game.xml, owner of the file: the host runtime task): checked when the file is there
do
	local function load_game_strings(lang)
		local fh = io.open(ROOT .. "configs/text/" .. lang .. "/st_coop_game.xml", "rb")
		if not fh then return nil end
		local src = fh:read("*a")
		fh:close()
		local t = {}
		for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do t[id] = text end
		return t
	end
	local sc = coop_game_schema
	local g = GEOM["ui_coop_newgame.xml"]
	for _, lang in ipairs({ "eng", "rus" }) do
		local t = load_game_strings(lang)
		if not t then
			print("  note: configs/text/" .. lang .. "/st_coop_game.xml is not here yet - captions and values are not measured")
		else
			local bad_cap, bad_val, missing, reported = {}, {}, {}, {}
			local widest_cap, widest_val = 0, 0
			for _, tab in ipairs({ "death", "party", "world", "saves" }) do
				for _, it in ipairs(sc.items(tab)) do
					if it.key ~= "faction" and it.key ~= "w|story" and it.key ~= "w|routes" then
						local cap = t[it.text]
						if not cap then
							missing[#missing + 1] = it.text
						elseif not fits(cap, font.W16, g.cap_gs_row.w) then
							if SHOWN_BY_T4[it.text] then reported[#reported + 1] = it.text .. " = " .. cap else bad_cap[#bad_cap + 1] = cap end
						else
							widest_cap = math.max(widest_cap, font.width(font.W16, cap))
							if tight(cap, font.W16, g.cap_gs_row.w) then tight_list[#tight_list + 1] = lang .. " " .. cap end
						end
						for _, e in ipairs(it.values) do
							local tx = e[2] and (t[e[2]] or STRINGS[e[2]])
							if e[2] and not tx then
								missing[#missing + 1] = e[2]
							elseif tx then
								local box = g.list_gs_row.w - ARROW
								if not fits(tx, font.W16, box) then
									bad_val[#bad_val + 1] = tx
								else
									widest_val = math.max(widest_val, font.width(font.W16, tx))
									if tight(tx, font.W16, box) then tight_list[#tight_list + 1] = lang .. " " .. tx end
								end
							end
						end
					end
				end
			end
			check(#missing == 0, lang .. ": every catalog caption and value has a string (" .. table.concat(missing, ",") .. ")")
			check(#bad_cap == 0, lang .. ": captions fit (" .. g.cap_gs_row.w .. " units): " .. table.concat(bad_cap, " | "))
			check(#bad_val == 0, lang .. ": values fit the combo (" .. (g.list_gs_row.w - ARROW) .. " units): " .. table.concat(bad_val, " | "))
			print(string.format("  info: %s: the widest caption is %d of %d units, the widest value %d of %d", lang, widest_cap,
				g.cap_gs_row.w, widest_val, g.list_gs_row.w - ARROW))
			for _, r in ipairs(reported) do
				print("  NOTE: " .. lang .. ": too long for the caption column (" .. g.cap_gs_row.w .. " units), a string of st_coop_game.xml: " .. r)
			end
		end
	end
end
if #tight_list > 0 then
	table.sort(tight_list)
	print("  note: would not fit a font " .. math.floor((STOCK - 1) * 100) .. " % wider than GAMMA's: " .. table.concat(tight_list, " | "))
end

-- ids used by the scripts and the layout exist in eng and rus
do
	local src = ""
	for _, f in ipairs({ ROOT .. "scripts/coop_newgame_modes.script", ROOT .. "scripts/coop_game_settings_view.script",
		ROOT .. "configs/ui/ui_coop_newgame.xml", ROOT .. "configs/ui/ui_coop_newgame_16.xml" }) do
		local fh = assert(io.open(f, "r"))
		src = src .. fh:read("*a")
		fh:close()
	end
	local no_eng, no_rus = {}, {}
	for id in src:gmatch('"?(st_coop_newgame_[%w_]+)') do
		if not id:find("_$") then
			if not STRINGS[id] then no_eng[#no_eng + 1] = id end
			if not RUS[id] then no_rus[#no_rus + 1] = id end
		end
	end
	for _, tab in ipairs(coop_game_schema.TABS) do -- built as "st_coop_newgame_tab_" .. tab
		local id = "st_coop_newgame_tab_" .. tab
		if not STRINGS[id] then no_eng[#no_eng + 1] = id end
		if not RUS[id] then no_rus[#no_rus + 1] = id end
	end
	for _, unit in ipairs({ "s", "m", "h" }) do
		local id = "st_coop_newgame_unit_" .. unit
		if not STRINGS[id] then no_eng[#no_eng + 1] = id end
		if not RUS[id] then no_rus[#no_rus + 1] = id end
	end
	check(#no_eng == 0, "every st_coop_newgame_* id is in the eng table (" .. table.concat(no_eng, ",") .. ")")
	check(#no_rus == 0, "and in the rus table (" .. table.concat(no_rus, ",") .. ")")
	local same = true
	for id in pairs(STRINGS) do if id:find("^st_coop_newgame_") then same = same and RUS[id] ~= nil end end
	for id in pairs(RUS) do if id:find("^st_coop_newgame_") then same = same and STRINGS[id] ~= nil end end
	check(same, "eng and rus have the same ids")
	local unused = {}
	for id in pairs(STRINGS) do
		if id:find("^st_coop_newgame_") and not src:find(id, 1, true) and not id:find("^st_coop_newgame_tab_") and not id:find("^st_coop_newgame_unit_") then
			unused[#unused + 1] = id
		end
	end
	table.sort(unused)
	check(#unused == 0, "no string of the file is left unused (" .. table.concat(unused, ",") .. ")")
	check(STRINGS.st_coop_newgame_other:find("%%s.*%%s.*%%s") ~= nil and RUS.st_coop_newgame_other:find("%%s.*%%s.*%%s") ~= nil,
		"the text of 'other' has three %s (options, addons' options, time) in both languages")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
