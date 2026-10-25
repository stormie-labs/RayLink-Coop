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
	// I-1: the same reviver may begin again inside his own chain (a Cancel got lost, he pressed again) once the gap of his
	// Begins is over, but the lock is never moved past the end of the chain: its first Begin + the hold + the grace.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started); // the chain starts at 1000; the lock runs to 5250
	CHECK(h.begin(1000 + kAnnounceGapMs, 4, 10, 400) == HostHold::Begin::Started);
	CHECK(h.open_at(1000 + kAnnounceGapMs, 4));
	CHECK(h.busy_for(1000 + kAnnounceGapMs, 4, 11));
	const uint64_t chain_end = 1000 + kHoldMs + kGraceMs;
	CHECK(h.busy_for(chain_end - 1, 4, 11));
	CHECK(!h.busy_for(chain_end, 4, 11)); // the restart (400 ms held: 7100 on its own) did not carry the lock beyond 5500
}

TEST(host_hold_a_restart_cannot_move_the_end_past_the_chain)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	const uint64_t chain_end = 1000 + kHoldMs + kGraceMs;
	// every honest-looking restart in the chain asks for a full new hold; none of them gets it
	for (uint64_t t = 1000 + kAnnounceGapMs; t < chain_end; t += kAnnounceGapMs)
	{
		CHECK(h.begin(t, 4, 10, 0) == HostHold::Begin::Started);
		CHECK(h.busy_for(chain_end - 1, 4, 11));
		CHECK(!h.busy_for(chain_end, 4, 11));
	}
}

TEST(host_hold_begins_closer_than_the_pace_are_busy)
{
	// I-1: the host takes one Begin per reviver and wounded per kHostBeginGapMs (the announcer's kAnnounceGapMs less what
	// the net may squeeze); a faster one is refused as Busy and changes nothing.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started); // lock to 5250
	CHECK(h.begin(1000 + kHostBeginGapMs - 1, 4, 10, 0) == HostHold::Begin::Busy);
	CHECK(h.busy_for(5249, 4, 11));
	CHECK(!h.busy_for(5250, 4, 11)); // not moved by the refused one (it would have asked for 9000+)
	// the refused one did not start the pace over either
	CHECK(h.begin(1000 + kHostBeginGapMs, 4, 10, 250) == HostHold::Begin::Started);
	// the jitter allowance: an honest Begin that the net squeezed to 1.6 s apart still passes
	HostHold j;
	CHECK(j.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(j.begin(1000 + kAnnounceGapMs - 400, 4, 10, 250) == HostHold::Begin::Started);
}

TEST(host_hold_pace_follows_a_cancel_but_not_another_reviver)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(h.stop(1100, 4, 10)); // let go
	CHECK(h.begin(1000 + kHostBeginGapMs - 1, 4, 10, 250) == HostHold::Begin::Busy); // a Begin-Cancel pair is paced too
	CHECK(h.begin(1000 + kHostBeginGapMs - 1, 4, 11, 250) == HostHold::Begin::Started); // the pace is his own
}

