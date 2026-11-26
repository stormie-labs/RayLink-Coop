// Anomaly Coop unit tests: F5-SEAT-1, 16 seats (TZ 6.7, R19: Dev build 58). The wire carries 16 clients (kMaxPlayers 16: seat 0
// and the client slots 1 .. 16, kMaxPeerSlots 17); how many seats a session has is the mode's to say (SessionConfig::max_players has
// no default): the server's start says 16 (its own seat plays no character: 16 clients), the co-op start 8 (the host + 7, the Steam
// lobby unchanged). Every reader of the wire bounded by the slots takes peer 16 and refuses peer 17; the scheduler's viewer list keeps
// 16 points. Real Sessions over 127.0.0.1, ports 38901+n.
#include "test_util.h"
#include "coop_limits.h"
#include "srv/coop_mapserver_rules.h"
#include "srv/coop_levels_wire.h"
#include "coop_debug_rules.h"
#include "coop_transition.h"
#include "coop_rest_rules.h"
#include "coop_viewers.h"
#include "srv/coop_session_srv.h" // a map server's level, carried by its bridge

#include <algorithm>
#include <array>
#include <chrono>
#include <fstream>
#include <iterator>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <vector>

using namespace coop;
using t::Node;

namespace
{
// What the two starts say (srv/coop_srv_mode.cpp and hostplay/coop_hostplay_mode.cpp, Mode::configure).
constexpr uint32_t kServerSeats = 16;
constexpr uint32_t kCoopSeats = 8;
constexpr PeerId kLastSlot = 16; // the 16th client of a server
constexpr PeerId kNoSlot = 17; // the first id past the slots

// Joins clients one after another until one is refused; the number welcomed.
size_t fill_seats(Node& host, std::vector<std::unique_ptr<Node>>& clients, uint16_t port)
{
	size_t welcomed = 0;
	for (auto& c : clients)
	{
		std::string err;
		REQUIRE(c->connect(port, &err));
		bool done = false;
		for (int i = 0; i < 1000 && !done; ++i)
		{
			host.s.update(t::now_ms());
			for (auto& o : clients)
				o->s.update(t::now_ms());
			done = c->welcomed || c->rejected;
			std::this_thread::sleep_for(std::chrono::milliseconds(2));
		}
		if (!c->welcomed)
			break;
		++welcomed;
	}
	return welcomed;
}

template <class F>
std::vector<uint8_t> bytes_of(F write)
{
	Writer w;
	write(w);
	return w.data();
}
} // namespace

// ============================================================================ the numbers

TEST(seats_wire_carries_sixteen_clients)
{
	CHECK_EQ(kMaxPlayers, uint32_t(16));
	CHECK_EQ(kMaxPeerSlots, uint32_t(17)); // seat 0 and the client slots 1 .. 16
	CHECK_EQ(limits::kMaxClientSlots, uint32_t(16));
	CHECK(mapserver::kBridgeBase >= kMaxPeerSlots); // a bridge's id stays no player slot
	for (PeerId slot = 0; slot < kMaxPeerSlots; ++slot)
		CHECK(!mapserver::is_bridge(slot));
	CHECK_EQ(viewers::kMaxViewers, unsigned(16)); // every client of a server is a viewer of the scheduler
	CHECK(viewers::kMaxViewers >= limits::kMaxClientSlots);
	// a count of the wire's u8 fields still fits
	CHECK(kMaxPeerSlots <= 255u);
}

TEST(seats_client_capacity_per_mode)
{
	// the server: its seat plays no character, 16 seats are 16 clients
	CHECK_EQ(limits::client_capacity(kServerSeats, false), uint32_t(16));
	// co-op: the host's seat plays, 8 seats are the host + 7
	CHECK_EQ(limits::client_capacity(kCoopSeats, true), uint32_t(7));
	// never more than the slots, whatever a config says
	CHECK_EQ(limits::client_capacity(100, false), limits::kMaxClientSlots);
	CHECK_EQ(limits::client_capacity(100, true), limits::kMaxClientSlots);
	CHECK_EQ(limits::client_capacity(0, false), uint32_t(0));
}

// ============================================================================ sessions

