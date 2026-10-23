// Anomaly Coop unit tests: the internal channel of the host's process (xrCoop/coop_local_link.h, F3a T4;
// docs/plans/2026-10-24-f3a-split-levels.md §1.2). The host player is a client of his own world server: the server's
// Session sees him as peer 0 flagged local, his messages run the server's handlers with from = 0, the server's messages
// run his client-side handlers, at the next pump (never inside a send) and in order per lane; players() lists him,
// peers() does not.
#include "test_util.h"
#include "coop_local_link.h"
#include "coop_protocol.h"
#include "coop_session.h"
#include "coop_world_gate.h"

#include <cstdint>
#include <string>
#include <vector>

using namespace coop;
using t::Node;

namespace
{
Writer seq_payload(uint32_t seq)
{
	Writer w;
	w.u32(seq);
	return w;
}

uint32_t read_seq(Reader& r)
{
	const uint32_t seq = r.u32();
	CHECK(r.ok());
	return seq;
}

const PeerInfo* find_peer(const std::vector<PeerInfo>& list, PeerId id)
{
	for (const PeerInfo& p : list)
		if (p.id == id)
			return &p;
	return nullptr;
}
} // namespace

// ============================================================================ order

TEST(link_order_per_lane)
{
	// The link alone: one queue per direction, the order of the pushes is kept in every lane (and across the lanes).
	LocalLink link;
	const Lane lanes[] = {Lane::Reliable, Lane::Unreliable, Lane::Reliable, Lane::Bulk, Lane::Unreliable, Lane::Reliable};
	for (uint32_t i = 0; i < 6; ++i)
		REQUIRE(link.push_to_server(Msg::ReqSpawn, lanes[i], seq_payload(i)));
	CHECK_EQ(link.queued_to_server(), size_t(6));
	CHECK_EQ(link.queued_to_client(), size_t(0));
	std::vector<uint32_t> per_lane[size_t(Lane::Count)];
	std::vector<uint32_t> all;
	const size_t drained = link.drain_server(link.epoch(), [&](LocalLink::Packet& p) {
		CHECK(p.type == Msg::ReqSpawn);
		Reader r(p.payload.data(), p.payload.size());
		const uint32_t seq = read_seq(r);
		per_lane[size_t(p.lane)].push_back(seq);
		all.push_back(seq);
	});
	CHECK_EQ(drained, size_t(6));
	CHECK(per_lane[size_t(Lane::Reliable)] == (std::vector<uint32_t>{0, 2, 5}));
	CHECK(per_lane[size_t(Lane::Unreliable)] == (std::vector<uint32_t>{1, 4}));
	CHECK(per_lane[size_t(Lane::Bulk)] == (std::vector<uint32_t>{3}));
	CHECK(all == (std::vector<uint32_t>{0, 1, 2, 3, 4, 5}));
	CHECK_EQ(link.queued_to_server(), size_t(0));

	// Through a hosting session, both ways, two lanes interleaved: the host player's messages reach the server's handlers
	// and the server's reach his, each lane in the order it was sent.
	Node host("Boss", 37501);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	std::vector<uint32_t> server_reliable, server_unreliable, player_reliable, player_unreliable;
	host.s.on(Msg::ReqSpawn, [&](PeerId, Reader& r) { server_reliable.push_back(read_seq(r)); });
	host.s.on(Msg::PlayerState, [&](PeerId, Reader& r) { server_unreliable.push_back(read_seq(r)); });
	link.on(Msg::ReqResult, [&](PeerId, Reader& r) { player_reliable.push_back(read_seq(r)); });
	link.on(Msg::TimeSync, [&](PeerId, Reader& r) { player_unreliable.push_back(read_seq(r)); });
	constexpr uint32_t kCount = 200;
	std::vector<uint32_t> want;
	for (uint32_t i = 0; i < kCount; ++i)
	{
		want.push_back(i);
		REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(i)));
		REQUIRE(link.push_to_server(Msg::PlayerState, Lane::Unreliable, seq_payload(i)));
		host.s.send(kHostPeer, Lane::Unreliable, Msg::TimeSync, seq_payload(i));
		host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(i));
	}
	host.s.update(t::now_ms());
	CHECK(server_reliable == want);
	CHECK(server_unreliable == want);
	CHECK(player_reliable == want);
	CHECK(player_unreliable == want);
	CHECK_EQ(link.queued_to_server(), size_t(0));
	CHECK_EQ(link.queued_to_client(), size_t(0));
	CHECK_EQ(link.stats().to_server, uint64_t(6 + 2 * kCount));
	CHECK_EQ(link.stats().to_client, uint64_t(2 * kCount));
	host.s.attach_local(nullptr);
}

