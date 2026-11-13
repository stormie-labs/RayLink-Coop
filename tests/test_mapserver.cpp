// Anomaly Coop unit tests: the map servers, the pure part (xrCoop/coop_mapserver_rules.h). The bridges and their ids, the key
// -coop_mapserver, the fsgame of a map server, who may connect as one, which message goes where, and who stands on its level.
#include "test_util.h"

#include "coop_mapserver_rules.h"

#include <string>
#include <vector>

using namespace coop;
using namespace coop::mapserver;

namespace
{
constexpr uint16_t kGarbage = 2;
constexpr uint16_t kCordon = 1;

Token token_of(uint8_t first)
{
	Token t{};
	for (size_t i = 0; i < t.size(); ++i)
		t[i] = uint8_t(first + i * 17);
	return t;
}

levels::wire::LevelMapMsg::Player row(uint32_t peer, uint16_t level, uint16_t proxy, bool in_world)
{
	levels::wire::LevelMapMsg::Player r;
	r.peer = peer;
	r.level = level;
	r.proxy = proxy;
	r.in_world = in_world ? 1 : 0;
	return r;
}
} // namespace

// ---------------------------------------------------------------- bridges

TEST(bridge_ids_are_no_player_slots)
{
	for (uint32_t k = 1; k <= kMaxBridges; ++k)
	{
		CHECK(is_bridge(bridge_peer(k)));
		CHECK_EQ(bridge_index(bridge_peer(k)), k);
		CHECK(bridge_peer(k) >= kMaxPeerSlots);
	}
	// every player slot, a world server's 8th client (slot 8) included
	CHECK_EQ(kMaxPeerSlots, uint32_t(9));
	for (PeerId slot = 0; slot < kMaxPeerSlots; ++slot)
		CHECK(!is_bridge(slot));
	CHECK(!is_bridge(PeerId(8)));
	CHECK(!is_bridge(kBridgeBase));
	CHECK(!is_bridge(bridge_peer(kMaxBridges + 1)));
	CHECK(!is_bridge(kInvalidPeer));
	CHECK_EQ(bridge_index(3), 0u);
}

// A crash: the process is gone, the new one of the same number loads, and only then the old connection times out.
TEST(bridge_link_the_end_of_an_old_connection_says_nothing_about_a_new_process)
{
	BridgeLink l;
	CHECK(!l.left()); // nothing connected: a process that never said Hello
	l.joined();
	CHECK(l.linked());
	l.cut(); // its process is given up on
	CHECK(!l.left());
	l.joined();
	CHECK(l.left()); // the running process's own connection
	CHECK(!l.left()); // once
}

// ---------------------------------------------------------------- the key

TEST(args_round_trip)
{
	Args a;
	a.level = 12;
	a.graph = 3456;
	a.port = 27960;
	a.token = token_of(3);
	const std::string line = "x:\\game\\bin\\anomaly.exe -fsltx fsgame_ms1.ltx " + key_text(a) + " -nosound";
	Args b;
	REQUIRE(parse_args(line.c_str(), b));
	CHECK_EQ(int(b.level), 12);
	CHECK_EQ(int(b.graph), 3456);
	CHECK_EQ(int(b.port), 27960);
	CHECK(b.token == a.token);
}

TEST(args_the_key_may_end_the_line)
{
	Args a;
	a.level = 0;
	a.graph = 0;
	a.port = 1;
	a.token = token_of(200);
	Args b;
	REQUIRE(parse_args(key_text(a).c_str(), b));
	CHECK(b.token == a.token);
}

TEST(args_anything_wrong_is_no_map_server)
{
	const std::string good = token_hex(token_of(1));
	Args out;
	out.level = 77;
	CHECK(!parse_args(nullptr, out));
	CHECK(!parse_args("", out));
	CHECK(!parse_args("-coop_host", out));
	CHECK(!parse_args("-coop_mapserver", out));
	CHECK(!parse_args("-coop_mapserver 1 2", out));
	CHECK(!parse_args(("-coop_mapserver 1 2 0 " + good).c_str(), out)); // port 0
	CHECK(!parse_args(("-coop_mapserver 1 2 70000 " + good).c_str(), out));
	CHECK(!parse_args(("-coop_mapserver 65535 2 3 " + good).c_str(), out)); // no level
	CHECK(!parse_args(("-coop_mapserver x 2 3 " + good).c_str(), out));
	CHECK(!parse_args("-coop_mapserver 1 2 3 abcd", out)); // a short token
	CHECK(!parse_args(("-coop_mapserver 1 2 3 " + good + "0").c_str(), out)); // a long one
	CHECK(!parse_args(("-coop_mapserver 1 2 3 " + std::string(32, 'g')).c_str(), out));
	CHECK(!parse_args(("-coop_mapserverx 1 2 3 " + good).c_str(), out)); // another key
	CHECK(!parse_args(("x-coop_mapserver 1 2 3 " + good).c_str(), out));
	CHECK_EQ(int(out.level), 77); // left as it was
}

