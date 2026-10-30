// Anomaly Coop unit tests: game messages for a world that is not there (xrCoop/coop_world_gate.h + Session::set_world_gate).
// Live crash 2026-10-23 20:00 (build 9, GAMMA): while the host built the new level a client's PlayerVitals reached
// store_vitals and ai().alife() had no simulator. The session decides, for every game message, whether its handler may run
// now (the table need_of), waits on the host (Hole) or drops on a client (Absent) what needs a world that is not there.
#include "test_util.h"

#include "coop_world_gate.h"

#include <algorithm>
#include <cstring>
#include <memory>
#include <vector>

using namespace coop;
using namespace coop::wgate;

namespace
{
using t::Node;

void join_one(Node& host, Node& cl, uint16_t port)
{
	std::string err;
	REQUIRE(host.host(&err));
	REQUIRE(cl.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.peers().size() == 1; }));
}

Held held(uint16_t type, uint32_t epoch, uint64_t at_ms, size_t size = 8, uint64_t conn = 1)
{
	Held h;
	h.conn = conn;
	h.type = type;
	h.epoch = epoch;
	h.at_ms = at_ms;
	h.bytes = std::make_shared<std::vector<uint8_t>>(size, uint8_t(0));
	return h;
}

std::vector<uint16_t> drain_all(HoldQueue& q, uint32_t epoch, uint64_t now)
{
	std::vector<uint16_t> ran;
	q.drain(epoch, now, [] { return true; }, [&](Held& h) {
		ran.push_back(h.type);
		return true;
	});
	return ran;
}

Writer one_u16(uint16_t v)
{
	Writer w;
	w.u16(v);
	return w;
}
} // namespace

// ---------------------------------------------------------------------------------------------- the table

TEST(world_gate_every_named_game_message_is_classified)
{
	// A new message (coop_protocol.h) needs its row in need_of: Unclassified is treated as Hold, which is safe but waits
	// for a world even for a message that must run without one (a join step).
	for (uint32_t v = uint32_t(Msg::GameBase); v <= 0xFFFFu; ++v)
	{
		const Msg m = static_cast<Msg>(v);
		if (std::strncmp(msg_name(m), "Msg_0x", 6) == 0)
			continue; // not a message of the protocol
		CHECK_EQ(std::string(msg_name(m)) + (need_of(m) == Need::Unclassified ? " has no row in need_of" : " is classified"),
		    std::string(msg_name(m)) + " is classified");
	}
	// Core messages (below GameBase) are the session's own and never gated.
	CHECK(need_of(Msg::Hello) == Need::Unclassified);
}

TEST(world_gate_the_join_lifecycle_and_world_free_handlers_run_without_a_world)
{
	for (Msg m : {Msg::JoinRequest, Msg::WorldBlob, Msg::JoinComplete, Msg::SessionReset, Msg::LevelChange, Msg::AvatarList,
	         Msg::CharOffer, Msg::CharChoice, Msg::TransitionState})
	{
		CHECK(need_of(m) == Need::Free);
		CHECK(decide(need_of(m), World::Hole) == Act::Run);
		CHECK(decide(need_of(m), World::Absent) == Act::Run);
	}
	// kept by their own modules: the newest value, a deferred queue, a Lua queue for a frame that checks the world
	for (Msg m : {Msg::TimeSync, Msg::WeatherSync, Msg::InfoPortion, Msg::TaskList, Msg::MapSpot, Msg::Relation,
	         Msg::StoryHash, Msg::SyncFull, Msg::SyncSet, Msg::ScriptEvent, Msg::CheckpointState, Msg::RestState,
	         Msg::PlayerRules})
		CHECK(decide(need_of(m), World::Absent) == Act::Run);
}