// ============================================================================ from

TEST(link_from_is_host_player)
{
	LocalLink link; // outlives the session it is attached to
	Node host("Boss", 37502);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	CHECK(host.s.local() == &link);

	std::vector<PeerId> server_from, player_from;
	host.s.on(Msg::ReqSpawn, [&](PeerId from, Reader&) { server_from.push_back(from); });
	host.s.on(Msg::PlayerState, [&](PeerId from, Reader&) { server_from.push_back(from); });
	link.on(Msg::TimeSync, [&](PeerId from, Reader&) { player_from.push_back(from); });

	// the host player's messages run the server's handlers with from = 0, the server's run his with from = 0 (the host)
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(1)));
	REQUIRE(link.push_to_server(Msg::PlayerState, Lane::Unreliable, seq_payload(2)));
	host.s.send(kHostPeer, Lane::Reliable, Msg::TimeSync, seq_payload(3));
	CHECK(server_from.empty()); // not inside a push or a send
	CHECK(player_from.empty());
	host.s.update(t::now_ms());
	CHECK(server_from == (std::vector<PeerId>{kHostPeer, kHostPeer}));
	CHECK(player_from == (std::vector<PeerId>{kHostPeer}));

	// The host player is a client: a message only the host may send does not run the server's handler, one only a
	// client may send does not run his.
	int host_only_ran = 0, client_only_ran = 0;
	host.s.on(Msg::WorldBlob, [&](PeerId, Reader&) { ++host_only_ran; });
	link.on(Msg::JoinRequest, [&](PeerId, Reader&) { ++client_only_ran; });
	link.push_to_server(Msg::WorldBlob, Lane::Reliable, seq_payload(4));
	host.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, seq_payload(5));
	host.s.update(t::now_ms());
	CHECK_EQ(host_only_ran, 0);
	CHECK_EQ(client_only_ran, 0);
	CHECK(host.logged("WorldBlob from the host player"));
	CHECK(host.logged("JoinRequest to the host player"));

	// The same world gate as a remote client's: a request of his that needs the world waits through a hole and runs when
	// the world is back, still from 0.
	wgate::World world = wgate::World::Hole;
	host.s.set_world_gate([&] { return world; });
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(6)));
	host.s.update(t::now_ms());
	CHECK_EQ(server_from.size(), size_t(2));
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(1));
	world = wgate::World::Up;
	host.s.update(t::now_ms());
	CHECK(server_from == (std::vector<PeerId>{kHostPeer, kHostPeer, kHostPeer}));
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));

	// The link's gate (the game: link_enabled) takes only what was moved onto it; the rest never reaches either side.
	link.set_gate([](Msg type) { return type == Msg::ReqSpawn; });
	CHECK(!link.push_to_server(Msg::PlayerState, Lane::Unreliable, seq_payload(7)));
	host.s.send(kHostPeer, Lane::Reliable, Msg::TimeSync, seq_payload(8));
	CHECK(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(9)));
	host.s.update(t::now_ms());
	CHECK_EQ(server_from.size(), size_t(4));
	CHECK_EQ(player_from.size(), size_t(1));
	CHECK_EQ(link.stats().refused, uint64_t(2));

	// Detached: the host has no player of its own any more, send(0) is ignored as it always was.
	link.set_gate(nullptr);
	host.s.attach_local(nullptr);
	CHECK(host.s.local() == nullptr);
	host.s.send(kHostPeer, Lane::Reliable, Msg::TimeSync, seq_payload(10));
	host.s.update(t::now_ms());
	CHECK_EQ(player_from.size(), size_t(1));
	CHECK_EQ(link.queued_to_client(), size_t(0));
	CHECK(host.logged("send(TimeSync): peer 0 is not joined, ignored"));
}

