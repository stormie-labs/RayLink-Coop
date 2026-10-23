// Anomaly Coop unit tests: leased object ids (F2 T12b, docs/research/f2-client-create-ids.md §5). The host takes free ids
// out of its own generator and leases them to a client (xrCoop/coop_id_lease.h HostLeases); the client reserves them in
// its generator (ClientPool) and creates an item at once under one of them, the host accepts the ReqSpawn with that id
// (marker 0xC7, coop_spawn.h) or the client takes its object back (SpecBook: the answer to the request).
#include "test_util.h"

#include "coop_id_lease.h"
#include "coop_spawn.h"

#include <algorithm>
#include <set>
#include <string>
#include <vector>

using namespace coop;

namespace
{
// The host's generator in the tests: hands out 100, 101, ... until `left` runs out (kNoId after).
struct Counter
{
	uint16_t next = 100;
	size_t left = 1000;
	uint16_t operator()()
	{
		if (!left)
			return lease::kNoId;
		--left;
		return next++;
	}
};

std::vector<uint8_t> leased_request(uint32_t seq, uint16_t parent, uint16_t id, uint16_t source,
    const std::string& section, size_t state_size)
{
	const float pos[3] = {1.f, 2.f, 3.f};
	std::vector<uint8_t> state(state_size, 0x5A);
	Writer w;
	spawn::write_leased(w, seq, parent, id, source, pos, section, state.data(), state.size());
	return w.data();
}
} // namespace

// ============================================================================ host: the leases

TEST(lease_host_grant_and_own)
{
	lease::HostLeases book;
	book.set_epoch(5);
	CHECK_EQ(book.want(1), lease::kLeaseSize); // a peer without a lease wants a whole one
	Counter pick;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> ids = book.grant(1, book.want(1), pick, bad);
	REQUIRE(ids.size() == lease::kLeaseSize);
	CHECK(bad.empty());
	CHECK_EQ(ids.front(), uint16_t(100));
	CHECK_EQ(ids.back(), uint16_t(100 + lease::kLeaseSize - 1));
	CHECK_EQ(book.count(1), lease::kLeaseSize);
	CHECK_EQ(book.want(1), size_t(0)); // full: nothing more until one is spent
	for (uint16_t id : ids)
	{
		CHECK(book.owns(1, id));
		CHECK(!book.owns(2, id)); // another player's lease never has it
	}
	CHECK(!book.owns(1, 99));
	CHECK(!book.owns(1, lease::kNoId));
	CHECK_EQ(book.total(), lease::kLeaseSize);
	// a second player gets other ids
	const std::vector<uint16_t> second = book.grant(2, 4, pick, bad);
	REQUIRE(second.size() == 4);
	for (uint16_t id : second)
		CHECK(std::find(ids.begin(), ids.end(), id) == ids.end());
	CHECK_EQ(book.total(), lease::kLeaseSize + 4);
}

TEST(lease_host_spend_once_then_refill_one_to_one)
{
	lease::HostLeases book;
	book.set_epoch(1);
	Counter pick;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> ids = book.grant(3, lease::kLeaseSize, pick, bad);
	REQUIRE(!ids.empty());
	const uint16_t id = ids[7];
	CHECK(book.spend(3, id)); // the host created the item with it
	CHECK(!book.owns(3, id));
	CHECK(!book.spend(3, id)); // a second request with the same id: not his any more
	CHECK_EQ(book.want(3), size_t(1)); // 1:1: one spent, one more
	const std::vector<uint16_t> more = book.grant(3, book.want(3), pick, bad);
	REQUIRE(more.size() == 1);
	CHECK(more[0] != id);
	CHECK_EQ(book.count(3), lease::kLeaseSize);
	CHECK_EQ(book.stats().spent, uint64_t(1));
	CHECK_EQ(book.stats().granted, uint64_t(lease::kLeaseSize + 1));
}

