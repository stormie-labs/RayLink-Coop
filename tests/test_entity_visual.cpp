// Anomaly Coop unit tests: a host creature that takes a new visual (Msg::EntityVisual, protocol 17).
// Found 2026-10-29 with the NPC T-pose (b29), fixed 2026-10-30: GE_CHANGE_VISUAL of an online NPC (Lua set_visual_name:
// disguises, mods that dress NPCs) changed the model on the host only. The motion ids of the snapshots belong to the
// host's visual and their order differs between stalker models (25 orders among GAMMA's stalker ogf), so the puppet that
// kept the old model played other motions or none. The host's server now reports the change, the host sends the new
// visual of a creature (never a player's character: PlayerEquip carries those), and a client changes its puppet the way
// the host's Lua did, or its server entity when the creature is offline there.
#include "test_util.h"

#include "coop_protocol.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>

using namespace coop;

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

bool read_back(const EntityVisualMsg& m, EntityVisualMsg& out)
{
	Writer w(64);
	m.write(w);
	Reader r(w.ptr(), w.size());
	return out.read(r);
}
} // namespace

TEST(entity_visual_is_a_new_host_message)
{
	CHECK(static_cast<uint16_t>(Msg::EntityVisual) == 0x012D);
	CHECK_EQ(std::string(msg_name(uint16_t(0x012D))), std::string("EntityVisual"));
	CHECK(kProtocolVersion >= 17u);
}

TEST(entity_visual_round_trip)
{
	EntityVisualMsg m;
	m.object = 4321;
	m.visual = "actors\\stalker_bandit\\stalker_bandit_3";
	EntityVisualMsg back;
	CHECK(read_back(m, back));
	CHECK_EQ(back.object, uint16_t(4321));
	CHECK_EQ(back.visual, m.visual);

	m.visual = "actors/Stalker_Neutral/stalker_neutral-1a.ogf"; // mods spell paths in other ways
	CHECK(read_back(m, back));
	CHECK_EQ(back.visual, m.visual);
}

TEST(entity_visual_refuses_what_is_not_a_model_name)
{
	EntityVisualMsg m;
	m.object = 7;
	EntityVisualMsg back;
	for (const char* bad : {"", "\\actors\\x", ".hidden", "actors\\..\\..\\fsgame", "c:\\models\\x", "$game_meshes$\\x",
	         "actors\\x\ty", "actors\\x\ny"})
	{
		m.visual = bad;
		CHECK(!m.valid());
		CHECK(!read_back(m, back));
	}
	m.visual.assign(EntityVisualMsg::kMaxVisual + 1, 'a');
	CHECK(!read_back(m, back));
	m.visual.assign(EntityVisualMsg::kMaxVisual, 'a');
	CHECK(read_back(m, back));

	const uint8_t cut[] = {0x07, 0x00}; // object only, no name
	Reader r(cut, sizeof(cut));
	CHECK(!back.read(r));
}

TEST(host_server_reports_a_visual_change)
{
	const std::string src = game_source("xrServer_process_event.cpp");
	REQUIRE(src.size() > 1000);
	const std::string ev = between(src, "case GE_CHANGE_VISUAL:", "break;");
	REQUIRE(!ev.empty());
	CHECK(ev.find("visual->set_visual(tmp);") != npos);
	CHECK(ev.find("coop::events::host_on_visual(receiver->ID);") != npos);
	CHECK(ev.find("set_visual(tmp)") < ev.find("host_on_visual("));
	CHECK(game_source("coop/coop_events.h").find("void host_on_visual(u16 id);") != npos);
}

TEST(host_sends_the_visual_of_a_creature_only)
{
	const std::string src = game_source("coop/coop_events.cpp");
	REQUIRE(src.size() > 10000);
	const std::string hook = between(src, "void host_on_visual(u16 id)", "\n}\n");
	REQUIRE(!hook.empty());
	CHECK(hook.find("mgr().is_host()") != npos);
	CHECK(hook.find("g_lock") != npos); // xrServer hooks may run on a game thread

	const std::string send = between(src, "void host_send_visual(u16 id)", "\n}\n");
	REQUIRE(!send.empty());
	CHECK(send.find("remote::is_puppet_type(obj)") != npos); // stalkers, monsters, traders
	CHECK(send.find("world::is_player_character(obj)") != npos); // PlayerEquip carries players' visuals
	CHECK(send.find("obj->cNameVisual()") != npos); // the visual the host's game object took
	CHECK(send.find("net::host_broadcast(Msg::EntityVisual, w)") != npos);
	CHECK(between(src, "void host_flush()", "\n}\n").find("host_send_visual(") != npos);
	CHECK(between(src, "void host_discard()", "\n}\n").find("g_visuals.clear()") != npos);
}

TEST(client_changes_the_puppet_as_the_host_lua_did)
{
	const std::string src = game_source("coop/coop_events.cpp");
	REQUIRE(src.size() > 10000);
	const std::string apply = between(src, "void client_on_entity_visual(", "\n}\n");
	REQUIRE(!apply.empty());
	CHECK(apply.find("before_live(Msg::EntityVisual)") != npos);
	CHECK(apply.find("m.read(r)") != npos);
	CHECK(apply.find("join::to_local(m.object)") != npos);
	CHECK(apply.find("world::is_player_character(obj)") != npos);
	CHECK(apply.find("entities::ClientApply scope;") != npos);
	CHECK(apply.find("set_visual_name(m.visual.c_str(), false)") != npos); // GE_CHANGE_VISUAL + ChangeVisual, as there
	CHECK(apply.find("->visual()") != npos); // offline here: the server entity spawns it with the new one
	CHECK(apply.find("set_visual(m.visual.c_str())") != npos);
	CHECK(src.find("e.on(Msg::EntityVisual,") != npos);
}
