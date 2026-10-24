// Anomaly Coop unit tests: W9 link hold after a load (coop_link_hold.h + Session::hold_connection).
// Live check 2026-10-23 (GAMMA host + client on one PC): the client's keep-alive covered its load steps, but the first
// frame without a load step released the hold while the client was still coming up (precache frames, the first update
// of every script, not live yet). One of those frames stalled past the silence timeout and the host dropped the client.
#include "test_util.h"

#include "coop_link_hold.h"

#include <atomic>
#include <thread>
#include <vector>

using namespace coop;

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

// One Manager::frame of the client: the hold policy, then the network pump.
void client_frame(Node& cl, const link_hold::FrameState& fs)
{
	cl.s.hold_connection(link_hold::keep_held(fs) ? link_hold::kLoadHoldMs : 0);
	cl.s.update(t::now_ms());
}
} // namespace

TEST(link_hold_lasts_until_the_machine_plays_normally)
{
	link_hold::FrameState fs;
	CHECK(!link_hold::keep_held(fs)); // in the game (or the menu), no load: released
	fs.load_steps_queued = true;
	CHECK(link_hold::keep_held(fs)); // a load step runs between frames
	fs = link_hold::FrameState();
	fs.precache_frames = true;
	CHECK(link_hold::keep_held(fs)); // host or client: the first frames after its load
	fs = link_hold::FrameState();
	fs.joining_world = true;
	CHECK(link_hold::keep_held(fs)); // client: loaded, not live yet
	CHECK(link_hold::kLoadHoldMs >= 60000u); // one arm outlasts a long load stage
}

TEST(first_frames_after_a_load_keep_the_link_until_live)
{
	Node host("Boss", 37210), cl("Alice", 37210);
	host.cfg.peer_timeout_ms = 1500;
	cl.cfg.peer_timeout_ms = 1500;
	join_one(host, cl, 37210);

	// The load: a stage armed the hold, the client's main thread does not pump.
	cl.s.hold_connection(link_hold::kLoadHoldMs);
	t::pump_for({&host.s}, 2000);
	CHECK(host.left.empty());

	// The first frame without a load step: precache frames run, the client is not live yet ...
	link_hold::FrameState coming_up;
	coming_up.precache_frames = true;
	coming_up.joining_world = true;
	client_frame(cl, coming_up);
	// ... and that frame (every script's first update) stalls longer than the silence timeout.
	t::pump_for({&host.s}, 3500);
	CHECK(host.left.empty());
	CHECK_EQ(host.s.peers().size(), size_t(1));

	// Live: the frame releases the hold, frames pump the network, still connected.
	client_frame(cl, link_hold::FrameState());
	t::pump_for({&host.s, &cl.s}, 500);
	CHECK(host.left.empty());
	CHECK(!cl.disconnected);

	// From now on a stall is silence (a hang, a crash): the host drops the client.
	REQUIRE(t::pump_until({&host.s}, 15000, [&] { return !host.left.empty(); }));
	CHECK(host.left[0].second.find("lost") != std::string::npos);
}

// Review of the live fixes: on_crash released the hold, but the next frame of the main thread (a crash on a worker
// thread does not stop it at once) armed it again for kLoadHoldMs while precache frames ran: the crashed player stayed
// "connected" for two minutes. A crash is for good: no frame and no load stage holds the link after it.
TEST(link_hold_never_again_after_a_crash)
{
	link_hold::FrameState fs;
	fs.load_steps_queued = true;
	fs.precache_frames = true;
	fs.joining_world = true;
	CHECK(link_hold::keep_held(fs));
	fs.crashed = true;
	CHECK(!link_hold::keep_held(fs));
	CHECK(!link_hold::may_arm(true)); // a load stage (on_blocking_work) after the crash
	CHECK(link_hold::may_arm(false));
}

TEST(a_crash_while_coming_up_is_silence)
{
	Node host("Boss", 37211), cl("Alice", 37211);
	host.cfg.peer_timeout_ms = 1500;
	cl.cfg.peer_timeout_ms = 1500;
	join_one(host, cl, 37211);

	// The client loads (held), then crashes on a worker thread: on_crash releases the hold ...
	cl.s.hold_connection(link_hold::kLoadHoldMs);
	cl.s.hold_connection(0);
	// ... and its main thread still runs a frame of its precache before the crash dialog stops it.
	link_hold::FrameState fs;
	fs.precache_frames = true;
	fs.joining_world = true;
	fs.crashed = true;
	client_frame(cl, fs);
	// It never pumps again: the host drops it after the silence timeout, not after kLoadHoldMs.
	REQUIRE(t::pump_until({&host.s}, 15000, [&] { return !host.left.empty(); }));
	CHECK(host.left[0].second.find("lost") != std::string::npos);
}

// Review of protocol 8 (Minor 2): Manager::frame and on_blocking_work read the crash flag, then armed the hold. A crash
// on another thread in between (on_crash) armed it again for kLoadHoldMs. The check lives in the hold word itself now:
// one atomic word, sealed for good by the crash.
TEST(link_hold_word_seal_is_for_good)
{
	link_hold::HoldWord w;
	CHECK(!w.held(1000) && !w.sealed());
	CHECK(w.arm(5000));
	CHECK(w.held(1000) && w.held(4999) && !w.held(5000));
	CHECK(w.arm(0)); // released
	CHECK(!w.held(1000));
	CHECK(w.arm(9000));
	w.seal(); // a crash: the hold goes at once ...
	CHECK(w.sealed() && !w.held(1000));
	CHECK(!w.arm(120000)); // ... and for good: no later arm takes
	CHECK(!w.held(1000) && !w.held(UINT64_MAX - 1));
	w.release(); // a session ending (Transport::destroy) does not lift it
	CHECK(w.sealed());
	CHECK(!w.arm(UINT64_MAX)); // not even with the seal's own value
	CHECK(w.sealed());

	link_hold::HoldWord v;
	CHECK(v.arm(UINT64_MAX)); // a deadline at the end of the clock is a deadline, not a seal
	CHECK(!v.sealed() && v.held(1000));
}

