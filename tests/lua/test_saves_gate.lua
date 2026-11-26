-- Anomaly Coop: saving and loading by hand in a session are refused in one place, coop_saves. A player who presses F5 / F7
-- or clicks Save / Load of an old in-game menu gets one hint, the translated one of coop_saves; in the rollback death mode
-- his F5 asks the host for the save (the save_req event) and says so, nothing contradicts it.
-- Real scripts: coop_route, coop_main, coop_saves and the facade coop_mode with its live layers; real eng strings
-- st_coop_saves.xml. Each mode on its own: a player of Coop (the hostplay layer answers) and a player of Server (the srv
-- layer answers: the session is split into maps). Not shipped. Run: tools\test_lua.cmd saves_gate
MODE = "client"
dofile("tests/lua/support/stubs.lua")

-- the real eng strings of coop_saves
STRINGS = {}
do
	local fh = assert(io.open(ROOT .. "configs/text/eng/st_coop_saves.xml", "rb"))
	local src = fh:read("*a")
	fh:close()
	for id, text in src:gmatch('<string id="([^"]+)">%s*<text>(.-)</text>') do STRINGS[id] = text end
end
game.translate_string = function(id) return STRINGS[id] or id end

-- coop_saves declares its restore window at load (luabind's class)
CUIScriptWnd = {}
function class(name)
	local env = getfenv(2)
	return function(base)
		local c = setmetatable({}, { __index = base })
		c.__index = c
		env[name] = c
	end
end

-- every hint over the game, in order
HUD = {}
actor_menu = { set_msg = function(_, text) HUD[#HUD + 1] = text end }

-- the stock in-game menu: what ran, and the menu's own message line
MM, MENU_MSG = {}, {}
ui_main_menu = { main_menu = {} }
ui_main_menu.main_menu.SetMsg = function(self, text) MENU_MSG[#MENU_MSG + 1] = text end
ui_main_menu.main_menu.OnButton_save_clicked = function(self) MM[#MM + 1] = "save" end
ui_main_menu.main_menu.OnButton_load_clicked = function(self) MM[#MM + 1] = "load" end
ui_main_menu.main_menu.OnButton_last_save = function(self) MM[#MM + 1] = "last" end
local STOCK_MENU = {}
for k, v in pairs(ui_main_menu.main_menu) do STOCK_MENU[k] = v end

-- the client's events to the host (coop_mods_core.to_host)
ASKED = {}
coop_mods_core = { to_host = function(verb, t) ASKED[#ASKED + 1] = verb return true end }

SAVES_OPEN = false
coop.saves_open = function() return SAVES_OPEN end
coop.life_of = function() return "alive" end

-------------------------------------------------------------------------------
print("== the save gate is coop_saves alone")
local modes = dofile("tests/lua/support/modes.lua")
modes.live(load_script_file("coop_mode"))
load_coop_main()
coop_main.on_game_start()
check(axr_main.count("on_before_save_input") == 0 and axr_main.count("on_before_load_input") == 0,
	"coop_main registers no save or load handler")
local untouched = true
for k, v in pairs(STOCK_MENU) do if ui_main_menu.main_menu[k] ~= v then untouched = false end end
check(untouched, "coop_main leaves the in-game menu's Save / Load / Last save as they are")
local saves = load_script_file("coop_saves")
saves.on_game_start()
check(axr_main.count("on_before_save_input") == 1 and axr_main.count("on_before_load_input") == 1,
	"coop_saves registers the one save handler and the one load handler")

local function one_hint(want, what)
	check(#HUD == 1 and HUD[1] == want and want ~= nil and not tostring(want):find("^st_coop_"),
		what .. " (" .. #HUD .. " hint(s): " .. table.concat(HUD, " | ") .. ")")
end

-- coop: the hostplay layer answers (no split); server: the srv layer answers (the session is split into maps)
local MODES = {
	{ name = "Coop", levels = nil, travels = true },
	{ name = "Server", levels = { split = function() return true end }, travels = false },
}

for _, m in ipairs(MODES) do
	coop.levels = m.levels
	print("== " .. m.name .. ": a player's save and load input")
	check(coop_mode.group_travels() == m.travels and not coop_mode.decides_world(),
		m.name .. ": the " .. (m.travels and "hostplay" or "srv") .. " layer answers, this process does not decide the world")
	SAVES_OPEN = false
	for _, typ in ipairs({ 1, 2, 3 }) do
		HUD, ASKED = {}, {}
		local flags = { ret = false }
		SendScriptCallback("on_before_save_input", flags, typ, "Save")
		check(flags.ret == true and #ASKED == 0, m.name .. ": save type " .. typ .. " is refused, nothing is asked")
		one_hint(STRINGS.st_coop_saves_auto_client, m.name .. ": save type " .. typ .. " shows one translated hint")
	end
	HUD = {}
	local flags = { ret = false }
	SendScriptCallback("on_before_load_input", 65, 33, flags)
	check(flags.ret == true, m.name .. ": F7 is refused")
	one_hint(STRINGS.st_coop_saves_load_client, m.name .. ": F7 shows one translated hint")

	print("== " .. m.name .. ": rollback death mode")
	SAVES_OPEN = true
	HUD, ASKED = {}, {}
	flags = { ret = false }
	SendScriptCallback("on_before_save_input", flags, 2, "Save")
	check(flags.ret == true and #ASKED == 1 and ASKED[1] == "save_req", m.name .. ": F5 sends save_req to the host")
	one_hint(STRINGS.st_coop_saves_asked, m.name .. ": F5 says the host was asked, and nothing else")
	HUD, ASKED = {}, {}
	flags = { ret = false }
	SendScriptCallback("on_before_save_input", flags, 1, "Save")
	check(flags.ret == true and #ASKED == 0, m.name .. ": the Save window asks nothing")
	one_hint(STRINGS.st_coop_saves_host_only, m.name .. ": the Save window shows one translated hint")
	HUD = {}
	flags = { ret = false }
	SendScriptCallback("on_before_load_input", 65, 33, flags)
	check(flags.ret == true, m.name .. ": F7 is refused")
	one_hint(STRINGS.st_coop_saves_host_only, m.name .. ": F7 shows one translated hint")
	SAVES_OPEN = false

	print("== " .. m.name .. ": an old in-game menu")
	MM, MENU_MSG, HUD = {}, {}, {}
	ui_main_menu.main_menu:OnButton_save_clicked()
	ui_main_menu.main_menu:OnButton_load_clicked()
	ui_main_menu.main_menu:OnButton_last_save()
	check(#MM == 0, m.name .. ": Save, Load and Last save do nothing")
	check(#MENU_MSG == 3 and #HUD == 0 and MENU_MSG[1] == STRINGS.st_coop_saves_auto_client
		and MENU_MSG[2] == STRINGS.st_coop_saves_load_client and MENU_MSG[3] == MENU_MSG[2],
		m.name .. ": one translated hint per click, on the menu's own line (" .. table.concat(MENU_MSG, " | ") .. ")")
end
coop.levels = nil

print(string.format("%d passed, %d failed", PASSES, FAILS))
