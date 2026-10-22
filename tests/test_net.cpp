// Anomaly Coop unit tests: real Sessions talking over 127.0.0.1 inside one process.
// Each test uses its own UDP port (37000+n) so sockets never collide.
#include "test_util.h"

#include <enet/enet.h>

#include <algorithm>
#include <cstring>
#include <iterator>
#include <map>

using namespace coop;

namespace
{
using t::Node;

// A bare ENet client that speaks the wire protocol by hand: used to send things Session never would
// (wrong protocol version, malformed core messages, silence).
struct RawPeer
{
	struct Message
	{
		uint16_t type = 0;
		std::vector<uint8_t> payload;
	};

	ENetHost* host = nullptr;
	ENetPeer* peer = nullptr;
	bool connected = false;
	bool disconnected = false;
	std::vector<Message> inbox;

	RawPeer() { enet_initialize(); }
	~RawPeer()
	{
		if (host)
			enet_host_destroy(host);
		enet_deinitialize();
	}

	bool connect(uint16_t port)
	{
		host = enet_host_create(nullptr, 1, 3, 0, 0);
		if (!host)
			return false;
		ENetAddress addr;
		enet_address_set_host(&addr, "127.0.0.1");
		addr.port = port;
		peer = enet_host_connect(host, &addr, 3, 0);
		return peer != nullptr;
	}

	void service()
	{
		if (!host)
			return;
		ENetEvent ev;
		while (enet_host_service(host, &ev, 0) > 0)
		{
			if (ev.type == ENET_EVENT_TYPE_CONNECT)
				connected = true;
			else if (ev.type == ENET_EVENT_TYPE_DISCONNECT)
				disconnected = true;
			else if (ev.type == ENET_EVENT_TYPE_RECEIVE)
			{
				if (ev.packet->dataLength >= 2)
				{
					Message m;
					m.type = uint16_t(ev.packet->data[0] | (ev.packet->data[1] << 8));
					m.payload.assign(ev.packet->data + 2, ev.packet->data + ev.packet->dataLength);
					inbox.push_back(std::move(m));
				}
				enet_packet_destroy(ev.packet);
			}
		}
	}

	void send_bytes(const void* data, size_t size, uint8_t channel = 0, bool reliable = true)
	{
		ENetPacket* p = enet_packet_create(data, size, reliable ? ENET_PACKET_FLAG_RELIABLE : 0);
		enet_peer_send(peer, channel, p);
		enet_host_flush(host);
	}

	void send(Msg type, const Writer& w, uint8_t channel = 0)
	{
		std::vector<uint8_t> buf;
		buf.push_back(uint8_t(uint16_t(type)));
		buf.push_back(uint8_t(uint16_t(type) >> 8));
		buf.insert(buf.end(), w.data().begin(), w.data().end());
		send_bytes(buf.data(), buf.size(), channel);
	}

	const Message* find(Msg type) const
	{
		for (const Message& m : inbox)
			if (m.type == uint16_t(type))
				return &m;
		return nullptr;
	}

	// Silently drops the socket: the peer on the other side only notices through its timeout.
	void vanish()
	{
		if (host)
			enet_host_destroy(host);
		host = nullptr;
		peer = nullptr;
	}
};

// A bare ENet server that answers Hello with Welcome (or stays silent) and can vanish without a word.
struct RawHost
{
	ENetHost* host = nullptr;
	bool answer_hello = true;
	bool got_hello = false;

	RawHost() { enet_initialize(); }
	~RawHost()
	{
		if (host)
			enet_host_destroy(host);
		enet_deinitialize();
	}

	bool listen(uint16_t port)
	{
		ENetAddress addr;
		addr.host = ENET_HOST_ANY;
		addr.port = port;
		host = enet_host_create(&addr, 4, 3, 0, 0);
		return host != nullptr;
	}

	void service()
	{
		if (!host)
			return;
		ENetEvent ev;
		while (host && enet_host_service(host, &ev, 0) > 0)
		{
			if (ev.type != ENET_EVENT_TYPE_RECEIVE)
				continue;
			if (ev.packet->dataLength >= 2 && ev.packet->data[0] == uint8_t(Msg::Hello) && ev.packet->data[1] == 0)
			{
				got_hello = true;
				if (answer_hello)
				{
					WelcomeMsg w;
					w.slot = 1;
					w.session_token = 7;
					w.host_nick = "Fake";
					w.max_players = 4;
					Writer body;
					w.write(body);
					std::vector<uint8_t> buf = {uint8_t(Msg::Welcome), 0};
					buf.insert(buf.end(), body.data().begin(), body.data().end());
					enet_peer_send(ev.peer, 0, enet_packet_create(buf.data(), buf.size(), ENET_PACKET_FLAG_RELIABLE));
					enet_host_flush(host);
				}
			}
			enet_packet_destroy(ev.packet);
		}
	}

	void vanish()
	{
		if (host)
			enet_host_destroy(host);
		host = nullptr;
	}
};

bool raw_join(RawPeer& raw, Node& host, uint16_t port, uint32_t protocol = kProtocolVersion)
{
	if (!raw.connect(port))
		return false;
	if (!t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.connected;
		}))
		return false;
	HelloMsg h;
	h.protocol = protocol;
	h.build_id = host.cfg.build_id;
	h.content_fp = manifest_fingerprint(host.cfg.manifest);
	h.key = generate_player_key();
	h.nick = "Raw";
	Writer w;
	h.write(w);
	raw.send(Msg::Hello, w);
	return t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return raw.find(Msg::Welcome) != nullptr || raw.find(Msg::Reject) != nullptr;
	});
}

bool all_lines_prefixed(const Node& n)
{
	for (const std::string& l : n.log)
		if (l.rfind("[coop] ", 0) != 0)
			return false;
	return true;
}

// Starts a host and joins `clients` (one after another so slots are 1, 2, ...).
void start_and_join(Node& host, std::initializer_list<Node*> clients, uint16_t port)
{
	std::string err;
	REQUIRE(host.host(&err));
	size_t expected = 0;
	for (Node* c : clients)
	{
		REQUIRE(c->connect(port, &err));
		++expected;
		REQUIRE(t::pump_until({&host.s, &c->s}, 5000, [&] { return c->s.is_active() && host.s.peers().size() == expected; }));
	}
	// Let the final PeerList reach everybody.
	for (Node* c : clients)
		REQUIRE(t::pump_until({&host.s, &c->s}, 5000, [&] { return c->s.peers().size() == 1 + (clients.size() - 1); }));
}

struct Received
{
	PeerId from = kInvalidPeer;
	std::vector<uint8_t> bytes;
};

Session::Handler collect(std::vector<Received>& into)
{
	return [&into](PeerId from, Reader& r) {
		Received rc;
		rc.from = from;
		rc.bytes.assign(r.cursor(), r.cursor() + r.remaining());
		into.push_back(std::move(rc));
	};
}

Writer sample_payload()
{
	Writer w;
	w.str("payload");
	w.u32(0xA5A5A5A5u);
	w.f32(1.25f);
	w.varu(1234567);
	const uint8_t tail[3] = {0, 255, 7};
	w.bytes(tail, sizeof(tail));
	return w;
}
} // namespace

// ============================================================================ handshake

