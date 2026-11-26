// Anomaly Coop unit tests: the stock hooks ask mode() (step S4 of docs/plans/2026-11-18-two-modes.md, unit A-S4H; docs/MODES.md
// section 4 "Хуки в стоке", section 3 rule 7, critique H5).
//
// The engine files cannot run here; what the step asks for is read from the sources:
// - the stock hooks (alife_switch_manager.cpp, alife_update_manager.cpp, GameObject.cpp, xrServer.h) name no server function of
//   tools/srv_entry.txt: they ask the session's mode (xrCoop/coop_mode.h, the H5 hooks);
// - the server functions behind them ask no mode any more: each is reached only through the server mode whose process has it, and
//   that mode's answer is written in its own class (srv/coop_srv_mode.cpp); the co-op's answers are the empty ones;
// - the frame of a map server waits for its world's Welcome as before, the stats of a server's process run from the server's boot;
// - the server's console names and the Lua table srv.*.
// GameObject's hook drops `|| g_coop_headless`: in every build of this game g_dedicated_server is set only with g_coop_headless
// (xrEngine/x_ray.cpp), so `!g_dedicated_server || g_coop_headless` is always true; mode_hooks_dedicated_means_headless keeps that so.
#include "test_util.h"

#include <fstream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace
{
// engine/src, found next to this source file (tests\ -> ..\engine\src)
std::string engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	std::ifstream probe(here + "/../engine/src/xrCoop/coop_mode.h");
	if (probe)
		return here + "/../engine/src";
	return here + "/../../engine/src"; // temp\s4h\ while the test is written
}

std::string read_text(const std::string& path)
{
	std::ifstream in(path, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	return s.str();
}

// The source with // and /* */ comments blanked (string literals kept).
std::string code_of(const std::string& src)
{
	std::string out = src;
	enum class St
	{
		Code,
		Line,
		Block,
		Str,
		Chr
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
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '/' && n == '*')
			{
				st = St::Block;
				out[i] = out[i + 1] = ' ';
				++i;
			}
			else if (c == '"')
				st = St::Str;
			else if (c == '\'')
				st = St::Chr;
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
				out[i] = out[i + 1] = ' ';
				++i;
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
		case St::Chr:
			if (c == '\\')
				++i;
			else if (c == '\'')
				st = St::Code;
			break;
		}
	}
	return out;
}

std::string collapse(const std::string& s)
{
	std::string r = std::regex_replace(s, std::regex(R"(\s+)"), " ");
	return std::regex_replace(r, std::regex(R"(^ | $)"), "");
}

// The body between the braces that open at `open` (the index of '{'); "" when they do not close.
std::string braced(const std::string& code, size_t open)
{
	int depth = 1;
	size_t i = open + 1;
	for (; i < code.size() && depth; ++i)
		depth += code[i] == '{' ? 1 : (code[i] == '}' ? -1 : 0);
	return depth ? "" : code.substr(open + 1, i - 2 - open);
}

// The body of the first function whose head matches `head` (a regex ending at the name); "" and a failure of the test when there is
// none.
std::string body_of(const std::string& code, const std::string& head)
{
	std::smatch m;
	const std::regex rx(head + R"(\s*\([^;{]*\)\s*(?:const\s*)?(?:override\s*)?(?:final\s*)?\{)");
	if (!std::regex_search(code, m, rx))
	{
		t::report_failure(__FILE__, __LINE__, "no function " + head);
		return "";
	}
	return braced(code, size_t(m.position(0) + m.length(0) - 1));
}

// The body of `class <name>` (its braces).
std::string class_body(const std::string& code, const std::string& name)
{
	std::smatch m;
	if (!std::regex_search(code, m, std::regex(R"(\bclass\s+)" + name + R"(\b[^;{]*\{)")))
	{
		t::report_failure(__FILE__, __LINE__, "no class " + name);
		return "";
	}
	return braced(code, size_t(m.position(0) + m.length(0) - 1));
}

