// Engine log contracts checked against the source because xrGame is outside the native test binary.
#include "test_util.h"

#include <fstream>
#include <iterator>
#include <regex>

namespace
{
std::string game_source(const char* file)
{
	std::string path = __FILE__;
	path.resize(path.find_last_of("\\/") + 1);
	std::ifstream in(path + "../engine/src/xrGame/" + file, std::ios::binary);
	REQUIRE(in.good());
	return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::string section(const std::string& src, const char* first, const char* next)
{
	const size_t begin = src.find(first);
	REQUIRE(begin != std::string::npos);
	const size_t end = src.find(next, begin + 1);
	REQUIRE(end != std::string::npos);
	return src.substr(begin, end - begin);
}
} // namespace

TEST(rep_log_coop_silence_cleanup_does_not_claim_the_host_replied)
{
	const std::string src = game_source("coop/coop_manager.cpp");
	const std::string disconnect = section(src, "session.on_disconnected = ", "session.on_chat = ");
	const std::string step = section(src, "void host_silence_step()", "void Manager::frame()");
	const std::string session_end = section(src, "void Manager::set_phase(Phase p)", "const char* Manager::build_id()");
	CHECK(session_end.find("host_silence_off(SilenceEnd::StoppedWaiting)") != std::string::npos);
	const std::regex recovery_line(R"(if \(reason == SilenceEnd::HostAnswered\)\s*::Msg\("\[coop\] the host answers again)");
	CHECK(std::regex_search(src, recovery_line));
	CHECK(step.find("SilenceEnd::HostAnswered") != std::string::npos);
	CHECK(step.find("\"[coop] the host does not answer") != std::string::npos);
	CHECK(step.find("drop_silent_host()") != std::string::npos);
	CHECK(disconnect.find("\"! [coop] disconnected: %s\"") != std::string::npos);
}

TEST(rep_log_server_world_bye_is_a_plain_client_line)
{
	using namespace coop;
	t::Node world("World", t::port(37290)), player("Player", t::port(37290));
	world.cfg.mode = SessionMode::Server;
	world.cfg.host_plays = false;
	REQUIRE(world.host());
	REQUIRE(player.connect(t::port(37290)));
	REQUIRE(t::pump_until({&world.s, &player.s}, 5000, [&] { return player.welcomed; }));
	world.s.shutdown("world stopped");
	REQUIRE(t::pump_until({&player.s}, 3000, [&] { return player.disconnected; }));
	CHECK_EQ(player.s.end_code(), std::string(kEndHostLeft));
	CHECK_EQ(player.disc_reason, std::string("world stopped"));

	const auto disconnect = section(game_source("coop/coop_manager.cpp"), "session.on_disconnected = ", "session.on_chat = ");
	const std::regex close_line(R"(if \(end_code == kEndHostLeft\)\s*::Msg\("\[coop\] the host closed the session: %s")");
	CHECK(std::regex_search(disconnect, close_line));
}

TEST(rep_log_content_refusal_is_plain_ascii)
{
	const auto reject = section(game_source("coop/coop_manager.cpp"), "session.on_rejected = ", "session.on_disconnected = ");
	CHECK(reject.find(" [coop] host refused: %s: %s") != std::string::npos ||
		reject.find("\"[coop] host refused: %s: %s") != std::string::npos);
	CHECK(reject.find("\"! [coop] host refused:") == std::string::npos);
	CHECK(reject.find("\"[coop] mod list differs:") != std::string::npos);
	CHECK(reject.find("\"!   ") == std::string::npos);
	CHECK(reject.find("\"[coop] autostart: no more connection attempts") != std::string::npos);
}

TEST(rep_log_save_refusals_are_plain)
{
	const auto save = game_source("coop/coop_autosave.cpp");
	CHECK(save.find("\"[coop] autosave (%s) skipped: the host's character is down") != std::string::npos);
	const auto console = game_source("console_commands.cpp");
	CHECK(console.find("\"[coop] saving is disabled on a co-op client") != std::string::npos);
}

TEST(rep_log_stalker_torso_fallback_is_plain_and_logs_each_visual_and_motion_once)
{
	const auto torso = section(game_source("stalker_animation_manager_update.cpp"),
		"IC void CStalkerAnimationManager::play_torso()", "void CStalkerAnimationManager::play_legs()");
	CHECK(torso.find("reported.emplace(visual, motion).second") != std::string::npos);
	CHECK(torso.find("\"[coop] stalker [%s] visual [%s]: torso motion [%s] is missing") != std::string::npos);
	CHECK(torso.find("no_object_animation(body_state())") != std::string::npos);
}

TEST(rep_log_script_animation_assert_names_the_item_model_and_animation_section)
{
	const auto anim = section(game_source("player_hud.cpp"), "u32 player_hud::script_anim_play(", "void player_hud::");
	CHECK(anim.find("r_string(section, \"item_visual\")") != std::string::npos);
	CHECK(anim.find("r_string(m_sect_name, \"item_visual\")") == std::string::npos);
	CHECK(std::regex_search(anim, std::regex(R"(R_ASSERT4\(M2.valid\(\), "[^"]+\[idle\]", section, item_visual)")));
}
