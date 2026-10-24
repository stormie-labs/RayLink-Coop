// Anomaly Coop unit tests: the ownership transfer core of split levels (xrCoop/coop_xfer.h, coop_level_hash.h; plan
// 2026-10-24-f3a §1.7, §4.1 requirements 1-4, 6). The world server's Ledger and a map server's Holder talk through
// Packets; these tests hand the packets over one by one (or through a loss-free Wire) and check who owns what at every
// moment: two-phase take and release, idempotent keys (id, gen), abort, spawn and destroy, the journal in the save and
// its resolution after a load or a lost map server, the auditor and its healing, the level hash.
#include "test_util.h"

#include "coop_xfer.h"

#include <algorithm>
#include <cstdint>
#include <deque>
#include <string>
#include <utility>
#include <vector>

using namespace coop::xfer;

namespace
{
using Bytes = std::vector<uint8_t>;
constexpr Peer kM1 = 1;
constexpr Peer kM2 = 2;

size_t count_op(const std::vector<Packet>& ps, Op op, Peer to)
{
	size_t n = 0;
	for (const Packet& p : ps)
		if (p.op == op && p.to == to)
			++n;
	return n;
}

size_t count_events(const std::vector<Holder::Event>& ev, Holder::Event::Kind kind, uint16_t id)
{
	size_t n = 0;
	for (const Holder::Event& e : ev)
		if (e.kind == kind && e.id == id)
			++n;
	return n;
}

// The only packet of `ps` (the test stops when there is not exactly one).
const Packet& one(const std::vector<Packet>& ps)
{
	REQUIRE(ps.size() == 1);
	return ps[0];
}

bool confirmed_is(const Ledger& w, uint16_t id, const Bytes& state)
{
	const Bytes* s = w.last_confirmed(id);
	return s && *s == state;
}

bool holds_state(const Holder& h, uint16_t id, const Bytes& state)
{
	const Bytes* s = h.state(id);
	return s && *s == state;
}

// A loss-free, in-order network between one ledger and its map servers.
struct Wire
{
	Ledger& world;
	std::vector<Holder*> maps;
	std::deque<Packet> q;
	uint64_t now = 10000;

	Wire(Ledger& w, std::initializer_list<Holder*> m) : world(w), maps(m) {}

	void send(std::vector<Packet> ps)
	{
		for (Packet& p : ps)
			q.push_back(std::move(p));
	}

	Holder* map(Peer peer)
	{
		for (Holder* h : maps)
			if (h->self() == peer)
				return h;
		return nullptr;
	}

	// Delivers what is queued, and every answer, until nothing is left.
	void pump()
	{
		for (size_t guard = 0; !q.empty() && guard < 100000; ++guard)
		{
			Packet p = std::move(q.front());
			q.pop_front();
			if (p.to == kWorld)
				send(world.on_packet(p, now));
			else if (Holder* h = map(p.to))
				send(h->on_packet(p, now));
		}
	}

	// Ticks every side each 100 ms for `ms`, delivering everything.
	void run(uint64_t ms)
	{
		for (uint64_t t = 0; t < ms; t += 100)
		{
			now += 100;
			send(world.tick(now));
			for (Holder* h : maps)
				send(h->tick(now));
			pump();
		}
	}

	void take(Holder& h, uint16_t id)
	{
		send(h.want_online(id, now));
		pump();
		h.take_events();
	}
};
} // namespace

// Requirement 1, take (world -> map server): TakeReq, Grant {id, gen+1, state}, TakeCommit, Done. Until TakeCommit the
// world owns it, frozen; after it the map server.
TEST(xfer_take_happy)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1, 2, 3});
	CHECK(w.registered(10));
	CHECK_EQ(w.owner(10), kWorld);
	CHECK_EQ(w.owner_count(10), uint16_t(1));
	CHECK(w.world_authors(10));
	const uint32_t g0 = w.gen(10);

	std::vector<Packet> req = m1.want_online(10, 1000);
	REQUIRE(req.size() == 1);
	CHECK(req[0].op == Op::TakeReq);
	CHECK_EQ(req[0].key.id, uint16_t(10));
	CHECK_EQ(req[0].from, kM1);
	CHECK_EQ(req[0].to, kWorld);
	CHECK(!m1.authors(10)); // asked, not granted
	CHECK(m1.busy(10));

	std::vector<Packet> grant = w.on_packet(one(req), 1000);
	REQUIRE(grant.size() == 1);
	CHECK(grant[0].op == Op::Grant);
	CHECK_EQ(grant[0].to, kM1);
	CHECK(grant[0].payload == Bytes({1, 2, 3}));
	const uint32_t g = grant[0].key.gen;
	CHECK(g > g0);
	CHECK_EQ(w.gen(10), g);
	CHECK_EQ(w.owner(10), kWorld); // until TakeCommit: the world's, frozen
	CHECK(w.frozen(10));
	CHECK(!w.world_authors(10));
	CHECK(w.phase(10) == Phase::Granting);
	CHECK_EQ(w.peer(10), kM1);
	CHECK_EQ(w.journal_size(), size_t(1));
	CHECK(!w.world_update(10, {4})); // frozen: the world's simulation leaves it alone
	CHECK(confirmed_is(w, 10, {1, 2, 3}));

	std::vector<Packet> commit = m1.on_packet(grant[0], 1010);
	REQUIRE(commit.size() == 1);
	CHECK(commit[0].op == Op::TakeCommit);
	CHECK_EQ(commit[0].key.gen, g);
	CHECK(m1.authors(10));
	CHECK(holds_state(m1, 10, {1, 2, 3}));
	CHECK_EQ(m1.gen(10), g);
	const std::vector<Holder::Event> ev = m1.take_events();
	REQUIRE(ev.size() == 1);
	CHECK(ev[0].kind == Holder::Event::Kind::Create);
	CHECK_EQ(ev[0].id, uint16_t(10));
	CHECK(ev[0].state == Bytes({1, 2, 3}));

	std::vector<Packet> done = w.on_packet(commit[0], 1020);
	REQUIRE(done.size() == 1);
	CHECK(done[0].op == Op::Done);
	CHECK_EQ(done[0].key.gen, g);
	CHECK_EQ(w.owner(10), kM1);
	CHECK_EQ(w.owner_count(10), uint16_t(1));
	CHECK(w.phase(10) == Phase::Stable);
	CHECK_EQ(w.journal_size(), size_t(0));
	CHECK(!w.world_authors(10));

	CHECK(m1.on_packet(done[0], 1030).empty());
	CHECK(m1.idle());
	CHECK(m1.tick(100000).empty()); // nothing left to repeat
	CHECK(w.tick(100000).empty());
}

// Requirement 1, release (map server -> world): the map server freezes it and sends ReleasePrepare; until the world's
// Ack it stays the map server's; the world keeps the state in the journal and applies it only at ReleaseCommit.
TEST(xfer_release_happy)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	REQUIRE(w.owner(10) == kM1);
	const uint32_t g = w.gen(10);

	std::vector<Packet> prep = m1.want_offline(10, {7, 7}, net.now);
	REQUIRE(prep.size() == 1);
	CHECK(prep[0].op == Op::ReleasePrepare);
	CHECK_EQ(prep[0].key.gen, g);
	CHECK(prep[0].payload == Bytes({7, 7}));
	CHECK(m1.frozen(10));
	CHECK(m1.authors(10)); // until the world's Ack the map server owns it

	std::vector<Packet> ack = w.on_packet(one(prep), net.now);
	REQUIRE(ack.size() == 1);
	CHECK(ack[0].op == Op::Ack);
	const uint32_t g2 = ack[0].key.gen;
	CHECK(g2 > g);
	CHECK_EQ(w.owner(10), kM1);
	CHECK(w.phase(10) == Phase::Releasing);
	CHECK(confirmed_is(w, 10, {1})); // kept in the journal, not applied
	CHECK_EQ(w.journal_size(), size_t(1));

	std::vector<Packet> rc = m1.on_packet(ack[0], net.now);
	REQUIRE(rc.size() == 1);
	CHECK(rc[0].op == Op::ReleaseCommit);
	CHECK_EQ(rc[0].key.gen, g2);
	CHECK(!m1.authors(10));
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Remove, 10), size_t(1));

	std::vector<Packet> done = w.on_packet(rc[0], net.now);
	REQUIRE(done.size() == 1);
	CHECK(done[0].op == Op::Done);
	CHECK_EQ(done[0].key.gen, g2);
	CHECK_EQ(w.owner(10), kWorld);
	CHECK(w.world_authors(10));
	CHECK(confirmed_is(w, 10, {7, 7}));
	CHECK_EQ(w.journal_size(), size_t(0));
	CHECK(w.phase(10) == Phase::Stable);

	CHECK(m1.on_packet(done[0], net.now).empty());
	CHECK(m1.idle());
	CHECK(!m1.busy(10));
}

