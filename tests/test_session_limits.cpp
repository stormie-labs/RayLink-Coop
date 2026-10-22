// Anomaly Coop unit tests: who may hold a player slot (player key, reconnect) and what the host keeps of a key;
// what a host takes from a client (blobs, joins, request rates), the world epoch and which way the join lifecycle goes.
// Real Sessions over 127.0.0.1 in one process. Ports 37100+n (test_net.cpp uses 37000+n).
#include "test_util.h"
#include "coop_limits.h"

#include <enet/enet.h>

#include <algorithm>
#include <cstring>
#include <iterator>
#include <set>

using namespace coop;

namespace
{
using t::Node;

// Starts a host and joins `clients` one after another (slots 1, 2, ...), then lets the last PeerList arrive.
void host_and_join(Node& host, std::initializer_list<Node*> clients, uint16_t port)
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
	for (Node* c : clients)
		REQUIRE(t::pump_until({&host.s, &c->s}, 5000, [&] { return c->s.peers().size() == clients.size(); }));
}

size_t peers_with_key(const Session& s, const PlayerKey& key)
{
	size_t n = 0;
	for (const PeerInfo& p : s.peers())
		if (p.key == key)
			++n;
	return n;
}

std::string hex(const Sha256& d) { return to_hex(d.data(), d.size()); }

// Longer than kReplaceSilentLinkMs (3000, coop_session.cpp): a link not pumped for this long may be replaced.
constexpr uint32_t kSilentMs = 3300;

bool has_delete_advice(const std::string& text)
{
	return text.find("delete") != std::string::npos || text.find("Delete") != std::string::npos;
}
} // namespace

// ============================================================================ R1 I2: player key and reconnect

TEST(session_reconnect_same_key)
{
	// Alice's game crashed or was restarted: she joins again with the same key while the host still holds her old
	// link (it is only dropped after the silence timeout). The old link is silent: the new connection replaces it.
	Node host("Boss", 37101), alice("Alice", 37101), bob("Bob", 37101), again("Alice", 37101);
	again.cfg.key = alice.cfg.key;
	host_and_join(host, {&alice, &bob}, 37101);
	REQUIRE(alice.s.self() == PeerId(1));

	// The old process is silent from now on (not pumped), its link is still up on the host.
	t::pump_for({&host.s, &bob.s}, kSilentMs);
	REQUIRE(host.s.peers().size() == 2);
	std::string err;
	REQUIRE(again.connect(37101, &err));
	REQUIRE(t::pump_until({&host.s, &bob.s, &again.s}, 5000, [&] { return again.welcomed || again.rejected; }));
	CHECK(again.welcomed);
	CHECK(!again.rejected);
	CHECK(again.s.is_active());
	CHECK_EQ(again.welcome.slot, PeerId(1)); // the freed slot

	// Host: the old link left, the new one joined, the key is held by exactly one connection.
	REQUIRE(t::pump_until({&host.s, &bob.s, &again.s}, 5000, [&] { return host.left.size() == 1 && host.joined.size() == 3; }));
	CHECK_EQ(host.left[0].first, PeerId(1));
	CHECK_EQ(host.joined[2].id, again.welcome.slot);
	CHECK(host.joined[2].key == alice.cfg.key);
	CHECK_EQ(host.s.peers().size(), size_t(2));
	CHECK_EQ(peers_with_key(host.s, alice.cfg.key), size_t(1));
	CHECK(!host.logged(reject_reason_name(RejectReason::DuplicateKey)));

	// Bob keeps playing and sees Alice back.
	REQUIRE(t::pump_until({&host.s, &bob.s, &again.s}, 5000, [&] { return bob.left.size() == 1 && bob.joined.size() == 2; }));
	CHECK(bob.s.is_active());
	CHECK_EQ(bob.s.peers().size(), size_t(2));

	// If the old process comes back to life it learns why its link is gone (a joined client gets a kick as
	// on_disconnected with the reason).
	REQUIRE(t::pump_until({&host.s, &bob.s, &again.s, &alice.s}, 5000, [&] { return alice.rejected || alice.disconnected; }));
	CHECK(alice.disconnected);
	CHECK(alice.disc_reason.find(reject_reason_name(RejectReason::Kicked)) != std::string::npos);
	CHECK(alice.disc_reason.find("connection replaced: the same player key reconnected") != std::string::npos);
	CHECK(!alice.s.is_active());
	// The reason everybody sees for the old slot is neutral.
	CHECK_EQ(host.left[0].second, std::string("connection replaced: the same player key reconnected"));
	CHECK_EQ(bob.left[0].second, std::string("connection replaced: the same player key reconnected"));
	// ... and that does not touch the new connection.
	t::pump_for({&host.s, &bob.s, &again.s, &alice.s}, 200);
	CHECK(again.s.is_active());
	CHECK(!again.rejected && !again.disconnected);
	CHECK_EQ(host.s.peers().size(), size_t(2));
}

TEST(session_same_key_while_the_old_link_is_live_is_refused)
{
	// Ruling 10: Alice's game is alive and talking (a second game started from the same folder, or a copy of it):
	// the new connection is refused, Alice keeps her place.
	Node host("Boss", 37104), alice("Alice", 37104), again("Alice", 37104);
	again.cfg.key = alice.cfg.key;
	host_and_join(host, {&alice}, 37104);
	t::pump_for({&host.s, &alice.s}, 600); // a ping round on an idle link

	std::string err;
	REQUIRE(again.connect(37104, &err));
	REQUIRE(t::pump_until({&host.s, &alice.s, &again.s}, 5000, [&] { return again.welcomed || again.rejected; }));
	CHECK(again.rejected);
	CHECK(!again.welcomed);
	CHECK(again.reject.reason == RejectReason::DuplicateKey);
	CHECK(again.reject.text.find("in this session right now") != std::string::npos);
	CHECK(!has_delete_advice(again.reject.text));

	t::pump_for({&host.s, &alice.s, &again.s}, 300);
	CHECK(alice.s.is_active());
	CHECK(!alice.disconnected && !alice.rejected);
	CHECK(host.left.empty());
	REQUIRE(host.s.peers().size() == 1);
	CHECK(host.s.peers()[0].key == alice.cfg.key);
}

TEST(session_reconnect_same_key_into_a_full_session)
{
	// The session is full, but a reconnect takes the player's own place: no SessionFull.
	Node host("Boss", 37102), alice("Alice", 37102), again("Alice", 37102);
	host.cfg.max_players = 2; // host + one client
	again.cfg.key = alice.cfg.key;
	host_and_join(host, {&alice}, 37102);
	t::pump_for({&host.s}, kSilentMs); // Alice's game is gone

	std::string err;
	REQUIRE(again.connect(37102, &err));
	REQUIRE(t::pump_until({&host.s, &again.s}, 5000, [&] { return again.welcomed || again.rejected; }));
	CHECK(again.welcomed);
	CHECK(!again.rejected);
	CHECK_EQ(host.s.peers().size(), size_t(1));
	CHECK_EQ(peers_with_key(host.s, alice.cfg.key), size_t(1));
}

