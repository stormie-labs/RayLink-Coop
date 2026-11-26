-- The emission's own script (coop_env.script) beside the event bus (coop_main.script): the hooks an adapter joins it by,
-- its tick on the router's tick service (no periodic registration of its own), its coop_status line through the status
-- registry, and the bus without the names that moved out of it.
-- Run: tools\test_lua.cmd env_hooks
local modes = dofile("tests/lua/support/modes.lua")

local function start(mode)
	local passed, failed = PASSES or 0, FAILS or 0
	MODE = mode
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passed, failed
	load_script_file("coop_util")
	load_script_file("coop_trust")
	load_script_file("coop_world_events")
	modes.live(load_script_file("coop_mode"))
	load_script_file("coop_route")
	load_script_file("coop_main")
	load_script_file("coop_env")
	-- as axr_main starts them, in the order of the file names
	coop_env.on_game_start()
	coop_main.on_game_start()
	coop_route.on_game_start()
end

local function tick(ms)
	NOW = NOW + (ms or 300)
	SendScriptCallback("actor_on_update")
end

local function logged(pat)
	local n = 0
	for _, line in ipairs(LOG) do
		if line:find(pat, 1, true) then n = n + 1 end
	end
	return n
end

print("== the bus keeps only the bus")
start("host")
for _, name in ipairs({ "set_env_policy", "reserve_world_event", "allow_world_event", "env_own_cover", "STATUS_MODULES",
	"on_transition_vote", "is_client", "is_active", "say" }) do
	check(coop_main[name] == nil, "coop_main has no " .. name)
end
check(type(coop_env.set_policy) == "function" and type(coop_world_events.allows) == "function",
	"the policy is coop_env's, the reserved names coop_world_events'")

print("== the tick: the router's tick service")
check(#coop_route.handlers_from("actor_on_update", "coop_env") == 0,
	"coop_env registers no actor_on_update of its own: " .. #coop_route.handlers_from("actor_on_update", "coop_env"))
check(#coop_route.handlers_from("actor_on_update", "coop_main") == 1, "the bus keeps its one per-frame handler")
do
	local d_env = coop.route.rule_of("actor_on_update", coop_env.on_game_start)
	local d_main = coop.route.rule_of("actor_on_update", coop_main.on_game_start)
	check(d_env == "view" and d_env == d_main, "the tick's route is its own script's, the domain the bus's handler has: "
		.. tostring(d_env) .. " / " .. tostring(d_main))
	local ran = 0
	coop_env.add_hook("world_tick", function() ran = ran + 1 end)
	SendScriptCallback("actor_on_update")
	check(ran == 1, "the tick runs in the first frame")
	SendScriptCallback("actor_on_update")
	NOW = NOW + 249
	SendScriptCallback("actor_on_update")
	check(ran == 1, "then not before 250 ms are over")
	NOW = NOW + 1
	SendScriptCallback("actor_on_update")
	check(ran == 2, "and at 250 ms again")
end

-- A session that starts in this Lua state. The bus's handler is registered before the router's tick runner (coop_main
-- starts before coop_route), and both gates step by 250 ms from the same frame's clock: in a frame where they are due the
-- debug gate has turned debug mode off before the emission tick runs, as when the bus ran both in one function.
print("== the tick: after the bus's own work of the frame")
do
	local session = false
	start("host")
	coop.is_active = function() return session end
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update") -- no session: nothing held, no tick work
	DEV_DEBUG = true
	local seen = {}
	coop_env.add_hook("world_tick", function() seen[#seen + 1] = tostring(DEV_DEBUG) end)
	session = true
	NOW = NOW + 1000
	SendScriptCallback("actor_on_update")
	check(#seen == 1 and seen[1] == "false", "the debug gate of the frame runs before the emission tick: " .. table.concat(seen, ","))
	coop.is_active = function() return true end
end

print("== hooks")
start("host")
check(coop_env.add_hook("no_such_kind", function() end) == false, "an unknown kind is refused")
check(coop_env.add_hook("world_tick", "not a function") == false, "a hook that is no function is refused")
local world, mirror = {}, {}
check(coop_env.add_hook("world_tick", function(tg) world[#world + 1] = tg end), "world_tick is taken")
check(coop_env.add_hook("mirror_tick", function(tg) mirror[#mirror + 1] = tg end), "mirror_tick is taken")
check(coop_env.add_hook("world_tick", function() error("adapter fault", 0) end), "a second world_tick hook is taken")
tick()
check(#world == 1 and world[1] == NOW and #mirror == 0, "the world runs world_tick with the frame's time, not mirror_tick")
check(logged("lua error in coop_env (world_tick hook)") == 1 and logged("adapter fault") == 1,
	"a hook's error is the bus's caught error, named after coop_env")
tick(100)
check(#world == 1, "the hooks keep the 250 ms step")
tick(200)
check(#world == 2, "and run on the next step")

print("== coop_status")
-- a module the bus used to name: it is there with its lines, and it has not registered itself
coop_loot_claim = { print_status = function() printf("[coop-loot] a line nobody registered") end }
LOG = {}
coop_main.print_status()
check(logged("[coop-lua] role host, client mode false") == 1 and LOG[1]:find("[coop-lua] role host", 1, true) ~= nil,
	"the bus's own line first")
check(logged("[coop-lua] emission sync: phase '--', emission #0") == 1 and LOG[2]:find("emission sync", 1, true) ~= nil,
	"then coop_env's line, from the registry")
check(logged("a line nobody registered") == 0, "the bus names no module: one that did not register itself is not printed")
coop_loot_claim = nil

print("== an exe without co-op: the coop_* callbacks are there")
do
	local passed, failed = PASSES, FAILS
	MODE = "host"
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passed, failed
	coop = nil
	load_script_file("coop_util")
	load_script_file("coop_mode")
	load_script_file("coop_route")
	load_script_file("coop_main")
	local callbacks = coop_route.intercepts()
	for _, name in ipairs({ "coop_on_event", "coop_on_chat", "coop_actor_revived", "coop_on_container_opened", "coop_avatar_step",
		"coop_respawned", "coop_events_lost", "coop_on_world_leaving", "coop_world_away", "coop_world_back", "coop_debug_changed" }) do
		check(callbacks[name] ~= nil, "without the engine API " .. name .. " is declared")
	end
	local heard = 0
	RegisterScriptCallback("coop_on_event", function() heard = heard + 1 end)
	coop_main.on_event("any", "", 0)
	check(heard == 1, "and the bus still calls its subscribers")
	coop_main.on_game_start()
	check(#coop_route.handlers_from("actor_on_update", "coop_main") == 0, "nothing else of the bus starts there")
end

print("== a player's mirror")
start("client")
local seen = {}
coop_env.add_hook("mirror_tick", function(tg) seen[#seen + 1] = tg end)
coop_env.add_hook("world_tick", function() seen.world = true end)
tick()
check(#seen == 1 and not seen.world, "a mirror runs mirror_tick only")
check(coop_env.mirrors_surge() == false and coop_env.reaches_here() == true,
	"no emission mirrored yet; with no policy the world's emission reaches every map")
coop_env.set_policy({ reaches_here = function() return false end })
check(coop_env.reaches_here() == false, "the mode's policy says where the emission reaches")

print(string.format("%d passed, %d failed", PASSES, FAILS))
