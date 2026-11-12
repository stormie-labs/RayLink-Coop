// Anomaly Coop unit tests: Lua errors survived in a co-op session (xrCoop/coop_lua_errors.h; glue in
// xrGame/coop/coop_lua_errors.cpp, the errfunc CScriptEngine::lua_pcall_failed, luabind's call proxies).
// Live 2026-11 (G.A.M.M.A.): a Lua error in any engine->Lua call (a UI functor, a dialog precondition, a callback, a binder)
// went to Debug.fatal and ended the session for that player; each report got its own Lua guard, the next mod failed elsewhere.
// In a session (console coop_lua_errors 1, the default) the error is logged with its stack once per place, repeats only as a
// counter (one line per place per 60 s at most), and the call returns a safe value.
// The bookkeeping is tested here; the luabind templates and the engine glue are checked by reading their sources (the unit-test
// exe links neither luabind nor LuaJIT).
#include "test_util.h"

#include "coop_lua_errors.h"

#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

using namespace coop;
using lua_errors::Ledger;
using lua_errors::Log;

namespace
{
bool contains(const std::string& s, const std::string& part)
{
	const bool ok = s.find(part) != std::string::npos;
	if (!ok)
		std::printf("    line: %s\n    want: %s\n", s.c_str(), part.c_str());
	return ok;
}
} // namespace

TEST(lua_errors_survive_only_in_a_session_with_the_switch_on)
{
	CHECK(lua_errors::survive(true, 1));
	CHECK(!lua_errors::survive(true, 0));
	CHECK(!lua_errors::survive(false, 1));
	CHECK(!lua_errors::survive(false, 0));
}

TEST(lua_errors_place_is_the_script_file_and_line)
{
	CHECK_EQ(lua_errors::place_key("...\\gamedata\\scripts\\ui_options.script", 912), std::string("ui_options.script:912"));
	CHECK_EQ(lua_errors::place_key("gamedata/scripts/_g_patches.script", 817), std::string("_g_patches.script:817"));
	CHECK_EQ(lua_errors::place_key("tasks_guide.script", 447), std::string("tasks_guide.script:447"));
	CHECK_EQ(lua_errors::place_key(nullptr, 3), std::string(lua_errors::kNoLuaFrame));
	CHECK_EQ(lua_errors::place_key("", 3), std::string(lua_errors::kNoLuaFrame));
}

TEST(lua_errors_first_error_of_a_place_is_logged_in_full)
{
	Ledger l;
	const auto a = l.note("ui_options.script:912", 1000);
	CHECK(a.log == Log::Full);
	CHECK_EQ(a.number, uint64_t(1));
	CHECK_EQ(a.place, std::string("ui_options.script:912"));
	const auto b = l.note("ssfx_weapons_dof.script:269", 1001);
	CHECK(b.log == Log::Full); // another place: its own full report
	CHECK_EQ(b.number, uint64_t(2));
	CHECK_EQ(l.total(), uint64_t(2));
	CHECK_EQ(l.places(), size_t(2));
}

TEST(lua_errors_repeats_are_counted_and_summed_up_once_per_minute)
{
	Ledger l;
	uint64_t now = 5000;
	CHECK(l.note("bind_x.script:10", now).log == Log::Full);
	// a callback failing every frame for the next minute: no line at all
	for (int i = 0; i < 3000; ++i)
	{
		now += 19;
		const auto n = l.note("bind_x.script:10", now);
		CHECK(n.log == Log::Count);
	}
	REQUIRE(now - 5000 < lua_errors::kRepeatMs);
	now = 5000 + lua_errors::kRepeatMs; // a minute after the full report
	const auto s = l.note("bind_x.script:10", now);
	CHECK(s.log == Log::Summary);
	CHECK_EQ(s.since_line, uint64_t(3001)); // the 3000 silent ones and this one
	CHECK_EQ(s.at_place, uint64_t(3002));
	CHECK_EQ(s.elapsed_ms, lua_errors::kRepeatMs);
	CHECK_EQ(s.number, uint64_t(3002));
	// the next minute starts from this line
	CHECK(l.note("bind_x.script:10", now + 1).log == Log::Count);
	const auto s2 = l.note("bind_x.script:10", now + lua_errors::kRepeatMs);
	CHECK(s2.log == Log::Summary);
	CHECK_EQ(s2.since_line, uint64_t(2));
	CHECK_EQ(l.total(), uint64_t(3004));
	CHECK_EQ(l.places(), size_t(1));
}

TEST(lua_errors_places_are_capped_and_the_rest_share_one)
{
	Ledger l;
	for (size_t i = 0; i < lua_errors::kMaxPlaces; ++i)
		CHECK(l.note("s.script:" + std::to_string(i), 100).log == Log::Full);
	CHECK_EQ(l.places(), lua_errors::kMaxPlaces);
	const auto a = l.note("late.script:1", 200);
	CHECK(a.log == Log::Full); // the first one past the cap still gets its stack
	CHECK_EQ(a.place, std::string(lua_errors::kOtherPlaces));
	const auto b = l.note("later.script:2", 300);
	CHECK(b.log == Log::Count); // ... the next ones count in the shared place
	CHECK_EQ(b.place, std::string(lua_errors::kOtherPlaces));
	CHECK_EQ(l.places(), lua_errors::kMaxPlaces + 1);
	// a place known before the cap keeps its own bookkeeping
	CHECK_EQ(l.note("s.script:0", 400).place, std::string("s.script:0"));
}

