// Anomaly Coop unit tests: the revive hold made visible (coop_revive_hold.h; HUD v2 part 2, docs/HUD_V2.md "Поднятие
// союзника"): the PlayerRevive ops and their layouts, the host's check of a Begin, the hold the wounded owner shows, the
// reviver's announcing machine, and that all of it fits the PlayerRevive row of the client rate table.
#include "test_util.h"

#include "coop_limits.h"
#include "coop_revive_hold.h"

#include <vector>

using namespace coop;
using namespace coop::revive;

namespace
{
Reader reader_of(const Writer& w) { return Reader(w.ptr(), w.size()); }
} // namespace

// ---------------------------------------------------------------- wire contract

TEST(revive_op_numbers_are_the_wire)
{
	// The first six are on the wire since F3 Task 8 (survival); Begin..Done are new in protocol 8 (not released).
	CHECK_EQ(int(OpRequest), 0);
	CHECK_EQ(int(OpRevive), 1);
	CHECK_EQ(int(OpRespawn), 2);
	CHECK_EQ(int(OpSpectate), 3);
	CHECK_EQ(int(OpRefused), 4);
	CHECK_EQ(int(OpEvacuate), 5);
	CHECK_EQ(int(OpBegin), 6);
	CHECK_EQ(int(OpCancel), 7);
	CHECK_EQ(int(OpReviving), 8);
	CHECK_EQ(int(OpStopped), 9);
	CHECK_EQ(int(OpDone), 10);
	CHECK_EQ(int(RefNone), 0);
	CHECK_EQ(int(RefNotWounded), 1);
	CHECK_EQ(int(RefTooFar), 2);
	CHECK_EQ(int(RefNoMedkit), 3);
	CHECK_EQ(int(RefBusy), 4);
	CHECK_EQ(int(RefYouAreDown), 5);
	CHECK_EQ(int(RefSelf), 6);
}

TEST(revive_client_ops_are_the_three_a_client_sends)
{
	for (int op = 0; op < 16; ++op)
		CHECK_EQ(is_client_op(uint8_t(op)), op == OpRequest || op == OpBegin || op == OpCancel);
}