TEST(handshake_accepted)
{
	Node host("Boss", 37001), cl("Alice", 37001);
	std::string err;
	REQUIRE(host.host(&err));
	CHECK(host.s.role() == Role::Host);
	CHECK_EQ(host.s.self(), kHostPeer);
	CHECK(host.s.is_active());
	CHECK(host.logged("[coop] host: listening on 0.0.0.0:37001"));

	REQUIRE(cl.connect(37001, &err));
	CHECK(cl.s.role() == Role::Client);
	CHECK_EQ(cl.s.self(), kInvalidPeer);
	CHECK(!cl.s.is_active());

	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000,
		[&] { return cl.welcomed && host.joined.size() == 1 && cl.s.peers().size() == 1 && cl.s.is_active(); }));

	CHECK_EQ(cl.welcome.slot, PeerId(1));
	CHECK_EQ(cl.welcome.host_nick, std::string("Boss"));
	CHECK_EQ(cl.welcome.max_players, kMaxPlayers);
	CHECK(cl.welcome.session_token != 0);
	CHECK_EQ(cl.s.self(), PeerId(1));

	// Host side.
	REQUIRE(host.joined.size() == 1);
	CHECK_EQ(host.joined[0].id, PeerId(1));
	CHECK_EQ(host.joined[0].nick, std::string("Alice"));
	CHECK(host.joined[0].key == cl.cfg.key);
	CHECK(host.joined[0].state == PeerState::Joined);
	CHECK(host.joined[0].address.rfind("127.0.0.1:", 0) == 0);
	const auto hp = host.s.peers();
	REQUIRE(hp.size() == 1);
	CHECK_EQ(hp[0].id, PeerId(1));
	CHECK_EQ(hp[0].nick, std::string("Alice"));
	REQUIRE(host.s.peer(1) != nullptr);
	CHECK_EQ(host.s.peer(1)->nick, std::string("Alice"));
	CHECK(host.s.peer(2) == nullptr);
	CHECK(host.s.peer(kHostPeer) == nullptr);

	// Client side: sees the host, does not list itself, gets no joined event for it.
	const auto cp = cl.s.peers();
	REQUIRE(cp.size() == 1);
	CHECK_EQ(cp[0].id, kHostPeer);
	CHECK_EQ(cp[0].nick, std::string("Boss"));
	CHECK(cp[0].state == PeerState::Joined);
	REQUIRE(cl.s.peer(kHostPeer) != nullptr);
	CHECK(cl.s.peer(1) == nullptr);
	CHECK(cl.joined.empty());

	// Stats of the handshake messages.
	CHECK_EQ(cl.s.stats(uint16_t(Msg::Hello)).sent_count, uint64_t(1));
	CHECK_EQ(host.s.stats(uint16_t(Msg::Hello)).recv_count, uint64_t(1));
	CHECK_EQ(host.s.stats(uint16_t(Msg::Welcome)).sent_count, uint64_t(1));
	CHECK_EQ(cl.s.stats(uint16_t(Msg::Welcome)).recv_count, uint64_t(1));
	CHECK_EQ(cl.s.stats(uint16_t(Msg::PeerList)).recv_count, uint64_t(1));

	CHECK(all_lines_prefixed(host));
	CHECK(all_lines_prefixed(cl));
	CHECK(!cl.disconnected && !cl.rejected);
}

TEST(host_port_busy_fails_with_error)
{
	Node a("A", 37002), b("B", 37002);
	std::string err;
	REQUIRE(a.host(&err));
	std::string err2;
	CHECK(!b.host(&err2));
	CHECK(!err2.empty());
	CHECK(b.s.role() == Role::None);
	CHECK(!b.s.is_active());
	// A second host() on the same session is refused too.
	std::string err3;
	CHECK(!a.host(&err3));
	CHECK(!err3.empty());
}

// ============================================================================ rejects

namespace
{
void expect_reject(Node& host, Node& cl, uint16_t port, RejectReason reason)
{
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(cl.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.rejected; }));
	CHECK(cl.reject.reason == reason);
	CHECK(!cl.reject.text.empty());
	CHECK(!cl.welcomed);
	CHECK(!cl.disconnected);
	CHECK(cl.s.role() == Role::None);
	CHECK(host.s.peers().empty());
	CHECK(host.joined.empty());
	CHECK(host.logged("[coop] reject peer"));
	CHECK(host.logged(reject_reason_name(reason)));
}
} // namespace

TEST(reject_protocol_mismatch_raw_client)
{
	Node host("Boss", 37003);
	std::string err;
	REQUIRE(host.host(&err));
	RawPeer raw;
	REQUIRE(raw_join(raw, host, 37003, 999));
	const RawPeer::Message* rj = raw.find(Msg::Reject);
	REQUIRE(rj != nullptr);
	RejectMsg rm;
	Reader r(rj->payload.data(), rj->payload.size());
	REQUIRE(rm.read(r));
	CHECK(rm.reason == RejectReason::ProtocolMismatch);
	CHECK(rm.text.find("999") != std::string::npos);
	CHECK(raw.find(Msg::Welcome) == nullptr);
	// The host closes the connection after a reject.
	CHECK(t::pump_until({&host.s}, 5000, [&] {
		raw.service();
		return raw.disconnected;
	}));
	CHECK(host.s.peers().empty());
}

TEST(reject_build_mismatch)
{
	Node host("Boss", 37004), cl("Alice", 37004);
	cl.cfg.build_id = "some-other-build";
	expect_reject(host, cl, 37004, RejectReason::BuildMismatch);
	CHECK(cl.reject.text.find("some-other-build") != std::string::npos);
	CHECK(cl.reject.text.find("test-build-1") != std::string::npos);
}

TEST(reject_content_mismatch_diff_names_exact_files)
{
	Node host("Boss", 37005), cl("Alice", 37005);
	// Host has: system.ltx, bind_stalker.script, stalker_hero.ogf (see sample_manifest).
	cl.cfg.manifest = {
		{"gamedata\\configs\\system.ltx", 0x1111111111111111ull}, // same
		{"gamedata\\scripts\\bind_stalker.script", 0xBADBADBADull}, // differs
		{"gamedata\\textures\\extra_mod.dds", 5}, // client only
		// stalker_hero.ogf missing here
	};
	expect_reject(host, cl, 37005, RejectReason::ContentMismatch);
	REQUIRE(cl.reject.host_manifest.size() == 3);
	CHECK(manifest_fingerprint(cl.reject.host_manifest) == manifest_fingerprint(host.cfg.manifest));
	REQUIRE(cl.diff.differ.size() == 1);
	CHECK_EQ(cl.diff.differ[0], std::string("gamedata\\scripts\\bind_stalker.script"));
	REQUIRE(cl.diff.missing_here.size() == 1);
	CHECK_EQ(cl.diff.missing_here[0], std::string("gamedata\\meshes\\actors\\stalker_hero.ogf"));
	REQUIRE(cl.diff.extra_here.size() == 1);
	CHECK_EQ(cl.diff.extra_here[0], std::string("gamedata\\textures\\extra_mod.dds"));
}

