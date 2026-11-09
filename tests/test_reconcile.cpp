// Anomaly Coop unit tests: a client catches up by itself (parity audit 2026-10-31, D1-D3, D5, F1-F3, F5).
// The host sends a digest of its roster of entities one bucket at a time; a client that differs twice in a row asks for
// the rows of that bucket and asks for a repair of each entity that differs. Every repair is a command of the host (an
// existing, idempotent world message to that client): the client never decides what the world is.
#include "test_util.h"

#include "coop_item_tags.h"
#include "coop_limits.h"
#include "coop_protocol.h"
#include "coop_reconcile.h"
#include "coop_rules.h"
#include "coop_scope.h"
#include "coop_world_gate.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

using namespace coop;
using namespace coop::reconcile;

namespace
{
// anomaly-coop/<rel>, the project root above this source file (tests\ -> ..), without '\r' (a checkout may have CRLF)
std::string project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

std::string game_source(const char* name) { return project_file(std::string("engine/src/xrGame/coop/") + name); }

// The text from `from` to the first `to` after it; "" if `from` is missing.
std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

constexpr size_t npos = std::string::npos;

Row row(uint16_t id, uint16_t parent = xfer::kNoParent, bool online = false, bool alive = true, uint16_t kind = 7,
    uint32_t state = 0)
{
	Row r;
	r.id = id;
	r.parent = parent;
	r.online = online;
	r.alive = alive;
	r.kind = kind;
	r.state = state;
	return r;
}

bool same_hash(const std::vector<Row>& a, const std::vector<Row>& b)
{
	return hash_bucket(1, a) == hash_bucket(1, b);
}

uint8_t what_of(const std::vector<Action>& actions, uint16_t id)
{
	for (const Action& a : actions)
		if (a.id == id)
			return a.what;
	return 0;
}

struct ItemView
{
	bool has_cond = false;
	uint16_t cond = 0;
	bool has_box = false;
	uint16_t box = 0;
	bool has_addons = false;
	uint8_t addons = 0;
	bool has_main = false;
	uint16_t main_count = 0;
	uint8_t main_type = 0;
	bool has_uses = false;
	uint8_t uses = 0;
};
} // namespace

TEST(reconcile_a_full_round_of_buckets_takes_ten_seconds)
{
	static_assert(xfer::kBuckets == 32u, "the same 32 buckets as a level hash");
	static_assert(kStepMs * xfer::kBuckets <= kCycleMs, "a round fits its time");
	static_assert(kStepMs >= 250u, "a bucket at a time: the walk of a world never lands in one frame");
}

TEST(reconcile_hash_sees_every_field_of_a_row)
{
	const std::vector<Row> base = {row(32), row(64, 32, false, true, 9, 5), row(96, xfer::kNoParent, true)};
	CHECK(same_hash(base, base));
	std::vector<Row> other = base;
	other[1].parent = 96;
	CHECK(!same_hash(base, other));
	other = base;
	other[2].online = false;
	CHECK(!same_hash(base, other));
	other = base;
	other[1].alive = false;
	CHECK(!same_hash(base, other));
	other = base;
	other[0].kind = 8;
	CHECK(!same_hash(base, other));
	other = base;
	other[1].state = 6;
	CHECK(!same_hash(base, other));
	other = base;
	other.pop_back();
	CHECK(!same_hash(base, other));
}

TEST(reconcile_hash_does_not_depend_on_the_order)
{
	const std::vector<Row> a = {row(32), row(64), row(96)};
	const std::vector<Row> b = {row(96), row(32), row(64)};
	CHECK(same_hash(a, b));
}

TEST(reconcile_hash_keeps_the_bucket_and_the_count)
{
	const BucketHash h = hash_bucket(17, {row(17), row(49)});
	CHECK_EQ(h.bucket, uint8_t(17));
	CHECK_EQ(h.n, uint16_t(2));
}

