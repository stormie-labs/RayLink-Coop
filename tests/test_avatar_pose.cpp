// Anomaly Coop unit tests: poses other players see on an avatar, read in the engine source. An avatar replays the exact
// third-person MotionIDs of its owner's CActor (coop_players.cpp capture -> drive_avatar), so the owner's
// CActor::g_SetAnimation (ActorAnimation.cpp) decides what everybody else sees. Also what an avatar holds and is
// called (coop_equip.cpp apply_equip) and what F does to it (ActorInput.cpp CActor::ActorUse).
#include "test_util.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>

namespace
{
// anomaly-coop/<rel>, the project root above this source file (tests\ -> ..), without '\r' (a checkout may have CRLF)
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// engine/src/xrGame/<name>, next to this source file (tests\ -> ..\engine\src\xrGame)
std::string game_source(const char* name) { return project_file(std::string("engine/src/xrGame/") + name); }

// The text from `from` to the next "default:" after it; "" if `from` is missing.
std::string block_from(const std::string& src, const std::string& from)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("default:", at);
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

// The text from `from` to the first `to` after it; "" if `from` is missing.
std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

constexpr size_t npos = std::string::npos;
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

// Owner, live 2026-10-29 (b29): "the PDA in the hands for others". The object handler plans only for weapons and
// missiles; the PDA goes to the avatar's left hand as an attachment (avatars only, the item stays in its inventory), and
// the avatar's section may attach the PDA sections (the engine compares exact names; '>' keeps the stalker list).
TEST(avatar_holds_the_pda_as_an_attachment)
{
	const std::string src = game_source("coop/coop_equip.cpp");
	REQUIRE(src.size() > 10000);
	const std::string apply = between(src, "bool apply_equip(", "\n}\n");
	REQUIRE(!apply.empty());
	CHECK(apply.find("held->cast_weapon() || held->cast_missile()") != npos);
	CHECK(apply.find("set_goal(MonsterSpace::eObjectActionIdle, planned ? in_hands : nullptr)") != npos);
	CHECK(apply.find("set_goal(MonsterSpace::eObjectActionIdle, in_hands)") == npos);
	CHECK(apply.find("show_pda(av, held)") != npos);

	const std::string show = between(src, "void show_pda(", "\n}\n");
	REQUIRE(!show.empty());
	CHECK(show.find("world::is_player_character(av)") != npos); // never an NPC
	CHECK(show.find("cast_pda()") != npos);
	CHECK(show.find("enable(true)") != npos);
	CHECK(show.find("enable(false)") != npos);
	CHECK(show.find("Ruck(") == npos); // the item stays where it is: no move in the inventory, no event
	CHECK(show.find("Slot(") == npos);
	CHECK(show.find("u_Event") == npos);

	const std::string ltx = project_file("gamedata/configs/mod_system_coop.ltx");
	const std::string avatar = between(ltx, "[coop_player_avatar]", "\n[");
	REQUIRE(!avatar.empty());
	const size_t at = avatar.find("\n>attachable_items");
	REQUIRE(at != npos);
	const std::string line = avatar.substr(at, avatar.find('\n', at + 1) - at);
	for (const char* pda : {"device_pda_1", "device_pda_2", "device_pda_3", "device_pda_milspec"})
		CHECK(line.find(pda) != npos);
	CHECK(avatar.find("\nattachable_items") == npos); // never a replacement of the inherited list
}

// Owner, live 2026-10-29 (b29): "remove interacting with each other on F". Reviving a wounded teammate stays (the two
// survival hooks run first); after them F on a player's character returns before the use callback, talk and search. A
// body being dragged is still let go.
TEST(avatar_use_key_only_revives)
{
	const std::string src = game_source("ActorInput.cpp");
	REQUIRE(src.size() > 10000);
	CHECK(src.find("#include \"coop/coop_world.h\"") != npos);
	const std::string use = between(src, "void CActor::ActorUse()", "\n}\n");
	REQUIRE(!use.empty());
	const size_t person = use.find("coop::survival::on_use_person(");
	const size_t nearby = use.find("coop::survival::on_use_nearby()");
	const size_t release = use.find("PHReleaseObject()");
	const size_t block = use.find("if (coop::world::is_player_character(m_pObjectWeLookingAt))");
	const size_t used = use.find("m_pUsableObject->use(this)");
	const size_t talk = use.find("TryToTalk()");
	const size_t search = use.find("StartCarBody(this, m_pPersonWeLookingAt)");
	REQUIRE(person != npos && nearby != npos && release != npos && block != npos);
	REQUIRE(used != npos && talk != npos && search != npos);
	CHECK(person < block && nearby < block);
	CHECK(release < block);
	CHECK(block < used && block < talk && block < search);
	CHECK(use.find("return;", block) < use.find("if (", block + 1));
}

// Owner, live 2026-10-29 (b29): "remove the random names on each other". Every machine gives each player's character
// its player's nick (game object and the server entity's display copy) with every PlayerEquip; the saved / sent name
// string of the server entity is not touched.
TEST(avatar_carries_its_player_nick)
{
	const std::string src = game_source("coop/coop_equip.cpp");
	REQUIRE(src.size() > 10000);
	const std::string name = between(src, "void apply_name(", "\n}\n");
	REQUIRE(!name.empty());
	CHECK(name.find("survival::nick_of(join::to_host(avatar_id))") != npos);
	CHECK(name.find("nametag::character_name(") != npos);
	CHECK(name.find("ChangeName(name)") != npos);
	CHECK(name.find("m_character_name = ") != npos);
	CHECK(name.find("m_character_name_str =") == npos);
	CHECK(between(src, "bool apply_equip(", "\n}\n").find("apply_name(avatar_id, av)") != npos);
}