TEST(seats_server_takes_sixteen_clients_and_refuses_the_seventeenth)
{
	Node host("server", t::port(38901));
	host.cfg.host_plays = false; // the server's start
	host.cfg.max_players = kServerSeats;
	host.cfg.mode = SessionMode::Server;
	std::vector<std::unique_ptr<Node>> clients;
	for (uint32_t i = 0; i < kServerSeats + 1; ++i)
		clients.emplace_back(new Node("C" + std::to_string(i), t::port(38901)));
	std::string err;
	REQUIRE(host.host(&err));
	CHECK_EQ(host.s.max_players(), kServerSeats); // its own config
	CHECK_EQ(fill_seats(host, clients, t::port(38901)), size_t(16));
	CHECK(clients.back()->rejected);
	CHECK(clients.back()->reject.reason == RejectReason::SessionFull);
	std::set<PeerId> slots;
	for (size_t i = 0; i < kServerSeats; ++i)
	{
		const PeerId s = clients[i]->welcome.slot;
		CHECK(s >= 1 && s < kMaxPeerSlots);
		CHECK(!mapserver::is_bridge(s));
		slots.insert(s);
		CHECK_EQ(clients[i]->welcome.max_players, kServerSeats);
		CHECK(!(clients[i]->welcome.flags & WelcomeMsg::HostSeatPlays));
		CHECK_EQ(clients[i]->s.max_players(), kServerSeats); // the Welcome's
		CHECK(clients[i]->s.session_mode() == SessionMode::Server);
	}
	CHECK_EQ(slots.size(), size_t(16));
	CHECK(slots.count(kLastSlot) == 1); // slots 1 .. 16
	CHECK(slots.count(kNoSlot) == 0);
	CHECK_EQ(host.s.peers().size(), size_t(16));
	// the first and the 16th client see each other in the PeerList
	REQUIRE(t::pump_until({&host.s, &clients[0]->s, &clients[15]->s}, 5000,
	    [&] { return clients[0]->s.peer(kLastSlot) != nullptr && clients[15]->s.peer(PeerId(1)) != nullptr; }));
	// a seat freed is taken again: the 17th comes in once one has left, with the slot that was freed
	const PeerId freed = clients[3]->welcome.slot;
	clients[3]->s.shutdown("leaves");
	REQUIRE(t::pump_until({&host.s}, 5000, [&] { return host.s.peers().size() == 15; }));
	Node late("Late", t::port(38901));
	REQUIRE(late.connect(t::port(38901), &err));
	REQUIRE(t::pump_until({&host.s, &late.s}, 5000, [&] { return late.welcomed || late.rejected; }));
	CHECK(late.welcomed);
	CHECK_EQ(late.welcome.slot, freed);
	// the session over: no seats any more
	host.s.shutdown("end");
	CHECK_EQ(host.s.max_players(), uint32_t(0));
}

TEST(seats_coop_refuses_the_eighth_client)
{
	Node host("Boss", t::port(38902));
	host.cfg.host_plays = true; // the co-op start
	host.cfg.max_players = kCoopSeats;
	host.cfg.mode = SessionMode::Coop;
	std::vector<std::unique_ptr<Node>> clients;
	for (uint32_t i = 0; i < kCoopSeats; ++i)
		clients.emplace_back(new Node("C" + std::to_string(i), t::port(38902)));
	std::string err;
	REQUIRE(host.host(&err));
	CHECK_EQ(host.s.max_players(), kCoopSeats);
	CHECK_EQ(fill_seats(host, clients, t::port(38902)), size_t(7));
	CHECK(clients.back()->rejected);
	CHECK(clients.back()->reject.reason == RejectReason::SessionFull);
	for (size_t i = 0; i < kCoopSeats - 1; ++i)
	{
		CHECK(clients[i]->welcome.slot >= 1 && clients[i]->welcome.slot < kCoopSeats); // slots 1 .. 7, no 8th
		CHECK_EQ(clients[i]->welcome.max_players, kCoopSeats);
		CHECK(clients[i]->welcome.flags & WelcomeMsg::HostSeatPlays);
		CHECK_EQ(clients[i]->s.max_players(), kCoopSeats);
		CHECK(clients[i]->s.session_mode() == SessionMode::Coop);
	}
	CHECK_EQ(host.s.peers().size(), size_t(7));
}

