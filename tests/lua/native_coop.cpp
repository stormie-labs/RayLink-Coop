// Anomaly Coop Lua test runner: native module `coop_native` built into runlua.exe, so the Lua stub tests use the same
// C++ tables as the engine instead of a Lua copy of them.
//   coop_native.route(callback, script)        -> "host" | "owner" | "view" | "none" | "level"   (coop_routes.h)
//   coop_native.add(section, {name = domain})  -> number of errors, {error text, ...}
//   coop_native.reset()                        -> drops every override added so far
//   coop_native.runs_here(domain, is_host)     -> boolean; an unknown domain name is an error
// F2 T10 (the router's pure half, for tests\lua\support\stubs.d\route.lua):
//   coop_native.script_key(source)             -> the script key of a lua_Debug source (routes::script_key)
//   coop_native.note(domain, outcome[, script[, callback]])  counts a call: outcome "ran" | "skipped" | "error"; an
//                                              unknown domain or outcome is an error (the engine ignores them; a test
//                                              wants to see them)
//   coop_native.counts(domain)                 -> ran, skipped, errors
//   coop_native.top_skipped(n)                 -> { {"callback@script", skips}, ... } most skipped first
//   coop_native.latest_new_skips(n)            -> { "callback@script", ... } the latest first-time skips first
//   coop_native.reset_counts()                 -> zeroes the counters
// Each Lua state gets its own route table and counters (a userdata upvalue freed by __gc).
// Kept Lua functions (coop_lua_fn.h, as coop_sync_api.cpp keeps coop.sync handlers, watches, effects and request callbacks):
//   coop_native.fn_keep(f)                     -> reference | nil (not a function)
//   coop_native.fn_call(ref, ...)              -> true, first result | false, fail kind, reason (luafn::reason), error
//                                                 kinds: "no_state" | "no_reference" | "stack_full" | "not_function" | "lua_error"
//   coop_native.fn_drop(ref), coop_native.fn_same(ref, f) -> boolean
// luabind's own registry references beside them, as the engine makes them for every luabind::object and functor (a model of
// 3rd party/luabind/luabind/src/ref.cpp ref / unref: free list in registry[1], count in sizes[registry] at registry[2]):
//   coop_native.lb_ref(v) -> reference, coop_native.lb_unref(ref), coop_native.lb_get(ref) -> what the registry slot holds
#include "lua.hpp"

#include "coop_routes.h"
#include "coop_lua_fn.h"

