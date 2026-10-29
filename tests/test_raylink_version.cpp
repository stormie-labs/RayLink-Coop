// RayLink Engine identity (engine/src/xrCore/raylink_version.h, owner request 2026-10-29: the engine names itself as
// "RayLink Engine" with its build everywhere). The build number is RAYLINK_BUILD of raylink_build.h: 0 in the source
// tree (a development build), N only in the CI tree of a release build (tools/ci_sync.py --build N).
#include "test_util.h"

#include "../engine/src/xrCore/raylink_version.h"

using raylink::build_label;
using raylink::engine_version;
using raylink::game_line_with_engine;

TEST(raylink_build_label)
{
	CHECK_EQ(build_label(0), std::string("dev"));
	CHECK_EQ(build_label(-3), std::string("dev"));
	CHECK_EQ(build_label(1), std::string("b1"));
	CHECK_EQ(build_label(28), std::string("b28"));
	CHECK_EQ(build_label(130), std::string("b130"));
}

TEST(raylink_engine_version)
{
	CHECK_EQ(engine_version(28), std::string("RayLink Engine b28"));
	CHECK_EQ(engine_version(0), std::string("RayLink Engine dev"));
}

TEST(raylink_compile_time_literal_matches_runtime_helper)
{
	// The literal the engine shows (and package.ps1 looks for in the exe) says the same as the helper.
	CHECK_EQ(std::string(RAYLINK_ENGINE_VERSION), engine_version(RAYLINK_BUILD));
	CHECK_EQ(std::string(RAYLINK_BUILD_LABEL), build_label(RAYLINK_BUILD));
}

TEST(raylink_source_tree_is_a_dev_build)
{
	// A release number is written into the CI tree by tools/ci_sync.py --build N, never committed to the source tree:
	// a build without it must call itself "dev", not the last release.
	int source_tree_build = RAYLINK_BUILD; // a variable, not the literal: no "constant condition" warning
	CHECK_EQ(source_tree_build, 0);
	CHECK_EQ(std::string(RAYLINK_ENGINE_VERSION), std::string("RayLink Engine dev"));
}

TEST(raylink_game_line_keeps_the_game_first)
{
	// G.A.M.M.A. (its text overhaul defines ui_st_game_version) and stock Anomaly, eng and rus
	CHECK_EQ(game_line_with_engine("S.T.A.L.K.E.R. G.A.M.M.A. 0.9.5", "RayLink Engine b28"),
	         std::string("S.T.A.L.K.E.R. G.A.M.M.A. 0.9.5 | RayLink Engine b28"));
	CHECK_EQ(game_line_with_engine("S.T.A.L.K.E.R. Anomaly 1.5.3", "RayLink Engine dev"),
	         std::string("S.T.A.L.K.E.R. Anomaly 1.5.3 | RayLink Engine dev"));
	const std::string rus = "S.T.A.L.K.E.R. Anomaly 1.5.3 \xD0\xF3\xF1\xF1\xEA\xE0\xFF \xE2\xE5\xF0\xF1\xE8\xFF"; // cp1251
	CHECK_EQ(game_line_with_engine(rus, "RayLink Engine b28"), rus + " | RayLink Engine b28");

	// Mods detect G.A.M.M.A. by searching this line (utils_catspaw_common, item_radio): it must still be found
	const std::string gamma = game_line_with_engine("S.T.A.L.K.E.R. G.A.M.M.A. 0.9.5", "RayLink Engine b28");
	CHECK(gamma.find("G.A.M.M.A.") != std::string::npos);
	CHECK(gamma.rfind("S.T.A.L.K.E.R. G.A.M.M.A. 0.9.5", 0) == 0);
}

TEST(raylink_game_line_edge_cases)
{
	// Applied twice (a language reload builds the table again from the files, but a mod could feed it back): once.
	const std::string once = game_line_with_engine("S.T.A.L.K.E.R. Anomaly 1.5.3", "RayLink Engine b28");
	CHECK_EQ(game_line_with_engine(once, "RayLink Engine b28"), once);
	// No game line (a mod removed the string): the engine alone; no engine text: the game line untouched.
	CHECK_EQ(game_line_with_engine("", "RayLink Engine b28"), std::string("RayLink Engine b28"));
	CHECK_EQ(game_line_with_engine("S.T.A.L.K.E.R. Anomaly 1.5.3", ""), std::string("S.T.A.L.K.E.R. Anomaly 1.5.3"));
}