TEST(seats_a_host_whose_mode_said_no_seats_is_refused)
{
	// SessionConfig::max_players has no default: a start that forgot to say it hosts nothing (and says why)
	SessionConfig cfg;
	CHECK_EQ(cfg.max_players, uint32_t(0));
	Node host("Boss", t::port(38903));
	host.cfg.max_players = 0;
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	CHECK(!host.host(&err));
	CHECK(err.find("max_players") != std::string::npos);
	CHECK(host.s.role() == Role::None);
	CHECK_EQ(host.s.max_players(), uint32_t(0));
	// a number past the wire is cut to the wire's 16
	Node big("Big", t::port(38904));
	big.cfg.host_plays = false;
	big.cfg.max_players = 100;
	big.cfg.mode = SessionMode::Server;
	REQUIRE(big.host(&err));
	CHECK_EQ(big.s.max_players(), kMaxPlayers);
	big.s.shutdown("end");
}

TEST(seats_a_client_knows_no_seats_before_its_welcome)
{
	Node host("Boss", t::port(38905)), cl("Alice", t::port(38905));
	host.cfg.max_players = kCoopSeats;
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err));
	CHECK_EQ(cl.s.max_players(), uint32_t(0)); // no session
	REQUIRE(cl.connect(t::port(38905), &err));
	CHECK_EQ(cl.s.max_players(), uint32_t(0)); // connecting: no Welcome yet
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.welcomed; }));
	CHECK_EQ(cl.s.max_players(), kCoopSeats);
	cl.s.shutdown("leaves");
	CHECK_EQ(cl.s.max_players(), uint32_t(0)); // the next session says its own
}

TEST(seats_a_map_servers_level_has_its_worlds_seats)
{
	// Server: a map server's level is hosted through its bridge to the world server (srv::SessionSrv::level_through): its seats are
	// the world's, as the bridge's Welcome said them, whatever its own config says.
	std::array<uint8_t, kHelloTokenSize> token{};
	for (size_t i = 0; i < token.size(); ++i)
		token[i] = uint8_t(7 + 3 * i);
	Node world("world", t::port(38906)), ms("ms", t::port(38906));
	world.cfg.host_plays = false;
	world.cfg.max_players = kServerSeats;
	std::string err;
	world.cfg.mode = SessionMode::Server;
	REQUIRE(world.host(&err));
	srv::SessionSrv(world.s).issue_bridge(2, token);
	Session level;
	srv::SessionSrv(level).level_through(ms.s);
	ms.cfg.hello_role = kHelloRoleMapServer;
	ms.cfg.hello_token = token;
	REQUIRE(ms.connect(t::port(38906), &err));
	SessionConfig cfg = ms.cfg;
	cfg.mode = SessionMode::Server;
	cfg.port = t::port(38907); // a level hosted through its bridge listens nowhere
	cfg.max_players = kCoopSeats; // not its number: a carried host's seats are its carrier's
	REQUIRE(level.host(cfg, &err));
	REQUIRE(t::pump_until({&world.s, &ms.s, &level}, 5000, [&] { return ms.s.is_active(); }));
	CHECK_EQ(ms.s.max_players(), kServerSeats);
	CHECK_EQ(level.max_players(), kServerSeats);
	level.shutdown("over");
	CHECK_EQ(level.max_players(), uint32_t(0));
}

// ============================================================================ the wire with peer 16

TEST(seats_avatar_list_carries_peer_sixteen)
{
	AvatarListMsg m;
	m.owners.push_back({0, kHostPeer});
	for (PeerId p = 1; p <= kLastSlot; ++p)
		m.owners.push_back({uint16_t(100 + p), p});
	REQUIRE(m.owners.size() == kMaxPeerSlots);
	const std::vector<uint8_t> b = bytes_of([&](Writer& w) { m.write(w); });
	Reader r(b.data(), b.size());
	AvatarListMsg back;
	REQUIRE(back.read(r));
	REQUIRE(back.owners.size() == kMaxPeerSlots);
	CHECK_EQ(back.owners.back().peer, kLastSlot);
	CHECK_EQ(back.owners.back().avatar, uint16_t(116));

	AvatarListMsg past;
	past.owners.push_back({200, kNoSlot});
	const std::vector<uint8_t> b2 = bytes_of([&](Writer& w) { past.write(w); });
	Reader r2(b2.data(), b2.size());
	CHECK(!back.read(r2)); // no player slot
	CHECK(back.owners.empty());
}

