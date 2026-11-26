// INTEG-C (A-S6-E-story's deferred rows, H-OPCMD): an operator's console line goes to the world server through the mode. Only a
// player of a server world has a world server to send it to: his mode checks the line (op::allowed) and sends it; every other
// process kind answers Unreachable. The Core (coop_debug.cpp) keeps its three lines and validates nothing itself.
#include "test_util.h"
#include "srv/coop_operator.h"
#include "support/fake_mode.h"

#include <fstream>
#include <iterator>
#include <string>
#include <string_view>

namespace
{
using coop::OperatorSend;

std::string game_source(const char* file)
{
	const std::string here = __FILE__;
	const auto slash = here.find_last_of("\\/");
	const auto dir = slash == std::string::npos ? std::string(".") : here.substr(0, slash);
	std::ifstream in(dir + "/../engine/src/xrGame/coop/" + file, std::ios::binary);
	return {std::istreambuf_iterator<char>(in), {}};
}

std::string_view section(std::string_view source, std::string_view start, std::string_view end)
{
	const size_t first = source.find(start);
	REQUIRE(first != std::string_view::npos);
	const size_t last = source.find(end, first + start.size());
	REQUIRE(last != std::string_view::npos);
	return source.substr(first, last - first);
}

bool has(std::string_view code, std::string_view what) { return code.find(what) != std::string_view::npos; }

void check_operator(const t::ModeCase& kind)
{
	t::FakeMode mode(kind);
	const bool player_of_server = std::string_view(kind.name) == "server_client";
	CHECK_EQ(mode.send_operator_command("coop_status"), player_of_server ? OperatorSend::Sent : OperatorSend::Unreachable);
	CHECK_EQ(mode.send_operator_command("coop_status;quit"), player_of_server ? OperatorSend::Refused : OperatorSend::Unreachable);
	CHECK_EQ(mode.send_operator_command("coop_status  x"), player_of_server ? OperatorSend::Refused : OperatorSend::Unreachable);
}
} // namespace

#define OPERATOR_CASE(kind) \
	TEST(mode_operator_##kind) { check_operator(t::mode_case(#kind)); }
MODE_CASES(OPERATOR_CASE)
#undef OPERATOR_CASE

TEST(mode_operator_none_has_no_world_server)
{
	coop::NoneMode none;
	CHECK_EQ(none.send_operator_command("coop_status"), OperatorSend::Unreachable);
	CHECK_EQ(none.send_operator_command(""), OperatorSend::Unreachable);
}

TEST(mode_operator_real_modes_answer_per_kind)
{
	const std::string srv = game_source("srv/coop_srv_mode.cpp");
	REQUIRE(!srv.empty());
	const auto player = section(srv, "class ServerClientMode final", "\n};");
	CHECK(has(player, "OperatorSend send_operator_command(const std::string& line) override"));
	CHECK(has(player, "op::allowed(line)"));
	CHECK(has(player, "mgr().session().send_operator_command(line)"));
	for (const char* other : {"class WorldServerMode final", "class MapServerMode final"})
	{
		const auto mode = section(srv, other, "\n};");
		CHECK(has(mode, "OperatorSend send_operator_command(const std::string&) override { return OperatorSend::Unreachable; }"));
	}
	const std::string coop = game_source("hostplay/coop_hostplay_mode.cpp");
	REQUIRE(!coop.empty());
	// both co-op modes answer it in their common base
	const auto base = section(coop, "class CoopModeBase : public ModeWithAnswers", "\n};");
	CHECK(has(base, "OperatorSend send_operator_command(const std::string&) override { return OperatorSend::Unreachable; }"));
	for (const char* kind : {"class CoopHostMode final : public CoopModeBase", "class CoopClientMode final : public CoopModeBase"})
		CHECK(!has(section(coop, kind, "\n};"), "send_operator_command"));
}

TEST(mode_operator_core_validates_nothing_itself)
{
	const std::string debug = game_source("coop_debug.cpp");
	REQUIRE(!debug.empty());
	const auto send = section(debug, "void send_to_server(const std::string& line)", "\n}");
	CHECK(has(send, "mode().send_operator_command(line)"));
	CHECK(has(send, "this line cannot go to the server"));
	CHECK(has(send, "the world server is not reachable now"));
	CHECK(has(send, "sent to the world server: "));
	CHECK(!has(debug, "op::allowed"));
	CHECK(!has(debug, "coop_operator.h"));
	CHECK(!has(debug, "session().send_operator_command"));
}