TEST(reject_content_mismatch_large_manifest)
{
	Node host("Boss", 37006), cl("Alice", 37006);
	Manifest big;
	for (int i = 0; i < 60000; ++i)
		big.push_back({"gamedata\\textures\\mod_pack\\texture_" + std::to_string(i) + ".dds", uint64_t(i) * 11400714819323198485ull});
	host.cfg.manifest = big;
	cl.cfg.manifest = big;
	cl.cfg.manifest[41234].hash ^= 1; // exactly one file differs
	expect_reject(host, cl, 37006, RejectReason::ContentMismatch);
	CHECK_EQ(cl.reject.host_manifest.size(), big.size());
	REQUIRE(cl.diff.differ.size() == 1);
	CHECK_EQ(cl.diff.differ[0], big[41234].path);
	CHECK(cl.diff.missing_here.empty() && cl.diff.extra_here.empty());
}

TEST(reject_duplicate_key_equal_to_host_key)
{
	Node host("Boss", 37007), cl("Alice", 37007);
	cl.cfg.key = host.cfg.key;
	expect_reject(host, cl, 37007, RejectReason::DuplicateKey);
	CHECK(cl.reject.text.find("coop_player.key") != std::string::npos);
	CHECK(cl.reject.text.find("copied") != std::string::npos);
}

TEST(reject_duplicate_key_between_two_clients)
{
	Node host("Boss", 37008), a("Alice", 37008), b("Bob", 37008);
	b.cfg.key = a.cfg.key;
	start_and_join(host, {&a}, 37008);
	std::string err;
	REQUIRE(b.connect(37008, &err));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b.rejected; }));
	CHECK(b.reject.reason == RejectReason::DuplicateKey);
	CHECK(b.reject.text.find("coop_player.key") != std::string::npos);
	// Alice is unaffected.
	t::pump_for({&host.s, &a.s, &b.s}, 200);
	CHECK(a.s.is_active());
	CHECK_EQ(host.s.peers().size(), size_t(1));
	CHECK(a.left.empty());
	CHECK(!a.disconnected);
}

TEST(reject_session_full_and_slot_reuse)
{
	Node host("Boss", 37009), a("Alice", 37009), b("Bob", 37009), c("Carl", 37009);
	host.cfg.max_players = 2; // host + one client
	start_and_join(host, {&a}, 37009);
	CHECK_EQ(a.s.self(), PeerId(1));

	std::string err;
	REQUIRE(b.connect(37009, &err));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b.rejected; }));
	CHECK(b.reject.reason == RejectReason::SessionFull);
	CHECK(!b.reject.text.empty());
	CHECK_EQ(host.s.peers().size(), size_t(1));

	// Alice leaves: the slot is free again and the next client gets the lowest free slot (1).
	a.s.shutdown("alice leaves");
	REQUIRE(t::pump_until({&host.s}, 5000, [&] { return host.s.peers().empty(); }));
	REQUIRE(c.connect(37009, &err));
	REQUIRE(t::pump_until({&host.s, &c.s}, 5000, [&] { return c.welcomed; }));
	CHECK_EQ(c.welcome.slot, PeerId(1));
	CHECK_EQ(c.welcome.max_players, uint32_t(2));
}

TEST(reject_check_order_protocol_build_content_key_full)
{
	Node host("Boss", 37010);
	host.cfg.max_players = 2;
	std::string err;
	REQUIRE(host.host(&err));

	Node a("Alice", 37010); // joins and fills the host
	REQUIRE(a.connect(37010, &err));
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return a.s.is_active(); }));

	// build wrong + content wrong + duplicate key + full  -> BuildMismatch
	Node c1("C1", 37010);
	c1.cfg.build_id = "x";
	c1.cfg.manifest.clear();
	c1.cfg.key = a.cfg.key;
	REQUIRE(c1.connect(37010, &err));
	REQUIRE(t::pump_until({&host.s, &c1.s}, 5000, [&] { return c1.rejected; }));
	CHECK(c1.reject.reason == RejectReason::BuildMismatch);

	// content wrong + duplicate key + full -> ContentMismatch
	Node c2("C2", 37010);
	c2.cfg.manifest.clear();
	c2.cfg.key = a.cfg.key;
	REQUIRE(c2.connect(37010, &err));
	REQUIRE(t::pump_until({&host.s, &c2.s}, 5000, [&] { return c2.rejected; }));
	CHECK(c2.reject.reason == RejectReason::ContentMismatch);

	// duplicate key + full -> DuplicateKey
	// (R1 I2: the host's key; Alice's key would depend on how long Alice, not pumped here, has been silent —
	// a silent player's key reconnects, see test_session_limits)
	Node c3("C3", 37010);
	c3.cfg.key = host.cfg.key;
	REQUIRE(c3.connect(37010, &err));
	REQUIRE(t::pump_until({&host.s, &c3.s}, 5000, [&] { return c3.rejected; }));
	CHECK(c3.reject.reason == RejectReason::DuplicateKey);

	// only full -> SessionFull
	Node c4("C4", 37010);
	REQUIRE(c4.connect(37010, &err));
	REQUIRE(t::pump_until({&host.s, &c4.s}, 5000, [&] { return c4.rejected; }));
	CHECK(c4.reject.reason == RejectReason::SessionFull);

	CHECK_EQ(host.s.peers().size(), size_t(1));
}

// ============================================================================ routing

TEST(game_message_routing_client_host_broadcast)
{
	Node host("Boss", 37011), a("Alice", 37011), b("Bob", 37011);
	start_and_join(host, {&a, &b}, 37011);
	CHECK_EQ(a.s.self(), PeerId(1));
	CHECK_EQ(b.s.self(), PeerId(2));

	std::vector<Received> host_got, a_got, b_got, a_other;
	host.s.on(Msg::PlayerVitals, collect(host_got));
	a.s.on(Msg::PlayerVitals, collect(a_got));
	b.s.on(Msg::PlayerVitals, collect(b_got));
	a.s.on(Msg::PlayerShot, collect(a_other));

	const Writer payload = sample_payload();

	// client -> host on every lane
	for (Lane lane : {Lane::Reliable, Lane::Unreliable, Lane::Bulk})
		a.s.send(kHostPeer, lane, Msg::PlayerVitals, payload);
	b.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, payload);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return host_got.size() == 4; }));
	size_t from_a = 0, from_b = 0;
	for (const Received& r : host_got)
	{
		CHECK(r.bytes == payload.data());
		from_a += r.from == 1;
		from_b += r.from == 2;
	}
	CHECK_EQ(from_a, size_t(3));
	CHECK_EQ(from_b, size_t(1));

	// host -> one client
	host.s.send(2, Lane::Reliable, Msg::PlayerVitals, payload);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b_got.size() == 1; }));
	CHECK(b_got[0].bytes == payload.data());
	CHECK_EQ(b_got[0].from, kHostPeer);
	CHECK(a_got.empty());

	// host broadcast with except
	b_got.clear();
	host.s.broadcast(Lane::Reliable, Msg::PlayerVitals, payload, 1);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b_got.size() == 1; }));
	t::pump_for({&host.s, &a.s, &b.s}, 100);
	CHECK_EQ(b_got.size(), size_t(1));
	CHECK(a_got.empty()); // the excepted peer got nothing
	CHECK(b_got[0].bytes == payload.data());

	// host broadcast to everybody
	b_got.clear();
	host.s.broadcast(Lane::Reliable, Msg::PlayerVitals, payload);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a_got.size() == 1 && b_got.size() == 1; }));
	CHECK(a_got[0].bytes == payload.data());

	// client broadcast == send to the host only
	host_got.clear();
	b_got.clear();
	a_got.clear();
	a.s.broadcast(Lane::Reliable, Msg::PlayerVitals, payload);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return host_got.size() == 1; }));
	t::pump_for({&host.s, &a.s, &b.s}, 100);
	CHECK_EQ(host_got.size(), size_t(1));
	CHECK(b_got.empty() && a_got.empty());

	// empty payload and a larger one that needs fragmentation
	host_got.clear();
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, Writer());
	Writer big;
	const std::vector<uint8_t> bigdata = t::random_bytes(300000, 99);
	big.bytes(bigdata.data(), bigdata.size());
	a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, big);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return host_got.size() == 2; }));
	CHECK(host_got[0].bytes.empty());
	CHECK(host_got[1].bytes == bigdata);
}