TEST(reconcile_hash_round_trip)
{
	BucketHash h;
	h.bucket = 31;
	h.n = 1234;
	h.sum = 0xDEADBEEFu;
	Writer w(16);
	write(w, h);
	Reader r(w.ptr(), w.size());
	BucketHash back;
	CHECK(read(r, back));
	CHECK(back == h);
}

TEST(reconcile_hash_refuses_a_bucket_that_does_not_exist)
{
	Writer w(16);
	w.u8(32);
	w.u16(1);
	w.u32(1);
	Reader r(w.ptr(), w.size());
	BucketHash back;
	CHECK(!read(r, back));
}

TEST(reconcile_roster_round_trip)
{
	std::vector<Row> rows = {row(33, 65, true, false, 99, 0xCAFEF00Du), row(65)};
	Writer w(64);
	write_roster(w, 1, rows);
	CHECK_EQ(w.size(), size_t(3) + 2 * kRowBytes);
	Reader r(w.ptr(), w.size());
	uint8_t bucket = 0;
	std::vector<Row> back;
	CHECK(read_roster(r, bucket, back));
	CHECK_EQ(bucket, uint8_t(1));
	CHECK_EQ(back.size(), size_t(2));
	CHECK_EQ(back[0].id, uint16_t(33));
	CHECK_EQ(back[0].parent, uint16_t(65));
	CHECK(back[0].online);
	CHECK(!back[0].alive);
	CHECK_EQ(back[0].kind, uint16_t(99));
	CHECK_EQ(back[0].state, 0xCAFEF00Du);
	CHECK(back[1].alive);
}

TEST(reconcile_roster_refuses_a_truncated_or_impossible_list)
{
	Writer w(64);
	write_roster(w, 1, {row(33), row(65)});
	Reader cut(w.ptr(), w.size() - 1);
	uint8_t bucket = 0;
	std::vector<Row> back;
	CHECK(!read_roster(cut, bucket, back));

	Writer big(8);
	big.u8(1);
	big.u16(uint16_t(kMaxRows + 1));
	Reader r(big.ptr(), big.size());
	CHECK(!read_roster(r, bucket, back));

	Writer bad(8);
	bad.u8(32);
	bad.u16(0);
	Reader rb(bad.ptr(), bad.size());
	CHECK(!read_roster(rb, bucket, back));
}

TEST(reconcile_a_handler_that_misses_an_entity_gets_no_switch)
{
	// client_on_switch asks when the entity is missing: an answer with a switch would ask again for as long as its id
	// is taken here, once per round trip
	CHECK(!(kAskMissing & Switch));
	CHECK(kAskMissing & Spawn);
	CHECK(kAskMissing & Died);
}

TEST(reconcile_diff_equal_rosters_need_nothing)
{
	const std::vector<Row> rows = {row(1), row(33, 1), row(65, xfer::kNoParent, true, false, 3, 4)};
	CHECK(diff(rows, rows).empty());
}

TEST(reconcile_diff_asks_for_what_is_missing_and_for_what_should_be_gone)
{
	const std::vector<Action> a = diff({row(1), row(33)}, {row(33), row(65)});
	CHECK_EQ(a.size(), size_t(2));
	CHECK_EQ(what_of(a, 1), uint8_t(Spawn));
	CHECK_EQ(what_of(a, 65), uint8_t(Gone));
}

TEST(reconcile_diff_a_holder_comes_before_what_it_holds)
{
	const std::vector<Action> a = diff({row(1, 33), row(33)}, {});
	CHECK_EQ(a.size(), size_t(2));
	CHECK_EQ(a[0].id, uint16_t(33)); // free
	CHECK_EQ(a[1].id, uint16_t(1)); // held
}

TEST(reconcile_diff_parent)
{
	CHECK_EQ(what_of(diff({row(1, 33)}, {row(1, 65)}), 1), uint8_t(Parent));
	CHECK_EQ(what_of(diff({row(1)}, {row(1, 65)}), 1), uint8_t(Parent));
}

