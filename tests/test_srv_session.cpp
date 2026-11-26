// Anomaly Coop unit tests: the server's part of a session (srv::ServerPart behind the view srv::SessionSrv, xrCoop/srv/coop_session_srv.h;
// docs/MODES.md section 4, critique H10; A-S4S made the view, A-S4Sb moved the bodies out of Session) on real sessions over 127.0.0.1.
// Server: a world server's bridges and its operator (the token armed for one host()), a map server's level hosted through its world
// connection, both the game's two steps and host_virtual. Co-op: a co-op host has no server part, and asking about one makes none.
// none: a session that hosts nothing takes nothing, and a token given to it before it hosts is no token after. Ports 38641+n.
#include "test_util.h"

#include "srv/coop_mapserver_rules.h"
#include "srv/coop_session_srv.h"

#include <array>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

using namespace coop;

namespace
{
using srv::ServerPart;
using srv::SessionSrv;
using t::Node;
using Token = std::array<uint8_t, kHelloTokenSize>;

Token token_of(uint8_t first)
{
	Token out{};
	for (size_t i = 0; i < out.size(); ++i)
		out[i] = uint8_t(first + 5 * i + 1);
	return out;
}

void present(Node& n, const Token& t) { std::memcpy(n.cfg.hello_token.data(), t.data(), t.size()); }

// A map server's connection to the world server: Hello role MapServer with the token of its command line.
void as_map_server(Node& n, const Token& t)
{
	n.cfg.hello_role = kHelloRoleMapServer;
	present(n, t);
}

bool join(Node& host, Node& c, uint16_t port)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	return t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed || c.rejected; }) && c.welcomed;
}

bool refused(Node& host, Node& c, uint16_t port)
{
	std::string err;
	if (!c.connect(port, &err))
		return false;
	return t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed || c.rejected; }) && c.rejected;
}

bool has_part(Session& s) { return s.part(ServerPart::kind(), nullptr) != nullptr; }

Writer payload(uint32_t v)
{
	Writer w;
	w.u32(v);
	return w;
}
} // namespace

// ============================================================================ Server: the world server's bridges

TEST(srv_session_bridge_needs_an_issued_token)
{
	Node host("world", t::port(38641)), stranger("x", t::port(38641)), ms("ms", t::port(38641));
	host.cfg.host_plays = false; // a world server: its own seat plays no character
	std::vector<PeerId> came;
	SessionSrv(host.s).on_bridge_joined([&came](PeerId id) { came.push_back(id); });
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));

	// a token this session never issued: refused, nobody is a bridge
	as_map_server(stranger, token_of(9));
	CHECK(refused(host, stranger, t::port(38641)));
	CHECK(stranger.reject.reason == RejectReason::Kicked);
	CHECK_EQ(stranger.reject.text, std::string("This token was not issued by this session."));
	CHECK(SessionSrv(host.s).bridges().empty());

	// the issued one: a bridge under its number's id, in no list of players
	SessionSrv(host.s).issue_bridge(3, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, t::port(38641)));
	REQUIRE(t::pump_until({&host.s, &ms.s}, 5000, [&came] { return !came.empty(); }));
	CHECK_EQ(ms.s.self(), mapserver::bridge_peer(3));
	CHECK_EQ(came[0], mapserver::bridge_peer(3));
	const std::vector<PeerId> b = SessionSrv(host.s).bridges();
	REQUIRE(b.size() == 1);
	CHECK_EQ(b[0], mapserver::bridge_peer(3));
	CHECK(SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(3)));
	CHECK(!SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(4)));
	CHECK(host.s.joined(mapserver::bridge_peer(3))); // send() reaches it
	CHECK(host.s.peers().empty());
	CHECK(host.s.players().empty());
	CHECK(host.logged("host: map server 3 connected from 127.0.0.1"));
}

