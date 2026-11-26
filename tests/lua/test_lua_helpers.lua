-- Anomaly Coop: how C++ calls Lua and registers the coop.* API, on the engine's own LuaJIT through the runner's module coop_native
-- (tests/lua/native_coop.cpp):
--   engine/src/xrCoop/coop_lua_fn.h     luafn::call_named (<module>.<fn> by name, protected) and luafn::traceback;
--   engine/src/xrGame/coop/coop_lua.h   fill / fill_global, the argument readers, the field setters.
-- The readers are checked against the copies they replace in xrGame/coop (written out below as they read there), value by value,
-- so a module that moves to a reader answers its callers as before. Run: tools\test_lua.cmd lua_helpers
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
if type(N) ~= "table" or type(N.fn_call_named) ~= "function" or type(N.arg) ~= "function" then
	print("  FAIL coop_native.fn_call_named / arg missing: temp\\lua\\runlua.exe predates tests\\lua\\native_coop.cpp, rebuild it "
		.. "with set LUA_REBUILD=1 & tools\\test_lua.cmd")
	print(string.format("%d passed, %d failed", PASSES, FAILS + 1))
	return
end

-- ---------------------------------------------------------------- call_named

coop_test_mod = {
	add = function(a, b) return a + b end,
	boom = function() error("kaboom") end,
	text = "not a function",
}

do
	local top = select("#", N.fn_call_named("coop_test_mod", "add", 2, 3))
	local ok, v = N.fn_call_named("coop_test_mod", "add", 2, 3)
	check("named call runs and returns its first result", ok == true and v == 5, tostring(v))
	check("named call answers two values on success", top == 2, top)
end

do
	local ok, kind, why, err = N.fn_call_named("coop_test_mod", "boom")
	check("a raising function is a lua_error", ok == false and kind == "lua_error", kind)
	check("the error carries its message", type(err) == "string" and err:find("kaboom", 1, true) ~= nil, err)
	check("traceback is the handler", type(err) == "string" and err:find("stack traceback", 1, true) ~= nil, err)
	check("the reason is the first line", type(why) == "string" and not why:find("\n", 1, true)
		and why:find("kaboom", 1, true) ~= nil, why)
end

do
	local ok, kind, why, err = N.fn_call_named("coop_no_such_module", "fn")
	check("no module: missing", ok == false and kind == "missing", kind)
	check("no module: what was found", err == "coop_no_such_module: nil", err)
	check("no module: reason", why == "missing (coop_no_such_module: nil)", why)
	ok, kind, why, err = N.fn_call_named("coop_test_mod", "nothing")
	check("no function: missing", ok == false and kind == "missing" and err == "coop_test_mod.nothing: nil", err)
	ok, kind, why, err = N.fn_call_named("coop_test_mod", "text")
	check("not a function: missing", ok == false and kind == "missing" and err == "coop_test_mod.text: string", err)
end

do
	-- a module whose loading raises (as _G.__index loading a broken script does): the lookup is protected
	local mt = getmetatable(_G)
	setmetatable(_G, { __index = function(_, k)
		if k == "coop_broken_module" then error("syntax error in coop_broken_module.script") end
		return nil
	end })
	local ok, kind, _, err = N.fn_call_named("coop_broken_module", "fn")
	setmetatable(_G, mt)
	check("a module that raises while it loads is a lua_error", ok == false and kind == "lua_error", kind)
	check("its error is kept", type(err) == "string" and err:find("syntax error", 1, true) ~= nil, err)
end

do
	-- the stack is left as it was, call after call
	for i = 1, 200 do
		N.fn_call_named("coop_test_mod", "add", i, 1)
		N.fn_call_named("coop_test_mod", "boom")
		N.fn_call_named("coop_none", "x")
	end
	local ok, v = N.fn_call_named("coop_test_mod", "add", 40, 2)
	check("no stack left behind", ok == true and v == 42, v)
end

-- ---------------------------------------------------------------- fill / fill_global

do
	local saved = coop
	coop = nil
	check("fill without coop answers false", N.fill("t") == false)
	check("fill without coop makes nothing", coop == nil)
	coop = { route = { keep = 7 } }
	check("fill on coop itself", N.fill(nil) == true and coop.one() == 1 and coop.two() == 2)
	check("fill makes coop.<name>", N.fill("fresh") == true and type(coop.fresh) == "table" and coop.fresh.two() == 2)
	check("fill keeps a table that is there", N.fill("route") == true and coop.route.keep == 7 and coop.route.one() == 1)
	coop.plain = 5
	check("fill replaces a field that is no table", N.fill("plain") == true and type(coop.plain) == "table")
	N.fill_global("coop_test_srv")
	check("fill_global makes the global table", type(coop_test_srv) == "table" and coop_test_srv.one() == 1)
	coop_test_srv.keep = true
	N.fill_global("coop_test_srv")
	check("fill_global keeps the table that is there", coop_test_srv.keep == true and coop_test_srv.two() == 2)
	coop = saved
	coop_test_srv = nil