TEST(reconcile_diff_online_counts_for_free_objects_only)
{
	CHECK_EQ(what_of(diff({row(1, xfer::kNoParent, true)}, {row(1)}), 1), uint8_t(Switch));
	CHECK_EQ(what_of(diff({row(1)}, {row(1, xfer::kNoParent, true)}), 1), uint8_t(Switch));
	// A child goes with its holder; the host's flag of a child is its holder's state there
	CHECK(diff({row(1, 33, true)}, {row(1, 33, false)}).empty());
}

TEST(reconcile_diff_death)
{
	CHECK_EQ(what_of(diff({row(1, xfer::kNoParent, true, false)}, {row(1, xfer::kNoParent, true, true)}), 1),
	    uint8_t(Died));
	// A body here of something that lives on the host: another creature under the same id. Death cannot be undone: replaced
	CHECK_EQ(what_of(diff({row(1, xfer::kNoParent, true, true)}, {row(1, xfer::kNoParent, true, false)}), 1),
	    uint8_t(Replace));
}

TEST(reconcile_diff_another_section_under_the_same_id_is_replaced)
{
	CHECK_EQ(what_of(diff({row(1, xfer::kNoParent, false, true, 5)}, {row(1, xfer::kNoParent, false, true, 6)}), 1),
	    uint8_t(Replace));
}

TEST(reconcile_diff_state)
{
	CHECK_EQ(what_of(diff({row(1, xfer::kNoParent, false, true, 7, 1)}, {row(1, xfer::kNoParent, false, true, 7, 2)}), 1),
	    uint8_t(State));
}

TEST(reconcile_diff_combines_what_differs)
{
	const uint8_t what = what_of(diff({row(1, 33, false, false, 7, 1)}, {row(1, 65, false, true, 7, 2)}), 1);
	CHECK_EQ(what, uint8_t(Parent | Died | State));
}

TEST(reconcile_a_first_difference_may_be_in_flight)
{
	Watch w;
	CHECK(!w.on_hash(3, false, 1000));
	CHECK(w.on_hash(3, false, 11000)); // still there a round later
}

TEST(reconcile_a_match_clears_the_streak)
{
	Watch w;
	CHECK(!w.on_hash(3, false, 1000));
	CHECK(!w.on_hash(3, true, 11000));
	CHECK(!w.on_hash(3, false, 21000));
	CHECK(w.on_hash(3, false, 31000));
}

TEST(reconcile_buckets_are_watched_one_by_one)
{
	Watch w;
	CHECK(!w.on_hash(3, false, 1000));
	CHECK(!w.on_hash(4, false, 1300));
	CHECK(w.on_hash(3, false, 11000));
	CHECK(w.on_hash(4, false, 11300));
}

TEST(reconcile_a_difference_that_stays_is_asked_ever_less_often)
{
	Watch w;
	uint64_t t = 1000;
	w.on_hash(3, false, t);
	t += kCycleMs;
	CHECK(w.on_hash(3, false, t));
	std::vector<uint64_t> asked;
	for (int i = 0; i < 200; ++i)
	{
		t += kCycleMs;
		if (w.on_hash(3, false, t))
			asked.push_back(t);
	}
	CHECK(asked.size() >= 3);
	CHECK(asked.size() <= 10); // 2000 s: 20, 40, 80, 160, 320, 320...
	const uint64_t last_gap = asked[asked.size() - 1] - asked[asked.size() - 2];
	CHECK(last_gap <= kMaxWaitMs + kCycleMs);
	CHECK(last_gap >= kMaxWaitMs);
}

TEST(reconcile_a_repair_is_not_repeated_at_once)
{
	Watch w;
	CHECK(w.allow(33, 1000));
	CHECK(!w.allow(33, 1000 + kRepairWaitMs - 1));
	CHECK(w.allow(33, 1000 + kRepairWaitMs));
	// the wait doubles
	CHECK(!w.allow(33, 1000 + kRepairWaitMs + kRepairWaitMs));
	CHECK(w.allow(33, 1000 + kRepairWaitMs + 2 * kRepairWaitMs));
}