TEST(session_mismatched_game_with_a_players_key_does_not_kick_him)
{
	// Build and content are checked before the key: a game that cannot join never replaces a player, even one whose
	// link is silent long enough to be replaced.
	Node host("Boss", 37105), alice("Alice", 37105), c1("C1", 37105), c2("C2", 37105);
	c1.cfg.key = alice.cfg.key;
	c1.cfg.build_id = "some-other-build";
	c2.cfg.key = alice.cfg.key;
	c2.cfg.manifest.clear();
	host_and_join(host, {&alice}, 37105);
	t::pump_for({&host.s}, kSilentMs);

	std::string err;
	REQUIRE(c1.connect(37105, &err));
	REQUIRE(t::pump_until({&host.s, &c1.s}, 5000, [&] { return c1.rejected || c1.welcomed; }));
	CHECK(c1.reject.reason == RejectReason::BuildMismatch);
	REQUIRE(c2.connect(37105, &err));
	REQUIRE(t::pump_until({&host.s, &c2.s}, 5000, [&] { return c2.rejected || c2.welcomed; }));
	CHECK(c2.reject.reason == RejectReason::ContentMismatch);
	CHECK(host.left.empty());
	CHECK_EQ(host.s.peers().size(), size_t(1));

	// Alice's game wakes up: still in.
	t::pump_for({&host.s, &alice.s}, 300);
	CHECK(alice.s.is_active());
	CHECK(!alice.disconnected && !alice.rejected);
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

TEST(session_duplicate_key_for_the_hosts_key)
{
	// The host's own key from a client = a game folder copied from the host: refused, without advice to delete
	// the key (a deleted key is a lost character).
	Node host("Boss", 37103), cl("Alice", 37103);
	cl.cfg.key = host.cfg.key;
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(cl.connect(37103, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.rejected || cl.welcomed; }));
	CHECK(cl.rejected);
	CHECK(cl.reject.reason == RejectReason::DuplicateKey);
	CHECK(cl.reject.text.find("host") != std::string::npos);
	CHECK(!has_delete_advice(cl.reject.text));
	CHECK(host.s.peers().empty());
}

// ============================================================================ R1 I1: what the host keeps of a key