// The collapsed body of a mode's hook `name` in a class body ("<none>" when the class has no such override).
std::string hook(const std::string& cls, const std::string& name)
{
	std::smatch m;
	const std::regex rx(R"(\b)" + name + R"(\s*\([^;{)]*\)\s*(?:const\s*)?override\s*\{)");
	if (!std::regex_search(cls, m, rx))
		return "<none>";
	return collapse(braced(cls, size_t(m.position(0) + m.length(0) - 1)));
}

bool has(const std::string& text, const std::string& what) { return text.find(what) != std::string::npos; }

bool calls(const std::string& code, const std::string& name)
{
	return std::regex_search(code, std::regex(R"((?:^|[^\w])(?:coop\s*::\s*)?)" + name + R"(\s*\()"));
}

// The names of tools/srv_entry.txt: one per line, `#` comments, `ns::name` qualified.
std::vector<std::string> srv_entries()
{
	std::vector<std::string> out;
	std::istringstream in(read_text(engine_src() + "/../../tools/srv_entry.txt"));
	std::string line;
	while (std::getline(in, line))
	{
		line = collapse(line);
		if (line.empty() || line[0] == '#')
			continue;
		out.push_back(std::regex_replace(line, std::regex(R"(::)"), R"(\s*::\s*)"));
	}
	return out;
}

const char* const kStockHooks[] = {"/xrGame/alife_switch_manager.cpp", "/xrGame/alife_update_manager.cpp", "/xrGame/GameObject.cpp",
    "/xrGame/xrServer.h"};
const char* const kHooks[] = {"online_elsewhere", "binder_may_update", "held_update", "switched_offline", "takes_own_ids",
    "own_free_id"};
// A mode without a map server's transfers: the answers of xrCoop/coop_mode.h NoneMode.
const char* const kEmpty[] = {"return false;", "return true;", "", "", "return false;", "return kNoId;"};
} // namespace

// Rule 7 (critique H5): no stock hook reaches a server function; each asks the session's mode.
TEST(mode_hooks_stock_files_ask_the_mode)
{
	const std::string src = engine_src();
	const std::vector<std::string> entries = srv_entries();
	REQUIRE(!entries.empty());
	for (const char* file : kStockHooks)
	{
		const std::string code = code_of(read_text(src + file));
		REQUIRE(!code.empty());
		for (const std::string& name : entries)
			if (calls(code, name))
				t::report_failure(__FILE__, __LINE__, std::string(file) + " calls the server entry " + name);
		CHECK(!has(code, "coop::levels::"));
		CHECK(!has(code, "coop_levels.h"));
		CHECK(has(code, "#include \"xrCoop/coop_mode.h\""));
	}
	const std::string sw = code_of(read_text(src + kStockHooks[0]));
	const std::string on = collapse(body_of(sw, R"(void\s+CALifeSwitchManager::switch_online)"));
	CHECK(has(on, "if (coop::mode().online_elsewhere(object->ID)) return; object->switch_online();"));
	const std::string off = collapse(body_of(sw, R"(void\s+CALifeSwitchManager::switch_offline)"));
	CHECK(has(off, "if (coop::mode().online_elsewhere(object->ID)) return; object->switch_offline(); "
	               "coop::entities::host_on_switch(object, false); coop::mode().switched_offline(object->ID);"));

	const std::string up = code_of(read_text(src + kStockHooks[1]));
	CHECK(has(collapse(body_of(up, R"(void\s+CALifeUpdateManager::update_scheduled)")),
	    "if (coop::sync::alife_frozen()) { coop::mode().held_update(); return; }"));
	CHECK(has(collapse(body_of(up, R"(void\s+CALifeUpdateManager::teleport_object)")),
	    "if (coop::mode().online_elsewhere(id)) return; if (object->m_bOnline) switch_offline(object);"));

	const std::string go = code_of(read_text(src + kStockHooks[2]));
	const std::string update = collapse(body_of(go, R"(void\s+CGameObject::shedule_Update)"));
	CHECK(has(update, "if (!g_dedicated_server || coop::mode().binder_may_update(this)) CScriptBinder::shedule_Update(dt);"));
	CHECK(!has(update, "g_coop_headless"));

	const std::string server = code_of(read_text(src + kStockHooks[3]));
	CHECK(has(collapse(body_of(server, R"(IC\s+u16\s+PerformIDgen)")),
	    "if (ID == 0xffff && coop::mode().takes_own_ids()) { ID = coop::mode().own_free_id(); if (ID == 0xffff) { ID = "
	    "m_tID_Generator.tfGetID(0xffff); CoopTookStockId(ID); return ID; } } return (m_tID_Generator.tfGetID(ID));"));
}