TEST(args_a_longer_key_before_the_real_one_is_passed_over)
{
	Args a;
	a.level = 4;
	a.graph = 5;
	a.port = 6;
	a.token = token_of(9);
	const std::string line = "-coop_mapserver_x 1 " + key_text(a);
	Args b;
	REQUIRE(parse_args(line.c_str(), b));
	CHECK_EQ(int(b.level), 4);
}

// ---------------------------------------------------------------- fsgame

TEST(fsltx_of_the_command_line)
{
	CHECK(fsltx_of("x.exe -fsltx fsgame_a.ltx -smap2048") == "fsgame_a.ltx");
	CHECK(fsltx_of("x.exe -fsltx fsgame_a.ltx") == "fsgame_a.ltx");
	CHECK(fsltx_of("x.exe -smap2048") == "fsgame.ltx");
	CHECK(fsltx_of(nullptr) == "fsgame.ltx");
	CHECK(fsltx_name("fsgame_a.ltx", 1) == "fsgame_ms1.ltx");
	CHECK(fsltx_name("..\\fsgame.ltx", 3) == "..\\fsgame_ms3.ltx");
	CHECK(fsltx_name("C:/game/fsgame_b.ltx", 2) == "C:/game/fsgame_ms2.ltx");
}

TEST(fsgame_a_map_server_has_its_own_appdata_and_the_hosts_game)
{
	const std::string text =
	    "$mnt_point$=\r\n"
	    "; $app_data_root$ = in a comment\r\n"
	    "$game_data$ = false| true| $fs_root$| gamedata\\\r\n"
	    "$app_data_root$ = false | false | $fs_root$ | appdata_a\\\r\n"
	    "$game_saves$ = true| false| $app_data_root$| savedgames\\\r\n";
	std::string out, dir;
	REQUIRE(rewrite_fsgame(text, 2, out, dir));
	CHECK(dir == "appdata_ms2\\");
	CHECK(out.find("$app_data_root$ = false | false | $fs_root$ | appdata_ms2\\\r\n") != std::string::npos);
	// every other line stands, byte for byte: the same gamedata
	CHECK(out.find("$game_data$ = false| true| $fs_root$| gamedata\\\r\n") != std::string::npos);
	CHECK(out.find("$game_saves$ = true| false| $app_data_root$| savedgames\\\r\n") != std::string::npos);
	CHECK(out.find("; $app_data_root$ = in a comment\r\n") != std::string::npos);
	CHECK(out.find("appdata_a") == std::string::npos);
}

TEST(fsgame_forms_of_the_line)
{
	std::string out, dir;
	REQUIRE(rewrite_fsgame("$app_data_root$=false|false|$fs_root$|appdata\\", 1, out, dir));
	CHECK(out == "$app_data_root$=false|false|$fs_root$|appdata_ms1\\");
	REQUIRE(rewrite_fsgame("  $app_data_root$ = false | false | D:\\Game\\appdata   \n", 3, out, dir));
	CHECK(dir == "D:\\Game\\appdata_ms3\\");
	CHECK(out == "  $app_data_root$ = false | false | D:\\Game\\appdata_ms3\\   \n");
	CHECK(!rewrite_fsgame("$game_data$ = false| true| $fs_root$| gamedata\\\n", 1, out, dir));
	CHECK(!rewrite_fsgame("", 1, out, dir));
}

TEST(user_ltx_a_map_server_keeps_the_hosts_and_needs_no_screen)
{
	const std::string out = map_server_user_ltx("rs_screenmode fullscreen\r\nsnd_volume_eff 1.\r\nvid_mode 2560x1440\r\ng_always_active off\r\n");
	CHECK(out.find("snd_volume_eff 1.\r\n") != std::string::npos);
	CHECK(out.find("fullscreen") == std::string::npos);
	CHECK(out.find("2560x1440") == std::string::npos);
	CHECK(out.find("rs_screenmode windowed\r\n") != std::string::npos);
	CHECK(out.find("vid_mode 640x480\r\n") != std::string::npos);
	CHECK(out.find("g_always_active on\r\n") != std::string::npos);
	CHECK(map_server_user_ltx("").find("g_always_active on") != std::string::npos); // the host has none yet
	CHECK(map_server_user_ltx("vid_mode_x 1\n").find("vid_mode_x 1\r\n") != std::string::npos); // another key
}

