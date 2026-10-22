// Anomaly Coop Lua test runner: native module `coop_native` built into runlua.exe, so the Lua stub tests use the same
// C++ tables as the engine instead of a Lua copy of them.
//   coop_native.route(callback, script)        -> "host" | "owner" | "view" | "none" | "level"   (coop_routes.h)
//   coop_native.add(section, {name = domain})  -> number of errors, {error text, ...}
//   coop_native.reset()                        -> drops every override added so far
//   coop_native.runs_here(domain, is_host)     -> boolean; an unknown domain name is an error
// Each Lua state gets its own route table (a userdata upvalue freed by __gc).
#include "lua.hpp"

#include "coop_routes.h"

#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace
{
using coop::routes::Domain;
using coop::routes::Override;
using coop::routes::Table;

Table* table_of(lua_State* L) { return static_cast<Table*>(lua_touserdata(L, lua_upvalueindex(1))); }

int table_gc(lua_State* L)
{
	static_cast<Table*>(lua_touserdata(L, 1))->~Table();
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

int l_runs_here(lua_State* L)
{
	size_t len = 0;
	const char* name = luaL_checklstring(L, 1, &len);
	const bool is_host = lua_toboolean(L, 2) != 0;
	Domain d = Domain::Owner;
	if (!coop::routes::parse_domain(std::string_view(name, len), d))
		return luaL_error(L, "coop_native.runs_here: unknown domain '%s'", name);
	lua_pushboolean(L, coop::routes::runs_here(d, is_host) ? 1 : 0);
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
	};

	lua_newtable(L); // the module table
	void* mem = lua_newuserdata(L, sizeof(Table));
	new (mem) Table();
	lua_newtable(L); // its metatable
	lua_pushcfunction(L, table_gc);
	lua_setfield(L, -2, "__gc");
	lua_setmetatable(L, -2);
	// stack: module, table userdata
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
