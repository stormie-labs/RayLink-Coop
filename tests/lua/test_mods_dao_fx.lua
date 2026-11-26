-- F4 G11-2 (review m19:1): the "Ghost" of Dynamic Anomalies Overhaul (drx_da_main anomalies_spawn_functions.zone_mine_ghost)
-- rolled its own path on every machine and stepped it by its own frame time; that zone is also each player's own anomaly
-- damage. Now the process that leads the map rolls the path with DAO's own choices and hands it to the engine
-- (coop.zone_path), which runs it there and on the copies of the players of that map (engine: xrCoop/coop_zone_path_rules.h,
-- tests/test_zone_path_rules.cpp: two frame rates, a late player). A player's machine and the world server roll nothing.
-- Single player: DAO's own function, unchanged. The real merged mod function runs here; coop.zone_path is a stub that records.
-- Runs once per answer set of the facade coop_mode (COOP_LUA_MODE): hostplay (co-op host, and a co-op client by override),
-- srv_map (map server, and a server player by override), srv_world (the world server), none (single player).
MODE = "host"
dofile("tests/lua/support/stubs_mods.lua")
local modes = dofile("tests/lua/support/modes.lua")

local function source(name)
	local f = assert(io.open("temp/review/corpus/merged/" .. name .. ".script", "rb"))
	local s = f:read("*a")
	f:close()
	return s
end
local function slice(s, first, last)
	local a = assert(s:find(first, 1, true), first)
	local b = assert(s:find(last, a, true), last)
	return s:sub(a, b - 1)
end

