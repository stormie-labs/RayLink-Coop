// Anomaly Coop unit tests: who may hold a player slot (player key, reconnect) and what the host keeps of a key.
// Real Sessions over 127.0.0.1 in one process. Ports 37100+n (test_net.cpp uses 37000+n).
#include "test_util.h"

#include <cstring>

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
