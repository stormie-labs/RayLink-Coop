// Anomaly Coop unit tests: the head torch of an NPC puppet on a client (coop_entities.cpp), read in the engine source.
// Found 2026-10-30 with the avatar headlamp (b29): the host's Lua (sr_light) spawns a device_torch into the NPC and wears
// it (enable_attachable_item -> CObjectHandler::attach, which lights it); the snapshot carries only "lit". A puppet runs
// no binder, so its copy of the torch was never attached: the light went on in the backpack, where the item gets no head
// transform, and shone from wherever the item last was on that machine. The puppet now wears the torch the host lights
// (only a section its attachable_items allow, as sr_light's) and takes it off when the host's goes dark.
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

std::string game_source(const char* name) { return project_file(std::string("engine/src/xrGame/") + name); }

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

TEST(puppet_torch_is_one_the_npc_can_wear)
{
	const std::string src = game_source("coop/coop_entities.cpp");
	REQUIRE(src.size() > 10000);
	const std::string pick = between(src, "CTorch* puppet_torch(", "\n}\n");
	REQUIRE(!pick.empty());
	CHECK(pick.find("attached_torch(obj)") != npos); // the one already on the head first
	CHECK(pick.find("may_attach(") != npos); // else only a section of its attachable_items (sr_light's device_torch)

	const std::string owner = game_source("attachment_owner.h");
	CHECK(owner.find("bool may_attach(const shared_str& section) const;") != npos);
	const std::string body = between(game_source("attachment_owner.cpp"), "bool CAttachmentOwner::may_attach(", "\n}\n");
	REQUIRE(!body.empty());
	CHECK(body.find("m_attach_item_sections") != npos);
}

TEST(puppet_wears_the_torch_the_host_lights)
{
	const std::string src = game_source("coop/coop_entities.cpp");
	REQUIRE(src.size() > 10000);
	const std::string apply = between(src, "bool apply_creature_flags(", "\n}\n");
	REQUIRE(!apply.empty());
	CHECK(apply.find("if (lit != stalker->attached(t))") != npos);
	CHECK(apply.find("t->enable(lit)") != npos); // lit: worn on the head bone; dark on the host: off the head here too
	CHECK(apply.find("const bool worn = stalker->attached(t);") != npos);
	CHECK(apply.find("t->enable(false)") != npos);
	CHECK(apply.find("t->enable(false)") > apply.find("const bool worn")); // a refused attach leaves no enabled flag
	CHECK(apply.find("t->Switch(lit && worn)") != npos); // never a light in the backpack
	CHECK(apply.find("t->Switch(lit);") == npos);
	CHECK(apply.find("if (lit && !worn && stalker->g_Alive())") != npos); // not worn yet: try again later
}
