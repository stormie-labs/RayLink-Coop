-- coop_status: every module registers its own lines (coop_util.add_status, docs\CODE_RULES.md LUA-6) and names its
-- place among them; the event bus (coop_main) names no module. The order of the lines is pinned here: the bus's own line,
-- then the modules in the order below, which is the order the bus's hand-written list printed them in; then the modules
-- that name no place (they came to coop_status with the registry).
-- The places are read from the scripts themselves, so a module that drops its registration or moves its place fails here.
-- Runs under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE): the registry asks nobody.
-- Not shipped. Run: tools\test_lua.cmd status_order
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")

local ORDER = {
	"coop_env", -- the emission line, the first after the bus's own
	"coop_route",
	"coop_trust",
	"coop_core_chat", "coop_core_hud", "coop_core_player",
	"coop_core_world_news", "coop_core_world_mloot", "coop_core_world_stash", "coop_core_world_trader",
	"coop_world_weather", "coop_world_fx", "coop_world_fight", "coop_world_compat",
	"coop_economy_core",
	"coop_npc_logic", "coop_npc_effects", "coop_npc_meet", "coop_npc_companions", "coop_npc_disguise",
	"coop_npc_world", "coop_npc_compat",
	"coop_tasks",
	"coop_loot_claim",
	"coop_mods_core",
	"coop_hud_depth",
	"coop_client_binders", -- a client's binder patches, the last of the old lines
}
-- registered, no place named: after the lines above, in the order of registration
local NO_PLACE = { "coop_mode", "coop_saves" }

local function source_of(name)
	local fh = io.open("gamedata/scripts/" .. name .. ".script", "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

-- the registration a script makes of itself: how many, and the place it names (nil: none)
local function registration(name)
	local text = source_of(name)
	if not text then return 0 end
	local n, place = 0, nil
	for args in text:gmatch('coop_util%.add_status%(([^%)]*)%)') do
		local who, at = args:match('^"([%w_]+)"%s*,?%s*(%d*)$')
		if who == name then
			n = n + 1
			place = tonumber(at)
		end
	end
	return n, place
end

local function run(set)
	print("== " .. set .. ": every module of the old list registers itself, with its place")
	local places, last = {}, 0
	for _, name in ipairs(ORDER) do
		local n, place = registration(name)
		check(n == 1 and place ~= nil, name .. " registers itself once and names its place (" .. tostring(n) .. ", "
			.. tostring(place) .. ")")
		check(place ~= nil and place > last, name .. " stands after the module before it (" .. tostring(place) .. " > " .. last .. ")")
		places[name] = place
		last = place or last
	end
	for _, name in ipairs(NO_PLACE) do
		local n, place = registration(name)
		check(n == 1 and place == nil, name .. " registers itself and names no place")
	end

	print("== " .. set .. ": the bus keeps no list of names")
	local bus = source_of("coop_main") or ""
	check(bus:find("add_status(", 1, true) == nil and bus:find("print_statuses(", 1, true) ~= nil,
		"coop_main registers nobody: it prints what registered itself")

	print("== " .. set .. ": the lines come out in the old order, whatever the order of the scripts' start")
	local U = load_script("coop_util")
	local printed = {}
	local all = {}
	for _, name in ipairs(ORDER) do all[#all + 1] = name end
	for _, name in ipairs(NO_PLACE) do all[#all + 1] = name end
	local real = {}
	for _, name in ipairs(all) do
		real[name] = rawget(_G, name)
		rawset(_G, name, { print_status = function() printed[#printed + 1] = name end })
	end
	-- the scripts start in the order of their file names: registered that way, with the places they name
	local by_file = {}
	for _, name in ipairs(ORDER) do by_file[#by_file + 1] = name end
	table.sort(by_file)
	for _, name in ipairs(NO_PLACE) do U.add_status(name) end
	for _, name in ipairs(by_file) do U.add_status(name, places[name]) end
	U.print_statuses(function() end)
	check(table.concat(printed, " ") == table.concat(all, " "), "printed: " .. table.concat(printed, " "))
	for _, name in ipairs(all) do rawset(_G, name, real[name]) end
end

modes.each(facade, run)

done("STATUS ORDER")