TEST(unregistered_game_type_counted_logged_once_and_dropped)
{
	Node host("Boss", 37012), a("Alice", 37012);
	start_and_join(host, {&a}, 37012);
	host.log.clear();
	Writer w;
	w.u32(1);
	for (int i = 0; i < 3; ++i)
		a.s.send(kHostPeer, Lane::Reliable, Msg::EntityState, w);
	a.s.send(kHostPeer, Lane::Reliable, Msg::TimeSync, w);
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] {
		return host.s.stats(uint16_t(Msg::EntityState)).recv_count == 3 && host.s.stats(uint16_t(Msg::TimeSync)).recv_count == 1;
	}));
	CHECK_EQ(host.s.stats(uint16_t(Msg::EntityState)).recv_bytes, uint64_t(3 * (2 + 4)));
	size_t es = 0, ts = 0;
	for (const std::string& l : host.log)
	{
		if (l.find("EntityState") != std::string::npos)
			++es;
		if (l.find("TimeSync") != std::string::npos)
			++ts;
	}
	CHECK_EQ(es, size_t(1)); // logged once per type
	CHECK_EQ(ts, size_t(1));
	CHECK(host.s.is_active() && a.s.is_active()); // not kicked
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

TEST(client_send_to_non_host_is_logged_noop)
{
	Node host("Boss", 37013), a("Alice", 37013), b("Bob", 37013);
	start_and_join(host, {&a, &b}, 37013);
	std::vector<Received> b_got;
	b.s.on(Msg::PlayerVitals, collect(b_got));
	a.log.clear();
	Writer w;
	w.u8(1);
	a.s.send(2, Lane::Reliable, Msg::PlayerVitals, w);
	t::pump_for({&host.s, &a.s, &b.s}, 300);
	CHECK(b_got.empty());
	CHECK_EQ(a.s.stats(uint16_t(Msg::PlayerVitals)).sent_count, uint64_t(0));
	CHECK(a.logged("[coop] "));
	CHECK(a.logged("only send to the host"));
}

TEST(stats_count_sent_and_received_exactly)
{
	Node host("Boss", 37014), a("Alice", 37014);
	start_and_join(host, {&a}, 37014);
	t::pump_for({&host.s, &a.s}, 100);
	host.s.reset_stats();
	a.s.reset_stats();
	CHECK(host.s.stats_types().empty());
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerVitals)).sent_count, uint64_t(0));

	std::vector<Received> got;
	a.s.on(Msg::PlayerVitals, collect(got));
	Writer w;
	w.u32(1);
	w.u32(2);
	w.u16(3); // 10 payload bytes
	const int N = 37;
	for (int i = 0; i < N; ++i)
		host.s.send(1, Lane::Reliable, Msg::PlayerVitals, w);
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return got.size() == size_t(N); }));

	const MsgStats& hs = host.s.stats(uint16_t(Msg::PlayerVitals));
	const MsgStats& as = a.s.stats(uint16_t(Msg::PlayerVitals));
	CHECK_EQ(hs.sent_count, uint64_t(N));
	CHECK_EQ(hs.sent_bytes, uint64_t(N * 12));
	CHECK_EQ(hs.recv_count, uint64_t(0));
	CHECK_EQ(as.recv_count, uint64_t(N));
	CHECK_EQ(as.recv_bytes, uint64_t(N * 12));
	CHECK_EQ(as.sent_count, uint64_t(0));
	const auto types = host.s.stats_types();
	CHECK(std::find(types.begin(), types.end(), uint16_t(Msg::PlayerVitals)) != types.end());
	CHECK(std::find(types.begin(), types.end(), uint16_t(Msg::PlayerState)) == types.end());

	// Broadcast counts one send per recipient.
	host.s.reset_stats();
	host.s.broadcast(Lane::Reliable, Msg::PlayerVitals, w);
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerVitals)).sent_count, uint64_t(1));
}

// ============================================================================ membership

TEST(three_party_peerlist_leave_reasons)
{
	Node host("Boss", 37015), a("Alice", 37015), b("Bob", 37015);
	start_and_join(host, {&a, &b}, 37015);

	// Alice learned about Bob through the PeerList, Bob about Alice, the host fired joined for both.
	REQUIRE(a.joined.size() == 1);
	CHECK_EQ(a.joined[0].id, PeerId(2));
	CHECK_EQ(a.joined[0].nick, std::string("Bob"));
	REQUIRE(b.joined.size() == 1);
	CHECK_EQ(b.joined[0].id, PeerId(1));
	CHECK_EQ(b.joined[0].nick, std::string("Alice"));
	CHECK_EQ(host.joined.size(), size_t(2));
	const auto ap = a.s.peers();
	REQUIRE(ap.size() == 2);
	CHECK_EQ(ap[0].id, kHostPeer);
	CHECK_EQ(ap[1].id, PeerId(2));
	REQUIRE(a.s.peer(2) != nullptr);
	CHECK_EQ(a.s.peer(2)->nick, std::string("Bob"));

	// Alice leaves with a reason.
	a.s.shutdown("bye test");
	CHECK(a.s.role() == Role::None);
	REQUIRE(t::pump_until({&host.s, &b.s}, 5000, [&] { return !host.left.empty() && !b.left.empty(); }));
	CHECK_EQ(host.left[0].first, PeerId(1));
	CHECK_EQ(host.left[0].second, std::string("bye test"));
	CHECK_EQ(b.left[0].first, PeerId(1));
	CHECK(b.left[0].second.find("bye test") != std::string::npos);
	CHECK_EQ(host.s.peers().size(), size_t(1));
	CHECK_EQ(b.s.peers().size(), size_t(1)); // only the host remains
	CHECK(b.s.peer(1) == nullptr);
	CHECK(b.s.is_active());

	// Alice may join again (slot 1 is free) with the same session object.
	a.welcomed = false;
	a.disconnected = false;
	std::string err;
	REQUIRE(a.connect(37015, &err));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a.welcomed && b.joined.size() == 2; }));
	CHECK_EQ(a.welcome.slot, PeerId(1));
}

TEST(host_shutdown_sends_bye_reason_to_clients)
{
	Node host("Boss", 37016), a("Alice", 37016), b("Bob", 37016);
	start_and_join(host, {&a, &b}, 37016);
	host.s.shutdown("server closing");
	CHECK(host.s.role() == Role::None);
	REQUIRE(t::pump_until({&a.s, &b.s}, 5000, [&] { return a.disconnected && b.disconnected; }));
	CHECK_EQ(a.disc_reason, std::string("server closing"));
	CHECK_EQ(b.disc_reason, std::string("server closing"));
	CHECK(a.s.role() == Role::None);
	CHECK(!a.s.is_active());
	CHECK(a.s.peers().empty());
	// Safe to call twice.
	host.s.shutdown("again");
	a.s.shutdown("again");
}