// GameObject's hook keeps `!g_dedicated_server` and drops `|| g_coop_headless`: that half is always true only while x_ray.cpp sets
// g_dedicated_server with g_coop_headless (a server's process of this game) or in a DEDICATED_SERVER build, which no project defines.
TEST(mode_hooks_dedicated_means_headless)
{
	const std::string src = engine_src();
	const std::string x_ray = code_of(read_text(src + "/xrEngine/x_ray.cpp"));
	REQUIRE(!x_ray.empty());
	const std::regex set_true(R"(\bg_dedicated_server\s*=\s*true\s*;)");
	std::vector<size_t> at;
	for (std::sregex_iterator it(x_ray.begin(), x_ray.end(), set_true), end; it != end; ++it)
		at.push_back(size_t(it->position(0)));
	REQUIRE(at.size() == 2);
	const std::string key = body_of(x_ray, R"(static\s+void\s+coop_headless_read_key)");
	CHECK(has(collapse(key), "g_coop_headless = true; g_dedicated_server = true;"));
	// the other one is the #else of `#ifndef DEDICATED_SERVER`: a DEDICATED_SERVER build's
	const size_t open = x_ray.rfind("#ifndef DEDICATED_SERVER", at[1]);
	REQUIRE(open != std::string::npos);
	int depth = 0;
	bool in_else = false;
	const std::string part = x_ray.substr(open, at[1] - open);
	const std::regex directive(R"(#\s*(if|else|endif))");
	for (std::sregex_iterator it(part.begin(), part.end(), directive), end; it != end; ++it)
	{
		const std::string word = (*it)[1].str();
		if (word == "if")
			++depth;
		else if (word == "endif")
			--depth;
		else if (depth == 1)
			in_else = true;
	}
	CHECK(depth == 1 && in_else);
	for (const char* project : {"/xrEngine/xrEngine.vcxproj", "/xrGame/xrGame.vcxproj"})
	{
		const std::string text = read_text(src + project);
		REQUIRE(!text.empty());
		CHECK(!has(text, "DEDICATED_SERVER"));
	}
}