TEST(world_gate_snapshots_and_stale_news_are_dropped_not_kept)
{
	// What the sender repeats, or what is stale when the world is back, is never kept: the live crash was one of these.
	for (Msg m : {Msg::PlayerState, Msg::PlayerVitals, Msg::PlayerEquip, Msg::PlayerShot, Msg::PlayerHit,
	         Msg::EntitySnapshot, Msg::EntitySound, Msg::EntityState, Msg::ZoneState, Msg::MoneyBalance,
	         Msg::DeathMarker, Msg::WorldLoaded, Msg::TransitionVote})
	{
		CHECK(need_of(m) == Need::Drop);
		CHECK(decide(need_of(m), World::Hole) == Act::Drop);
		CHECK(decide(need_of(m), World::Absent) == Act::Drop);
		CHECK(decide(need_of(m), World::Up) == Act::Run);
	}
}

TEST(world_gate_requests_wait_on_the_host_and_are_dropped_on_a_client)
{
	for (Msg m : {Msg::ReqSpawn, Msg::ReqDestroy, Msg::ReqTake, Msg::ReqDrop, Msg::ReqTransfer, Msg::ReqUse, Msg::ReqHit,
	         Msg::ReqMoney, Msg::ReqContainer, Msg::ReqItemEvent, Msg::ReqLaunch, Msg::TradeOp, Msg::DialogLock,
	         Msg::ItemState, Msg::EntityEvent, Msg::PlayerWounded, Msg::PlayerRevive, Msg::NewCharacter,
	         Msg::CheckpointClaim, Msg::RestRequest, Msg::StateDumpRequest, Msg::IdLease, Msg::IdLeaseAck,
	         Msg::EntitySpawn, Msg::EntityDestroy, Msg::EntitySwitch, Msg::EntityParent, Msg::EntityDied,
	         Msg::EntityLocal, Msg::EntityVisual})
	{
		CHECK(need_of(m) == Need::Hold);
		CHECK(decide(need_of(m), World::Hole) == Act::Hold);
		CHECK(decide(need_of(m), World::Absent) == Act::Drop); // a client's mirror is rebuilt from the host's save
		CHECK(decide(need_of(m), World::Up) == Act::Run);
	}
}

TEST(world_gate_an_unclassified_message_is_never_run_without_a_world)
{
	const Msg unknown = static_cast<Msg>(0x01FE);
	CHECK(need_of(unknown) == Need::Unclassified);
	CHECK(decide(Need::Unclassified, World::Up) == Act::Run);
	CHECK(decide(Need::Unclassified, World::Hole) == Act::Hold);
	CHECK(decide(Need::Unclassified, World::Absent) == Act::Drop);
}

// ---------------------------------------------------------------------------------------------- the queue

TEST(hold_queue_runs_what_waited_in_arrival_order)
{
	HoldQueue q;
	for (uint16_t i = 1; i <= 5; ++i)
		q.push(held(i, 3, 1000 + i));
	CHECK_EQ(q.size(), size_t(5));
	CHECK_EQ(q.bytes(), size_t(40));
	const std::vector<uint16_t> ran = drain_all(q, 3, 1100);
	CHECK(ran == std::vector<uint16_t>({1, 2, 3, 4, 5}));
	CHECK(q.empty());
	CHECK_EQ(q.bytes(), size_t(0));
	CHECK_EQ(q.stats().held, uint64_t(5));
	CHECK_EQ(q.stats().replayed, uint64_t(5));
}

TEST(hold_queue_voids_what_was_made_in_an_older_world)
{
	HoldQueue q;
	q.push(held(1, 3, 1000));
	q.push(held(2, 4, 1000)); // made after the epoch moved (cannot happen today, but never run it against another one)
	q.push(held(3, 3, 1000));
	const std::vector<uint16_t> ran = drain_all(q, 4, 1100);
	CHECK(ran == std::vector<uint16_t>({2}));
	CHECK_EQ(q.stats().void_epoch, uint64_t(2));
}

TEST(hold_queue_purge_voids_other_epochs_at_once)
{
	HoldQueue q;
	q.push(held(1, 3, 1000, 10));
	q.push(held(2, 4, 1000, 10));
	q.push(held(3, 3, 1000, 10));
	CHECK_EQ(q.purge(4), size_t(2));
	CHECK_EQ(q.size(), size_t(1));
	CHECK_EQ(q.bytes(), size_t(10));
	CHECK_EQ(q.stats().void_epoch, uint64_t(2));
	CHECK_EQ(q.purge(4), size_t(0));
}