TEST(sha256_known_vectors)
{
	Sha256 d{};
	REQUIRE(sha256("", 0, d));
	CHECK_EQ(hex(d), std::string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
	REQUIRE(sha256("abc", 3, d));
	CHECK_EQ(hex(d), std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
	const char* two_blocks = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
	REQUIRE(sha256(two_blocks, std::strlen(two_blocks), d));
	CHECK_EQ(hex(d), std::string("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
	// A player key is 16 bytes.
	const PlayerKey zero{};
	REQUIRE(sha256(zero.data(), zero.size(), d));
	CHECK_EQ(hex(d), std::string("374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb"));
	std::string text;
	REQUIRE(key_digest_hex(zero, text));
	CHECK_EQ(text, std::string("374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb"));
}

namespace
{
const std::string kKey32 = "00112233445566778899aabbccddeeff";
const std::string kDigest64 = "374708fff7719dd5979ec875d56cd2286f6d3cf7ec317a3b25632aab28ec37bb";

std::string key_value_of(const std::string& ini)
{
	size_t at = 0, len = 0;
	return find_key_value(ini, at, len) ? ini.substr(at, len) : std::string("<none>");
}
} // namespace

TEST(custom_data_key_line_parse_is_strict)
{
	CHECK_EQ(key_value_of("[coop]\nkey = " + kKey32 + "\nnick = Bob\n"), kKey32);
	CHECK_EQ(key_value_of("[coop]\nkey = " + kDigest64 + "\nnick = Bob\nvitals = 1,1,0,1,1,0\n"), kDigest64);
	CHECK_EQ(key_value_of("[coop]\r\nkey=" + kDigest64 + "\r\nnick = Bob\r\n"), kDigest64);
	CHECK_EQ(key_value_of("[coop]\n\t key \t=\t " + kDigest64 + " \t\nnick = x\n"), kDigest64);
	CHECK_EQ(key_value_of("[coop]\nkey = " + kDigest64), kDigest64); // no final newline
	// The original hole: somebody's key anywhere in the text (the nick is the player's own choice) matched.
	CHECK_EQ(key_value_of("[coop]\nnick = key = " + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nnick = " + kKey32 + "\nkey = " + kDigest64 + "\n"), kDigest64);
	CHECK_EQ(key_value_of("[coop]\nkeyboard=" + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey2=" + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey2 = " + kDigest64 + "\nkey = " + kKey32 + "\n"), kKey32);
	// Outside [coop].
	CHECK_EQ(key_value_of("key = " + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[logic]\nkey = " + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nnick = a\n[logic]\nkey = " + kDigest64 + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[logic]\nkey = " + kKey32 + "\n[coop]\nkey = " + kDigest64 + "\n"), kDigest64);
	// The value: exactly 32 or 64 lowercase hex digits.
	CHECK_EQ(key_value_of("[coop]\nkey = " + kDigest64.substr(0, 63) + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey = " + kDigest64 + "0\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey = 3" + kDigest64.substr(1, 62) + "G\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey = A" + kDigest64.substr(1) + "\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey = " + kDigest64.substr(0, 32) + " " + kDigest64.substr(32) + "\n"),
		std::string("<none>"));
	CHECK_EQ(key_value_of(""), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey =\n"), std::string("<none>"));
	CHECK_EQ(key_value_of("[coop]\nkey"), std::string("<none>"));
}

TEST(custom_data_key_migration_in_place)
{
	// A save from before: the key itself. It becomes its digest, every other line stays.
	PlayerKey key{};
	REQUIRE(key_from_hex(kKey32, key));
	std::string digest;
	REQUIRE(key_digest_hex(key, digest));
	const std::string before = "[coop]\nkey = " + kKey32 + "\nnick = Bob\nvitals = 0.900,1.000,0.000,1.000,1.000,0.000\n";
	std::string ini = before;
	CHECK(migrate_key_value(ini));
	CHECK_EQ(ini, "[coop]\nkey = " + digest + "\nnick = Bob\nvitals = 0.900,1.000,0.000,1.000,1.000,0.000\n");
	CHECK_EQ(key_value_of(ini), digest);
	// Done once: a digest stays as it is, and so does text without a valid key line.
	const std::string after = ini;
	CHECK(!migrate_key_value(ini));
	CHECK_EQ(ini, after);
	std::string attack = "[coop]\nnick = key = " + kKey32 + "\n";
	CHECK(!migrate_key_value(attack));
	CHECK_EQ(attack, "[coop]\nnick = key = " + kKey32 + "\n");
	std::string other = "[logic]\nkey = " + kKey32 + "\n";
	CHECK(!migrate_key_value(other));
}

TEST(key_hex_round_trip)
{
	PlayerKey key{};
	REQUIRE(key_from_hex(kKey32, key));
	CHECK_EQ(int(key[0]), 0x00);
	CHECK_EQ(int(key[1]), 0x11);
	CHECK_EQ(int(key[15]), 0xff);
	CHECK_EQ(to_hex(key.data(), key.size()), kKey32);
	const PlayerKey random = generate_player_key();
	PlayerKey back{};
	REQUIRE(key_from_hex(to_hex(random.data(), random.size()), back));
	CHECK(back == random);
	// Anything but 32 lowercase hex digits is refused and leaves a zero key.
	CHECK(!key_from_hex(kKey32.substr(1), back));
	CHECK(back == PlayerKey{});
	CHECK(!key_from_hex(kKey32 + "0", back));
	CHECK(!key_from_hex("0011223344556677889AABBCCDDEEFF0", back));
	CHECK(!key_from_hex("00112233445566778899aabbccddeeg0", back));
}

// ============================================================================ R1 I3, I4, R2 I1, I4: limits, world epoch

namespace
{
// A bare ENet client that speaks the wire protocol by hand: it sends what a Session never would (several blobs
// announced at once, an epoch from the future).
struct RawClient
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

	RawClient() { enet_initialize(); }
	~RawClient()
	{
		if (host)
			enet_host_destroy(host);
		enet_deinitialize();
	}
	RawClient(const RawClient&) = delete;
	RawClient& operator=(const RawClient&) = delete;

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
		ENetEvent ev;
		while (host && enet_host_service(host, &ev, 0) > 0)
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

	void send(Msg type, const Writer& w, uint8_t channel)
	{
		std::vector<uint8_t> buf;
		buf.push_back(uint8_t(uint16_t(type)));
		buf.push_back(uint8_t(uint16_t(type) >> 8));
		buf.insert(buf.end(), w.data().begin(), w.data().end());
		enet_peer_send(peer, channel, enet_packet_create(buf.data(), buf.size(), ENET_PACKET_FLAG_RELIABLE));
		enet_host_flush(host);
	}

	// BlobBegin as protocol 5 lays it out: id, kind, total, crc, world epoch. No chunk follows.
	void blob_begin(uint32_t id, uint32_t kind, uint64_t total, uint32_t epoch)
	{
		Writer w;
		w.u32(id);
		w.u32(kind);
		w.u64(total);
		w.u32(0);
		w.u32(epoch);
		send(Msg::BlobBegin, w, uint8_t(Lane::Bulk));
	}

	const Message* find(Msg type) const
	{
		for (const Message& m : inbox)
			if (m.type == uint16_t(type))
				return &m;
		return nullptr;
	}

	// Text of the host's Reject, "" if none came.
	std::string reject_text() const
	{
		const Message* m = find(Msg::Reject);
		if (!m)
			return std::string();
		RejectMsg rm;
		Reader r(m->payload.data(), m->payload.size());
		return rm.read(r) ? std::string(reject_reason_name(rm.reason)) + ": " + rm.text : std::string("<bad Reject>");
	}
};

bool raw_join(RawClient& raw, Node& host, uint16_t port)
{
	if (!raw.connect(port))
		return false;
	if (!t::pump_until({&host.s}, 3000, [&] {
			raw.service();
			return raw.connected;
		}))
		return false;
	HelloMsg h;
	h.build_id = host.cfg.build_id;
	h.content_fp = manifest_fingerprint(host.cfg.manifest);
	h.key = generate_player_key();
	h.nick = "Raw";
	Writer w;
	h.write(w);
	raw.send(Msg::Hello, w, 0);
	return t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return raw.find(Msg::Welcome) != nullptr || raw.find(Msg::Reject) != nullptr;
	});
}

void pump_with(Node& host, RawClient& raw, uint32_t ms)
{
	const uint64_t start = t::now_ms();
	t::pump_until({&host.s}, ms, [&] {
		raw.service();
		return t::now_ms() - start >= ms;
	});
}

// Starts a host in world epoch `epoch` (the game sets it after host(): a new session starts at 0) and joins `cl`.
void host_at_epoch_and_join(Node& host, Node& cl, uint16_t port, uint32_t epoch)
{
	std::string err;
	REQUIRE(host.host(&err));
	host.s.set_world_epoch(epoch);
	REQUIRE(cl.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
}

bool kicked(const Node& n, const std::string& why)
{
	return n.disconnected && n.disc_reason.find(reject_reason_name(RejectReason::Malformed)) != std::string::npos &&
		n.disc_reason.find(why) != std::string::npos;
}

constexpr uint32_t kBlobOk = 7; // a kind the host's game accepts from clients in these tests
} // namespace

TEST(limits_blob_kind)
{
	// R1 I3: a client could announce 4 x 256 MB and the host would buffer it. The host takes only the blob kinds its
	// game accepts from clients, each at most 1 MiB; the boundary is exact.
	static_assert(kMaxClientBlobBytes == 1024u * 1024u, "brief: 1 MiB per blob from a client");
	Node host("Boss", 37110), a("Alice", 37110), b("Bob", 37110), c("Carl", 37110);
	host.s.accept_client_blob(kBlobOk);
	host_and_join(host, {&a, &b, &c}, 37110);

	// Exactly 1 MiB of an accepted kind: taken.
	const std::vector<uint8_t> limit = t::random_bytes(size_t(kMaxClientBlobBytes), 11);
	REQUIRE(a.s.send_blob(kHostPeer, kBlobOk, limit) != 0);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s, &c.s}, 20000, [&] { return !host.blobs.empty() || a.disconnected; }));
	REQUIRE(host.blobs.size() == 1);
	CHECK_EQ(host.blobs[0].kind, kBlobOk);
	CHECK_EQ(host.blobs[0].from, PeerId(1));
	CHECK(host.blobs[0].data == limit);
	CHECK(a.s.is_active());

	// 1 MiB + 1: the sender is kicked as malformed when it announces it; nothing reaches the game.
	REQUIRE(b.s.send_blob(kHostPeer, kBlobOk, t::random_bytes(size_t(kMaxClientBlobBytes) + 1, 12)) != 0);
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s, &c.s}, 10000, [&] { return b.disconnected; }));
	CHECK(kicked(b, "over the client limit"));

	// A kind the game does not take from clients (the world save is host -> client only), however small.
	REQUIRE(c.s.send_blob(kHostPeer, kBlobOk + 1, std::vector<uint8_t>(10, 1)) != 0);
	REQUIRE(t::pump_until({&host.s, &a.s, &c.s}, 10000, [&] { return c.disconnected; }));
	CHECK(kicked(c, "not accepted from clients"));

	t::pump_for({&host.s, &a.s}, 100);
	CHECK_EQ(host.blobs.size(), size_t(1));
	CHECK(a.s.is_active());
	CHECK_EQ(host.s.peers().size(), size_t(1));
	CHECK_EQ(host.progress.size(), size_t(16)); // Alice's 1 MiB in 64 KiB chunks, not a byte of the others

	// A host whose game takes nothing from clients (the default) refuses every kind.
	Node bare("Boss", 37111), d("Dan", 37111);
	host_and_join(bare, {&d}, 37111);
	REQUIRE(d.s.send_blob(kHostPeer, kBlobOk, std::vector<uint8_t>(10, 1)) != 0);
	REQUIRE(t::pump_until({&bare.s, &d.s}, 10000, [&] { return d.disconnected; }));
	CHECK(kicked(d, "not accepted from clients"));
	CHECK(bare.blobs.empty());
}

TEST(limits_blob_kind_bytes_in_flight)
{
	// R1 I3: announced but unfinished blobs of one client may hold at most 4 MiB on the host (a Session sends its
	// blobs one after another; a modified client announces several and never finishes them).
	static_assert(kMaxClientBlobBytesInFlight == 4u * 1024u * 1024u, "brief: 4 MiB in flight per client");
	Node host("Boss", 37112);
	host.s.accept_client_blob(kBlobOk);
	std::string err;
	REQUIRE(host.host(&err));

	// Four blobs of exactly 1 MiB in flight = 4 MiB: still fine.
	RawClient full;
	REQUIRE(raw_join(full, host, 37112));
	REQUIRE(full.find(Msg::Welcome) != nullptr);
	for (uint32_t id = 1; id <= 4; ++id)
		full.blob_begin(id, kBlobOk, kMaxClientBlobBytes, 0);
	pump_with(host, full, 300);
	CHECK(full.find(Msg::Reject) == nullptr);
	CHECK_EQ(host.s.peers().size(), size_t(1));
	// One more byte in flight: kicked.
	full.blob_begin(5, kBlobOk, 1, 0);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		full.service();
		return full.find(Msg::Reject) != nullptr;
	}));
	CHECK(full.reject_text().find("Malformed") != std::string::npos);
	CHECK(full.reject_text().find("unfinished blob bytes") != std::string::npos);

	// The count of unfinished blobs stays limited too (a fifth empty one adds no bytes).
	RawClient many;
	REQUIRE(raw_join(many, host, 37112));
	REQUIRE(many.find(Msg::Welcome) != nullptr);
	for (uint32_t id = 1; id <= 4; ++id)
		many.blob_begin(id, kBlobOk, kMaxClientBlobBytes, 0);
	many.blob_begin(5, kBlobOk, 0, 0);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		many.service();
		return many.find(Msg::Reject) != nullptr;
	}));
	CHECK(many.reject_text().find("too many unfinished blobs") != std::string::npos);

	// A kind the game does not take, announced raw.
	RawClient other;
	REQUIRE(raw_join(other, host, 37112));
	other.blob_begin(1, kBlobOk + 1, 10, 0);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		other.service();
		return other.find(Msg::Reject) != nullptr;
	}));
	CHECK(other.reject_text().find("not accepted from clients") != std::string::npos);
	t::pump_for({&host.s}, 100);
	CHECK(host.s.peers().empty());
	CHECK(host.blobs.empty());
}