TEST(lease_host_foreign_and_spent_ids_refused)
{
	lease::HostLeases book;
	book.set_epoch(1);
	Counter pick;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> a = book.grant(1, 2, pick, bad);
	const std::vector<uint16_t> b = book.grant(2, 2, pick, bad);
	REQUIRE(a.size() == 2 && b.size() == 2);
	CHECK(!book.spend(1, b[0])); // another player's id
	CHECK(!book.give_back(1, b[0]));
	CHECK(book.owns(2, b[0])); // untouched
	CHECK(!book.spend(1, 5000)); // an id nobody leased
	CHECK(!book.give_back(1, 0));
	CHECK(book.spend(1, a[0]));
	CHECK(!book.give_back(1, a[0])); // spent: an entity of the host's world has it, never freed by a give-back
}

TEST(lease_host_give_back)
{
	// The client could not take an id (an object of its own holds it there) or its create was refused: the id goes
	// back to the host, who frees it in its generator and tops the lease up again.
	lease::HostLeases book;
	book.set_epoch(1);
	Counter pick;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> ids = book.grant(4, lease::kLeaseSize, pick, bad);
	CHECK(book.give_back(4, ids[0]));
	CHECK(book.give_back(4, ids[1]));
	CHECK(!book.owns(4, ids[0]));
	CHECK(!book.give_back(4, ids[0])); // once
	CHECK_EQ(book.want(4), size_t(2));
	CHECK_EQ(book.stats().given_back, uint64_t(2));
	// A client that gives back again and again stops getting new ids in this world (it churns the host's generator).
	size_t rounds = 0;
	while (book.want(4) > 0 && rounds < 10 * lease::kMaxGivenBack)
	{
		const std::vector<uint16_t> one = book.grant(4, 1, pick, bad);
		REQUIRE(one.size() == 1);
		book.give_back(4, one[0]);
		++rounds;
	}
	CHECK_EQ(rounds, lease::kMaxGivenBack - 2);
	CHECK_EQ(book.want(4), size_t(0));
	CHECK(book.grant(4, 5, pick, bad).empty()); // grant never gives more than want()
	// a new world starts it again
	CHECK(book.set_epoch(2));
	CHECK_EQ(book.want(4), lease::kLeaseSize);
}

TEST(lease_host_bad_picks)
{
	// What the generator gives is checked: id 0 (the actor), kNoId (none left) and an id leased already are not leased;
	// the first two end the grant or are left out, a picked id that is not leased goes to `bad` for the caller to free.
	lease::HostLeases book;
	book.set_epoch(1);
	std::vector<uint16_t> seq = {200, 0, 200, 201, lease::kNoId, 202};
	size_t i = 0;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> ids = book.grant(1, 10, [&] { return i < seq.size() ? seq[i++] : lease::kNoId; }, bad);
	CHECK((ids == std::vector<uint16_t>{200, 201}));
	CHECK((bad == std::vector<uint16_t>{0, 200})); // 0 and the repeat: picked, not leased
	CHECK_EQ(i, size_t(5)); // kNoId: the generator has no more, the grant stops
	CHECK(!book.owns(1, 0));
	Counter none;
	none.left = 0;
	CHECK(book.grant(2, 3, none, bad).empty());
}

TEST(lease_host_drop_and_epoch)
{
	lease::HostLeases book;
	book.set_epoch(7);
	CHECK(!book.set_epoch(7)); // the same world: nothing changes
	Counter pick;
	std::vector<uint16_t> bad;
	const std::vector<uint16_t> a = book.grant(1, 3, pick, bad);
	const std::vector<uint16_t> b = book.grant(2, 3, pick, bad);
	book.spend(1, a[0]);
	// The player left: what he still holds goes back (the caller frees it), the spent one is the world's.
	std::vector<uint16_t> dropped = book.drop(1);
	std::sort(dropped.begin(), dropped.end());
	CHECK((dropped == std::vector<uint16_t>{a[1], a[2]}));
	CHECK_EQ(book.count(1), size_t(0));
	CHECK(book.drop(1).empty());
	CHECK(book.owns(2, b[0]));
	// The host world was replaced (a load): every lease is void; the new world's generator never had these ids, so
	// nothing is freed (a free of a free id would put it twice into the generator).
	CHECK(book.leased(b[0]) && !book.leased(a[0]));
	CHECK(book.set_epoch(8));
	CHECK_EQ(book.epoch(), uint32_t(8));
	CHECK(!book.owns(2, b[0]) && !book.leased(b[0]));
	CHECK_EQ(book.total(), size_t(0));
	const std::vector<uint16_t> c = book.grant(2, 2, pick, bad);
	const std::vector<uint16_t> d = book.grant(3, 1, pick, bad);
	// The session ends in the same world: every lease goes back to the host's generator.
	std::vector<uint16_t> all = book.drop_all();
	std::sort(all.begin(), all.end());
	CHECK((all == std::vector<uint16_t>{c[0], c[1], d[0]}));
	CHECK_EQ(book.total(), size_t(0));
	CHECK_EQ(book.count(2), size_t(0));
	book.grant(2, 2, pick, bad);
	book.clear(); // the session ends with the world: nothing to free
	CHECK_EQ(book.total(), size_t(0));
}

