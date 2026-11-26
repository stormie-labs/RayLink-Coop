// Anomaly Coop unit tests: a client's pause while the host is silent ends by what was taken (coop_silence_pause.h).
// In a session the clock refuses to stop, so the device reads as not paused while the sound is. Ending by the device's word
// left every sound then playing paused for good: ambient gone, new sounds such as footsteps fine (live 2026-10-31).
#include "test_util.h"

#include "coop_silence_pause.h"

#include <fstream>
#include <iterator>
#include <string>

using coop::SilencePause;

namespace
{
// xrGame is outside the test binary: its wiring is checked against the source.
std::string manager_source()
{
	std::string path = __FILE__;
	path.resize(path.find_last_of("\\/") + 1);
	std::ifstream in(path + "../engine/src/xrGame/coop/coop_manager.cpp", std::ios::binary);
	REQUIRE(in.good());
	return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::string between(const std::string& src, const char* first, const char* next)
{
	const size_t begin = src.find(first);
	REQUIRE(begin != std::string::npos);
	const size_t end = src.find(next, begin + 1);
	REQUIRE(end != std::string::npos);
	return src.substr(begin, end - begin);
}
} // namespace

TEST(silence_pause_takes_it_once)
{
	SilencePause p;
	CHECK(!p.waiting);
	CHECK(p.begin(false));
	CHECK(p.waiting);
	CHECK(!p.begin(false)); // the next frames of the same silence
}

TEST(silence_pause_gives_back_what_it_took_whatever_the_device_says)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end()); // the session's device still reads as not paused here: the sound comes back all the same
	CHECK(!p.waiting);
}

TEST(silence_pause_leaves_a_pause_that_was_not_its_own)
{
	SilencePause p;
	CHECK(!p.begin(true)); // somebody else paused the device: nothing is taken
	CHECK(p.waiting);
	CHECK(!p.end()); // and nothing is given back
	CHECK(!p.waiting);
}

TEST(silence_pause_ends_once)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end());
	CHECK(!p.end());
}

TEST(silence_pause_works_again_after_an_end)
{
	SilencePause p;
	CHECK(p.begin(false));
	CHECK(p.end());
	CHECK(p.begin(false));
	CHECK(p.end());
}

// Audit H4 (2026-10-31): the Pause key toggled by the device's word. In a session that word is always "not paused", so each
// press took the sound's pause and none gave it back: what played at that moment stayed paused for good.
TEST(pause_key_works_only_where_the_clock_can_stop)
{
	CHECK(coop::pause_key_acts(true));
	CHECK(!coop::pause_key_acts(false));
}

// Manager::frame() stops at Phase::Off before host_silence_step, so a pause still taken when the session ends would hold
// the device until a later session's first frame lifts it, in another context. set_phase(Off) lifts it: every end of a
// session passes there - the player's own leave (stop: coop_disconnect, the menu, an invite), the link's, a refusal.
TEST(silence_pause_is_lifted_by_every_end_of_a_session)
{
	const std::string src = manager_source();
	const std::string frame = between(src, "void Manager::frame()", "void Manager::print_status()");
	const size_t off_return = frame.find("if (m_phase == Phase::Off)");
	const size_t step = frame.find("host_silence_step();");
	REQUIRE(off_return != std::string::npos);
	REQUIRE(step != std::string::npos);
	CHECK(off_return < step);
	const std::string set_phase = between(src, "void Manager::set_phase(Phase p)", "const char* Manager::build_id()");
	const std::string off_branch = between(set_phase, "if (p == Phase::Off)", "m_roles = roles_of(p);");
	CHECK(off_branch.find("host_silence_off(SilenceEnd::StoppedWaiting)") != std::string::npos);
	const char* const ends[][2] = {
		{"void Manager::stop(", "void Manager::send_chat("},
		{"session.on_disconnected = ", "session.on_chat = "},
		{"session.on_rejected = ", "session.on_disconnected = "},
	};
	for (const auto& end : ends)
		CHECK(between(src, end[0], end[1]).find("set_phase(Phase::Off)") != std::string::npos);
}