// Requirement 1: repeats on both sides until the answer; every answer is idempotent - one grant gen, one object, one
// commit.
TEST(xfer_take_retry_idempotent)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1});
	const uint64_t t0 = 1000;

	std::vector<Packet> req = m1.want_online(10, t0);
	REQUIRE(req.size() == 1);
	CHECK(m1.tick(t0 + 10).empty()); // not yet
	std::vector<Packet> again = m1.tick(t0 + kRetryFirstMs);
	REQUIRE(again.size() == 1);
	CHECK(again[0].op == Op::TakeReq);

	// Two copies of the request: one grant, the second copy repeats it with the same gen.
	std::vector<Packet> g1 = w.on_packet(one(req), t0);
	std::vector<Packet> g2 = w.on_packet(again[0], t0 + 1);
	REQUIRE(g1.size() == 1);
	REQUIRE(g2.size() == 1);
	CHECK(g2[0].op == Op::Grant);
	CHECK_EQ(g1[0].key.gen, g2[0].key.gen);
	CHECK_EQ(w.journal_size(), size_t(1));

	// The world repeats the grant by itself until TakeCommit.
	std::vector<Packet> g3 = w.tick(t0 + 10 * kRetryFirstMs);
	REQUIRE(g3.size() == 1);
	CHECK(g3[0].op == Op::Grant);
	CHECK_EQ(g3[0].key.gen, g1[0].key.gen);
	CHECK_EQ(w.counters().retries, uint64_t(1));

	// The map server creates the object once; a repeated grant only repeats TakeCommit.
	std::vector<Packet> c1 = m1.on_packet(g1[0], t0 + 2);
	std::vector<Packet> c2 = m1.on_packet(g3[0], t0 + 3);
	REQUIRE(c1.size() == 1);
	REQUIRE(c2.size() == 1);
	CHECK(c2[0].op == Op::TakeCommit);
	CHECK_EQ(c1[0].key.gen, c2[0].key.gen);
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Create, 10), size_t(1));
	// TakeCommit repeats until Done.
	std::vector<Packet> c3 = m1.tick(t0 + 10 * kRetryFirstMs);
	REQUIRE(c3.size() == 1);
	CHECK(c3[0].op == Op::TakeCommit);

	// The world commits once and answers every copy.
	std::vector<Packet> d1 = w.on_packet(c1[0], t0 + 4);
	const uint32_t gen = w.gen(10);
	std::vector<Packet> d2 = w.on_packet(c2[0], t0 + 5);
	REQUIRE(d1.size() == 1);
	REQUIRE(d2.size() == 1);
	CHECK(d2[0].op == Op::Done);
	CHECK_EQ(d1[0].key.gen, d2[0].key.gen);
	CHECK_EQ(w.owner(10), kM1);
	CHECK_EQ(w.gen(10), gen);
	CHECK_EQ(w.owner_count(10), uint16_t(1));
	// A stale request after the commit gets nothing.
	CHECK(w.on_packet(one(req), t0 + 6).empty());
	CHECK_EQ(w.owner(10), kM1);

	CHECK(m1.on_packet(d1[0], t0 + 7).empty());
	CHECK(m1.on_packet(d2[0], t0 + 8).empty());
	CHECK(m1.tick(t0 + 100000).empty());
	CHECK(m1.idle());
	CHECK(m1.authors(10));
}

// Requirement 1: Release only after the world's Ack; before it the object is the map server's (frozen), and nothing the
// world receives out of order moves it.
TEST(xfer_release_before_ack_still_owner)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);

	// The prepare is lost: the map server still owns the object, frozen, and repeats.
	std::vector<Packet> prep = m1.want_offline(10, {5}, net.now);
	REQUIRE(prep.size() == 1);
	CHECK(m1.authors(10));
	CHECK(m1.frozen(10));
	CHECK_EQ(w.owner(10), kM1);
	CHECK(w.phase(10) == Phase::Stable);
	std::vector<Packet> again = m1.tick(net.now + 10 * kRetryFirstMs);
	REQUIRE(again.size() == 1);
	CHECK(again[0].op == Op::ReleasePrepare);
	CHECK_EQ(again[0].key.gen, g);
	CHECK(again[0].payload == Bytes({5}));

	// The world's Ack is lost: still the map server's, the state waits in the journal.
	std::vector<Packet> ack1 = w.on_packet(again[0], net.now);
	REQUIRE(ack1.size() == 1);
	CHECK(ack1[0].op == Op::Ack);
	CHECK_EQ(w.owner(10), kM1);
	CHECK(confirmed_is(w, 10, {1}));
	CHECK_EQ(w.journal_size(), size_t(1));
	// The prepare repeated: the same Ack, nothing else changes.
	std::vector<Packet> ack2 = w.on_packet(one(prep), net.now);
	REQUIRE(ack2.size() == 1);
	CHECK_EQ(ack2[0].key.gen, ack1[0].key.gen);
	CHECK_EQ(w.journal_size(), size_t(1));
	// A commit that does not match the Ack's gen, or from another map server, is ignored.
	CHECK(w.on_packet(Packet{Op::ReleaseCommit, {10, g}, kM1, kWorld, {}}, net.now).empty());
	CHECK(w.on_packet(Packet{Op::ReleaseCommit, {10, ack1[0].key.gen}, kM2, kWorld, {}}, net.now).empty());
	CHECK_EQ(w.owner(10), kM1);
	CHECK(w.phase(10) == Phase::Releasing);
	// Nobody else takes it meanwhile.
	CHECK(w.on_packet(Packet{Op::TakeReq, {10, 0}, kM2, kWorld, {}}, net.now).empty());
	CHECK(m1.authors(10)); // no Ack reached it yet

	// Only now the Ack reaches the map server: it deletes the object and commits.
	net.send(m1.on_packet(ack2[0], net.now));
	CHECK(!m1.authors(10));
	net.pump();
	CHECK_EQ(w.owner(10), kWorld);
	CHECK(confirmed_is(w, 10, {5}));
	CHECK(m1.idle());
}

// Duplicated and late messages of a finished transfer change nothing on either side.
TEST(xfer_duplicate_prepare)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	std::vector<Packet> req = m1.want_online(10, net.now);
	std::vector<Packet> grant = w.on_packet(one(req), net.now);
	REQUIRE(grant.size() == 1);
	net.send(m1.on_packet(grant[0], net.now));
	net.pump();
	REQUIRE(w.owner(10) == kM1);

	std::vector<Packet> prep = m1.want_offline(10, {5}, net.now);
	std::vector<Packet> ack = w.on_packet(one(prep), net.now);
	REQUIRE(ack.size() == 1);
	std::vector<Packet> rc = m1.on_packet(ack[0], net.now);
	REQUIRE(rc.size() == 1);
	std::vector<Packet> done = w.on_packet(rc[0], net.now);
	REQUIRE(done.size() == 1);
	CHECK(m1.on_packet(done[0], net.now).empty());
	CHECK(confirmed_is(w, 10, {5}));
	CHECK(w.world_update(10, {6})); // the world's own simulation changes it after the release
	const uint32_t gen_after = w.gen(10);

	// Late copies at the world: the prepare is not the map server's any more, the commit is answered but not applied
	// again.
	CHECK(w.on_packet(one(prep), net.now).empty());
	std::vector<Packet> d2 = w.on_packet(rc[0], net.now);
	REQUIRE(d2.size() == 1);
	CHECK(d2[0].op == Op::Done);
	CHECK(confirmed_is(w, 10, {6}));
	CHECK_EQ(w.owner(10), kWorld);
	CHECK_EQ(w.gen(10), gen_after);
	CHECK_EQ(w.journal_size(), size_t(0));

	// Late copies at the map server: no object comes back.
	m1.take_events();
	CHECK(m1.on_packet(ack[0], net.now).empty());
	CHECK_EQ(count_op(m1.on_packet(grant[0], net.now), Op::TakeCommit, kWorld), size_t(0)); // at most a refusal
	CHECK(m1.on_packet(done[0], net.now).empty());
	CHECK(!m1.authors(10));
	CHECK(m1.take_events().empty());
	CHECK(m1.idle());

	// A duplicated SpawnPrepare: registered once and answered again; once the object moved, a late copy takes nothing
	// back.
	std::vector<Packet> sp = m1.spawned(20, {9}, net.now);
	REQUIRE(sp.size() == 1);
	std::vector<Packet> a1 = w.on_packet(one(sp), net.now);
	std::vector<Packet> a2 = w.on_packet(one(sp), net.now);
	REQUIRE(a1.size() == 1);
	REQUIRE(a2.size() == 1);
	CHECK(a2[0].op == Op::Ack);
	CHECK_EQ(a1[0].key.gen, a2[0].key.gen);
	net.send(m1.on_packet(a1[0], net.now));
	net.send(m1.want_offline(20, {8}, net.now));
	net.pump();
	CHECK_EQ(w.owner(20), kWorld);
	CHECK(w.on_packet(one(sp), net.now).empty());
	CHECK_EQ(w.owner(20), kWorld);
	CHECK(confirmed_is(w, 20, {8}));
	CHECK(!m1.authors(20));
}

