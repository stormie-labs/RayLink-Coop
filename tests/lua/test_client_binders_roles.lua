-- coop_client_binders is a Core file: it asks the mode facade who this process is, never the engine's role predicates
-- (docs\CODE_RULES.md LAYER-1). Each of its role tests gives what the engine's predicate gave for the same process:
--   "a client" (install, the guards, the status line)   coop_util.follows_world()     was coop.is_client()
--   "a player's machine" (the skipped methods, fixes)   coop_mode.is_player_mirror()  was coop.is_client() and is_mirror()
--   "the host" (the status line)                        a session, the world decided here   was coop.is_host()
-- The oracle below is the old expressions over the engine's roles of the process each answer set stands for
-- (coop_manager.h, coop_roles.h); the script itself gets an engine that raises when it is asked for a role.
-- Runs under every test answer set (tests\lua\support\modes.lua, COOP_LUA_MODE) and for a player's machine.
-- Not shipped. Run: tools\test_lua.cmd client_binders_roles
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")
local facade = load_script("coop_mode")
load_script("coop_util")

-- The engine's roles of each process: a session, WorldServer (is_host), WorldClient (is_client), Mirror (is_mirror).
local ENGINE = {
	hostplay = { active = true, host = true, client = false, mirror = false },
	srv_world = { active = true, host = true, client = false, mirror = false },
	srv_map = { active = true, host = false, client = true, mirror = false },
	none = { active = false, host = false, client = false, mirror = false },
	player = { active = true, host = false, client = true, mirror = true },
}
-- A player's machine is no answer set of its own: the co-op layer's answers there.
local PLAYER = {
	decides_world = function() return false end,
	leads_here = function() return false end,
	is_player_mirror = function() return true end,
}

-- golden: the role tests as the script had them, over the engine's roles
local old = {}
function old.on_client(e) return e.client end
function old.on_mirror(e) return e.client and e.mirror end
function old.role(e) return e.host and "host" or e.client and "client" or "off" end

local function asked() error("a Core file asked the engine for its role", 0) end
coop.is_host, coop.is_client, coop.is_mirror, coop.is_map_server, coop.is_dedicated = asked, asked, asked, asked, asked

-- The Lua sections of configs\coop_route_binders.ltx, as this test has them: one skipped method, one guarded one.
local LTX = {
	binder_lua_skip = { { "test_zone.zone_binder", "spawn" } },
	binder_lua_guard = { { "test_item.item_binder", "update" } },
}
function ini_file()
	local ini = {}
	function ini:section_exist(s) return LTX[s] ~= nil end
	function ini:line_count(s) return #LTX[s] end
	function ini:r_line(s, i) return true, LTX[s][i + 1][1], LTX[s][i + 1][2] end
	return ini
end

local calls
local function fresh_classes()
	calls = { spawn = 0, update = 0 }
	test_zone = { zone_binder = { spawn = function() calls.spawn = calls.spawn + 1 return "spawned" end } }
	test_item = { item_binder = { update = function() calls.update = calls.update + 1 error("binder fault", 0) end } }
end

local function logged(text)
	local n = 0
	for _, line in ipairs(LOG) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function process(name)
	local e = ENGINE[name]
	coop.is_active = function() return e.active end
	if name == "player" then
		modes.install(facade, "hostplay", PLAYER)
	else
		modes.install(facade, name)
	end
	return e
end

local function run(name)
	print("== " .. name .. ": the process from its start")
	local e = process(name)
	fresh_classes()
	local B = load_script("coop_client_binders")
	local ok, n = pcall(B.install)
	check(ok, "install asks no engine role: " .. tostring(n))
	check(ok and (n > 0) == old.on_client(e), "the patches are installed where the engine's is_client() was true ("
		.. tostring(old.on_client(e)) .. ")")
	LOG = {}
	local said = pcall(B.print_status)
	check(said and logged("[coop-binders] role " .. old.role(e) .. ",") == 1, "the status line names the role the engine's "
		.. "is_host() / is_client() gave: " .. old.role(e))

	print("== " .. name .. ": the wrappers ask at call time")
	-- installed on a player's machine, then the answers of this process (a session that ended, a role that changed)
	process("player")
	fresh_classes()
	B = load_script("coop_client_binders")
	check(B.install() == 2, "a player's machine installs both patches")
	e = process(name)
	local done, r = pcall(test_zone.zone_binder.spawn, {})
	check(done and (r == nil and calls.spawn == 0) == old.on_mirror(e),
		"a skipped method is skipped where is_client() and is_mirror() were true (" .. tostring(old.on_mirror(e)) .. ")")
	local caught = pcall(test_item.item_binder.update, {})
	check(calls.update == 1 and caught == old.on_client(e),
		"a guarded method's error is caught where is_client() was true (" .. tostring(old.on_client(e)) .. ")")
end

modes.each(facade, run)
run("player")

-- Where the facade and the engine's is_client() differ: a world server whose Lua state starts while its session is on (a
-- restored world). The bus asks at its own start, and the server's layer comes into the facade after that (the scripts start
-- in the order of their file names): until then the facade answers as "none", nobody decides the world, so the process
-- seems to follow one and the patches are installed, where the engine's is_client() installed none. Every patch asks again
-- when it is called, so with the layer in each of them is the stock method.
print("== a world server asked before its layer is in the facade: the patches are installed and stay stock")
do
	coop.is_active = function() return true end
	modes.install(facade, "none")
	fresh_classes()
	local B = load_script("coop_client_binders")
	check(B.install() == 2, "no layer answers yet: both patches are installed")
	local e = process("srv_world")
	local done, r = pcall(test_zone.zone_binder.spawn, {})
	check(done and r == "spawned" and calls.spawn == 1, "with the layer in, a skipped method runs as the stock's")
	local caught = pcall(test_item.item_binder.update, {})
	check(calls.update == 1 and caught == false, "and a guarded method's error is not caught, as on any world server")
	LOG = {}
	B.print_status()
	check(logged("[coop-binders] role " .. old.role(e) .. ", installed true") == 1,
		"coop_status tells it: the role of a world server, with the patches installed")
end

done("CLIENT BINDERS ROLES")
