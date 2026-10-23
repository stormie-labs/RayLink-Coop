// Anomaly Coop unit tests: the waiting point of a level change (coop_transition.h; owner 2026-10-23: "a place where you
// wait for your allies to go to the next level"). The host's board of who is ready for which exit and when the group
// goes (everybody, the loading players' 60 s, the 5 s countdown, "go now"), the two messages (TransitionVote ops and the
// host's TransitionState), the hold at the exit and the client's reconciling of what it wants with what the host says.
#include "test_util.h"

#include "coop_limits.h"
#include "coop_transition.h"

#include <cstring>
#include <vector>

using namespace coop;
using namespace coop::transition;

namespace
{
constexpr uint32_t kA = 7; // the host's exit 7 (a level changer id)
constexpr uint32_t kB = 9; // another exit

Reader reader_of(const Writer& w) { return Reader(w.ptr(), w.size()); }

// Players 0 (the host) and the given clients, all in the world and alive.
std::vector<Member> party(std::initializer_list<uint32_t> ids)
{
	std::vector<Member> v;
	for (uint32_t id : ids)
	{
		Member m;
		m.id = id;
		m.remote = id != 0;
		v.push_back(m);
	}
	return v;
}

const DistFn kNear = [](uint32_t, uint32_t) { return 1.f; };

Row row_of(const Status& s, uint32_t id)
{
	for (const Row& r : s.rows)
		if (r.id == id)
			return r;
	Row none;
	none.id = 0xdeadbeef;
	return none;
}
} // namespace

// ---------------------------------------------------------------- who goes when

TEST(transition_nothing_claimed_is_idle)
{
	Board b;
	const Status s = b.tick(party({0, 1}), kNear, 1000);
	CHECK_EQ(int(s.state), int(State::Idle));
	CHECK(!s.go);
	CHECK(s.rows.empty());
}

TEST(transition_lone_host_goes_after_the_countdown)
{
	Board b;
	const auto m = party({0});
	b.claim(0, kA, 1000);
	Status s = b.tick(m, kNear, 1000);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.ready, 1u);
	CHECK_EQ(s.total, 1u);
	CHECK_EQ(s.goal, kA);
	CHECK_EQ(s.countdown_ms, 5000u);
	CHECK(!s.go);
	s = b.tick(m, kNear, 3000);
	CHECK_EQ(s.countdown_ms, 3000u);
	s = b.tick(m, kNear, 5999);
	CHECK_EQ(s.countdown_ms, 1u);
	CHECK(!s.go);
	s = b.tick(m, kNear, 6000);
	CHECK(s.go);
	CHECK_EQ(s.goal, kA);
	s = b.tick(m, kNear, 6100); // the claims went with the group
	CHECK_EQ(int(s.state), int(State::Idle));
	CHECK(!s.go);
}

TEST(transition_waits_for_every_player_then_counts)
{
	Board b;
	const auto m = party({0, 1, 2});
	b.claim(0, kA, 1000);
	b.claim(1, kA, 1500);
	Status s = b.tick(m, kNear, 2000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.ready, 2u);
	CHECK_EQ(s.total, 3u);
	CHECK_EQ(s.countdown_ms, 0u);
	CHECK_EQ(int(row_of(s, 0).mark), int(Mark::Ready));
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Ready));
	CHECK_EQ(int(row_of(s, 2).mark), int(Mark::Away));
	b.claim(2, kA, 2500);
	s = b.tick(m, kNear, 2600);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.ready, 3u);
	CHECK_EQ(s.countdown_ms, 5000u);
	s = b.tick(m, kNear, 7600);
	CHECK(s.go);
}

TEST(transition_a_player_at_another_exit_does_not_count)
{
	Board b;
	const auto m = party({0, 1});
	b.claim(0, kA, 1000);
	b.claim(1, kB, 2000);
	Status s = b.tick(m, kNear, 3000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.goal, kA); // the oldest claim leads
	CHECK_EQ(s.ready, 1u);
	CHECK_EQ(s.total, 2u);
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Elsewhere));
	b.release(0); // the leader walks away: the other exit leads now
	s = b.tick(m, kNear, 3100);
	CHECK_EQ(s.goal, kB);
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Ready));
	CHECK_EQ(int(row_of(s, 0).mark), int(Mark::Away));
}

