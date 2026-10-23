-- Anomaly Coop test: the new game screen of a co-op host (gamedata\scripts\coop_newgame_modes.script, its main menu seam
-- modxml_coop_newgame.script, the layout configs\ui\ui_coop_newgame.xml and its _16 twin, the strings
-- configs\text\*\st_coop_newgame.xml). The stock screen (ui_mm_faction_select.UINewGame), the main menu and the engine
-- are stand-ins shaped like the real ones; the field names are checked against the real stock script below.
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
CONSOLE = { coop_death_mode = "checkpoint", coop_death_drop = "drop", coop_autosave_interval = "10" }
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
	STARTS[#STARTS + 1] = { exec = #EXEC, keys = {} }
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
	EXEC = {}
end
local function click_start(dlg)
	local cb = dlg.callbacks["btn_start#" .. ui_events.BUTTON_CLICKED]
	assert(cb, "btn_start has no callback")
	return cb.f(cb.obj)
end
local function pick(dlg, field, index)
	dlg[field].cur = index
	local cb = dlg.callbacks[field .. "#" .. ui_events.LIST_ITEM_SELECT]
	assert(cb, field .. " has no select callback")
	cb.f(cb.obj)
end
local function texts(list)
	local t = {}
	for _, it in ipairs(list.items) do t[#t + 1] = it.text end
	return table.concat(t, "|")
end
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

print("== co-op host: the rules block")
GAMMA = true
reset_console(); clear_cfg(); coop_info()
local mn = new_menu()
mn:ShowFactionUI()
local d = mn.new_game_dlg
check(d.coop_header and d.coop_header.shown ~= false, "the block has its header")
check(d.coop_header.parent == nil or d.coop_header.parent == d.templ_options, "inside the options frame")
for _, f in ipairs({ "list_coop_death_mode", "list_coop_death_drop", "list_coop_autosave" }) do
	check(d[f] and d[f].shown and d[f].enabled and d[f .. "_cap"] and d[f .. "_cap"].shown, f .. " and its caption are shown")
	check(d.registered[f] == d[f], f .. " is registered under its name")
end
check(d.list_coop_death_mode_cap.path == "main_dialog:options:cap_list_coop_death_mode", "the captions come from the layout")
check(texts(d.list_coop_death_mode) == "Camps|Hardcore", "death: " .. texts(d.list_coop_death_mode))
check(texts(d.list_coop_death_drop) == "Bag at the body|All in a stash|Lost", "loss: " .. texts(d.list_coop_death_drop))
check(texts(d.list_coop_autosave) == "5 min|10 min|20 min|off", "autosave: " .. texts(d.list_coop_autosave))
check(d.list_coop_death_mode.text == "Camps" and d.list_coop_death_drop.text == "Bag at the body"
	and d.list_coop_autosave.text == "10 min", "the lists show the console's values")
check(d.coop_hint and d.coop_hint.text == STRINGS.st_coop_newgame_hint and d.coop_hint.shown ~= false, "the hint is under the block")
check(STRINGS.st_coop_newgame_hint:find("Options > Co%-op") ~= nil, "and points to Options > Co-op")
check(#EXEC == 0, "opening the screen writes nothing to the console")

print("== co-op host: the values for the console")
-- the user (or a mod) switched the hidden modes on; he picks hardcore, lose and autosave off
d.ck_hardcore:SetCheck(true); d.ck_soulslike_mode:SetCheck(true); d.ck_azazel_mode:SetCheck(true)
d.ck_campfire:SetCheck(true); d.ck_conditions:SetCheck(true); d.ck_survival:SetCheck(true); d.ck_warfare:SetCheck(true)
d.selected_timer = d.table_timer[2]; d.selected_hardcore_regen = d.table_hardcore_regen[2]
axr_main.config:w_value("character_creation", "new_game_campfire_mode", true)
pick(d, "list_coop_death_mode", 2)
pick(d, "list_coop_death_drop", 3)
pick(d, "list_coop_autosave", 4)
check(#EXEC == 0, "picking in the lists writes nothing yet")
click_start(d)
local s = STARTS[#STARTS]
check(s ~= nil, "the world start was asked")
check(EXEC[1] == "coop_death_mode hardcore" and EXEC[2] == "coop_death_drop lose"
	and EXEC[3] == "coop_autosave_interval 0" and EXEC[4] == "cfg_save" and #EXEC == 4,
	"the three variables, then cfg_save (" .. table.concat(EXEC, "; ") .. ")")
check(s and s.exec == 4, "all of it before the start of the world")
check(CONSOLE.coop_death_mode == "hardcore" and CONSOLE.coop_death_drop == "lose" and CONSOLE.coop_autosave_interval == "0",
	"the console holds the new rules")
local left = {}
for _, k in ipairs(CFG_KEYS) do if cfg(k) ~= nil then left[#left + 1] = k end end
check(#left == 0, "none of the 9 hidden modes reaches the config, whatever was ticked or stale (" .. table.concat(left, ",") .. ")")
check(cfg("new_game_story_mode") == "true" and cfg("new_game_opened_routes") == "true" and cfg("new_game_difficulty") == "1",
	"story, open Zone and difficulty are written as the stock does")
check(s and s.keys.new_game_hardcore_mode == nil and s.keys.new_game_timer_mode == nil and s.keys.new_game_soulslike_mode == nil,
	"already clean when the world starts")

print("== co-op host: untouched lists write nothing")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
click_start(d)
check(#EXEC == 0, "the rules stay as they were: no console writes, no cfg_save (" .. table.concat(EXEC, "; ") .. ")")
check(cfg("new_game_character_name") == "Stalker", "the stock start still ran")

print("== co-op host: the console's values, odd ones too")
reset_console(); clear_cfg(); coop_info()
CONSOLE.coop_death_mode, CONSOLE.coop_death_drop, CONSOLE.coop_autosave_interval = "hardcore", "corpse", "15"
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(d.list_coop_death_mode.text == "Hardcore" and d.list_coop_death_drop.text == "All in a stash",
	"hardcore and corpse are shown")
check(texts(d.list_coop_autosave) == "5 min|10 min|15 min|20 min|off" and d.list_coop_autosave.text == "15 min",
	"an interval from the options page (15) is kept as an entry: " .. texts(d.list_coop_autosave))
click_start(d)
check(#EXEC == 0, "and written back unchanged: nothing")
reset_console(); clear_cfg()
CONSOLE.coop_death_mode, CONSOLE.coop_autosave_interval = "respawn_keep", "0"
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(d.list_coop_death_mode.text == "Camps" and d.list_coop_autosave.text == "off", "an old synonym is camps, 0 is off")
reset_console(); clear_cfg()
CONSOLE.coop_death_mode, CONSOLE.coop_death_drop, CONSOLE.coop_autosave_interval = nil, nil, nil
get_console_cmd = function() return nil end
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
check(d.list_coop_death_mode.text == "Camps" and d.list_coop_death_drop.text == "Bag at the body"
	and d.list_coop_autosave.text == "10 min", "no console variable: the engine defaults")
click_start(d)
check(#EXEC == 0, "and nothing to write")
function get_console_cmd(typ, name) return CONSOLE[name] end

print("== co-op host: a start that does not start")
reset_console(); clear_cfg(); coop_info()
mn = new_menu(); mn:ShowFactionUI(); d = mn.new_game_dlg
pick(d, "list_coop_death_mode", 2)
d.character_name:SetText("")
local starts_before = #STARTS
click_start(d)
check(#STARTS == starts_before and #EXEC == 0, "no name: the stock refuses, the rules are not written either")
d.character_name:SetText("Strelok"); d.access = false
click_start(d)
check(#STARTS == starts_before and #EXEC == 0, "a pop-up is open: same")
d.access = true
click_start(d)
check(#STARTS == starts_before + 1 and EXEC[1] == "coop_death_mode hardcore", "then the start goes through")

print("== co-op host: the screen follows the kind of game")
reset_console(); clear_cfg(); GAMMA = true
mn = new_menu()
single_info(); mn:ShowFactionUI(); local a = mn.new_game_dlg
coop_info(); mn:ShowFactionUI(); local b = mn.new_game_dlg
check(b ~= a and b.coop_modes_applied == true, "single player -> co-op: a new dialog, set up")
mn:ShowFactionUI(); local c2 = mn.new_game_dlg
check(c2 ~= b and c2.coop_modes_applied == true and c2.list_coop_death_mode ~= nil,
	"co-op again: built again (the console may have changed meanwhile)")
single_info(); mn:ShowFactionUI(); local e = mn.new_game_dlg
check(e ~= c2 and e.coop_modes_applied == nil and is_visible(e, "ck_hardcore") and e.list_coop_death_mode == nil,
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
check(cfg("new_game_hardcore_mode") == nil and #EXEC == 0, "the start still forces them off, no rules written")
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
local function elements(file)
	local fh = assert(io.open(file, "r"))
	local src = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
	fh:close()
	local out = {}
	local body = src:match("<options>(.-)</options>")
	assert(body, file .. ": no <options>")
	for name, x, y, w, h in body:gmatch('<([%w_]+)%s+x="(%-?%d+)"%s+y="(%-?%d+)"%s+width="(%d+)"%s+height="(%d+)"') do
		out[name] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
	end
	return out
end
local NAMES = { "cap_coop_header", "cap_list_coop_death_mode", "list_coop_death_mode", "cap_list_coop_death_drop",
	"list_coop_death_drop", "cap_list_coop_autosave", "list_coop_autosave", "text_coop_hint" }
for _, lay in ipairs({ { "ui_coop_newgame.xml", 880, 331 }, { "ui_coop_newgame_16.xml", 704, 264 } }) do
	local els = elements(ROOT .. "configs/ui/" .. lay[1])
	local miss, bad = {}, {}
	for _, n in ipairs(NAMES) do
		local e = els[n]
		if not e then miss[#miss + 1] = n
		elseif e.x < lay[3] or e.x + e.w > lay[2] or e.y < 0 or e.y + e.h > 160 then
			bad[#bad + 1] = n .. string.format(" (%d,%d %dx%d)", e.x, e.y, e.w, e.h)
		end
	end
	check(#miss == 0, lay[1] .. ": every element is there (" .. table.concat(miss, ",") .. ")")
	check(#bad == 0, lay[1] .. ": inside the options frame (" .. lay[2] .. " x 160) and right of the first column (x from "
		.. lay[3] .. "): " .. table.concat(bad, ", "))
	local rows = {}
	for _, n in ipairs({ "list_coop_death_mode", "list_coop_death_drop", "list_coop_autosave" }) do
		local e, cap = els[n], els["cap_" .. n]
		if e and cap then
			check(cap.x + cap.w <= e.x, lay[1] .. ": " .. n .. " caption ends before the list")
			rows[#rows + 1] = e
		end
	end
	if #rows == 3 then
		check(rows[1].y + rows[1].h <= rows[2].y and rows[2].y + rows[2].h <= rows[3].y, lay[1] .. ": the rows do not overlap")
		check(els.text_coop_hint and els.text_coop_hint.y >= rows[3].y + rows[3].h, lay[1] .. ": the hint is under the block")
	end
end
-- ids used by the script exist in eng and rus
do
	local fh = assert(io.open(ROOT .. "scripts/coop_newgame_modes.script", "r"))
	local src = fh:read("*a")
	fh:close()
	local fx = assert(io.open(ROOT .. "configs/ui/ui_coop_newgame.xml", "r"))
	src = src .. fx:read("*a")
	fx:close()
	local no_eng, no_rus = {}, {}
	for id in src:gmatch('"?(st_coop_newgame_[%w_]+)') do
		if not STRINGS[id] then no_eng[#no_eng + 1] = id end
		if not RUS[id] then no_rus[#no_rus + 1] = id end
	end
	check(#no_eng == 0, "every st_coop_newgame_* id is in the eng table (" .. table.concat(no_eng, ",") .. ")")
	check(#no_rus == 0, "and in the rus table (" .. table.concat(no_rus, ",") .. ")")
	local same = true
	for id in pairs(STRINGS) do same = same and RUS[id] ~= nil end
	for id in pairs(RUS) do same = same and STRINGS[id] ~= nil end
	check(same, "eng and rus have the same ids")
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
