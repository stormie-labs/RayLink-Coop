-- Anomaly Coop: how gamedata\scripts\coop_route.script counts the calls it routes, and its tick service every(ms, fn).
-- An owner or view handler runs on every machine (routes::runs_here), so its wrapper does not ask coop.route.runs and counts
-- its runs in Lua; the counts reach the engine in one coop.route.note_batch call, once a second and before the shim's status
-- line. The engine's totals then equal what one coop.route.note per call gave. A host handler asks and notes on every call.
-- every(ms, fn) runs fn through the wrapper its own actor_on_update registration would get (its domain, its skips, its
-- scope), from one actor_on_update that reads the clock once per frame.
-- coop_route is Core: the cases run under every answer set of the facade coop_mode. Run: tools\test_lua.cmd route_counts

local modes = dofile("tests/lua/support/modes.lua")

-- the engine's coop.route.scoped / scope as coop_router.cpp keeps them: wrapper -> domain, the innermost frame on the stack
local function install_scope_api()
	local scopes = setmetatable({}, { __mode = "k" })
	coop.route.scoped = function(fn, domain) scopes[fn] = domain end
	coop.route.scope = function()
		for level = 2, 66 do
			local info = debug.getinfo(level, "f")
			if not info then break end
			local d = info.func and scopes[info.func]
			if d then return d end
		end
		return nil
	end
end

local function boot(mode, set)
	MODE = mode
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	RAN = {}
	coop_native.reset_counts()
	AddScriptCallback("actor_on_item_use")
	install_scope_api()
	load_script_file("coop_mode")
	modes.install(coop_mode, set)
	load_script_file("coop_route")
	assert(coop_route.install() == true, "the shim installs")
end

local function engine_counts(d)
	local ran, skipped, errors = coop_native.counts(d)
	return ran or 0, skipped or 0, errors or 0
end

for _, mode in ipairs({ "client", "host" }) do
	for _, set in ipairs(modes.names()) do
		local tag = mode .. "/" .. set

		print("== route_counts_owner_view " .. tag)
		boot(mode, set)
		RegisterScriptCallback("actor_on_item_use",
			from_script("some_unknown_mod", "return function() RAN.own = (RAN.own or 0) + 1 end"))
		RegisterScriptCallback("actor_on_item_use", from_script("coop_some_view", "return function() RAN.view = (RAN.view or 0) + 1 end"))
		local runs_before, batches_before = ROUTE_CALLS.runs, ROUTE_CALLS.note_batch
		for _ = 1, 5 do SendScriptCallback("actor_on_item_use", "medkit") end
		check(RAN.own == 5 and RAN.view == 5, tag .. ": both handlers ran five times")
		check(ROUTE_CALLS.runs == runs_before, tag .. ": an owner or view wrapper does not ask the engine whether it runs")
		check(engine_counts("owner") == 0 and engine_counts("view") == 0 and ROUTE_CALLS.note_batch == batches_before,
			tag .. ": the runs are counted here until they are handed over")
		coop_route.print_status()
		check(engine_counts("owner") == 5 and engine_counts("view") == 5, tag .. ": the status line hands them over: 5 and 5 (got "
			.. engine_counts("owner") .. ", " .. engine_counts("view") .. ")")
		check(ROUTE_CALLS.note_batch == batches_before + 1, tag .. ": in one call")
		coop_route.print_status()
		check(ROUTE_CALLS.note_batch == batches_before + 1 and engine_counts("owner") == 5,
			tag .. ": nothing counted since: no call, nothing added")

		print("== route_counts_host " .. tag)
		RegisterScriptCallback("actor_on_item_use",
			from_script("treasure_manager", "return function() RAN.tm = (RAN.tm or 0) + 1 end"))
		runs_before = ROUTE_CALLS.runs
		for _ = 1, 3 do SendScriptCallback("actor_on_item_use", "bandage") end
		check(ROUTE_CALLS.runs == runs_before + 3, tag .. ": a host wrapper asks on every call")
		local h_ran, h_skipped = engine_counts("host")
		if mode == "client" then
			check(RAN.tm == nil and h_skipped == 3 and h_ran == 0, tag .. ": skipped three times, each told at once")
		else
			check(RAN.tm == 3 and h_ran == 3 and h_skipped == 0, tag .. ": ran three times, each told at once")
		end

		print("== route_counts_every " .. tag)
		boot(mode, set)
		coop_route.on_game_start()
		check(axr_main.count("actor_on_update") == 1, tag .. ": one actor_on_update for the tick service")
		check(coop_route.every(0, function() end) == false and coop_route.every(100, nil) == false
			and coop_route.every("100", function() end) == false, tag .. ": a bad period or no function: refused")
		local own = from_script("some_unknown_mod", "return function() RAN.own = (RAN.own or 0) + 1; RAN.own_scope = coop_route.scope_now() end")
		local hosted = from_script("treasure_manager", "return function() RAN.tm = (RAN.tm or 0) + 1 end")
		check(coop_route.every(250, own) == true and coop_route.every(250, hosted) == true, tag .. ": two ticks")
		check(axr_main.count("actor_on_update") == 1, tag .. ": still one actor_on_update")
		check(coop_route.handler_domain(own) == "owner" and coop_route.handler_domain(hosted) == "host",
			tag .. ": each tick has its own script's domain")
		local runs_before_tick = ROUTE_CALLS.runs
		NOW = 10000
		SendScriptCallback("actor_on_update")
		check(RAN.own == 1, tag .. ": a tick runs on its first frame")
		check(RAN.own_scope == "owner", tag .. ": under its own wrapper's scope (got " .. tostring(RAN.own_scope) .. ")")
		for _ = 1, 4 do
			NOW = NOW + 50
			SendScriptCallback("actor_on_update")
		end
		check(RAN.own == 1, tag .. ": not before its period is over")
		local asked = ROUTE_CALLS.runs - runs_before_tick
		check(asked == 1, tag .. ": a frame where a host tick is not due asks nothing (asked " .. asked .. "x)")
		NOW = NOW + 50
		SendScriptCallback("actor_on_update")
		check(RAN.own == 2, tag .. ": again at 250 ms")
		local _, h_skipped = engine_counts("host")
		if mode == "client" then
			check(RAN.tm == nil and h_skipped == 2, tag .. ": the host tick is skipped on a client, counted per due call")
			local top = coop_native.top_skipped(10)
			check(top[1] and top[1][1] == "actor_on_update@treasure_manager", tag .. ": the skip names its script and callback")
		else
			check(RAN.tm == 2 and h_skipped == 0, tag .. ": the host tick runs on the host")
		end
		coop_route.every(1000, own)
		NOW = NOW + 250
		SendScriptCallback("actor_on_update")
		check(RAN.own == 3, tag .. ": the same function again keeps its due time")
		NOW = NOW + 250
		SendScriptCallback("actor_on_update")
		check(RAN.own == 3, tag .. ": and from then on runs at its new period")

		print("== route_counts_flush_tick " .. tag)
		local before = engine_counts("owner")
		NOW = NOW + 1000
		SendScriptCallback("actor_on_update")
		check(engine_counts("owner") > before, tag .. ": the counted runs reach the engine within a second without a status line")
	end