TEST(transition_a_player_who_steps_back_breaks_the_countdown)
{
	Board b;
	const auto m = party({0, 1});
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	Status s = b.tick(m, kNear, 100);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK(!s.cancelled);
	CHECK(b.release(1));
	s = b.tick(m, kNear, 2000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK(s.cancelled); // once
	CHECK(!b.tick(m, kNear, 2100).cancelled);
	b.claim(1, kA, 3000);
	s = b.tick(m, kNear, 3000);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.countdown_ms, 5000u); // starts over
}

TEST(transition_everybody_leaving_cancels_and_goes_idle)
{
	Board b;
	const auto m = party({0});
	b.claim(0, kA, 0);
	CHECK_EQ(int(b.tick(m, kNear, 10).state), int(State::Counting));
	b.release(0);
	const Status s = b.tick(m, kNear, 20);
	CHECK_EQ(int(s.state), int(State::Idle));
	CHECK(s.cancelled);
	CHECK(!s.go);
}

TEST(transition_loading_player_holds_the_group_for_a_minute)
{
	Board b;
	auto m = party({0, 1, 2});
	m[2].in_world = false; // loading the world or choosing a character
	b.claim(0, kA, 1000);
	b.claim(1, kA, 1000);
	Status s = b.tick(m, kNear, 1000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.ready, 2u);
	CHECK_EQ(s.total, 3u);
	CHECK_EQ(s.load_ms, 60000u);
	CHECK_EQ(int(row_of(s, 2).mark), int(Mark::Loading));
	CHECK_EQ(row_of(s, 2).dist_m, kUnknownDist);
	b.claim(1, kA, 20000); // his refresh keeps the claim alive
	s = b.tick(m, kNear, 31000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.load_ms, 30000u);
	b.claim(1, kA, 40000);
	b.claim(1, kA, 55000);
	s = b.tick(m, kNear, 60999);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.load_ms, 1u);
	s = b.tick(m, kNear, 61000); // the minute is over: the group does not wait for him any more
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.countdown_ms, 5000u);
	CHECK_EQ(s.total, 2u);
	CHECK_EQ(int(row_of(s, 2).mark), int(Mark::Loading)); // still shown
	CHECK(b.tick(m, kNear, 66000).go);
}

TEST(transition_the_loading_minute_starts_when_everyone_else_is_ready)
{
	Board b;
	auto m = party({0, 1, 2});
	m[2].in_world = false;
	b.claim(0, kA, 0);
	Status s = b.tick(m, kNear, 0); // player 1 is not ready: the minute does not run yet
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.load_ms, 0u);
	s = b.tick(m, kNear, 50000);
	CHECK_EQ(s.load_ms, 0u);
	b.claim(1, kA, 50000);
	s = b.tick(m, kNear, 50000);
	CHECK_EQ(s.load_ms, 60000u); // from now
	b.release(1);
	s = b.tick(m, kNear, 70000); // he steps back: the clock stops and starts over
	CHECK_EQ(s.load_ms, 0u);
	b.claim(1, kA, 80000);
	s = b.tick(m, kNear, 80000);
	CHECK_EQ(s.load_ms, 60000u);
}

TEST(transition_a_loader_who_arrives_must_get_ready_too)
{
	Board b;
	auto m = party({0, 1});
	m[1].in_world = false;
	b.claim(0, kA, 0);
	CHECK_EQ(int(b.tick(m, kNear, 100).state), int(State::Waiting));
	m[1].in_world = true; // his world is up: he is one of those who must be ready now
	const Status s = b.tick(m, kNear, 200);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.load_ms, 0u);
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Away));
}