TEST(revive_begin_round_trip)
{
	BeginMsg b;
	b.target = 7;
	b.seq = 3;
	b.item = 4242;
	b.held_ms = 260;
	Writer w;
	b.write(w);
	CHECK_EQ(w.size(), size_t(9)); // op, 4 x u16
	Reader r = reader_of(w);
	CHECK_EQ(int(r.u8()), int(OpBegin));
	BeginMsg out;
	REQUIRE(out.read(r));
	CHECK_EQ(int(out.target), 7);
	CHECK_EQ(int(out.seq), 3);
	CHECK_EQ(int(out.item), 4242);
	CHECK_EQ(int(out.held_ms), 260);
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(revive_cancel_round_trip)
{
	CancelMsg c;
	c.target = 9;
	c.seq = 65000;
	Writer w;
	c.write(w);
	CHECK_EQ(w.size(), size_t(5));
	Reader r = reader_of(w);
	CHECK_EQ(int(r.u8()), int(OpCancel));
	CancelMsg out;
	REQUIRE(out.read(r));
	CHECK_EQ(int(out.target), 9);
	CHECK_EQ(int(out.seq), 65000);
}

TEST(revive_reviving_round_trip)
{
	RevivingMsg m;
	m.target = 12;
	m.seq = 2;
	m.reviver = 30;
	m.reviver_peer = 3;
	m.total_ms = 3000;
	m.held_ms = 250;
	Writer w;
	m.write(w);
	CHECK_EQ(w.size(), size_t(19));
	Reader r = reader_of(w);
	CHECK_EQ(int(r.u8()), int(OpReviving));
	RevivingMsg out;
	REQUIRE(out.read(r));
	CHECK_EQ(int(out.target), 12);
	CHECK_EQ(int(out.seq), 2);
	CHECK_EQ(int(out.reviver), 30);
	CHECK_EQ(out.reviver_peer, uint32_t(3));
	CHECK_EQ(out.total_ms, uint32_t(3000));
	CHECK_EQ(out.held_ms, uint32_t(250));
}

TEST(revive_stopped_and_done_round_trip)
{
	StoppedMsg s;
	s.target = 5;
	s.seq = 8;
	s.reviver = 6;
	Writer ws;
	s.write(ws);
	CHECK_EQ(ws.size(), size_t(7));
	Reader rs = reader_of(ws);
	CHECK_EQ(int(rs.u8()), int(OpStopped));
	StoppedMsg so;
	REQUIRE(so.read(rs));
	CHECK_EQ(int(so.target), 5);
	CHECK_EQ(int(so.seq), 8);
	CHECK_EQ(int(so.reviver), 6);

	DoneMsg d;
	d.target = 5;
	d.seq = 8;
	Writer wd;
	d.write(wd);
	CHECK_EQ(wd.size(), size_t(5));
	Reader rd = reader_of(wd);
	CHECK_EQ(int(rd.u8()), int(OpDone));
	DoneMsg dout;
	REQUIRE(dout.read(rd));
	CHECK_EQ(int(dout.target), 5);
	CHECK_EQ(int(dout.seq), 8);
}

TEST(revive_truncated_messages_do_not_read)
{
	// a message cut short at any byte is refused, never half-read
	BeginMsg b;
	b.target = 1;
	b.seq = 1;
	b.item = 1;
	b.held_ms = 1;
	Writer w;
	b.write(w);
	for (size_t cut = 1; cut < w.size(); ++cut)
	{
		Reader r(w.ptr(), cut);
		r.u8();
		BeginMsg out;
		CHECK(!out.read(r));
	}
	RevivingMsg m;
	Writer wm;
	m.write(wm);
	for (size_t cut = 1; cut < wm.size(); ++cut)
	{
		Reader r(wm.ptr(), cut);
		r.u8();
		RevivingMsg out;
		CHECK(!out.read(r));
	}
	StoppedMsg s;
	Writer ws;
	s.write(ws);
	for (size_t cut = 1; cut < ws.size(); ++cut)
	{
		Reader r(ws.ptr(), cut);
		r.u8();
		StoppedMsg out;
		CHECK(!out.read(r));
	}
}

// ---------------------------------------------------------------- the host's verdict

TEST(revive_verdict_all_good_is_no_refusal)
{
	CHECK_EQ(int(verdict(Facts())), int(RefNone));
}

TEST(revive_verdict_keeps_the_order_of_survival)
{
	// F3 Task 8's chain: self, not wounded, the reviver is down, busy, too far, no medkit. The first one that fails wins.
	Facts f;
	f.self = f.target_wounded = f.reviver_down = f.busy = f.in_range = f.has_item = true;
	f.target_wounded = false;
	f.in_range = false;
	f.has_item = false;
	CHECK_EQ(int(verdict(f)), int(RefSelf));
	f.self = false;
	CHECK_EQ(int(verdict(f)), int(RefNotWounded));
	f.target_wounded = true;
	CHECK_EQ(int(verdict(f)), int(RefYouAreDown));
	f.reviver_down = false;
	CHECK_EQ(int(verdict(f)), int(RefBusy));
	f.busy = false;
	CHECK_EQ(int(verdict(f)), int(RefTooFar));
	f.in_range = true;
	CHECK_EQ(int(verdict(f)), int(RefNoMedkit));
	f.has_item = true;
	CHECK_EQ(int(verdict(f)), int(RefNone));
}

// ---------------------------------------------------------------- fractions

TEST(revive_fraction_is_clamped)
{
	CHECK_EQ(fraction(0, 3000), 0.f);
	CHECK_EQ(fraction(1500, 3000), 0.5f);
	CHECK_EQ(fraction(3000, 3000), 1.f);
	CHECK_EQ(fraction(99999, 3000), 1.f);
	CHECK_EQ(fraction(5, 0), 1.f); // no length: done
}

// ---------------------------------------------------------------- the host's hold of one wounded character

TEST(host_hold_begin_opens_it)
{
	HostHold h;
	CHECK(!h.busy_for(1000, 4, 10));
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(h.open_at(1000, 4));
	CHECK(!h.busy_for(1000, 4, 10)); // his own hold does not block him
	CHECK(h.busy_for(1000, 4, 11)); // another reviver is turned away
	CHECK(h.begin(1000, 4, 11, 250) == HostHold::Begin::Busy);
}

TEST(host_hold_same_reviver_may_restart)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(h.begin(1500, 4, 10, 400) == HostHold::Begin::Started); // a lost Cancel, a new hold of his own
	CHECK(h.busy_for(1500, 4, 11));
}