TEST(hold_queue_lets_an_old_entry_expire)
{
	Limits lim;
	lim.max_age_ms = 5000;
	HoldQueue q(lim);
	q.push(held(1, 0, 1000));
	q.push(held(2, 0, 4000));
	const std::vector<uint16_t> ran = drain_all(q, 0, 7000); // the first waited 6 s, the second 3 s
	CHECK(ran == std::vector<uint16_t>({2}));
	CHECK_EQ(q.stats().expired, uint64_t(1));
}

TEST(hold_queue_over_its_limits_loses_the_oldest_first)
{
	Limits lim;
	lim.max_entries = 3;
	lim.max_bytes = 1000;
	HoldQueue q(lim);
	CHECK_EQ(q.push(held(1, 0, 0)), size_t(0));
	q.push(held(2, 0, 0));
	q.push(held(3, 0, 0));
	CHECK_EQ(q.push(held(4, 0, 0)), size_t(1)); // the entry limit: 1 goes
	CHECK(drain_all(q, 0, 0) == std::vector<uint16_t>({2, 3, 4}));

	Limits bytes;
	bytes.max_entries = 100;
	bytes.max_bytes = 100;
	HoldQueue b(bytes);
	b.push(held(1, 0, 0, 60));
	b.push(held(2, 0, 0, 30));
	CHECK_EQ(b.push(held(3, 0, 0, 40)), size_t(1)); // 130 B > 100 B: the oldest (60 B) goes, 70 B stay
	CHECK_EQ(b.bytes(), size_t(70));
	CHECK(drain_all(b, 0, 0) == std::vector<uint16_t>({2, 3}));
	// one packet over the byte limit alone is not kept at all
	CHECK_EQ(b.push(held(9, 0, 0, 500)), size_t(1));
	CHECK(b.empty());
	CHECK_EQ(b.stats().evicted, uint64_t(2));
}

TEST(hold_queue_stops_when_the_world_goes_away_again)
{
	HoldQueue q;
	for (uint16_t i = 1; i <= 4; ++i)
		q.push(held(i, 0, 0));
	std::vector<uint16_t> ran;
	bool up = true;
	q.drain(0, 0, [&] { return up; }, [&](Held& h) {
		ran.push_back(h.type);
		up = h.type < 2; // the handler of 2 starts a level change
		return true;
	});
	CHECK(ran == std::vector<uint16_t>({1, 2}));
	CHECK_EQ(q.size(), size_t(2)); // 3 and 4 wait for the next return
	up = true;
	CHECK(drain_all(q, 0, 0) == std::vector<uint16_t>({3, 4}));
}

TEST(hold_queue_skips_a_sender_who_left)
{
	HoldQueue q;
	q.push(held(1, 0, 0, 8, /*conn*/ 7));
	q.push(held(2, 0, 0, 8, /*conn*/ 8));
	std::vector<uint16_t> ran;
	q.drain(0, 0, [] { return true; }, [&](Held& h) {
		if (h.conn == 7)
			return false; // gone
		ran.push_back(h.type);
		return true;
	});
	CHECK(ran == std::vector<uint16_t>({2}));
	CHECK_EQ(q.stats().gone, uint64_t(1));
	CHECK_EQ(q.stats().replayed, uint64_t(1));
}

// ---------------------------------------------------------------------------------------------- the session

