-- Anomaly Coop test (the main menu "Halt", coop_main_menu.script): a view over the stock widget. The items are the widget's, the
-- press goes through it, keyboard and pointer pick, a failure of any kind leaves the stock menu. Engine and UI are stand-ins;
-- coop_games, coop_menu_kit, coop_ui_kit and the themes are the real scripts. Not shipped. Run: tools\test_lua.cmd main_menu
ENGINE_CLIP = true
dofile("tests/lua/support/menu_stubs.lua")

XML_FILES["ui_coop_chronicle.xml"] = xml_paths(ROOT .. "configs/ui/ui_coop_chronicle.xml")

STRINGS = {}
do
	local fh = assert(io.open(ROOT .. "configs/text/eng/st_coop_menu.xml", "r"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
STRINGS.k00_marsh = "Swamps"
STRINGS.ui_st_game_version = "Version 1.5.3"
game = { translate_string = function(id) return STRINGS[id] or id end }

-- the disk: the saves folder of a test, newest first; textures that exist
SAVES = {}
TEXTURES = {}
FS = { FS_ListFiles = 1, FS_RootOnly = 2 }
function bit_or(a, b) return a + b end
function getFS()
	return {
		exist = function(_, root, name)
			if root == "$game_textures$" then return TEXTURES[name] end
			return nil
		end,
		file_list_open_ex = function()
			return {
				Size = function() return #SAVES end,
				Sort = function() end,
				GetAt = function(_, i)
					local s = SAVES[i + 1]
					return {
						NameFull = function() return s.name .. ".scop" end,
						Size = function() return 1000000 end,
						ModifDigitOnly = function() return s.stamp end,
					}
				end,
			}
		end,
	}
end

DIK_keys.DIK_UP, DIK_keys.DIK_DOWN, DIK_keys.DIK_NUMPADENTER = 200, 208, 156
IN_LEVEL = false
level = { present = function() return IN_LEVEL end, name = function() return "k00_marsh" end }

-- the co-op games and saves
GAMES = {}
coop_game_settings = {
	list_games = function() return GAMES end,
	game_of_save = function(stem)
		local s
		for _, e in ipairs(SAVES) do if e.name == stem then s = e end end
		if s and s.game then return s.game, { at = s.at } end
		return nil
	end,
}
coop_menu = { get_nick = function() return "stormie" end, plain = function(s) return s end, max_players = function() return 8 end }
anomaly_flavor = { get_flavor = function() return "GAMMA" end }

-- RegisterScriptCallback: the name of what the module asked for
CALLBACKS = {}
function RegisterScriptCallback(name, fn) CALLBACKS[name] = fn end

CURSOR = { x = 500, y = 400 }
function GetCursorPosition() return { x = CURSOR.x, y = CURSOR.y } end

-- a stand-in of ui_main_menu.main_menu, the class the engine's mods wrap
local stock_updates = 0
ui_main_menu = { main_menu = { Update = function(self) stock_updates = stock_updates + 1 end } }

local function shniaga(buttons)
	local s = window("shniaga")
	s.buttons = buttons
	s.page = 0
	function s:GetPage() return self.page end
	function s:GetButtonCount() return #self.buttons end
	function s:GetButtonName(i) local b = self.buttons[i + 1]; return b and b[1] or nil end
	function s:GetButtonCaption(i) local b = self.buttons[i + 1]; return b and b[2] or nil end
	function s:PressButton(name)
		self.pressed = name
		for _, b in ipairs(self.buttons) do if b[1] == name then return true end end
		return false
	end
	function s:SetSilent(on) self.silent = on end
	function s:IsSilent() return self.silent end
	return s
end

local function new_menu(buttons, stripped)
	local m = window("menu")
	m.callbacks, m.registered = {}, {}
	function m:Register(w, n) self.registered[n] = w; w.name = n end
	function m:AddCallback(n, ev, f, obj) self.callbacks[n .. "#" .. ev] = { f = f, obj = obj } end
	function m:AttachChild(c) self.attached = c end
	function m:DetachChild(c) self.detached = c end
	m.Update = function(self) return ui_main_menu.main_menu.Update(self) end
	m.shniaga = shniaga(buttons)
	m.msg_wnd = window("msg")
	if stripped then m.shniaga[stripped] = nil end
	return m
end

local COLD = { { "btn_newgame", "New game" }, { "btn_load", "Load" }, { "btn_lastsave", "Last save" }, { "btn_coop", "Co-op" }, { "btn_options", "Options" },
	{ "btn_mcm", "MCM" }, { "btn_quit", "Quit" } }
local IN_GAME = { { "btn_ret", "Return" }, { "btn_lastsave", "Last save" }, { "btn_load", "Load" }, { "btn_save", "Save" }, { "btn_coop", "Co-op" }, { "btn_options", "Options" },
	{ "btn_quit_to_mm", "To the menu" }, { "btn_quit", "Quit" } }

local base = load_module("coop_menu_theme_base")
local gamma = load_module("coop_menu_theme", "gamedata_gamma/scripts/").theme
local function use_theme(t) _G.coop_menu_theme = { theme = t } end
use_theme(gamma)
for _, t in pairs(gamma.main_menu.arts) do TEXTURES[t .. ".dds"] = true end
TEXTURES["GAMMAMainMenuLogo.dds"] = true
TEXTURES["intro\\intro_k00_marsh_1.dds"] = true

local mm = load_module("coop_main_menu")

local function names(v)
	local out = {}
	for i, it in ipairs(v.items) do out[i] = it.name end
	return table.concat(out, " ")
end
local function step(v, ms)
	NOW = NOW + (ms or 16)
	v:update()
end
local function text_of(v, i) return v.rows[i].title.text end

print("== built over the widget")
SAVES = { { name = "game_a", stamp = "29/10/2026 23:38", game = "g1", at = { level = "k00_marsh" } } }
GAMES = { { id = "g1", name = "Halt", title = "With Kent" }, { id = "g2", name = "Other", title = "Other" } }
local menu = new_menu(COLD)
check(mm.attach(menu) == true, "attaches")
local v = menu.coop_view
check(v ~= nil, "the view is held by the menu instance")
check(menu.shniaga.silent == true, "the stock widget goes silent")
check(menu.shniaga.shown ~= false, "and stays shown: hidden it stops the menu music")
check(names(v) == "btn_lastsave btn_coop btn_newgame btn_load btn_options btn_mcm btn_quit", "the order of the theme, then the widget's: " .. names(v))
check(v.rows[1].title.text == STRINGS.st_coop_mm_continue, "the caption of the theme")
check(text_of(v, 2) == "Co-op" and text_of(v, 6) == "MCM", "the rest keep the widget's caption, a mod's button is there")
check(v.items[1].sub == "With Kent, Swamps, 29 Oct, 23:38" or v.items[1].sub:find("With Kent, Swamps", 1, true) == 1, "the last save: title, place, date: " .. tostring(v.items[1].sub))
check(v.items[2].sub:find("2", 1, true) and v.items[2].sub:find("8", 1, true), "the games and the players: " .. tostring(v.items[2].sub))
check(v.items[3].sub == STRINGS.st_coop_mm_sub_new, "a line of the theme")
check(v.rows[1].primary == true and v.rows[2].primary ~= true, "the first item is the primary one")
check(menu.attached == menu.msg_wnd and menu.detached == menu.msg_wnd, "the hints of the stock menu stay on top")
check(v.root.flush == true, "the stock texts under the view are drawn before it")

print("== the first frame of the cold start")
do
	local m0 = new_menu(COLD)
	mm.attach(m0)
	local v0 = m0.coop_view
	step(v0)
	step(v0, 5000) -- that one frame
	check(v0.logo_w ~= nil, "a logo")
	check(v0.rows[1].title.talpha == 0, "the entrance has not started")
	for _ = 1, 150 do step(v0, 16) end
	check(v0.rows[1].title.talpha == 255, "and then it runs")
end

print("== the frame")
local before = stock_updates
menu:Update()
check(stock_updates == before + 1 and ui_main_menu.main_menu.Update ~= nil, "the stock Update still runs")
step(v, 3000)
check(v.rows[1].title.talpha == 255, "the entrance ends")
local y2 = v.rows[2].title.pos.y
NOW = NOW + 1
local again = v.last
v:update()
v:update() -- the menu's Update runs twice in a frame
check(v.last == again + 1, "the clock of the frame")

print("== the pointer")
v.rows[3].hit.hot = true
step(v)
check(v.on == 1, "a pointer that rests on a row when the menu opens picks nothing")
CURSOR.x = 510
step(v)
check(v.on == 3, "when it moves, it picks")
check(v.hero.tex == gamma.main_menu.arts.btn_newgame, "and the art follows")
step(v, 2000)
check(v.rows[3].sub.talpha == 255 and v.rows[1].sub.talpha == 0, "the line of the picked button only")
check(v.rows[2].title.pos.y < y2 + 1 and v.rows[4].title.pos.y > v.rows[3].title.pos.y, "the rows stay in order")
v.rows[3].hit.hot = false
step(v)
check(v.on == 3, "the pick stays when the pointer leaves")

print("== the keyboard")
local press = ui_events.WINDOW_KEY_PRESSED
check(CALLBACKS.main_menu_on_keyboard ~= nil, "the keys come by the stock callback")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_DOWN, press, menu, false)
check(v.on == 4, "down")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_UP, press, menu, false)
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_UP, press, menu, false)
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_UP, press, menu, false)
check(v.on == 1, "up")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_UP, press, menu, false)
check(v.on == #v.items, "around the end")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_DOWN, press, menu, false)
check(v.on == 1, "and back")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_DOWN, press + 1, menu, false)
check(v.on == 1, "a key that is let go does nothing")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_RETURN, press, menu, false)
check(menu.shniaga.pressed == "btn_lastsave", "Enter presses the picked button through the widget")
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_DOWN, press, menu, false)
CALLBACKS.main_menu_on_keyboard(DIK_keys.DIK_NUMPADENTER, press, menu, false)
check(menu.shniaga.pressed == "btn_coop", "the Enter of the numpad too")