TEST(link_hold_seal_wins_every_race)
{
	// Threads arm the hold as fast as they can (frames, load stages); the crash seals it in the middle. An arm that
	// starts after the seal never takes, and the word ends sealed whatever the interleaving.
	for (int round = 0; round < 20; ++round)
	{
		link_hold::HoldWord w;
		std::atomic<bool> go{false}, sealed{false};
		std::atomic<int> late_arms{0};
		std::vector<std::thread> armers;
		for (int i = 0; i < 4; ++i)
			armers.emplace_back([&] {
				while (!go.load())
					std::this_thread::yield();
				for (int n = 0; n < 20000; ++n)
				{
					const bool after_seal = sealed.load();
					if (w.arm(1000000 + uint64_t(n)) && after_seal)
						late_arms.fetch_add(1);
				}
			});
		go.store(true);
		for (int n = 0; n < 200 * (round + 1); ++n)
			std::this_thread::yield();
		w.seal();
		sealed.store(true);
		for (std::thread& t : armers)
			t.join();
		CHECK_EQ(late_arms.load(), 0);
		CHECK(w.sealed());
		CHECK(!w.held(0));
	}
}

TEST(a_crash_between_the_check_and_the_hold_is_silence)
{
	Node host("Boss", 37212), cl("Alice", 37212);
	host.cfg.peer_timeout_ms = 1500;
	cl.cfg.peer_timeout_ms = 1500;
	join_one(host, cl, 37212);

	// A frame (or a load stage) read "not crashed" ...
	link_hold::FrameState fs;
	fs.precache_frames = true;
	fs.joining_world = true;
	CHECK(link_hold::keep_held(fs));
	// ... a worker thread crashes right then (on_crash) ...
	cl.s.seal_connection_hold();
	// The helper pumps between the owner's frames (2026-10-24); from the crash on it stops (one pass may be in flight).
	const uint64_t at_crash = cl.s.keepalive_services();
	// ... and the frame arms the hold it decided on. It does not take: nothing holds the link after a crash.
	cl.s.hold_connection(link_hold::kLoadHoldMs);
	cl.s.hold_connection(link_hold::kLoadHoldMs);
	// The crashed client never pumps again: dropped after the silence timeout, not after kLoadHoldMs.
	REQUIRE(t::pump_until({&host.s}, 15000, [&] { return !host.left.empty(); }));
	CHECK(host.left[0].second.find("lost") != std::string::npos);
	CHECK(cl.s.keepalive_services() <= at_crash + 1); // the helper never answered for it after the crash
}

// Review of protocol 8 (Minor 3): joins that come while the host's own level precaches wait for it, and the engine's
// precache is no end signal: it counts down only in the focused window (xrEngine/device.cpp End) and starts again on a
// device reset. An unfocused host never served them and the client dropped after 5 min. The wait is limited.
TEST(precache_wait_for_joins_is_limited)
{
	link_hold::PrecacheWait p;
	static_assert(link_hold::PrecacheWait::kLimitMs == 20000, "20 s after the level is up");
	CHECK(!p.waiting(false, 1000)); // the host plays: joins go at once
	CHECK(!p.take_gave_up());

	const uint64_t t0 = 50000; // the first frame of the precache the join code sees (load steps run without frames)
	CHECK(p.waiting(true, t0));
	CHECK(p.waiting(true, t0 + 1000));
	CHECK(p.waiting(true, t0 + link_hold::PrecacheWait::kLimitMs - 1));
	CHECK(!p.take_gave_up());
	// the window has no focus: precache never ends. The joins go after the limit and stay going.
	CHECK(!p.waiting(true, t0 + link_hold::PrecacheWait::kLimitMs));
	CHECK(p.take_gave_up()); // the log says so once
	CHECK(!p.take_gave_up());
	CHECK(!p.waiting(true, t0 + 10 * link_hold::PrecacheWait::kLimitMs));
	CHECK(!p.take_gave_up());

	// it ends (focus came back); a later precache (a device reset, the next load) is a new stretch with its own limit
	CHECK(!p.waiting(false, t0 + 11 * link_hold::PrecacheWait::kLimitMs));
	const uint64_t t1 = t0 + 12 * link_hold::PrecacheWait::kLimitMs;
	CHECK(p.waiting(true, t1));
	CHECK(p.waiting(true, t1 + link_hold::PrecacheWait::kLimitMs - 1));
	CHECK(!p.waiting(true, t1 + link_hold::PrecacheWait::kLimitMs));
	CHECK(p.take_gave_up());

	// a precache that ends in time never gives up
	link_hold::PrecacheWait q;
	CHECK(q.waiting(true, 100));
	CHECK(!q.waiting(false, 5000));
	CHECK(!q.take_gave_up());
	// a clock that went back (another tick source) waits, it does not end the wait at once
	CHECK(q.waiting(true, 90000));
	CHECK(q.waiting(true, 80000));
}