// Read from the console of the owner's map servers (2026-11-13): "! Unknown command: g_unlimitedammo", "log_missing_ini", "ph_gravity"
// at every start. The world server runs with -dbg, which registers them, and saves them; a map server runs without it.
TEST(user_ltx_a_map_server_gets_no_command_only_a_debug_game_knows)
{
	const std::string out = map_server_user_ltx("g_god off\r\ng_unlimitedammo off\r\nph_gravity 19.62\r\nlog_missing_ini off\r\ng_end_modif 1.\r\nsnd_volume_eff 1.\r\n");
	CHECK(out.find("g_god") == std::string::npos);
	CHECK(out.find("g_unlimitedammo") == std::string::npos);
	CHECK(out.find("ph_gravity") == std::string::npos);
	CHECK(out.find("log_missing_ini") == std::string::npos);
	CHECK(out.find("g_end_modif") == std::string::npos);
	CHECK(out.find("snd_volume_eff 1.\r\n") != std::string::npos);
	CHECK(map_server_user_ltx("g_god_extra 1\n").find("g_god_extra 1\r\n") != std::string::npos); // another key
}

TEST(command_tail_holds_what_the_key_needs)
{
	Args a;
	a.level = 7;
	a.graph = 8;
	a.port = 9;
	a.token = token_of(5);
	const std::string tail = command_tail(a, 4, "fsgame_ms4.ltx");
	CHECK(tail.find("-fsltx fsgame_ms4.ltx ") != std::string::npos);
	Args b;
	REQUIRE(parse_args(tail.c_str(), b));
	CHECK(b.token == a.token);
	CHECK(fsltx_of(tail.c_str()) == "fsgame_ms4.ltx");
}

TEST(command_tail_a_map_server_has_its_sounds)
{
	// -nosound leaves a sound with no file and no length: its players hear nothing of the level, its scripts' sound_end comes at once.
	// The silent core is the engine's own choice for this key (x_ray.cpp, psSoundSilent).
	Args a;
	a.token = token_of(5);
	CHECK(command_tail(a, 1, "fsgame_ms1.ltx").find("-nosound") == std::string::npos);
}

// ---------------------------------------------------------------- who may connect

TEST(hello_only_the_loopback_with_an_issued_token)
{
	CHECK(hello_verdict(true, true) == HelloVerdict::Accept);
	CHECK(hello_verdict(true, false) == HelloVerdict::BadToken);
	CHECK(hello_verdict(false, true) == HelloVerdict::NotLoopback);
	CHECK(hello_verdict(false, false) == HelloVerdict::NotLoopback);
	CHECK(loopback_address("127.0.0.1:50123"));
	CHECK(!loopback_address("192.168.1.5:50123"));
	CHECK(!loopback_address("10.127.0.1:50123"));
	CHECK(!loopback_address(""));
}

// ---------------------------------------------------------------- which message goes where

TEST(incoming_split_off_or_on_the_hosts_level_everything_as_always)
{
	for (uint32_t v = 0; v <= 0xffff; ++v)
	{
		const Msg m = Msg(uint16_t(v));
		if (!scope_listed(m))
			continue;
		for (const bool has : {false, true})
		{
			Incoming a = route_incoming(m, false, false, has);
			CHECK(a.here && !a.tunnel);
			a = route_incoming(m, true, true, has);
			CHECK(a.here && !a.tunnel);
		}
	}
}

TEST(incoming_a_map_message_goes_to_the_map_server_and_never_acts_here)
{
	for (const Msg m : {Msg::PlayerState, Msg::PlayerShot, Msg::ReqTake, Msg::DialogLock, Msg::TradeOp, Msg::EntityEvent})
	{
		const Incoming a = route_incoming(m, true, false, true);
		CHECK(a.tunnel);
		CHECK(!a.here);
		const Incoming no = route_incoming(m, true, false, false); // his map server is not up yet: nobody to act on it
		CHECK(!no.tunnel);
		CHECK(!no.here);
	}
}

TEST(incoming_his_own_data_goes_to_the_map_server_and_stays_for_the_save)
{
	for (const Msg m : {Msg::PlayerVitals, Msg::PlayerEquip, Msg::ItemState})
	{
		const Incoming a = route_incoming(m, true, false, true);
		CHECK(a.tunnel);
		CHECK(a.here);
	}
}

TEST(incoming_a_world_message_stays_here_and_what_touches_his_body_goes_on_too)
{
	for (const Msg m : {Msg::InfoPortion, Msg::ReqMoney, Msg::JoinRequest, Msg::LevelMove, Msg::SyncRequest})
	{
		const Incoming a = route_incoming(m, true, false, true);
		CHECK(a.here);
		CHECK(!a.tunnel);
	}
	for (const Msg m : {Msg::PlayerWounded, Msg::PlayerRevive, Msg::PlayerDied, Msg::CheckpointClaim, Msg::RestRequest})
	{
		const Incoming a = route_incoming(m, true, false, true);
		CHECK(a.here);
		CHECK(a.tunnel);
	}
}