TEST(host_kick_reaches_client_with_text)
{
	Node host("Boss", 37017), a("Alice", 37017), b("Bob", 37017);
	start_and_join(host, {&a, &b}, 37017);
	host.s.kick(1, RejectReason::Kicked, "behave yourself");
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a.disconnected && !b.left.empty(); }));
	CHECK(a.disc_reason.find("behave yourself") != std::string::npos);
	CHECK(a.disc_reason.find("Kicked") != std::string::npos);
	REQUIRE(host.left.size() == 1);
	CHECK_EQ(host.left[0].first, PeerId(1));
	CHECK_EQ(host.left[0].second, std::string("behave yourself"));
	CHECK_EQ(b.left[0].first, PeerId(1));
	CHECK_EQ(host.s.peers().size(), size_t(1));
	// Kicking an unknown peer is a harmless no-op.
	host.s.kick(5, RejectReason::Kicked, "nobody");
	t::pump_for({&host.s, &b.s}, 50);
	CHECK(b.s.is_active());
}

TEST(chat_client_host_rebroadcast_and_host_to_all)
{
	Node host("Boss", 37018), a("Alice", 37018), b("Bob", 37018);
	start_and_join(host, {&a, &b}, 37018);
	a.s.send_chat("hello zone");
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return !host.chat.empty() && !b.chat.empty(); }));
	t::pump_for({&host.s, &a.s, &b.s}, 100);
	REQUIRE(host.chat.size() == 1);
	CHECK_EQ(host.chat[0].first, PeerId(1));
	CHECK_EQ(host.chat[0].second, std::string("hello zone"));
	REQUIRE(b.chat.size() == 1);
	CHECK_EQ(b.chat[0].first, PeerId(1));
	CHECK_EQ(b.chat[0].second, std::string("hello zone"));
	CHECK(a.chat.empty()); // no echo to the sender

	host.s.send_chat("stay sharp");
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return !a.chat.empty() && b.chat.size() == 2; }));
	CHECK_EQ(a.chat[0].first, kHostPeer);
	CHECK_EQ(a.chat[0].second, std::string("stay sharp"));
	CHECK_EQ(host.chat.size(), size_t(1)); // host does not receive its own chat
}

TEST(peer_silence_timeout_drops_vanished_client)
{
	Node host("Boss", 37019);
	host.cfg.peer_timeout_ms = 1500;
	std::string err;
	REQUIRE(host.host(&err));
	RawPeer raw;
	REQUIRE(raw_join(raw, host, 37019));
	REQUIRE(raw.find(Msg::Welcome) != nullptr);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return host.joined.size() == 1;
	}));
	raw.vanish(); // no disconnect, no more packets
	const uint64_t t0 = t::now_ms();
	REQUIRE(t::pump_until({&host.s}, 15000, [&] { return !host.left.empty(); }));
	const uint64_t took = t::now_ms() - t0;
	CHECK_EQ(host.left[0].first, PeerId(1));
	CHECK(host.left[0].second.find("lost") != std::string::npos);
	CHECK(took >= 1000);
	CHECK(host.s.peers().empty());
}

// ============================================================================ malformed input

TEST(malformed_core_message_from_joined_client_kicks)
{
	Node host("Boss", 37020);
	std::string err;
	REQUIRE(host.host(&err));
	RawPeer raw;
	REQUIRE(raw_join(raw, host, 37020));
	REQUIRE(raw.find(Msg::Welcome) != nullptr);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return host.joined.size() == 1;
	}));

	Writer w; // BlobChunk for a blob nobody announced
	w.u32(4242);
	w.u32(1);
	raw.send(Msg::BlobChunk, w, 2);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return raw.find(Msg::Reject) != nullptr;
	}));
	RejectMsg rm;
	Reader r(raw.find(Msg::Reject)->payload.data(), raw.find(Msg::Reject)->payload.size());
	REQUIRE(rm.read(r));
	CHECK(rm.reason == RejectReason::Malformed);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] { return !host.left.empty(); }));
	CHECK_EQ(host.left[0].first, PeerId(1));
	CHECK(host.s.peers().empty());
	CHECK(t::pump_until({&host.s}, 5000, [&] {
		raw.service();
		return raw.disconnected;
	}));
}

TEST(malformed_truncated_hello_and_short_packet_and_early_game_message)
{
	Node host("Boss", 37021);
	std::string err;
	REQUIRE(host.host(&err));

	// Hello that ends after the protocol field.
	{
		RawPeer raw;
		REQUIRE(raw.connect(37021));
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.connected;
		}));
		Writer w;
		w.u32(kProtocolVersion);
		raw.send(Msg::Hello, w);
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.find(Msg::Reject) != nullptr;
		}));
		RejectMsg rm;
		Reader r(raw.find(Msg::Reject)->payload.data(), raw.find(Msg::Reject)->payload.size());
		REQUIRE(rm.read(r));
		CHECK(rm.reason == RejectReason::Malformed);
	}
	// A one-byte packet.
	{
		RawPeer raw;
		REQUIRE(raw.connect(37021));
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.connected;
		}));
		const uint8_t one = 7;
		raw.send_bytes(&one, 1);
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.find(Msg::Reject) != nullptr;
		}));
	}
	// A game message before the handshake.
	{
		RawPeer raw;
		REQUIRE(raw.connect(37021));
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.connected;
		}));
		Writer w;
		w.u32(1);
		raw.send(Msg::PlayerState, w);
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.find(Msg::Reject) != nullptr;
		}));
	}
	// Second Hello from a joined client.
	{
		RawPeer raw;
		REQUIRE(raw_join(raw, host, 37021));
		REQUIRE(raw.find(Msg::Welcome) != nullptr);
		HelloMsg h;
		h.build_id = host.cfg.build_id;
		h.content_fp = manifest_fingerprint(host.cfg.manifest);
		h.key = generate_player_key();
		Writer w;
		h.write(w);
		raw.send(Msg::Hello, w);
		REQUIRE(t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.find(Msg::Reject) != nullptr;
		}));
	}
	t::pump_for({&host.s}, 100);
	CHECK(host.s.peers().empty());
	CHECK(host.s.is_active()); // the host itself is fine
}

TEST(blob_crc_mismatch_dropped_then_good_blob_from_client_arrives)
{
	Node host("Boss", 37022);
	std::string err;
	REQUIRE(host.host(&err));
	RawPeer raw;
	REQUIRE(raw_join(raw, host, 37022));
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return host.joined.size() == 1;
	}));

	const uint8_t data[6] = {1, 2, 3, 4, 5, 6};
	auto send_blob = [&](uint32_t id, uint32_t crc) {
		Writer b;
		b.u32(id);
		b.u32(77);
		b.u64(sizeof(data));
		b.u32(crc);
		raw.send(Msg::BlobBegin, b, 2);
		Writer c;
		c.u32(id);
		c.bytes(data, sizeof(data));
		raw.send(Msg::BlobChunk, c, 2);
		Writer e;
		e.u32(id);
		raw.send(Msg::BlobEnd, e, 2);
	};
	send_blob(5, crc32(data, sizeof(data)) ^ 0xFFu); // wrong crc
	send_blob(6, crc32(data, sizeof(data))); // right crc
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return !host.blobs.empty();
	}));
	t::pump_for({&host.s}, 100);
	REQUIRE(host.blobs.size() == 1);
	CHECK_EQ(host.blobs[0].id, uint32_t(6));
	CHECK_EQ(host.blobs[0].kind, uint32_t(77));
	CHECK_EQ(host.blobs[0].from, PeerId(1));
	CHECK(host.blobs[0].data == std::vector<uint8_t>(data, data + sizeof(data)));
	CHECK(host.logged("CRC mismatch"));
	CHECK_EQ(host.s.peers().size(), size_t(1)); // a bad CRC is dropped, not punished
	CHECK_EQ(host.progress.size(), size_t(2));
}