#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace
{
using coop::routes::Counters;
using coop::routes::Domain;
using coop::routes::Outcome;
using coop::routes::Override;
using coop::routes::Table;

struct NativeState
{
	Table table;
	Counters counters;
};

NativeState* state_of(lua_State* L) { return static_cast<NativeState*>(lua_touserdata(L, lua_upvalueindex(1))); }
Table* table_of(lua_State* L) { return &state_of(L)->table; }

int state_gc(lua_State* L)
{
	static_cast<NativeState*>(lua_touserdata(L, 1))->~NativeState();
	return 0;
}

// Argument errors (luaL_check*, luaL_error) are raised before any C++ object with a destructor is alive in the frame.

int l_route(lua_State* L)
{
	size_t cb_len = 0, sc_len = 0;
	const char* cb = luaL_checklstring(L, 1, &cb_len);
	const char* sc = luaL_optlstring(L, 2, "", &sc_len);
	const Domain d = table_of(L)->route(std::string_view(cb, cb_len), std::string_view(sc, sc_len));
	lua_pushstring(L, coop::routes::domain_name(d));
	return 1;
}

int l_add(lua_State* L)
{
	size_t sec_len = 0;
	const char* sec = luaL_checklstring(L, 1, &sec_len);
	luaL_checktype(L, 2, LUA_TTABLE);

	std::vector<std::string> errors;
	{
		std::vector<std::pair<std::string, std::string>> lines;
		lua_pushnil(L);
		while (lua_next(L, 2) != 0)
		{
			// lua_tolstring on a number key would turn it into a string and break lua_next: check the types first.
			if (lua_type(L, -2) == LUA_TSTRING && lua_type(L, -1) == LUA_TSTRING)
			{
				size_t klen = 0, vlen = 0;
				const char* k = lua_tolstring(L, -2, &klen);
				const char* v = lua_tolstring(L, -1, &vlen);
				lines.emplace_back(std::string(k, klen), std::string(v, vlen));
			}
			else
				errors.push_back(std::string(sec, sec_len) + ": entries must be name = \"domain\" strings");
			lua_pop(L, 1);
		}
		Table* t = table_of(L);
		for (const Override& o : coop::routes::parse_section(std::string_view(sec, sec_len), lines, &errors))
			t->add(o);
	}

	lua_pushinteger(L, static_cast<lua_Integer>(errors.size()));
	lua_createtable(L, static_cast<int>(errors.size()), 0);
	for (size_t i = 0; i < errors.size(); ++i)
	{
		lua_pushlstring(L, errors[i].data(), errors[i].size());
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 2;
}

int l_reset(lua_State* L)
{
	table_of(L)->clear();
	return 0;
}

Domain check_domain(lua_State* L, int idx, const char* fn)
{
	size_t len = 0;
	const char* name = luaL_checklstring(L, idx, &len);
	Domain d = Domain::Owner;
	if (!coop::routes::parse_domain(std::string_view(name, len), d))
		luaL_error(L, "coop_native.%s: unknown domain '%s'", fn, name);
	return d;
}

int l_runs_here(lua_State* L)
{
	const Domain d = check_domain(L, 1, "runs_here");
	const bool is_host = lua_toboolean(L, 2) != 0;
	lua_pushboolean(L, coop::routes::runs_here(d, is_host) ? 1 : 0);
	return 1;
}

int l_script_key(lua_State* L)
{
	size_t len = 0;
	const char* source = luaL_checklstring(L, 1, &len);
	const std::string key = coop::routes::script_key(std::string_view(source, len));
	lua_pushlstring(L, key.data(), key.size());
	return 1;
}

int l_note(lua_State* L)
{
	const Domain d = check_domain(L, 1, "note");
	size_t olen = 0, slen = 0, clen = 0;
	const char* outcome = luaL_checklstring(L, 2, &olen);
	const char* script = luaL_optlstring(L, 3, "", &slen);
	const char* callback = luaL_optlstring(L, 4, "", &clen);
	Outcome o = Outcome::Ran;
	if (!coop::routes::parse_outcome(std::string_view(outcome, olen), o))
		return luaL_error(L, "coop_native.note: unknown outcome '%s'", outcome);
	state_of(L)->counters.note(d, o, std::string_view(script, slen), std::string_view(callback, clen));
	return 0;
}

int l_counts(lua_State* L)
{
	const Domain d = check_domain(L, 1, "counts");
	const Counters::Totals& t = state_of(L)->counters.totals(d);
	lua_pushnumber(L, static_cast<lua_Number>(t.ran));
	lua_pushnumber(L, static_cast<lua_Number>(t.skipped));
	lua_pushnumber(L, static_cast<lua_Number>(t.errors));
	return 3;
}

int l_top_skipped(lua_State* L)
{
	const lua_Integer n = luaL_optinteger(L, 1, 10);
	const std::vector<std::pair<std::string, uint64_t>> top =
		state_of(L)->counters.top_skipped(n > 0 ? static_cast<size_t>(n) : 0);
	lua_createtable(L, static_cast<int>(top.size()), 0);
	for (size_t i = 0; i < top.size(); ++i)
	{
		lua_createtable(L, 2, 0);
		lua_pushlstring(L, top[i].first.data(), top[i].first.size());
		lua_rawseti(L, -2, 1);
		lua_pushnumber(L, static_cast<lua_Number>(top[i].second));
		lua_rawseti(L, -2, 2);
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

int l_latest_new_skips(lua_State* L)
{
	const lua_Integer n = luaL_optinteger(L, 1, 10);
	const std::vector<std::string> latest = state_of(L)->counters.latest_new_skips(n > 0 ? static_cast<size_t>(n) : 0);
	lua_createtable(L, static_cast<int>(latest.size()), 0);
	for (size_t i = 0; i < latest.size(); ++i)
	{
		lua_pushlstring(L, latest[i].data(), latest[i].size());
		lua_rawseti(L, -2, static_cast<int>(i + 1));
	}
	return 1;
}

int l_reset_counts(lua_State* L)
{
	state_of(L)->counters.clear();
	return 0;
}

// ---- kept functions (coop_lua_fn.h)

int l_fn_keep(lua_State* L)
{
	const int ref = coop::luafn::keep(L, 1);
	if (ref == LUA_NOREF)
		lua_pushnil(L);
	else
		lua_pushinteger(L, ref);
	return 1;
}

const char* fail_kind(coop::luafn::Fail f)
{
	using coop::luafn::Fail;
	switch (f)
	{
	case Fail::None: return "none";
	case Fail::NoState: return "no_state";
	case Fail::NoReference: return "no_reference";
	case Fail::StackFull: return "stack_full";
	case Fail::NotFunction: return "not_function";
	case Fail::LuaError: return "lua_error";
	}
	return "?";
}

int l_fn_call(lua_State* L)
{
	const int ref = static_cast<int>(luaL_checkinteger(L, 1));
	const int nargs = lua_gettop(L) - 1;
	lua_pushnil(L); // the first result goes here
	const int slot = lua_gettop(L);
	std::string error;
	const coop::luafn::Fail f = coop::luafn::call(
	    L, ref, nullptr,
	    [&](lua_State* S) {
		    for (int i = 0; i < nargs; ++i)
			    lua_pushvalue(S, 2 + i);
		    return nargs;
	    },
	    1, [&](lua_State* S) { lua_replace(S, slot); }, error);
	if (f == coop::luafn::Fail::None)
	{
		lua_pushboolean(L, 1);
		lua_pushvalue(L, slot);
		return 2;
	}
	const std::string why = coop::luafn::reason(f, error);
	lua_pushboolean(L, 0);
	lua_pushstring(L, fail_kind(f));
	lua_pushlstring(L, why.data(), why.size());
	lua_pushlstring(L, error.data(), error.size());
	return 4;
}

int l_fn_drop(lua_State* L)
{
	coop::luafn::drop(L, static_cast<int>(luaL_checkinteger(L, 1)));
	return 0;
}

int l_fn_same(lua_State* L)
{
	lua_pushboolean(L, coop::luafn::same(L, static_cast<int>(luaL_checkinteger(L, 1)), 2) ? 1 : 0);
	return 1;
}

// ---- luabind's registry references (a model of 3rd party/luabind/luabind/src/ref.cpp, the engine's luabind)

constexpr int kLbFreeList = 1; // registry[1]: luabind's first free slot
constexpr int kLbSizes = 2; // registry[2]: a weak-keyed table, sizes[registry] = luabind's count of slots

// luabind's count of the registry's slots: registry.n, else sizes[registry], else the slots from 1 up to the first nil
int lb_count(lua_State* L)
{
	lua_getfield(L, LUA_REGISTRYINDEX, "n");
	if (lua_isnumber(L, -1))
	{
		const int n = static_cast<int>(lua_tonumber(L, -1));
		lua_pop(L, 1);
		if (n >= 0)
			return n;
	}
	else
		lua_pop(L, 1);
	lua_rawgeti(L, LUA_REGISTRYINDEX, kLbSizes);
	if (lua_isnil(L, -1))
	{
		lua_pop(L, 1);
		lua_newtable(L);
		lua_pushvalue(L, -1);
		lua_setmetatable(L, -2);
		lua_pushstring(L, "k");
		lua_setfield(L, -2, "__mode");
		lua_pushvalue(L, -1);
		lua_rawseti(L, LUA_REGISTRYINDEX, kLbSizes);
	}
	lua_pushvalue(L, LUA_REGISTRYINDEX);
	lua_rawget(L, -2);
	const bool known = lua_isnumber(L, -1) != 0;
	const int n = known ? static_cast<int>(lua_tonumber(L, -1)) : -1;
	lua_pop(L, 2);
	if (known && n >= 0)
		return n;
	int i = 1;
	for (;; ++i)
	{
		lua_rawgeti(L, LUA_REGISTRYINDEX, i);
		const bool nil = lua_isnil(L, -1) != 0;
		lua_pop(L, 1);
		if (nil)
			break;
	}
	return i - 1;
}

void lb_set_count(lua_State* L, int n)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, kLbSizes); // made by lb_count
	lua_pushvalue(L, LUA_REGISTRYINDEX);
	lua_pushnumber(L, n);
	lua_rawset(L, -3);
	lua_pop(L, 1);
}

int l_lb_ref(lua_State* L)
{
	luaL_checkany(L, 1);
	lua_settop(L, 1);
	lua_rawgeti(L, LUA_REGISTRYINDEX, kLbFreeList);
	int ref = static_cast<int>(lua_tonumber(L, -1));
	lua_pop(L, 1);
	if (ref != 0)
	{
		lua_rawgeti(L, LUA_REGISTRYINDEX, ref); // the next free one
		lua_rawseti(L, LUA_REGISTRYINDEX, kLbFreeList);
	}
	else
	{
		ref = lb_count(L);
		if (ref < 2)
			ref = 2; // registry[1] and [2] are luabind's own
		++ref;
		lb_set_count(L, ref);
	}
	lua_rawseti(L, LUA_REGISTRYINDEX, ref); // the value
	lua_pushinteger(L, ref);
	return 1;
}

int l_lb_unref(lua_State* L)
{
	const int ref = static_cast<int>(luaL_checkinteger(L, 1));
	if (ref >= 0)
	{
		lua_rawgeti(L, LUA_REGISTRYINDEX, kLbFreeList);
		lua_rawseti(L, LUA_REGISTRYINDEX, ref);
		lua_pushnumber(L, ref);
		lua_rawseti(L, LUA_REGISTRYINDEX, kLbFreeList);
	}
	return 0;
}

int l_lb_get(lua_State* L)
{
	lua_rawgeti(L, LUA_REGISTRYINDEX, static_cast<int>(luaL_checkinteger(L, 1)));
	return 1;
}
} // namespace

extern "C" int luaopen_coop_native(lua_State* L)
{
	static const luaL_Reg kFunctions[] = {
		{"route", l_route},
		{"add", l_add},
		{"reset", l_reset},
		{"runs_here", l_runs_here},
		{"script_key", l_script_key},
		{"note", l_note},
		{"counts", l_counts},
		{"top_skipped", l_top_skipped},
		{"latest_new_skips", l_latest_new_skips},
		{"reset_counts", l_reset_counts},
		{"fn_keep", l_fn_keep},
		{"fn_call", l_fn_call},
		{"fn_drop", l_fn_drop},
		{"fn_same", l_fn_same},
		{"lb_ref", l_lb_ref},
		{"lb_unref", l_lb_unref},
		{"lb_get", l_lb_get},
	};

	lua_newtable(L); // the module table
	void* mem = lua_newuserdata(L, sizeof(NativeState));
	new (mem) NativeState();
	lua_newtable(L); // its metatable
	lua_pushcfunction(L, state_gc);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	// stack: module, state userdata
	for (const luaL_Reg& f : kFunctions)
	{
		lua_pushvalue(L, -1);
		lua_pushcclosure(L, f.func, 1);
		lua_setfield(L, -3, f.name);
	}
	lua_pop(L, 1); // the userdata lives on as an upvalue
	lua_pushvalue(L, -1);
	lua_setglobal(L, "coop_native");
	return 1;
}