TEST(reconcile_a_match_forgets_the_repairs_of_its_bucket)
{
	Watch w;
	CHECK(w.allow(33, 1000)); // bucket 1
	CHECK(w.allow(34, 1000)); // bucket 2
	w.on_hash(1, true, 2000);
	CHECK(w.allow(33, 2000));
	CHECK(!w.allow(34, 2000));
}

TEST(reconcile_the_list_of_repairs_is_bounded)
{
	Watch w;
	for (uint32_t i = 0; i < kMaxRepairs; ++i)
		CHECK(w.allow(uint16_t(i), 1000));
	CHECK(!w.allow(uint16_t(kMaxRepairs), 1000));
}

TEST(reconcile_a_full_list_of_repairs_makes_room_for_a_new_one)
{
	Watch w;
	for (uint32_t i = 0; i < kMaxRepairs; ++i)
		CHECK(w.allow(uint16_t(i), 1000));
	CHECK(w.allow(uint16_t(kMaxRepairs), 1000 + kRepairWaitMs));
	CHECK_EQ(w.repairing(), size_t(kMaxRepairs));
}

TEST(reconcile_queue_merges_repairs_of_one_entity)
{
	Queue q;
	q.push(33, Parent);
	q.push(65, Spawn);
	q.push(33, State);
	CHECK_EQ(q.size(), size_t(2));
	Action a;
	CHECK(q.pop(a));
	CHECK_EQ(a.id, uint16_t(33));
	CHECK_EQ(a.what, uint8_t(Parent | State));
	CHECK(q.pop(a));
	CHECK_EQ(a.id, uint16_t(65));
	CHECK(!q.pop(a));
}

TEST(reconcile_queue_is_bounded)
{
	Queue q;
	for (uint32_t i = 0; i < kMaxQueued + 10; ++i)
		q.push(uint16_t(i), Spawn);
	CHECK_EQ(q.size(), size_t(kMaxQueued));
	CHECK_EQ(q.refused(), uint64_t(10));
}

TEST(reconcile_retry_of_a_taken_id)
{
	Retry r;
	r.add(40, 1000);
	std::vector<uint16_t> due;
	r.due(1000 + kRetryGapMs - 1, due);
	CHECK(due.empty());
	r.due(1000 + kRetryGapMs, due);
	CHECK_EQ(due.size(), size_t(1));
	due.clear();
	r.due(1000 + kRetryGapMs, due);
	CHECK(due.empty()); // the next one waits its gap
	r.done(40);
	r.due(1000 + 2 * kRetryGapMs, due);
	CHECK(due.empty());
}

TEST(reconcile_retry_ends)
{
	Retry r;
	r.add(40, 1000);
	std::vector<uint16_t> due;
	uint32_t asked = 0;
	for (uint64_t t = 1000; t < 1000 + 3 * kRetryForMs; t += 500)
	{
		due.clear();
		r.due(t, due);
		asked += uint32_t(due.size());
	}
	CHECK_EQ(asked, kRetryForMs / kRetryGapMs);
	CHECK_EQ(r.size(), size_t(0));
}

TEST(reconcile_retry_a_second_skip_does_not_extend_it)
{
	Retry r;
	r.add(40, 1000);
	r.add(40, 1000 + kRetryForMs);
	std::vector<uint16_t> due;
	r.due(1000 + kRetryForMs + 1, due);
	CHECK_EQ(r.size(), size_t(0));
}

TEST(reconcile_kind_of_a_section)
{
	CHECK(kind_of("wpn_ak74") != 0);
	CHECK_EQ(kind_of("wpn_ak74"), kind_of("wpn_ak74"));
	CHECK(kind_of("wpn_ak74") != kind_of("wpn_ak74u"));
	CHECK(kind_of("") != 0); // 0 is a player's character: never compared
}