-- drx_da_main as GAMMA loads it: its callbacks (register_callback / unregister_callback) and its spawn and destroy functions,
-- with the file locals they use.
GROUND_Y = 1.75
FRAME_MS = 16
RANDOM_CALLS = 0
function random_choice(...)
	RANDOM_CALLS = RANDOM_CALLS + 1
	local a = { ... }
	return a[math.random(1, #a)]
end
level.vertex_id = function() return 7 end
level.vertex_position = function() return vec3(0, GROUND_Y, 0) end
function device() return { time_delta = FRAME_MS } end
do
	local src = source("drx_da_main")
	local pre = [[
local random = function(...) RANDOM_CALLS = RANDOM_CALLS + 1 return math.random(...) end
local abs, min, floor = math.abs, math.min, math.floor
local level_vertex_id = level.vertex_id
local level_vertex_position = level.vertex_position
anomalies_vars = { sin_lut = {}, cos_lut = {} }
for i = 0, 360 do anomalies_vars.sin_lut[i] = math.sin(i * 0.0174533) anomalies_vars.cos_lut[i] = math.cos(i * 0.0174533) end
]]
	local body = pre .. slice(src, "\ncallbacks = {}", "-- Get psy table") ..
		slice(src, "anomalies_spawn_functions = {", "anomaly_detector_ignore = {")
	local m = setmetatable({}, { __index = _G })
	rawset(_G, "drx_da_main", m)
	local f = assert(loadstring(body, "@drx_da_main.script"))
	setfenv(f, m)
	f()
end
local DA = drx_da_main
local DAO_SPAWN = DA.anomalies_spawn_functions.zone_mine_ghost

-- the engine: coop.zone_path records, answers ZONE_PATH_OK
ZONE_PATHS = {}
ZONE_PATH_OK = true
local function engine_path(...)
	ZONE_PATHS[#ZONE_PATHS + 1] = { ... }
	return ZONE_PATH_OK
end
coop.zone_path = engine_path

make_actor()
start_all()
local loaded = pcall(load_script, "coop_mods_dao_fx")
check(loaded, "coop_mods_dao_fx loads")
if loaded then coop_mods_dao_fx.on_game_start() end

-- a Ghost as its binder holds it (bind_anomaly_field net_spawn: spawn_position = object:position())
local function ghost(pos)
	local _, obj = spawn("zone_mine_ghost", pos or vec3(10, 2, 30))
	obj.moves = 0
	obj.name = function(self) return "zone_mine_ghost_" .. self._id end
	obj.set_anomaly_position = function(self, v)
		self.moves = self.moves + 1
		self._pos = vector():set(v)
	end
	return { object = obj, section = "zone_mine_ghost", spawn_position = obj:position() }, obj
end
local function net_spawn(b) DA.anomalies_spawn_functions[b.section](b) end
local function net_destroy(b) DA.anomalies_destroy_functions[b.section](b) end
local function frames(n, ms)
	for _ = 1, n do
		NOW = NOW + ms
		FRAME_MS = ms
		SendScriptCallback("actor_on_update")
	end
end
local function stock_wander(obj) return DA.callbacks[obj:name()] ~= nil end
local function reset_counts()
	ZONE_PATHS = {}
	RANDOM_CALLS = 0
	ZONE_PATH_OK = true
	coop.zone_path = engine_path
end

-- the values DAO rolls (:2413-2432): what the engine accepts
local J_OF = { [1] = { [2] = true, [3] = true }, [2] = { [1] = true, [3] = true }, [3] = { [2] = true, [4] = true } }
local function rolled_like_dao(c, b)
	local id, x, y, z, i0, is, js, xm, zm = unpack(c)
	local sp = b.spawn_position
	local function amp(v) return type(v) == "number" and math.abs(v) >= 0.5 and math.abs(v) <= 3.0 end
	return id == b.object:id() and x == sp.x and y == sp.y and z == sp.z and (i0 == 0 or i0 == 45 or i0 == 90 or i0 == 135 or
		i0 == 180) and J_OF[is] ~= nil and J_OF[is][js] == true and amp(xm) and amp(zm)
end

-- The process that leads the map: one roll, handed to the engine; no wander of its own in Lua.
local function decider_case(tag)
	reset_counts()
	local b, obj = ghost()
	net_spawn(b)
	check(#ZONE_PATHS == 1, tag .. ": the path goes to the engine once (" .. #ZONE_PATHS .. ")")
	check(ZONE_PATHS[1] ~= nil and rolled_like_dao(ZONE_PATHS[1], b),
		tag .. ": the zone, its spawn point and a roll DAO makes (" .. table.concat(ZONE_PATHS[1] or {}, " ") .. ")")
	check(not stock_wander(obj), tag .. ": no Lua wander of its own (the engine moves the zone)")
	frames(30, 16)
	check(obj.moves == 0, tag .. ": Lua does not move the zone (" .. obj.moves .. ")")
	net_destroy(b)
	check(not stock_wander(obj), tag .. ": destroyed: nothing left registered")

	-- a Ghost that was online before the session (single player, then hosting): DAO's own wander is taken back and the
	-- engine gets a path around its spawn point, not around where it has wandered to
	reset_counts()
	MODE = "sp"
	b, obj = ghost(vec3(-40, 5, 12))
	net_spawn(b)
	check(stock_wander(obj), tag .. ": before the session DAO's own wander runs")
	frames(10, 33)
	check(obj.moves > 0, tag .. ": and moves the zone")
	MODE = "host"
	frames(1, 16)
	check(not stock_wander(obj), tag .. ": the session took DAO's wander back")
	check(#ZONE_PATHS == 1 and rolled_like_dao(ZONE_PATHS[1], b),
		tag .. ": and gave the engine a path around the spawn point (" .. #ZONE_PATHS .. ")")
	frames(5, 16)
	check(#ZONE_PATHS == 1, tag .. ": once (" .. #ZONE_PATHS .. ")")
	-- the session is over (the host plays on alone): DAO's wander again
	MODE = "sp"
	frames(1, 16)
	check(stock_wander(obj), tag .. ": after the session DAO's own wander is back")
	MODE = "host"
	frames(1, 16)
	net_destroy(b)

	-- the engine refuses the path: DAO's own wander here, counted
	reset_counts()
	ZONE_PATH_OK = false
	b, obj = ghost()
	net_spawn(b)
	check(#ZONE_PATHS == 1 and stock_wander(obj), tag .. ": a refused path: DAO's own wander on this machine")
	net_destroy(b)
	reset_counts()
end

-- A player's machine (or the world server): nothing rolled, nothing registered, the zone not moved by Lua.
local function quiet_case(tag)
	reset_counts()
	local b, obj = ghost()
	net_spawn(b)
	check(#ZONE_PATHS == 0, tag .. ": no path of its own (" .. #ZONE_PATHS .. ")")
	check(RANDOM_CALLS == 0, tag .. ": no roll of its own (" .. RANDOM_CALLS .. " random calls)")
	check(not stock_wander(obj), tag .. ": no Lua wander")
	frames(30, 16)
	check(obj.moves == 0, tag .. ": Lua does not move the zone (" .. obj.moves .. ")")
	net_destroy(b)
end

local MIRROR = { leads_here = function() return false end, is_player_mirror = function() return true end,
	decides_world = function() return false end, actor_is_player = function() return true end }

for _, name in ipairs(modes.names()) do
	print("== DAO Ghost path (" .. name .. ")")
	if name == "hostplay" then
		MODE = "client"
		modes.install(coop_mode, name, MIRROR)
		quiet_case("co-op client")
		MODE = "host"
		modes.install(coop_mode, name)
		decider_case("co-op host")
	elseif name == "srv_map" then
		MODE = "client"
		modes.install(coop_mode, name, MIRROR)
		quiet_case("server player")
		MODE = "host"
		modes.install(coop_mode, name)
		decider_case("map server")
	elseif name == "srv_world" then
		MODE = "host"
		modes.install(coop_mode, name)
		quiet_case("world server")
	else
		-- single player: DAO's own function, exactly
		MODE = "sp"
		modes.install(coop_mode, name)
		reset_counts()
		local b, obj = ghost()
		net_spawn(b)
		check(#ZONE_PATHS == 0, "single player: no engine path")
		check(stock_wander(obj), "single player: DAO's own wander")
		check(RANDOM_CALLS > 0, "single player: DAO's own roll")
		frames(20, 33)
		check(obj.moves == 20, "single player: DAO moves the zone every frame (" .. obj.moves .. ")")
		net_destroy(b)
		check(not stock_wander(obj), "single player: DAO's destroy unregisters it")
		check(DA.anomalies_spawn_functions.zone_mine_ghost ~= DAO_SPAWN or not loaded,
			"single player: the function is wrapped (and calls DAO's own)")
	end
end

-- on_game_start never throws, also without DAO
do
	local saved = rawget(_G, "drx_da_main")
	rawset(_G, "drx_da_main", nil)
	local ok, err = pcall(function() if loaded then coop_mods_dao_fx.on_game_start() end end)
	check(ok, "on_game_start without DAO does not throw (" .. tostring(err) .. ")")
	rawset(_G, "drx_da_main", saved)
end

done("DAO Ghost path")