TEST(limits_blob_replaced_by_newer_of_the_same_kind)
{
	// R1 I4: a newer blob of the same kind to the same peer replaces the one still queued or streaming (the host
	// never holds two world saves for one player); other kinds are not touched.
	Node host("Boss", 37113), a("Alice", 37113);
	host_and_join(host, {&a}, 37113);
	const std::vector<uint8_t> old_world = t::random_bytes(6u * 1024 * 1024, 21);
	const uint32_t old_id = host.s.send_blob(1, 1, old_world);
	REQUIRE(old_id != 0);
	REQUIRE(t::pump_until({&host.s, &a.s}, 10000, [&] { return !a.progress.empty(); }));
	REQUIRE(a.blobs.empty());
	const std::vector<uint8_t> other_kind = t::random_bytes(1000, 22);
	const std::vector<uint8_t> new_world = t::random_bytes(200000, 23);
	const uint32_t other_id = host.s.send_blob(1, 2, other_kind);
	const uint32_t new_id = host.s.send_blob(1, 1, new_world);
	REQUIRE(t::pump_until({&host.s, &a.s}, 20000, [&] { return a.blobs.size() == 2; }));
	t::pump_for({&host.s, &a.s}, 200);
	REQUIRE(a.blobs.size() == 2);
	CHECK_EQ(a.blobs[0].id, other_id);
	CHECK(a.blobs[0].data == other_kind);
	CHECK_EQ(a.blobs[1].id, new_id);
	CHECK(a.blobs[1].data == new_world);
	CHECK(a.logged("dropped: got")); // the old one ended early on Alice's side
	CHECK(host.s.stats(uint16_t(Msg::BlobChunk)).sent_bytes < old_world.size()); // and was not sent in full
	CHECK(a.s.is_active());
}

TEST(limits_join_rate)
{
	// R1 I4, R2 I4: every JoinRequest costs the host a full world save. One join in flight per peer (until its
	// WorldLoaded), at most one join per peer every 5 s; a request that comes too soon waits instead of being lost.
	static_assert(JoinGate::kIntervalMs == 5000, "brief: one join per 5 s");
	using V = JoinGate::Verdict;
	JoinGate g;
	CHECK(g.request(1, 1000) == V::Admit);
	CHECK(g.in_flight(1));
	// One in flight: a second request is refused, however late.
	CHECK(g.request(1, 1001) == V::Refused);
	CHECK(g.request(1, 60000) == V::Refused);
	// Peers are independent.
	CHECK(g.request(2, 1000) == V::Admit);
	// WorldLoaded ends the join once; a repeated or unasked-for WorldLoaded is nothing.
	CHECK(g.loaded(1));
	CHECK(!g.in_flight(1));
	CHECK(!g.loaded(1));
	CHECK(!g.loaded(3));
	// The next join of peer 1: not before 5 s after the last one; it waits and comes due exactly then.
	CHECK(g.request(1, 5999) == V::Later);
	CHECK(g.waiting(1));
	CHECK(!g.in_flight(1));
	CHECK(g.request(1, 5999) == V::Refused); // one waiting request is enough
	CHECK(g.due(5999).empty());
	const std::vector<PeerId> due = g.due(6000);
	REQUIRE(due.size() == 1);
	CHECK_EQ(due[0], PeerId(1));
	CHECK(g.in_flight(1));
	CHECK(!g.waiting(1));
	CHECK(g.due(7000).empty());
	CHECK(g.loaded(1));
	CHECK(g.request(1, 11000) == V::Admit); // 6000 + 5000
	CHECK(g.loaded(1));

	// A world change voids joins in flight and waiting ones (everybody rejoins); the interval holds across it.
	CHECK(g.request(1, 13000) == V::Later);
	CHECK(g.loaded(2));
	CHECK(g.request(2, 7000) == V::Admit); // 1000 + 5000 <= 7000
	g.world_replaced();
	CHECK(!g.in_flight(2));
	CHECK(!g.waiting(1));
	CHECK(!g.loaded(2)); // the old world's WorldLoaded
	CHECK(g.due(20000).empty());
	CHECK(g.request(2, 11999) == V::Later);
	CHECK(g.request(1, 16000) == V::Admit);

	// A peer that left: its join and its waiting request are gone; its slot keeps the interval.
	g.forget(1);
	CHECK(!g.in_flight(1));
	CHECK(!g.loaded(1));
	CHECK(g.request(1, 20999) == V::Later);
	g.forget(1);
	CHECK(g.due(30000).size() == 1); // peer 2 only
	CHECK(g.request(1, 30000) == V::Admit);
}

TEST(limits_message_rate)
{
	// R2 I4: heavy requests of a client (StateDumpRequest) are rate limited per client before their handler.
	Node host("Boss", 37114), a("Alice", 37114), b("Bob", 37114);
	host.s.limit_rate(Msg::StateDumpRequest, 4, 1000); // 4 at once, one more every second
	std::vector<PeerId> dumps, others;
	host.s.on(Msg::StateDumpRequest, [&](PeerId from, Reader&) { dumps.push_back(from); });
	host.s.on(Msg::ScriptEvent, [&](PeerId from, Reader&) { others.push_back(from); });
	host_and_join(host, {&a, &b}, 37114);

	for (int i = 0; i < 10; ++i)
	{
		a.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, Writer());
		a.s.send(kHostPeer, Lane::Reliable, Msg::ScriptEvent, Writer());
	}
	b.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return others.size() == 10 && dumps.size() >= 5; }));
	t::pump_for({&host.s, &a.s, &b.s}, 50);
	CHECK_EQ(dumps.size(), size_t(5)); // Alice's 4, Bob's own bucket
	CHECK_EQ(std::count(dumps.begin(), dumps.end(), PeerId(2)), std::ptrdiff_t(1));
	CHECK_EQ(others.size(), size_t(10)); // other types are not limited
	CHECK(host.logged("rate limit"));
	CHECK(host.left.empty()); // dropped, not punished
	// T12 review (Ruling 18): every drop is counted by type (the log line comes once per client and type).
	CHECK_EQ(host.s.stats(uint16_t(Msg::StateDumpRequest)).rate_dropped, uint64_t(6)); // Alice's 10 - 4
	CHECK_EQ(host.s.stats(uint16_t(Msg::StateDumpRequest)).recv_count, uint64_t(11));
	CHECK_EQ(host.s.stats(uint16_t(Msg::ScriptEvent)).rate_dropped, uint64_t(0));

	// Tokens come back with time: two after 2.1 s.
	t::pump_for({&host.s, &a.s, &b.s}, 2100);
	for (int i = 0; i < 5; ++i)
		a.s.send(kHostPeer, Lane::Reliable, Msg::StateDumpRequest, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return dumps.size() >= 7; }));
	t::pump_for({&host.s, &a.s, &b.s}, 50);
	CHECK_EQ(dumps.size(), size_t(7));
	CHECK_EQ(host.s.stats(uint16_t(Msg::StateDumpRequest)).rate_dropped, uint64_t(9)); // + 3 of the 5
}