// Abort is two-phase too: the world stays frozen until AbortAck; a late TakeCommit does not beat it. A grant nobody
// answers is aborted after kGrantTimeoutMs; a map server that no longer wants a grant declines it (AbortAck) and never
// creates it.
TEST(xfer_abort_two_phase)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1});
	const uint64_t now = 1000;
	std::vector<Packet> req = m1.want_online(10, now);
	std::vector<Packet> grant = w.on_packet(one(req), now);
	REQUIRE(grant.size() == 1);
	const uint32_t g = grant[0].key.gen;
	std::vector<Packet> commit = m1.on_packet(grant[0], now); // made on the map server; the commit will be late
	REQUIRE(commit.size() == 1);
	CHECK(m1.authors(10));
	m1.take_events();

	std::vector<Packet> ab = w.abort(10, now);
	REQUIRE(ab.size() == 1);
	CHECK(ab[0].op == Op::Abort);
	CHECK_EQ(ab[0].key.gen, g);
	CHECK_EQ(ab[0].to, kM1);
	CHECK(w.frozen(10));
	CHECK(w.phase(10) == Phase::Aborting);
	CHECK(!w.world_authors(10));
	// The late commit does not win over the abort.
	CHECK(w.on_packet(commit[0], now).empty());
	CHECK_EQ(w.owner(10), kWorld);
	CHECK(w.frozen(10));
	// The abort repeats until AbortAck.
	std::vector<Packet> ab2 = w.tick(now + 10 * kRetryFirstMs);
	REQUIRE(ab2.size() == 1);
	CHECK(ab2[0].op == Op::Abort);

	// The map server deletes its copy and confirms; only then is the world's object live again.
	std::vector<Packet> aa = m1.on_packet(ab[0], now);
	REQUIRE(aa.size() == 1);
	CHECK(aa[0].op == Op::AbortAck);
	CHECK_EQ(aa[0].key.gen, g);
	CHECK(!m1.authors(10));
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Remove, 10), size_t(1));
	CHECK(w.on_packet(aa[0], now).empty());
	CHECK(!w.frozen(10));
	CHECK(w.world_authors(10));
	CHECK_EQ(w.owner(10), kWorld);
	CHECK_EQ(w.journal_size(), size_t(0));
	// Stale copies: the grant does not make it again, the abort is confirmed again.
	std::vector<Packet> stale = m1.on_packet(grant[0], now);
	CHECK(count_op(stale, Op::TakeCommit, kWorld) == 0);
	CHECK(!m1.authors(10));
	std::vector<Packet> aa2 = m1.on_packet(ab2[0], now);
	REQUIRE(aa2.size() == 1);
	CHECK(aa2[0].op == Op::AbortAck);
	CHECK(w.on_packet(aa2[0], now).empty());
	CHECK(w.world_authors(10));
	CHECK(m1.idle());

	// No answer for kGrantTimeoutMs: the world aborts by itself (the grant was lost on the way).
	Holder m2(kM2);
	std::vector<Packet> req2 = m2.want_online(10, now);
	REQUIRE(w.on_packet(one(req2), now).size() == 1);
	std::vector<Packet> t = w.tick(now + kGrantTimeoutMs + 1);
	CHECK(count_op(t, Op::Abort, kM2) == 1);
	CHECK(w.phase(10) == Phase::Aborting);
	// The map server had only asked: the abort ends its request (Refused) and is confirmed.
	std::vector<Packet> aa3 = m2.on_packet(one(t), now + kGrantTimeoutMs + 2);
	REQUIRE(aa3.size() == 1);
	CHECK(aa3[0].op == Op::AbortAck);
	CHECK_EQ(count_events(m2.take_events(), Holder::Event::Kind::Refused, 10), size_t(1));
	CHECK(!m2.busy(10));
	CHECK(w.on_packet(aa3[0], now + kGrantTimeoutMs + 3).empty());
	CHECK(w.world_authors(10));

	// Declining: asked, then not wanted before the grant came (the player left).
	std::vector<Packet> req3 = m2.want_online(10, now + 20000);
	CHECK(m2.want_offline(10, {}, now + 20000).empty());
	CHECK(!m2.busy(10));
	CHECK(m2.tick(now + 40000).empty()); // the request is not repeated any more
	std::vector<Packet> grant3 = w.on_packet(one(req3), now + 20001);
	REQUIRE(grant3.size() == 1);
	std::vector<Packet> decline = m2.on_packet(grant3[0], now + 20002);
	REQUIRE(decline.size() == 1);
	CHECK(decline[0].op == Op::AbortAck);
	CHECK_EQ(decline[0].key.gen, grant3[0].key.gen);
	CHECK(!m2.authors(10));
	CHECK(m2.take_events().empty());
	CHECK(w.on_packet(decline[0], now + 20003).empty());
	CHECK(w.world_authors(10));
	CHECK_EQ(w.journal_size(), size_t(0));
}

// R2: a map server never declines a grant while it writes the object. A newer grant while it holds an older incarnation
// replaces it (the world holds that the older one is not there) and is committed; while it spawns or releases, a grant
// gets no answer (the world's abort will come) - an AbortAck there would let the world write it too.
TEST(xfer_grant_while_holding)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);

	CHECK(m1.on_packet(Packet{Op::Grant, {10, g - 1}, kWorld, kM1, {9}}, net.now).empty()); // older: stale
	CHECK(holds_state(m1, 10, {1}));
	std::vector<Packet> c = m1.on_packet(Packet{Op::Grant, {10, g + 5}, kWorld, kM1, {2}}, net.now);
	REQUIRE(c.size() == 1);
	CHECK(c[0].op == Op::TakeCommit);
	CHECK_EQ(c[0].key.gen, g + 5);
	CHECK(m1.authors(10));
	CHECK(holds_state(m1, 10, {2}));
	CHECK_EQ(m1.gen(10), g + 5);
	const std::vector<Holder::Event> ev = m1.take_events();
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Remove, 10), size_t(1));
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Create, 10), size_t(1));

	m1.want_offline(10, {3}, net.now);
	CHECK(m1.on_packet(Packet{Op::Grant, {10, g + 9}, kWorld, kM1, {4}}, net.now).empty());
	CHECK(m1.authors(10));
	CHECK(holds_state(m1, 10, {3}));
	m1.spawned(20, {5}, net.now);
	CHECK(m1.on_packet(Packet{Op::Grant, {20, g + 9}, kWorld, kM1, {6}}, net.now).empty());
	CHECK(holds_state(m1, 20, {5}));
}