TEST(host_hold_a_lapsed_chain_locks_its_reviver_out_for_a_gap)
{
	// I-1: a chain that ran out without a Revive, a Cancel or a refused Request: the reviver may not start another before
	// kAnnounceGapMs have passed; anybody else may in that window.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	const uint64_t end = 1000 + kHoldMs + kGraceMs;
	CHECK(h.begin(1000 + kAnnounceGapMs, 4, 10, 0) == HostHold::Begin::Started); // inside the chain (the lock is not moved)
	CHECK(h.begin(end, 4, 10, 0) == HostHold::Begin::Busy); // its end, long after his last Begin: not the pace but the lockout
	CHECK(h.begin(end + kAnnounceGapMs - 1, 4, 10, 0) == HostHold::Begin::Busy);
	CHECK(h.begin(end + kAnnounceGapMs, 4, 10, 0) == HostHold::Begin::Started); // a new chain
	CHECK(h.busy_for(end + kAnnounceGapMs + kHoldMs + kGraceMs - 1, 4, 11));
	CHECK(!h.busy_for(end + kAnnounceGapMs + kHoldMs + kGraceMs, 4, 11));

	HostHold other;
	CHECK(other.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	CHECK(other.begin(end, 4, 11, 250) == HostHold::Begin::Started); // the window is for the others
	CHECK(other.begin(end + 1, 4, 10, 0) == HostHold::Begin::Busy); // and the second one's lock holds against the first
	CHECK(other.busy_for(end + 1, 4, 10));
}

TEST(host_hold_a_cancel_does_not_end_the_chain)
{
	// Round 2 of I-1: a Cancel closes the lock but not the chain. A Begin that follows within kAnnounceGapMs of it (the
	// lock was not free for a whole gap, nobody had a window) is the same chain, with the same ceiling.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started); // chain from 1000, ceiling 5500
	CHECK(h.stop(2900, 4, 10)); // let go
	CHECK(!h.busy_for(2950, 4, 11)); // the lock is free for the others at once
	CHECK(h.begin(3000, 4, 10, 0) == HostHold::Begin::Started); // 100 ms later: the same chain
	const uint64_t ceiling = 1000 + kHoldMs + kGraceMs;
	CHECK(h.busy_for(ceiling - 1, 4, 11));
	CHECK(!h.busy_for(ceiling, 4, 11)); // not carried past the ceiling of the FIRST Begin, though this one asked for 7500
}

TEST(host_hold_a_used_up_chain_locks_its_reviver_out_after_a_cancel_too)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	CHECK(h.begin(3000, 4, 10, 0) == HostHold::Begin::Started); // inside the chain
	const uint64_t ceiling = 1000 + kHoldMs + kGraceMs;
	CHECK(h.stop(ceiling - 10, 4, 10)); // Cancel 10 ms before the end, as a client does who wants the lock back at once
	CHECK(h.begin(ceiling, 4, 10, 0) == HostHold::Begin::Busy); // the chain is used up: not at the ceiling,
	CHECK(h.begin(ceiling - 10 + kAnnounceGapMs - 1, 4, 10, 0) == HostHold::Begin::Busy); // nor for a gap after his Cancel
	CHECK(h.begin(ceiling - 10 + kAnnounceGapMs, 4, 10, 0) == HostHold::Begin::Started); // then a chain of its own
	CHECK(h.busy_for(ceiling - 10 + kAnnounceGapMs + kHoldMs + kGraceMs - 1, 4, 11));
	CHECK(!h.busy_for(ceiling - 10 + kAnnounceGapMs + kHoldMs + kGraceMs, 4, 11));
}

TEST(host_hold_the_window_after_a_used_up_chain_is_for_the_others)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	const uint64_t ceiling = 1000 + kHoldMs + kGraceMs;
	CHECK(h.stop(ceiling - 10, 4, 10));
	CHECK(h.begin(ceiling, 4, 11, 250) == HostHold::Begin::Started); // somebody else may take it
	CHECK(h.begin(ceiling + kHostBeginGapMs, 4, 10, 0) == HostHold::Begin::Busy); // and his lock holds against the first
}

TEST(host_hold_an_idle_gap_after_a_cancel_starts_a_fresh_chain)
{
	// The lock was free for a whole gap: the others had their window, so the chain starts over, even before the old
	// ceiling or long after it. A reviver who lets go and comes back later is not punished.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started); // ceiling 5500
	CHECK(h.stop(1300, 4, 10));
	CHECK(h.begin(1300 + kAnnounceGapMs, 4, 10, 0) == HostHold::Begin::Started); // before the old ceiling: a fresh chain
	CHECK(h.busy_for(1300 + kAnnounceGapMs + kHoldMs + kGraceMs - 1, 4, 11)); // with a ceiling of its own, past 5500
	CHECK(h.stop(3400, 4, 10));
	const uint64_t long_after = 3400 + 4 * kAnnounceGapMs;
	CHECK(h.begin(long_after, 4, 10, 0) == HostHold::Begin::Started); // long after both ceilings
	CHECK(h.busy_for(long_after + kHoldMs + kGraceMs - 1, 4, 11));
}