TEST(transition_a_downed_player_does_not_block)
{
	Board b;
	auto m = party({0, 1});
	m[1].alive = false; // wounded or dead: he cannot walk to the exit
	b.claim(0, kA, 0);
	const Status s = b.tick(m, kNear, 10);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.total, 1u);
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Down));
}

TEST(transition_a_claim_of_one_who_is_not_in_the_world_is_void)
{
	Board b;
	auto m = party({0, 1});
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	m[1].in_world = false; // his world is replaced / he is loading again
	Status s = b.tick(m, kNear, 10);
	CHECK(!b.claimed(1));
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Loading));
	m[1].in_world = true;
	s = b.tick(m, kNear, 20);
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Away));
}

TEST(transition_a_player_who_left_the_session_is_forgotten)
{
	Board b;
	b.claim(1, kA, 0);
	b.claim(0, kA, 0);
	Status s = b.tick(party({0, 1, 2}), kNear, 10);
	CHECK_EQ(s.ready, 2u);
	s = b.tick(party({0, 2}), kNear, 20); // 1 is not in the session any more
	CHECK(!b.claimed(1));
	CHECK_EQ(s.ready, 1u);
	b.claim(2, kA, 30);
	b.forget(2);
	CHECK(!b.claimed(2));
}

TEST(transition_a_remote_claim_lapses_without_a_refresh)
{
	Board b;
	const auto m = party({0, 1, 2});
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	CHECK_EQ(b.tick(m, kNear, 19999).ready, 2u);
	b.claim(1, kA, 15000); // a refresh (the client sends one every kClaimRefreshMs)
	CHECK_EQ(b.tick(m, kNear, 20001).ready, 2u);
	CHECK_EQ(b.tick(m, kNear, 35001).ready, 1u); // no refresh since 15000: lapsed; the host's own claim stays
	CHECK(b.claimed(0));
	CHECK(!b.claimed(1));
}

TEST(transition_a_claim_ends_when_the_player_is_far_from_the_exit)
{
	Board b;
	const auto m = party({0, 1, 2});
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	const DistFn far1 = [](uint32_t id, uint32_t) { return id == 1 ? 12.f : 1.f; };
	Status s = b.tick(m, far1, 10);
	CHECK(!b.claimed(1));
	CHECK_EQ(row_of(s, 1).dist_m, uint16_t(12)); // shown with the distance
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Away));
	// within the reach plus the slack he keeps his claim (the host sees him a little behind)
	b.claim(1, kA, 20);
	const DistFn edge = [](uint32_t id, uint32_t) { return id == 1 ? kLeaveM - 0.5f : 1.f; };
	s = b.tick(m, edge, 30);
	CHECK(b.claimed(1));
}

TEST(transition_distance_unknown_is_not_a_reason_to_drop_a_claim)
{
	Board b;
	const auto m = party({0, 1, 2});
	b.claim(1, kA, 0);
	const DistFn unknown = [](uint32_t, uint32_t) { return -1.f; };
	const Status s = b.tick(m, unknown, 10);
	CHECK(b.claimed(1));
	CHECK_EQ(row_of(s, 1).dist_m, kUnknownDist);
}

TEST(transition_rows_are_in_player_order_with_rounded_distances)
{
	Board b;
	const auto m = party({0, 3, 1});
	b.claim(0, kA, 0);
	const DistFn far = [](uint32_t id, uint32_t) { return id == 3 ? 118.6f : id == 1 ? 41.2f : 0.f; };
	const Status s = b.tick(m, far, 10);
	CHECK_EQ(s.rows.size(), size_t(3));
	CHECK_EQ(s.rows[0].id, 0u);
	CHECK_EQ(s.rows[1].id, 1u);
	CHECK_EQ(s.rows[2].id, 3u);
	CHECK_EQ(s.rows[1].dist_m, uint16_t(41));
	CHECK_EQ(s.rows[2].dist_m, uint16_t(119));
}

