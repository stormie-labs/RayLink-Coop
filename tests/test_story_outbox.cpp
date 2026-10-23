// Anomaly Coop unit tests: the client's outbox of story messages (coop_story.cpp push_out / flush_outbox) as a pure queue,
// limits::Outbox. F2 T3c (T3b review I-3): a community relation is a fact "from -> to is v", so the queue keeps only the
// last value of a pair; the relations have a queue and a cap of their own, so a fight in GAMMA (Fluid Relations makes 8-15
// set_community_relation calls per kill, sometimes dozens) neither holds up the infos, spots and tasks behind the client
// pacer nor fills their room.
#include "test_util.h"
#include "coop_limits.h"

#include <cstdint>
#include <map>
#include <utility>
#include <vector>

using namespace coop;

namespace
{
// What sits in the queue: the message type and, for a relation, the pair and its value.
struct Item
{
	Msg type = Msg::InfoPortion;
	int from = 0, to = 0, value = 0;
	int id = 0; // which info / spot / task
};
using Box = limits::Outbox<Item>;
using Push = Box::Push;

constexpr uint64_t kFrameMs = 33; // as in limits_honest_relation (a frame of the game)

Push relation(Box& box, int from, int to, int value)
{
	Item it;
	it.type = Msg::Relation;
	it.from = from;
	it.to = to;
	it.value = value;
	const limits::CommunityPair pair{from, to};
	return box.push(Msg::Relation, std::move(it), &pair);
}

// A relation that is not a "set the pair" fact (a goodwill change to a player): no pair, never merged.
Push relation_delta(Box& box, int community, int delta)
{
	Item it;
	it.type = Msg::Relation;
	it.from = community;
	it.value = delta;
	return box.push(Msg::Relation, std::move(it));
}

Push story(Box& box, Msg type, int id)
{
	Item it;
	it.type = type;
	it.id = id;
	return box.push(type, std::move(it));
}

struct Sent
{
	Item item;
	uint64_t at;
};

// One frame of flush_outbox on a client: the pacer lets out what the host takes.
size_t frame(Box& box, limits::Pacer& pacer, uint64_t now, std::vector<Sent>& out)
{
	return box.drain([&](Msg type) { return pacer.take(type, now); }, [&](Item& it) { out.push_back({it, now}); });
}

// Everything goes (the host: no pacer).
size_t drain_all(Box& box, std::vector<Sent>& out)
{
	return box.drain([](Msg) { return true; }, [&](Item& it) { out.push_back({it, 0}); });
}

size_t count_of(const std::vector<Sent>& sent, Msg type)
{
	size_t n = 0;
	for (const Sent& s : sent)
		if (s.item.type == type)
			++n;
	return n;
}
} // namespace

TEST(outbox_relation_same_pair_keeps_only_the_last_value)
{
	// Fluid Relations saves a pair three times in a row (game_relations.script:232-236); the host needs the last one.
	Box box;
	CHECK(relation(box, 3, 4, 10) == Push::Queued);
	CHECK(relation(box, 3, 4, 25) == Push::Merged);
	CHECK(relation(box, 3, 4, -20) == Push::Merged);
	CHECK_EQ(box.size(), size_t(1));
	CHECK_EQ(box.relation_size(), size_t(1));
	CHECK_EQ(box.merged(), uint64_t(2));
	CHECK_EQ(box.dropped_relation(), uint64_t(0));

	std::vector<Sent> out;
	CHECK_EQ(drain_all(box, out), size_t(1));
	REQUIRE(out.size() == 1);
	CHECK_EQ(out[0].item.value, -20);
	CHECK(box.empty());
}

