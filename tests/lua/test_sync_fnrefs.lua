-- Anomaly Coop: Lua functions the engine keeps (engine/src/xrCoop/coop_lua_fn.h: coop.sync handlers, on_change watches, effects,
-- request callbacks; coop_sync_api.cpp) on the engine's own LuaJIT, through the runner's module coop_native
-- (tests/lua/native_coop.cpp), beside luabind's own registry references (3rd party/luabind/luabind/src/ref.cpp), which the
-- engine makes and lets go all the time (every luabind::object and functor made from Lua).
-- 2026-11-07, live: the F7 debug window answered "handler error" for god, ammo, invis and test_squad with no Lua error in the log:
-- the handlers coop.dbg.self and coop.dbg.spawn had been kept with luaL_ref(L, LUA_REGISTRYINDEX), and luabind's references hand
-- out the same registry slots (their own free list and count), so a luabind object took a handler's slot and its call found no
-- function. Run: tools\test_lua.cmd sync_fnrefs
local PASSES, FAILS = 0, 0

local function check(name, cond, extra)
	if cond then
		PASSES = PASSES + 1
	else
		FAILS = FAILS + 1
		print("  FAIL " .. name .. (extra and (": " .. tostring(extra)) or ""))
	end
end

local N = coop_native
if type(N) ~= "table" or type(N.fn_keep) ~= "function" or type(N.lb_ref) ~= "function" then
	print("  FAIL coop_native.fn_* / lb_* missing: temp\\lua\\runlua.exe predates tests\\lua\\native_coop.cpp, rebuild it with "
		.. "set LUA_REBUILD=1 & tools\\test_lua.cmd")
	print(string.format("%d passed, %d failed", PASSES, FAILS + 1))
	return
end

-- the five coop.dbg.* handlers of coop_debug_server.install_handlers, kept as the engine keeps them
local function keep_handlers(n)
	local refs = {}
	for i = 1, n do
		local tag = "handler " .. i
		refs[i] = N.fn_keep(function(peer, args) return true, tag end)
	end
	return refs
end

local function all_call(refs, label)
	local broken = {}
	for i, ref in ipairs(refs) do
		local ok, v, why = N.fn_call(ref, 0, {})
		if not (ok and v == true) then broken[#broken + 1] = string.format("#%d %s", i, tostring(why or v)) end
	end
	check(label, #broken == 0, table.concat(broken, "; "))
end

-- luabind at work: objects made and let go, a few more made than let go each round (live callbacks, binders, ini iterators)
local function luabind_churn(live, rounds, made, freed)
	for r = 1, rounds do
		for k = 1, made do live[#live + 1] = { ref = N.lb_ref({ r, k }), r = r, k = k } end
		for _ = 1, freed do
			local o = table.remove(live, 1)
			if o then N.lb_unref(o.ref) end
		end
	end
end

local function luabind_intact(live, label)
	local bad = 0
	for _, o in ipairs(live) do
		local v = N.lb_get(o.ref)
		if not (type(v) == "table" and v[1] == o.r and v[2] == o.k) then bad = bad + 1 end
	end
	check(label, bad == 0, bad .. " luabind object(s) overwritten")
end

---------------------------------------------------------------- the live case: handlers kept at the game's start, luabind runs on
do
	local live = {}
	luabind_churn(live, 3, 4, 2) -- the engine's start: luabind made objects before the scripts' on_game_start
	local refs = keep_handlers(5)
	luabind_churn(live, 40, 6, 4) -- a session: luabind makes and lets go
	all_call(refs, "handlers kept before luabind's traffic still answer")
	luabind_intact(live, "luabind's objects untouched by the kept handlers")
end

---------------------------------------------------------------- luabind let one go first (a hole in the registry), then handlers
do
	local live = {}
	luabind_churn(live, 1, 3, 0)
	N.lb_unref(table.remove(live, 1).ref) -- luabind's first free slot: the registry gets a nil there
	local refs = keep_handlers(3)
	luabind_churn(live, 10, 3, 1)
	all_call(refs, "handlers kept after luabind freed a slot still answer")
	luabind_intact(live, "luabind's objects untouched (freed slot case)")
end

---------------------------------------------------------------- request callbacks: kept and let go per request, luabind beside them
do
	local live = {}
	local handler = keep_handlers(1)
	for i = 1, 60 do
		local cb = N.fn_keep(function(ok, result) return result end)
		live[#live + 1] = { ref = N.lb_ref({ i, 0 }), r = i, k = 0 }
		local ok, v = N.fn_call(cb, true, "answer " .. i)
		check("request callback " .. i .. " called", ok and v == "answer " .. i, v)
		N.fn_drop(cb)
		if i % 3 == 0 then N.lb_unref(table.remove(live, 1).ref) end
	end
	all_call(handler, "a handler survives 60 callbacks kept and let go")
	luabind_intact(live, "luabind's objects untouched by callbacks let go")
end

---------------------------------------------------------------- same() and drop()
do
	local f, g = function() end, function() end
	local ref = N.fn_keep(f)
	check("keep gives a reference", type(ref) == "number")
	check("same: the kept function", N.fn_same(ref, f) == true)
	check("same: another function", N.fn_same(ref, g) == false)
	check("keep refuses a non-function", N.fn_keep(42) == nil)
	N.fn_drop(ref)
	local ok, kind, why = N.fn_call(ref)
	check("a dropped reference: not called", ok == false and kind == "not_function", kind)
	check("a dropped reference says what it holds", type(why) == "string" and why:find("^not a function %(") ~= nil, why)
end

---------------------------------------------------------------- the reasons an answer carries ("handler error: <reason>")
do
	local ok, kind, why = N.fn_call(-2) -- LUA_NOREF
	check("no reference: kind", ok == false and kind == "no_reference", kind)
	check("no reference: reason", why == "no function kept", why)

	local ref = N.fn_keep(function() error("C:\\games\\gamedata\\scripts\\coop_x.script:12: attempt to index a nil value\nstack traceback:\n\tsomewhere", 0) end)
	ok, kind, why = N.fn_call(ref)
	check("lua error: kind", ok == false and kind == "lua_error", kind)
	check("lua error: the first line without folders", why == "coop_x.script:12: attempt to index a nil value", why)

	ref = N.fn_keep(function() error("a plain message") end)
	ok, kind, why = N.fn_call(ref)
	check("lua error with a chunk name: no folders", ok == false and why:find("attempt", 1, true) == nil and why:find("a plain message", 1, true) ~= nil
		and why:find("[\\/]") == nil, why)

	ref = N.fn_keep(function() error(string.rep("x", 400), 0) end)
	ok, kind, why = N.fn_call(ref)
	check("a long error is cut", ok == false and #why <= 160 and why:sub(-3) == "...", #why)

	ref = N.fn_keep(function() error({}) end)
	ok, kind, why = N.fn_call(ref)
	check("an error that is no string", ok == false and kind == "lua_error" and why == "(error object is not a string)", why)

	ref = N.fn_keep(function(a, b) return a + b end)
	ok, why = N.fn_call(ref, 2, 3)
	check("a call passes its arguments and gives the first result", ok == true and why == 5, why)
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
