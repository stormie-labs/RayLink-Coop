-- Anomaly Coop (F0, review R5 I1): the check boxes of the "Co-op" options page that write an integer console
-- variable must carry bool_to_num = true. Without it the stock ui_options.On_Accept sends "on"/"off", the engine's
-- CCC_Integer parses that as 0 and friendly fire / shared rewards / name tags are silently always off.
-- Real coop_menu_options.script; the stock options window is a stand-in (menu_stubs.lua). Not shipped.
-- Run: tools\test_lua.cmd menu_options
dofile("tests/lua/support/menu_stubs.lua")

local BS = string.char(92)

-- Mirrors the console-command part of UIOptions:On_Accept in the stock ui_options.script (a boolean option value
-- becomes "1"/"0" with bool_to_num, otherwise "on"/"off"; everything else is sent as is).
local function stock_console_line(opt, val)
	local cmd_value = val
	if type(cmd_value) == "boolean" then
		if opt.bool_to_num then
			cmd_value = cmd_value and "1" or "0"
		else
			cmd_value = cmd_value and "on" or "off"
		end
	end
	return opt.cmd .. " " .. tostring(cmd_value)
end

-- The page, built exactly like ui_options does it: install() wraps init_opt_base and appends the page.
local function build_options_page()
	ui_options = { options = {} }
	function ui_options.init_opt_base() ui_options.options = { { id = "video" }, { id = "sound" } } end
	local mo = load_module("coop_menu_options")
	mo.install()
	ui_options.init_opt_base()
	local page
	for _, t in ipairs(ui_options.options) do
		if t.id == "coop" then page = t end
	end
	return assert(page, "coop page was not appended")
end

-- Console variable types registered by the engine's co-op layer: name -> "Integer" | "String" | "Token" | ...
local function engine_console_types()
	local types, files = {}, 0
	local pipe = io.popen("dir /b engine" .. BS .. "src" .. BS .. "xrGame" .. BS .. "coop" .. BS .. "*.cpp 2>nul")
	for name in pipe:lines() do
		name = name:gsub("\r", "")
		local fh = io.open("engine/src/xrGame/coop/" .. name, "rb")
		if fh then
			files = files + 1
			local src = fh:read("*a")
			fh:close()
			for kind, cmd in src:gmatch('CMD%d%(CCC_(%w+),%s*"([%w_]+)"') do types[cmd] = kind end
		end
	end
	pipe:close()
	return types, files
end

-------------------------------------------------------------------------------
print("== menu_options_bool_to_num")
local page = build_options_page()

local checks_with_cmd = {}
for _, group in ipairs(page.gr) do
	for _, opt in ipairs(group.gr) do
		if opt.type == "check" and opt.cmd then checks_with_cmd[#checks_with_cmd + 1] = opt end
	end
end

-- the four console check boxes of the page (a deleted or renamed one must not make this test vacuous)
local expected = { coop_friendly_fire = false, coop_share_rewards = false, coop_nametags = false, coop_nametags_dist = false }
for _, opt in ipairs(checks_with_cmd) do
	if expected[opt.cmd] ~= nil then expected[opt.cmd] = true end
end
for cmd, seen in pairs(expected) do
	check(seen, "the page still has a check box for the console variable " .. cmd)
end

for _, opt in ipairs(checks_with_cmd) do
	check(opt.bool_to_num == true, "check box '" .. opt.id .. "' (" .. opt.cmd .. ") has bool_to_num = true")
	check(stock_console_line(opt, true) == opt.cmd .. " 1", "'" .. opt.id .. "': saving true sends '" .. opt.cmd .. " 1'")
	check(stock_console_line(opt, false) == opt.cmd .. " 0", "'" .. opt.id .. "': saving false sends '" .. opt.cmd .. " 0'")
end

-- the engine side of the contract: these console variables really are CCC_Integer (so "on"/"off" would read as 0)
local types, files = engine_console_types()
if files > 0 then
	for _, opt in ipairs(checks_with_cmd) do
		check(types[opt.cmd] == "Integer",
			"engine registers " .. opt.cmd .. " as CCC_Integer (found: " .. tostring(types[opt.cmd]) .. ")")
	end
else
	print("  note: engine/src/xrGame/coop not found, console variable types not cross-checked")
end

-- the stock window must still honour bool_to_num, otherwise the flag above means nothing
local stock = io.open(REF .. "scripts/ui_options.script", "rb")
if stock then
	local src = stock:read("*a")
	stock:close()
	check(src:find("if v.bool_to_num then", 1, true) ~= nil and src:find('cmd_value and "1" or "0"', 1, true) ~= nil,
		"stock ui_options.script still maps bool_to_num to 1/0")
else
	print("  note: " .. REF .. "scripts/ui_options.script not found, stock behaviour not cross-checked")
end

-- check boxes without a console variable live in axr_options.ltx as booleans and must stay untouched
for _, group in ipairs(page.gr) do
	for _, opt in ipairs(group.gr) do
		if opt.type == "check" and not opt.cmd then
			check(opt.bool_to_num == nil, "flag '" .. opt.id .. "' (no console variable) has no bool_to_num")
		end
	end
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