TEST(srv_session_bridge_token_is_good_once_and_revoked_is_none)
{
	Node host("world", t::port(38642)), ms("ms", t::port(38642)), again("x", t::port(38642)), late("y", t::port(38642)), zero("z", t::port(38642));
	host.cfg.host_plays = false;
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, t::port(38642)));

	as_map_server(again, token_of(7)); // one process, one use
	CHECK(refused(host, again, t::port(38642)));

	SessionSrv(host.s).issue_bridge(4, token_of(8));
	SessionSrv(host.s).revoke_bridge(4); // its process was given up on
	as_map_server(late, token_of(8));
	CHECK(refused(host, late, t::port(38642)));

	SessionSrv(host.s).issue_bridge(0, token_of(11)); // no map server has number 0
	as_map_server(zero, token_of(11));
	CHECK(refused(host, zero, t::port(38642)));

	const std::vector<PeerId> b = SessionSrv(host.s).bridges();
	REQUIRE(b.size() == 1);
	CHECK_EQ(b[0], mapserver::bridge_peer(2));
}

TEST(srv_session_a_lost_bridge_is_told)
{
	Node host("world", t::port(38643)), ms("ms", t::port(38643));
	host.cfg.host_plays = false;
	std::vector<std::pair<PeerId, std::string>> went;
	SessionSrv(host.s).on_bridge_left([&went](PeerId id, const std::string& why) { went.emplace_back(id, why); });
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, t::port(38643)));
	REQUIRE(SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(2)));
	ms.s.shutdown("over");
	REQUIRE(t::pump_until({&host.s}, 5000, [&went] { return !went.empty(); }));
	CHECK_EQ(went[0].first, mapserver::bridge_peer(2));
	CHECK(SessionSrv(host.s).bridges().empty());
	CHECK(!SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(2)));
	CHECK(!host.s.joined(mapserver::bridge_peer(2)));
	CHECK(host.logged("host: map server 2 left"));
}

// ============================================================================ Server: a map server's level

TEST(srv_session_a_map_servers_level_is_hosted_through_its_world_connection)
{
	Node host("world", t::port(38644)), ms("ms", t::port(38644));
	host.cfg.host_plays = false;
	std::vector<levels::wire::TunnelMsg> up;
	std::vector<PeerId> up_from;
	host.s.on(Msg::Tunnel, [&](PeerId from, Reader& r) {
		levels::wire::TunnelMsg m;
		if (m.read(r))
		{
			up.push_back(m);
			up_from.push_back(from);
		}
	});
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(2, token_of(7));
	as_map_server(ms, token_of(7));
	REQUIRE(join(host, ms, t::port(38644)));

	Session level; // after `ms`: the world connection outlives the level hosted through it
	CHECK(!SessionSrv(level).is_virtual());
	ms.cfg.mode = SessionMode::Server;
	REQUIRE(SessionSrv(level).host_virtual(ms.cfg, ms.s, &err));
	CHECK(SessionSrv(level).is_virtual());
	CHECK(level.is_active());
	CHECK_EQ(level.self(), mapserver::bridge_peer(2)); // toward the world it is its bridge
	CHECK(level.session_mode() == SessionMode::Server); // its level is part of its world's session
	CHECK(!SessionSrv(level).host_virtual(ms.cfg, ms.s, &err)); // one session, one host
	CHECK_EQ(err, std::string("session is already active"));

	std::vector<PeerId> joined, left;
	level.on_peer_joined = [&joined](const PeerInfo& p) { joined.push_back(p.id); };
	level.on_peer_left = [&left](PeerId id, const std::string&) { left.push_back(id); };
	SessionSrv(level).virtual_join(5, "Cy");
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&joined] { return !joined.empty(); }));
	CHECK_EQ(joined[0], PeerId(5));
	REQUIRE(level.peers().size() == 1);
	CHECK_EQ(level.peers()[0].nick, std::string("Cy"));
	CHECK(level.joined(5));

	// what the level's host code sends him goes up its world connection in a Tunnel
	level.send(5, Lane::Reliable, Msg::ReqResult, payload(99));
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 5000, [&up] { return !up.empty(); }));
	CHECK_EQ(up[0].peer, 5u);
	CHECK(up[0].type() == Msg::ReqResult);
	CHECK(mapserver::tunnel_lane(up[0].flags) == Lane::Reliable);
	CHECK_EQ(up_from[0], mapserver::bridge_peer(2));
	CHECK_EQ(level.stats(uint16_t(Msg::ReqResult)).sent_count, 1ull); // counted as the level's message, not as the Tunnel

	// what he sent comes down in one and runs here as his
	uint32_t got = 0;
	PeerId by = kInvalidPeer;
	level.on(Msg::PlayerShot, [&](PeerId from, Reader& r) {
		by = from;
		got = r.u32();
	});
	const uint8_t packet[6] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8), 7, 0, 0, 0};
	SessionSrv(level).virtual_receive(5, Lane::Reliable, packet, sizeof(packet));
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&got] { return got != 0; }));
	CHECK_EQ(got, 7u);
	CHECK_EQ(by, PeerId(5));

	// he went to another level: nobody here, and a late Tunnel of his runs nothing
	SessionSrv(level).virtual_leave(5, "he moved");
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 2000, [&left] { return !left.empty(); }));
	CHECK(level.peers().empty());
	got = 0;
	SessionSrv(level).virtual_receive(5, Lane::Reliable, packet, sizeof(packet));
	t::pump_for({&host.s, &ms.s, &level}, 50);
	CHECK_EQ(got, 0u);
	level.shutdown("over");
	CHECK(!SessionSrv(level).is_virtual()); // the session is over: it carries nothing
	CHECK(level.session_mode() == SessionMode::None);
}