TEST(host_hold_a_revive_or_a_departure_ends_the_chain)
{
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 0) == HostHold::Begin::Started);
	h.close(); // the revive went through / the wounded stood up
	CHECK(h.begin(1000 + kHostBeginGapMs, 4, 10, 0) == HostHold::Begin::Started); // nothing of the old chain counts
	CHECK(h.busy_for(1000 + kHostBeginGapMs + kHoldMs + kGraceMs - 1, 4, 11));
	CHECK(h.drop_reviver(10)); // he left
	CHECK(h.begin(1000 + 2 * kHostBeginGapMs, 4, 10, 0) == HostHold::Begin::Started); // and came back: a new one
}

TEST(host_hold_drop_reviver_frees_his_lock)
{
	// M-1: the reviver went away in the middle of the hold.
	HostHold h;
	CHECK(!h.drop_reviver(10)); // nothing held
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK_EQ(int(h.seq()), 4);
	CHECK(!h.drop_reviver(11)); // not his lock
	CHECK(h.open_at(1100, 4));
	CHECK(h.drop_reviver(10)); // his: the wounded is told
	CHECK(!h.open_at(1100, 4));
	CHECK(!h.busy_for(1100, 4, 11)); // free for the next one
	CHECK(!h.drop_reviver(10)); // once
	CHECK(h.begin(1100, 4, 11, 250) == HostHold::Begin::Started);
	h.close();
	CHECK(!h.drop_reviver(11)); // nothing held after a revive
}

TEST(host_hold_a_request_meets_the_lock_of_another_reviver)
{
	// M-3: host_on_revive_request asks busy_for with the Request's reviver, as a Begin does.
	HostHold h;
	CHECK(h.begin(1000, 4, 10, 250) == HostHold::Begin::Started);
	CHECK(h.busy_for(1500, 4, 11)); // a Request of somebody else: RefBusy
	CHECK(!h.busy_for(1500, 4, 10)); // the reviver's own Request passes the lock
	CHECK(!h.busy_for(1500, 5, 11)); // the lock is of the fall 4
	CHECK(!h.stop(1500, 4, 11)); // and his refused Request does not end the first one's hold
	CHECK(h.open_at(1500, 4));
	CHECK(!h.busy_for(5250, 4, 11)); // lapsed
	CHECK(h.stop(2000, 4, 10));
	CHECK(!h.busy_for(1500, 4, 11)); // ended
}

namespace
{
// A modified client's train of Begins on a wounded character (never a Cancel, never a Request), every `period` ms from
// `from` to `to` (exclusive); what the host answered to each.
struct Train
{
	uint32_t started = 0, busy = 0;
};
Train begin_train(HostHold& h, uint16_t reviver, uint64_t from, uint64_t to, uint32_t period, uint32_t held_ms = 0)
{
	Train out;
	for (uint64_t t = from; t < to; t += period)
		(h.begin(t, 4, reviver, held_ms) == HostHold::Begin::Started ? out.started : out.busy)++;
	return out;
}
} // namespace

TEST(host_hold_a_begin_train_does_not_keep_the_lock_for_ever)
{
	// M-2 / I-1: a client sends Begin every 1.9 s, or every 4 s, for a minute and never a Cancel or a Request. A second
	// reviver looks at the lock every 10 ms: it is never shut on him for longer than the first Begin's hold + grace.
	const uint32_t periods[] = {1900, 4000, 100, 700, 2000, 2600, 4400, 4600};
	for (const uint32_t period : periods)
	{
		HostHold h;
		const uint64_t t0 = 7000;
		uint64_t shut_since = 0, longest = 0, first_open = 0;
		bool shut = false, opened = false;
		uint32_t windows = 0;
		for (uint64_t t = 0; t < 60000; t += 10)
		{
			if (t % period == 0)
				h.begin(t0 + t, 4, 10, 0);
			const bool now_shut = h.busy_for(t0 + t, 4, 11);
			if (now_shut && !shut)
				shut_since = t;
			if (!now_shut && shut)
			{
				longest = t - shut_since > longest ? t - shut_since : longest;
				++windows;
				if (!opened)
				{
					opened = true;
					first_open = t;
				}
			}
			shut = now_shut;
		}
		CHECK_EQ(first_open, uint64_t(kHoldMs + kGraceMs)); // the first lock ended with its first Begin's hold + grace
		CHECK(longest <= uint64_t(kHoldMs + kGraceMs));
		CHECK(windows >= 6); // and it kept opening: at least one window in every ~8 s of a minute
	}
}