// ============================================================================ no reentrancy

TEST(link_no_reentrancy)
{
	// The link alone: a drain delivers what was queued before it began; what its callback pushes waits for the next one.
	{
		LocalLink link;
		REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(0)));
		size_t calls = 0;
		const size_t drained = link.drain_server(link.epoch(), [&](LocalLink::Packet&) {
			++calls;
			link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(1));
		});
		CHECK_EQ(drained, size_t(1));
		CHECK_EQ(calls, size_t(1));
		CHECK_EQ(link.queued_to_server(), size_t(1));
	}

	// A ping-pong through a hosting session: the server answers every request of the host player, he asks again at every
	// answer. A send from inside a handler is never delivered inside it, and the game moves by one hop per update.
	LocalLink link;
	Node host("Boss", 37503);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	int at_server = 0, at_player = 0;
	bool reentered = false;
	host.s.on(Msg::ReqSpawn, [&](PeerId from, Reader&) {
		CHECK_EQ(from, kHostPeer);
		++at_server;
		const int before = at_player;
		host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(uint32_t(at_server)));
		host.s.broadcast(Lane::Reliable, Msg::ReqResult, seq_payload(uint32_t(at_server)));
		reentered = reentered || at_player != before;
	});
	link.on(Msg::ReqResult, [&](PeerId from, Reader&) {
		CHECK_EQ(from, kHostPeer);
		++at_player;
		const int before = at_server;
		link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(uint32_t(at_player)));
		reentered = reentered || at_server != before;
	});
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(0)));
	host.s.update(t::now_ms()); // the request
	CHECK_EQ(at_server, 1);
	CHECK_EQ(at_player, 0);
	host.s.update(t::now_ms()); // the two answers (send and broadcast)
	CHECK_EQ(at_server, 1);
	CHECK_EQ(at_player, 2);
	host.s.update(t::now_ms()); // the two requests again
	CHECK_EQ(at_server, 3);
	CHECK_EQ(at_player, 2);
	CHECK(!reentered);
	CHECK_EQ(link.queued_to_client(), size_t(4));
	CHECK_EQ(link.queued_to_server(), size_t(0));

	// A session that ends takes what is in flight with it.
	host.s.shutdown("test over");
	CHECK_EQ(link.queued_to_client(), size_t(0));
	CHECK_EQ(link.queued_to_server(), size_t(0));
	host.s.attach_local(nullptr);
}

// ============================================================================ players and peers

TEST(players_includes_local_peers_not)
{
	LocalLink link;
	Node host("Boss", 37504), cl("Alice", 37504);
	REQUIRE(host.host());

	// no link: the host has no player of its own in the session, players() is peers()
	CHECK(host.s.players().empty());

	host.s.attach_local(&link);
	REQUIRE(cl.connect(37504));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));

	// players(): the host player (peer 0, local) and the client
	const std::vector<PeerInfo> players = host.s.players();
	CHECK_EQ(players.size(), size_t(2));
	const PeerInfo* me = find_peer(players, kHostPeer);
	REQUIRE(me != nullptr);
	CHECK(me->local);
	CHECK(me->state == PeerState::Joined);
	CHECK_EQ(me->nick, std::string("Boss"));
	const PeerInfo* alice = find_peer(players, PeerId(1));
	REQUIRE(alice != nullptr);
	CHECK(!alice->local);
	CHECK_EQ(alice->nick, std::string("Alice"));

	// peers(): the remote ones only, as before, so that old code does not count the host twice; peer(0) the same
	const std::vector<PeerInfo> peers = host.s.peers();
	CHECK_EQ(peers.size(), size_t(1));
	CHECK(find_peer(peers, kHostPeer) == nullptr);
	CHECK(host.s.peer(kHostPeer) == nullptr);

	// a client: its players() are its peers() (the host, who is a player, and the others); nobody is local there
	const std::vector<PeerInfo> seen_by_client = cl.s.players();
	CHECK_EQ(seen_by_client.size(), cl.s.peers().size());
	for (const PeerInfo& p : seen_by_client)
		CHECK(!p.local);

	// detached: the host player is gone from players()
	host.s.attach_local(nullptr);
	CHECK_EQ(host.s.players().size(), size_t(1));
	CHECK(find_peer(host.s.players(), kHostPeer) == nullptr);
}