// A map server spawns under a leased id: SpawnPrepare -> the world registers it (owner = that map server) -> Ack.
TEST(xfer_spawn_registers)
{
	Ledger w;
	Holder m1(kM1);
	const uint64_t now = 1000;
	std::vector<Packet> sp = m1.spawned(500, {7}, now);
	REQUIRE(sp.size() == 1);
	CHECK(sp[0].op == Op::SpawnPrepare);
	CHECK_EQ(sp[0].from, kM1);
	CHECK(sp[0].payload == Bytes({7}));
	CHECK(m1.authors(500)); // the map server made it
	CHECK(!w.registered(500));
	std::vector<Packet> rep = m1.tick(now + 10 * kRetryFirstMs); // repeated until Ack
	REQUIRE(rep.size() == 1);
	CHECK(rep[0].op == Op::SpawnPrepare);

	std::vector<Packet> ack = w.on_packet(one(sp), now);
	REQUIRE(ack.size() == 1);
	CHECK(ack[0].op == Op::Ack);
	const uint32_t gs = ack[0].key.gen;
	CHECK(gs != 0);
	CHECK(w.registered(500));
	CHECK_EQ(w.owner(500), kM1);
	CHECK_EQ(w.owner_count(500), uint16_t(1));
	CHECK(confirmed_is(w, 500, {7}));
	CHECK_EQ(w.gen(500), gs);
	CHECK_EQ(w.journal_size(), size_t(0)); // registration is atomic: the record itself goes into the save
	std::vector<Packet> ack2 = w.on_packet(rep[0], now);
	REQUIRE(ack2.size() == 1);
	CHECK_EQ(ack2[0].key.gen, gs);
	CHECK(m1.on_packet(ack[0], now).empty());
	CHECK_EQ(m1.gen(500), gs);
	CHECK(m1.idle());
	CHECK(m1.authors(500));

	// A spawn under an id the world already has (a lease fault): refused with Drop, the map server lets go of it.
	w.add_world_object(600, {1});
	std::vector<Packet> bad = m1.spawned(600, {2}, now);
	REQUIRE(bad.size() == 1);
	std::vector<Packet> drop = w.on_packet(one(bad), now);
	REQUIRE(drop.size() == 1);
	CHECK(drop[0].op == Op::Drop);
	CHECK_EQ(drop[0].to, kM1);
	CHECK_EQ(w.owner(600), kWorld);
	CHECK(confirmed_is(w, 600, {1}));
	CHECK_EQ(w.counters().violations, uint64_t(1));
	CHECK(m1.on_packet(drop[0], now).empty());
	CHECK(!m1.authors(600));
	CHECK(m1.idle());
}

// Destroy -> Done, repeated until Done, answered again for a copy; a destroyed id stays dead (late spawn, take, grant).
TEST(xfer_destroy_idempotent)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);

	std::vector<Packet> d = m1.destroyed(10, net.now);
	REQUIRE(d.size() == 1);
	CHECK(d[0].op == Op::Destroy);
	CHECK_EQ(d[0].key.gen, g);
	CHECK(!m1.authors(10));
	CHECK(m1.busy(10));
	CHECK(m1.tick(net.now + 10 * kRetryFirstMs).size() == 1);
	std::vector<Packet> done = w.on_packet(d[0], net.now);
	REQUIRE(done.size() == 1);
	CHECK(done[0].op == Op::Done);
	CHECK(done[0].key.gen > g);
	CHECK(!w.registered(10));
	CHECK_EQ(w.owner_count(10), uint16_t(0));
	std::vector<Packet> done2 = w.on_packet(d[0], net.now);
	REQUIRE(done2.size() == 1);
	CHECK_EQ(done2[0].key.gen, done[0].key.gen);
	CHECK(m1.on_packet(done[0], net.now).empty());
	CHECK(m1.idle());

	// Nothing brings it back: a take request is refused, a late SpawnPrepare is ignored.
	m1.take_events();
	std::vector<Packet> req = m1.want_online(10, net.now);
	REQUIRE(req.size() == 1);
	std::vector<Packet> refuse = w.on_packet(one(req), net.now);
	REQUIRE(refuse.size() == 1);
	CHECK(refuse[0].op == Op::Abort);
	net.send(m1.on_packet(refuse[0], net.now));
	net.pump();
	CHECK(!m1.busy(10));
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Refused, 10), size_t(1));
	CHECK(w.on_packet(Packet{Op::SpawnPrepare, {10, 0}, kM1, kWorld, {1}}, net.now).empty());
	CHECK(!w.registered(10));

	// The world destroys its own objects too; never one that is frozen or at a map server.
	w.add_world_object(11, {1});
	CHECK(w.world_destroy(11, net.now));
	CHECK(!w.registered(11));
	CHECK(!w.world_destroy(11, net.now));
	w.add_world_object(13, {1});
	net.take(m1, 13);
	CHECK(!w.world_destroy(13, net.now));
	CHECK_EQ(w.owner(13), kM1);

	// Destroyed before the spawn was answered: the world tombstones the id, the late SpawnPrepare registers nothing.
	std::vector<Packet> sp = m1.spawned(12, {3}, net.now);
	std::vector<Packet> d12 = m1.destroyed(12, net.now);
	REQUIRE(d12.size() == 1);
	CHECK(d12[0].op == Op::Destroy);
	CHECK(!m1.authors(12));
	std::vector<Packet> dd = w.on_packet(one(d12), net.now);
	REQUIRE(dd.size() == 1);
	CHECK(dd[0].op == Op::Done);
	CHECK(w.on_packet(one(sp), net.now).empty());
	CHECK(!w.registered(12));
	CHECK(m1.on_packet(dd[0], net.now).empty());
	CHECK(m1.idle());

	// After kTombstoneMs the id may be used again (the id generator gave it out anew).
	w.tick(net.now + kTombstoneMs + 1);
	Holder m2(kM2);
	std::vector<Packet> s2 = m2.spawned(12, {4}, net.now + kTombstoneMs + 2);
	std::vector<Packet> a2 = w.on_packet(one(s2), net.now + kTombstoneMs + 2);
	REQUIRE(a2.size() == 1);
	CHECK(a2[0].op == Op::Ack);
	CHECK_EQ(w.owner(12), kM2);
}

// The stream of changes within ownership (Snapshot, numbered): the world keeps the newest and never goes back; repeated
// until acknowledged; nobody but the owner writes it; a frozen object does not change.
TEST(xfer_snapshot_stream)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);

	std::vector<Packet> s1 = m1.changed(10, {2}, net.now);
	std::vector<Packet> s2 = m1.changed(10, {3}, net.now);
	REQUIRE(s1.size() == 1);
	REQUIRE(s2.size() == 1);
	CHECK(s2[0].op == Op::Snapshot);
	CHECK_EQ(s2[0].key.gen, g);
	uint32_t seq = 0;
	Bytes st;
	REQUIRE(read_snapshot(s2[0].payload, seq, st));
	CHECK_EQ(seq, uint32_t(2));
	CHECK(st == Bytes({3}));
	CHECK(holds_state(m1, 10, {3}));

	// The newer one first, the older one late: the world keeps the newer.
	std::vector<Packet> a2 = w.on_packet(one(s2), net.now);
	std::vector<Packet> a1 = w.on_packet(s1[0], net.now);
	CHECK(confirmed_is(w, 10, {3}));
	REQUIRE(a2.size() == 1);
	CHECK(a2[0].op == Op::Snapshot);
	CHECK_EQ(a2[0].to, kM1);

	// An ack of the older one alone does not stop the repeats; the newest does.
	CHECK(m1.on_packet(Packet{Op::Snapshot, {10, g}, kWorld, kM1, snapshot_payload(1, {})}, net.now).empty());
	std::vector<Packet> rep = m1.tick(net.now + 10 * kRetryFirstMs);
	REQUIRE(rep.size() == 1);
	CHECK(rep[0].op == Op::Snapshot);
	CHECK(m1.on_packet(a2[0], net.now).empty());
	CHECK(m1.tick(net.now + 100 * kRetryFirstMs).empty());
	CHECK(m1.idle());

	// Not the owner, or another gen: ignored.
	CHECK(w.on_packet(Packet{Op::Snapshot, {10, g}, kM2, kWorld, snapshot_payload(9, {9})}, net.now).empty());
	CHECK(w.on_packet(Packet{Op::Snapshot, {10, g + 1}, kM1, kWorld, snapshot_payload(9, {9})}, net.now).empty());
	CHECK(confirmed_is(w, 10, {3}));

	// Frozen for the release: no more changes.
	m1.want_offline(10, {4}, net.now);
	CHECK(m1.changed(10, {5}, net.now).empty());
	CHECK(holds_state(m1, 10, {4}));
}

// Requirement 2: the journal in the save - every in-flight transfer, the payload in base64, at most kJournalMaxEntries
// and kJournalMaxBytes; a broken text is refused whole.
TEST(xfer_journal_roundtrip)
{
	Ledger w;
	Holder m1(kM1), m2(kM2);
	Wire net(w, {&m1, &m2});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	w.add_world_object(13, {4});
	net.take(m1, 10);
	Bytes all(256);
	for (size_t i = 0; i < all.size(); ++i)
		all[i] = uint8_t(i);
	std::vector<Packet> prep = m1.want_offline(10, all, net.now);
	REQUIRE(w.on_packet(one(prep), net.now).size() == 1); // 10: Releasing, the Ack not delivered
	std::vector<Packet> req = m2.want_online(11, net.now);
	REQUIRE(w.on_packet(one(req), net.now).size() == 1); // 11: Granting
	std::vector<Packet> req13 = m2.want_online(13, net.now);
	REQUIRE(w.on_packet(one(req13), net.now).size() == 1);
	REQUIRE(w.abort(13, net.now).size() == 1); // 13: Aborting
	CHECK_EQ(w.journal_size(), size_t(3));

	const std::string text = w.save_journal();
	CHECK(text.rfind("[coop_xfer]", 0) == 0);
	CHECK(text.size() <= kJournalMaxBytes);
	Ledger fresh;
	REQUIRE(fresh.load_journal(text));
	CHECK_EQ(fresh.save_journal(), text);

	// Broken input: refused, nothing taken.
	Ledger bad;
	const std::string empty_text = Ledger().save_journal();
	CHECK(!bad.load_journal("garbage"));
	CHECK(!bad.load_journal(text.substr(0, text.size() / 2)));
	std::string corrupt = text;
	const size_t at = corrupt.find("AAEC"); // base64 of bytes 0, 1, 2
	REQUIRE(at != std::string::npos);
	corrupt[at] = '!';
	CHECK(!bad.load_journal(corrupt));
	CHECK_EQ(bad.save_journal(), empty_text);
	CHECK(Ledger().load_journal(empty_text)); // an empty journal round-trips too
}