TEST(seats_level_map_and_load_wait_carry_peer_sixteen)
{
	using namespace levels::wire;
	LevelMapMsg m;
	m.flags = LevelMapMsg::Split;
	for (PeerId p = 0; p < kMaxPeerSlots; ++p)
		m.players.push_back({p, uint16_t(3), uint8_t(1), uint16_t(500 + p), 1000u * p});
	REQUIRE(m.fits());
	Writer w;
	REQUIRE(m.write(w));
	Reader r(w.data().data(), w.size());
	LevelMapMsg back;
	REQUIRE(back.read(r));
	REQUIRE(back.players.size() == kMaxPeerSlots);
	CHECK_EQ(back.players.back().peer, kLastSlot);
	CHECK_EQ(back.players.back().proxy, uint16_t(516));
	CHECK_EQ(back.players.back().money, uint32_t(16000));

	LevelMapMsg over = m; // a row more than the slots
	over.players.push_back({1, 4, 1, 600, 0});
	CHECK(!over.fits());
	Writer wo;
	CHECK(!over.write(wo));

	LevelMapMsg past;
	past.players.push_back({kNoSlot, 3, 1, 700, 0});
	Writer wp;
	REQUIRE(past.write(wp)); // the writer does not judge peers
	Reader rp(wp.data().data(), wp.size());
	CHECK(!back.read(rp));

	LoadWaitMsg lw;
	lw.state = LoadWaitMsg::Waiting;
	lw.epoch = 7;
	lw.level = 3;
	for (PeerId p = 0; p < kMaxPeerSlots; ++p)
		lw.rows.push_back({p, uint8_t(p % 2)});
	Writer wl;
	REQUIRE(lw.write(wl));
	Reader rl(wl.data().data(), wl.size());
	LoadWaitMsg lback;
	REQUIRE(lback.read(rl));
	REQUIRE(lback.rows.size() == kMaxPeerSlots);
	CHECK_EQ(lback.rows.back().peer, kLastSlot);
	LoadWaitMsg lpast;
	lpast.rows.push_back({kNoSlot, 1});
	Writer wlp;
	REQUIRE(lpast.write(wlp));
	Reader rlp(wlp.data().data(), wlp.size());
	CHECK(!lback.read(rlp));
}

TEST(seats_debug_state_carries_peer_sixteen)
{
	debug::StateMsg m;
	m.on = true;
	m.source = debug::Source::Console;
	m.serial = 9;
	for (PeerId p = 1; p <= kLastSlot; ++p)
		m.rows.push_back({p, debug::kFlagGod});
	const std::vector<uint8_t> b = bytes_of([&](Writer& w) { debug::write_state(w, m); });
	Reader r(b.data(), b.size());
	debug::StateMsg back;
	REQUIRE(debug::read_state(r, back));
	REQUIRE(back.rows.size() == size_t(kLastSlot));
	CHECK_EQ(back.flags_of(kLastSlot), debug::kFlagGod);

	debug::StateMsg past = m;
	past.rows.push_back({kNoSlot, debug::kFlagGod});
	const std::vector<uint8_t> b2 = bytes_of([&](Writer& w) { debug::write_state(w, past); });
	Reader r2(b2.data(), b2.size());
	CHECK(!debug::read_state(r2, back));

	debug::ServerState s;
	REQUIRE(s.switch_on(debug::Source::Console));
	CHECK(s.set_flags(kLastSlot, debug::kFlagGod) == debug::ServerState::FlagsResult::Changed);
	CHECK(s.set_flags(kNoSlot, debug::kFlagGod) == debug::ServerState::FlagsResult::BadPeer);
}

TEST(seats_transition_board_carries_seventeen_rows)
{
	transition::StateMsg m;
	m.state = transition::State::Waiting;
	m.level = "l01_escape";
	m.ready = 3;
	m.total = uint16_t(kMaxPeerSlots);
	for (PeerId p = 0; p < kMaxPeerSlots; ++p)
	{
		transition::Row row;
		row.id = p;
		row.mark = transition::Mark::Ready;
		row.dist_m = uint16_t(10 + p);
		m.rows.push_back(row);
	}
	const std::vector<uint8_t> b = bytes_of([&](Writer& w) { m.write(w); });
	Reader r(b.data(), b.size());
	transition::StateMsg back;
	REQUIRE(back.read(r));
	REQUIRE(back.rows.size() == kMaxPeerSlots);
	CHECK_EQ(back.rows.back().id, uint32_t(kLastSlot));
	CHECK_EQ(back.rows.back().dist_m, uint16_t(26));

	transition::StateMsg over = m; // more rows than slots
	over.rows.push_back(over.rows.front());
	const std::vector<uint8_t> b2 = bytes_of([&](Writer& w) { over.write(w); });
	Reader r2(b2.data(), b2.size());
	CHECK(!back.read(r2));
}

