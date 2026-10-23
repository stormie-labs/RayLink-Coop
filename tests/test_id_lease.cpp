// Anomaly Coop unit tests: leased object ids (F2 T12b, docs/research/f2-client-create-ids.md §5). The host takes free ids
// out of its own generator and leases them to a client (xrCoop/coop_id_lease.h HostLeases); the client reserves them in
// its generator (ClientPool) and creates an item at once under one of them, the host accepts the ReqSpawn with that id
// (marker 0xC7, coop_spawn.h) or the client takes its object back (SpecBook: the answer to the request).
#include "test_util.h"

#include "coop_id_lease.h"
#include "coop_spawn.h"

#include <algorithm>
#include <deque>
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
	book.sent(300, 11, 0);
	book.sent(301, 12, 0);
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
	book.sent(400, 1, 0);
	uint16_t id = 0;
	CHECK(book.answer(1, false, true, 1000, id) == lease::Outcome::Retry);
	CHECK_EQ(id, uint16_t(400));
	CHECK(book.pending(400));
	const lease::SpecBook::Due early = book.due(1000 + lease::kRetryFirstMs - 1);
	CHECK(early.resend.empty() && early.rollback.empty());
	CHECK((book.due(1000 + lease::kRetryFirstMs).resend == std::vector<uint16_t>{400}));
	book.sent(400, 2, 1100); // asked again: in flight, not due before its answer is late
	CHECK(book.due(1100 + lease::kAnswerTimeoutMs - 1).resend.empty());
	// round 2: a refusal of an older request of it is stale (the newer one decides)
	CHECK(book.answer(1, false, false, 2000, id) == lease::Outcome::Unknown);
	CHECK(book.pending(400));
	uint64_t prev = 0;
	uint32_t seq = 2;
	for (uint32_t i = 2; i < lease::kMaxRetries; ++i) // tries 2 .. kMaxRetries - 1
	{
		REQUIRE(book.answer(seq, false, true, 10000, id) == lease::Outcome::Retry);
		const uint32_t delay = lease::retry_delay(i);
		CHECK(delay >= lease::kRetryFirstMs && delay <= lease::kRetryMaxMs);
		CHECK(delay >= prev);
		prev = delay;
		book.sent(400, ++seq, 10000);
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

// ============================================================================ round 1 (task-12b-review.md)

TEST(lease_held_actions_wait_for_their_item)
{
	// Review C1: a request about an item of ours the host has not created yet (its create waits in the host's budget
	// queue, or for a retry after RateLimited) would reach the host first and be refused (Missing) while the item is
	// created later: a duplicate. Such requests wait here, in order, until the host's Ok; a rollback drops them.
	lease::Held<int> held;
	held.hold(300, 1);
	held.hold(301, 2);
	held.hold(300, 3);
	CHECK(held.holds(300) && held.holds(301) && !held.holds(302));
	CHECK_EQ(held.size(), size_t(3));
	CHECK((held.release(300) == std::vector<int>{1, 3})); // in the order they were made
	CHECK(!held.holds(300));
	CHECK(held.release(300).empty());
	std::vector<int> dropped;
	CHECK_EQ(held.drop(301, [&](int& a) { dropped.push_back(a); }), size_t(1));
	CHECK((dropped == std::vector<int>{2}));
	CHECK_EQ(held.size(), size_t(0));
	held.hold(5, 7);
	held.hold(6, 8);
	dropped.clear();
	held.clear([&](int& a) { dropped.push_back(a); });
	std::sort(dropped.begin(), dropped.end());
	CHECK((dropped == std::vector<int>{7, 8}));
	CHECK_EQ(held.size(), size_t(0));
}

TEST(lease_spec_first_pending)
{
	// Which create an action waits for: the first id it names that is ours and not answered yet.
	lease::SpecBook book;
	book.add(300);
	book.add(301, 900);
	CHECK_EQ(book.first_pending({lease::kNoId, 5, 300}), uint16_t(300));
	CHECK_EQ(book.first_pending({301, 300}), uint16_t(301));
	CHECK_EQ(book.first_pending({5, 900, lease::kNoId}), lease::kNoId); // a clone's source is no create of ours
	CHECK_EQ(book.first_pending({}), lease::kNoId);
	// a clone of a weapon the host has not made yet, or of one a pending clone replaces: refused (review C1)
	CHECK(book.waiting(300) && book.waiting(900) && !book.waiting(5) && !book.waiting(lease::kNoId));
}

TEST(lease_quarantine_keeps_other_worlds)
{
	// Review I2: a rolled-back entity is freed kQuarantineMs after its release, but only in the world it was released
	// in: a new world closed the Lua state its script object lives in, freeing it then is an access violation.
	lease::Quarantine<int> q;
	q.keep(1, 1000, 7);
	q.keep(2, 5000, 7);
	q.keep(3, 1000, 6); // released before the world changed
	std::vector<int> freed, leaked;
	const auto free_it = [&](int e) { freed.push_back(e); };
	const auto leak_it = [&](int e) { leaked.push_back(e); };
	CHECK_EQ(q.expire(1000 + 100 - 1, 100, 7, false, free_it, leak_it), size_t(0));
	CHECK_EQ(q.expire(1100, 100, 7, false, free_it, leak_it), size_t(2)); // 1 freed, 3 of another world left
	CHECK((freed == std::vector<int>{1}));
	CHECK((leaked == std::vector<int>{3}));
	CHECK_EQ(q.size(), size_t(1));
	q.expire(1100, 100, 8, true, free_it, leak_it); // the session ends in another world: nothing of world 7 is freed
	CHECK((freed == std::vector<int>{1}));
	CHECK((leaked == std::vector<int>{3, 2}));
	CHECK_EQ(q.size(), size_t(0));
}

TEST(lease_clone_state_from_source)
{
	// Review I1: the host builds a clone from its own source (as lua_clone copies it on the client), never from the
	// client's blob: a modified client would get upgrades, a full magazine and a repair for the price difference.
	const std::vector<uint8_t> client = {9, 9, 9, 9};
	const std::vector<uint8_t> source = {1, 2};
	spawn::StateRef s = spawn::spawn_state(900, client.data(), client.size(), source);
	CHECK(s.data == source.data() && s.size == 2);
	const std::vector<uint8_t> none;
	s = spawn::spawn_state(900, client.data(), client.size(), none); // no state of the source: the section's defaults
	CHECK_EQ(s.size, size_t(0));
	s = spawn::spawn_state(lease::kNoId, client.data(), client.size(), source); // a create: the client's blob
	CHECK(s.data == client.data() && s.size == 4);
}

// ============================================================================ round 2 (task-12b-review.md, N1 N3)

TEST(lease_spec_watchdog)
{
	// N1: a request the host never answers (the session's rate row drops it silently, or it never got there) is asked
	// again with the same id after kAnswerTimeoutMs; after kMaxResends the create is taken back - nothing waits for ever.
	lease::SpecBook book;
	book.add(500);
	book.sent(500, 1, 0);
	uint64_t now = 0;
	CHECK(book.due(lease::kAnswerTimeoutMs - 1).resend.empty());
	for (uint32_t i = 0; i < lease::kMaxResends; ++i)
	{
		now += lease::kAnswerTimeoutMs;
		const lease::SpecBook::Due d = book.due(now);
		REQUIRE((d.resend == std::vector<uint16_t>{500}) && d.rollback.empty());
		book.sent(500, 0, now); // in our own outbox (paced): no watchdog meanwhile
		CHECK(book.due(now + 10 * lease::kAnswerTimeoutMs).resend.empty());
		book.sent(500, 2 + i, now);
	}
	now += lease::kAnswerTimeoutMs;
	const lease::SpecBook::Due last = book.due(now);
	CHECK(last.resend.empty() && (last.rollback == std::vector<uint16_t>{500}));
	CHECK(!book.pending(500) && book.size() == 0);
}

TEST(lease_spec_queued_waits)
{
	// N1: the host says the request waits in its budget queue (ReqResult Queued, not final): no watchdog for it - a
	// second request with its id would queue twice; the host answers when it creates or refuses it.
	lease::SpecBook book;
	book.add(600);
	book.sent(600, 7, 0);
	CHECK(book.queued(7));
	CHECK(!book.queued(8)); // no request of ours
	const lease::SpecBook::Due d = book.due(100 * lease::kAnswerTimeoutMs);
	CHECK(d.resend.empty() && d.rollback.empty());
	uint16_t id = 0;
	CHECK(book.answer(7, true, false, 0, id) == lease::Outcome::Confirmed);
}

TEST(lease_spec_any_request_confirms)
{
	// N1: asked twice (the watchdog), the host makes it under the first request and refuses the second (not his any
	// more): the Ok of either confirms, what comes after is no news.
	lease::SpecBook book;
	book.add(700);
	book.sent(700, 1, 0);
	REQUIRE(book.due(lease::kAnswerTimeoutMs).resend.size() == 1);
	book.sent(700, 2, lease::kAnswerTimeoutMs);
	uint16_t id = 0;
	CHECK(book.answer(1, true, false, 0, id) == lease::Outcome::Confirmed);
	CHECK_EQ(id, uint16_t(700));
	CHECK(book.answer(2, false, false, 0, id) == lease::Outcome::Unknown);
	CHECK(book.size() == 0);
}

TEST(lease_spawn_pacer)
{
	// N1: a client's ReqSpawn goes no faster than the host takes it (CatSpawn: 20 a second after 40 in a row; the
	// session's row drops more without an answer): kSpawnPaceBurst in a row, then one per kSpawnPaceMs.
	lease::SpawnPacer pacer;
	size_t n = 0;
	while (pacer.take(1000))
		++n;
	CHECK_EQ(n, size_t(lease::kSpawnPaceBurst));
	CHECK(!pacer.take(1000 + lease::kSpawnPaceMs - 1));
	CHECK(pacer.take(1000 + lease::kSpawnPaceMs));
	CHECK(!pacer.take(1000 + lease::kSpawnPaceMs));
	static_assert(lease::kSpawnPaceMs > 50 && lease::kSpawnPaceBurst <= 40, "slower than the host's 20 a second, 40");
}

namespace
{
// A burst of creates against a model of the host: the session's rate row for ReqSpawn (80 in a row, one per 25 ms,
// dropped without an answer), the host's CatSpawn bucket (40 in a row, 20 a second: RateLimited), every third item over
// the cost budget (Queued at once, made 2 s later), 50 ms each way. `paced`: the client's pacer on.
struct BurstResult
{
	size_t confirmed = 0, rolled_back = 0, pending = 0, dropped = 0, rate_limited = 0;
};

struct ModelBucket
{
	double tokens;
	double burst;
	double per_ms;
	uint64_t at = 0;
	bool take(uint64_t now)
	{
		tokens = std::min(burst, tokens + double(now - at) * per_ms);
		at = now;
		if (tokens < 1.)
			return false;
		tokens -= 1.;
		return true;
	}
};

struct ModelMsg
{
	uint64_t at;
	uint32_t seq;
	uint16_t id;
	int kind; // to the host: 0; to the client: 1 Ok, 2 RateLimited, 3 refused, 4 Queued
};

BurstResult run_burst(size_t creates, bool paced)
{
	const uint64_t kWire = 50;
	lease::SpecBook book;
	lease::SpawnPacer pacer;
	std::deque<uint16_t> out;
	std::vector<ModelMsg> to_host, to_client;
	std::set<uint16_t> made, queued_ids;
	std::vector<std::pair<uint64_t, ModelMsg>> host_queue; // (when made, the request)
	ModelBucket row{80., 80., 1. / 25.};
	ModelBucket cat{40., 40., 20. / 1000.};
	BurstResult res;
	uint32_t seq = 0;
	for (size_t i = 0; i < creates; ++i)
	{
		const uint16_t id = uint16_t(1000 + i);
		book.add(id);
		out.push_back(id);
	}
	for (uint64_t now = 0; now <= 300000; now += 10)
	{
		// client: retries and the watchdog, then what the pacer lets out
		const lease::SpecBook::Due due = book.due(now);
		for (uint16_t id : due.resend)
		{
			book.sent(id, 0, now);
			out.push_back(id);
		}
		res.rolled_back += due.rollback.size();
		while (!out.empty() && (!paced || pacer.take(now)))
		{
			const uint16_t id = out.front();
			out.pop_front();
			if (!book.pending(id))
				continue;
			book.sent(id, ++seq, now);
			to_host.push_back({now + kWire, seq, id, 0});
		}
		// host: arrivals in order
		for (auto it = to_host.begin(); it != to_host.end();)
		{
			if (it->at > now)
			{
				++it;
				continue;
			}
			const ModelMsg m = *it;
			it = to_host.erase(it);
			if (!row.take(now))
			{
				++res.dropped; // the session's row: no answer at all
				continue;
			}
			if (!cat.take(now))
			{
				++res.rate_limited;
				to_client.push_back({now + kWire, m.seq, m.id, 2});
			}
			else if (made.count(m.id) || queued_ids.count(m.id))
				to_client.push_back({now + kWire, m.seq, m.id, 3}); // its id is spent, or taken by the queued one
			else if (m.id % 3 == 0)
			{
				queued_ids.insert(m.id);
				to_client.push_back({now + kWire, m.seq, m.id, 4});
				host_queue.push_back({now + 2000, m});
			}
			else
			{
				made.insert(m.id);
				to_client.push_back({now + kWire, m.seq, m.id, 1});
			}
		}
		for (auto it = host_queue.begin(); it != host_queue.end();)
		{
			if (it->first > now)
			{
				++it;
				continue;
			}
			made.insert(it->second.id);
			to_client.push_back({now + kWire, it->second.seq, it->second.id, 1});
			it = host_queue.erase(it);
		}
		// client: answers
		for (auto it = to_client.begin(); it != to_client.end();)
		{
			if (it->at > now)
			{
				++it;
				continue;
			}
			const ModelMsg m = *it;
			it = to_client.erase(it);
			if (m.kind == 4)
			{
				book.queued(m.seq);
				continue;
			}
			uint16_t id = 0;
			const lease::Outcome o = book.answer(m.seq, m.kind == 1, m.kind == 2, now, id);
			res.confirmed += o == lease::Outcome::Confirmed ? 1 : 0;
			res.rolled_back += o == lease::Outcome::RolledBack ? 1 : 0;
		}
		if (book.size() == 0 && to_client.empty() && to_host.empty() && host_queue.empty())
			break;
	}
	res.pending = book.size();
	return res;
}
} // namespace

TEST(lease_burst_of_creates_all_settle)
{
	// N1: 100 creates at once (a mass disassembly, unpacking). Paced, nothing is dropped by the session's row and every
	// create is made (a third of them after the budget queue). Unpaced (the bug: every retry at once), the row drops some
	// and the host rate-limits many - still nothing waits for ever: the watchdog asks again or takes the item back.
	const BurstResult paced = run_burst(100, true);
	CHECK_EQ(paced.pending, size_t(0));
	CHECK_EQ(paced.dropped, size_t(0));
	CHECK_EQ(paced.confirmed, size_t(100));
	CHECK_EQ(paced.rolled_back, size_t(0));
	const BurstResult unpaced = run_burst(100, false);
	CHECK_EQ(unpaced.pending, size_t(0));
	CHECK_EQ(unpaced.confirmed + unpaced.rolled_back, size_t(100));
	CHECK(unpaced.dropped > 0); // the model shows the loss the pacer avoids
}

TEST(lease_clone_family)
{
	// N3: a clone keeps to its weapon's variants - the same section, or one base (parent_section; a section without one
	// is its own base): a scope or magnifier variant. Another weapon would convert the source's rounds into its ammo.
	CHECK(lease::clone_family("wpn_ak74", "", "wpn_ak74_pso", "wpn_ak74")); // attach: base -> variant
	CHECK(lease::clone_family("wpn_ak74_pso", "wpn_ak74", "wpn_ak74", "wpn_ak74")); // detach (the base names itself)
	CHECK(lease::clone_family("wpn_ak74_pso", "wpn_ak74", "wpn_ak74", "")); // a base without the line
	CHECK(lease::clone_family("wpn_ak74_pso", "wpn_ak74", "wpn_ak74_kobra", "wpn_ak74")); // variant -> variant
	CHECK(lease::clone_family("wpn_aug_kit_off", "wpn_aug_kit", "wpn_aug_kit", "wpn_aug_kit")); // a magnifier pair
	CHECK(lease::clone_family("wpn_pm", "", "wpn_pm", "")); // the same section (a jam cleared)
	CHECK(!lease::clone_family("wpn_pm", "", "wpn_svd", ""));
	CHECK(!lease::clone_family("wpn_ak74_pso", "wpn_ak74", "wpn_svd_pso", "wpn_svd"));
	CHECK(!lease::clone_family("wpn_ak74", "wpn_ak74", "wpn_vintorez", "wpn_vintorez"));
}