TEST(host_hold_lapses_after_its_end_and_the_grace)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started); // 2750 ms of the hold left
	const uint64_t end = 1000 + 2750 + kGraceMs;
	CHECK(h.busy_for(end - 1, 4, 11));
	CHECK(!h.busy_for(end, 4, 11)); // the reviver went away without a Cancel: the lock ends by itself
	CHECK(!h.open_at(end, 4));
	CHECK(h.begin(end, 4, 11, 250) == HostHold::Begin::Started);
}

TEST(host_hold_a_new_fall_is_not_busy)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(!h.busy_for(1100, 5, 11)); // the hold of fall 4 means nothing for fall 5
	CHECK(h.begin(1100, 5, 11, 250) == HostHold::Begin::Started);
	CHECK(!h.open_at(1100, 4));
	CHECK(h.open_at(1100, 5));
}

TEST(host_hold_stop_only_by_its_reviver_and_fall)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(!h.stop(4, 11)); // somebody else's Cancel
	CHECK(!h.stop(5, 10)); // another fall
	CHECK(h.open_at(1000, 4));
	CHECK(h.stop(4, 10));
	CHECK(!h.open_at(1000, 4));
	CHECK(!h.stop(4, 10)); // once
	CHECK(!h.busy_for(1000, 4, 11)); // free again
}

TEST(host_hold_close_frees_it)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	h.close();
	CHECK(!h.open_at(1000, 4));
	CHECK(!h.busy_for(1000, 4, 11));
}

TEST(host_hold_held_past_the_length_is_still_one_grace_long)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 9000) == HostHold::Begin::Started); // held_ms beyond the length: the hold is over already
	CHECK(h.busy_for(1000 + kGraceMs - 1, 4, 11));
	CHECK(!h.busy_for(1000 + kGraceMs, 4, 11));
}

// ---------------------------------------------------------------- the hold as the wounded sees it

TEST(lift_view_starts_empty)
{
	LiftView v;
	CHECK(!v.active(1000, 3));
	CHECK_EQ(v.fraction(1000), 0.f);
	CHECK_EQ(v.ms_left(1000), uint32_t(0));
}

TEST(lift_view_fills_with_time_from_what_was_held)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 600)); // 20 % of the hold was done when the host told us
	CHECK(v.active(10000, 3));
	CHECK_EQ(v.reviver(), uint16_t(30));
	CHECK_EQ(v.peer(), uint32_t(2));
	CHECK_EQ(v.fraction(10000), 0.2f);
	CHECK_EQ(v.ms_left(10000), uint32_t(2400));
	CHECK_EQ(v.fraction(11200), 0.6f);
	CHECK_EQ(v.fraction(12400), 1.f);
	CHECK_EQ(v.ms_left(12400), uint32_t(0));
	CHECK_EQ(v.fraction(20000), 1.f);
}

TEST(lift_view_waits_for_the_revive_then_gives_up)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 0));
	CHECK(v.active(13000, 3)); // full ring, the Revive is on its way
	CHECK(v.active(13000 + kGraceMs - 1, 3));
	CHECK(!v.active(13000 + kGraceMs, 3)); // nothing came: the ring goes, the wounded is still down
}