TEST(transition_go_now_goes_at_once_even_if_not_everybody_is_ready)
{
	Board b;
	const auto m = party({0, 1, 2});
	b.claim(0, kA, 0);
	b.force(kA);
	Status s = b.tick(m, kNear, 10);
	CHECK(s.go);
	CHECK_EQ(s.goal, kA);
	CHECK_EQ(s.countdown_ms, 0u);
	s = b.tick(m, kNear, 20);
	CHECK(!s.go);
	CHECK_EQ(int(s.state), int(State::Idle));
}

TEST(transition_go_now_needs_somebody_waiting_at_that_exit)
{
	Board b;
	const auto m = party({0, 1});
	b.claim(0, kA, 0);
	b.force(kB); // nobody claimed it
	CHECK(!b.tick(m, kNear, 10).go);
	b.force(kA);
	b.release(0); // and the one who held the key stepped away before the tick
	CHECK(!b.tick(m, kNear, 20).go);
	b.claim(0, kA, 30);
	CHECK(!b.tick(m, kNear, 40).go); // the force was for that moment only
}

TEST(transition_clear_forgets_everything)
{
	Board b;
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	b.force(kA);
	b.clear(); // the world was replaced
	const Status s = b.tick(party({0, 1}), kNear, 10);
	CHECK_EQ(int(s.state), int(State::Idle));
	CHECK(!s.go);
	CHECK(!b.claimed(0));
}

TEST(transition_a_claim_for_a_new_exit_replaces_the_old_one)
{
	Board b;
	b.claim(1, kA, 0);
	b.claim(1, kB, 100);
	uint32_t goal = 0;
	CHECK(b.claimed(1, &goal));
	CHECK_EQ(goal, kB);
	b.claim(1, kB, 200); // a refresh keeps its age
	const Status s = b.tick(party({0, 1}), kNear, 300);
	CHECK_EQ(s.goal, kB);
}

// ---------------------------------------------------------------- the guide (a trip without an exit)

TEST(transition_a_guide_trip_waits_for_everybody_to_confirm)
{
	Board b;
	const auto m = party({0, 1});
	b.start_guide(0, 1000);
	Status s = b.tick(m, kNear, 1000);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.goal, kGuideGoal);
	CHECK_EQ(s.ready, 1u);
	CHECK_EQ(s.total, 2u);
	b.claim(1, kGuideGoal, 9000); // he confirms
	s = b.tick(m, kNear, 9000);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK(b.tick(m, kNear, 14000).go);
}

TEST(transition_a_guide_trip_is_not_cancelled_by_distance)
{
	Board b;
	const auto m = party({0, 1});
	b.start_guide(0, 0);
	b.claim(1, kGuideGoal, 0);
	const DistFn far = [](uint32_t, uint32_t) { return 500.f; }; // nobody stands at an exit
	CHECK_EQ(b.tick(m, far, 10).ready, 2u);
}

TEST(transition_a_guide_trip_expires_after_a_minute)
{
	Board b;
	const auto m = party({0, 1});
	b.start_guide(0, 1000);
	CHECK_EQ(int(b.tick(m, kNear, 60999).state), int(State::Waiting));
	const Status s = b.tick(m, kNear, 61000);
	CHECK_EQ(int(s.state), int(State::Idle));
	CHECK(s.expired);
	CHECK(!s.go);
	CHECK(!b.claimed(0));
	CHECK(!b.tick(m, kNear, 61100).expired); // once
}

// ---------------------------------------------------------------- the messages

TEST(transition_message_numbers_and_directions)
{
	CHECK_EQ(uint16_t(Msg::TransitionVote), uint16_t(0x0106));
	CHECK_EQ(uint16_t(Msg::TransitionState), uint16_t(0x010A));
	CHECK(msg_sender(Msg::TransitionVote) == MsgSender::ClientOnly);
	CHECK(msg_sender(Msg::TransitionState) == MsgSender::HostOnly);
	CHECK_EQ(std::string(msg_name(Msg::TransitionState)), std::string("TransitionState"));
	CHECK_EQ(kProtocolVersion, 11u); // since protocol 10 TransitionVote carries an op (F3a made it 11: protocol 10 peers are refused)
}