print("== a click")
click(menu, "mm_row_5")
check(menu.shniaga.pressed == "btn_options", "a click presses that row's button")

print("== the widget's page")
menu.shniaga.page = 1
menu.shniaga.buttons = { { "btn_novice", "Novice" }, { "btn_new_back", "Back" } }
step(v)
check(names(v) == "btn_novice btn_new_back", "another page: the list is read again")
check(v.on == 1 and v.rows[3].hit.shown == false, "the rows left over are gone")

print("== no saves")
SAVES = {}
local m2 = new_menu({ { "btn_newgame", "New game" }, { "btn_load", "Load" }, { "btn_coop", "Co-op" }, { "btn_quit", "Quit" } })
mm.attach(m2)
check(names(m2.coop_view) == "btn_coop btn_newgame btn_load btn_quit", "no item of the last save, as in the stock menu")

print("== a save with no record of a game")
SAVES = { { name = "stalker - cordon", stamp = "28/10/2026 20:00" } }
local m3 = new_menu(COLD)
mm.attach(m3)
check(m3.coop_view.items[1].sub:find("stalker - cordon", 1, true) == 1, "its file name and date: " .. tostring(m3.coop_view.items[1].sub))
check(m3.coop_view.items[1].sub:find("28 Oct", 1, true) ~= nil, "the date stays when the place is not known: " .. tostring(m3.coop_view.items[1].sub))

