-- GAMMA's zzz_craft_use_in_tooltip_mcm (reports b40-b43, 7 issues, 4 installs) replaces utils_ui.UIInfoItem.Update at
-- its load (:182) with a function that reads craft.ltx / cook.ltx through the file locals ini_craft / ini_cook (:2-3),
-- filled only in its on_game_start (:476-477). A tooltip shown before that (the main-menu new-game windows: stock
-- ui_mm_faction_select's loadout, our character window) fails on every hover:
--   zzz_craft_use_in_tooltip_mcm.script:288: attempt to index upvalue 'ini_craft' (a nil value)
-- (its own try() prints it). coop_mods_guard fills the two locals with the very ini files on_game_start opens, before the
-- mod's Update reads them, whichever of the two wraps UIInfoItem.Update last.
MODE = "client"
dofile("tests/lua/support/stubs_mods.lua")
dofile("tests/lua/support/mod_source.lua")
print("== craft tooltip guard")
local BS = string.char(92)

local path = GAMMA_DIR .. "/zzz_craft_use_in_tooltip_mcm.script"
local fh = assert(io.open(path, "rb"), "real GAMMA zzz_craft_use_in_tooltip_mcm.script required (GAMMA_SCRIPTS)")
local text = fh:read("*a")
fh:close()

local LOG = {}
local saved_printf = printf
printf = function(fmt, ...)
	local ok, line = pcall(string.format, tostring(fmt), ...)
	LOG[#LOG + 1] = ok and line or tostring(fmt)
end
local function logged(pat)
	for _, l in ipairs(LOG) do if l:find(pat, 1, true) then return true end end
	return false
end

local OPENED = {}
-- craft.ltx: one recipe of prt_i_x; cook.ltx: no meal of it
local function fake_ini(name)
	OPENED[#OPENED + 1] = name
	local craft = name:find("craft", 1, true) ~= nil
	return {
		section_for_each = function(_, f) if craft then f("recipes_1") end end,
		line_count = function(_, s) return (craft and s == "recipes_1") and 1 or 0 end,
		r_line_ex = function() return true, "x_prt_glue", "prt_i_x,1" end,
	}
end

local function fresh(order)
	LOG, OPENED = {}, {}
	ini_file = fake_ini
	str_explode = function(s, sep)
		local t = {}
		for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do t[#t + 1] = part end
		return t
	end
	is_not_empty = function(t) return next(t) ~= nil end
	utils_xml = { sync_cursor = function() end }
	local stock = { n = 0 }
	utils_ui = { UIInfoItem = {
		__init = function() end,
		Update = function() stock.n = stock.n + 1 end,
	} }
	workshop_autoinject, ui_mcm = nil, nil
	zzz_craft_use_in_tooltip_mcm, coop_mods_guard = nil, nil
	local function load_mod()
		local env = setmetatable({}, { __index = _G })
		zzz_craft_use_in_tooltip_mcm = env
		local chunk = assert(loadstring(text, "@" .. path))
		setfenv(chunk, env)
		chunk()
		return env
	end
	local mod
	if order == "mod first" then
		mod = load_mod()
		load_script("coop_mods_guard")
	else
		load_script("coop_mods_guard")
		mod = load_mod()
	end
	return mod, stock
end

local function info()
	local i = { cont_to_str = {}, recipes_shown = {} }
	function i:Pass() return true end
	function i:Show() end
	function i:RemoveRecipesContainer() end
	function i:AddRecipesContainer(_, t) self.recipes_shown = t end
	function i:Sync_Finale() end
	function i:SyncRecipesText() end
	i.frame = { GetHeight = function() return 100 end }
	i.stats_dialog = { IsShown = function() return false end }
	i.recipes = { IsShown = function() return true end }
	return i
end

SYS_GetParam = function() return "" end

for _, order in ipairs({ "mod first", "guard first" }) do
	local mod, stock = fresh(order)
	-- the main menu: the mod's on_game_start has not run
	local i = info()
	utils_ui.UIInfoItem.Update(i, nil, "prt_i_x")
	check(not logged("ini_craft") and not logged("ini_cook"), order .. ": no nil ini_craft / ini_cook before the world")
	check(stock.n == 1, order .. ": the stock tooltip still runs once")
	check(i.recipes_shown[1] == "prt_glue", order .. ": the recipe of the item is shown (" .. tostring(i.recipes_shown[1]) .. ")")
	local both = table.concat(OPENED, "|")
	check(both:find("items" .. BS .. "settings" .. BS .. "craft.ltx", 1, true) and both:find("items" .. BS .. "settings" .. BS .. "cook.ltx", 1, true),
		order .. ": the files the mod's on_game_start opens (" .. both .. ")")
	-- the world: the mod's on_game_start opens its own; nothing is opened again
	ui_item = { build_desc_footer = function() end }
	ui_itm_details = { UIItemSheet = { Reset = function() end } }
	mod.on_game_start()
	local n = #OPENED
	utils_ui.UIInfoItem.Update(info(), nil, "prt_i_x")
	check(#OPENED == n and not logged("ini_craft"), order .. ": in a loaded game the mod's own files are used")
end

-- without the mod: nothing is wrapped
LOG, OPENED = {}, {}
local stock_update = function() end
utils_ui = { UIInfoItem = { Update = stock_update } }
zzz_craft_use_in_tooltip_mcm, coop_mods_guard = nil, nil
load_script("coop_mods_guard")
utils_ui.UIInfoItem.Update({}, nil, "x")
check(#OPENED == 0 and #LOG == 0, "without the GAMMA mod nothing is opened or logged")

printf = saved_printf
done("CRAFT TOOLTIP GUARD")