// ============================================================================ timeouts

TEST(connect_to_dead_port_times_out)
{
	Node cl("Alice", 37023);
	cl.cfg.connect_timeout_ms = 1500;
	std::string err;
	const uint64_t t0 = t::now_ms();
	REQUIRE(cl.connect(37023, &err)); // nobody listens there
	REQUIRE(t::pump_until({&cl.s}, 6000, [&] { return cl.disconnected; }));
	const uint64_t took = cl.disc_at - t0;
	CHECK(cl.disc_reason.find("timeout") != std::string::npos);
	CHECK(took >= 1400);
	CHECK(took <= 1500 + 800);
	CHECK(cl.s.role() == Role::None);
	CHECK(!cl.welcomed && !cl.rejected);
	CHECK(all_lines_prefixed(cl));
	// The session is reusable after the failure: a real host can be joined now.
	Node host("Boss", 37023);
	REQUIRE(host.host(&err));
	cl.disconnected = false;
	REQUIRE(cl.connect(37023, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.welcomed; }));
}

// ============================================================================ blobs

namespace
{
void run_blob_transfer(uint16_t port, size_t size, bool sim, uint32_t timeout_ms)
{
	Node host("Boss", port), cl("Alice", port);
	start_and_join(host, {&cl}, port);
	if (sim)
	{
		NetSim ns;
		ns.lag_ms = 50;
		ns.jitter_ms = 10;
		ns.loss = 0.05f;
		host.s.set_netsim(ns);
		cl.s.set_netsim(ns);
		CHECK(host.s.netsim().enabled());
		CHECK_EQ(host.s.netsim().lag_ms, uint32_t(50));
	}

	std::vector<uint8_t> data = t::random_bytes(size, 0x1234567ull + size);
	const std::vector<uint8_t> copy = data;
	const uint32_t id = host.s.send_blob(1, 42, std::move(data));
	CHECK(id != 0);
	const uint64_t t0 = t::now_ms();
	REQUIRE(t::pump_until({&host.s, &cl.s}, timeout_ms, [&] { return !cl.blobs.empty(); }, false));
	const uint64_t took = t::now_ms() - t0;
	std::printf("    blob %zu bytes, netsim=%d: %llu ms\n", size, int(sim), static_cast<unsigned long long>(took));

	REQUIRE(cl.blobs.size() == 1);
	CHECK_EQ(cl.blobs[0].id, id);
	CHECK_EQ(cl.blobs[0].kind, uint32_t(42));
	CHECK_EQ(cl.blobs[0].from, kHostPeer);
	CHECK_EQ(cl.blobs[0].data.size(), copy.size());
	CHECK(cl.blobs[0].data == copy);
	CHECK_EQ(crc32(cl.blobs[0].data.data(), cl.blobs[0].data.size()), crc32(copy.data(), copy.size()));

	// Progress: monotonic, ends at total, one event per 64 KiB chunk.
	REQUIRE(!cl.progress.empty());
	uint64_t last = 0;
	bool monotonic = true;
	for (const Node::BlobProgress& p : cl.progress)
	{
		monotonic = monotonic && p.done >= last && p.done <= p.total && p.total == copy.size() && p.id == id && p.kind == 42;
		last = p.done;
	}
	CHECK(monotonic);
	CHECK_EQ(cl.progress.back().done, uint64_t(copy.size()));
	CHECK_EQ(cl.progress.size(), (copy.size() + 65535) / 65536);
	CHECK(cl.s.is_active() && host.s.is_active());
}
} // namespace

TEST(blob_20mb_host_to_client_intact)
{
	run_blob_transfer(37024, 20u * 1024 * 1024, false, 60000);
}

TEST(blob_20mb_host_to_client_with_netsim_lag_and_loss)
{
	run_blob_transfer(37025, 20u * 1024 * 1024, true, 120000);
}

TEST(blob_edge_sizes_queued_together_arrive_in_order)
{
	Node host("Boss", 37026), cl("Alice", 37026);
	start_and_join(host, {&cl}, 37026);
	const size_t sizes[] = {0, 1, 65535, 65536, 65537, 131072, 200000};
	std::vector<std::vector<uint8_t>> sent;
	std::vector<uint32_t> ids;
	for (size_t i = 0; i < std::size(sizes); ++i)
	{
		sent.push_back(t::random_bytes(sizes[i], 100 + i));
		ids.push_back(host.s.send_blob(1, uint32_t(i), sent.back()));
	}
	for (size_t i = 1; i < ids.size(); ++i)
		CHECK(ids[i] != ids[i - 1] && ids[i] != 0);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 20000, [&] { return cl.blobs.size() == std::size(sizes); }));
	for (size_t i = 0; i < std::size(sizes); ++i)
	{
		CHECK_EQ(cl.blobs[i].id, ids[i]);
		CHECK_EQ(cl.blobs[i].kind, uint32_t(i));
		CHECK(cl.blobs[i].data == sent[i]);
	}

	// And in the other direction, client -> host.
	const std::vector<uint8_t> up = t::random_bytes(150000, 5);
	const uint32_t uid = cl.s.send_blob(kHostPeer, 9, up);
	CHECK(uid != 0);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 20000, [&] { return host.blobs.size() == 1; }));
	CHECK(host.blobs[0].data == up);
	CHECK_EQ(host.blobs[0].from, PeerId(1));

	// Invalid targets return 0.
	CHECK_EQ(host.s.send_blob(7, 1, std::vector<uint8_t>(10)), uint32_t(0));
	CHECK_EQ(cl.s.send_blob(2, 1, std::vector<uint8_t>(10)), uint32_t(0));
}

TEST(blob_does_not_starve_reliable_lane)
{
	Node host("Boss", 37027), cl("Alice", 37027);
	start_and_join(host, {&cl}, 37027);
	std::vector<Received> got;
	cl.s.on(Msg::PlayerVitals, collect(got));
	host.s.send_blob(1, 1, t::random_bytes(30u * 1024 * 1024, 3));
	t::pump_for({&host.s, &cl.s}, 20); // the transfer is under way
	Writer w;
	w.u32(1);
	const uint64_t t0 = t::now_ms();
	host.s.send(1, Lane::Reliable, Msg::PlayerVitals, w);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 10000, [&] { return !got.empty(); }, false));
	const uint64_t took = t::now_ms() - t0;
	CHECK(cl.blobs.empty()); // the small message overtook the 30 MB transfer
	CHECK(took < 2000);
	std::printf("    reliable message delivered %llu ms after queueing behind a 30 MB blob\n",
		static_cast<unsigned long long>(took));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 120000, [&] { return !cl.blobs.empty(); }, false));
}

// ============================================================================ NetSim