TEST(lift_view_belongs_to_one_fall)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 0));
	CHECK(!v.active(10100, 4)); // another fall of mine: not this ring
	CHECK(v.active(10100, 3));
}

TEST(lift_view_stopped_by_its_reviver)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 0));
	v.on_stopped(3, 31); // not him
	CHECK(v.active(10100, 3));
	v.on_stopped(4, 30); // not this fall
	CHECK(v.active(10100, 3));
	v.on_stopped(3, 30);
	CHECK(!v.active(10100, 3));
	CHECK_EQ(v.fraction(10100), 0.f);
}

TEST(lift_view_a_second_reviver_replaces_the_first)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 0));
	CHECK(v.on_reviving(11000, 3, 31, 4, 3000, 0)); // the first one's lock ran out on the host
	CHECK_EQ(v.reviver(), uint16_t(31));
	CHECK_EQ(v.peer(), uint32_t(4));
	CHECK_EQ(v.fraction(11000), 0.f);
}

TEST(lift_view_refuses_nonsense_lengths)
{
	LiftView v;
	CHECK(!v.on_reviving(10000, 3, 30, 2, 0, 0));
	CHECK(!v.on_reviving(10000, 3, 30, 2, kMaxHoldMs + 1, 0));
	CHECK(!v.active(10000, 3));
	CHECK(v.on_reviving(10000, 3, 30, 2, kMaxHoldMs, 0));
}

TEST(lift_view_clear)
{
	LiftView v;
	CHECK(v.on_reviving(10000, 3, 30, 2, 3000, 0));
	v.clear();
	CHECK(!v.active(10000, 3));
}

// ---------------------------------------------------------------- the reviver's announcing machine

TEST(announcer_a_tap_sends_nothing)
{
	Announcer a;
	a.start();
	CHECK(a.step(1000, 0) == Announcer::Act::None);
	CHECK(a.step(1100, kAnnounceAfterMs - 1) == Announcer::Act::None);
	CHECK(a.stop() == Announcer::Act::None); // never announced: no Cancel either
}

TEST(announcer_begins_once_after_the_threshold)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, kAnnounceAfterMs) == Announcer::Act::Begin);
	CHECK(a.announced());
	CHECK(a.step(1300, 300) == Announcer::Act::None);
	CHECK(a.step(2000, 1000) == Announcer::Act::None);
}

TEST(announcer_cancel_follows_an_announced_hold_only)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, 250) == Announcer::Act::Begin);
	CHECK(a.stop() == Announcer::Act::Cancel);
	CHECK(!a.announced());
	CHECK(a.stop() == Announcer::Act::None); // once
}

TEST(announcer_a_finished_hold_sends_no_cancel)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, 250) == Announcer::Act::Begin);
	a.done(); // the Request goes instead: the host ends the hold with it
	CHECK(a.stop() == Announcer::Act::None);
}

TEST(announcer_waits_out_the_gap_between_begins)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, 250) == Announcer::Act::Begin);
	CHECK(a.stop() == Announcer::Act::Cancel);
	a.start(); // pressed again at once
	CHECK(a.step(1700, 300) == Announcer::Act::None); // inside the gap: not announced, no message
	CHECK(a.step(1250 + kAnnounceGapMs - 1, 1000) == Announcer::Act::None);
	CHECK(a.step(1250 + kAnnounceGapMs, 1100) == Announcer::Act::Begin); // announced late, in the middle of the hold
	CHECK(a.stop() == Announcer::Act::Cancel);
}

TEST(announcer_a_hold_inside_the_gap_that_ends_sends_nothing)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, 250) == Announcer::Act::Begin);
	CHECK(a.stop() == Announcer::Act::Cancel);
	a.start();
	CHECK(a.step(1600, 400) == Announcer::Act::None);
	CHECK(a.stop() == Announcer::Act::None);
}