end

-- ---------------------------------------------------------------- argument readers against the old copies

local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end
local function floor_eq(v) return v == math.floor(v) end

-- coop_levels.cpp arg_whole(max) / coop_checkpoints_lua.cpp arg_character / coop_rest.cpp arg_id / coop_debug.cpp arg_peer
local function old_whole(v, max)
	if type(v) ~= "number" then return false end
	if not finite(v) or v < 0 or v > max or not floor_eq(v) then return false end
	return true, v
end
-- coop_objects.cpp lua_whole(lo, hi)
local function old_lua_whole(v, lo, hi)
	if type(v) ~= "number" then return false end
	if not (v >= lo and v <= hi) or not floor_eq(v) then return false end
	return true, v
end
-- coop_sync_api.cpp arg_whole(lo, hi)
local function old_sync_whole(v, lo, hi)
	if type(v) ~= "number" or not finite(v) then return false end
	if not (floor_eq(v) and v >= lo and v <= hi) then return false end
	return true, v
end
-- srv/coop_srv_script.cpp id_arg: 0xffff for "no"
local function old_id_arg(v)
	if type(v) ~= "number" then return false end
	if v >= 0 and v < 0xffff and floor_eq(v) then return true, v end
	return false
end
-- srv/coop_srv_script.cpp u32_arg
local function old_u32_arg(v)
	if type(v) ~= "number" then return false end
	if not (v >= 0 and v <= 0xffffffff) or not floor_eq(v) then return false end
	return true, v
end
-- coop_money.cpp arg_int(lo, hi)
local function trunc(v) if v < 0 then return math.ceil(v) end return math.floor(v) end
local function old_arg_int(v, lo, hi)
	if type(v) ~= "number" or not finite(v) then return false end
	local w = trunc(v)
	if w < lo or w > hi then return false end
	return true, w
end
-- coop_script.cpp arg_id: any number 0 .. 0xffffffff, fractions kept
local function old_arg_id(v)
	if type(v) ~= "number" then return false end
	if v >= 0 and v <= 0xffffffff then return true, v end
	return false
end

local VALUES = { 0, 1, 2, 1.5, -1, -0.5, 0.25, 7, 15, 16, 17, 255, 256, 0xfffe, 0xffff, 0x10000, 1e6, 0xfffffffe, 0xffffffff,
	0x100000000, 1e300, -1e300, math.huge, -math.huge, 0 / 0, -2.5, 2.5, 99.999, "5", "x", true, {}, }

local function same(label, v, ok, out, ref_ok, ref_out)
	local good = (ok == ref_ok) and (not ok or out == ref_out)
	check(label .. " " .. tostring(v), good, string.format("got %s %s, old %s %s", tostring(ok), tostring(out), tostring(ref_ok),
		tostring(ref_out)))
end

for _, v in ipairs(VALUES) do
	for _, max in ipairs({ 0xfffe, 0xffffffff, 16, 0 }) do
		local ok, out = N.arg("whole_u32", v, 0, max)
		same("whole_u32 0.." .. max, v, ok, out, old_whole(v, max))
	end
	local ok, out = N.arg("object_id", v)
	same("object_id = arg_character / arg_id(rest) / id_arg", v, ok, out, old_whole(v, 0xfffe))
	same("object_id = srv id_arg", v, ok, out, old_id_arg(v))
	ok, out = N.arg("whole_u32", v, 0, 0xffffffff)
	same("whole_u32 = srv u32_arg", v, ok, out, old_u32_arg(v))
	for _, r in ipairs({ { 0, 100 }, { -5, 5 }, { 1, 0xfffe } }) do
		ok, out = N.arg("whole", v, r[1], r[2])
		same("whole = objects lua_whole", v, ok, out, old_lua_whole(v, r[1], r[2]))
		same("whole = sync_api arg_whole", v, ok, out, old_sync_whole(v, r[1], r[2]))
	end
	for _, r in ipairs({ { 0, 16 }, { -1e9, 1e9 }, { 0, 0xfffffffe } }) do
		ok, out = N.arg("trunc", v, r[1], r[2])
		same("trunc = money arg_int", v, ok, out, old_arg_int(v, r[1], r[2]))
	end
	ok, out = N.arg("number_in", v, 0, 0xffffffff)
	same("number_in = script arg_id", v, ok, out, old_arg_id(v))
	ok, out = N.arg("number", v)
	same("number", v, ok, out, type(v) == "number" and finite(v), type(v) == "number" and v or nil)
end

-- ---------------------------------------------------------------- field setters

do
	local t = N.fields()
	check("set_bool", t.yes == true)
	check("set_num", t.n == 1.5)
	check("set_str", t.s == "text")
	check("set_str of null is empty", t.null == "")
	check("set_str keeps every byte", t.z == "a\0b" and #t.z == 3, #tostring(t.z))
end

print(string.format("%d passed, %d failed", PASSES, FAILS))