TEST(reconcile_traits_digest)
{
	CHECK_EQ(traits_digest(1, 2, 3), traits_digest(1, 2, 3));
	CHECK(traits_digest(1, 2, 3) != traits_digest(2, 2, 3));
	CHECK(traits_digest(1, 2, 3) != traits_digest(1, 3, 3));
	CHECK(traits_digest(1, 2, 3) != traits_digest(1, 2, 4));
	CHECK(traits_digest(0, 0, 0) != 0);
}

TEST(reconcile_traits_round_trip)
{
	TraitsMsg m;
	m.object = 4321;
	m.community = 7;
	m.rank = 3500;
	m.reputation = -250;
	Writer w(16);
	write(w, m);
	Reader r(w.ptr(), w.size());
	TraitsMsg back;
	CHECK(read(r, back));
	CHECK_EQ(back.object, uint16_t(4321));
	CHECK_EQ(back.community, 7);
	CHECK_EQ(back.rank, 3500);
	CHECK_EQ(back.reputation, -250);
}

TEST(reconcile_squad_digest_is_a_set)
{
	CHECK_EQ(members_digest({1, 2, 3}), members_digest({3, 1, 2}));
	CHECK(members_digest({1, 2, 3}) != members_digest({1, 2}));
	CHECK(members_digest({}) != 0);
}

TEST(reconcile_squad_round_trip_and_limit)
{
	SquadMsg m;
	m.squad = 900;
	m.members = {901, 902};
	Writer w(16);
	write(w, m);
	Reader r(w.ptr(), w.size());
	SquadMsg back;
	CHECK(read(r, back));
	CHECK_EQ(back.squad, uint16_t(900));
	CHECK_EQ(back.members.size(), size_t(2));
	CHECK_EQ(back.members[1], uint16_t(902));

	Writer big(8);
	big.u16(900);
	big.u16(uint16_t(SquadMsg::kMaxMembers + 1));
	Reader rb(big.ptr(), big.size());
	CHECK(!read(rb, back));
}

TEST(reconcile_item_digest_sees_the_state_of_an_item)
{
	ItemView a;
	a.has_cond = true;
	a.cond = 40000;
	a.has_box = true;
	a.box = 30;
	ItemView b = a;
	CHECK_EQ(itemtags::state_digest(a, false), itemtags::state_digest(b, false));
	b.box = 29;
	CHECK(itemtags::state_digest(a, false) != itemtags::state_digest(b, false));
	b = a;
	b.cond = 20000;
	CHECK(itemtags::state_digest(a, false) != itemtags::state_digest(b, false));
	b = a;
	b.has_main = true;
	b.main_count = 3;
	CHECK(itemtags::state_digest(a, false) != itemtags::state_digest(b, false));
	b = a;
	b.has_addons = true;
	b.addons = 2;
	CHECK(itemtags::state_digest(a, false) != itemtags::state_digest(b, false));
}

TEST(reconcile_item_digest_portions_count_only_where_both_can_see_them)
{
	ItemView a;
	a.has_cond = true;
	a.cond = 40000;
	a.has_uses = true;
	a.uses = 2;
	ItemView b = a;
	b.uses = 3;
	CHECK(itemtags::state_digest(a, true) != itemtags::state_digest(b, true));
	CHECK_EQ(itemtags::state_digest(a, false), itemtags::state_digest(b, false));
	ItemView c = a;
	c.has_uses = false; // an offline copy holds no portions
	CHECK_EQ(itemtags::state_digest(a, false), itemtags::state_digest(c, false));
}

TEST(reconcile_item_digest_ignores_a_drift_below_its_step)
{
	ItemView a;
	a.has_cond = true;
	a.cond = 40000;
	ItemView b = a;
	b.cond = 40001;
	CHECK_EQ(itemtags::state_digest(a, false), itemtags::state_digest(b, false));
}