print("== in a game")
IN_LEVEL = true
SAVES = { { name = "game_a", stamp = "29/10/2026 23:38", game = "g1", at = { level = "k00_marsh" } } }
local m4 = new_menu(IN_GAME)
mm.attach(m4)
local w4 = m4.coop_view
check(names(w4) == "btn_ret btn_lastsave btn_coop btn_load btn_save btn_options btn_quit_to_mm btn_quit", "the list of a game: " .. names(w4))
check(w4.rows[2].title.text == "Last save", "the widget's caption: Continue is for the cold start")
check(w4.hero.tex == "intro\\intro_k00_marsh_1", "the art of this level")
w4:select(4, NOW)
check(w4.hero.tex == "intro\\intro_k00_marsh_1", "on every item")
IN_LEVEL = false

print("== the theme says no")
local off = {}
for k, val in pairs(gamma) do off[k] = val end
off.main_menu = { enabled = false }
use_theme(off)
local m5 = new_menu(COLD)
check(mm.attach(m5) == false and m5.coop_view == nil and m5.shniaga.silent == nil, "the stock menu stays")
use_theme(gamma)

print("== an old exe")
for _, method in ipairs({ "GetButtonCount", "GetButtonName", "GetButtonCaption", "PressButton", "SetSilent" }) do
	local m6 = new_menu(COLD, method)
	check(mm.attach(m6) == false and m6.coop_view == nil and m6.shniaga.silent ~= true, "without " .. method .. " the stock menu stays")
