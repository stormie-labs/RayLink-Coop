// Anomaly Coop unit tests: a queue drained by a budget per frame (coop_frame_queue.h), the sound module's Lua callbacks
// (coop_avatar_step, coop_npc_sound, coop_npc_sound_stop). What a frame's budget leaves waits for the next frame: a lost
// "stop" leaves its sound playing. Only overflow loses events, and the status line counts them.
#include "test_util.h"

#include "coop_frame_queue.h"

namespace
{
struct Ev
{
	int id = 0;
	bool stop = false;
};

using Queue = coop::FrameQueue<Ev>;

void push(Queue& q, int id, bool stop = false) { q.push(Ev{id, stop}); }

std::vector<int> run(Queue& q)
{
	std::vector<int> fired;
	q.run([&](const Ev& e) { fired.push_back(e.id); });
	return fired;
}

std::vector<int> ids(int from, int to)
{
	std::vector<int> v;
	for (int i = from; i <= to; ++i)
		v.push_back(i);
	return v;
}
}

TEST(frame_queue_fires_the_budget_and_keeps_the_rest_for_the_next_frame)
{
	Queue q(64, 32);
	for (int i = 0; i < 40; ++i)
		push(q, i);
	CHECK(run(q) == ids(0, 31));
	CHECK_EQ(q.size(), size_t(8));
	CHECK(run(q) == ids(32, 39));
	CHECK(q.empty());
	CHECK_EQ(q.dropped(), uint64_t(0));
}

TEST(frame_queue_delivers_a_stop_past_the_budget)
{
	Queue q(64, 32);
	for (int i = 0; i < 40; ++i)
		push(q, i);
	push(q, 777, true); // a squad dies at once: forty sounds, then the stop of one of them
	std::vector<int> fired = run(q);
	CHECK_EQ(fired.size(), size_t(32));
	fired = run(q);
	CHECK(!fired.empty() && fired.back() == 777);
}

TEST(frame_queue_keeps_the_deferred_ahead_of_new_events)
{
	Queue q(64, 32);
	for (int i = 0; i < 34; ++i)
		push(q, i);
	CHECK(run(q) == ids(0, 31));
	push(q, 100);
	push(q, 101);
	CHECK((run(q) == std::vector<int>{32, 33, 100, 101}));
}

TEST(frame_queue_holds_what_a_handler_queues_for_the_next_frame)
{
	Queue q(64, 32);
	for (int i = 0; i < 34; ++i)
		push(q, i);
	std::vector<int> fired;
	q.run([&](const Ev& e) {
		fired.push_back(e.id);
		if (e.id == 0)
			push(q, 1000);
	});
	CHECK(fired == ids(0, 31));
	CHECK((run(q) == std::vector<int>{32, 33, 1000}));
	CHECK_EQ(q.dropped(), uint64_t(0));
}

TEST(frame_queue_counts_what_overflow_drops_oldest_first)
{
	Queue q(64, 32);
	for (int i = 0; i < 70; ++i)
		push(q, i);
	CHECK_EQ(q.dropped(), uint64_t(6));
	CHECK(run(q) == ids(6, 37));
	CHECK(run(q) == ids(38, 69));
}

TEST(frame_queue_trims_a_frame_that_ends_past_the_cap)
{
	Queue q(4, 2);
	for (int i = 0; i < 4; ++i)
		push(q, i);
	q.run([&](const Ev& e) {
		if (e.id == 0)
			for (int k = 100; k < 104; ++k)
				push(q, k); // the deferred 2 and 3 plus four new: two over the cap, the oldest go
	});
	CHECK_EQ(q.size(), size_t(4));
	CHECK_EQ(q.dropped(), uint64_t(2));
	CHECK((run(q) == std::vector<int>{100, 101}));
}

TEST(frame_queue_clear_empties_and_keeps_the_count)
{
	Queue q(2, 2);
	for (int i = 0; i < 3; ++i)
		push(q, i);
	CHECK_EQ(q.dropped(), uint64_t(1));
	q.clear();
	CHECK(q.empty());
	CHECK(run(q).empty());
	CHECK_EQ(q.dropped(), uint64_t(1));
}
