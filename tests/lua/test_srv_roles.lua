-- Anomaly Coop test: gamedata\scripts\coop_srv_roles.script, the roles the server's scripts ask. Each process here is its own
-- environment over the real coop_util and coop_srv_roles, with the engine's answers as coop.* stand-ins.
-- Not shipped. Run: tools\test_lua.cmd srv_roles
local PASSES, FAILS = 0, 0
local function check(cond, what)
	if cond then
		PASSES = PASSES + 1
		print("  ok   " .. what)
	else
		FAILS = FAILS + 1
		print("  FAIL " .. what)
	end
end

-- a process: `api` the engine's coop.* (nil: an exe without co-op)
local function process(api)
	local env = setmetatable({ coop = api }, { __index = _G })
	env._G = env
	for _, name in ipairs({ "coop_util", "coop_srv_roles" }) do
		local f = assert(loadfile("gamedata/scripts/" .. name .. ".script"))
		local m = setmetatable({}, { __index = env })
		setfenv(f, m)
		f()
		env[name] = m
	end
	return env.coop_srv_roles
end

local function engine(t)
	local s = t.session ~= false
	return {
		is_active = function() return s end,
		is_host = function() return t.host == true end,
		is_map_server = function() return t.map == true end,
		is_dedicated = function() return t.dedicated == true end,
		levels = t.levels,
	}
end

print("== the world server")
local R = process(engine({ host = true, dedicated = true, levels = { split = function() return true end } }))
check(R.world_server() and not R.map_server() and R.dedicated() and R.split(), "in its session: the world server, split")
R = process(engine({ session = false, host = true, dedicated = true }))
check(not R.world_server() and R.dedicated(), "before its session: no world server yet, started as one")

print("== a map server")
R = process(engine({ map = true, levels = { split = function() return true end } }))
check(R.map_server() and not R.world_server() and not R.dedicated() and R.split(), "in its session: a map server")
R = process(engine({ map = true, host = true }))
check(R.map_server() and not R.world_server(), "a map server is never the world server, whatever is_host says")
R = process(engine({ session = false, map = true }))
check(not R.map_server(), "outside a session: no map server")

print("== a player's machine and no co-op")
R = process(engine({}))
check(not (R.world_server() or R.map_server() or R.dedicated() or R.split()), "a player: none of the roles")
R = process(engine({ host = true, levels = {} }))
check(not R.split(), "levels without split: not split")
R = process(nil)
check(not (R.world_server() or R.map_server() or R.dedicated() or R.split()), "an exe without co-op: none of the roles")
local raising = engine({ host = true, dedicated = true })
raising.is_host = function() error("engine fault") end
R = process(raising)
check(R.world_server() == false and R.dedicated(), "a raising engine call answers no")

print(string.format("== %d passed, %d failed", PASSES, FAILS))
if FAILS > 0 then error("failures") end