namespace
{
// Two machines' rosters and the whole exchange between them, without the engine: the host's digests a bucket at a time,
// the client's Watch, the rows, diff, the Queue at a rate, and a repair that sets the client's row to the host's.
struct Exchange
{
	std::map<uint16_t, Row> host, client;
	Watch watch;
	Queue queue;
	uint64_t now = 1000;
	uint32_t rosters = 0, repairs = 0;
	bool frozen_id = false; // an entity whose repair never takes
	uint16_t stuck = 0;

	std::vector<Row> rows_of(const std::map<uint16_t, Row>& world, uint8_t bucket) const
	{
		std::vector<Row> out;
		for (const auto& it : world)
			if (xfer::bucket_of(it.first) == bucket)
				out.push_back(it.second);
		return out;
	}
	void apply(const Action& a)
	{
		++repairs;
		if (frozen_id && a.id == stuck)
			return;
		const auto found = host.find(a.id);
		if (found == host.end())
			client.erase(a.id);
		else
			client[a.id] = found->second;
	}
	void round()
	{
		for (uint32_t b = 0; b < xfer::kBuckets; ++b)
		{
			now += kStepMs;
			const uint8_t bucket = uint8_t(b);
			const bool same = hash_bucket(bucket, rows_of(host, bucket)) == hash_bucket(bucket, rows_of(client, bucket));
			if (watch.on_hash(bucket, same, now))
			{
				++rosters;
				for (const Action& a : diff(rows_of(host, bucket), rows_of(client, bucket)))
					if (watch.allow(a.id, now))
						queue.push(a.id, a.what);
			}
			Action a;
			for (int i = 0; i < 8 && queue.pop(a); ++i)
				apply(a);
		}
	}
	bool equal() const
	{
		for (uint32_t b = 0; b < xfer::kBuckets; ++b)
			if (!(hash_bucket(uint8_t(b), rows_of(host, uint8_t(b))) == hash_bucket(uint8_t(b), rows_of(client, uint8_t(b)))))
				return false;
		return true;
	}
};

Exchange a_world()
{
	Exchange x;
	for (uint16_t id = 100; id < 400; ++id)
		x.host[id] = row(id, id % 3 ? xfer::kNoParent : uint16_t(100), id % 3 && id % 2 == 0, true, uint16_t(id % 5 + 1), id % 7);
	x.client = x.host;
	return x;
}
} // namespace

TEST(reconcile_equal_worlds_cost_digests_only)
{
	Exchange x = a_world();
	x.round();
	x.round();
	CHECK_EQ(x.rosters, 0u);
	CHECK_EQ(x.repairs, 0u);
}

TEST(reconcile_a_client_that_missed_things_heals_by_itself)
{
	Exchange x = a_world();
	x.client.erase(150); // a spawn lost
	x.client[9999] = row(9999); // a destroy lost
	x.client[200].parent = 300; // a move lost
	x.client[202].online = !x.client[202].online; // a switch lost
	x.host[203].alive = false; // a death lost
	x.client[204].state = 77; // an item's state nobody sent
	CHECK(!x.equal());
	x.round();
	CHECK(!x.equal()); // the first round only notes it: it may be in flight
	CHECK_EQ(x.rosters, 0u);
	x.round();
	CHECK(x.equal());
	CHECK(x.rosters <= 6u); // the buckets that differed, no others
	CHECK_EQ(x.repairs, 6u);
	x.round();
	CHECK_EQ(x.repairs, 6u); // healed: quiet again
}

TEST(reconcile_a_change_in_flight_costs_nothing)
{
	Exchange x = a_world();
	x.client[150].parent = 300;
	x.round(); // the difference is seen
	x.client[150] = x.host[150]; // the host's own message arrives
	x.round();
	CHECK_EQ(x.rosters, 0u);
	CHECK_EQ(x.repairs, 0u);
}