TEST(bridge_takes_the_world_and_the_registry_not_the_stream_of_the_hosts_level)
{
	for (const Msg m : {Msg::TimeSync, Msg::InfoPortion, Msg::Emission, Msg::LevelMap, Msg::AvatarList, Msg::TaskList})
		CHECK(bridge_takes(m));
	for (const Msg m : {Msg::EntitySpawn, Msg::EntityDestroy, Msg::EntityParent, Msg::EntitySquad})
		CHECK(bridge_takes(m));
	for (const Msg m : {Msg::EntitySnapshot, Msg::PlayerState, Msg::EntitySwitch, Msg::ZoneState, Msg::Chat, Msg::PeerList,
	         Msg::WeatherSync, Msg::Thunderbolt})
		CHECK(!bridge_takes(m));
}

TEST(a_map_server_says_nothing_of_a_body_it_does_not_have)
{
	for (const Msg m : {Msg::PlayerState, Msg::PlayerVitals, Msg::PlayerEquip, Msg::PlayerShot, Msg::ReqTake, Msg::EntityEvent})
		CHECK(!map_server_sends(m));
	for (const Msg m : {Msg::ReqMoney, Msg::JoinRequest, Msg::WorldLoaded, Msg::InfoPortion, Msg::LevelXferUp, Msg::LevelEntity,
	         Msg::LevelHash, Msg::MapServerState, Msg::SyncRequest})
		CHECK(map_server_sends(m));
}

TEST(tunnel_lane_both_ways)
{
	for (const Lane l : {Lane::Reliable, Lane::Unreliable, Lane::Bulk})
		CHECK(tunnel_lane(tunnel_lane_flags(l)) == l);
}

// ---------------------------------------------------------------- the players of a map server

TEST(virtual_peers_a_player_comes_loads_and_leaves)
{
	VirtualPeers v;
	VirtualPeers::Change c = v.update(kGarbage, {row(1, kCordon, 500, true), row(2, kGarbage, 501, false)});
	REQUIRE(c.came.size() == 1);
	CHECK_EQ(c.came[0].peer, 2u);
	CHECK_EQ(int(c.came[0].proxy), 501);
	CHECK(c.in_world.empty());
	CHECK(c.left.empty());

	c = v.update(kGarbage, {row(1, kCordon, 500, true), row(2, kGarbage, 501, false)});
	CHECK(c.came.empty()); // the same table says nothing
	CHECK(c.in_world.empty());

	c = v.update(kGarbage, {row(2, kGarbage, 501, true)});
	CHECK(c.came.empty());
	REQUIRE(c.in_world.size() == 1);
	CHECK_EQ(c.in_world[0].peer, 2u);

	c = v.update(kGarbage, {row(2, kGarbage, 501, true)});
	CHECK(c.in_world.empty());

	c = v.update(kGarbage, {row(2, kCordon, 501, false)}); // he went on
	REQUIRE(c.left.size() == 1);
	CHECK_EQ(c.left[0], 2u);
	CHECK(v.empty());
}

TEST(virtual_peers_two_players_on_one_level)
{
	VirtualPeers v;
	VirtualPeers::Change c = v.update(kGarbage, {row(1, kGarbage, 500, true), row(2, kGarbage, 501, true)});
	CHECK_EQ(c.came.size(), size_t(2));
	CHECK_EQ(c.in_world.size(), size_t(2));
	CHECK_EQ(v.on().size(), size_t(2));
	c = v.update(kGarbage, {row(2, kGarbage, 501, true)});
	REQUIRE(c.left.size() == 1);
	CHECK_EQ(c.left[0], 1u);
	CHECK(c.came.empty());
	CHECK_EQ(v.on().size(), size_t(1));
}

TEST(virtual_peers_a_new_character_of_the_same_player_starts_over)
{
	VirtualPeers v;
	v.update(kGarbage, {row(1, kGarbage, 500, true)});
	const VirtualPeers::Change c = v.update(kGarbage, {row(1, kGarbage, 600, false)});
	REQUIRE(c.left.size() == 1);
	REQUIRE(c.came.size() == 1);
	CHECK_EQ(int(c.came[0].proxy), 600);
}

TEST(virtual_peers_the_host_is_no_player_of_a_map_server)
{
	VirtualPeers v;
	const VirtualPeers::Change c = v.update(kGarbage, {row(0, kGarbage, 0, true), row(1, kGarbage, 500, true)});
	REQUIRE(c.came.size() == 1);
	CHECK_EQ(c.came[0].peer, 1u);
}

TEST(virtual_peers_a_row_without_a_character_says_nothing)
{
	VirtualPeers v;
	const VirtualPeers::Change c = v.update(kGarbage, {row(1, kGarbage, levels::wire::kNoObject, false)});
	CHECK(c.came.empty());
	CHECK(v.empty());
}