TEST(limits_client_rate_rules)
{
	// F2 T3: one table of what a host takes from each client (coop_join installs it). Equip, spots, infos, script
	// events, story resyncs, vitals, money and talk locks joined the F0 two (heavy requests, level exit votes).
	struct Expected
	{
		Msg type;
		uint32_t burst, refill_ms;
	};
	const Expected expected[] = {{Msg::StateDumpRequest, 64, 50}, {Msg::TransitionVote, 4, 2000}, {Msg::PlayerEquip, 8, 400},
		{Msg::PlayerVitals, 4, 1000}, {Msg::MapSpot, 32, 250}, {Msg::InfoPortion, 64, 50}, {Msg::StoryResync, 4, 5000},
		{Msg::ScriptEvent, 64, 20}, {Msg::ReqMoney, 32, 100}, {Msg::DialogLock, 10, 1000}};
	for (const Expected& e : expected)
	{
		const limits::RateRule* rule = nullptr;
		for (const limits::RateRule& r : limits::kClientRateRules)
			if (r.type == e.type)
				rule = &r;
		CHECK_EQ(std::string(msg_name(e.type)) + (rule ? " has a rule" : " has no rule"), std::string(msg_name(e.type)) + " has a rule");
		if (!rule)
			continue;
		CHECK_EQ(rule->burst, e.burst);
		CHECK_EQ(rule->refill_ms, e.refill_ms);
	}
	for (const limits::RateRule& r : limits::kClientRateRules)
	{
		CHECK_EQ(std::string(msg_name(r.type)) +
		        (std::any_of(std::begin(expected), std::end(expected), [&](const Expected& e) { return e.type == r.type; })
		                ? " is expected"
		                : " is not expected"),
		    std::string(msg_name(r.type)) + " is expected");
		// a rule for a message clients do not send would be dead (the session kicks the sender before it)
		CHECK(msg_sender(r.type) != MsgSender::HostOnly);
		// 0 removes a limit (Session::limit_rate); one rule per type, the session keeps the last
		CHECK(r.burst > 0 && r.refill_ms > 0);
		CHECK_EQ(std::count_if(std::begin(limits::kClientRateRules), std::end(limits::kClientRateRules),
		             [&](const limits::RateRule& o) { return o.type == r.type; }),
		    std::ptrdiff_t(1));
	}
}

TEST(limits_rate_drops_equip_burst)
{
	// F2 T3: with the game's table a client's PlayerEquip passes 8 in a row, then one per 400 ms. An honest client sends
	// one per 500 ms at most (coop_equip.cpp kEquipCheckMs: a change, or the refresh every 5 s).
	Node host("Boss", 37119), a("Alice", 37119);
	for (const limits::RateRule& rule : limits::kClientRateRules)
		host.s.limit_rate(rule.type, rule.burst, rule.refill_ms);
	size_t equips = 0;
	host.s.on(Msg::PlayerEquip, [&](PeerId, Reader&) { ++equips; });
	host_and_join(host, {&a}, 37119);
	const auto stats = [&] { return host.s.stats(uint16_t(Msg::PlayerEquip)); };

	// F2 T3 fix round 1: the host's clock is the test's (Session::update takes the time from its caller), so its token
	// bucket sees exactly the time set here however slow this machine is; Alice and the transport run in real time.
	uint64_t host_ms = t::now_ms();
	const auto pump_until_handled = [&](uint64_t count) {
		const uint64_t start = t::now_ms();
		while (equips + stats().rate_dropped < count)
		{
			if (t::now_ms() - start > 5000)
				return false;
			host.s.update(host_ms);
			a.s.update(t::now_ms());
			std::this_thread::sleep_for(std::chrono::milliseconds(1));
		}
		return true;
	};
	const auto send_equips = [&](int n) {
		for (int i = 0; i < n; ++i)
			a.s.send(kHostPeer, Lane::Reliable, Msg::PlayerEquip, Writer());
	};

	send_equips(9);
	REQUIRE(pump_until_handled(9));
	CHECK_EQ(equips, size_t(8));
	CHECK_EQ(stats().rate_dropped, uint64_t(1));
	CHECK(host.logged("rate limit: PlayerEquip"));
	CHECK(host.left.empty()); // dropped, not kicked

	// Half a token after 200 ms: not enough.
	host_ms += 200;
	send_equips(1);
	REQUIRE(pump_until_handled(10));
	CHECK_EQ(equips, size_t(8));
	CHECK_EQ(stats().rate_dropped, uint64_t(2));

	// A whole token 400 ms after the burst: one more passes, the next right after it does not.
	host_ms += 200;
	send_equips(2);
	REQUIRE(pump_until_handled(12));
	CHECK_EQ(equips, size_t(9));
	CHECK_EQ(stats().rate_dropped, uint64_t(3));
}