end

print("== a failure while building")
local m7 = new_menu(COLD)
local real_new = coop_ui_kit.new
coop_ui_kit.new = function() error("broken") end
check(mm.attach(m7) == false and m7.coop_view == nil and m7.shniaga.silent == false, "the widget speaks again")
coop_ui_kit.new = real_new
check(log_has("%[coop%-main%-menu%] !"), "and the log says why")

print("== a failure in a frame")
local m8 = new_menu(COLD)
mm.attach(m8)
local v8 = m8.coop_view
v8.hero.draw = function() error("broken") end
step(v8)
check(m8.coop_view == nil and m8.shniaga.silent == false and v8.root.shown == false, "the view is gone, the stock menu is there")
check(m8.shniaga:PressButton("btn_quit") == true, "and it works")

print("== the keys of a menu with no view")
check(pcall(CALLBACKS.main_menu_on_keyboard, DIK_keys.DIK_DOWN, press, m8, false), "are left alone")

print("== the size of a picture")
do
	local m = new_menu(COLD)
	mm.attach(m)
	local vw = m.coop_view
	local layer = vw.hero.layers[3 - vw.hero.on]
	-- the engine answers with the static's rectangle when it has one
	function layer.w:GetTextureSize()
		local r = self.trect
		if r and r.x2 - r.x1 > 0 then return { x = r.x2 - r.x1, y = r.y2 - r.y1 } end
		return { x = 2048, y = 1024 }
	end
	vw:select(2, NOW)
	check(layer.tw == 2048 and layer.th == 1024, "not the rectangle of the last picture")
end

print("== the art the window leaves")
local m9 = new_menu(COLD)
mm.attach(m9)
local v9 = m9.coop_view
v9:take_art("intro\\intro_l01_escape_3")
check(v9.hero.tex == v9.items[v9.on].art, "the menu takes it and goes back to its own")
check(v9.hero.layers[3 - v9.hero.on].tex == "intro\\intro_l01_escape_3", "by a cross-fade from that picture")

print("== the screen of another shape")
SCREEN.w, SCREEN.h = 1024, 768
local m10 = new_menu(COLD)
mm.attach(m10)
check(m10.coop_view.ui.L.s < .6, "a menu of its own for that screen")
local list = m10.coop_view.list
check(list.pos.x > 0 and list.pos.y > 0, "the list on the screen")
SCREEN.w, SCREEN.h = 1920, 1080

print("== many buttons")
local many = {}
for i = 1, 11 do many[i] = { "btn_" .. i, "B" .. i } end
local m11 = new_menu(many)
mm.attach(m11)
local v11 = m11.coop_view
step(v11, 3000)
local last = v11.rows[11].hit
local bottom = (last.pos.y + last.h) / v11.ui.L.ky / v11.ui.L.s
check(#v11.items == 11, "all of them")
local M = gamma.main_menu
check(v11.step < 66, "the rows close up: " .. tostring(v11.step))

print("== no motion")
local still = {}
for k, val in pairs(gamma) do still[k] = val end
still.motion = false
use_theme(still)
local m12 = new_menu(COLD)
mm.attach(m12)
local v12 = m12.coop_view
step(v12, 1)
check(v12.rows[1].title.talpha == 255, "everything stands at once")
use_theme(gamma)

print("== the embers")
local m13 = new_menu(COLD)
mm.attach(m13)
local v13 = m13.coop_view
check(#v13.embers == base.DEFAULTS.main_menu.embers.count, "a pool of the theme's size")
step(v13, 5000)
local y0 = v13.embers[1].w.pos.y
step(v13, 500)
check(v13.embers[1].w.pos.y < y0, "they rise")

print(string.format("%d passed, %d failed", PASSES, FAILS))