TEST(announcer_reset_forgets_the_gap)
{
	Announcer a;
	a.start();
	CHECK(a.step(1250, 250) == Announcer::Act::Begin);
	a.reset();
	a.start();
	CHECK(a.step(1300, 250) == Announcer::Act::Begin);
}

// ---------------------------------------------------------------- the PlayerRevive row

namespace
{
// Session::limit_rate: a token bucket per client and type, `burst` in a row, then one more every `refill_ms`.
struct Bucket
{
	double tokens;
	uint64_t at = 0;
	uint32_t burst, refill_ms;
	uint64_t dropped = 0, taken = 0;

	explicit Bucket(const limits::RateRule& r) : tokens(double(r.burst)), burst(r.burst), refill_ms(r.refill_ms) {}

	void take(uint64_t now)
	{
		if (now > at)
		{
			tokens += double(now - at) / double(refill_ms);
			if (tokens > double(burst))
				tokens = double(burst);
			at = now;
		}
		if (tokens < 1.)
		{
			++dropped;
			return;
		}
		tokens -= 1.;
		++taken;
	}
};

// One honest or button-mashing reviver for `seconds`: holds USE `hold_ms`, lets go `release_ms`, over and over. The hold goes
// on until the ring is full (kHoldMs), then the Request goes. The messages the machine sends go through the host's bucket.
Bucket mash(uint32_t hold_ms, uint32_t release_ms, uint32_t seconds)
{
	const limits::RateRule* rule = limits::client_rule(Msg::PlayerRevive);
	REQUIRE(rule != nullptr);
	Bucket bucket(*rule);
	Announcer a;
	bool holding = false;
	uint64_t press_at = 0, release_at = 0;
	for (uint64_t t = 0; t < uint64_t(seconds) * 1000; t += 10)
	{
		if (!holding && t >= release_at)
		{
			holding = true;
			press_at = t;
			a.start();
		}
		if (holding)
		{
			const uint32_t held = uint32_t(t - press_at);
			if (a.step(t, held) == Announcer::Act::Begin)
				bucket.take(t);
			if (held >= kHoldMs) // the hold completed: the Request replaces the Cancel
			{
				a.done();
				bucket.take(t);
				holding = false;
				release_at = t + release_ms;
			}
			else if (held >= hold_ms) // let go early
			{
				if (a.stop() == Announcer::Act::Cancel)
					bucket.take(t);
				holding = false;
				release_at = t + release_ms;
			}
		}
	}
	return bucket;
}
} // namespace

TEST(revive_row_is_still_the_one_of_task_3c)
{
	// Begin and Cancel ride the row F2 T3c gave the revive request: it was not raised for them (see coop_limits.h).
	const limits::RateRule* rule = limits::client_rule(Msg::PlayerRevive);
	REQUIRE(rule != nullptr);
	CHECK_EQ(rule->burst, uint32_t(8));
	CHECK_EQ(rule->refill_ms, uint32_t(750));
}

TEST(revive_row_takes_a_player_who_mashes_the_button)
{
	// the worst a hand can do: hold 300 ms, let go 100 ms, again and again; one more hold 1.7 s, one full hold
	// of 3 s with a quick press again; two minutes each. The announcing gap keeps Begin + Cancel to a pair per 2 s.
	const uint32_t holds[][2] = {{300, 100}, {400, 50}, {1700, 100}, {1900, 20}, {3000, 100}, {kHoldMs, 10}, {260, 1}};
	for (const auto& p : holds)
	{
		const Bucket b = mash(p[0], p[1], 120);
		CHECK_EQ(b.dropped, uint64_t(0));
		CHECK(b.taken > 0);
	}
}

TEST(revive_row_a_mash_sends_at_most_a_pair_per_gap)
{
	// Counting, not the bucket: in 120 s of mashing at most one Begin per kAnnounceGapMs and no more Cancels than Begins
	// (plus the Requests of completed holds).
	const Bucket b = mash(300, 100, 120);
	CHECK(b.taken <= uint64_t(2) * (120000 / kAnnounceGapMs + 1));
}