namespace
{
template <class Pred>
bool pump_nodes(const std::vector<Node*>& nodes, uint32_t timeout_ms, Pred pred)
{
	const uint64_t start = t::now_ms();
	for (;;)
	{
		const uint64_t now = t::now_ms();
		for (Node* n : nodes)
			n->s.update(now);
		if (pred())
			return true;
		if (now - start > timeout_ms)
			return false;
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}
} // namespace

TEST(limits_new_characters_per_session)
{
	// Ruling F2-10 b: a client picks its own player key, and the host made a character for every key its world had none
	// for: new keys farmed the starting kit and money, and each character stays in the save for good. A session makes
	// at most coop_max_new_characters (F2 T3 fix round 1: a host setting, default 8, 1..64, read at each join): the
	// next new key is refused, a player who has a character comes in, and a host who raises the setting lets the
	// refused player in without a new session.
	// The host here does on JoinRequest what coop_join::host_send_world does (its world: the keys with a character;
	// `setting`: the console value).
	static_assert(limits::kNewCharactersDefault == 8 && limits::kNewCharactersMin == 1 && limits::kNewCharactersMax == 64,
	    "coop_max_new_characters: default 8, 1..64");
	constexpr uint16_t kPort = 37121;
	Node host("Boss", kPort), p1("P1", kPort), p2("P2", kPort), p3("P3", kPort), p3_again("P3", kPort), back("P1", kPort);
	back.cfg.key = p1.cfg.key;
	p3_again.cfg.key = p3.cfg.key;
	const std::vector<Node*> all = {&host, &p1, &p2, &p3, &p3_again, &back};
	std::set<std::string> world; // key digests with a character
	limits::NewCharacters made;
	uint32_t setting = 2;
	size_t in_world = 0;
	host.s.on(Msg::JoinRequest, [&](PeerId from, Reader&) {
		const PeerInfo* p = host.s.peer(from);
		std::string digest;
		if (!p || !key_digest_hex(p->key, digest))
			return;
		if (world.count(digest) == 0)
		{
			if (!made.admits(digest, setting))
			{
				host.s.kick(from, limits::kNoNewCharacterReason, limits::no_new_character_text(setting));
				return;
			}
			made.add(digest);
			world.insert(digest);
		}
		++in_world;
	});
	auto join = [&](Node& n) {
		std::string err;
		REQUIRE(n.connect(kPort, &err));
		REQUIRE(pump_nodes(all, 5000, [&] { return n.s.is_active() || n.rejected || n.disconnected; }));
		REQUIRE(n.s.is_active());
		n.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	};
	auto leave = [&](Node& n) {
		const size_t left = host.left.size();
		n.s.shutdown("bye");
		REQUIRE(pump_nodes(all, 5000, [&] { return host.left.size() == left + 1; }));
	};

	// Setting 2: two new keys come in.
	host_and_join(host, {&p1, &p2}, kPort);
	for (Node* n : {&p1, &p2})
		n->s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	REQUIRE(pump_nodes(all, 5000, [&] { return in_world == 2; }));
	CHECK_EQ(made.count(), size_t(2));

	// The third new key: refused with the reason and the setting's value, nothing made.
	join(p3);
	REQUIRE(pump_nodes(all, 5000, [&] { return p3.disconnected; }));
	CHECK(p3.disc_reason.find(reject_reason_name(limits::kNoNewCharacterReason)) != std::string::npos);
	CHECK(p3.disc_reason.find(limits::no_new_character_text(2)) != std::string::npos);
	CHECK(p3.disc_reason.find("all 2 new characters") != std::string::npos);
	CHECK_EQ(in_world, size_t(2));
	CHECK_EQ(made.count(), size_t(2));

	// P1 comes back with his key: his character is in the world, it costs nothing.
	leave(p1); // his character stays in the world
	join(back);
	REQUIRE(pump_nodes(all, 5000, [&] { return in_world == 3; }));
	CHECK(back.s.is_active() && !back.disconnected);
	CHECK_EQ(made.count(), size_t(2));

	// The host loads a save from before P2 came: his character is gone, his key is not new to this session.
	std::string p2_digest;
	REQUIRE(key_digest_hex(p2.cfg.key, p2_digest));
	world.erase(p2_digest);
	p2.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer()); // as after SessionReset
	REQUIRE(pump_nodes(all, 5000, [&] { return in_world == 4 || p2.disconnected; }));
	CHECK(!p2.disconnected);
	CHECK_EQ(made.count(), size_t(2));

	// The host raises the setting to 3: P3 comes in now, in the same session.
	setting = 3;
	join(p3_again);
	REQUIRE(pump_nodes(all, 5000, [&] { return in_world == 5 || p3_again.disconnected; }));
	CHECK(p3_again.s.is_active() && !p3_again.disconnected);
	CHECK_EQ(made.count(), size_t(3));
}

TEST(world_epoch)
{
	// R2 I1: a load or a level change on the host replaces the world. What a client made in the old world
	// (WorldLoaded, JoinRequest, any request) is dropped after the change, the new world's messages do not reach
	// a client still in the old one, and a blob of an old world is not taken by a client already in the new one.
	Node host("Boss", 37115), a("Alice", 37115);
	std::vector<uint16_t> at_host, at_client;
	std::vector<uint32_t> resets;
	auto record = [](std::vector<uint16_t>& into, Msg type) {
		return [&into, type](PeerId, Reader&) { into.push_back(uint16_t(type)); };
	};
	host.s.on(Msg::WorldLoaded, record(at_host, Msg::WorldLoaded));
	host.s.on(Msg::JoinRequest, record(at_host, Msg::JoinRequest));
	a.s.on(Msg::EntityState, record(at_client, Msg::EntityState));
	// As the game does on SessionReset: the new epoch, then the JoinRequest.
	a.s.on(Msg::SessionReset, [&](PeerId, Reader& r) {
		r.str();
		const uint32_t epoch = r.u32();
		if (!r.ok())
			return;
		resets.push_back(epoch);
		a.s.set_world_epoch(epoch);
		a.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	});
	host_at_epoch_and_join(host, a, 37115, 1);
	CHECK_EQ(host.s.world_epoch(), uint32_t(1));
	CHECK_EQ(a.welcome.world_epoch, uint32_t(1));
	CHECK_EQ(a.s.world_epoch(), uint32_t(1));

	// One world: everything goes through.
	a.s.send(kHostPeer, Lane::Reliable, Msg::WorldLoaded, Writer());
	host.s.send(1, Lane::Reliable, Msg::EntityState, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s}, 3000, [&] { return at_host.size() == 1 && at_client.size() == 1; }));

	// The host loads a save: epoch 2. Alice does not know yet.
	host.s.set_world_epoch(2);
	a.s.send(kHostPeer, Lane::Reliable, Msg::WorldLoaded, Writer()); // she finished loading the old world
	a.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	host.s.send(1, Lane::Reliable, Msg::EntityState, Writer()); // a change of the new world
	host.s.broadcast(Lane::Reliable, Msg::EntityState, Writer());
	t::pump_for({&host.s, &a.s}, 300);
	CHECK_EQ(at_host.size(), size_t(1));
	CHECK_EQ(at_client.size(), size_t(1));
	CHECK(host.logged("made in world epoch 1"));
	CHECK(host.left.empty()); // a stale message is dropped, not punished
	CHECK(a.s.is_active());

	// SessionReset still reaches her; she rejoins and her messages count again.
	Writer reset;
	reset.str("the host loaded a save");
	reset.u32(host.s.world_epoch());
	host.s.send(1, Lane::Reliable, Msg::SessionReset, reset);
	REQUIRE(t::pump_until({&host.s, &a.s}, 3000, [&] { return at_host.size() == 2; }));
	CHECK(resets == std::vector<uint32_t>{2});
	CHECK_EQ(a.s.world_epoch(), uint32_t(2));
	CHECK_EQ(at_host[1], uint16_t(Msg::JoinRequest));
	host.s.send(1, Lane::Reliable, Msg::EntityState, Writer());
	a.s.send(kHostPeer, Lane::Reliable, Msg::WorldLoaded, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s}, 3000, [&] { return at_host.size() == 3 && at_client.size() == 2; }));

	// A blob of world 2 is on its way when the host moves to world 3 and Alice rejoins it: she drops it on arrival.
	const std::vector<uint8_t> world2 = t::random_bytes(100000, 31);
	REQUIRE(host.s.send_blob(1, 1, world2) != 0);
	host.s.update(t::now_ms()); // handed to the transport; Alice is not pumped yet
	host.s.set_world_epoch(3);
	a.s.set_world_epoch(3); // what her SessionReset handler does
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return a.logged("made in world epoch 2"); }));
	t::pump_for({&host.s, &a.s}, 100);
	CHECK(a.blobs.empty());
	// The new world's blob is taken.
	const std::vector<uint8_t> world3 = t::random_bytes(100000, 32);
	REQUIRE(host.s.send_blob(1, 1, world3) != 0);
	REQUIRE(t::pump_until({&host.s, &a.s}, 5000, [&] { return !a.blobs.empty(); }));
	CHECK(a.blobs[0].data == world3);
	// And her messages count (the host has her declaration of world 3).
	a.s.send(kHostPeer, Lane::Reliable, Msg::WorldLoaded, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s}, 3000, [&] { return at_host.size() == 4; }));
	CHECK(host.left.empty());
}