TEST(transition_vote_round_trip)
{
	VoteMsg v;
	v.op = VoteReady;
	v.changer = 16601;
	Writer w;
	v.write(w);
	CHECK_EQ(w.size(), size_t(3)); // op, u16 changer
	Reader r = reader_of(w);
	VoteMsg back;
	CHECK(back.read(r));
	CHECK_EQ(int(back.op), int(VoteReady));
	CHECK_EQ(back.changer, uint16_t(16601));
	CHECK_EQ(r.remaining(), size_t(0));

	VoteMsg cancel;
	cancel.op = VoteCancel;
	Writer w2;
	cancel.write(w2);
	Reader r2 = reader_of(w2);
	VoteMsg back2;
	CHECK(back2.read(r2));
	CHECK_EQ(int(back2.op), int(VoteCancel));
	CHECK_EQ(back2.changer, kNoChanger); // a cancel names no exit; a ready without one confirms the guide trip
}

TEST(transition_vote_rejects_unknown_ops_and_cut_packets)
{
	const uint8_t bad_op[] = {2, 0x59, 0x40};
	Reader r(bad_op, sizeof(bad_op));
	VoteMsg v;
	CHECK(!v.read(r));
	const uint8_t cut[] = {0, 0x59};
	Reader r2(cut, sizeof(cut));
	CHECK(!v.read(r2));
	const uint8_t old_layout[] = {0x59, 0x40}; // protocol 9: just the u16
	Reader r3(old_layout, sizeof(old_layout));
	CHECK(!v.read(r3));
	CHECK(v.is_client_op(VoteReady) && v.is_client_op(VoteCancel) && !v.is_client_op(2));
}

namespace
{
StateMsg sample_state()
{
	StateMsg m;
	m.state = State::Waiting;
	m.kind = 0;
	m.changer = 16601;
	m.level = "l01_escape";
	m.ready = 1;
	m.total = 2;
	m.countdown_ms = 0;
	m.load_ms = 30000;
	m.rows.push_back({0, Mark::Ready, 2});
	m.rows.push_back({1, Mark::Away, 118});
	return m;
}
} // namespace

TEST(transition_state_round_trip)
{
	const StateMsg m = sample_state();
	Writer w;
	m.write(w);
	CHECK_EQ(w.size(), size_t(42));
	Reader r = reader_of(w);
	StateMsg back;
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(int(back.state), int(State::Waiting));
	CHECK_EQ(back.changer, uint16_t(16601));
	CHECK_EQ(back.level, std::string("l01_escape"));
	CHECK_EQ(back.ready, uint16_t(1));
	CHECK_EQ(back.total, uint16_t(2));
	CHECK_EQ(back.load_ms, 30000u);
	CHECK_EQ(back.rows.size(), size_t(2));
	CHECK_EQ(back.rows[1].id, 1u);
	CHECK_EQ(int(back.rows[1].mark), int(Mark::Away));
	CHECK_EQ(back.rows[1].dist_m, uint16_t(118));
}

TEST(transition_state_cut_anywhere_is_refused)
{
	Writer w;
	sample_state().write(w);
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		Reader r(w.ptr(), cut);
		StateMsg m;
		CHECK(!m.read(r));
	}
}

TEST(transition_state_refuses_nonsense)
{
	{
		StateMsg m = sample_state();
		Writer w;
		m.write(w);
		std::vector<uint8_t> bytes(w.data());
		bytes[0] = 9; // no such state
		Reader r(bytes.data(), bytes.size());
		StateMsg back;
		CHECK(!back.read(r));
	}
	{
		StateMsg m = sample_state();
		m.level = std::string(65, 'x'); // a level name is short
		Writer w;
		m.write(w);
		Reader r = reader_of(w);
		StateMsg back;
		CHECK(!back.read(r));
	}
	{
		StateMsg m = sample_state();
		for (uint32_t i = 0; i < kMaxPlayers + 1; ++i)
			m.rows.push_back({i, Mark::Away, 5});
		Writer w;
		m.write(w);
		Reader r = reader_of(w);
		StateMsg back;
		CHECK(!back.read(r)); // more rows than players
	}
	{
		StateMsg m = sample_state();
		m.rows[0].mark = static_cast<Mark>(77);
		Writer w;
		m.write(w);
		Reader r = reader_of(w);
		StateMsg back;
		CHECK(!back.read(r));
	}
}

