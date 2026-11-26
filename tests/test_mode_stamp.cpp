// Anomaly Coop unit tests: the stamp of the mode's answers (xrCoop/coop_mode_stamp.h, coop.mode_stamp in Lua). The counter rule runs
// here; its wiring (where the engine bumps it, the Lua export) is read from the engine's sources, which cannot run without the game.
#include "test_util.h"

#include "coop_mode_stamp.h"

#include <fstream>
#include <set>
#include <sstream>
#include <string>

using coop::ModeStamp;

TEST(mode_stamp_stays_until_a_bump_and_never_repeats)
{
	ModeStamp s;
	const uint64_t first = s.now();
	CHECK(first != 0);
	CHECK_EQ(s.now(), first); // reads alone change nothing
	std::set<uint64_t> seen{first};
	uint64_t last = first;
	for (int i = 0; i < 10000; ++i)
	{
		s.bump();
		const uint64_t v = s.now();
		CHECK(v > last); // only grows: a value of an earlier frame never comes back
		CHECK(seen.insert(v).second);
		CHECK_EQ(s.now(), v);
		last = v;
	}
	// the process's own stamp follows the same rule
	const uint64_t g0 = coop::g_mode_stamp.now();
	coop::g_mode_stamp.bump();
	CHECK(coop::g_mode_stamp.now() > g0);
}

namespace
{
std::string stamp_engine_src()
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	if (slash == std::string::npos)
		return "engine/src";
	here.resize(slash);
	return here + "/../engine/src";
}

std::string stamp_read(const std::string& rel)
{
	std::ifstream in(stamp_engine_src() + rel, std::ios::binary);
	std::ostringstream s;
	s << in.rdbuf();
	std::string out;
	for (char c : s.str())
		if (c != '')
			out += c;
	return out;
}

// The source with // comments blanked (the files read here keep no /* */ comments and no "//" inside a string).
std::string stamp_code(const std::string& src)
{
	std::string out = src;
	for (size_t at = out.find("//"); at != std::string::npos; at = out.find("//", at))
	{
		const size_t end = out.find('\n', at);
		for (size_t i = at; i < (end == std::string::npos ? out.size() : end); ++i)
			out[i] = ' ';
	}
	return out;
}

// The text from `head` to the matching close of the first '{' after it; empty when `head` is missing.
std::string stamp_body(const std::string& code, const std::string& head)
{
	const size_t at = code.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t open = code.find('{', at);
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

size_t stamp_count(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + 1))
		++n;
	return n;
}

const char* const kBump = "g_mode_stamp.bump();";
} // namespace

TEST(mode_stamp_is_bumped_where_the_facade_can_change)
{
	const std::string mgr = stamp_code(stamp_read("/xrGame/coop/coop_manager.cpp"));
	REQUIRE(!mgr.empty());

	// every frame, first
	const std::string frame = stamp_body(mgr, "void Manager::frame()");
	REQUIRE(!frame.empty());
	const size_t first_stmt = frame.find_first_not_of(" \t\r\n", 1);
	CHECK_EQ(frame.compare(first_stmt, std::string(kBump).size(), kBump), 0);
	// after each update of the session and of a map server's world link: what their messages changed
	for (const char* update : {"m_world.update(now_ms());", "m_session.update(now_ms());"})
	{
		const size_t at = frame.find(update);
		REQUIRE(at != std::string::npos);
		const size_t next = frame.find_first_not_of(" \t\r\n", at + std::string(update).size());
		CHECK_EQ(frame.compare(next, std::string(kBump).size(), kBump), 0);
	}

	// the phase and the roles
	const std::string phase = stamp_body(mgr, "void Manager::set_phase(Phase p)");
	REQUIRE(!phase.empty());
	const size_t roles = phase.find("m_roles = roles_of(p);");
	REQUIRE(roles != std::string::npos);
	CHECK(phase.find(kBump, roles) != std::string::npos);

	// a mode installed (two starts), a failed start back to none
	for (const char* fn : {"bool Manager::enter_mode(Mode* m)", "void Manager::enter_mode_of_welcome(SessionMode said)"})
	{
		const std::string body = stamp_body(mgr, fn);
		REQUIRE(!body.empty());
		const size_t installed = body.find("install_mode(*m)");
		REQUIRE(installed != std::string::npos);
		CHECK(body.find(kBump, installed) != std::string::npos);
	}
	CHECK_EQ(stamp_count(mgr, "reset_mode();"), stamp_count(mgr, std::string("reset_mode();\n\t\t") + kBump) + 1); // + set_phase's
	CHECK(phase.find("reset_mode();") != std::string::npos);

	// a peer joins or leaves
	for (const char* cb : {"m_session.on_peer_joined = ", "m_session.on_peer_left = "})
	{
		const std::string body = stamp_body(mgr, cb);
		REQUIRE(!body.empty());
		const size_t first = body.find_first_not_of(" \t\r\n", 1);
		CHECK_EQ(body.compare(first, std::string(kBump).size(), kBump), 0);
	}

	// a Lua state is made (a level starts), and the export reads the counter
	const std::string script = stamp_code(stamp_read("/xrGame/coop/coop_script.cpp"));
	const std::string raw = stamp_body(script, "void register_raw(lua_State* L)");
	REQUIRE(!raw.empty());
	CHECK(raw.find(kBump) != std::string::npos);
	CHECK(raw.find("{\"mode_stamp\", &l_mode_stamp},") != std::string::npos);
	const std::string read = stamp_body(script, "int l_mode_stamp(lua_State* L)");
	REQUIRE(!read.empty());
	CHECK(read.find("g_mode_stamp.now()") != std::string::npos);
	CHECK(read.find("if") == std::string::npos); // no session check: every process, with or without a session
}