TEST(host_hold_a_begin_train_leaves_a_window_for_the_second_reviver)
{
	// M-2: whatever the train's period, the second reviver gets Started once the first chain has lapsed, anywhere in the
	// window of kAnnounceGapMs after it, and then the train is Busy against his lock.
	const uint32_t periods[] = {1900, 4000, 100, 700, 2000};
	const uint64_t t0 = 7000, end = t0 + kHoldMs + kGraceMs;
	const uint64_t asks[] = {end, end + 700, end + kAnnounceGapMs - 1};
	for (const uint32_t period : periods)
		for (const uint64_t ask : asks)
		{
			HostHold h;
			const Train first = begin_train(h, 10, t0, ask, period);
			CHECK(first.started >= 1);
			CHECK(h.begin(ask, 4, 11, 250) == HostHold::Begin::Started);
			// his lock is a lock: the train is turned away for as long as it holds, however it is paced
			const uint64_t his_end = ask + (kHoldMs - 250) + kGraceMs;
			const Train second = begin_train(h, 10, ask + 10, his_end, period);
			CHECK_EQ(second.started, uint32_t(0));
			CHECK(second.busy >= 1);
			CHECK(h.busy_for(his_end - 1, 4, 10));
		}
}

namespace
{
// A modified client that sends a Cancel 10 ms before every Begin (round 2 of I-1: the lock is shut for 10 ms only, a chain
// that ended at a Cancel would never run out): a Begin every `period` ms from `from` to `to` (exclusive).
void begin_cancel_train(HostHold& h, uint16_t reviver, uint64_t from, uint64_t to, uint32_t period)
{
	for (uint64_t t = from; t < to; t += 10)
	{
		const uint64_t in_period = (t - from) % period;
		if (in_period == 0)
			h.begin(t, 4, reviver, 0);
		else if (in_period == period - 10)
			h.stop(t, 4, reviver);
	}
}
} // namespace

TEST(host_hold_a_begin_cancel_train_does_not_keep_the_lock)
{
	// Round 2 of I-1 (measured with the first fix: periods 1.5 / 2 / 2.5 s kept the lock shut for 59.6 / 59.7 / 59.76 s of
	// 60 s, the longest window 10 ms): a Cancel right before each Begin. A second reviver looks at the lock every 10 ms for
	// a minute: the lock is shut for 70 % of the time at the most, and the others get a whole gap again and again.
	const uint32_t periods[] = {1500, 1900, 2000, 2500, 4000, 100, 700};
	for (const uint32_t period : periods)
	{
		HostHold h;
		const uint64_t t0 = 7000;
		uint32_t shut_probes = 0, probes = 0, windows = 0, open_run = 0;
		for (uint64_t t = 0; t < 60000; t += 10)
		{
			const uint64_t in_period = t % period;
			if (in_period == 0)
				h.begin(t0 + t, 4, 10, 0);
			else if (in_period == period - 10)
				h.stop(t0 + t, 4, 10);
			const bool shut = h.busy_for(t0 + t, 4, 11);
			++probes;
			shut_probes += shut ? 1 : 0;
			open_run = shut ? 0 : open_run + 10;
			if (open_run == kAnnounceGapMs - 10)
				++windows; // a stretch the others could take the lock in
		}
		CHECK(shut_probes * 100 <= probes * 70);
		CHECK(windows >= 6);
	}
}