TEST(transition_status_makes_the_message)
{
	Board b;
	const auto m = party({0, 1});
	b.claim(0, kA, 0);
	const DistFn d = [](uint32_t id, uint32_t) { return id == 1 ? 88.f : 1.f; };
	const Status s = b.tick(m, d, 10);
	const StateMsg msg = state_message(s, "l01_escape");
	CHECK_EQ(int(msg.state), int(State::Waiting));
	CHECK_EQ(msg.changer, uint16_t(kA));
	CHECK_EQ(msg.kind, uint8_t(0));
	CHECK_EQ(msg.ready, uint16_t(1));
	CHECK_EQ(msg.total, uint16_t(2));
	CHECK_EQ(msg.rows.size(), size_t(2));
	CHECK_EQ(msg.level, std::string("l01_escape"));
	// a guide trip has no exit
	Board g;
	g.start_guide(0, 0);
	const StateMsg gm = state_message(g.tick(m, d, 10), "zaton");
	CHECK_EQ(gm.kind, uint8_t(1));
	CHECK_EQ(gm.changer, kNoChanger);
	// idle: no rows, nothing to show
	const StateMsg idle = state_message(Board().tick(m, d, 10), "");
	CHECK_EQ(int(idle.state), int(State::Idle));
	CHECK(idle.rows.empty());
}

TEST(transition_a_client_that_flaps_stays_within_the_hosts_rate_row)
{
	// The client says ready / not ready as the player steps in and out of the exit; the host takes `burst` and then one
	// per `refill_ms` (coop_limits.h). Intent + Pacer together never send more than a host would drop.
	const limits::RateRule* rule = limits::client_rule(Msg::TransitionVote);
	REQUIRE(rule != nullptr);
	limits::Pacer pacer;
	Intent intent;
	double tokens = double(rule->burst);
	uint64_t last = 0;
	uint32_t sent = 0;
	bool want = false, view = false;
	for (uint64_t now = 1000; now < 61000; now += 100)
	{
		want = ((now / 200) % 2) == 0; // in and out every 200 ms
		const Send s = intent.wants(want, kA, view, kA, now);
		if (s != Send::Nothing && pacer.take(Msg::TransitionVote, now))
		{
			intent.sent(now);
			view = s == Send::Ready; // the host answered at once
			++sent;
			tokens += double(now - last) / double(rule->refill_ms);
			if (tokens > double(rule->burst))
				tokens = double(rule->burst);
			last = now;
			CHECK(tokens >= 1.); // the host's bucket still had a token
			tokens -= 1.;
		}
	}
	CHECK(sent > 10); // it did keep saying what the player wants
}

// ---------------------------------------------------------------- the hold at the exit

TEST(transition_hold_puts_a_waiting_player_back_when_he_walks_off_the_map)
{
	Hold h;
	const float inside[3] = {1.f, 0.f, 2.f};
	const float inside2[3] = {1.5f, 0.f, 2.5f};
	const float out[3] = {40.f, 0.f, 9.f};
	float back[3] = {0, 0, 0};
	CHECK(!h.step(true, true, true, inside, back));
	CHECK(!h.step(true, true, true, inside2, back)); // the last good place moves with him
	CHECK(h.step(true, true, false, out, back)); // in the zone but off the map
	CHECK(back[0] == inside2[0] && back[1] == inside2[1] && back[2] == inside2[2]);
	CHECK(h.step(true, false, false, out, back)); // off the zone and the map
	CHECK(back[0] == inside2[0] && back[2] == inside2[2]);
}