TEST(reconcile_what_cannot_heal_stays_cheap)
{
	Exchange x = a_world();
	x.frozen_id = true;
	x.stuck = 150;
	x.client[150].state = 77;
	for (int i = 0; i < 60; ++i) // ten minutes
		x.round();
	CHECK(x.rosters <= 7u); // 20 s, 40, 80, 160, 320
	CHECK(x.repairs <= 7u);
}

TEST(reconcile_new_messages_are_in_every_table)
{
	CHECK_EQ(std::string(msg_name(Msg::EntityHash)), std::string("EntityHash"));
	CHECK_EQ(std::string(msg_name(Msg::EntityRoster)), std::string("EntityRoster"));
	CHECK_EQ(std::string(msg_name(Msg::EntityResync)), std::string("EntityResync"));
	CHECK_EQ(std::string(msg_name(Msg::EntityTraits)), std::string("EntityTraits"));
	CHECK_EQ(std::string(msg_name(Msg::EntitySquad)), std::string("EntitySquad"));
	CHECK(msg_sender(Msg::EntityHash) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::EntityRoster) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::EntityTraits) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::EntitySquad) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::EntityResync) == MsgSender::ClientOnly);
	// a digest comes again in 10 s, the answers of a world that is gone are void
	CHECK(wgate::need_of(Msg::EntityHash) == wgate::Need::Drop);
	CHECK(wgate::need_of(Msg::EntityRoster) == wgate::Need::Drop);
	CHECK(wgate::need_of(Msg::EntityResync) == wgate::Need::Drop);
	CHECK(wgate::need_of(Msg::EntityTraits) == wgate::Need::Drop);
	CHECK(wgate::need_of(Msg::EntitySquad) == wgate::Need::Drop);
	CHECK(rules::live_only(Msg::EntityHash));
	CHECK(rules::live_only(Msg::EntityRoster));
	CHECK(rules::live_only(Msg::EntityTraits));
	CHECK(rules::live_only(Msg::EntitySquad));
	CHECK(limits::client_rule(Msg::EntityResync) != nullptr);
}

TEST(reconcile_a_request_of_a_client_stays_cheap)
{
	const limits::RateRule* rule = limits::client_rule(Msg::EntityResync);
	CHECK(rule != nullptr);
	// the whole world at the worst, a bucket per round each: 32 in a row, then a few a second
	CHECK(rule->burst >= xfer::kBuckets);
	CHECK(rule->refill_ms >= 100u);
}

TEST(reconcile_host_runs_after_the_events_went_out)
{
	const std::string src = game_source("coop_sync.cpp");
	const std::string body = between(src, "void frame()", "void print_status()");
	const size_t events = body.find("events::frame();");
	const size_t reconcile = body.find("entities::reconcile_frame();");
	CHECK(events != npos);
	CHECK(reconcile != npos);
	CHECK(events < reconcile); // a hash counts what the frame's flush has told the clients
}

TEST(reconcile_host_answers_a_repair_with_its_world_messages)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void host_on_entity_request(PeerId from, Reader& r)", "bool interpolate(");
	CHECK(body.find("Msg::EntityDestroy") != npos); // only for an id the host does not have
	CHECK(body.find("Msg::EntitySpawn") != npos);
	CHECK(body.find("write_switch") != npos);
	CHECK(body.find("events::host_send_parent") != npos);
	CHECK(body.find("events::host_send_death") != npos);
	CHECK(body.find("items::host_send_state") != npos);
	CHECK(body.find("Msg::EntityTraits") != npos);
	CHECK(body.find("Msg::EntitySquad") != npos);
}

TEST(reconcile_a_client_never_gives_up_its_own_waiting_create)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void client_on_roster(", "\n}\n");
	CHECK(body.find("requests::client_lease_waiting") != npos);
	CHECK(body.find("events::client_parent_pending") != npos);
}