end

print("== route_counts_error_on_client")
boot("client", modes.names()[1])
coop_route.on_game_start()
local broken = from_script("some_broken_mod", "return function() RAN.broken = (RAN.broken or 0) + 1; error('tick broke') end")
local after = from_script("some_unknown_mod", "return function() RAN.after = (RAN.after or 0) + 1 end")
coop_route.every(100, broken)
coop_route.every(100, after)
NOW = 5000
check(pcall(SendScriptCallback, "actor_on_update"), "client: a failing tick is caught, as its own handler's error is")
check(RAN.broken == 1 and RAN.after == 1, "client: the next tick still runs")
local _, _, owner_errors = engine_counts("owner")
check(owner_errors == 1, "client: the error is counted in the tick's domain (got " .. owner_errors .. ")")

-- A script may ask for its tick while it is being loaded, before the router is installed: the tick is routed all the same.
print("== route_counts_tick_before_install")
MODE = "client"
do
	local passes, fails = PASSES, FAILS
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
end
RAN = {}
coop_native.reset_counts()
install_scope_api()
load_script_file("coop_mode")
modes.install(coop_mode, modes.names()[1])
load_script_file("coop_route")
local early_host = from_script("treasure_manager", "return function() RAN.early_host = (RAN.early_host or 0) + 1 end")
local early_own = from_script("some_unknown_mod", "return function() RAN.early_own = (RAN.early_own or 0) + 1 end")
check(coop_route.every(100, early_host) == true and coop_route.every(100, early_own) == true,
	"before install: the ticks are taken")
check(coop_route.install() == true, "the shim installs after them")
coop_route.on_game_start()
NOW = 5000
SendScriptCallback("actor_on_update")
local _, early_skipped = engine_counts("host")
check(RAN.early_host == nil and early_skipped == 1,
	"client: a host script's tick taken before install is skipped and counted (ran " .. tostring(RAN.early_host)
	.. ", skipped " .. early_skipped .. ")")
check(RAN.early_own == 1, "client: an owner script's tick taken before install runs")
check(coop_route.handler_domain(early_host) == "host" and coop_route.handler_domain(early_own) == "owner",
	"and both answer their domain")

print(string.format("%d passed, %d failed", PASSES, FAILS))