TEST(transition_hold_lets_him_walk_back_into_the_map)
{
	Hold h;
	const float inside[3] = {1.f, 0.f, 2.f};
	const float map_only[3] = {-8.f, 0.f, 2.f}; // back in the level, out of the zone: he cancelled by walking away
	float back[3] = {0, 0, 0};
	CHECK(!h.step(true, true, true, inside, back));
	CHECK(!h.step(true, false, true, map_only, back));
	CHECK(h.step(true, true, false, inside, back)); // the last good place is still the one in the zone
	CHECK(back[0] == inside[0]);
}

TEST(transition_hold_is_off_when_nobody_waits)
{
	Hold h;
	const float inside[3] = {1.f, 0.f, 2.f};
	const float out[3] = {40.f, 0.f, 9.f};
	float back[3] = {0, 0, 0};
	CHECK(!h.step(true, true, true, inside, back));
	CHECK(!h.step(false, false, false, out, back)); // not waiting: the stock level edge, nothing is held
	CHECK(!h.step(true, false, false, out, back)); // and the memory went with it: nothing to put him back to
}

TEST(transition_hold_without_a_good_place_does_nothing)
{
	Hold h;
	const float out[3] = {40.f, 0.f, 9.f};
	float back[3] = {0, 0, 0};
	CHECK(!h.step(true, true, false, out, back)); // the zone itself is off the map: no place to put him back to
}

// ---------------------------------------------------------------- what the player wants against what the host says

TEST(transition_intent_says_ready_once_and_refreshes)
{
	Intent i;
	CHECK(i.wants(true, kA, false, 0, 100) == Send::Ready); // not known to the host yet
	i.sent(100);
	CHECK(i.wants(true, kA, true, kA, 200) == Send::Nothing); // the host says ready: quiet
	CHECK(i.wants(true, kA, true, kA, 100 + kClaimRefreshMs - 1) == Send::Nothing);
	CHECK(i.wants(true, kA, true, kA, 100 + kClaimRefreshMs) == Send::Ready); // the refresh
	i.sent(100 + kClaimRefreshMs);
	CHECK(i.wants(true, kA, true, kA, 200 + kClaimRefreshMs) == Send::Nothing);
}

TEST(transition_intent_cancels_and_corrects)
{
	Intent i;
	CHECK(i.wants(false, 0, false, 0, 100) == Send::Nothing); // nothing wanted, nothing known
	CHECK(i.wants(false, 0, true, kA, 100) == Send::Cancel); // the host thinks I am ready, I am not
	CHECK(i.wants(true, kB, true, kA, 100) == Send::Ready); // the host has me at another exit
	CHECK(i.wants(true, kA, false, 0, 100) == Send::Ready); // a lost message: say it again
}

TEST(transition_intent_gives_the_host_a_moment_to_answer)
{
	Intent i;
	CHECK(i.wants(true, kA, false, 0, 100) == Send::Ready);
	i.sent(100);
	// the host's board has not said "ready" yet (its message is on the way): saying it again each frame would burn the pace
	CHECK(i.wants(true, kA, false, 0, 100 + 16) == Send::Nothing);
	CHECK(i.wants(true, kA, false, 0, 100 + kIntentSettleMs - 1) == Send::Nothing);
	CHECK(i.wants(true, kA, false, 0, 100 + kIntentSettleMs) == Send::Ready); // it did not take: again
	CHECK(i.wants(false, 0, true, kA, 100 + 16) == Send::Nothing); // the same for a cancel
	CHECK(i.wants(false, 0, true, kA, 100 + kIntentSettleMs) == Send::Cancel);
}

TEST(transition_intent_forgets_on_reset)
{
	Intent i;
	i.sent(100);
	i.reset(); // a new world: the refresh clock starts over
	CHECK(i.wants(true, kA, true, kA, 100 + kClaimRefreshMs) == Send::Nothing);
}