// ============================================================================ fix round 1

// R1 1: a link packet belongs to the world it was made in. One pushed before the world epoch moves on is not delivered
// after it, either way (as a remote client's game message of another epoch is dropped at receipt, game_message); one
// pushed after it is.
TEST(link_world_epoch_old_packets_dropped)
{
	LocalLink link;
	Node host("Boss", 37505);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	std::vector<uint32_t> at_server, at_player;
	host.s.on(Msg::ReqSpawn, [&](PeerId, Reader& r) { at_server.push_back(read_seq(r)); });
	link.on(Msg::ReqResult, [&](PeerId, Reader& r) { at_player.push_back(read_seq(r)); });

	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(1))); // made in world epoch 0
	host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(1));
	host.s.set_world_epoch(1); // a load: the old world is gone
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(2))); // made in world epoch 1
	host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(2));
	host.s.update(t::now_ms());
	CHECK(at_server == (std::vector<uint32_t>{2}));
	CHECK(at_player == (std::vector<uint32_t>{2}));
	CHECK_EQ(link.queued_to_server(), size_t(0));
	CHECK_EQ(link.queued_to_client(), size_t(0));
	CHECK(host.logged("made in world epoch 0"));

	// the same when the epoch moves on between two pumps, packets already queued
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, seq_payload(3)));
	host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(3));
	host.s.set_world_epoch(2);
	host.s.update(t::now_ms());
	CHECK(at_server == (std::vector<uint32_t>{2}));
	CHECK(at_player == (std::vector<uint32_t>{2}));
	host.s.attach_local(nullptr);
}

// R1 3: what only the bridge of a map server sends never passes the link, either way.
TEST(link_trunk_only_refused)
{
	LocalLink link;
	Node host("Boss", 37506);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	int at_server = 0, at_player = 0;
	host.s.on(Msg::LevelSnapshot, [&](PeerId, Reader&) { ++at_server; });
	link.on(Msg::LevelSnapshot, [&](PeerId, Reader&) { ++at_player; });
	link.push_to_server(Msg::LevelSnapshot, Lane::Reliable, seq_payload(1));
	host.s.send(kHostPeer, Lane::Reliable, Msg::LevelSnapshot, seq_payload(2));
	host.s.update(t::now_ms());
	CHECK_EQ(at_server, 0);
	CHECK_EQ(at_player, 0);
	CHECK(host.logged("LevelSnapshot from the host player"));
	CHECK(host.logged("LevelSnapshot to the host player"));
	host.s.attach_local(nullptr);
}