namespace
{
size_t run_loss_round(uint16_t port, float loss, size_t* reliable_out, bool on_receiver = false)
{
	Node host("Boss", port), cl("Alice", port);
	host.cfg.key = PlayerKey{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}; // fixed -> fixed PRNG seed
	cl.cfg.key = PlayerKey{16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1};
	start_and_join(host, {&cl}, port);
	std::vector<Received> unrel, rel;
	cl.s.on(Msg::PlayerState, collect(unrel));
	cl.s.on(Msg::PlayerVitals, collect(rel));

	NetSim ns;
	ns.loss = loss;
	(on_receiver ? cl.s : host.s).set_netsim(ns);
	Writer w;
	w.u32(0xABCDEF01u);
	for (int batch = 0; batch < 50; ++batch)
	{
		for (int i = 0; i < 20; ++i)
		{
			host.s.send(1, Lane::Unreliable, Msg::PlayerState, w);
			host.s.send(1, Lane::Reliable, Msg::PlayerVitals, w);
		}
		t::pump_for({&host.s, &cl.s}, 3);
	}
	REQUIRE(t::pump_until({&host.s, &cl.s}, 10000, [&] { return rel.size() == 1000; }));
	t::pump_for({&host.s, &cl.s}, 200);
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerState)).sent_count, uint64_t(1000));
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerVitals)).sent_count, uint64_t(1000));
	CHECK_EQ(cl.s.stats(uint16_t(Msg::PlayerState)).recv_count, uint64_t(unrel.size()));
	for (const Received& r : unrel)
		CHECK(r.bytes == w.data());
	*reliable_out = rel.size();
	return unrel.size();
}
} // namespace

TEST(netsim_loss_half_drops_unreliable_only)
{
	size_t reliable = 0;
	const size_t got = run_loss_round(37028, 0.5f, &reliable);
	std::printf("    unreliable delivered %zu of 1000, reliable %zu of 1000\n", got, reliable);
	CHECK(got >= 300 && got <= 700);
	CHECK_EQ(reliable, size_t(1000));
}

TEST(netsim_loss_zero_delivers_everything_and_loss_is_deterministic)
{
	size_t reliable = 0;
	const size_t all = run_loss_round(37029, 0.f, &reliable);
	CHECK_EQ(all, size_t(1000));

	size_t r1 = 0, r2 = 0;
	const size_t a = run_loss_round(37030, 0.3f, &r1);
	const size_t b = run_loss_round(37031, 0.3f, &r2);
	std::printf("    loss 0.3 twice with the same keys: %zu and %zu delivered\n", a, b);
	CHECK_EQ(a, b); // same keys -> same seed -> same drops
	CHECK(a > 600 && a < 800);
}

TEST(netsim_delay_applied_and_order_kept_under_jitter)
{
	Node host("Boss", 37032), cl("Alice", 37032);
	start_and_join(host, {&cl}, 37032);
	std::vector<Received> got;
	cl.s.on(Msg::PlayerVitals, collect(got));

	// Pure lag: the first message must take at least ~lag.
	NetSim ns;
	ns.lag_ms = 120;
	host.s.set_netsim(ns);
	Writer w;
	w.u32(0);
	const uint64_t t0 = t::now_ms();
	host.s.send(1, Lane::Reliable, Msg::PlayerVitals, w);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return !got.empty(); }));
	const uint64_t took = t::now_ms() - t0;
	CHECK(took >= 110);
	CHECK(took < 600);

	// Jitter must never reorder a lane.
	got.clear();
	ns.lag_ms = 30;
	ns.jitter_ms = 25;
	host.s.set_netsim(ns);
	for (uint32_t i = 0; i < 200; ++i)
	{
		Writer m;
		m.u32(i);
		host.s.send(1, Lane::Reliable, Msg::PlayerVitals, m);
		if (i % 10 == 0)
			t::pump_for({&host.s, &cl.s}, 2);
	}
	REQUIRE(t::pump_until({&host.s, &cl.s}, 10000, [&] { return got.size() == 200; }));
	bool ordered = true;
	for (uint32_t i = 0; i < got.size(); ++i)
	{
		Reader r(got[i].bytes.data(), got[i].bytes.size());
		ordered = ordered && r.u32() == i;
	}
	CHECK(ordered);

	// Switching the simulation off drains what is queued and keeps order.
	got.clear();
	host.s.send(1, Lane::Reliable, Msg::PlayerVitals, w);
	host.s.set_netsim(NetSim());
	Writer last;
	last.u32(0xFFFFFFFFu);
	host.s.send(1, Lane::Reliable, Msg::PlayerVitals, last);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() == 2; }));
	Reader r0(got[1].bytes.data(), got[1].bytes.size());
	CHECK_EQ(r0.u32(), 0xFFFFFFFFu);
}

TEST(session_destroy_and_shutdown_are_safe_in_any_state)
{
	{
		Session idle; // never started
		idle.shutdown("nothing");
	}
	{
		Node host("Boss", 37033), cl("Alice", 37033);
		std::string err;
		REQUIRE(host.host(&err));
		REQUIRE(cl.connect(37033, &err)); // destroyed while still connecting
	}
	{
		Node host("Boss", 37033), cl("Alice", 37033);
		start_and_join(host, {&cl}, 37033);
		host.s.send_blob(1, 1, t::random_bytes(5u * 1024 * 1024, 1)); // destroyed mid-transfer
		t::pump_for({&host.s, &cl.s}, 30);
	}
	// Callback that shuts the session down from inside itself.
	{
		Node host("Boss", 37034), cl("Alice", 37034);
		std::string err;
		REQUIRE(host.host(&err));
		cl.s.on_welcome = [&cl](const WelcomeMsg&) { cl.s.shutdown("self-shutdown in callback"); };
		REQUIRE(cl.connect(37034, &err));
		REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return !host.left.empty(); }));
		CHECK(cl.s.role() == Role::None);
		CHECK_EQ(host.left[0].second, std::string("self-shutdown in callback"));
	}
}

TEST(netsim_loss_applies_on_receive_side_too)
{
	size_t reliable = 0;
	const size_t got = run_loss_round(37035, 0.5f, &reliable, true);
	std::printf("    receiver-side loss: unreliable delivered %zu of 1000, reliable %zu\n", got, reliable);
	CHECK(got >= 300 && got <= 700);
	CHECK_EQ(reliable, size_t(1000));
}

// ============================================================================ more edge cases

TEST(unreliable_lane_large_packets_arrive_whole)
{
	Node host("Boss", 37036), cl("Alice", 37036);
	start_and_join(host, {&cl}, 37036);
	std::vector<Received> got;
	cl.s.on(Msg::EntitySnapshot, collect(got));
	std::vector<std::vector<uint8_t>> sent;
	for (int i = 0; i < 40; ++i)
	{
		sent.push_back(t::random_bytes(6000 + size_t(i) * 37, 1000 + uint64_t(i))); // several fragments each
		Writer w;
		w.bytes(sent.back().data(), sent.back().size());
		host.s.send(1, Lane::Unreliable, Msg::EntitySnapshot, w);
		t::pump_for({&host.s, &cl.s}, 4);
	}
	t::pump_for({&host.s, &cl.s}, 300);
	std::printf("    large unreliable packets delivered: %zu of 40\n", got.size());
	CHECK(got.size() >= 38); // loopback: no real loss expected, tolerate ENet throttling of a packet or two
	for (const Received& r : got)
	{
		bool match = false;
		for (const auto& s : sent)
			match = match || s == r.bytes;
		CHECK(match); // whole payloads only, never a torn one
	}
}

