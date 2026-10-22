-- Anomaly Coop: the Lua half of the callback router (gamedata\scripts\coop_route.script, F2 T10, MOD_LAYER.md §2.2)
-- over the engine API coop.route, stood in by tests\lua\support\stubs.d\route.lua: the script keys, the route table
-- and the counters are the engine's own C++ (coop_routes.h through coop_native); the overrides are the shipped
-- gamedata\configs\coop_route*.ltx. Run: tools\test_lua.cmd route_shim

-- a chunk defined in a .lua package file (debug.getinfo source = its path under the scripts folder, like require)
local function from_lua(rel, body, ...)
	local f = assert(loadstring(body, "@.\\gamedata\\scripts\\" .. rel .. ".lua"))
	return f(...)
end

-- axr_main's local `intercepts` (an upvalue of callback_set, as in the shipped script)
local function intercepts()
	for i = 1, 255 do
		local n, v = debug.getupvalue(axr_main.callback_set, i)
		if n == nil then break end
		if n == "intercepts" then return v end
	end
	-- after install callback_set is the shim's wrapper: ask the shim
	return coop_route and coop_route.intercepts()
end

local function order_string() return table.concat(ORDER, ",") end

-- A fresh Lua world per case (stubs: axr_main, coop + coop.route; then coop_route.script), the check counters kept.
-- before(): registrations made before the shim is installed.
local function boot(mode, before, no_install)
	MODE = mode
	local passes, fails = PASSES or 0, FAILS or 0
	dofile("tests/lua/support/stubs.lua")
	PASSES, FAILS = passes, fails
	RAN, ORDER = {}, {}
	coop_native.reset_counts()
	for _, name in ipairs({ "actor_on_item_use", "npc_on_death_callback", "idiots_on_start", "actor_on_first_update",
		"mcm_option_change", "npc_on_hit_callback", "idiots_on_state_change", "save_state" }) do
		AddScriptCallback(name)
	end
	if before then before() end
	load_script_file("coop_route")
	if not no_install then check(coop_route.install() == true, mode .. ": the shim installs") end
end

print("== route_shim_client_skips_host")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("actor_on_update",
		from_script("treasure_manager", "return function() RAN.tm = (RAN.tm or 0) + 1 end"))
	SendScriptCallback("actor_on_update")
	if mode == "client" then
		check(RAN.tm == nil, "client: treasure_manager on actor_on_update is skipped (host script)")
		local _, skipped = coop_native.counts("host")
		check(skipped == 1, "client: the skip is counted in the host domain (got " .. tostring(skipped) .. ")")
		local top = coop_native.top_skipped(10)
		check(top[1] and top[1][1] == "actor_on_update@treasure_manager" and top[1][2] == 1,
			"client: the pair actor_on_update@treasure_manager tops the skips (review M2: per callback and script)")
		local latest = coop_native.latest_new_skips(10)
		check(latest[1] == "actor_on_update@treasure_manager", "client: and it is the latest new skip")
	else
		check(RAN.tm == 1, "host: treasure_manager on actor_on_update runs")
		local ran, skipped = coop_native.counts("host")
		check(ran == 1 and skipped == 0, "host: counted as ran")
	end
end

print("== route_shim_unknown_script_runs_owner")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("actor_on_item_use", from_script("some_unknown_mod", "return function(o) RAN.use = o end"))
	RegisterScriptCallback("npc_on_death_callback", from_script("some_unknown_mod", "return function() RAN.death = true end"))
	SendScriptCallback("actor_on_item_use", "medkit")
	SendScriptCallback("npc_on_death_callback")
	check(RAN.use == "medkit", mode .. ": an unknown script's actor_on_item_use runs (owner by the callback, R5 I4)")
	if mode == "client" then
		check(RAN.death == nil, "client: an unknown script's npc_on_death_callback is skipped (host by the callback)")
	else
		check(RAN.death == true, "host: an unknown script's npc_on_death_callback runs")
	end
end

