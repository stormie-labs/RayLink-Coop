-- coop_util (Core, docs\CODE_RULES.md LUA-1): the helpers the emission script, the event bus, the client binders and an
-- adapter share instead of a copy each. Every helper is compared with the copy it replaces, written out below as the
-- oracle, under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE):
--   follows_world()         "a session runs and another process decides its world"; per kind of process it is what the
--                           engine's own role says of it (coop_manager.h is_client: a player's machine or a map server)
--   option(name, def)       a game option read through ui_options, with a default
--   in_range(v, min, max)   a number inside a closed range
--   add_status(name, place) a module names its place among the coop_status lines; the order of printing is by place
-- Not shipped. Run: tools\test_lua.cmd util_roles_options
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
local U = load_script("coop_util")

-- golden: the copies the helpers replace, as they were written in the scripts
local old = {}
-- coop_main and coop_env, one copy each
function old.follows_world()
	return coop.is_active() and not coop_mode.decides_world()
end
-- coop_env and the Preblowout adapter, one copy each
function old.option(name, def)
	local uo = rawget(_G, "ui_options")
	local ok, v = pcall(function() return uo and uo.get(name) end)
	if ok and v ~= nil then return v end
	return def
end
-- coop_env bounded_env_number, the Preblowout adapter's bounded
function old.bounded(value, min, max)
	return type(value) == "number" and value >= min and value <= max
end

-- The engine's role of the process each answer set stands for (coop_manager.h): is_client() is the role WorldClient, a
-- player's machine or a map server in a session; no role without a session.
local IS_CLIENT = { hostplay = false, srv_world = false, srv_map = true, none = false }

local real_active = coop.is_active

local function run(name)
	print("== " .. name .. ": follows_world")
	coop.is_active = function() return name ~= "none" end
	check(U.follows_world() == IS_CLIENT[name], "follows_world is the engine's client role of this process (" .. tostring(IS_CLIENT[name]) .. ")")
	check(U.follows_world() == old.follows_world(), "and what the copies in coop_main and coop_env answered")
	coop.is_active = function() return false end
	check(U.follows_world() == false and old.follows_world() == false, "no session: nobody follows a world")
	coop.is_active = real_active

	print("== " .. name .. ": option")
	local real_options = rawget(_G, "ui_options")
	local VALUES = { on = true, off = false, text = "kill_at_wave", zero = 0 }
	ui_options = {
		get = function(key)
			if key == "boom" then error("no such option") end
			return VALUES[key]
		end,
	}
	for _, key in ipairs({ "on", "off", "text", "zero", "missing", "boom" }) do
		for _, def in ipairs({ "default", false }) do
			check(U.option(key, def) == old.option(key, def),
				string.format("option(%s, %s) = %s", key, tostring(def), tostring(old.option(key, def))))
		end
	end
	check(U.option("off", true) == false, "an option that is false is false, not the default")
	check(U.option("missing") == nil and U.option("boom", 7) == 7, "no value, or a read that raises: the default")
	ui_options = nil
	check(U.option("on", "default") == "default" and old.option("on", "default") == "default",
		"the options script is not loaded: the default")
	ui_options = real_options

	print("== " .. name .. ": in_range")
	for _, v in ipairs({ 0, 1, 5, 5.5, 6, -1, 0 / 0, math.huge, "3", true, {} }) do
		check(U.in_range(v, 1, 5.5) == old.bounded(v, 1, 5.5), "in_range(" .. tostring(v) .. ", 1, 5.5) = " .. tostring(old.bounded(v, 1, 5.5)))
	end
	check(U.in_range(nil, 0, 1) == false and U.in_range(1, 1, 1) == true, "nil is outside, the ends are inside")
end

modes.each(facade, run)

-- A player's machine is no answer set of its own (the co-op layer and the server's both answer for one): the co-op
-- layer's answers there.
print("== a player's machine")
modes.install(facade, "hostplay", {
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
})
check(U.follows_world() == true and old.follows_world() == true, "a player's machine follows the world")

-- The status registry: a module names its place, coop_status prints by place.
print("== add_status: places")
local printed = {}
local function module_of(tag)
	return { print_status = function() printed[#printed + 1] = tag end }
end
coop_test_place_c, coop_test_place_a, coop_test_place_b = module_of("c"), module_of("a"), module_of("b")
coop_test_place_late, coop_test_place_free1, coop_test_place_free2 = module_of("late"), module_of("free1"), module_of("free2")
U.add_status("coop_test_place_free1")
U.add_status("coop_test_place_c", 30)
U.add_status("coop_test_place_free2")
U.add_status("coop_test_place_a", 10)
U.add_status("coop_test_place_b", 20)
U.add_status("coop_test_place_a", 99) -- once per name: the first registration stands
U.print_statuses(function() end)
check(table.concat(printed, ",") == "a,b,c,free1,free2",
	"by place, ascending; a module without a place after those that have one, in the order it registered: "
	.. table.concat(printed, ","))
printed = {}
U.add_status("coop_test_place_late", 15)
U.print_statuses(function() end)
check(table.concat(printed, ",") == "a,late,b,c,free1,free2", "a module that registers later still stands at its place: "
	.. table.concat(printed, ","))

done("UTIL ROLES OPTIONS")
