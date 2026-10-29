// Anomaly Coop unit tests: the head torch of another player (coop_equip.cpp), read in the engine source.
// Live 2026-10-29 (b29): the head torch of the host's avatar lit the ground beside it "who knows where", and a headlamp
// given to the other player kept shining from where its old holder wore it. No torch item is ever attached to an
// avatar's head (GAMMA's device_torch_dummy / _nv_* are not in the stalker's attachable_items; CAI_Stalker::can_attach
// wants enable(true), which only sr_light gives an NPC), and a backpack item gets no CTorch::Update: a lit one shone from
// wherever the item last was on that machine. The items stay dark; the owner's head torch is drawn at the head, aimed
// where the player looks, and the AI reads the owner's flag instead of the item.
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

TEST(avatar_torch_items_stay_dark)
{
	const std::string src = game_source("coop/coop_equip.cpp");
	REQUIRE(src.size() > 10000);
	const std::string apply = between(src, "bool apply_equip(", "\n}\n");
	REQUIRE(!apply.empty());
	CHECK(apply.find("Switch(e.torch)") == npos); // every CTorch of the inventory, lit wherever it last was
	CHECK(apply.find("Switch(true)") == npos);
	CHECK(apply.find("torch->Switch(false)") != npos);
}

TEST(avatar_head_torch_is_drawn_at_the_head_where_the_player_looks)
{
	const std::string src = game_source("coop/coop_equip.cpp");
	REQUIRE(src.size() > 10000);
	const std::string frame = between(src, "void hand_light_frame()", "\n}\n");
	REQUIRE(!frame.empty());
	CHECK(frame.find("g_head_lights") != npos);
	CHECK(frame.find("it.second.torch") != npos);
	CHECK(frame.find("e->second.torch") != npos); // goes out with the owner's torch
	CHECK(frame.find("make_head_light(av)") != npos);

	const std::string make = between(src, "HandLight* make_head_light(", "\n}\n");
	REQUIRE(!make.empty());
	CHECK(make.find("l->head = true") != npos);
	CHECK(make.find("l->offset = kHeadLampOffset") != npos);
	CHECK(src.find("kHeadLampOffset = {0.134f, -0.007f, 0.09f}") != npos); // stock device_torch on bip01_head

	const std::string place = between(src, "void place_light(", "\n}\n");
	REQUIRE(!place.empty());
	CHECK(place.find("l->head ? \"bip01_head\" : \"bip01_l_hand\"") != npos);
	CHECK(place.find("transform_tiny(pos, l->offset)") != npos);
	CHECK(place.find("avatar_view(av->ID(), view_yaw, view_pitch)") != npos);
	CHECK(place.find("dir.setHP(view_yaw, -view_pitch)") != npos); // CTorch's own actor branch: setHP(-cam.yaw, -cam.pitch)
	CHECK(between(src, "void destroy_lights()", "\n}\n").find("g_head_lights.clear()") != npos);
}

TEST(ai_light_of_a_player_reads_his_head_torch_flag)
{
	const std::string ai = game_source("coop/coop_ai.cpp");
	REQUIRE(ai.size() > 5000);
	const std::string est = between(ai, "float estimate_light(", "\n}\n");
	REQUIRE(!est.empty());
	CHECK(est.find("p.headlamp = players::avatar_headlamp(obj->ID());") != npos);
	CHECK(est.find("p.headlamp = false;") == npos);
	CHECK(game_source("coop/coop_players.h").find("bool avatar_headlamp(u16 avatar_id);") != npos);
	const std::string acc = between(game_source("coop/coop_equip.cpp"), "bool avatar_headlamp(u16 avatar_id)", "\n}\n");
	REQUIRE(!acc.empty());
	CHECK(acc.find("it->second.torch") != npos);
}