TEST(host_hold_a_begin_cancel_train_leaves_a_window_for_the_second_reviver)
{
	// The second reviver gets Started once the train's chain has run out, anywhere in the gap that follows, and his lock holds
	// against the train.
	const uint32_t periods[] = {1500, 2000, 2500, 4000};
	const uint64_t t0 = 7000, ceiling = t0 + kHoldMs + kGraceMs;
	const uint64_t asks[] = {ceiling, ceiling + 700, ceiling + kAnnounceGapMs - 11};
	for (const uint32_t period : periods)
		for (const uint64_t ask : asks)
		{
			HostHold h;
			begin_cancel_train(h, 10, t0, ask, period);
			// the train never held the lock past the ceiling of its first Begin: at `ask` the lock is free
			CHECK(!h.busy_for(ask, 4, 11));
			CHECK(h.begin(ask, 4, 11, 250) == HostHold::Begin::Started);
			const uint64_t his_end = ask + (kHoldMs - 250) + kGraceMs;
			CHECK(h.busy_for(his_end - 1, 4, 10));
			CHECK(h.begin(ask + kHostBeginGapMs, 4, 10, 0) == HostHold::Begin::Busy); // and the train is turned away
		}
}

TEST(host_hold_an_honest_release_and_press_again_is_not_refused)
{
	// Press, let go after 1 s, press again and hold the 3 s: the announcer's Begins and Cancel go through the host's hold at
	// the times the announcer sends them, the second Begin is Started, nobody else gets in, and the Request meets no lock of
	// the reviver's own. Also with other first holds.
	const uint32_t releases[] = {300, 1000, 1700, 2400};
	for (const uint32_t release : releases)
	{
		HostHold h;
		Announcer a;
		uint32_t begins = 0;
		a.start(); // pressed at 0
		for (uint64_t t = 0; t <= release; t += 10) // the first hold, until let go
			if (a.step(t, uint32_t(t)) == Announcer::Act::Begin)
			{
				++begins;
				CHECK(h.begin(t, 4, 10, uint32_t(t)) == HostHold::Begin::Started);
			}
		CHECK(a.stop() == Announcer::Act::Cancel);
		CHECK(h.stop(release, 4, 10));
		const uint64_t press_again = release + 100;
		a.start();
		bool second_begin = false;
		for (uint64_t t = press_again; t < press_again + kHoldMs; t += 10)
			if (a.step(t, uint32_t(t - press_again)) == Announcer::Act::Begin)
			{
				++begins;
				second_begin = true;
				CHECK(h.begin(t, 4, 10, uint32_t(t - press_again)) == HostHold::Begin::Started);
				CHECK(h.busy_for(t, 4, 11)); // his lock is on again
			}
		CHECK(second_begin);
		CHECK_EQ(begins, uint32_t(2));
		// the hold is over: his Request meets no lock of another reviver
		CHECK(!h.busy_for(press_again + kHoldMs, 4, 10));
		h.close();
	}
}

namespace
{
struct Mash
{
	uint32_t begins = 0, started = 0, refused = 0;
};

// The reviver of mash() above against the host's hold: every message of the reviver goes through one ordered channel (a Cancel
// never overtakes his Begin), every other Begin is held up 400 ms on its way (the host sees a pair 1.6 s apart at the least),
// and a refused Begin ends the hold at once, without a Cancel, as stop_revive_hold(false) does.
Mash mash_against_the_host(uint32_t hold_ms, uint32_t release_ms, uint32_t seconds)
{
	HostHold h;
	Announcer a;
	Mash out;
	bool holding = false;
	uint64_t press_at = 0, release_at = 0, last_arrival = 0;
	uint32_t nth = 0;
	const auto arrive = [&last_arrival](uint64_t sent, uint32_t delay) {
		const uint64_t at = sent + delay > last_arrival ? sent + delay : last_arrival;
		last_arrival = at;
		return at;
	};
	for (uint64_t t = 0; t < uint64_t(seconds) * 1000; t += 10)
	{
		if (!holding && t >= release_at)
		{
			holding = true;
			press_at = t;
			a.start();
		}
		if (!holding)
			continue;
		const uint32_t held = uint32_t(t - press_at);
		if (a.step(t, held) == Announcer::Act::Begin)
		{
			++out.begins;
			if (h.begin(arrive(t, nth++ % 2 == 0 ? 400 : 0), 4, 10, held) == HostHold::Begin::Started)
				++out.started;
			else
			{
				++out.refused;
				a.stop(); // no Cancel goes: the host had no hold of his
				holding = false;
				release_at = t + release_ms;
				continue;
			}
		}
		if (held >= kHoldMs) // the hold completed: the Request goes (the host closes the hold with the revive)
		{
			a.done();
			h.close();
			holding = false;
			release_at = t + release_ms;
		}
		else if (held >= hold_ms) // let go early
		{
			if (a.stop() == Announcer::Act::Cancel)
				h.stop(arrive(t, 0), 4, 10);
			holding = false;
			release_at = t + release_ms;
		}
	}
	return out;
}
} // namespace