TEST(outbox_relation_pairs_are_ordered_and_a_merged_pair_keeps_its_place)
{
	// (1,2) is not (2,1): the game keeps both directions. A merged pair stays where it was queued.
	Box box;
	CHECK(relation(box, 1, 2, 1) == Push::Queued);
	CHECK(relation(box, 2, 1, 2) == Push::Queued);
	CHECK(relation(box, 1, 3, 3) == Push::Queued); // the same "from" as (1,2), another "to"
	CHECK(relation(box, 3, 1, 4) == Push::Queued); // the same "to" as (2,1), another "from"
	CHECK(relation(box, 3, 4, 5) == Push::Queued);
	CHECK(relation(box, 1, 2, 9) == Push::Merged);
	CHECK_EQ(box.size(), size_t(5));

	std::vector<Sent> out;
	drain_all(box, out);
	REQUIRE(out.size() == 5);
	CHECK(out[0].item.from == 1 && out[0].item.to == 2 && out[0].item.value == 9);
	CHECK(out[1].item.from == 2 && out[1].item.to == 1 && out[1].item.value == 2);
	CHECK(out[2].item.from == 1 && out[2].item.to == 3 && out[2].item.value == 3);
	CHECK(out[3].item.from == 3 && out[3].item.to == 1 && out[3].item.value == 4);
	CHECK(out[4].item.from == 3 && out[4].item.to == 4 && out[4].item.value == 5);
}

TEST(outbox_relation_after_a_sent_pair_is_queued_again)
{
	// Only what waits in the queue is merged: a pair already out is a new fact.
	Box box;
	relation(box, 5, 6, 1);
	std::vector<Sent> out;
	drain_all(box, out);
	CHECK(relation(box, 5, 6, 2) == Push::Queued);
	CHECK_EQ(box.size(), size_t(1));
	CHECK_EQ(box.merged(), uint64_t(0));
}

TEST(outbox_relation_without_a_pair_is_never_merged)
{
	// A change of a goodwill by a delta: two of them are not one (the sum is not the last).
	Box box;
	CHECK(relation_delta(box, 7, 5) == Push::Queued);
	CHECK(relation_delta(box, 7, 5) == Push::Queued);
	CHECK_EQ(box.size(), size_t(2));
	CHECK_EQ(box.merged(), uint64_t(0));
}

TEST(outbox_a_pair_given_with_a_story_message_is_ignored)
{
	// The pair is a thing of Relation only: two infos with the same pair arguments stay two.
	Box box;
	const limits::CommunityPair pair{1, 2};
	Item a;
	a.id = 1;
	Item b;
	b.id = 2;
	CHECK(box.push(Msg::InfoPortion, std::move(a), &pair) == Push::Queued);
	CHECK(box.push(Msg::InfoPortion, std::move(b), &pair) == Push::Queued);
	CHECK_EQ(box.story_size(), size_t(2));
	CHECK_EQ(box.merged(), uint64_t(0));
}

TEST(outbox_relation_storm_does_not_hold_up_the_story)
{
	// A fight: 300 pairs queued, the pacer lets 32 out and then one per 100 ms. An info, a spot and a task queued behind
	// them must leave in the first frame, not wait for the relations (before 3c they stood behind the first held one).
	Box box;
	limits::Pacer pacer;
	for (int i = 0; i < 300; ++i)
		CHECK(relation(box, i / 17, i % 17 + 100 * (i / 17), i) == Push::Queued);
	CHECK(story(box, Msg::InfoPortion, 1) == Push::Queued);
	CHECK(story(box, Msg::InfoPortion, 2) == Push::Queued);
	CHECK(story(box, Msg::MapSpot, 3) == Push::Queued);
	CHECK(story(box, Msg::TaskUpdate, 4) == Push::Queued);

	std::vector<Sent> out;
	frame(box, pacer, 0, out);
	CHECK_EQ(count_of(out, Msg::InfoPortion), size_t(2));
	CHECK_EQ(count_of(out, Msg::MapSpot), size_t(1));
	CHECK_EQ(count_of(out, Msg::TaskUpdate), size_t(1));
	CHECK_EQ(count_of(out, Msg::Relation), size_t(limits::client_pace(*limits::client_rule(Msg::Relation)).burst));
	for (const Sent& s : out)
		if (s.item.type != Msg::Relation)
			CHECK_EQ(s.at, uint64_t(0));

	// ... and the relations all arrive in time, each once, in the order they were queued.
	for (uint64_t now = kFrameMs; now < 60000 && !box.empty(); now += kFrameMs)
		frame(box, pacer, now, out);
	CHECK(box.empty());
	CHECK_EQ(count_of(out, Msg::Relation), size_t(300));
	int expected = 0;
	for (const Sent& s : out)
		if (s.item.type == Msg::Relation)
			CHECK_EQ(s.item.value, expected++);
}