// Requirement 2: the journal never grows past its limits - a transfer that does not fit waits (the map server repeats)
// and goes through when the journal empties.
TEST(xfer_journal_limits)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	for (uint16_t id = 100; id < 170; ++id)
	{
		w.add_world_object(id, {1});
		net.take(m1, id);
	}
	size_t acked = 0;
	for (uint16_t id = 100; id < 170; ++id)
	{
		std::vector<Packet> prep = m1.want_offline(id, Bytes(1024, uint8_t(id)), net.now);
		REQUIRE(prep.size() == 1);
		acked += w.on_packet(one(prep), net.now).size(); // the Acks are not delivered
	}
	CHECK_EQ(acked, kJournalMaxEntries);
	CHECK_EQ(w.journal_size(), kJournalMaxEntries);
	CHECK(w.save_journal().size() <= kJournalMaxBytes);
	net.run(30000); // the repeats and the commits drain it
	CHECK_EQ(w.journal_size(), size_t(0));
	for (uint16_t id = 100; id < 170; ++id)
		CHECK(w.world_authors(id));
	CHECK(m1.idle());

	// Large states: the byte limit holds first.
	Ledger w2;
	Holder m2(kM2);
	Wire net2(w2, {&m2});
	for (uint16_t id = 200; id < 210; ++id)
	{
		w2.add_world_object(id, {1});
		net2.take(m2, id);
	}
	acked = 0;
	for (uint16_t id = 200; id < 210; ++id)
	{
		std::vector<Packet> prep = m2.want_offline(id, Bytes(60 * 1024, uint8_t(id)), net2.now);
		acked += w2.on_packet(one(prep), net2.now).size();
	}
	CHECK(acked >= 2);
	CHECK(acked < 10);
	CHECK(w2.save_journal().size() <= kJournalMaxBytes);
	net2.run(30000);
	CHECK_EQ(w2.journal_size(), size_t(0));
	for (uint16_t id = 200; id < 210; ++id)
		CHECK(w2.world_authors(id));
}

// Requirement 2, the table of §1.7 after a load: Releasing with a payload - completed; Granting - rolled back to the
// last confirmed; SpawnPrepare - completed (the record is in the world); an object of a gone map server without an
// entry - rolled back to the last confirmed, owned by the world. New gens after the load are of a newer epoch.
TEST(xfer_journal_resolve)
{
	Ledger w;
	Holder m1(kM1), m2(kM2);
	Wire net(w, {&m1, &m2});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	w.add_world_object(12, {3});
	net.take(m1, 10);
	net.take(m1, 12);
	net.send(m1.changed(12, {30}, net.now));
	net.pump(); // 12: confirmed {30}
	m1.changed(12, {31}, net.now); // not delivered: not confirmed
	std::vector<Packet> prep = m1.want_offline(10, {10, 10}, net.now);
	REQUIRE(w.on_packet(one(prep), net.now).size() == 1); // 10: Releasing
	std::vector<Packet> req = m2.want_online(11, net.now);
	std::vector<Packet> gr = w.on_packet(one(req), net.now);
	REQUIRE(gr.size() == 1);
	m2.on_packet(one(gr), net.now); // 11: Granting, m2 made it
	std::vector<Packet> sp = m1.spawned(20, {20}, net.now);
	REQUIRE(w.on_packet(one(sp), net.now).size() == 1); // 20: spawned, registered
	uint32_t max_gen = 0;
	for (uint16_t id : w.ids())
		max_gen = std::max(max_gen, w.gen(id));

	// The save: the world's objects at their last confirmed state, plus the journal.
	std::vector<std::pair<uint16_t, Bytes>> world;
	for (uint16_t id : w.ids())
		world.emplace_back(id, *w.last_confirmed(id));
	const std::string journal = w.save_journal();

	// The load: a fresh ledger; the map servers are gone.
	Ledger l;
	for (const auto& o : world)
		l.add_world_object(o.first, o.second);
	REQUIRE(l.load_journal(journal));
	l.resolve_after_load();
	CHECK_EQ(l.journal_size(), size_t(0));
	CHECK(confirmed_is(l, 10, {10, 10})); // Releasing: completed
	CHECK(confirmed_is(l, 11, {2})); // Granting: rolled back
	CHECK(confirmed_is(l, 12, {30})); // at the gone map server: its last confirmed
	CHECK(confirmed_is(l, 20, {20})); // spawned: kept
	for (uint16_t id : {uint16_t(10), uint16_t(11), uint16_t(12), uint16_t(20)})
	{
		CHECK(l.world_authors(id));
		CHECK_EQ(l.owner_count(id), uint16_t(1));
	}
	CHECK_EQ(l.ids().size(), size_t(4));
	CHECK_EQ(l.counters().completed, uint64_t(1));
	CHECK_EQ(l.counters().rolled_back, uint64_t(1));

	// New transfers: gens of a newer epoch, above everything from before the load.
	Holder m3(kM1);
	Wire net3(l, {&m3});
	net3.take(m3, 10);
	CHECK_EQ(l.owner(10), kM1);
	CHECK(l.gen(10) > max_gen);
	CHECK((l.gen(10) >> kEpochShift) > (max_gen >> kEpochShift));
}

// Requirement 2: a lost map server - its objects go back to the world at their last confirmed state, its prepared
// release is completed, a grant to it is undone at once; the other map servers keep theirs.
TEST(xfer_server_lost)
{
	Ledger w;
	Holder m1(kM1), m2(kM2);
	Wire net(w, {&m1, &m2});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	w.add_world_object(12, {3});
	w.add_world_object(13, {4});
	net.take(m1, 10);
	net.take(m2, 13);
	net.send(m1.changed(10, {11}, net.now));
	net.pump(); // 10: owned, confirmed {11}
	std::vector<Packet> req = m1.want_online(11, net.now);
	std::vector<Packet> gr = w.on_packet(one(req), net.now); // 11: Granting to m1
	REQUIRE(gr.size() == 1);
	net.take(m1, 12);
	std::vector<Packet> prep = m1.want_offline(12, {33}, net.now);
	REQUIRE(w.on_packet(one(prep), net.now).size() == 1); // 12: Releasing
	std::vector<Packet> sp = m1.spawned(20, {20}, net.now);
	REQUIRE(w.on_packet(one(sp), net.now).size() == 1); // 20: spawned by m1
	const Ledger::Counters before = w.counters();

	std::vector<Packet> out = w.server_lost(kM1, net.now);
	CHECK(confirmed_is(w, 10, {11}));
	CHECK(confirmed_is(w, 11, {2}));
	CHECK(confirmed_is(w, 12, {33}));
	CHECK(confirmed_is(w, 20, {20}));
	for (uint16_t id : {uint16_t(10), uint16_t(11), uint16_t(12), uint16_t(20)})
	{
		CHECK(w.world_authors(id));
		CHECK_EQ(w.owner_count(id), uint16_t(1));
	}
	CHECK_EQ(w.owner(13), kM2);
	CHECK_EQ(w.journal_size(), size_t(0));
	CHECK_EQ(w.counters().completed, before.completed + 1);
	CHECK_EQ(w.counters().rolled_back, before.rolled_back + 3);
	CHECK_EQ(count_op(out, Op::Drop, kM1), size_t(4)); // in case it is still there: let go of everything

	// Late messages of the lost map server change nothing; a second report of the loss neither.
	CHECK(w.on_packet(Packet{Op::TakeCommit, {11, gr[0].key.gen}, kM1, kWorld, {}}, net.now).empty());
	CHECK(w.world_authors(11));
	CHECK(w.server_lost(kM1, net.now).empty());
	CHECK_EQ(w.counters().rolled_back, before.rolled_back + 3);
}