// ============================================================================ client: the pool

TEST(lease_client_pool_take)
{
	lease::ClientPool pool;
	std::set<uint16_t> busy_here = {103}; // an object of this machine holds 103 (a bolt, a fake missile)
	std::set<uint16_t> reserved;
	const auto take_here = [&](uint16_t id)
	{
		if (busy_here.count(id))
			return false;
		reserved.insert(id);
		return true;
	};
	std::vector<uint16_t> rejected;
	const size_t added = pool.add(4, {101, 102, 103, 104}, take_here, rejected);
	CHECK_EQ(added, size_t(3));
	CHECK((rejected == std::vector<uint16_t>{103})); // back to the host
	CHECK((reserved == std::set<uint16_t>{101, 102, 104}));
	CHECK_EQ(pool.size(), size_t(3));
	CHECK(pool.has(101) && !pool.has(103));
	// The same id again (a host that repeats itself): skipped, neither reserved twice nor given back.
	rejected.clear();
	CHECK_EQ(pool.add(4, {101}, take_here, rejected), size_t(0));
	CHECK(rejected.empty());
	CHECK_EQ(pool.size(), size_t(3));
	// Taken first in, first out; a taken id is the caller's.
	CHECK_EQ(pool.take(), uint16_t(101));
	CHECK_EQ(pool.take(), uint16_t(102));
	CHECK(!pool.has(101));
	pool.put_back(102); // a temporary object released before its register: the id can be used again
	CHECK(pool.has(102));
	pool.put_back(102); // once
	CHECK_EQ(pool.size(), size_t(2));
	CHECK_EQ(pool.take(), uint16_t(104));
	CHECK_EQ(pool.take(), uint16_t(102));
	CHECK_EQ(pool.take(), lease::kNoId); // empty
	CHECK_EQ(pool.stats().taken, uint64_t(4));
	pool.put_back(0); // not an id that can be leased
	pool.put_back(lease::kNoId);
	CHECK_EQ(pool.size(), size_t(0));
}

TEST(lease_client_pool_new_world)
{
	// A lease of another world (the host loaded, a level change): the old ids went with the old generator.
	lease::ClientPool pool;
	std::vector<uint16_t> rejected;
	const auto yes = [](uint16_t) { return true; };
	pool.add(1, {10, 11}, yes, rejected);
	CHECK_EQ(pool.epoch(), uint32_t(1));
	pool.add(2, {20}, yes, rejected);
	CHECK_EQ(pool.epoch(), uint32_t(2));
	CHECK_EQ(pool.size(), size_t(1));
	CHECK(pool.has(20) && !pool.has(10));
	pool.clear();
	CHECK_EQ(pool.size(), size_t(0));
	CHECK_EQ(pool.take(), lease::kNoId);
}

// ============================================================================ client: the answers

TEST(lease_spec_confirm_and_rollback)
{
	lease::SpecBook book;
	book.add(300);
	book.add(301, 900); // a clone: it replaces item 900
	CHECK(book.pending(300) && book.pending(301));
	CHECK(book.is_source(900));
	CHECK(!book.is_source(300));
	book.sent(300, 11);
	book.sent(301, 12);
	uint16_t id = 0;
	CHECK(book.answer(11, true, false, 0, id) == lease::Outcome::Confirmed);
	CHECK_EQ(id, uint16_t(300));
	CHECK(!book.pending(300));
	CHECK(book.answer(11, true, false, 0, id) == lease::Outcome::Unknown); // answered once
	// Refused for a reason that stays (not his, a section he may not have, the holder gone): taken back here.
	CHECK(book.answer(12, false, false, 0, id) == lease::Outcome::RolledBack);
	CHECK_EQ(id, uint16_t(301));
	CHECK(!book.pending(301) && !book.is_source(900));
	CHECK(book.answer(99, false, false, 0, id) == lease::Outcome::Unknown); // no create of ours
	CHECK_EQ(book.size(), size_t(0));
}