TEST(outbox_story_keeps_its_order_and_waits_at_the_first_held)
{
	// Infos, spots and tasks go as before 3c: one queue, in order; what the pacer holds holds the rest of them.
	Box box;
	story(box, Msg::InfoPortion, 1);
	story(box, Msg::TaskUpdate, 2);
	story(box, Msg::InfoPortion, 3);

	std::vector<Sent> out;
	size_t n = box.drain([](Msg type) { return type != Msg::TaskUpdate; }, [&](Item& it) { out.push_back({it, 0}); });
	CHECK_EQ(n, size_t(1));
	REQUIRE(out.size() == 1);
	CHECK_EQ(out[0].item.id, 1);
	CHECK_EQ(box.size(), size_t(2));
	CHECK_EQ(box.held(), uint64_t(1));

	drain_all(box, out);
	REQUIRE(out.size() == 3);
	CHECK_EQ(out[1].item.id, 2);
	CHECK_EQ(out[2].item.id, 3);
	CHECK_EQ(box.held(), uint64_t(1));
}

TEST(outbox_relations_have_a_cap_of_their_own)
{
	// A flood of relations fills their room, not the story's: an info is still taken when the relations are full.
	Box box;
	const size_t over = 100;
	size_t full = 0;
	for (size_t i = 0; i < limits::kMaxStoryOutbox + over; ++i)
		if (relation(box, int(i), int(i) + 1, 1) == Push::Full)
			++full;
	CHECK_EQ(box.relation_size(), limits::kMaxRelationOutbox);
	CHECK_EQ(full, limits::kMaxStoryOutbox + over - limits::kMaxRelationOutbox);
	CHECK_EQ(box.dropped_relation(), uint64_t(full));
	CHECK_EQ(box.dropped_story(), uint64_t(0));
	CHECK(story(box, Msg::InfoPortion, 1) == Push::Queued);
	CHECK(story(box, Msg::TaskUpdate, 2) == Push::Queued);
	CHECK_EQ(box.story_size(), size_t(2));
}

TEST(outbox_story_cap_is_not_the_relations)
{
	// ... and the other way: a full story queue (a broken mod) does not take the room of the relations.
	Box box;
	for (size_t i = 0; i < limits::kMaxStoryOutbox; ++i)
		CHECK(story(box, Msg::InfoPortion, int(i)) == Push::Queued);
	CHECK(story(box, Msg::InfoPortion, -1) == Push::Full);
	CHECK(story(box, Msg::MapSpot, -2) == Push::Full);
	CHECK_EQ(box.dropped_story(), uint64_t(2));
	CHECK(relation(box, 1, 2, 3) == Push::Queued);
	CHECK_EQ(box.dropped_relation(), uint64_t(0));
	CHECK_EQ(box.size(), limits::kMaxStoryOutbox + 1);
}

TEST(outbox_a_full_relation_queue_still_merges_a_known_pair)
{
	// Full means no room for one more pair, not no room for a new value of a pair that waits.
	Box box;
	for (size_t i = 0; i < limits::kMaxRelationOutbox; ++i)
		relation(box, int(i), int(i) + 1, 1);
	CHECK(relation(box, 5000, 5001, 1) == Push::Full);
	CHECK(relation(box, 10, 11, 77) == Push::Merged);
	std::vector<Sent> out;
	drain_all(box, out);
	CHECK_EQ(out.size(), limits::kMaxRelationOutbox);
	CHECK_EQ(out[10].item.value, 77);
}