// Requirement 3: a map server that writes an object it does not own (fault) - Duplicate, a loud line, Drop at the
// illegal one and a snapshot asked from the legal owner.
TEST(audit_duplicate_heals)
{
	Ledger w;
	Holder m1(kM1), m2(kM2);
	Wire net(w, {&m1, &m2});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);
	// The fault: m2 is made to write 10 too (a forged grant for a request the world never answered).
	m2.want_online(10, net.now);
	m2.on_packet(Packet{Op::Grant, {10, g + 1000}, kWorld, kM2, {9}}, net.now);
	REQUIRE(m2.authors(10));

	CHECK(audit(w, kM1, m1.report()).empty());
	std::vector<Finding> f = audit(w, kM2, m2.report());
	REQUIRE(f.size() == 1);
	CHECK(f[0].kind == Violation::Duplicate);
	CHECK_EQ(f[0].id, uint16_t(10));
	CHECK_EQ(f[0].server, kM2);
	CHECK_EQ(f[0].owner, kM1);
	CHECK(describe(f[0]).rfind("!! [coop] ownership violation", 0) == 0);

	std::vector<Packet> out = heal(w, f);
	CHECK_EQ(count_op(out, Op::Drop, kM2), size_t(1));
	CHECK_EQ(count_op(out, Op::Snapshot, kM1), size_t(1));
	CHECK_EQ(w.counters().violations, uint64_t(1));
	net.send(out);
	net.pump();
	CHECK(!m2.authors(10));
	CHECK(m1.authors(10));
	CHECK_EQ(w.owner(10), kM1);
	CHECK(audit(w, kM2, m2.report()).empty());
	CHECK(audit(w, kM1, m1.report()).empty());
}

// Requirement 3: an object the ledger gives to a map server that does not have it - Lost, back to the world from the
// last confirmed snapshot; only the buckets asked for are judged; transfers in flight are never "lost".
TEST(audit_lost_heals)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	net.take(m1, 10);
	net.take(m1, 11);
	net.send(m1.changed(10, {5}, net.now));
	net.pump();
	const uint32_t g = w.gen(10);

	// The fault: m1's report lacks 10 (its engine lost the object).
	std::vector<Entry> rep;
	for (const Entry& e : m1.report())
		if (e.id != 10)
			rep.push_back(e);
	std::vector<Finding> f = audit(w, kM1, rep);
	REQUIRE(f.size() == 1);
	CHECK(f[0].kind == Violation::Lost);
	CHECK_EQ(f[0].id, uint16_t(10));
	CHECK_EQ(f[0].server, kM1);
	// Only the buckets asked for: an empty report of 11's bucket makes only 11 lost.
	std::vector<Finding> only11 = audit(w, kM1, {}, 1u << bucket_of(11));
	REQUIRE(only11.size() == 1);
	CHECK_EQ(only11[0].id, uint16_t(11));

	// Fix round 1 (review I3): the world takes it back two-phase - Abort, and it writes the object only after AbortAck.
	std::vector<Packet> out = heal(w, f);
	CHECK_EQ(w.owner(10), kWorld);
	CHECK(!w.world_authors(10));
	CHECK(w.phase(10) == Phase::Aborting);
	CHECK(w.gen(10) > g);
	CHECK_EQ(w.counters().violations, uint64_t(1));
	CHECK_EQ(count_op(out, Op::Abort, kM1), size_t(1)); // a copy it may still have goes first
	net.send(out);
	net.pump();
	CHECK(!m1.authors(10));
	CHECK(w.world_authors(10));
	CHECK(confirmed_is(w, 10, {5}));
	CHECK(m1.authors(11));
	CHECK_EQ(w.owner(11), kM1);
	CHECK(audit(w, kM1, m1.report()).empty());

	// In flight: granted to m1, not made there yet - not lost.
	w.add_world_object(12, {3});
	std::vector<Packet> req = m1.want_online(12, net.now);
	REQUIRE(w.on_packet(one(req), net.now).size() == 1);
	CHECK(audit(w, kM1, m1.report()).empty());
}

// Requirement 3: the owner's state drifted from the world's copy (a lost change) - a snapshot of the owner, counted as
// a resync, not a violation.
TEST(audit_drift_resyncs)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	net.take(m1, 10);
	m1.changed(10, {2}, net.now); // the change is lost and not repeated yet
	std::vector<Finding> f = audit(w, kM1, m1.report());
	REQUIRE(f.size() == 1);
	CHECK(f[0].kind == Violation::Drift);
	std::vector<Packet> out = heal(w, f);
	CHECK_EQ(count_op(out, Op::Snapshot, kM1), size_t(1));
	CHECK_EQ(w.counters().resyncs, uint64_t(1));
	CHECK_EQ(w.counters().violations, uint64_t(0));
	net.send(out);
	net.pump();
	CHECK(confirmed_is(w, 10, {2}));
	CHECK(audit(w, kM1, m1.report()).empty());
}

// Requirement 4: the level hash - order-independent, n and the set of ids, 32 buckets over (id, gen, parent, alive,
// digest); a difference shows exactly in its bucket.
TEST(hash_bucket_mismatch)
{
	const std::vector<Entry> a = {{1, 10, kNoParent, true, 0}, {33, 11, 1, true, 0}, {2, 12, kNoParent, false, 0}};
	CHECK_EQ(bucket_of(1), uint32_t(1));
	CHECK_EQ(bucket_of(33), uint32_t(1));
	CHECK_EQ(bucket_of(2), uint32_t(2));
	const LevelHash ha = hash_of(a);
	CHECK_EQ(ha.n, uint32_t(3));
	CHECK(ha.set != 0);
	const LevelHash hb = hash_of({a[2], a[0], a[1]});
	CHECK_EQ(mismatched(ha, hb), uint32_t(0));
	CHECK(ha.set == hb.set);

	std::vector<Entry> c = a;
	c[2].gen = 13;
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 2));
	c = a;
	c[1].parent = 5;
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 1));
	c = a;
	c[0].alive = false;
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 1));
	c = a;
	c[2].digest = 7;
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 2));
	c = a;
	std::swap(c[0].gen, c[1].gen); // two ids of one bucket swap their gens
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 1));
	// A missing id: its bucket, and n and the set differ.
	const LevelHash hm = hash_of({a[0], a[2]});
	CHECK_EQ(mismatched(ha, hm), uint32_t(1u << 1));
	CHECK(hm.n != ha.n);
	CHECK(hm.set != ha.set);
	// An extra id in bucket 0.
	c = a;
	c.push_back({64, 1, kNoParent, true, 0});
	CHECK_EQ(mismatched(ha, hash_of(c)), uint32_t(1u << 0));
	CHECK_EQ(mismatched(hash_of({}), hash_of({})), uint32_t(0));
	CHECK_EQ(hash_of({}).n, uint32_t(0));

	// The world's expectation and the map server's report agree after transfers.
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	for (uint16_t id = 1; id <= 40; ++id)
	{
		w.add_world_object(id, {uint8_t(id)});
		net.take(m1, id);
	}
	net.send(m1.changed(7, {70}, net.now));
	net.pump();
	CHECK_EQ(mismatched(hash_of(m1.report()), hash_of(w.owned_by(kM1))), uint32_t(0));
	m1.changed(39, {90}, net.now); // a lost change: only 39's bucket
	CHECK_EQ(mismatched(hash_of(m1.report()), hash_of(w.owned_by(kM1))), uint32_t(1u << bucket_of(39)));
}

// Requirement 6: in flight and retries.
TEST(counters_in_flight_and_retries)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	const uint64_t now = 1000;
	std::vector<Packet> r10 = m1.want_online(10, now);
	std::vector<Packet> r11 = m1.want_online(11, now);
	REQUIRE(r10.size() == 1);
	REQUIRE(r11.size() == 1);
	std::vector<Packet> g10 = w.on_packet(one(r10), now);
	std::vector<Packet> g11 = w.on_packet(one(r11), now);
	REQUIRE(g10.size() == 1);
	REQUIRE(g11.size() == 1);
	CHECK_EQ(w.counters().in_flight, uint64_t(2));
	CHECK_EQ(w.counters().retries, uint64_t(0));
	CHECK_EQ(w.tick(now + 10 * kRetryFirstMs).size(), size_t(2));
	CHECK_EQ(w.counters().retries, uint64_t(2));
	std::vector<Packet> c10 = m1.on_packet(one(g10), now);
	REQUIRE(c10.size() == 1);
	w.on_packet(one(c10), now);
	CHECK_EQ(w.counters().in_flight, uint64_t(1));
	std::vector<Packet> c11 = m1.on_packet(one(g11), now);
	REQUIRE(c11.size() == 1);
	w.on_packet(one(c11), now);
	CHECK_EQ(w.counters().in_flight, uint64_t(0));
	CHECK(w.tick(now + 100000).empty());
	CHECK_EQ(w.counters().retries, uint64_t(2));
}

