-- Anomaly Coop test (co-op window, the look of a pack): the theme of plain Anomaly (gamedata), the override of G.A.M.M.A.
-- (gamedata_gamma, the same path in a layer above Core), the fallback of every field, and that no colour, font name or
-- duration stays in the window's code. Not shipped. Run: tools\test_lua.cmd menu_theme
dofile("tests/lua/support/menu_stubs.lua")

local base = load_module("coop_menu_theme_base")
local D = base.DEFAULTS

print("== the two themes")
local anomaly_theme = load_module("coop_menu_theme").theme
local gamma_theme = load_module("coop_menu_theme", "gamedata_gamma/scripts/").theme
check(type(anomaly_theme) == "table" and type(gamma_theme) == "table", "both files hold a plain table")
local function resolved(theme_table)
	_G.coop_menu_theme = theme_table and { theme = theme_table } or {}
	return base.load()
end
local A, G = resolved(anomaly_theme), resolved(gamma_theme)
check(A.colors.accent[1] ~= G.colors.accent[1] or A.colors.accent[2] ~= G.colors.accent[2], "the packs differ in their accent")
check(G.colors.accent[1] == 217 and G.colors.accent[2] == 171 and G.colors.accent[3] == 91, "G.A.M.M.A. has the sand of the prototype")
check(G.layout.tile.x == 1516 and G.layout.tile.w == 340 and G.map.focus.x == 880, "the prototype's numbers")
check(G.anim.map_open == 450 and G.anim.map_close == 350 and A.anim.map_open == 450 and A.anim.map_close == 350, "the map opens in 0.45 s, closes in 0.35 s, in both themes")
for _, t in ipairs({ A, G }) do
	local n = t.anim
	check(n.shade_delay + n.shade_open <= 500 and n.timeline_delay + n.timeline_slide <= 500 and n.line_delay + n.line_grow <= 500
		and n.hero_out <= 500 and n.hero_zoom <= 500 and n.tile_fade <= 500, "the opening is one move: all done in about half a second")
	check(n.route <= 500 and n.route_delay <= 150 and n.tl_step >= 25 and n.tl_step <= 30, "the route reveal and the rows of the chronicle are quick")
end
check(G.anim.swing[1] == .62 and G.anim.swing[2] == .02 and G.anim.swing[3] == .18 and G.anim.swing[4] == 1, "cubic-bezier(.62,.02,.18,1)")

print("== an override is picked up")
local T = resolved({ colors = { accent = { 1, 2, 3 } }, motion = false, layout = { tile = { x = 1400 } }, anim = { map_open = 500 } })
check(T.colors.accent[3] == 3, "a colour")
check(T.motion == false, "the motion switch")
check(T.layout.tile.x == 1400 and T.layout.tile.w == D.layout.tile.w, "one number of a block: the others stay")
check(T.anim.map_open == 500 and T.anim.tl_step == D.anim.tl_step, "a duration")
check(T.colors.text[1] == D.colors.text[1], "what the theme does not name stays")

print("== a missing or broken field falls back")
T = resolved({})
check(T.colors.accent[1] == D.colors.accent[1], "an empty theme is the default theme")
T = resolved(nil)
check(T.layout.rail.x == D.layout.rail.x, "no theme at all")
_G.coop_menu_theme = { theme = "not a table" }
T = base.load()
check(T.colors.accent[1] == D.colors.accent[1], "a theme that is no table")
T = resolved({ colors = { accent = "red", text = { 1, 2 }, dim = { 1, 2, "x" }, line = { 300, 0, 0 }, faint = { 0, 0, 0, 7 } } })
check(T.colors.accent[1] == D.colors.accent[1], "a colour of the wrong type")
check(T.colors.text[3] == D.colors.text[3], "a colour with two numbers")
check(T.colors.dim[3] == D.colors.dim[3], "a colour with a word in it")
check(T.colors.line[1] == D.colors.line[1], "a channel above 255")
check(T.colors.faint[4] == D.colors.faint[4], "an alpha above 1")
T = resolved({ layout = "x", anim = { map_open = "slow", swing = { 1, 2 } }, motion = "yes", fonts = { roles = { title = { name = 5 } } } })
check(T.layout.tile.x == D.layout.tile.x, "a block of the wrong type")
check(T.anim.map_open == D.anim.map_open, "a word for a number")
check(T.anim.swing[3] == D.anim.swing[3], "a curve that is no curve")
check(T.motion == D.motion, "a word for a switch")
check(T.fonts.roles.title.name == D.fonts.roles.title.name, "a font without a name")
T = resolved({ anim = { map_open = -5 } })
check(T.anim.map_open == D.anim.map_open, "a negative duration")
T = resolved({ art = { levels = { my_level = "ui\\art" } }, text = { mark = { color = "no_such_role" } } })
check(T.art.levels.my_level == "ui\\art", "a table of the theme's own keys comes through")
check(T.text.mark.color == D.text.mark.color, "a colour role that does not exist")
check(T.text.mark.font == D.text.mark.font, "the font of that style stays")
T = resolved({ text = { mark = { font = "no_such_role" } } })
check(T.text.mark.font == D.text.mark.font, "a font role that does not exist")
local before = D.colors.accent[1]
T = resolved({})
T.colors.accent[1] = 1
check(D.colors.accent[1] == before, "the window cannot change the defaults")

print("== a theme file that is broken")
_G.coop_menu_theme = nil
do
	local mt = getmetatable(_G)
	local keep = mt.__index
	mt.__index = function(t, k)
		if k == "coop_menu_theme" then error("syntax error in the theme") end
		return keep(t, k)
	end
	T = base.load()
	check(T.colors.accent[1] == D.colors.accent[1], "a script that does not load: the defaults")
	mt.__index = keep
end

print("== nothing of the look in the code")
local function source(name)
	local fh = assert(io.open(ROOT .. "scripts/" .. name .. ".script", "r"))
	local s = fh:read("*a")
	fh:close()
	return (s:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end
for _, name in ipairs({ "coop_menu", "coop_games", "coop_menu_kit", "coop_ui_kit" }) do
	local src = source(name)
	check(not src:find("GetARGB%(%s*%d"), name .. ": no GetARGB with numbers")
	check(not src:find("%f[%w]0x[%x][%x][%x][%x][%x][%x]"), name .. ": no 0xRRGGBB")
	check(not src:find("{%s*%d+%s*,%s*%d+%s*,%s*%d+%s*[,}]"), name .. ": no { r, g, b } tables")
	check(not src:find('"menu_title"', 1, true) and not src:find('"menu_body"', 1, true) and not src:find("raylink_", 1, true), name .. ": no font names")
	check(not src:find("GetFontRaylink", 1, true), name .. ": the fonts of the contract, not the old names")
	check(not src:find("intro\\", 1, true) and not src:find("intro_", 1, true), name .. ": no art rule")
end
local src = source("coop_ui_kit")
check(select(2, src:gsub("GetARGB", "")) == 1 and not source("coop_menu"):find("GetARGB", 1, true), "one place makes a colour")
local xml = assert(io.open(ROOT .. "configs/ui/ui_coop_chronicle.xml", "r"))
local xsrc = xml:read("*a"):gsub("<!%-%-.-%-%->", "")
xml:close()
check(not xsrc:find('%sr="') and not xsrc:find('%sa="'), "the layout templates carry no colours")
check(not xsrc:find('"menu_', 1, true) and not xsrc:find("raylink", 1, true), "and name stock fonts only: the exe may not have others")

print(string.format("%d passed, %d failed", PASSES, FAILS))