TEST(connect_timeout_when_host_never_welcomes)
{
	RawHost fake;
	fake.answer_hello = false;
	REQUIRE(fake.listen(37037));
	Node cl("Alice", 37037);
	cl.cfg.connect_timeout_ms = 1200;
	std::string err;
	const uint64_t t0 = t::now_ms();
	REQUIRE(cl.connect(37037, &err));
	REQUIRE(t::pump_until({&cl.s}, 6000, [&] {
		fake.service();
		return cl.disconnected;
	}));
	CHECK(fake.got_hello);
	CHECK(cl.disc_reason.find("timeout") != std::string::npos);
	CHECK(cl.disc_reason.find("Welcome") != std::string::npos);
	CHECK(cl.disc_at - t0 >= 1100 && cl.disc_at - t0 <= 2200);
	CHECK(cl.s.role() == Role::None);
}

TEST(client_detects_vanished_host_by_silence_timeout)
{
	RawHost fake;
	REQUIRE(fake.listen(37038));
	Node cl("Alice", 37038);
	cl.cfg.peer_timeout_ms = 1500;
	std::string err;
	REQUIRE(cl.connect(37038, &err));
	REQUIRE(t::pump_until({&cl.s}, 5000, [&] {
		fake.service();
		return cl.welcomed;
	}));
	CHECK_EQ(cl.s.self(), PeerId(1));
	CHECK_EQ(cl.s.peers()[0].nick, std::string("Fake"));
	fake.vanish();
	const uint64_t t0 = t::now_ms();
	REQUIRE(t::pump_until({&cl.s}, 15000, [&] { return cl.disconnected; }));
	CHECK(cl.disc_reason.find("lost") != std::string::npos);
	CHECK(cl.disc_at - t0 >= 1000);
	CHECK(cl.s.role() == Role::None);
	CHECK(!cl.s.is_active());
}

TEST(host_drops_transport_connection_that_never_says_hello)
{
	Node host("Boss", 37039);
	host.cfg.connect_timeout_ms = 800;
	std::string err;
	REQUIRE(host.host(&err));
	RawPeer raw;
	REQUIRE(raw.connect(37039));
	const uint64_t t0 = t::now_ms();
	REQUIRE(t::pump_until({&host.s}, 5000, [&] {
		raw.service();
		return raw.disconnected;
	}));
	CHECK(t::now_ms() - t0 >= 700);
	CHECK(host.logged("no Hello within"));
	CHECK(host.s.peers().empty() && host.joined.empty());
}

TEST(nicknames_are_sanitized)
{
	Node host("", 37040), a("\x01" "Al\x07" "ice\x7F", 37040), b("", 37040), c("", 37040);
	c.cfg.nick = std::string(47, 'a') + "\xD0\xBF"; // 49 bytes, the last character would be cut in half
	start_and_join(host, {&a, &b, &c}, 37040);
	CHECK_EQ(a.welcome.host_nick, std::string("Host")); // empty host nick gets a default
	REQUIRE(host.joined.size() == 3);
	CHECK_EQ(host.joined[0].nick, std::string("Alice"));
	CHECK_EQ(host.joined[1].nick, std::string("Player2")); // default is derived from the slot
	CHECK_EQ(host.joined[2].nick, std::string(47, 'a'));
}

TEST(peer_info_reports_rtt_and_loss)
{
	Node host("Boss", 37041), cl("Alice", 37041);
	start_and_join(host, {&cl}, 37041);
	t::pump_for({&host.s, &cl.s}, 800);
	const auto hp = host.s.peers();
	REQUIRE(hp.size() == 1);
	CHECK(hp[0].rtt_ms < 100);
	CHECK(hp[0].packet_loss >= 0.f && hp[0].packet_loss <= 1.f);
	const PeerInfo* h = cl.s.peer(kHostPeer);
	REQUIRE(h != nullptr);
	CHECK(h->rtt_ms < 100);
}

TEST(callbacks_may_use_the_session_freely)
{
	// on_peer_joined sends, broadcasts and kicks from inside the callback; on_peer_left connects nothing.
	Node host("Boss", 37042), a("Alice", 37042), b("Bob", 37042);
	std::vector<Received> a_got;
	a.s.on(Msg::JoinComplete, collect(a_got));
	host.s.on_peer_joined = [&host](const PeerInfo& p) {
		host.joined.push_back(p);
		Writer w;
		w.u32(p.id);
		host.s.send(p.id, Lane::Reliable, Msg::JoinComplete, w);
		if (p.nick == "Bob")
			host.s.kick(p.id, RejectReason::Kicked, "no bobs");
	};
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(a.connect(37042, &err));
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return !a_got.empty(); }));
	REQUIRE(b.connect(37042, &err));
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return b.disconnected; }));
	CHECK(b.disc_reason.find("no bobs") != std::string::npos);
	CHECK_EQ(host.s.peers().size(), size_t(1));
	REQUIRE(a_got.size() == 1);
	Reader r(a_got[0].bytes.data(), a_got[0].bytes.size());
	CHECK_EQ(r.u32(), uint32_t(1));
}

// ============================================================================ keep-alive (W9)

TEST(held_link_survives_a_long_owner_stall)
{
	// A client loading a level does not pump the network for many seconds. While it holds the link, the
	// transport's helper thread keeps answering, the host does not drop it, and what the host sent meanwhile
	// is delivered once the client pumps again.
	Node host("Boss", 37043), cl("Alice", 37043);
	host.cfg.peer_timeout_ms = 1500;
	cl.cfg.peer_timeout_ms = 1500;
	start_and_join(host, {&cl}, 37043);
	cl.s.hold_connection(10000);
	host.s.send_chat("while you were loading");
	t::pump_for({&host.s}, 4000); // the client's owner thread is "blocked": only the host pumps
	CHECK(host.left.empty());
	CHECK_EQ(host.s.peers().size(), size_t(1));
	CHECK(cl.s.keepalive_services() > 0);
	cl.s.hold_connection(0);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 3000, [&] { return !cl.chat.empty(); }));
	CHECK_EQ(cl.chat[0].second, std::string("while you were loading"));
	CHECK(!cl.disconnected);
	t::pump_for({&host.s, &cl.s}, 2500); // released, but pumping: still connected
	CHECK(host.left.empty());
	CHECK(!cl.disconnected);
}

TEST(stall_without_hold_or_after_it_expired_drops_the_peer)
{
	// A crashed client (stuck on an error dialog) pumps nothing and holds nothing: dropped by the silence
	// timeout. A hold is bounded: once it expires the same happens.
	Node host("Boss", 37044), cl("Alice", 37044);
	host.cfg.peer_timeout_ms = 1500;
	start_and_join(host, {&cl}, 37044);
	cl.s.hold_connection(700);
	const uint64_t t0 = t::now_ms();
	REQUIRE(t::pump_until({&host.s}, 15000, [&] { return !host.left.empty(); }));
	const uint64_t took = t::now_ms() - t0;
	CHECK(took >= 700 + 1000);
	CHECK(host.left[0].second.find("lost") != std::string::npos);
	CHECK(host.s.peers().empty());
}