// The game's two steps (srv/coop_srv_mode.cpp MapServerMode::install, then Manager::start_map_server): the level is made its world
// connection's before that connects, and the plain host() after it hosts the level, on no port of its own.
TEST(srv_session_a_map_servers_mode_hosts_its_level_through_its_bridge)
{
	Node host("world", t::port(38649)), ms("ms", t::port(38649));
	host.cfg.host_plays = false;
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	SessionSrv(host.s).issue_bridge(5, token_of(3));

	Session level;
	SessionSrv(level).level_through(ms.s); // install: before its bridge connects
	as_map_server(ms, token_of(3));
	REQUIRE(ms.connect(t::port(38649), &err));
	SessionConfig cfg = ms.cfg;
	cfg.mode = SessionMode::Server;
	cfg.port = t::port(38650); // a port nobody listens on: a level hosted through its bridge opens none
	REQUIRE(level.host(cfg, &err)); // Manager::start_map_server
	CHECK(SessionSrv(level).is_virtual());
	REQUIRE(t::pump_until({&host.s, &ms.s, &level}, 5000, [&] { return ms.s.is_active(); }));
	CHECK(level.is_active()); // its world connection's
	CHECK_EQ(level.self(), mapserver::bridge_peer(5));

	// it listens nowhere: the port of its config is free for anybody else
	Node other("other", t::port(38650));
	other.cfg.mode = SessionMode::Coop;
	CHECK(other.host(&err));
	CHECK(level.peers().empty());
	level.shutdown("over");
}

// SESSION-MODE (review rv_SESSION-MODE, blocker): every host() is told its mode, a carried one too. A map server's start says Server
// (MapServerMode::configure); a config that says none is refused before the carrier takes it, and the level stays idle. The seat rule
// stays the listening host's (this config keeps host_plays true), and the carried session's mode is its world's Welcome's.
TEST(srv_session_a_carried_host_needs_its_mode)
{
	Node world("world", t::port(38654)), bridge("bridge", t::port(38654));
	world.cfg.host_plays = false;
	world.cfg.mode = SessionMode::Server;
	std::string err;
	REQUIRE(world.host(&err));
	SessionSrv(world.s).issue_bridge(2, token_of(4));

	Session level;
	SessionSrv(level).level_through(bridge.s); // MapServerMode::install
	as_map_server(bridge, token_of(4));
	REQUIRE(bridge.connect(t::port(38654), &err));
	CHECK(!level.host(bridge.cfg, &err)); // a start that said no mode
	CHECK_EQ(err, std::string("the session's mode was not configured"));
	CHECK(!level.is_active());
	REQUIRE(level.role() == Role::None);

	bridge.cfg.mode = SessionMode::Server; // MapServerMode::configure
	REQUIRE(bridge.cfg.host_plays); // the seat rule (a Server seat plays nobody) is not asked of a carried host
	REQUIRE(level.host(bridge.cfg, &err)); // Manager::start_map_server
	CHECK(level.role() == Role::Host);
	CHECK(!level.is_active());
	CHECK(level.session_mode() == SessionMode::None); // the level waits for its world's Welcome
	REQUIRE(t::pump_until({&world.s, &bridge.s}, 5000, [&] { return bridge.welcomed; }));
	CHECK(bridge.welcome.mode == SessionMode::Server);
	CHECK(level.is_active());
	CHECK(level.session_mode() == SessionMode::Server);
	level.shutdown("over");
	CHECK(level.session_mode() == SessionMode::None);
}