TEST(host_hold_never_refuses_an_honest_hold_that_goes_the_distance)
{
	// Holds that complete (the Request replaces the Cancel and ends the chain) are never turned away, at any pace, however
	// the net squeezes the Begins.
	const uint32_t releases[] = {10, 100, 1000};
	for (const uint32_t release : releases)
	{
		const Mash m = mash_against_the_host(kHoldMs, release, 120);
		CHECK(m.begins > 10);
		CHECK_EQ(m.refused, uint32_t(0));
	}
}

TEST(host_hold_an_honest_mash_loses_at_most_a_window_to_the_chain)
{
	// A player who lets go before the end again and again for minutes looks like the Begin-Cancel train of a cheat to the
	// host, so his chain has a ceiling too: once in 4.5 s of it he may be refused (and has to press again), never more.
	const uint32_t holds[][2] = {{300, 100}, {400, 50}, {1700, 100}, {1900, 20}, {260, 1}, {1000, 100}};
	for (const auto& p : holds)
	{
		const Mash m = mash_against_the_host(p[0], p[1], 120);
		CHECK(m.begins > 0);
		CHECK(m.started > 0);
		CHECK(m.refused <= 120000 / (kHoldMs + kGraceMs) + 1);
		CHECK_EQ(m.started + m.refused, m.begins);
	}
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
	CHECK(!h.stop(1100, 4, 11)); // somebody else's Cancel
	CHECK(!h.stop(1100, 5, 10)); // another fall
	CHECK(h.open_at(1000, 4));
	CHECK(h.stop(1100, 4, 10));
	CHECK(!h.open_at(1000, 4));
	CHECK(!h.stop(1100, 4, 10)); // once
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

// Live 2026-10-25 (owner): "sometimes you cannot revive an ally when a corpse or something else clickable lies next to
// him". F revived only what the crosshair hit; a corpse or an item nearer along the ray took the F (loot). A wounded
// teammate in reach and in front of the camera wins over them.
TEST(revive_pick_target_prefers_a_wounded_teammate_in_front)
{
	const Vec3 eye{0.f, 1.6f, 0.f};
	const Vec3 feet{0.f, 0.f, 0.f};
	const Vec3 ahead{0.f, -0.6f, 1.f}; // looking down and forward at a body on the ground
	std::vector<ReviveCandidate> c;
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), kNoTarget); // nobody

	c.push_back({7, {0.2f, 0.f, 1.5f}, true}); // wounded, 1.5 m ahead
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), uint16_t(7));

	c[0].wounded = false; // alive or dead: nothing to revive
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), kNoTarget);
	c[0].wounded = true;

	c[0].pos = {0.f, 0.f, 3.2f}; // out of reach (kReviveRange 2.5 m from the feet)
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), kNoTarget);

	c[0].pos = {0.f, 0.f, -1.5f}; // behind: I am not turned to him (I may loot the corpse in front)
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), kNoTarget);
	c[0].pos = {1.5f, 0.f, 0.2f}; // at my side, 80 degrees off the view
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), kNoTarget);

	// two in front: the one nearer the middle of the view
	c[0].pos = {1.0f, 0.f, 1.4f};
	c.push_back({9, {0.1f, 0.f, 1.6f}, true});
	CHECK_EQ(pick_revive_target(eye, ahead, feet, c), uint16_t(9));
}