TEST(world_gate_host_holds_a_request_until_the_world_is_back)
{
	Node host("Boss", 37400), cl("Alice", 37400);
	join_one(host, cl, 37400);
	World world = World::Hole;
	host.s.set_world_gate([&] { return world; });
	std::vector<uint16_t> got;
	host.s.on(Msg::ReqSpawn, [&](PeerId, Reader& r) { got.push_back(r.u16()); });
	host.s.on(Msg::ReqTake, [&](PeerId, Reader& r) { got.push_back(r.u16()); });

	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqSpawn, one_u16(1));
	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqTake, one_u16(2));
	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqSpawn, one_u16(3));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.world_gate_stats().queued == 3; }));
	t::pump_for({&host.s, &cl.s}, 200);
	CHECK(got.empty()); // no handler touched the world that is not there
	CHECK_EQ(host.s.stats(uint16_t(Msg::ReqSpawn)).world_held, uint64_t(2));
	CHECK_EQ(host.s.stats(uint16_t(Msg::ReqTake)).world_held, uint64_t(1));
	CHECK_EQ(host.s.world_gate_stats().gaps, uint64_t(1));
	CHECK(host.logged("no world here right now"));

	world = World::Up;
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() == 3; }));
	CHECK(got == std::vector<uint16_t>({1, 2, 3})); // in arrival order, across message types
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));
	CHECK_EQ(host.s.world_gate_stats().hold.replayed, uint64_t(3));
	CHECK(host.logged("world is up again: 3 waiting message(s) ran"));

	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqSpawn, one_u16(4)); // a message in an up world runs at once
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() == 4; }));
	CHECK_EQ(got.back(), uint16_t(4));
	CHECK_EQ(host.s.world_gate_stats().gaps, uint64_t(1));
}

TEST(world_gate_host_drops_a_snapshot_in_a_hole_and_never_replays_it)
{
	Node host("Boss", 37401), cl("Alice", 37401);
	join_one(host, cl, 37401);
	World world = World::Hole;
	host.s.set_world_gate([&] { return world; });
	std::vector<uint16_t> got;
	host.s.on(Msg::PlayerVitals, [&](PeerId, Reader& r) { got.push_back(r.u16()); }); // the handler of the live crash

	cl.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, one_u16(1));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.stats(uint16_t(Msg::PlayerVitals)).recv_count == 1; }));
	t::pump_for({&host.s, &cl.s}, 100);
	CHECK(got.empty());
	CHECK_EQ(host.s.stats(uint16_t(Msg::PlayerVitals)).world_dropped, uint64_t(1));
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0)); // nothing kept

	world = World::Up;
	t::pump_for({&host.s, &cl.s}, 200);
	CHECK(got.empty()); // and nothing replayed
	cl.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, one_u16(2));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() == 1; }));
	CHECK_EQ(got[0], uint16_t(2));
}

TEST(world_gate_a_replaced_world_voids_what_waited_for_the_old_one)
{
	// The level change of the live crash: requests of the old level arrive while the new one is built; the host's world
	// epoch moves on when the new world exists (join::on_world_created) and they must never touch it.
	Node host("Boss", 37402), cl("Alice", 37402);
	join_one(host, cl, 37402);
	World world = World::Hole;
	host.s.set_world_gate([&] { return world; });
	int ran = 0;
	host.s.on(Msg::ReqTake, [&](PeerId, Reader&) { ++ran; });

	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqTake, one_u16(5));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.world_gate_stats().queued == 1; }));
	host.s.set_world_epoch(1); // the new world exists
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));
	CHECK_EQ(host.s.world_gate_stats().hold.void_epoch, uint64_t(1));
	CHECK(host.logged("1 waiting game message(s) made in world epoch 0 are void"));
	world = World::Up;
	t::pump_for({&host.s, &cl.s}, 300);
	CHECK_EQ(ran, 0);
	CHECK(host.logged("world is up again: 0 waiting message(s) ran, 1 void"));
}

TEST(world_gate_a_join_step_runs_in_a_hole)
{
	// The join lifecycle answers a missing world itself (host_can_start kicks with a reason): the session must not hide it.
	Node host("Boss", 37403), cl("Alice", 37403);
	join_one(host, cl, 37403);
	host.s.set_world_gate([] { return World::Hole; });
	int ran = 0;
	host.s.on(Msg::JoinRequest, [&](PeerId, Reader&) { ++ran; });
	cl.s.send(kHostPeer, Lane::Reliable, Msg::JoinRequest, Writer());
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return ran == 1; }));
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));
	CHECK_EQ(host.s.world_gate_stats().gaps, uint64_t(0));
}