// ============================================================================ Server: the operator of a world server

TEST(srv_session_armed_token_makes_the_operator_and_his_lines_reach_the_hook)
{
	Node host("server", t::port(38645)), creator("Creator", t::port(38645)), other("Other", t::port(38645));
	host.cfg.host_plays = false;
	std::vector<std::pair<PeerId, std::string>> got;
	SessionSrv(host.s).on_operator_command([&got](PeerId from, const std::string& line) { got.emplace_back(from, line); });
	const Token tok = token_of(5);
	present(creator, tok);
	SessionSrv(host.s).arm_operator(tok); // the world server's configure (srv/coop_srv_mode.cpp)
	std::string err;
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, creator, t::port(38645)));
	REQUIRE(join(host, other, t::port(38645)));
	REQUIRE(t::pump_until({&host.s, &creator.s, &other.s}, 5000, [&] { return creator.s.self_host_rights(); }));
	CHECK(!other.s.self_host_rights());

	CHECK(creator.s.send_operator_command("coop_status"));
	CHECK(creator.s.send_operator_command("quit")); // not on the list: refused
	CHECK(other.s.send_operator_command("coop_status")); // not the operator: refused
	REQUIRE(t::pump_until({&host.s, &creator.s, &other.s}, 3000, [&got] { return !got.empty(); }));
	t::pump_for({&host.s, &creator.s, &other.s}, 200);
	REQUIRE(got.size() == 1);
	CHECK_EQ(got[0].first, creator.welcome.slot);
	CHECK_EQ(got[0].second, std::string("coop_status"));
	CHECK_EQ(SessionSrv(host.s).operator_refused(), uint64_t(2));
	CHECK(host.logged("' refused (not_")); // the first refusal is logged (whichever came first), the second only counted
	CHECK(creator.s.is_active() && other.s.is_active()); // a refusal is no kick
}

// Review A-S4S (was test_session_srv.cpp:225-227, trivially true): the token is armed for one host() and for no other. A host()
// refused while the session is up takes none; the session that ends drops it and what was armed meanwhile, so the next host() of the
// same Session has no operator unless it is armed again.
TEST(srv_session_an_armed_token_is_for_one_host)
{
	const Token tok = token_of(5);
	Node host("server", t::port(38646)), first("Creator", t::port(38646)), late("Late", t::port(38646));
	host.cfg.host_plays = false;
	present(first, tok);
	std::string err;
	SessionSrv(host.s).arm_operator(tok);
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	REQUIRE(join(host, first, t::port(38646)));
	REQUIRE(t::pump_until({&host.s, &first.s}, 5000, [&] { return first.s.self_host_rights(); }));

	// armed while the session is up, with a host() that is refused: the session keeps its own token
	SessionSrv(host.s).arm_operator(token_of(6));
	CHECK(!host.host(&err));
	CHECK_EQ(err, std::string("session is already active"));
	CHECK(host.s.is_active());
	present(late, token_of(6));
	REQUIRE(join(host, late, t::port(38646)));
	t::pump_for({&host.s, &first.s, &late.s}, 200);
	CHECK(!late.s.self_host_rights());
	REQUIRE(host.s.peer(late.welcome.slot) != nullptr);
	CHECK(!host.s.peer(late.welcome.slot)->host_rights);

	// the session ends: the next host() of the same Session, armed with nothing, has no operator for either token
	host.s.shutdown("over");
	first.s.shutdown("over");
	late.s.shutdown("over");
	host.cfg.port = t::port(38653);
	REQUIRE(host.host(&err));
	Node again("Creator", t::port(38653)), other("Other", t::port(38653));
	again.cfg.key = first.cfg.key; // the creator's game again: the key the token was bound to
	present(again, tok);
	present(other, token_of(6));
	REQUIRE(join(host, again, t::port(38653)));
	REQUIRE(join(host, other, t::port(38653)));
	t::pump_for({&host.s, &again.s, &other.s}, 200);
	CHECK(!again.s.self_host_rights());
	CHECK(!other.s.self_host_rights());
	for (const PeerInfo& p : host.s.peers())
		CHECK(!p.host_rights);
	CHECK_EQ(host.s.peers().size(), size_t(2));
}