// R1 3: toward the host player the world gate decides as for the server's own handlers: in a hole a Hold message waits
// and runs his handler when the world is back (from 0), a Drop message is dropped; a held one whose link is gone by then
// counts as a player who left.
TEST(link_world_gate_toward_player)
{
	LocalLink link;
	Node host("Boss", 37507);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	wgate::World world = wgate::World::Hole;
	host.s.set_world_gate([&] { return world; });
	std::vector<PeerId> results;
	int hits = 0;
	link.on(Msg::ReqResult, [&](PeerId from, Reader&) { results.push_back(from); }); // Hold
	link.on(Msg::PlayerHit, [&](PeerId, Reader&) { ++hits; }); // Drop
	host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(1));
	host.s.send(kHostPeer, Lane::Reliable, Msg::PlayerHit, seq_payload(2));
	host.s.update(t::now_ms());
	CHECK(results.empty());
	CHECK_EQ(hits, 0);
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(1));
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerHit)).world_dropped, uint64_t(1));
	world = wgate::World::Up;
	host.s.update(t::now_ms()); // replay_held runs the host player's handler (kToLocalPlayer)
	CHECK(results == (std::vector<PeerId>{kHostPeer}));
	CHECK_EQ(hits, 0);
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));

	// held, then the link goes: the message is of a player who left
	world = wgate::World::Hole;
	host.s.send(kHostPeer, Lane::Reliable, Msg::ReqResult, seq_payload(3));
	host.s.update(t::now_ms());
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(1));
	const uint64_t gone = host.s.world_gate_stats().hold.gone;
	host.s.attach_local(nullptr);
	world = wgate::World::Up;
	host.s.update(t::now_ms());
	CHECK_EQ(results.size(), size_t(1));
	CHECK_EQ(host.s.world_gate_stats().hold.gone, gone + 1);
}

// R1 4: the link takes game messages only, within the session's packet size, and a handler only for a game message.
TEST(link_limits)
{
	LocalLink link;
	// a core message has no handler on the link, as on a Session
	link.on(Msg::Hello, [](PeerId, Reader&) {});
	CHECK(!link.handler(Msg::Hello));
	link.on(Msg::ReqResult, [](PeerId, Reader&) {});
	CHECK(bool(link.handler(Msg::ReqResult)));

	// a payload over the session's limit is not taken, either way; one at the limit is
	std::vector<uint8_t> big(16 * 1024 * 1024 + 1, 0x5A);
	CHECK(!link.push_to_server(Msg::ReqSpawn, Lane::Reliable, big.data(), big.size()));
	CHECK(!link.push_to_client(Msg::ReqResult, Lane::Reliable, big.data(), big.size()));
	CHECK(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, big.data(), big.size() - 1));
	CHECK_EQ(link.queued_to_server(), size_t(1));
	CHECK_EQ(link.queued_to_client(), size_t(0));
	CHECK_EQ(link.stats().oversize, uint64_t(2));
	link.clear_queues();

	// a direction holds at most kMaxQueued waiting messages (nobody pumps); the next push is refused and counted, the
	// other direction is not affected
	const uint8_t one = 1;
	for (size_t i = 0; i < LocalLink::kMaxQueued; ++i)
		REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, &one, 1));
	CHECK(!link.push_to_server(Msg::ReqSpawn, Lane::Reliable, &one, 1));
	CHECK_EQ(link.stats().overflow, uint64_t(1));
	CHECK_EQ(link.queued_to_server(), LocalLink::kMaxQueued);
	CHECK(link.push_to_client(Msg::ReqResult, Lane::Reliable, &one, 1));
	// a pump makes room again
	const size_t pumped = link.drain_server(link.epoch(), [](LocalLink::Packet&) {});
	CHECK_EQ(pumped, LocalLink::kMaxQueued);
	CHECK(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, &one, 1));

	// the drain takes only what was made in the epoch it is given (the session's); the rest is counted stale
	link.clear_queues();
	link.set_epoch(4);
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, &one, 1));
	link.set_epoch(5);
	REQUIRE(link.push_to_server(Msg::ReqSpawn, Lane::Reliable, &one, 1));
	std::vector<uint32_t> fresh;
	const size_t taken = link.drain_server(5, [&](LocalLink::Packet& p) { fresh.push_back(p.epoch); });
	CHECK_EQ(taken, size_t(2));
	CHECK(fresh == (std::vector<uint32_t>{5}));
	CHECK_EQ(link.stats().stale, uint64_t(1));
	CHECK_EQ(link.stats().stale_epoch, uint32_t(4));
}