TEST(world_epoch_cancels_the_old_worlds_blob)
{
	// R2 I1, R1 I4: the world save of a world that is gone is not streamed any further.
	Node host("Boss", 37116), a("Alice", 37116);
	host_at_epoch_and_join(host, a, 37116, 1);
	CHECK_EQ(a.s.world_epoch(), uint32_t(1));
	const std::vector<uint8_t> old_world = t::random_bytes(6u * 1024 * 1024, 41);
	REQUIRE(host.s.send_blob(1, 1, old_world) != 0);
	REQUIRE(t::pump_until({&host.s, &a.s}, 10000, [&] { return !a.progress.empty(); }));
	host.s.set_world_epoch(2);
	REQUIRE(t::pump_until({&host.s, &a.s}, 10000, [&] { return a.logged("dropped: got"); }));
	t::pump_for({&host.s, &a.s}, 100);
	CHECK(a.blobs.empty());
	CHECK(host.s.stats(uint16_t(Msg::BlobChunk)).sent_bytes < old_world.size());
	CHECK(a.s.is_active());
}

TEST(world_epoch_from_the_future_is_malformed)
{
	// A client tells the host which world it is in; it cannot be in one the host has not made yet.
	Node host("Boss", 37117);
	host.s.set_world_epoch(3);
	std::string err;
	REQUIRE(host.host(&err));
	CHECK_EQ(host.s.world_epoch(), uint32_t(0)); // a new session starts over; the game sets it after host()
	host.s.set_world_epoch(3);
	RawClient raw;
	REQUIRE(raw_join(raw, host, 37117));
	const RawClient::Message* wm = raw.find(Msg::Welcome);
	REQUIRE(wm != nullptr);
	WelcomeMsg welcome;
	Reader wr(wm->payload.data(), wm->payload.size());
	REQUIRE(welcome.read(wr));
	CHECK_EQ(welcome.world_epoch, uint32_t(3));

	Writer same;
	same.u32(3);
	raw.send(Msg::WorldEpoch, same, 0); // the one it is in: fine
	pump_with(host, raw, 200);
	CHECK(raw.find(Msg::Reject) == nullptr);
	Writer future;
	future.u32(4);
	raw.send(Msg::WorldEpoch, future, 0);
	REQUIRE(t::pump_until({&host.s}, 3000, [&] {
		raw.service();
		return raw.find(Msg::Reject) != nullptr;
	}));
	CHECK(raw.reject_text().find("WorldEpoch") != std::string::npos);
}

// ============================================================================ F0 final review: who sends what

TEST(lifecycle_messages_go_one_way)
{
	// F0 final review (Critical): the join lifecycle has a direction. SessionReset, JoinComplete, WorldBlob,
	// LevelChange and AvatarList come from the host only: a client that sends one is kicked as malformed before any
	// handler sees it, as for a core message the wrong way (Welcome from a client). A SessionReset handled at the host
	// wiped its sync state and turned it into a client. JoinRequest, WorldLoaded and TransitionVote come from clients
	// only: a client ignores one from the host.
	const Msg host_only[] = {Msg::SessionReset, Msg::JoinComplete, Msg::WorldBlob, Msg::LevelChange, Msg::AvatarList};
	const Msg client_only[] = {Msg::JoinRequest, Msg::WorldLoaded, Msg::TransitionVote};
	for (Msg m : host_only)
		CHECK(msg_sender(m) == MsgSender::HostOnly);
	for (Msg m : client_only)
		CHECK(msg_sender(m) == MsgSender::ClientOnly);
	// F2 T3: every other game message has a direction too (game_messages_have_direction); these go both ways (an
	// owner's change the host relays): their handlers check the sender.
	for (Msg m : {Msg::ScriptEvent, Msg::PlayerState, Msg::TradeOp, Msg::MapSpot, Msg::InfoPortion})
		CHECK(msg_sender(m) == MsgSender::Either);
	Node host("Boss", 37118), a("Al", 37118), b("Bo", 37118), c("Cy", 37118), d("Di", 37118), e("Ed", 37118),
	    f("Fay", 37118);
	Node* senders[] = {&a, &b, &c, &d, &e};
	std::vector<uint16_t> at_host, at_fay;
	auto record = [](std::vector<uint16_t>& into, Msg type) {
		return [&into, type](PeerId, Reader&) { into.push_back(uint16_t(type)); };
	};
	for (Msg m : host_only)
	{
		host.s.on(m, record(at_host, m));
		f.s.on(m, record(at_fay, m));
	}
	for (Msg m : client_only)
	{
		host.s.on(m, record(at_host, m));
		f.s.on(m, record(at_fay, m));
	}
	host_and_join(host, {&a, &b, &c, &d, &e, &f}, 37118);
	REQUIRE(f.s.self() == PeerId(6));

	// Five clients, each sends one message only the host sends: each is kicked, no handler at the host runs.
	Writer reset;
	reset.str("forged by a client");
	reset.u32(7);
	for (size_t i = 0; i < 5; ++i)
		senders[i]->s.send(kHostPeer, Lane::Reliable, host_only[i], i == 0 ? reset : Writer());
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s, &c.s, &d.s, &e.s, &f.s}, 5000,
	    [&] { return a.disconnected && b.disconnected && c.disconnected && d.disconnected && e.disconnected; }));
	CHECK(at_host.empty());
	for (size_t i = 0; i < 5; ++i)
		CHECK(kicked(*senders[i], std::string("unexpected ") + msg_name(host_only[i])));
	CHECK_EQ(host.left.size(), size_t(5));
	CHECK(f.s.is_active());

	// The host sends a client what only clients send: ignored there, the client stays (it has nobody to punish).
	for (Msg m : client_only)
		host.s.send(6, Lane::Reliable, m, Writer());
	// The right way still works, both ways (reliable lane: in order, after the three above).
	host.s.send(6, Lane::Reliable, Msg::SessionReset, reset);
	f.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	REQUIRE(t::pump_until({&host.s, &f.s}, 3000, [&] { return at_fay.size() == 1 && at_host.size() == 1; }));
	t::pump_for({&host.s, &f.s}, 100);
	CHECK(at_fay == std::vector<uint16_t>{uint16_t(Msg::SessionReset)});
	CHECK(at_host == std::vector<uint16_t>{uint16_t(Msg::JoinRequest)});
	CHECK(f.logged("unexpected JoinRequest"));
	CHECK(f.logged("unexpected TransitionVote"));
	CHECK(f.s.is_active() && !f.disconnected);
	CHECK_EQ(host.s.peers().size(), size_t(1));
}