-- Review Focus 3: an unknown script now runs on a client; what it does to the world goes through the engine, which
-- turns a client's alife():create into one request to the host (call router, MOD_LAYER §2.3) and makes no local object.
print("== route_shim_unknown_script_world_call_is_gated")
boot("client")
REQUESTS, OBJECTS = {}, {}
function alife()
	return {
		create = function(_, section)
			if coop.is_client() then
				REQUESTS[#REQUESTS + 1] = section
				return nil
			end
			local o = { id = #OBJECTS + 1, section = section }
			OBJECTS[#OBJECTS + 1] = o
			return o
		end,
	}
end
RegisterScriptCallback("actor_on_update", from_script("some_unknown_mod", [[return function()
	RAN.calls = (RAN.calls or 0) + 1
	RAN.created = alife():create("medkit")
end]]))
SendScriptCallback("actor_on_update")
check(RAN.calls == 1, "client: the unknown script's actor_on_update ran once")
check(#REQUESTS == 1 and REQUESTS[1] == "medkit", "client: the engine got exactly one request (got " .. #REQUESTS .. ")")
check(#OBJECTS == 0 and RAN.created == nil, "client: no local object")

print("== route_shim_priority_and_unregister")
boot("client")
local a = from_script("ui_a", "return function() ORDER[#ORDER + 1] = 'a' end")
local b = from_script("ui_b", "return function() ORDER[#ORDER + 1] = 'b' end")
local c = from_script("ui_c", "return function() ORDER[#ORDER + 1] = 'c' end")
RegisterScriptCallback("on_key_press", b)
RegisterScriptCallback("on_key_press", c)
RegisterScriptCallback("on_key_press", a)
SendScriptCallback("on_key_press")
check(order_string() == "b,c,a", "the registration order (priority) is kept: " .. order_string())
local t = intercepts().on_key_press
local wa = coop_route.wrapper_of("on_key_press", a)
check(wa ~= nil and wa ~= a and t[wa] ~= nil and t[a] == nil, "the shim registered a wrapper, not the function")
RegisterScriptCallback("on_key_press", a)
check(axr_main.count("on_key_press") == 3 and coop_route.wrapper_of("on_key_press", a) == wa,
	"one wrapper per (callback, function): registering again does not add a second")
UnregisterScriptCallback("on_key_press", c)
check(axr_main.count("on_key_press") == 2, "unregister removes the wrapper")
check(coop_route.wrapper_of("on_key_press", c) == nil, "the shim forgets the unregistered pair")
ORDER = {}
SendScriptCallback("on_key_press")
check(order_string() == "b,a", "the others keep their order: " .. order_string())
UnregisterScriptCallback("on_key_press", wa) -- by the wrapper itself (an addon that read the table)
check(axr_main.count("on_key_press") == 1 and coop_route.wrapper_of("on_key_press", a) == nil,
	"unregister by the wrapper works too")
-- an object registers itself: called as obj[name](obj, ...)
local obj = from_script("ui_obj", "return { on_key_press = function(self, k) ORDER[#ORDER + 1] = self.tag .. k end, tag = 'obj' }")
RegisterScriptCallback("on_key_press", obj)
ORDER = {}
SendScriptCallback("on_key_press", 7)
check(order_string() == "b,obj7", "an object callback is called with itself: " .. order_string())
UnregisterScriptCallback("on_key_press", obj)
check(axr_main.count("on_key_press") == 1, "unregister of an object callback")
check(#coop_route.handlers_of("on_key_press", "ui_b") == 1 and coop_route.handlers_of("on_key_press", "ui_b")[1] == b,
	"handlers_of gives the script's own function back")

print("== route_shim_late_install")
local PRE, before = {}, {}
boot("client", function()
	PRE.obj = from_script("ui_obj", "return { actor_on_update = function(self) ORDER[#ORDER + 1] = self.tag end, tag = 'obj' }")
	PRE.host = from_script("treasure_manager", "return function() ORDER[#ORDER + 1] = 'host' end")
	PRE.view = from_script("ui_extra", "return function() ORDER[#ORDER + 1] = 'view' end")
	PRE.owner = from_script("actor_effects", "return function() ORDER[#ORDER + 1] = 'owner' end")
	RegisterScriptCallback("actor_on_update", PRE.obj)
	RegisterScriptCallback("actor_on_update", PRE.host)
	RegisterScriptCallback("actor_on_update", PRE.view)
	RegisterScriptCallback("actor_on_update", PRE.owner)
	-- a mod moved one ahead by its priority value (axr_main sorts by the value)
	intercepts().actor_on_update[PRE.owner] = 0.5
	for k, v in pairs(intercepts().actor_on_update) do before[k] = v end
end)
check(before[PRE.owner] == 0.5 and before[PRE.view] ~= nil, "the values before install were read")
SendScriptCallback("actor_on_update")
check(order_string() == "owner,obj,view", "registrations made before install are routed, order kept: " .. order_string())
local t2 = intercepts().actor_on_update
local same = true
for name, f in pairs(PRE) do
	local w = coop_route.wrapper_of("actor_on_update", f)
	if not (w and t2[f] == nil and t2[w] == before[f]) then same = false end
end
check(same, "each one is replaced in place by its wrapper with the same priority value")
check(axr_main.count("actor_on_update") == 4, "nothing added or lost")
local hs = coop_route.handlers_of("actor_on_update", "treasure_manager")
check(#hs == 1 and hs[1] == PRE.host, "handlers_of finds a reclassified handler")
check(coop_route.install() == true and axr_main.count("actor_on_update") == 4, "a second install changes nothing")

print("== route_shim_none_on_host")
boot("host")
route_stub_load()
coop_native.add("route_scripts", { cheat_spawner = "none" })
local cheat = from_script("cheat_spawner", "return function() RAN.cheat = (RAN.cheat or 0) + 1 end")
RegisterScriptCallback("actor_on_update", cheat)
RegisterScriptCallback("load_state", from_script("cheat_spawner", "return function() RAN.cheat_load = true end"))
SendScriptCallback("actor_on_update")
check(RAN.cheat == nil, "host: a none script is skipped on the host too")
SendScriptCallback("load_state", {})
check(RAN.cheat_load == nil, "host: a forced view callback does not bring a none script back")
local _, none_skipped = coop_native.counts("none")
check(none_skipped == 2, "host: counted as none skips")
coop.is_active = function() return false end -- single player: no session, nothing is co-op routed
SendScriptCallback("actor_on_update")
check(RAN.cheat == 1, "outside a session the same handler runs (single player is untouched)")

print("== route_shim_unique_calls_and_time_events")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	local uc_host = from_script("surge_manager", "return function() RAN.uc = true return false end")
	AddUniqueCall(uc_host)
	local w = UNIQUE[#UNIQUE]
	if mode == "client" then
		check(w ~= uc_host and w() == false and RAN.uc == nil, "client: a host unique call is skipped and stays (false)")
	else
		check(w() == false and RAN.uc == true, "host: a host unique call runs")
	end
	local n = #UNIQUE
	RemoveUniqueCall(uc_host)
	check(#UNIQUE == n - 1, mode .. ": RemoveUniqueCall finds the wrapper")
	local te_host = from_script("death_manager", "return function() RAN.te = true end")
	CreateTimeEvent("x", "y", 1, te_host)
	if mode == "client" then
		check(TIMEEV[#TIMEEV].f ~= te_host and TIMEEV[#TIMEEV].f() == true and RAN.te == nil,
			"client: a host time event is skipped and removed (true)")
		local uc_err = from_script("xrs_dyn_music", "return function() error('loop broken') end")
		AddUniqueCall(uc_err)
		check(UNIQUE[#UNIQUE]() == true, "client: a broken view unique call returns true (removed)")
		local _, _, errors = coop_native.counts("view")
		check(errors == 1, "client: the error is counted in the view domain")
	else
		check(TIMEEV[#TIMEEV].f() == nil and RAN.te == true, "host: a host time event runs")
	end
	-- _g_patches.script replaces _G.CreateTimeEvent with its own; a replacement after install is wrapped again
	-- in on_game_start (axr_main runs it after every script is loaded)
	local later = {}
	_G.CreateTimeEvent = function(ev, act, timer, f) later[#later + 1] = f end
	coop_route.on_game_start()
	CreateTimeEvent("x", "z", 1, te_host)
	RAN.te = nil
	local f = later[1]
	if mode == "client" then
		check(f ~= nil and f ~= te_host and f() == true and RAN.te == nil, "client: the later CreateTimeEvent is wrapped too")
	else
		check(f ~= nil and f() == nil and RAN.te == true, "host: the later CreateTimeEvent still runs the handler")
	end
	coop_route.on_game_start()
	CreateTimeEvent("x", "w", 1, te_host)
	check(#later == 2 and later[2] == later[1], mode .. ": no double wrap, one wrapper per function")
end

-- Live bug 2026-10-23: the filter keyed a function by its file's base name, so GAMMA's
-- illish\patches\xr_combat_ignore.lua counted as the stock xr_combat_ignore. The key is the path now.
print("== route_shim_script_keys_by_path")
boot("client")
local body = "return function() end"
local stock = assert(loadstring(body, "@D:\\Games\\Anomaly\\gamedata\\scripts\\xr_combat_ignore.script"))()
local patch = assert(loadstring(body, "@E:\\AnomalyCoopGamma\\gamedata\\scripts\\illish\\patches\\xr_combat_ignore.lua"))()
local _, k_stock = coop.route.of("actor_on_update", stock)
local _, k_patch = coop.route.of("actor_on_update", patch)
check(k_stock == "xr_combat_ignore", "the stock script keeps its name (got " .. tostring(k_stock) .. ")")
check(k_patch == "illish.patches.xr_combat_ignore", "the same body from illish\\patches gets its path (got "
	.. tostring(k_patch) .. ")")
local d_stock = coop.route.of("npc_on_update", from_script("utils_obj", body))
local d_patch, k_utils = coop.route.of("npc_on_update", from_lua("illish\\patches\\utils_obj", body))
check(d_stock == "view", "utils_obj is view through utils_* (got " .. tostring(d_stock) .. ")")
check(k_utils == "illish.patches.utils_obj" and d_patch == "host",
	"utils_* does not catch illish.patches.utils_obj: npc_on_update keeps its host default (got " .. tostring(d_patch) .. ")")
local d_items = coop.route.of("actor_on_item_take", from_lua("illish\\patches\\itms_manager", body))
check(d_items == "owner", "illish's itms_manager.actor_on_item_take (registered by the stock script) stays owner")
check(select(2, coop.route.of("actor_on_update", print)) == "[C]", "a C function is [C]")

-- Useful Idiots: idiots_on_start runs everywhere (forced view, live fix 2026-10-23); what its listeners register in
-- illish\patches\surge_manager.lua:146 and axr_companions.lua:223 stays host (their own script rules).
print("== route_shim_idiots_nested_stay_host")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("idiots_on_start", from_lua("illish\\patches\\surge_manager", [[return function()
		RAN.surge_init = true
		RegisterScriptCallback("actor_on_first_update", function() RAN.surge_covers = true end)
		RegisterScriptCallback("mcm_option_change", function() RAN.surge_mcm = true end)
	end]]))
	RegisterScriptCallback("idiots_on_start", from_lua("illish\\patches\\axr_companions", [[return function()
		RAN.comp_init = true
		RegisterScriptCallback("npc_on_hit_callback", function() RAN.comp_hit = true end)
		RegisterScriptCallback("actor_on_first_update", function() RAN.comp_split = true end)
		RegisterScriptCallback("idiots_on_state_change", function() RAN.comp_state = true end)
	end]]))
	RegisterScriptCallback("idiots_on_start", from_lua("illish\\patches\\xr_danger", [[return function()
		RAN.danger_init = true
	end]]))
	SendScriptCallback("idiots_on_start")
	check(RAN.surge_init and RAN.comp_init and RAN.danger_init, mode .. ": every idiots_on_start listener ran")
	for _, cb in ipairs({ "actor_on_first_update", "mcm_option_change", "npc_on_hit_callback", "idiots_on_state_change" }) do
		SendScriptCallback(cb)
	end
	local nested = { "surge_covers", "surge_mcm", "comp_hit", "comp_split", "comp_state" }
	local ran = {}
	for _, k in ipairs(nested) do if RAN[k] then ran[#ran + 1] = k end end
	if mode == "client" then
		check(#ran == 0, "client: the nested registrations stay host (ran: " .. table.concat(ran, ",") .. ")")
	else
		check(#ran == #nested, "host: the nested registrations run (ran: " .. table.concat(ran, ",") .. ")")
	end
end

-- The 15 old [callbacks_host] names are forced host: a view script (coop_*) does not run them on a client.
print("== route_shim_forced_callbacks")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("squad_on_update", from_script("coop_npc_world", "return function() RAN.squad = true end"))
	RegisterScriptCallback("save_state", from_script("coop_core_player", "return function() RAN.save = true end"))
	RegisterScriptCallback("load_state", from_script("treasure_manager", "return function() RAN.load = true end"))
	RegisterScriptCallback("on_key_press", from_script("ui_debug_launcher", "return function() RAN.debug = true end"))
	SendScriptCallback("squad_on_update")
	SendScriptCallback("save_state", {})
	SendScriptCallback("load_state", {})
	SendScriptCallback("on_key_press", 1)
	if mode == "client" then
		check(RAN.squad == nil and RAN.save == nil, "client: squad_on_update / save_state of coop_* are skipped (forced host)")
		check(RAN.load == true, "client: load_state of a host script runs (forced view)")
		check(RAN.debug == nil, "client: a debug tool (old [blocked] = host, not none) is skipped")
	else
		check(RAN.squad and RAN.save and RAN.load and RAN.debug, "host: all of them run")
	end
end

print("== route_shim_errors")
boot("client")
RegisterScriptCallback("actor_on_update", from_script("ui_inventory", "return function() RAN.err = true error('boom') end"))
RegisterScriptCallback("actor_on_update", from_script("actor_effects", "return function() RAN.after = true end"))
check(pcall(SendScriptCallback, "actor_on_update"), "client: a handler's Lua error does not leave the callback")
check(RAN.err and RAN.after, "client: the next handler still runs")
local _, _, view_errors = coop_native.counts("view")
check(view_errors == 1, "client: the error is counted")
boot("host")
RegisterScriptCallback("actor_on_update", from_script("ui_inventory", "return function() error('boom') end"))
check(not pcall(SendScriptCallback, "actor_on_update"), "host: a Lua error goes on as in single player (no pcall)")

print("== route_shim_none_functions")
boot("client")
local nf = coop.route.none_functions()
local set = {}
for _, v in ipairs(nf) do set[v] = true end
check(#nf == 10 and set["ui_debug_launcher.start_debug_main"] and set["ui_debug_item.start_artfact"],
	"the old [blocked_functions] list (" .. #nf .. " entries)")
check(#ROUTE_ERRORS == 0, "every coop_route*.ltx line parses (" .. table.concat(ROUTE_ERRORS, " | ") .. ")")
check(ROUTE_FILES[1] == "coop_route.ltx", "coop_route.ltx is read first")

-- Ruling F2-28: GAMMA scripts that call world functions and had no rule are host again
-- (configs\coop_route_gamma.ltx, generated by tools\gen_route_gamma.lua): before F2 T10 a script without a rule never
-- ran on a client, and until the call router (T12) such a script on a client could duplicate items.
print("== route_shim_gamma_world_scripts_host")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("actor_on_update", from_script("guards_spawner", "return function() RAN.spawner = true end"))
	RegisterScriptCallback("actor_on_update", from_script("squads_filler", "return function() RAN.filler = true end"))
	RegisterScriptCallback("actor_on_update", from_script("footstep_sounds", "return function() RAN.view = true end"))
	SendScriptCallback("actor_on_update")
	if mode == "client" then
		check(RAN.spawner == nil and RAN.filler == nil,
			"client: guards_spawner / squads_filler (coop_route_gamma.ltx) do not run")
		check(RAN.view == true, "client: footstep_sounds (explicit view, coop_route_mods.ltx) runs")
	else
		check(RAN.spawner and RAN.filler and RAN.view, "host: all three run")
	end
end
local gamma_read = false
for _, f in ipairs(ROUTE_FILES) do if f == "coop_route_gamma.ltx" then gamma_read = true end end
check(gamma_read, "coop_route_gamma.ltx is read like the other coop_route_*.ltx")

-- Ruling F2-29 (review I1): the stock scripts that call world functions (configs\coop_route_stock.ltx, generated by
-- tools\gen_route_world.lua) and the timers of a script without a rule run on the host only again, as before F2 T10.
-- bind_anomaly_zone.script:30-36 respawns artefacts on actor_on_first_update (alife_create_item :405): on a client
-- that was a request the host granted, a duplicate of its own respawn.
print("== route_shim_stock_world_and_timers_host")
for _, mode in ipairs({ "client", "host" }) do
	boot(mode)
	RegisterScriptCallback("actor_on_first_update",
		from_script("bind_anomaly_zone", "return function() RAN.zone = true end"))
	RegisterScriptCallback("actor_on_update", from_script("sim_board", "return function() RAN.board = true end"))
	CreateTimeEvent("x", "y", 1, from_script("some_unknown_mod", "return function() RAN.te = true return true end"))
	AddUniqueCall(from_script("some_unknown_mod", "return function() RAN.uc = true return false end"))
	SendScriptCallback("actor_on_first_update")
	SendScriptCallback("actor_on_update")
	TIMEEV[#TIMEEV].f()
	UNIQUE[#UNIQUE]()
	if mode == "client" then
		check(RAN.zone == nil and RAN.board == nil, "client: stock world scripts (bind_anomaly_zone, sim_board) do not run")
		check(RAN.te == nil and RAN.uc == nil, "client: a time event / unique call of a script without a rule does not run")
	else
		check(RAN.zone and RAN.board and RAN.te and RAN.uc, "host: all of them run")
	end
end
-- Our own scripts keep their timers on a client: every gamedata\scripts file that makes a unique call or a time event
-- has a rule that runs on a client (coop_* / modxml_* = view).
do
	local silent, seen = {}, 0
	local pipe = io.popen("dir /b /on gamedata" .. string.char(92) .. "scripts" .. string.char(92) .. "*.script 2>nul")
	for name in pipe:lines() do
		name = name:gsub("\r", "")
		local fh = io.open("gamedata/scripts/" .. name, "rb")
		local src = fh and fh:read("*a") or ""
		if fh then fh:close() end
		for kind, pat in pairs({ unique_call = "AddUniqueCall%s*%(", time_event = "CreateTimeEvent%s*%(" }) do
			if src:find(pat) then
				seen = seen + 1
				local d = coop.route.of(kind, from_script(name:gsub("%.script$", ""), "return function() end"))
				if not coop_native.runs_here(d, false) then silent[#silent + 1] = name .. ":" .. kind .. "=" .. d end
			end
		end
	end
	pipe:close()
	check(seen > 0 and #silent == 0, "client: none of our " .. seen .. " timer users goes silent (" .. table.concat(silent, ", ") .. ")")
end

-- Review M6: coop_route.script loaded a second time in the same Lua state (a script reload) installs over the first
-- one: a handler is still guarded once (one runs / note per call), unregisters, and nothing recurses.
print("== route_shim_reload")
boot("client")
local first = coop_route
load_script_file("coop_route")
check(coop_route ~= first and coop_route.install() == true, "the second load installs")
local hud = from_script("some_addon_hud", "return function() RAN.hud = (RAN.hud or 0) + 1 end")
RegisterScriptCallback("actor_on_update", hud)
local runs_before = ROUTE_CALLS.runs
local ok_send = pcall(SendScriptCallback, "actor_on_update")
check(ok_send and RAN.hud == 1, "after a reload a handler runs once, no stack overflow")
check(ROUTE_CALLS.runs - runs_before == 1, "and is guarded once (runs asked " .. (ROUTE_CALLS.runs - runs_before) .. "x)")
UnregisterScriptCallback("actor_on_update", hud)
check(axr_main.count("actor_on_update") == 0, "and unregisters")
local uc = from_script("some_addon_hud", "return function() RAN.uc_reload = (RAN.uc_reload or 0) + 1 return false end")
AddUniqueCall(uc)
runs_before = ROUTE_CALLS.runs
UNIQUE[#UNIQUE]()
check(RAN.uc_reload == nil and ROUTE_CALLS.runs - runs_before == 1,
	"a unique call after a reload is wrapped once (host by default on a client, F2-29)")
local n_uc = #UNIQUE
RemoveUniqueCall(uc)
check(#UNIQUE == n_uc - 1, "and RemoveUniqueCall finds it")

print("== route_shim_without_router")
boot("client", nil, true)
coop.route = nil
check(coop_route.install() == false, "an exe without coop.route: install says no")
local plain = from_script("treasure_manager", "return function() RAN.plain = true end")
RegisterScriptCallback("actor_on_update", plain)
check(coop_route.wrapper_of("actor_on_update", plain) == nil, "nothing is wrapped")
SendScriptCallback("actor_on_update")
check(RAN.plain == true, "the handler runs as in the stock game")

print("== route_shim_status")
boot("client")
RegisterScriptCallback("actor_on_update", from_script("treasure_manager", "return function() end"))
check(pcall(coop_route.print_status), "print_status runs")

print(string.format("%d passed, %d failed", PASSES, FAILS))
