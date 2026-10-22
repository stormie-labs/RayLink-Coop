// Anomaly Coop unit tests: W9 link hold after a load (coop_link_hold.h + Session::hold_connection).
// Live check 2026-10-23 (GAMMA host + client on one PC): the client's keep-alive covered its load steps, but the first
// frame without a load step released the hold while the client was still coming up (precache frames, the first update
// of every script, not live yet). One of those frames stalled past the silence timeout and the host dropped the client.
#include "test_util.h"

#include "coop_link_hold.h"

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