namespace
{
const char* sender_name(MsgSender s)
{
	switch (s)
	{
	case MsgSender::Either: return "Either";
	case MsgSender::HostOnly: return "HostOnly";
	case MsgSender::ClientOnly: return "ClientOnly";
	}
	return "?";
}

struct Direction
{
	Msg type;
	MsgSender sender;
};

// F2 T3: who sends each game message, from the senders in the game layer (net::host_send / host_broadcast against
// net::client_send, engine/src/xrGame/coop/*.cpp; task-3-report.md lists them). A message without a sender takes
// the direction its comment in coop_protocol.h gives.
constexpr MsgSender kHost = MsgSender::HostOnly;
constexpr MsgSender kClient = MsgSender::ClientOnly;
constexpr MsgSender kBoth = MsgSender::Either;
constexpr Direction kDirections[] = {
	// session / join / world lifecycle
	{Msg::JoinRequest, kClient},
	{Msg::WorldBlob, kHost},
	{Msg::WorldLoaded, kClient},
	{Msg::JoinComplete, kHost},
	{Msg::SessionReset, kHost},
	{Msg::LevelChange, kHost},
	{Msg::TransitionVote, kClient},
	{Msg::AvatarList, kHost},
	// players: the owner sends, the host relays
	{Msg::PlayerState, kBoth},
	{Msg::PlayerVitals, kClient},
	{Msg::PlayerEquip, kBoth},
	{Msg::PlayerAnim, kBoth},
	{Msg::PlayerShot, kBoth},
	{Msg::PlayerGrenade, kBoth},
	{Msg::PlayerHit, kHost},
	{Msg::PlayerWounded, kBoth},
	{Msg::PlayerRevive, kBoth},
	{Msg::PlayerDied, kBoth},
	{Msg::PlayerRules, kHost},
	// entities: the host's world
	{Msg::EntitySpawn, kHost},
	{Msg::EntityDestroy, kHost},
	{Msg::EntitySwitch, kHost},
	{Msg::EntitySnapshot, kHost},
	{Msg::EntityAnim, kHost},
	{Msg::EntityEvent, kClient}, // a client's use / push / throw / activate (coop_objects.h)
	{Msg::EntityHealth, kHost},
	{Msg::EntityDied, kHost},
	{Msg::EntityParent, kHost},
	{Msg::EntityState, kHost},
	{Msg::EntityLocal, kHost},
	{Msg::ItemState, kBoth}, // the owner's item, relayed; the host's authority
	{Msg::EntitySound, kHost},
	// requests and their results
	{Msg::ReqSpawn, kClient},
	{Msg::ReqDestroy, kClient},
	{Msg::ReqTake, kClient},
	{Msg::ReqDrop, kClient},
	{Msg::ReqTransfer, kClient},
	{Msg::ReqUse, kClient},
	{Msg::ReqHit, kClient},
	{Msg::ReqResult, kHost},
	{Msg::ReqMoney, kClient},
	{Msg::ReqContainer, kClient},
	{Msg::ReqItemEvent, kClient},
	{Msg::ReqLaunch, kClient},
	// world state
	{Msg::TimeSync, kHost},
	{Msg::WeatherSync, kHost},
	{Msg::Emission, kHost},
	{Msg::ZoneState, kHost},
	{Msg::TimeRequest, kClient},
	// quests, story, PDA: a client asks, the host applies and tells everybody
	{Msg::InfoPortion, kBoth},
	{Msg::TaskList, kHost},
	{Msg::TaskUpdate, kBoth},
	{Msg::MapSpot, kBoth},
	{Msg::Relation, kBoth},
	{Msg::Progress, kBoth},
	{Msg::StoryHash, kHost},
	{Msg::StoryResync, kClient},
	// dialogs and trade
	{Msg::DialogLock, kClient},
	{Msg::DialogLockResult, kHost},
	{Msg::DialogUnlock, kBoth}, // a client lets go, the host revokes
	{Msg::DialogPhrases, kHost},
	{Msg::DialogSelect, kClient},
	{Msg::TradeOp, kBoth},
	// F2 mod layer
	{Msg::MoneyBalance, kHost},
	// scripting and diagnostics
	{Msg::ScriptEvent, kBoth},
	{Msg::StateDumpRequest, kClient},
	{Msg::StateDump, kHost},
};
} // namespace

TEST(game_messages_have_direction)
{
	// F2 T3: the session checks the direction of every game message on receipt (msg_sender): what only the host sends
	// kicks a client that sends it, what only clients send is ignored by a client. In F0 only the join lifecycle had one.
	for (const Direction& d : kDirections)
		CHECK_EQ(std::string(msg_name(d.type)) + ": " + sender_name(msg_sender(d.type)),
		    std::string(msg_name(d.type)) + ": " + sender_name(d.sender));

	// Each message once, and every game message of coop_protocol.h is here: a new one needs its direction decided.
	for (const Direction& d : kDirections)
		CHECK_EQ(std::count_if(std::begin(kDirections), std::end(kDirections), [&](const Direction& o) { return o.type == d.type; }),
		    std::ptrdiff_t(1));
	for (uint32_t v = uint32_t(Msg::GameBase); v <= 0xFFFFu; ++v)
	{
		const Msg m = static_cast<Msg>(v);
		if (std::strncmp(msg_name(m), "Msg_0x", 6) == 0)
			continue; // not a message of the protocol
		const bool listed =
			std::any_of(std::begin(kDirections), std::end(kDirections), [&](const Direction& d) { return d.type == m; });
		CHECK_EQ(std::string(msg_name(m)) + (listed ? " has a direction" : " has no direction in kDirections"),
		    std::string(msg_name(m)) + " has a direction");
	}
}

TEST(game_messages_the_wrong_way_are_refused)
{
	// F2 T3: the directions beyond the join lifecycle hold on receipt. A client that sends a message of the host's
	// world (a forged EntitySpawn) is kicked before any handler sees it; a client ignores what only clients send.
	Node host("Boss", 37120), a("Al", 37120), b("Bo", 37120);
	std::vector<uint16_t> at_host, at_b;
	auto record = [](std::vector<uint16_t>& into, Msg type) {
		return [&into, type](PeerId, Reader&) { into.push_back(uint16_t(type)); };
	};
	for (Msg m : {Msg::EntitySpawn, Msg::DialogLock})
	{
		host.s.on(m, record(at_host, m));
		b.s.on(m, record(at_b, m));
	}
	host_and_join(host, {&a, &b}, 37120);
	REQUIRE(b.s.self() == PeerId(2));

	a.s.send(kHostPeer, Lane::Reliable, Msg::EntitySpawn, Writer());
	REQUIRE(t::pump_until({&host.s, &a.s, &b.s}, 5000, [&] { return a.disconnected; }));
	CHECK(at_host.empty());
	CHECK(kicked(a, "unexpected EntitySpawn"));

	host.s.send(2, Lane::Reliable, Msg::DialogLock, Writer()); // only clients ask for a talk lock
	host.s.send(2, Lane::Reliable, Msg::EntitySpawn, Writer()); // the right way, after it (reliable lane: in order)
	b.s.send(kHostPeer, Lane::Reliable, Msg::DialogLock, Writer());
	REQUIRE(t::pump_until({&host.s, &b.s}, 3000, [&] { return at_b.size() == 1 && at_host.size() == 1; }));
	t::pump_for({&host.s, &b.s}, 100);
	CHECK(at_b == std::vector<uint16_t>{uint16_t(Msg::EntitySpawn)});
	CHECK(at_host == std::vector<uint16_t>{uint16_t(Msg::DialogLock)});
	CHECK(b.logged("unexpected DialogLock"));
	CHECK(b.s.is_active() && !b.disconnected);
}