// Requirement 6: journal fixed / rolled back - after a lost map server and after a load.
TEST(counters_journal_fixed_and_rolled_back)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	w.add_world_object(12, {3});
	net.take(m1, 10);
	net.take(m1, 11);
	std::vector<Packet> p10 = m1.want_offline(10, {9}, net.now);
	w.on_packet(one(p10), net.now); // Releasing
	std::vector<Packet> p11 = m1.want_offline(11, {8}, net.now);
	w.on_packet(one(p11), net.now); // Releasing
	Holder m2(kM2);
	std::vector<Packet> r12 = m2.want_online(12, net.now);
	w.on_packet(one(r12), net.now); // Granting
	const std::string journal = w.save_journal();
	CHECK_EQ(w.counters().completed, uint64_t(0));
	CHECK_EQ(w.counters().rolled_back, uint64_t(0));

	Ledger l;
	l.add_world_object(10, {1});
	l.add_world_object(11, {2});
	l.add_world_object(12, {3});
	REQUIRE(l.load_journal(journal));
	l.resolve_after_load();
	CHECK_EQ(l.counters().completed, uint64_t(2));
	CHECK_EQ(l.counters().rolled_back, uint64_t(1));
	CHECK_EQ(l.counters().in_flight, uint64_t(0));

	w.server_lost(kM1, net.now);
	CHECK_EQ(w.counters().completed, uint64_t(2));
	CHECK_EQ(w.counters().rolled_back, uint64_t(0));
	CHECK_EQ(w.counters().in_flight, uint64_t(1)); // 12 is m2's grant
	w.server_lost(kM2, net.now);
	CHECK_EQ(w.counters().rolled_back, uint64_t(1));
	CHECK_EQ(w.counters().in_flight, uint64_t(0));
}

// Requirement 6: violations and resyncs are counted apart.
TEST(counters_violations_and_resyncs)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	net.take(m1, 10);
	m1.changed(10, {3}, net.now); // drift
	std::vector<Entry> rep;
	for (const Entry& e : m1.report())
		rep.push_back(e);
	rep.push_back({11, w.gen(11), kNoParent, true, 0}); // a duplicate of a world object
	std::vector<Finding> f = audit(w, kM1, rep);
	REQUIRE(f.size() == 2);
	heal(w, f);
	CHECK_EQ(w.counters().violations, uint64_t(1));
	CHECK_EQ(w.counters().resyncs, uint64_t(1));
}

// ---------------------------------------------------------------------------------------------------------------------
// Fix round 1 (review of T2)
// ---------------------------------------------------------------------------------------------------------------------

// Review C1: an AbortAck is a promise - "I do not hold (id, gen) and never will". A map server in Committing (its
// own release in flight) that confirms the world's abort of a grant it never saw must not accept that grant later,
// even when it asks for the object again (`again`). The review's schedule, step by step.
TEST(xfer_abort_ack_bars_the_grant)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(5, {0});
	uint64_t t = 1000;
	std::vector<Packet> req1 = m1.want_online(5, t);
	std::vector<Packet> req2 = m1.tick(t + kRetryFirstMs); // a repeat of the request, late in the network
	t += kRetryFirstMs;
	std::vector<Packet> gr1 = w.on_packet(one(req1), t);
	std::vector<Packet> tc1 = m1.on_packet(one(gr1), t);
	std::vector<Packet> dn1 = w.on_packet(one(tc1), t);
	m1.on_packet(one(dn1), t);
	REQUIRE(w.owner(5) == kM1);
	std::vector<Packet> rp = m1.want_offline(5, {1}, t); // the player steps out ...
	m1.want_online(5, t); // ... and back in at once: again
	std::vector<Packet> ack = w.on_packet(one(rp), t);
	std::vector<Packet> rc = m1.on_packet(one(ack), t); // Committing
	std::vector<Packet> dn2 = w.on_packet(one(rc), t); // Done(g2): late in the network
	REQUIRE(w.world_authors(5));
	std::vector<Packet> gr3 = w.on_packet(one(req2), t); // the late request: grant g3, late in the network
	REQUIRE(gr3.size() == 1);
	const uint32_t g3 = gr3[0].key.gen;
	std::vector<Packet> ab = w.abort(5, t); // overtakes Done(g2) and Grant(g3)
	std::vector<Packet> aa = m1.on_packet(one(ab), t);
	REQUIRE(aa.size() == 1);
	CHECK(aa[0].op == Op::AbortAck);
	CHECK_EQ(aa[0].key.gen, g3);
	CHECK(w.on_packet(aa[0], t).empty());
	CHECK(w.world_authors(5));
	std::vector<Packet> req3 = m1.on_packet(one(dn2), t); // Committing ends; again: a new request (lost)
	CHECK_EQ(count_op(req3, Op::TakeReq, kWorld), size_t(1));
	std::vector<Packet> late = m1.on_packet(gr3[0], t); // the late grant g3
	CHECK(!m1.authors(5));
	CHECK(!(w.world_authors(5) && m1.authors(5)));
	CHECK_EQ(count_op(late, Op::TakeCommit, kWorld), size_t(0));
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Create, 5), size_t(1)); // the first take only

	// The request goes on and gets a fresh grant: one author again.
	Wire net(w, {&m1});
	net.now = t;
	net.send(std::move(late));
	net.run(5000);
	CHECK(m1.authors(5));
	CHECK(!w.world_authors(5));
	CHECK_EQ(w.owner(5), kM1);
	CHECK(w.gen(5) > g3);
	CHECK(m1.idle());
}

// Review C1, the spawn side: an abort answered while spawning bars the grant's gen but not the spawn's own Ack.
TEST(xfer_abort_while_spawning_keeps_the_spawn)
{
	Ledger w;
	Holder m1(kM1);
	const uint64_t t = 1000;
	std::vector<Packet> sp = m1.spawned(30, {3}, t);
	std::vector<Packet> aa = m1.on_packet(Packet{Op::Abort, {30, 0x00ffffffu}, kWorld, kM1, {}}, t);
	CHECK_EQ(count_op(aa, Op::AbortAck, kWorld), size_t(1));
	CHECK(m1.authors(30));
	std::vector<Packet> ack = w.on_packet(one(sp), t);
	CHECK(m1.on_packet(one(ack), t).empty());
	CHECK(m1.idle());
	CHECK_EQ(m1.gen(30), w.gen(30));
	// the barred gen: a grant under it is refused, never made
	CHECK_EQ(count_op(m1.on_packet(Packet{Op::Grant, {31, 5}, kWorld, kM1, {}}, t), Op::AbortAck, kWorld), size_t(1));
}

// Review I2: a record the world makes anew takes a fresh gen, so a late ReleaseCommit of the id's earlier life is still
// answered and the map server stops repeating it.
TEST(xfer_late_release_commit_after_id_reuse)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(7, {0});
	CHECK(w.gen(7) != 0);
	const uint64_t t = 1000;
	std::vector<Packet> req = m1.want_online(7, t);
	std::vector<Packet> gr = w.on_packet(one(req), t);
	std::vector<Packet> tc = m1.on_packet(one(gr), t);
	std::vector<Packet> dn = w.on_packet(one(tc), t);
	m1.on_packet(one(dn), t);
	std::vector<Packet> rp = m1.want_offline(7, {1}, t);
	std::vector<Packet> ack = w.on_packet(one(rp), t);
	std::vector<Packet> rc = m1.on_packet(one(ack), t);
	REQUIRE(rc.size() == 1);
	w.on_packet(rc[0], t); // applied; its Done is lost
	REQUIRE(w.world_destroy(7, t));
	w.tick(t + kTombstoneMs + 1000); // the tombstone goes
	w.add_world_object(7, {9}); // the id is used again
	CHECK(w.gen(7) > rc[0].key.gen);
	size_t answered = 0;
	for (uint64_t now = t + kTombstoneMs + 1000; now < t + kTombstoneMs + 20000; now += 100)
		for (const Packet& p : m1.tick(now))
			for (const Packet& a : w.on_packet(p, now))
			{
				++answered;
				m1.on_packet(a, now);
			}
	CHECK(answered >= 1);
	CHECK(m1.idle());
	CHECK(!m1.busy(7));
	CHECK(confirmed_is(w, 7, {9}));
	CHECK(w.world_authors(7));
}