// The server functions behind the hooks ask no mode: the server mode that has them calls them (critique H5, docs/MODES.md section 4).
TEST(mode_hooks_server_functions_ask_no_mode)
{
	const std::string src = engine_src();
	const std::string xfer = code_of(read_text(src + "/xrGame/coop/srv/coop_levels_xfer.cpp"));
	REQUIRE(!xfer.empty());
	const char* const words[] = {"is_map_server", "is_world_server", "is_host(", "is_client(", "has_role", "split()", "dedicated"};
	for (const char* fn : {"bool\\s+logic_may_update", "bool\\s+online_at_server", "void\\s+xfer_scheduled",
	         "void\\s+xfer_on_switched_offline", "u16\\s+leader_free_id"})
	{
		const std::string body = body_of(xfer, fn);
		REQUIRE(!body.empty());
		for (const char* word : words)
			if (has(body, word))
				t::report_failure(__FILE__, __LINE__, std::string(fn) + " asks " + word);
	}
	CHECK(!calls(xfer, "leader_takes_ids")); // a map server's mode answers takes_own_ids itself
	const std::string levels = code_of(read_text(src + "/xrGame/coop/coop_levels.cpp"));
	CHECK(!has(body_of(levels, R"(void\s+frame)"), "split()"));
	// coop.levels.online_at_server asks the hook the switch manager asks, not the world server's function
	const std::string lua_online = collapse(body_of(levels, R"(int\s+l_online_at_server)"));
	CHECK(has(lua_online, "mode().online_elsewhere(u16(id))"));
	CHECK(!calls(lua_online, "online_at_server"));
	const std::string map = code_of(read_text(src + "/xrGame/coop/srv/coop_mapserver.cpp"));
	CHECK(!has(body_of(map, R"(void\s+host_frame)"), "is_host("));
	const std::string serve = body_of(map, R"(void\s+server_frame)");
	CHECK(!has(serve, "is_map_server"));
	// a map server's frame waits for its world's Welcome, as levels::frame did before (its frame times count from there)
	CHECK(has(collapse(serve).substr(0, 40), "if (!levels::split()) return;"));
	const std::string stats = code_of(read_text(src + "/xrGame/coop/srv/coop_mapserver_stats.cpp"));
	CHECK(!has(body_of(stats, R"(void\s+mapserver_stats_frame)"), "g_coop_headless"));
	const std::string manager = code_of(read_text(src + "/xrGame/coop/coop_manager.cpp"));
	REQUIRE(!manager.empty());
	CHECK(!calls(manager, "mapserver_stats_frame")); // the Core's frame: the server's boot runs it
}