TEST(reconcile_expired_death_is_counted_and_asked_again_once)
{
	const std::string src = game_source("coop_events.cpp");
	const std::string body = between(src, "void client_step_deaths()", "void client_on_entity_parent");
	CHECK(body.find("deaths_expired") != npos);
	const size_t once = body.find("g_death_asked.insert");
	const size_t ask = body.find("Msg::StateDumpRequest");
	CHECK(once != npos); // the answer brings an EntityDied: asked every time, a creature that cannot be made here never ends
	CHECK(ask != npos);
	CHECK(once < ask);
}

TEST(reconcile_a_member_is_switched_with_its_squad)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void host_on_entity_request(PeerId from, Reader& r)", "bool interpolate(");
	const size_t squad = body.find("m->m_group_id");
	const size_t send = body.find("write_switch(w, who,");
	CHECK(squad != npos); // client_on_switch takes a switch of its own as "it left its squad"
	CHECK(send != npos);
	CHECK(squad < send);
}

TEST(reconcile_an_entity_here_but_off_our_roster_is_not_spawned)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void client_on_roster(", "\n}\n");
	CHECK(body.find("reconcile::State | reconcile::Switch") != npos); // a squad emptied here is redundant: no row of ours
}

TEST(reconcile_a_squad_is_judged_before_its_list_changes)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void client_on_squad(", "\n}\n");
	const size_t bound = body.find("const bool bound");
	const size_t leaving = body.find("unregister_member");
	CHECK(bound != npos);
	CHECK(leaving != npos);
	CHECK(bound < leaving);
	CHECK(body.find("!g->squad_members().empty()") != npos);
}

TEST(reconcile_the_engine_queue_is_as_patient_as_the_inbox)
{
	const std::string src = game_source("coop_script.cpp");
	const std::string engine = between(src, "void deliver_engine()", "bool ok = false;");
	CHECK(engine.find("limits::event_stale") != npos);
	CHECK(engine.find("g_lost_events") != npos);
}

TEST(reconcile_a_window_follows_its_own_container_only)
{
	const std::string src = game_source("coop_trade.cpp");
	const std::string body = between(src, "void client_on_item_state(u16 holder)", "\n}\n");
	CHECK(body.find("g_view.id == holder") != npos);
}

TEST(reconcile_a_repair_to_free_keeps_the_hosts_position)
{
	const std::string src = game_source("coop_events.cpp");
	const std::string body = between(src, "void host_send_parent(PeerId to, CSE_Abstract* e)", "\n}\n");
	CHECK(body.find("e->ID_Parent == kNoId ? 1 : 0") != npos);
}

TEST(reconcile_a_parent_timeout_asks_for_item_and_holder)
{
	const std::string src = game_source("coop_events.cpp");
	const std::string body = between(src, "void client_step_parents()", "bool step_death");
	CHECK(body.find("t.extended") != npos);
	CHECK(body.find("kExtendMs") != npos);
}

TEST(reconcile_a_skipped_spawn_is_tried_again)
{
	const std::string src = game_source("coop_entities.cpp");
	const std::string body = between(src, "void client_on_spawn(PeerId, Reader& r)", "void client_on_destroy");
	size_t adds = 0;
	for (size_t at = body.find("g_id_retry.add"); at != npos; at = body.find("g_id_retry.add", at + 1))
		++adds;
	CHECK_EQ(adds, size_t(3)); // deferred initial metadata, a local object, or a reserved generator id
	const std::string staged = between(body, "!requests::stage_clone_initial", "g_id_retry.done");
	CHECK(staged.find("g_id_retry.add") != npos);
	CHECK(body.find("g_id_retry.done") != npos);
}

TEST(reconcile_a_body_at_rest_is_not_lost_to_a_failed_capture)
{
	const std::string src = game_source("coop_objects.cpp");
	const std::string body = between(src, "else if (it != g_host_bodies.end() && it->second.moving)", "rests.add(w);");
	const size_t capture = body.find("capture(sh, poses)");
	const size_t still = body.find("moving = false");
	CHECK(capture != npos);
	CHECK(still != npos);
	CHECK(capture < still);
}
