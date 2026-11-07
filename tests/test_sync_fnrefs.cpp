// Anomaly Coop unit tests: the Lua functions the engine keeps (coop.sync handlers, on_change watches, effects, request callbacks).
// 2026-11-07, live: the F7 debug window answered "handler error" for god, ammo, invis and test_squad, with no Lua error in the log.
// coop_sync_api.cpp kept the handlers with luaL_ref(L, LUA_REGISTRYINDEX); luabind (3rd party/luabind/luabind/src/ref.cpp) hands
// out the registry's integer slots with its own free list and count, so a luabind object took the handlers' slots and their calls
// found a table (pcall_ref returned false without a word). The behaviour is tested on the engine's LuaJIT beside a model of luabind's
// references (tests/lua/test_sync_fnrefs.lua over xrCoop/coop_lua_fn.h); this file reads the engine's sources: no coop code keeps a
// Lua value in the registry's integer slots, coop_sync_api.cpp keeps and calls through coop_lua_fn.h, and a handler that does not
// run answers "handler error: <why>".
#include "test_util.h"

#include <cctype>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace
{
// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string engine_src_dir()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

// The source with // and /* */ comments blanked; string literals kept.
std::string strip_comments(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str
	} st = St::Code;
	for (size_t i = 0; i < out.size(); ++i)
	{
		const char c = out[i];
		const char n = i + 1 < out.size() ? out[i + 1] : '\0';
		switch (st)
		{
		case St::Code:
			if (c == '/' && n == '/')
			{
				st = St::Line;
				out[i] = ' ';
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = ' ';
				out[++i] = ' ';
			}
			else if (c == '"')
				st = St::Str;
			break;
		case St::Line:
			if (c == '\n')
				st = St::Code;
			else
				out[i] = ' ';
			break;
		case St::Block:
			if (c == '*' && n == '/')
			{
				out[i] = ' ';
				out[++i] = ' ';
				st = St::Code;
			}
			else if (c != '\n')
				out[i] = ' ';
			break;
		case St::Str:
			if (c == '\\')
				++i;
			else if (c == '"')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string read_code(const std::filesystem::path& p)
{
	std::ifstream in(p, std::ios::binary);
	if (!in)
		return std::string();
	std::stringstream ss;
	ss << in.rdbuf();
	return strip_comments(ss.str());
}

// The calls of `fn` ("luaL_ref(") whose arguments name LUA_REGISTRYINDEX.
size_t registry_calls(const std::string& code, const std::string& fn)
{
	size_t n = 0;
	for (size_t at = code.find(fn); at != std::string::npos; at = code.find(fn, at + fn.size()))
	{
		if (at > 0 && (std::isalnum(static_cast<unsigned char>(code[at - 1])) || code[at - 1] == '_'))
			continue; // another name ending so
		const size_t close = code.find(')', at);
		if (close != std::string::npos && code.substr(at, close - at).find("LUA_REGISTRYINDEX") != std::string::npos)
			++n;
	}
	return n;
}

// Lua values kept in, read from or let go of the registry's integer slots, the ones luabind's references use.
size_t registry_slot_uses(const std::string& code)
{
	return registry_calls(code, "luaL_ref(") + registry_calls(code, "luaL_unref(") + registry_calls(code, "lua_rawgeti(") +
	    registry_calls(code, "lua_rawseti(");
}

// The body of the first function whose definition starts with `head`: from its '{' to the matching '}'.
std::string body_of(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t open = code.find('{', at);
	if (open == std::string::npos)
		return std::string();
	int depth = 0;
	for (size_t i = open; i < code.size(); ++i)
	{
		if (code[i] == '{')
			++depth;
		else if (code[i] == '}' && --depth == 0)
			return code.substr(open, i - open + 1);
	}
	return std::string();
}
} // namespace

TEST(sync_fnrefs_the_check_finds_the_old_registry_references)
{
	// coop_sync_api.cpp before the fix: arg_function, same_function, unref and pcall_ref
	const std::string old_code = "ref = luaL_ref(L, LUA_REGISTRYINDEX);\n"
	                             "lua_rawgeti(L, LUA_REGISTRYINDEX, ref);\n"
	                             "luaL_unref(L, LUA_REGISTRYINDEX, ref);\n"
	                             "lua_rawgeti(L, LUA_REGISTRYINDEX, ref);\n";
	CHECK_EQ(registry_slot_uses(strip_comments(old_code)), size_t(4));
	// the store of coop_lua_fn.h: a table of its own under a string key
	const std::string new_code = "lua_rawget(L, LUA_REGISTRYINDEX);\nluaL_ref(L, store);\nlua_rawgeti(L, store, ref);\n"
	                             "luaL_unref(L, store, ref);\n// luaL_ref(L, LUA_REGISTRYINDEX) in a comment\n";
	CHECK_EQ(registry_slot_uses(strip_comments(new_code)), size_t(0));
}

TEST(sync_fnrefs_no_coop_source_keeps_lua_values_in_the_registry_slots)
{
	namespace fs = std::filesystem;
	const fs::path dir = fs::path(engine_src_dir()) / "xrGame" / "coop";
	REQUIRE(fs::is_directory(dir));
	size_t files = 0;
	for (const auto& e : fs::directory_iterator(dir))
	{
		const std::string ext = e.path().extension().string();
		if (ext != ".cpp" && ext != ".h")
			continue;
		++files;
		const size_t uses = registry_slot_uses(read_code(e.path()));
		if (uses != 0)
			t::report_failure(__FILE__, __LINE__, e.path().filename().string() + ": " + std::to_string(uses) +
			        " Lua value(s) kept in the registry's integer slots (luabind hands them out too): keep them through "
			        "xrCoop/coop_lua_fn.h");
	}
	CHECK(files > 20);
	const std::string header = read_code(fs::path(engine_src_dir()) / "xrCoop" / "coop_lua_fn.h");
	REQUIRE(!header.empty());
	CHECK_EQ(registry_slot_uses(header), size_t(0));
	CHECK(header.find("luaL_ref(L, store)") != std::string::npos);
}

TEST(sync_fnrefs_coop_sync_keeps_and_calls_through_coop_lua_fn)
{
	const std::string code = read_code(std::filesystem::path(engine_src_dir()) / "xrGame" / "coop" / "coop_sync_api.cpp");
	REQUIRE(!code.empty());
	CHECK(code.find("#include \"xrCoop/coop_lua_fn.h\"") != std::string::npos);
	CHECK(body_of(code, "bool arg_function(").find("luafn::keep(") != std::string::npos);
	CHECK(body_of(code, "bool same_function(").find("luafn::same(") != std::string::npos);
	CHECK(body_of(code, "void unref(").find("luafn::drop(") != std::string::npos);
	const std::string pcall = body_of(code, "bool pcall_ref(");
	CHECK(pcall.find("luafn::call(") != std::string::npos);
	// every kind of failure is logged (a Lua error with its traceback; a call not made with why), none silently
	CHECK(pcall.find("lua error in coop.sync") != std::string::npos);
	CHECK(pcall.find("not called") != std::string::npos);
	CHECK(pcall.find("log_allowed(") != std::string::npos);
	CHECK(pcall.find("return false") == pcall.rfind("return false")); // one way out on failure, after the log
}

TEST(sync_fnrefs_a_handler_that_does_not_run_says_why)
{
	const std::string code = read_code(std::filesystem::path(engine_src_dir()) / "xrGame" / "coop" / "coop_sync_api.cpp");
	const std::string run = body_of(code, "void run_host_calls(");
	REQUIRE(!run.empty());
	CHECK(run.find("\"handler error: \"") != std::string::npos); // "handler error: <first line of the Lua error | why not called>"
	CHECK(run.find("&not_run") != std::string::npos);
}