// Review I3: healing a loss is two-phase - an Abort, repeated until AbortAck; a lost Abort leaves no second writer.
TEST(audit_lost_heal_is_two_phase)
{
	Ledger w;
	Holder m1(kM1);
	Wire net(w, {&m1});
	w.add_world_object(10, {0});
	net.take(m1, 10);
	const uint32_t g = w.gen(10);
	std::vector<Finding> f = audit(w, kM1, {}); // a wrong report: m1 still has the object
	REQUIRE(f.size() == 1);
	CHECK(f[0].kind == Violation::Lost);
	std::vector<Packet> out = heal(w, f); // lost in the network
	REQUIRE(out.size() == 1);
	CHECK(out[0].op == Op::Abort);
	CHECK_EQ(out[0].to, kM1);
	CHECK(out[0].key.gen > g);
	CHECK(!w.world_authors(10)); // not before the map server let go
	CHECK(w.phase(10) == Phase::Aborting);
	CHECK(m1.authors(10));
	CHECK_EQ(w.journal_size(), size_t(1));
	CHECK_EQ(w.counters().violations, uint64_t(1));
	net.run(5000); // the Abort repeats until answered
	CHECK(!m1.authors(10));
	CHECK(w.world_authors(10));
	CHECK(confirmed_is(w, 10, {0}));
	CHECK_EQ(w.journal_size(), size_t(0));
	CHECK(w.counters().retries >= 1);
	CHECK_EQ(count_events(m1.take_events(), Holder::Event::Kind::Remove, 10), size_t(1));
	CHECK(heal(w, f).empty()); // the same finding again: nothing left to do
}

// Review I4: a lost map server is gone for good (R7) - its late messages are ignored (a grant to a dead peer would
// freeze the object behind an abort nobody answers); server_joined takes the peer id back for a new connection.
TEST(xfer_lost_peer_ignored)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1});
	const uint64_t t = 1000;
	std::vector<Packet> req = m1.want_online(10, t);
	std::vector<Packet> sp = m1.spawned(20, {3}, t);
	w.server_lost(kM1, t);
	CHECK(w.on_packet(one(req), t).empty()); // no grant to a dead peer
	CHECK(w.world_authors(10));
	CHECK(!w.frozen(10));
	CHECK(w.on_packet(one(sp), t).empty());
	CHECK(!w.registered(20));
	CHECK(w.tick(t + 100000).empty());

	w.server_joined(kM1); // a new connection under the same peer id
	Holder m1b(kM1);
	Wire net(w, {&m1b});
	net.take(m1b, 10);
	CHECK_EQ(w.owner(10), kM1);
	CHECK(m1b.authors(10));
	w.server_lost(kM1, net.now);
	CHECK(audit(w, kM1, m1b.report()).empty()); // the auditor does not judge a lost peer
	CHECK(w.world_authors(10));
}

// Review m6: an abort of what the map server holds says both things - the object goes (Remove) and the request ended
// without it (Refused); a wish to take it again (`again`) is kept: it asks again.
TEST(xfer_abort_refuses_and_keeps_the_wish)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(10, {1});
	w.add_world_object(11, {2});
	const uint64_t t = 1000;
	std::vector<Packet> r10 = m1.want_online(10, t);
	std::vector<Packet> g10 = w.on_packet(one(r10), t);
	m1.on_packet(one(g10), t); // Held, the commit not delivered
	m1.take_events();
	std::vector<Packet> ab10 = w.abort(10, t);
	std::vector<Packet> aa = m1.on_packet(one(ab10), t);
	CHECK_EQ(count_op(aa, Op::AbortAck, kWorld), size_t(1));
	std::vector<Holder::Event> ev = m1.take_events();
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Remove, 10), size_t(1));
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Refused, 10), size_t(1));
	CHECK(!m1.busy(10));

	std::vector<Packet> r11 = m1.want_online(11, t);
	std::vector<Packet> g11 = w.on_packet(one(r11), t);
	m1.on_packet(one(g11), t);
	m1.want_offline(11, {5}, t); // Releasing (the prepare is lost)
	m1.want_online(11, t); // wanted again
	m1.take_events();
	std::vector<Packet> ab11 = w.abort(11, t);
	std::vector<Packet> out = m1.on_packet(one(ab11), t);
	CHECK_EQ(count_op(out, Op::AbortAck, kWorld), size_t(1));
	CHECK_EQ(count_op(out, Op::TakeReq, kWorld), size_t(1));
	ev = m1.take_events();
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Remove, 11), size_t(1));
	CHECK_EQ(count_events(ev, Holder::Event::Kind::Refused, 11), size_t(1));
	CHECK(m1.requesting(11));
}

// Review m7: the counters say exactly what they count - a spawn refused under a taken id is one violation however often
// the map server repeats it; a journal entry is completed only with its state applied; a map server counts its repeats.
TEST(counters_are_honest)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(600, {1});
	std::vector<Packet> sp = m1.spawned(600, {2}, 1000);
	for (int i = 0; i < 3; ++i)
		w.on_packet(one(sp), 1000);
	CHECK_EQ(w.counters().violations, uint64_t(1));

	Holder m2(kM2);
	m2.want_online(11, 1000);
	CHECK_EQ(m2.tick(1000 + 10 * kRetryFirstMs).size(), size_t(1));
	CHECK_EQ(m2.tick(1000 + 100 * kRetryFirstMs).size(), size_t(1));
	CHECK_EQ(m2.retries(), uint64_t(2));

	// A Releasing entry is applied even where the loading world has the object at a map server.
	Ledger src;
	Holder m3(kM1);
	Wire net(src, {&m3});
	src.add_world_object(10, {1});
	net.take(m3, 10);
	std::vector<Packet> rp = m3.want_offline(10, {7}, net.now);
	REQUIRE(src.on_packet(one(rp), net.now).size() == 1);
	const std::string journal = src.save_journal();
	Ledger l;
	Holder m4(kM2);
	Wire net4(l, {&m4});
	l.add_world_object(10, {1});
	net4.take(m4, 10);
	REQUIRE(l.load_journal(journal));
	l.resolve_after_load();
	CHECK(confirmed_is(l, 10, {7}));
	CHECK(l.world_authors(10));
	CHECK_EQ(l.counters().completed, uint64_t(1));
	CHECK_EQ(l.counters().rolled_back, uint64_t(1)); // the copy at m4
}

// Review m8: every load starts an epoch below the top bit, so a session always has at least 2^31 gens ahead.
TEST(xfer_gen_epochs_stay_low)
{
	std::string journal = Ledger().save_journal();
	size_t high = 0;
	for (int i = 0; i < 300; ++i)
	{
		Ledger l;
		REQUIRE(l.load_journal(journal));
		l.resolve_after_load();
		l.add_world_object(1, {1});
		if (l.gen(1) >= 0x80000000u || l.gen(1) == 0)
			++high;
		journal = l.save_journal();
	}
	CHECK_EQ(high, size_t(0));
}

// Found by the fuzzer in fix round 1 (limits profile): a map server spawns an id the world destroyed a while ago (its
// tombstone almost over), then destroys the spawn before the world saw it. The Destroy {0} must tombstone the id for
// this spawn anew - with the world's old tombstone gone, a late SpawnPrepare copy would register an object nobody has.
TEST(xfer_destroyed_spawn_outlives_an_old_tombstone)
{
	Ledger w;
	Holder m1(kM1);
	w.add_world_object(4, {1});
	const uint64_t t = 1000;
	REQUIRE(w.world_destroy(4, t));
	const uint64_t late = t + kTombstoneMs - 500; // the world's tombstone ends in half a second
	std::vector<Packet> sp = m1.spawned(4, {2}, late); // a reuse too early; the SpawnPrepare is late in the network
	std::vector<Packet> d = m1.destroyed(4, late);
	std::vector<Packet> done = w.on_packet(one(d), late);
	REQUIRE(done.size() == 1);
	CHECK(done[0].op == Op::Done);
	CHECK(m1.on_packet(done[0], late).empty());
	CHECK(m1.idle());
	w.tick(late + 1000); // the world's old tombstone is over
	CHECK(w.on_packet(one(sp), late + 1000).empty()); // the late copy registers nothing
	CHECK(!w.registered(4));
	w.tick(late + kTombstoneMs + 1000); // the new one is over too: the id is free
	Holder m2(kM2);
	std::vector<Packet> sp2 = m2.spawned(4, {3}, late + kTombstoneMs + 1000);
	CHECK_EQ(count_op(w.on_packet(one(sp2), late + kTombstoneMs + 1000), Op::Ack, kM2), size_t(1));
}
