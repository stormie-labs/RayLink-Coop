// Anomaly Coop unit tests: poses other players see on an avatar, read in the engine source. An avatar replays the exact
// third-person MotionIDs of its owner's CActor (coop_players.cpp capture -> drive_avatar), so the owner's
// CActor::g_SetAnimation (ActorAnimation.cpp) decides what everybody else sees.
#include "test_util.h"

#include <fstream>
#include <iterator>
#include <string>

namespace
{
// engine/src/xrGame/<name>, next to this source file (tests\ -> ..\engine\src\xrGame)
std::string game_source(const char* name)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/" + name, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// The text from `from` to the next "default:" after it; "" if `from` is missing.
std::string block_from(const std::string& src, const std::string& from)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("default:", at);
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

// Live 2026-10-29 (b28, GAMMA): a player raised the 3D PDA to his face and the others saw his avatar look through
// binoculars. device_pda_1 and wpn_binoc share animation_slot 13, whose zoom / draw / holster torsos are the
// binoculars'. The PDA keeps its own hands pose in every state; binoculars (a CWeapon) and artefacts still use the slot.
TEST(avatar_pda_is_not_binoculars)
{
	const std::string src = game_source("ActorAnimation.cpp");
	REQUIRE(src.size() > 10000);
	const std::string pda = block_from(src, "case CPda::eIdle:");
	REQUIRE(!pda.empty());
	CHECK(pda.find("TW->") == std::string::npos);
	CHECK(pda.find("case CPda::eShowing:") != std::string::npos);
	CHECK(pda.find("case CPda::eHiding:") != std::string::npos);
	CHECK(pda.find("ST->m_torso[4].moving[moving_idx]") != std::string::npos);
	CHECK(src.find("case CWeapon::eIdle: M_torso = W->IsZoomed() ? TW->zoom") != std::string::npos);
	CHECK(src.find("case CArtefact::eActivating: M_torso = TW->zoom;") != std::string::npos);
}
