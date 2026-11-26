// Anomaly Coop unit tests: player survival is four files over one private state header (xrGame/coop/coop_survival*.cpp,
// coop_survival_state.h). The native runner cannot link xrGame, so the shape the cleanup left is checked in the source: one way
// to list the players without copies, one prefix test of a revive item, the camera named by its enum, the revive's tail read
// whole, no hybrid branch at a new world, the test command only in debug builds.
//
// Per mode: survival is Core and has no mode branch; these checks hold for Co-op and Server alike.
#include "test_util.h"

#include <fstream>
#include <sstream>
#include <string>

namespace
{
std::string split_source(const char* file)
{
	std::string path = __FILE__;
	const size_t slash = path.find_last_of("/\\");
	path = slash == std::string::npos ? "tests/" : path.substr(0, slash + 1);
	std::ifstream in(path + "../engine/src/xrGame/coop/" + file, std::ios::binary);
	std::ostringstream out;
	out << in.rdbuf();
	return out.str();
}

// The body of a function: from its signature to the first closing brace at the start of a line.
std::string split_function(const std::string& code, const char* signature)
{
	const size_t start = code.find(signature);
	REQUIRE(start != std::string::npos);
	const size_t end = code.find("\n}", start);
	REQUIRE(end != std::string::npos);
	return code.substr(start, end - start);
}

size_t split_count(const std::string& text, const std::string& what)
{
	size_t n = 0;
	for (size_t at = text.find(what); at != std::string::npos; at = text.find(what, at + what.size()))
		++n;
	return n;
}

const char* const kSurvivalFiles[] = {"coop_survival.cpp", "coop_survival_cam.cpp", "coop_survival_hud.cpp",
	"coop_survival_newchar.cpp", "coop_survival_state.h"};
} // namespace

TEST(survival_split_files_are_there)
{
	for (const char* f : kSurvivalFiles)
		CHECK(split_source(f).size() > 1000);
	// the shared state is declared once, in the private header, and defined in one file
	const std::string state = split_source("coop_survival_state.h");
	CHECK(state.find("extern Local g_me;") != std::string::npos);
	CHECK(split_count(split_source("coop_survival.cpp"), "\nLocal g_me;") == 1);
}

// The players of this machine are walked by each_player (no vector, no nick copies); collect_players is the public list and
// is built from it, so both give the same players in the same order.
TEST(survival_split_players_are_walked_without_copies)
{
	for (const char* f : kSurvivalFiles)
	{
		const std::string src = split_source(f);
		const size_t calls = split_count(src, "collect_players(");
		const size_t defs = split_count(src, "void collect_players(");
		if (calls != defs)
			::t::report_failure(__FILE__, __LINE__, std::string(f) + " lists the players with collect_players");
	}
	const std::string survival = split_source("coop_survival.cpp");
	CHECK(split_function(survival, "void collect_players(").find("each_player(") != std::string::npos);
	CHECK(split_function(survival, "\nvoid frame()").find("each_player(") != std::string::npos);
	const std::string state = split_source("coop_survival_state.h");
	const std::string walk = split_function(state, "template <class F> void each_player(");
	CHECK(walk.find("for_each_joined(") != std::string::npos);
	CHECK(walk.find("peers()") == std::string::npos);
}

// The section prefixes of the revive items are tested in one place (revive_rank); the medkit is still preferred.
TEST(survival_split_one_revive_prefix_test)
{
	const std::string survival = split_source("coop_survival.cpp");
	CHECK(survival.find("const char* const kReviveItems[] = {\"medkit\", \"stimpack\"};") != std::string::npos);
	CHECK(split_count(survival, "kReviveItems[i]") == 1);
	CHECK(survival.find("for (const char* prefix : kReviveItems)") == std::string::npos);
	CHECK(survival.find("is_revive_section") == std::string::npos);
	const std::string pick = split_function(survival, "PIItem find_revive_item(");
	CHECK(pick.find("rank < best_rank") != std::string::npos); // the first item of the most preferred kind
}

// The camera of the own player is named by Cam, never by a number.
TEST(survival_split_camera_by_name)
{
	for (const char* f : kSurvivalFiles)
	{
		const std::string src = split_source(f);
		for (const char* bad : {"set_cam(a, 0)", "set_cam(a, 1)", "set_cam(a, 2)", "set_cam(a, 3)", "g_me.cam == 1", "g_me.cam == 2",
			     "g_me.cam == 3", "u8 cam"})
			if (src.find(bad) != std::string::npos)
				::t::report_failure(__FILE__, __LINE__, std::string(f) + ": '" + bad + "'");
	}
	CHECK(split_source("coop_survival_state.h").find("enum class Cam : u8") != std::string::npos);
}

// Revive: the reviver's peer and the medkit are always on the wire, read whole; a malformed tail still revives.
TEST(survival_split_revive_tail_read_whole)
{
	const std::string survival = split_source("coop_survival.cpp");
	// the body of apply_order (its first line; the forward declaration above it has none)
	const std::string order = split_function(survival, "if (op == OpReviving || op == OpStopped || op == OpDone)");
	const size_t revive = order.find("case OpRevive:");
	const size_t respawn = order.find("case OpRespawn:");
	REQUIRE(revive != std::string::npos && respawn != std::string::npos && revive < respawn);
	const std::string body = order.substr(revive, respawn - revive);
	CHECK(body.find("remaining()") == std::string::npos);
	CHECK(body.find("if (r.ok() && s.size() <= 128)") != std::string::npos);
	CHECK(body.find("apply_revive(seq, reviver, health, reviver_peer, medkit.c_str());") != std::string::npos);
	const std::string request = split_function(survival, "void host_on_revive_request(");
	CHECK(request.find("w.u32(peer_of_character(reviver));") != std::string::npos);
	CHECK(request.find("w.str(i_obj->cNameSect().c_str());") != std::string::npos);
}

// A new world starts the host's records over: nobody stays in his world through the host's move.
TEST(survival_split_new_world_drops_every_record)
{
	const std::string survival = split_source("coop_survival.cpp");
	const std::string host = split_function(survival, "void host_frame(u64 t)");
	CHECK(host.find("host_stayed_in_world") == std::string::npos);
	CHECK(host.find("g_host.clear();") != std::string::npos);
	CHECK(host.find("g_retire.clear();") != std::string::npos);
}

// coop_wound_me is a test command: registered in debug builds only.
TEST(survival_split_test_command_debug_only)
{
	const std::string survival = split_source("coop_survival.cpp");
	const std::string reg = split_function(survival, "void register_console()");
	const size_t guard = reg.find("#ifdef DEBUG");
	const size_t cmd = reg.find("CMD1(CCC_CoopWoundMe, \"coop_wound_me\");");
	const size_t end = reg.find("#endif", guard);
	REQUIRE(guard != std::string::npos && cmd != std::string::npos && end != std::string::npos);
	CHECK(guard < cmd && cmd < end);
}