// Each mode answers the hooks of its own process: the world server's transfers keep its objects (online at a map server), a map
// server holds, updates, gives back and numbers its own; a player of a server world and both co-op modes answer the empty ones.
TEST(mode_hooks_each_mode_answers_its_own)
{
	const std::string src = engine_src();
	const std::string srv = code_of(read_text(src + "/xrGame/coop/srv/coop_srv_mode.cpp"));
	const std::string coop = code_of(read_text(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp"));
	REQUIRE(!srv.empty() && !coop.empty());
	const std::map<std::string, std::vector<std::string>> want = {
		{"WorldServerMode",
		    {"return levels::online_at_server(id);", "return true;", "", "", "return false;", "return kNoId;"}},
		{"MapServerMode",
		    {"return false;", "return levels::logic_may_update(object);", "levels::xfer_scheduled();",
		        "levels::xfer_on_switched_offline(id);", "return true;", "return levels::leader_free_id();"}},
		{"ServerClientMode", std::vector<std::string>(std::begin(kEmpty), std::end(kEmpty))},
		{"CoopHostMode", std::vector<std::string>(std::begin(kEmpty), std::end(kEmpty))},
		{"CoopClientMode", std::vector<std::string>(std::begin(kEmpty), std::end(kEmpty))},
	};
	for (const auto& w : want)
	{
		// both co-op modes answer these in their common base (CoopModeBase), after their own overrides
		const bool co = w.first.rfind("Coop", 0) == 0;
		const std::string cls = co ? class_body(coop, w.first) + class_body(coop, "CoopModeBase") : class_body(srv, w.first);
		REQUIRE(!cls.empty());
		for (size_t i = 0; i < w.second.size(); ++i)
		{
			const std::string got = hook(cls, kHooks[i]);
			if (got != w.second[i])
				t::report_failure(__FILE__, __LINE__, w.first + "::" + kHooks[i] + " is '" + got + "', not '" + w.second[i] + "'");
		}
	}
	// the stats line of a server's process (60 s; plan F3a 1.8): the server's boot runs it in its own processes, the co-op names none
	CHECK(has(collapse(body_of(srv, R"(bool\s+boot_frame)")), "if (g_coop_headless) mapserver_stats_frame();"));
	CHECK(!has(coop, "mapserver_stats"));
}

// docs/MODES.md section 6: A-S8 retires the old levels commands. Check the command handlers and machine settings too.
TEST(mode_hooks_srv_console_names)
{
	const std::string code = code_of(read_text(engine_src() + "/xrGame/coop/srv/coop_srv_console.cpp"));
	REQUIRE(!code.empty());
	struct Cmd
	{
		std::string cls, rest;
	};
	std::map<std::string, Cmd> cmds;
	const std::regex rx(R"rx(\bCMD[14]\s*\(\s*(\w+)\s*,\s*"(\w+)"\s*((?:,[^;]*?)?)\)\s*;)rx");
	for (std::sregex_iterator it(code.begin(), code.end(), rx), end; it != end; ++it)
	{
		if (cmds.count((*it)[2].str()))
			t::report_failure(__FILE__, __LINE__, "two commands " + (*it)[2].str());
		cmds[(*it)[2].str()] = Cmd{(*it)[1].str(), collapse((*it)[3].str())};
	}
	const std::map<std::string, std::string> settings = {
		{"max_map_servers", ", &levels::g_coop_max_map_servers, 0, 7"},
		{"mapserver_linger", ", &levels::g_coop_mapserver_linger, 0, 3600"},
		{"map_servers_rev", ", &levels::g_coop_map_servers_rev, 0, 1"},
	};
	for (const auto& s : settings)
		for (const std::string& name : {"srv_" + s.first, "coop_" + s.first})
		{
			const auto it = cmds.find(name);
			REQUIRE(it != cmds.end());
			// the old name is never saved (review A-REV-E-1, finding 7; tests/test_mode_review_e1.cpp)
			CHECK_EQ(it->second.cls, std::string(name.rfind("srv_", 0) == 0 ? "CCC_Integer" : "CCC_SrvOldName"));
			CHECK_EQ(it->second.rest, s.second);
		}
	const std::map<std::string, std::string> commands = {
		{"levels_status", "CCC_SrvLevelsStatus"},
		{"levels_audit", "CCC_SrvLevelsAudit"},
	};
	for (const auto& cmd : commands)
	{
		const auto now = cmds.find("srv_" + cmd.first);
		REQUIRE(now != cmds.end());
		CHECK_EQ(now->second.cls, cmd.second);
		CHECK(now->second.rest.empty());
		CHECK_EQ(cmds.count("coop_" + cmd.first), size_t(0));
	}
	const auto netstats = cmds.find("srv_netstats");
	REQUIRE(netstats != cmds.end());
	CHECK_EQ(netstats->second.cls, std::string("CCC_SrvNetStats"));
	CHECK(netstats->second.rest.empty());
	CHECK_EQ(cmds.size(), size_t(9));
	CHECK(has(collapse(body_of(code, R"(void\s+Execute)")), "levels::print_status();"));
	CHECK(calls(code, "levels\\s*::\\s*xfer_audit_now"));
}

TEST(mode_hooks_srv_stand_uses_canonical_console_names)
{
	const std::string stand = engine_src() + "/../../tools/stand/";
	for (const char* scenario : {"base_server.ps1", "carry_server.ps1", "phantoms_server.ps1"})
	{
		const std::string source = read_text(stand + scenario);
		CHECK(has(source, "'srv_levels_status'"));
		CHECK(!has(source, "'coop_levels_status'"));
	}
}

// The server's commands and table are registered where the Core's are, through the switchboard (the one place of the Core that names
// the layers): the commands before user.ltx is read (a machine's saved settings), the table with every Lua state. The co-op layer has
// none of its own; the levels register no command any more.
TEST(mode_hooks_layers_register_their_own)
{
	const std::string src = engine_src();
	const std::string board = code_of(read_text(src + "/xrGame/coop/coop_mode.cpp"));
	CHECK_EQ(collapse(body_of(board, R"(void\s+register_layers_console)")),
	    std::string("for (Layer* layer : layers().list) layer->register_console();"));
	CHECK_EQ(collapse(body_of(board, R"(void\s+register_layers_lua)")),
	    std::string("for (Layer* layer : layers().list) layer->register_lua(L);"));
	const std::string console = code_of(read_text(src + "/xrGame/coop/coop_console.cpp"));
	CHECK(calls(console, "register_layers_console"));
	CHECK(!calls(console, "levels\\s*::\\s*register_console"));
	CHECK(calls(code_of(read_text(src + "/xrGame/coop/coop_script.cpp")), "register_layers_lua"));
	const std::string levels = code_of(read_text(src + "/xrGame/coop/coop_levels.cpp"));
	CHECK(!std::regex_search(levels, std::regex(R"(\bCMD\d\s*\()")));
	CHECK(!has(levels, "\"coop_max_map_servers\""));
	const std::string layer = class_body(code_of(read_text(src + "/xrGame/coop/srv/coop_srv_mode.cpp")), "ServerLayer");
	CHECK_EQ(hook(layer, "register_console"), std::string("srv::register_console();"));
	CHECK_EQ(hook(layer, "register_lua"), std::string("srv::register_lua(L);"));
	const std::string coop = class_body(code_of(read_text(src + "/xrGame/coop/hostplay/coop_hostplay_mode.cpp")), "CoopLayer");
	CHECK_EQ(hook(coop, "register_console"), std::string("<none>"));
	CHECK_EQ(hook(coop, "register_lua"), std::string("steam::register_lua(L);")); // INTEG-C: Steam is the co-op's
}

// docs/MODES.md section 4 "Lua": the predicates of the server's mode in their own table srv.*; the coop.* copies stay until A-S8.
TEST(mode_hooks_srv_lua_table)
{
	const std::string src = engine_src();
	const std::string code = code_of(read_text(src + "/xrGame/coop/srv/coop_srv_script.cpp"));
	REQUIRE(!code.empty());
	CHECK(has(code, "\"srv\""));
	const std::map<std::string, std::string> want = {
		{"is_dedicated", "dedicated::on()"},
		{"dedicated_new_world", "dedicated::new_world()"},
		{"is_map_server", "is_map_server()"},
		{"is_world_server", "dedicated::on() && is_world_server()"}, // false on a co-op host (review A-REV-E-1, finding 5)
		{"split", "levels::split()"},
	};
	std::map<std::string, std::string> got;
	const std::regex row(R"rx(\{\s*"(\w+)"\s*,\s*&?(\w+)\s*\})rx");
	for (std::sregex_iterator it(code.begin(), code.end(), row), end; it != end; ++it)
		got[(*it)[1].str()] = (*it)[2].str();
	// The rows that are not predicates: the world server's srv.kill_record (TZ P45; its body is pinned by
	// tests/test_issue_p45_kill_record.cpp) and a map server's srv.journal_done (R32 W7, A21 E-1; its body is pinned by
	// tests/test_srv_ops_done_e1.cpp). Every other row is a predicate of the table above.
	const auto kill = got.find("kill_record");
	REQUIRE(kill != got.end());
	CHECK_EQ(kill->second, std::string("l_kill_record"));
	got.erase(kill);
	const auto journal_done = got.find("journal_done");
	REQUIRE(journal_done != got.end());
	CHECK_EQ(journal_done->second, std::string("l_journal_done"));
	got.erase(journal_done);
	CHECK_EQ(got.size(), want.size());
	for (const auto& w : want)
	{
		const auto it = got.find(w.first);
		REQUIRE(it != got.end());
		const std::string body = collapse(body_of(code, R"(int\s+)" + it->second));
		CHECK_EQ(body, "lua_pushboolean(L, " + w.second + "); return 1;");
	}
	// the copies in coop.* (coop_levels.cpp register_lua), read by today's scripts until step S8
	const std::string levels = collapse(code_of(read_text(src + "/xrGame/coop/coop_levels.cpp")));
	for (const char* row_text : {"{\"is_world_server\", &l_is_world_server}", "{\"is_dedicated\", &l_is_dedicated}",
	         "{\"dedicated_new_world\", &l_dedicated_new_world}", "{\"is_map_server\", &l_is_map_server}", "{\"split\", &l_split}"})
		CHECK(has(levels, row_text));
}