TEST(lease_spec_rate_limited_is_retried)
{
	// RateLimited is no refusal of the item: the same id is asked again after 100-250 ms, each try later than the one
	// before; after kMaxRetries the create is taken back.
	lease::SpecBook book;
	book.add(400);
	book.sent(400, 1);
	uint16_t id = 0;
	CHECK(book.answer(1, false, true, 1000, id) == lease::Outcome::Retry);
	CHECK_EQ(id, uint16_t(400));
	CHECK(book.pending(400));
	CHECK(book.due(1000 + lease::kRetryFirstMs - 1).empty());
	CHECK((book.due(1000 + lease::kRetryFirstMs) == std::vector<uint16_t>{400}));
	book.sent(400, 2); // asked again: not due any more, the old seq is forgotten
	CHECK(book.due(1000000).empty());
	CHECK(book.answer(1, true, false, 2000, id) == lease::Outcome::Unknown);
	uint64_t prev = 0;
	uint32_t seq = 2;
	for (uint32_t i = 2; i < lease::kMaxRetries; ++i) // tries 2 .. kMaxRetries - 1
	{
		REQUIRE(book.answer(seq, false, true, 10000, id) == lease::Outcome::Retry);
		const uint32_t delay = lease::retry_delay(i);
		CHECK(delay >= lease::kRetryFirstMs && delay <= lease::kRetryMaxMs);
		CHECK(delay >= prev);
		prev = delay;
		book.sent(400, ++seq);
	}
	CHECK(book.answer(seq, false, true, 10000, id) == lease::Outcome::RolledBack);
	CHECK(!book.pending(400));
}

TEST(lease_spec_forget)
{
	lease::SpecBook book;
	book.add(500, 600);
	CHECK(book.forget(500));
	CHECK(!book.forget(500));
	CHECK(!book.is_source(600));
	book.add(501);
	book.add(501); // twice: one record
	CHECK_EQ(book.size(), size_t(1));
	book.clear();
	CHECK_EQ(book.size(), size_t(0));
}

TEST(lease_clone_cost)
{
	// A clone replaces its source on the host (released there with the clone's creation): the budget pays only what the
	// clone is worth more (a scope variant, another weapon); a detached scope comes as an item of its own.
	CHECK_EQ(lease::clone_cost(30000, 25000), uint32_t(5000));
	CHECK_EQ(lease::clone_cost(25000, 30000), uint32_t(0));
	CHECK_EQ(lease::clone_cost(1000, 1000), uint32_t(0));
}

// ============================================================================ the wire

TEST(lease_ids_msg_roundtrip)
{
	lease::IdsMsg m;
	m.epoch = 0xA1B2C3D4u;
	m.ids = {5, 6, 0xFFFE, 300};
	Writer w;
	m.write(w);
	Reader r(w.ptr(), w.size());
	lease::IdsMsg got;
	REQUIRE(got.read(r));
	CHECK_EQ(got.epoch, m.epoch);
	CHECK((got.ids == m.ids));
	CHECK_EQ(r.remaining(), size_t(0));
	// empty: an ack with nothing to give back is valid too
	Writer we;
	lease::IdsMsg().write(we);
	Reader re(we.ptr(), we.size());
	CHECK(got.read(re) && got.ids.empty());
}

TEST(lease_ids_msg_malformed)
{
	const auto refused = [](const std::vector<uint16_t>& ids, uint64_t n)
	{
		Writer w;
		w.u32(1);
		w.varu(n);
		for (uint16_t id : ids)
			w.u16(id);
		Reader r(w.ptr(), w.size());
		lease::IdsMsg m;
		m.ids = {77};
		const bool ok = m.read(r);
		return !ok && m.ids.empty();
	};
	CHECK(refused({1, 2}, 3)); // fewer ids than n
	CHECK(refused({}, lease::kMaxIdsPerMsg + 1)); // more than a message may carry
	CHECK(refused({1, 0}, 2)); // id 0: the actor
	CHECK(refused({1, lease::kNoId}, 2)); // no id
	CHECK(refused({9, 9}, 2)); // twice
	std::vector<uint16_t> full;
	for (uint16_t i = 1; i <= lease::kMaxIdsPerMsg; ++i)
		full.push_back(i);
	CHECK(!refused(full, full.size()));
	static_assert(lease::kLeaseSize <= lease::kMaxIdsPerMsg, "a whole lease fits one IdLease");
}

