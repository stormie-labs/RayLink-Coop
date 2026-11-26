// The story group's mode answers must preserve the six process kinds' behavior.
#include "test_util.h"

#include "coop_roles.h"
#include "coop_task_target.h"
#include "support/fake_mode.h"

#include <fstream>
#include <sstream>
#include <string>

namespace
{
using namespace coop;

void check_story_mode(const t::ModeCase& c)
{
	t::FakeMode mode(c);
	const uint8_t old_roles = c.answers.roles;
	const bool active = old_roles != 0;
	const bool authority = mode.decides_world() || mode.leads_level();
	CHECK_EQ(mode.decides_world(), has(old_roles, ProcessRole::WorldServer));
	// In particular the world server still keeps talk locks and the lamp/sound authority branches.
	CHECK_EQ(authority, has(old_roles, ProcessRole::MapAuthority));
	// A map server still consumes the world's clock and weather updates.
	CHECK_EQ(active && !mode.decides_world(), has(old_roles, ProcessRole::WorldClient));
	CHECK_EQ(active && mode.actor_is_player(), has(old_roles, ProcessRole::Player));

	// An online squad without a local game object follows the host's place on a mirror.
	const task_target::Here squad{true, true, false, false, authority};
	const auto expected = has(old_roles, ProcessRole::MapAuthority) ? task_target::Take::Own : task_target::Take::Online;
	CHECK_EQ(task_target::take(squad), expected);
	// An offline copy still takes its place from the world, even on a level this process leads.
	const task_target::Here offline{true, false, false, false, authority};
	CHECK_EQ(task_target::take(offline), task_target::Take::Offline);
}

std::string source(const char* filename)
{
	const std::string self = __FILE__;
	const size_t slash = self.find_last_of("/\\");
	const std::string tests = slash == std::string::npos ? "tests" : self.substr(0, slash);
	std::ifstream file(tests + "/../engine/src/xrGame/coop/" + filename);
	std::ostringstream content;
	content << file.rdbuf();
	return content.str();
}
} // namespace

#define STORY_MODE_TEST(name) TEST(story_s6_##name) { check_story_mode(t::mode_case(#name)); }
MODE_CASES(STORY_MODE_TEST)
#undef STORY_MODE_TEST

// The native runner cannot link xrGame. Check the hand-offs in the consumer as well as the mode answers above.
TEST(story_s6_routes_story_hashes_tasks_and_ghost_words_through_mode)
{
	const auto story = source("coop_story.cpp");
	const auto tasks = source("coop_story_tasks.cpp");
	const auto relations = source("coop_story_relations.cpp");
	CHECK(story.find("!mode().reaches(p.id, Msg::StoryHash)") != std::string::npos);
	CHECK(tasks.find("mode().reaches(p.id, type) && may_see(p.id, id)") != std::string::npos);
	CHECK(tasks.find("mode().deliver_links(type, w, Lane::Reliable)") != std::string::npos);
	CHECK(story.find("mode().deliver_links(Msg::StoryHash, w, Lane::Reliable)") != std::string::npos);
	CHECK(relations.find("if (!mode().ghost_said(s))") != std::string::npos);
	CHECK(relations.find("g_action_depth > 0 && !mode().leads_level()") != std::string::npos);
}

TEST(story_s6_keeps_world_and_level_authority)
{
	const std::string authority = "mode().decides_world() || mode().leads_level()";
	for (const char* filename : {"coop_dialog.cpp", "coop_lamps.cpp", "coop_sound.cpp", "coop_worldstate.cpp"})
	{
		const auto found = source(filename).find(authority);
		if (found == std::string::npos)
			t::report_failure(__FILE__, __LINE__, std::string(filename) + ": missing the world/level authority check");
	}
	// Do not replace the clock/sky receiver gate with a player-mirror check.
	const auto world = source("coop_worldstate.cpp");
	CHECK(world.find("from != kHostPeer || !mgr().active() || mode().decides_world()") != std::string::npos);
}

TEST(story_s6_debug_keeps_log_and_answers_through_the_layer)
{
	const auto debug = source("coop_debug.cpp");
	const size_t log = debug.find("::Msg(\"%s\", line);");
	REQUIRE(log != std::string::npos);
	const auto body_end = debug.find('}', log);
	REQUIRE(body_end != std::string::npos);
	CHECK(debug.substr(log, body_end - log).find("coop::console_line(line);") != std::string::npos);
}