TEST(outbox_what_a_send_queues_waits_for_the_next_frame)
{
	// flush_outbox sends what was queued when it began; a hook that queues more while sending (a spot, a relation) is for the
	// next frame, not an endless loop of this one.
	Box box;
	story(box, Msg::InfoPortion, 1);
	relation(box, 1, 2, 3);
	std::vector<Sent> out;
	size_t again = 0;
	const auto send = [&](Item& it) {
		out.push_back({it, 0});
		if (again++ < 2)
		{
			story(box, Msg::InfoPortion, 100 + int(again));
			relation(box, 7, 8, int(again));
		}
	};
	CHECK_EQ(box.drain([](Msg) { return true; }, send), size_t(2));
	CHECK_EQ(box.size(), size_t(3)); // two new infos, one pair (7,8): the second value merged into the first
	CHECK_EQ(out.size(), size_t(2));
	CHECK_EQ(box.drain([](Msg) { return true; }, send), size_t(3)); // (7,8) merged
}

TEST(outbox_clear_empties_both_queues_and_keeps_the_counters)
{
	Box box;
	story(box, Msg::MapSpot, 1);
	relation(box, 1, 2, 1);
	relation(box, 1, 2, 2);
	box.clear();
	CHECK(box.empty());
	CHECK_EQ(box.story_size() + box.relation_size(), size_t(0));
	CHECK_EQ(box.merged(), uint64_t(1));
	CHECK(relation(box, 1, 2, 3) == Push::Queued); // no leftover index of the old queue
}

TEST(outbox_the_host_state_after_a_storm_is_what_the_calls_made)
{
	// The point of merging: whatever the client calls (a random fight over 8 communities, 3 saves of every pair like Fluid
	// Relations), the host that applies what leaves ends with the same pair values as the calls made, and the queue
	// never holds more than the pairs there are.
	constexpr int kCommunities = 8;
	std::map<std::pair<int, int>, int> truth, host;
	Box box;
	limits::Pacer pacer;
	std::vector<Sent> out;
	uint64_t seed = 99, now = 0;
	size_t peak = 0, calls = 0;
	const auto next = [&seed] {
		seed = seed * 6364136223846793005ull + 1442695040888963407ull;
		return uint32_t(seed >> 33);
	};
	for (int kill = 0; kill < 400; ++kill)
	{
		const int pairs = 3 + int(next() % 13);
		for (int p = 0; p < pairs; ++p)
		{
			const int a = int(next() % kCommunities), b = int(next() % kCommunities);
			for (int save = 0; save < 3; ++save)
			{
				const int value = int(next() % 2001) - 1000;
				relation(box, a, b, value);
				truth[{a, b}] = value;
				++calls;
				if (box.relation_size() > peak)
					peak = box.relation_size();
			}
		}
		for (int f = 0; f < 6; ++f) // about 200 ms of frames between kills
		{
			now += kFrameMs;
			frame(box, pacer, now, out);
		}
	}
	while (!box.empty() && now < 10 * 60 * 1000)
	{
		now += kFrameMs;
		frame(box, pacer, now, out);
	}
	CHECK(box.empty());
	for (const Sent& s : out)
		host[{s.item.from, s.item.to}] = s.item.value;
	CHECK(host == truth);
	CHECK(peak <= size_t(kCommunities * kCommunities));
	CHECK_EQ(box.dropped_relation(), uint64_t(0));
	CHECK_EQ(count_of(out, Msg::Relation) + size_t(box.merged()), calls); // nothing vanished: sent or merged
}

TEST(outbox_the_drop_line_is_logged_first_and_every_hundredth)
{
	// A full queue drops the same way again and again: one line for the first, then one in a hundred.
	CHECK(!limits::drop_logged(0));
	CHECK(limits::drop_logged(1));
	for (uint64_t n = 2; n < 100; ++n)
		CHECK(!limits::drop_logged(n));
	CHECK(limits::drop_logged(100));
	CHECK(!limits::drop_logged(101));
	CHECK(limits::drop_logged(200));
	CHECK(limits::drop_logged(1000000));
}