TEST(srv_session_host_that_cannot_start_says_why)
{
	Node host("server", t::port(38647));
	host.cfg.host_plays = false;
	std::string err;
	SessionSrv(host.s).arm_operator(token_of(5));
	host.cfg.mode = SessionMode::Server;
	REQUIRE(host.host(&err));
	CHECK(!host.host(&err)); // one session, one host()
	CHECK_EQ(err, std::string("session is already active"));
	CHECK(host.s.is_active());
	Node other("other", t::port(38648));
	other.cfg.mode = SessionMode::Server; // a seat that plays with the Server mode: refused by the session as it is
	other.cfg.host_plays = true;
	SessionSrv(other.s).arm_operator(token_of(5));
	err.clear();
	CHECK(!other.host(&err));
	CHECK(!err.empty());
	CHECK(!other.s.is_active());
}

// ============================================================================ Co-op: a co-op host has no server part

TEST(srv_session_a_coop_host_has_no_server_part)
{
	Node host("Host", t::port(38651)), pal("Pal", t::port(38651)), ms("ms", t::port(38651));
	std::string err;
	host.cfg.mode = SessionMode::Coop;
	REQUIRE(host.host(&err)); // a co-op host: its seat plays; it issues no bridge and holds no operator token
	present(pal, token_of(5)); // a player who presents a token anyway
	REQUIRE(join(host, pal, t::port(38651)));
	t::pump_for({&host.s, &pal.s}, 100);
	CHECK(!pal.s.self_host_rights());
	CHECK((pal.welcome.flags & WelcomeMsg::HostSeatPlays) != 0);
	CHECK(pal.welcome.mode == SessionMode::Coop);
	as_map_server(ms, token_of(5)); // nobody issued it a token: no map server comes into a co-op session
	CHECK(refused(host, ms, t::port(38651)));
	CHECK_EQ(ms.reject.text, std::string("This token was not issued by this session."));
	// asking the view makes no part: the co-op session stays without one
	CHECK(SessionSrv(host.s).bridges().empty());
	CHECK(!SessionSrv(host.s).bridge_connected(mapserver::bridge_peer(1)));
	CHECK(!SessionSrv(host.s).is_virtual());
	CHECK_EQ(SessionSrv(host.s).operator_refused(), uint64_t(0));
	SessionSrv(host.s).revoke_bridge(1);
	CHECK(!has_part(host.s));
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

// ============================================================================ none: a session that hosts nothing

// Review A-S4S (was test_session_srv.cpp:290-291, checked nothing: bridges() lists connected bridges only): a token given to a session
// that does not host is kept by nobody, so the map server that presents it once that session hosts is refused.
TEST(srv_session_outside_a_session_takes_nothing)
{
	Node idle("world", t::port(38652)), ms("ms", t::port(38652));
	idle.cfg.host_plays = false;
	SessionSrv v(idle.s);
	v.issue_bridge(1, token_of(3)); // not hosting: no token is kept
	CHECK(!v.is_virtual());
	v.virtual_join(3, "x"); // not a level's host: nobody joins
	CHECK(idle.s.peers().empty());
	const uint8_t packet[2] = {uint8_t(uint16_t(Msg::PlayerShot) & 0xff), uint8_t(uint16_t(Msg::PlayerShot) >> 8)};
	v.virtual_receive(3, Lane::Reliable, packet, sizeof(packet));
	v.virtual_leave(3, "x");
	CHECK(idle.s.peers().empty());
	CHECK_EQ(v.operator_refused(), uint64_t(0));
	CHECK(!idle.s.is_active());

	std::string err;
	idle.cfg.mode = SessionMode::Server;
	REQUIRE(idle.host(&err));
	as_map_server(ms, token_of(3));
	CHECK(refused(idle, ms, t::port(38652)));
	CHECK(v.bridges().empty());
	CHECK(!v.bridge_connected(mapserver::bridge_peer(1)));
}