TEST(lua_errors_top_places_most_errors_first)
{
	Ledger l;
	for (int i = 0; i < 5; ++i)
		l.note("a.script:1", 10);
	for (int i = 0; i < 9; ++i)
		l.note("b.script:2", 10);
	l.note("c.script:3", 10);
	const auto top = l.top(2);
	REQUIRE(top.size() == 2);
	CHECK_EQ(top[0].place, std::string("b.script:2"));
	CHECK_EQ(top[0].count, uint64_t(9));
	CHECK_EQ(top[1].place, std::string("a.script:1"));
	CHECK_EQ(l.top(10).size(), size_t(3));
}

TEST(lua_errors_lines_have_the_launcher_form)
{
	Ledger l;
	const auto n = l.note("ui_options.script:912", 0);
	const std::string full = lua_errors::survived_line(n, "...\\ui_options.script:912: attempt to index a nil value");
	CHECK_EQ(full, std::string("! [coop] Lua error survived (#1, ui_options.script:912): ...\\ui_options.script:912: attempt "
	                           "to index a nil value"));
	l.note("ui_options.script:912", 10);
	const auto s = l.note("ui_options.script:912", lua_errors::kRepeatMs);
	const std::string again = lua_errors::survived_line(s, "boom");
	CHECK(contains(again, "! [coop] Lua error survived (#3, ui_options.script:912): 2 more in 60 s, 3 at this place: boom"));
	CHECK_EQ(lua_errors::stack_line(" 0 : [Lua] ui_options.script(912) : on_change"),
	    std::string("! [LUA]  0 : [Lua] ui_options.script(912) : on_change"));
}

TEST(lua_errors_message_is_one_line_and_clipped)
{
	CHECK_EQ(lua_errors::clip("a\nb\r\nc"), std::string("a | b | c"));
	CHECK_EQ(lua_errors::clip(nullptr), std::string("(not a string)"));
	const std::string big(lua_errors::kMaxMessage + 50, 'x');
	const std::string c = lua_errors::clip(big.c_str());
	CHECK_EQ(c.size(), lua_errors::kMaxMessage + 3);
	CHECK(c.substr(c.size() - 3) == "...");
}

TEST(lua_errors_status_lines)
{
	Ledger l;
	CHECK_EQ(lua_errors::status_line(l, 1, true),
	    std::string("[coop] lua errors: coop_lua_errors 1 (survive, in a session now), survived 0 at 0 place(s)"));
	for (int i = 0; i < 4; ++i)
		l.note("b.script:2", 10);
	l.note("a.script:1", 10);
	CHECK_EQ(lua_errors::status_line(l, 0, true),
	    std::string("[coop] lua errors: coop_lua_errors 0 (stock: fatal), survived 5 at 2 place(s)"));
	CHECK_EQ(lua_errors::status_line(l, 1, false),
	    std::string("[coop] lua errors: coop_lua_errors 1 (survive, not in a session now: fatal), survived 5 at 2 place(s)"));
	const auto top = l.top(1);
	REQUIRE(top.size() == 1);
	CHECK_EQ(lua_errors::status_place_line(top[0]), std::string("[coop]   lua errors x4 at b.script:2"));
}

// --- the engine's sources -------------------------------------------------------------------------------------------------
namespace
{
std::string engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string read_file(const std::string& rel)
{
	std::ifstream in(std::filesystem::path(engine_src()) / rel, std::ios::binary);
	std::stringstream ss;
	ss << in.rdbuf();
	return ss.str();
}

// The `if (` block that starts at `at`: from its '{' to the matching '}'.
std::string block_after(const std::string& code, size_t at)
{
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

// Every failed pcall in luabind's call proxies asks the survive callback first: the error is then dropped (or turned into
// nil for a luabind::object) and the call returns a safe value; only when it says no do they go on to the error callback.
TEST(lua_errors_every_luabind_call_proxy_asks_the_survive_callback)
{
	const char* files[] = {"3rd party/luabind/functor.hpp", "3rd party/luabind/detail/call_member.hpp",
	    "3rd party/luabind/detail/call_function.hpp", "3rd party/luabind/object.hpp"};
	size_t sites = 0;
	for (const char* f : files)
	{
		const std::string code = read_file(f);
		REQUIRE(!code.empty());
		for (const char* head : {"if (pcall(L", "if (m_fun(L"})
		{
			for (size_t at = code.find(head); at != std::string::npos; at = code.find(head, at + 1))
			{
				++sites;
				const std::string block = block_after(code, at);
				const size_t asked = block.find("pcall_error_survived(L)");
				const size_t fatal = block.find("get_error_callback()");
				if (asked == std::string::npos || (fatal != std::string::npos && fatal < asked))
				{
					std::printf("    %s: a failed call that does not ask the survive callback first:\n%s\n", f, block.c_str());
					CHECK(false);
				}
			}
		}
	}
	CHECK_EQ(sites, size_t(18)); // functor 5, call_member 5, call_function 5, object 3
}

TEST(lua_errors_engine_wires_the_errfunc_the_callback_and_the_console)
{
	const std::string engine = read_file("xrServerEntities/script_engine.cpp");
	CHECK(contains(engine, "::luabind::set_error_survive_callback("));
	CHECK(contains(engine, "coop::lua_errors::on_pcall_error(L)"));
	const std::string glue = read_file("xrGame/coop/coop_lua_errors.cpp");
	CHECK(contains(glue, "CMD4(CCC_Integer, \"coop_lua_errors\", &g_coop_lua_errors, 0, 1)"));
	CHECK(contains(glue, "int g_coop_lua_errors = 1;"));
	const std::string console = read_file("xrGame/coop/coop_console.cpp");
	CHECK(contains(console, "lua_errors::register_console()"));
	const std::string manager = read_file("xrGame/coop/coop_manager.cpp");
	CHECK(contains(manager, "lua_errors::print_status()"));
	const std::string err = read_file("3rd party/luabind/luabind/src/error.cpp");
	CHECK(contains(err, "get_error_survive_callback()"));
}