TEST(seats_rest_state_carries_sixteen_players)
{
	rest::StateMsg m;
	m.block = rest::Block::NotAll;
	for (uint16_t i = 0; i < uint16_t(kMaxPlayers); ++i)
		m.entries.push_back({uint16_t(10 + i), i % 2 ? rest::State::Resting : rest::State::Awake, uint8_t(i % 2 ? 6 : 0)});
	const std::vector<uint8_t> b = bytes_of([&](Writer& w) { rest::write_state(w, m); });
	Reader r(b.data(), b.size());
	rest::StateMsg back;
	REQUIRE(rest::read_state(r, back));
	REQUIRE(back.entries.size() == size_t(16));
	CHECK_EQ(back.entries.back().character, uint16_t(25));
	CHECK(back.entries.back().state == rest::State::Resting);

	// a 17th row is more players than a session has
	Writer many;
	many.u8(uint8_t(rest::Block::None));
	many.u8(uint8_t(kMaxPlayers + 1));
	for (uint16_t i = 0; i <= uint16_t(kMaxPlayers); ++i)
	{
		many.u16(uint16_t(10 + i));
		many.u8(0);
		many.u8(0);
	}
	many.u8(0);
	Reader rm(many.data().data(), many.size());
	CHECK(!rest::read_state(rm, back));
}

// ============================================================================ the scheduler's viewers

TEST(seats_viewer_list_keeps_sixteen_points)
{
	// 16 clients of a server stand far apart; only the 16th stands by the object: the object is updated by its distance to him
	viewers::Point list[viewers::kMaxViewers];
	for (unsigned i = 0; i < viewers::kMaxViewers; ++i)
		list[i] = viewers::Point{1000.f * float(i + 1), 0.f, 0.f};
	const viewers::Point at{16000.f + 5.f, 0.f, 0.f};
	const float d = viewers::nearest_distance(900.f, list, viewers::kMaxViewers, at, viewers::kDefaultRange);
	CHECK(d > 4.99f && d < 5.01f);
	CHECK(viewers::within(list, viewers::kMaxViewers, at, viewers::kDefaultFrameRadius));
	// without the 16th the object is the camera's
	CHECK(viewers::nearest_distance(900.f, list, viewers::kMaxViewers - 1, at, viewers::kDefaultRange) == 900.f);
	CHECK(!viewers::within(list, viewers::kMaxViewers - 1, at, viewers::kDefaultFrameRadius));
}

// ============================================================================ who says the seats (rv_F5-SEAT-1 L1)

namespace
{
// engine/src/<rel> (tests\ -> ..\engine\src), without '\r'
std::string seats_engine_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream in(here + "/../engine/src/" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}
} // namespace

// The Core's config (Manager::make_config) says no seats: a hidden 16 there made host()'s refusal of 0 dead code in the game (a mode
// whose configure forgot max_players would have hosted the server's 16). Each start says its own in Mode::configure.
TEST(seats_the_cores_config_says_no_seats)
{
	const std::string manager = seats_engine_file("xrGame/coop/coop_manager.cpp");
	const size_t at = manager.find("SessionConfig Manager::make_config(u16 port)");
	REQUIRE(at != std::string::npos);
	const std::string body = manager.substr(at, manager.find("\n}", at) - at);
	CHECK(body.find("cfg.port = port;") != std::string::npos);
	CHECK(body.find("max_players") == std::string::npos);
	CHECK(seats_engine_file("xrGame/coop/hostplay/coop_hostplay_mode.cpp").find("cfg.max_players = 8;") != std::string::npos);
	CHECK(seats_engine_file("xrGame/coop/srv/coop_srv_mode.cpp").find("cfg.max_players = kMaxPlayers;") != std::string::npos);
}