TEST(lease_spawn_request_layout)
{
	// ReqSpawn with a leased id: marker 0xC7, then parent, id, source (0xffff: no clone) and the State fields.
	const std::vector<uint8_t> msg = leased_request(77, 0x1234, 4321, lease::kNoId, "medkit", 3);
	REQUIRE(spawn::detect(msg.data(), msg.size()) == spawn::Layout::Leased);
	CHECK(spawn::has_seq(spawn::Layout::Leased));
	Reader r(msg.data(), msg.size());
	CHECK_EQ(r.u32(), 77u);
	spawn::Request q;
	REQUIRE(spawn::read_body(r, spawn::Layout::Leased, q));
	CHECK_EQ(q.parent, 0x1234);
	CHECK_EQ(q.id, 4321);
	CHECK_EQ(q.source, lease::kNoId);
	CHECK(q.pos[0] == 1.f && q.pos[2] == 3.f);
	CHECK(q.section == "medkit");
	CHECK_EQ(q.state_size, size_t(3));
	CHECK_EQ(r.remaining(), size_t(0));
	// a clone names the weapon it replaces
	const std::vector<uint8_t> clone = leased_request(78, 0x1234, 4322, 900, "wpn_ak74_pso", 0);
	Reader rc(clone.data(), clone.size());
	rc.u32();
	REQUIRE(spawn::read_body(rc, spawn::Layout::Leased, q));
	CHECK_EQ(q.id, 4322);
	CHECK_EQ(q.source, 900);
	// An id that cannot be leased is malformed (0: the actor, 0xffff: none).
	for (uint16_t bad : {uint16_t(0), lease::kNoId})
	{
		const std::vector<uint8_t> m = leased_request(1, 2, bad, lease::kNoId, "bread", 0);
		Reader rb(m.data(), m.size());
		rb.u32();
		CHECK(!spawn::read_body(rb, spawn::Layout::Leased, q));
	}
	// cut inside the ids
	std::vector<uint8_t> cut(msg.begin(), msg.begin() + 4 + 1 + 2 + 1);
	Reader rt(cut.data(), cut.size());
	rt.u32();
	CHECK(!spawn::read_body(rt, spawn::Layout::Leased, q));
}

TEST(lease_spawn_request_state_layout_unchanged)
{
	// 0xC6 stays what it was (no lease: the request path that answers nil), its Request has no id.
	const float pos[3] = {0.f, 0.f, 0.f};
	Writer w;
	spawn::write_state(w, 5, 6, pos, "bread", nullptr, 0);
	REQUIRE(spawn::detect(w.ptr(), w.size()) == spawn::Layout::State);
	Reader r(w.ptr(), w.size());
	r.u32();
	spawn::Request q;
	q.id = 1234;
	q.source = 99;
	REQUIRE(spawn::read_body(r, spawn::Layout::State, q));
	CHECK_EQ(q.id, lease::kNoId);
	CHECK_EQ(q.source, lease::kNoId);
}

TEST(lease_queued_request_keeps_id)
{
	// A leased request over the budget waits with its id (and the clone's source); the id stays leased meanwhile.
	const float pos[3] = {1.f, 2.f, 3.f};
	const spawn::QueuedRequest r =
	    spawn::queued_request(7, 2, 0x10, 0x10, pos, "wpn_ak74_pso", nullptr, 0, 3, false, 4321, 900);
	CHECK_EQ(r.id, uint16_t(4321));
	CHECK_EQ(r.source, uint16_t(900));
	const spawn::QueuedRequest plain = spawn::queued_request(7, 2, 0x10, 0x10, pos, "bread", nullptr, 0, 3, false);
	CHECK_EQ(plain.id, lease::kNoId);
	CHECK_EQ(plain.source, lease::kNoId);
}