TEST(world_gate_a_sender_who_left_takes_his_waiting_requests_with_him)
{
	Node host("Boss", 37404), cl("Alice", 37404);
	join_one(host, cl, 37404);
	World world = World::Hole;
	host.s.set_world_gate([&] { return world; });
	int ran = 0;
	host.s.on(Msg::ReqTake, [&](PeerId, Reader&) { ++ran; });
	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqTake, one_u16(5));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.world_gate_stats().queued == 1; }));
	cl.s.shutdown("leaving");
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.peers().empty(); }));
	world = World::Up;
	t::pump_for({&host.s}, 200);
	CHECK_EQ(ran, 0);
	CHECK_EQ(host.s.world_gate_stats().hold.gone, uint64_t(1));
}

TEST(world_gate_a_client_without_a_world_drops_what_needs_one_and_keeps_the_join)
{
	Node host("Boss", 37405), cl("Alice", 37405);
	join_one(host, cl, 37405);
	World world = World::Absent; // in the main menu, choosing a character, loading
	cl.s.set_world_gate([&] { return world; });
	std::vector<std::string> got;
	cl.s.on(Msg::EntitySpawn, [&](PeerId, Reader&) { got.push_back("spawn"); });
	cl.s.on(Msg::EntitySnapshot, [&](PeerId, Reader&) { got.push_back("snapshot"); });
	cl.s.on(Msg::CharOffer, [&](PeerId, Reader&) { got.push_back("offer"); });
	cl.s.on(Msg::SyncFull, [&](PeerId, Reader&) { got.push_back("syncfull"); });

	const PeerId me = cl.s.self();
	host.s.send(me, Lane::Reliable, Msg::EntitySpawn, one_u16(1));
	host.s.send(me, Lane::Reliable, Msg::EntitySnapshot, one_u16(1));
	host.s.send(me, Lane::Reliable, Msg::CharOffer, Writer());
	host.s.send(me, Lane::Reliable, Msg::SyncFull, Writer());
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() >= 2; }));
	t::pump_for({&host.s, &cl.s}, 100);
	CHECK(got == std::vector<std::string>({"offer", "syncfull"})); // the join steps ran, the world's deltas did not
	CHECK_EQ(cl.s.stats(uint16_t(Msg::EntitySpawn)).world_dropped, uint64_t(1));
	CHECK_EQ(cl.s.stats(uint16_t(Msg::EntitySnapshot)).world_dropped, uint64_t(1));
	CHECK_EQ(cl.s.world_gate_stats().queued, size_t(0)); // a client never keeps them: the host's save carries the state
	CHECK(cl.logged("this machine is not in the host's world"));

	world = World::Up; // live
	host.s.send(me, Lane::Reliable, Msg::EntitySpawn, one_u16(2));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return got.size() == 3; }));
	CHECK_EQ(got.back(), std::string("spawn"));
	CHECK(cl.logged("world is up again: 0 waiting message(s) ran, 0 void"));
}

TEST(world_gate_without_a_gate_every_message_runs)
{
	Node host("Boss", 37406), cl("Alice", 37406);
	join_one(host, cl, 37406);
	int ran = 0;
	host.s.on(Msg::ReqSpawn, [&](PeerId, Reader&) { ++ran; });
	host.s.on(Msg::PlayerVitals, [&](PeerId, Reader&) { ++ran; });
	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqSpawn, one_u16(1));
	cl.s.send(kHostPeer, Lane::Reliable, Msg::PlayerVitals, one_u16(1));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return ran == 2; }));
	CHECK_EQ(host.s.world_gate_stats().gaps, uint64_t(0));
}

TEST(world_gate_the_queue_is_dropped_with_the_session)
{
	Node host("Boss", 37407), cl("Alice", 37407);
	join_one(host, cl, 37407);
	host.s.set_world_gate([] { return World::Hole; });
	host.s.on(Msg::ReqTake, [](PeerId, Reader&) {});
	cl.s.send(kHostPeer, Lane::Reliable, Msg::ReqTake, one_u16(5));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.world_gate_stats().queued == 1; }));
	host.s.shutdown("host stops");
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(0));
	CHECK_EQ(host.s.world_gate_stats().queued_bytes, size_t(0));
}
