// Anomaly Coop unit tests: the waiting point of a level change (coop_transition.h; owner 2026-10-23: "a place where you
// wait for your allies to go to the next level"). The host's board of who is ready for which exit and when the group
// goes (everybody, the loading players' 60 s, the 5 s countdown, "go now"), the two messages (TransitionVote ops and the
// host's TransitionState), the hold at the exit and the client's reconciling of what it wants with what the host says.
// F3a T8: the board through the local link (the host player is peer 0 and votes like anybody), the rows of the together
// entry of split levels, and the simultaneous load of a group transition (PreparedLoad on the server, LoadScreen on each
// player, and the order of LoadWait / epoch / save on a real session that the host's "go" relies on).
#include "test_util.h"

#include "coop_levels_wire.h"
#include "coop_limits.h"
#include "coop_local_link.h"
#include "coop_session.h"
#include "coop_transition.h"
#include "coop_world_gate.h"

#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

using namespace coop;
using namespace coop::transition;
using t::Node;

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

// ---------------------------------------------------------------- F3a T8: the board through the local link

namespace
{
VoteMsg vote_ready(uint32_t exit)
{
	VoteMsg v;
	v.op = VoteReady;
	v.changer = uint16_t(exit);
	return v;
}

VoteMsg vote_cancel()
{
	VoteMsg v;
	v.op = VoteCancel;
	return v;
}

VoteFacts near_exit()
{
	VoteFacts f;
	f.in_world = true;
	f.exit_known = true;
	f.dist = 1.f;
	return f;
}
} // namespace

TEST(board_host_claim_via_link)
{
	// The host player is peer 0 of the server's players(), a member like any other: no claim of his own until his vote comes
	// over the local link, and that vote goes through the same rule as a remote client's (from = 0).
	Board b;
	const auto m = party({0, 1});
	CHECK(apply_vote(b, 1, vote_ready(kA), near_exit(), 100) == Verdict::Claimed);
	Status s = b.tick(m, kNear, 100);
	CHECK_EQ(int(row_of(s, 0).mark), int(Mark::Away)); // being the host makes him ready for nothing
	CHECK_EQ(s.ready, 1u);
	CHECK_EQ(s.total, 2u);
	CHECK(apply_vote(b, 0, vote_ready(kA), near_exit(), 200) == Verdict::Claimed); // his vote
	s = b.tick(m, kNear, 200);
	CHECK_EQ(int(row_of(s, 0).mark), int(Mark::Ready));
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK(apply_vote(b, 0, vote_ready(kA), near_exit(), 5200) == Verdict::Refreshed); // his refresh keeps the claim's age
	CHECK(apply_vote(b, 0, vote_ready(kB), near_exit(), 5300) == Verdict::Claimed); // another exit replaces it
	CHECK(apply_vote(b, 0, vote_cancel(), VoteFacts(), 5400) == Verdict::Released); // a cancel needs no facts
	CHECK(apply_vote(b, 0, vote_cancel(), VoteFacts(), 5400) == Verdict::Nothing);
	s = b.tick(m, kNear, 5500);
	CHECK(s.cancelled);
	CHECK_EQ(int(row_of(s, 0).mark), int(Mark::Away));
	// the same checks as anybody's
	VoteFacts out = near_exit();
	out.in_world = false;
	CHECK(apply_vote(b, 0, vote_ready(kA), out, 6000) == Verdict::NotInWorld);
	VoteFacts nowhere = near_exit();
	nowhere.exit_known = false;
	CHECK(apply_vote(b, 0, vote_ready(kA), nowhere, 6000) == Verdict::NoExit);
	VoteFacts far = near_exit();
	far.dist = kReachM + 0.5f;
	CHECK(apply_vote(b, 0, vote_ready(kA), far, 6000) == Verdict::TooFar);
	VoteFacts edge = near_exit();
	edge.dist = kReachM;
	CHECK(apply_vote(b, 0, vote_ready(kA), edge, 6000) == Verdict::Claimed);
	VoteFacts unknown = near_exit();
	unknown.dist = -1.f;
	CHECK(apply_vote(b, 1, vote_ready(kB), unknown, 6000) == Verdict::TooFar); // no distance, no claim on the exit's map
	uint32_t goal = 0;
	CHECK(b.claimed(1, &goal) && goal == kA); // a refused vote leaves the claim he had
	// a guide trip: a ready without an exit is a yes, only while the trip runs
	VoteMsg yes;
	yes.op = VoteReady;
	yes.changer = kNoChanger;
	CHECK(apply_vote(b, 1, yes, near_exit(), 7000) == Verdict::NoGuide);
	VoteFacts trip = near_exit();
	trip.guide_running = true;
	trip.dist = -1.f; // no exit, no distance
	CHECK(apply_vote(b, 1, yes, trip, 7000) == Verdict::Claimed);
	CHECK(b.claimed(1, &goal) && goal == kGuideGoal);
}

TEST(together_on_target_not_counted)
{
	// The together entry (split levels): who already stands on the level the exit leads to does not go, is not waited for and
	// has no row; a claim of his means nothing.
	Board b;
	auto m = party({0, 1, 2});
	m[2].on_target = true;
	b.claim(0, kA, 0);
	b.claim(1, kA, 0);
	Status s = b.tick(m, kNear, 10);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.ready, 2u);
	CHECK_EQ(s.total, 2u);
	CHECK_EQ(s.rows.size(), size_t(2));
	CHECK_EQ(row_of(s, 2).id, 0xdeadbeefu);
	b.claim(2, kA, 20);
	s = b.tick(m, kNear, 30);
	CHECK(!b.claimed(2));
	CHECK_EQ(s.total, 2u);
	CHECK_EQ(int(s.state), int(State::Counting));
	m[2].on_target = false; // he left that level: he is waited for again
	s = b.tick(m, kNear, 40);
	CHECK_EQ(int(s.state), int(State::Waiting));
	CHECK_EQ(s.total, 3u);
	CHECK_EQ(int(row_of(s, 2).mark), int(Mark::Away));
}

TEST(together_remote_confirm)
{
	// A player on another map says yes with the exit's id: no distance is asked of him (he is not near it), the board does
	// not drop his claim for being far, his row has no metres.
	Board b;
	auto m = party({0, 1});
	m[1].other_map = true;
	VoteFacts there;
	there.in_world = true;
	there.exit_known = true;
	there.other_map = true; // dist unknown
	CHECK(apply_vote(b, 1, vote_ready(kA), there, 0) == Verdict::Claimed);
	VoteFacts far_there = there;
	far_there.dist = 900.f;
	CHECK(apply_vote(b, 1, vote_ready(kA), far_there, 10) == Verdict::Refreshed);
	b.claim(0, kA, 5);
	const DistFn far = [](uint32_t id, uint32_t) { return id == 1 ? 900.f : 1.f; };
	const Status s = b.tick(m, far, 20);
	CHECK(b.claimed(1));
	CHECK_EQ(int(row_of(s, 1).mark), int(Mark::Ready));
	CHECK_EQ(row_of(s, 1).dist_m, kUnknownDist);
	CHECK_EQ(int(s.state), int(State::Counting));
	CHECK_EQ(s.ready, 2u);
	// on the exit's own map the same vote needs the distance
	VoteFacts here = there;
	here.other_map = false;
	CHECK(apply_vote(b, 1, vote_ready(kA), here, 30) == Verdict::TooFar);
}

TEST(together_row_flags)
{
	Board b;
	auto m = party({0, 1, 2});
	m[2].other_map = true;
	b.claim(0, kA, 0);
	const Status s = b.tick(m, kNear, 10);
	CHECK(!row_of(s, 0).other_map);
	CHECK(!row_of(s, 1).other_map);
	CHECK(row_of(s, 2).other_map);
	CHECK_EQ(int(row_of(s, 2).mark), int(Mark::Away));
	const StateMsg msg = state_message(s, "l01_escape");
	Writer w;
	msg.write(w);
	// the flag rides in the high bit of the mark byte: the layout of protocol 10 (7 bytes a row) stays
	StateMsg plain = msg;
	for (Row& r : plain.rows)
		r.other_map = false;
	Writer w0;
	plain.write(w0);
	CHECK_EQ(w.size(), w0.size());
	CHECK(w.data() != w0.data());
	Reader r = reader_of(w);
	StateMsg back;
	CHECK(back.read(r));
	CHECK_EQ(back.rows.size(), size_t(3));
	if (back.rows.size() == 3)
	{
		CHECK(!back.rows[0].other_map);
		CHECK(!back.rows[1].other_map);
		CHECK(back.rows[2].other_map);
		CHECK_EQ(int(back.rows[2].mark), int(Mark::Away));
	}
	// a mark nobody knows is refused with the flag set as without it
	std::vector<uint8_t> bytes(w.data());
	bytes[bytes.size() - 3] = uint8_t(kRowOtherMap | 77); // the mark byte of the last row (u32 id, u8 mark, u16 dist)
	Reader r2(bytes.data(), bytes.size());
	StateMsg bad;
	CHECK(!bad.read(r2));
}

// ---------------------------------------------------------------- F3a T8: the simultaneous load, the server's side

namespace
{
using Peers = std::vector<uint32_t>;
using Rows = std::vector<std::pair<uint32_t, bool>>;
constexpr uint32_t kOldWorld = 1; // this machine's world generation (join::world_generation) at LoadWait Prepared
constexpr uint32_t kNewWorld = 2; // ... once the transition's world is created
} // namespace

TEST(load_enter_together)
{
	PreparedLoad l;
	l.start(5, {0, 1, 2}, 1000);
	CHECK(l.active());
	CHECK_EQ(l.epoch(), 5u);
	CHECK(l.is_mover(0) && l.is_mover(1) && l.is_mover(2) && !l.is_mover(3));
	CHECK(l.take_entering(1000).empty()); // the server's world is not up: nobody enters a world that is not there
	CHECK(l.ready(1, 5)); // 1 loaded before the host: his LoadReady waited in the world gate and replayed
	CHECK(!l.ready(1, 5)); // again: nothing new
	CHECK(!l.ready(2, 4)); // another epoch is not an answer
	CHECK(!l.ready(3, 5)); // not a mover
	CHECK(l.take_entering(20000).empty());
	l.world_up(31000); // the server's world, and the host player with it
	CHECK(l.world_is_up());
	CHECK(l.is_ready(0) && l.is_ready(1) && !l.is_ready(2));
	CHECK(l.rows() == (Rows{{0, true}, {1, true}, {2, false}}));
	CHECK(l.take_entering(31000).empty()); // 2 is still loading
	CHECK(!l.finished());
	CHECK(l.ready(2, 5));
	CHECK(l.take_entering(32000) == (Peers{0, 1, 2})); // all at once
	CHECK(l.entered(0) && l.entered(1) && l.entered(2));
	CHECK(l.take_entering(32100).empty());
	CHECK(l.finished());
	l.clear();
	CHECK(!l.active());
	CHECK(!l.ready(1, 5));
}

TEST(load_minute_counts_from_the_server_world)
{
	PreparedLoad l;
	l.start(5, {0, 1, 2}, 0);
	CHECK(l.ready(1, 5));
	l.world_up(70000); // the host loaded for 70 s: the others' minute starts now, not at the go
	CHECK(l.is_ready(1)); // and who was ready stays ready
	CHECK(l.take_entering(70000).empty());
	CHECK(l.take_entering(129999).empty());
	CHECK(l.take_entering(130000) == (Peers{0, 1})); // a minute after the server's world: who is ready goes
	CHECK(!l.finished());
	CHECK(l.take_entering(140000).empty());
	CHECK(l.ready(2, 5)); // the laggard enters alone
	CHECK(l.take_entering(150000) == (Peers{2}));
	CHECK(l.finished());
}

TEST(load_a_mover_who_never_reports_holds_nobody_beyond_the_minute)
{
	PreparedLoad l;
	l.start(9, {0, 1, 2}, 0);
	l.world_up(10000);
	CHECK(l.ready(1, 9));
	CHECK(l.take_entering(69999).empty());
	CHECK(l.take_entering(70000) == (Peers{0, 1}));
	CHECK(!l.finished()); // 2 never said a word
	l.drop(2); // he left, or asked for the world the usual way
	CHECK(!l.is_mover(2));
	CHECK(l.rows() == (Rows{{0, true}, {1, true}}));
	CHECK(l.finished());
	// a mover dropped before the server's world is up is not waited for at all
	PreparedLoad k;
	k.start(3, {0, 4}, 0);
	k.drop(4);
	k.world_up(500);
	CHECK(k.take_entering(500) == (Peers{0}));
	CHECK(k.finished());
}

TEST(load_a_new_go_replaces_the_old_load)
{
	PreparedLoad l;
	l.start(5, {0, 1, 2}, 0);
	l.world_up(100);
	l.ready(1, 5);
	l.start(6, {0, 1}, 200); // the group moves again before 2 was in (he is no mover of this one)
	CHECK_EQ(l.epoch(), 6u);
	CHECK(!l.world_is_up());
	CHECK(!l.is_ready(1));
	CHECK(!l.is_mover(2));
	CHECK(!l.ready(1, 5));
	CHECK(l.ready(1, 6));
}

// ---------------------------------------------------------------- F3a T8: the simultaneous load, a player's screen

TEST(load_screen_holds_from_the_save_to_enter)
{
	LoadScreen sc;
	CHECK(!sc.holds());
	CHECK(sc.prepared(5, true, 1000, kOldWorld)); // a remote client: the save comes as a blob
	CHECK(sc.stage == Load::Waiting);
	CHECK(!sc.holds()); // still in the old world while the save comes
	CHECK(!sc.world_up(1500, kNewWorld)); // nothing to say before the save is loading
	CHECK(sc.loading()); // the save came, its load is issued
	CHECK(!sc.loading());
	CHECK(sc.holds());
	CHECK(sc.world_up(20000, kNewWorld)); // LoadReady now
	CHECK(!sc.world_up(20001, kNewWorld)); // once
	CHECK(sc.stage == Load::Holding);
	CHECK(sc.holds());
	CHECK(!sc.enter(4, 30000)); // another epoch's Enter
	CHECK(sc.holds());
	CHECK(sc.enter(5, 30000));
	CHECK(!sc.holds());
	CHECK(sc.stage == Load::Entering);
	// an Enter that comes while the world still loads: the screen goes as soon as the world is up, without a hold
	LoadScreen early;
	early.prepared(7, true, 0, kOldWorld);
	early.loading();
	CHECK(early.enter(7, 100));
	CHECK(early.stage == Load::Entering);
	CHECK(!early.holds());
	CHECK(!early.world_up(200, kNewWorld));
}

TEST(load_screen_says_ready_again_until_enter)
{
	LoadScreen sc;
	CHECK(sc.prepared(5, false, 0, kOldWorld)); // the host player: his process loads the world itself
	CHECK(sc.stage == Load::Loading);
	CHECK(sc.local);
	CHECK(sc.holds());
	CHECK(sc.world_up(1000, kNewWorld));
	CHECK(!sc.repeat(1000 + kLoadReadyRepeatMs - 1));
	CHECK(sc.repeat(1000 + kLoadReadyRepeatMs));
	CHECK(!sc.repeat(1000 + kLoadReadyRepeatMs + 1));
	CHECK(sc.repeat(1000 + 2 * kLoadReadyRepeatMs));
	CHECK(sc.enter(5, 9000));
	CHECK(!sc.repeat(1000 + 10 * kLoadReadyRepeatMs));
}

TEST(load_screen_enters_alone_only_after_the_server_world_was_up)
{
	LoadScreen sc;
	sc.prepared(5, true, 0, kOldWorld);
	sc.loading();
	sc.world_up(10000, kNewWorld); // the client is up long before the host
	CHECK(!sc.alone(10000 + 600000)); // no word from the server's world: nobody plays in a world the host is not in
	sc.waiting(5, Rows{{0, true}, {1, true}, {2, false}}, 50000); // the server's world is up, 2 is missing
	CHECK_EQ(sc.host_up_at, uint64_t(50000));
	CHECK(sc.waiting_for == (Peers{2}));
	sc.waiting(5, Rows{{0, true}, {1, true}, {2, false}}, 50500);
	CHECK_EQ(sc.host_up_at, uint64_t(50000)); // the first word counts
	CHECK(!sc.alone(50000 + kLoadWaitMs + kLoadAloneGraceMs - 1));
	CHECK(sc.alone(50000 + kLoadWaitMs + kLoadAloneGraceMs));
	// the host player: his own world is the server's
	LoadScreen h;
	h.prepared(5, false, 0, kOldWorld);
	h.world_up(30000, kNewWorld);
	CHECK(!h.alone(30000 + kLoadWaitMs + kLoadAloneGraceMs - 1));
	CHECK(h.alone(30000 + kLoadWaitMs + kLoadAloneGraceMs));
	// not holding: nothing to let go
	LoadScreen idle;
	CHECK(!idle.alone(10000000));
}

TEST(load_screen_other_epochs_change_nothing)
{
	LoadScreen sc;
	CHECK(sc.prepared(5, true, 0, kOldWorld));
	CHECK(!sc.prepared(5, true, 10, kOldWorld)); // the same again
	CHECK(!sc.prepared(4, true, 10, kOldWorld)); // an older one
	sc.waiting(4, Rows{{2, false}}, 20);
	CHECK_EQ(sc.host_up_at, uint64_t(0));
	CHECK(sc.waiting_for.empty());
	CHECK(!sc.cancel(4));
	CHECK(sc.stage == Load::Waiting);
	CHECK(sc.cancel(5));
	CHECK(sc.stage == Load::None);
	CHECK(!sc.holds());
	CHECK(sc.prepared(6, true, 30, kOldWorld)); // a newer transition starts over
	CHECK(sc.stage == Load::Waiting);
	CHECK_EQ(sc.epoch, 6u);
}

TEST(load_screen_lost_save_asks_for_the_world)
{
	LoadScreen sc;
	sc.prepared(5, true, 0, kOldWorld);
	sc.progress(5000);
	CHECK(!sc.stalled(500000)); // the server's world is not up: its own load may be what holds the rest of the save
	sc.waiting(5, Rows{{0, true}, {1, false}}, 60000);
	CHECK(!sc.stalled(60000 + kLoadBlobStallMs - 1));
	sc.progress(80000); // still coming
	CHECK(!sc.stalled(80000 + kLoadBlobStallMs - 1));
	CHECK(sc.stalled(80000 + kLoadBlobStallMs));
	CHECK(sc.loading()); // it came after all
	CHECK(!sc.stalled(900000));
}

// ---------------------------------------------------------------- F3a T8: the order of the "go" on a real session

namespace
{
Writer load_wait(uint8_t state, uint32_t epoch, uint16_t level)
{
	levels::wire::LoadWaitMsg m;
	m.state = state;
	m.epoch = epoch;
	m.level = level;
	Writer w;
	CHECK(m.write(w));
	return w;
}
} // namespace

// The world server's "go" (coop_join.cpp host_prepare): LoadWait Prepared to a moving client while he is still in the old
// epoch (a game message to a client of another epoch is not sent), then the epoch, then the save (a blob carries the epoch it
// was queued in: queued before the move it would be cancelled by it). The client takes the new epoch from the LoadWait, so
// the save completes there.
TEST(load_prepared_world_reaches_the_client_across_the_epoch_move)
{
	Node host("Boss", 37801), cl("Alice", 37801);
	REQUIRE(host.host());
	host.s.set_world_epoch(3);
	REQUIRE(cl.connect(37801));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
	const PeerId id = host.s.peers()[0].id;
	CHECK_EQ(cl.s.world_epoch(), 3u);
	std::vector<uint32_t> prepared;
	cl.s.on(Msg::LoadWait, [&](PeerId from, Reader& r) {
		levels::wire::LoadWaitMsg m;
		CHECK_EQ(from, kHostPeer);
		if (m.read(r) && m.state == levels::wire::LoadWaitMsg::Prepared)
		{
			prepared.push_back(m.epoch);
			cl.s.set_world_epoch(m.epoch); // as client_on_load_wait
		}
	});
	host.s.send(id, Lane::Reliable, Msg::LoadWait, load_wait(levels::wire::LoadWaitMsg::Prepared, 4, 7));
	host.s.set_world_epoch(4);
	host.s.send_blob(id, 2, t::random_bytes(300000, 7)); // join::BlobPreparedSave
	// what is sent to him after the move and before he follows does not reach him
	host.s.send(id, Lane::Reliable, Msg::LoadWait, load_wait(levels::wire::LoadWaitMsg::Prepared, 99, 7));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 10000, [&] { return !cl.blobs.empty(); }));
	CHECK(prepared == (std::vector<uint32_t>{4}));
	CHECK_EQ(cl.blobs[0].kind, 2u);
	CHECK_EQ(cl.blobs[0].data.size(), size_t(300000));
	CHECK_EQ(cl.s.world_epoch(), 4u);
	CHECK(host.logged("not sent until it rejoins"));
}

// Plan §1.5 step 7: a LoadReady of the new epoch that comes while the server still builds its world waits in the world gate
// (LoadReady = Hold) and runs when the world is up, from a remote client and from the host player over the local link.
TEST(load_ready_before_the_server_world_waits_and_replays)
{
	LocalLink link; // outlives the session it is attached to
	Node host("Boss", 37802), cl("Alice", 37802);
	REQUIRE(host.host());
	host.s.set_world_epoch(4);
	wgate::World world = wgate::World::Hole; // the host's process loads the world of the transition
	host.s.set_world_gate([&] { return world; });
	std::vector<std::pair<PeerId, uint32_t>> ready;
	host.s.on(Msg::LoadReady, [&](PeerId from, Reader& r) {
		levels::wire::LoadReadyMsg m;
		if (m.read(r))
			ready.emplace_back(from, m.epoch);
	});
	REQUIRE(cl.connect(37802));
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return cl.s.is_active() && host.s.peers().size() == 1; }));
	const PeerId id = host.s.peers()[0].id;
	levels::wire::LoadReadyMsg m;
	m.epoch = 4;
	Writer w;
	m.write(w);
	cl.s.send(kHostPeer, Lane::Reliable, Msg::LoadReady, w);
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return host.s.world_gate_stats().queued == 1; }));
	CHECK(ready.empty());
	world = wgate::World::Up;
	REQUIRE(t::pump_until({&host.s, &cl.s}, 5000, [&] { return !ready.empty(); }));
	CHECK(ready[0] == (std::pair<PeerId, uint32_t>{id, 4u}));
	// the host player's, over the link
	host.s.attach_local(&link);
	world = wgate::World::Hole;
	REQUIRE(link.push_to_server(Msg::LoadReady, Lane::Reliable, w));
	host.s.update(t::now_ms());
	CHECK_EQ(ready.size(), size_t(1));
	CHECK_EQ(host.s.world_gate_stats().queued, size_t(1));
	world = wgate::World::Up;
	host.s.update(t::now_ms());
	REQUIRE(ready.size() == 2);
	CHECK(ready[1] == (std::pair<PeerId, uint32_t>{kHostPeer, 4u}));
	host.s.attach_local(nullptr);
}

// The host player's LoadWait goes over the local link AFTER the epoch move: a link packet carries the epoch it was pushed in
// and one of an older epoch is dropped at the pump (F3a T4 R1).
TEST(load_wait_to_the_host_player_goes_after_the_epoch_move)
{
	LocalLink link;
	Node host("Boss", 37803);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	host.s.set_world_epoch(4);
	std::vector<uint32_t> got;
	link.on(Msg::LoadWait, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		levels::wire::LoadWaitMsg m;
		if (m.read(r))
			got.push_back(m.epoch);
	});
	host.s.send(kHostPeer, Lane::Reliable, Msg::LoadWait, load_wait(levels::wire::LoadWaitMsg::Prepared, 5, 7)); // too early
	host.s.set_world_epoch(5);
	host.s.send(kHostPeer, Lane::Reliable, Msg::LoadWait, load_wait(levels::wire::LoadWaitMsg::Prepared, 5, 7));
	host.s.update(t::now_ms());
	CHECK(got == (std::vector<uint32_t>{5}));
	CHECK_EQ(link.stats().stale, uint64_t(1));
	host.s.attach_local(nullptr);
}

// F3a T8 moved the board and the load onto the host player's local link (coop_local_link.h kLinkMessages): with the game's
// gate his vote reaches the world server's handler from peer 0 and the board, LoadWait come back to his handlers.
TEST(board_vote_and_state_travel_the_gated_link)
{
	const Msg moved[] = {Msg::TransitionVote, Msg::TransitionState, Msg::LoadWait, Msg::LoadReady};
	for (Msg m : moved)
		CHECK(link_enabled(m));
	LocalLink link;
	link.set_gate(&link_enabled);
	Node host("Boss", 37804);
	REQUIRE(host.host());
	host.s.attach_local(&link);
	std::vector<PeerId> votes_from;
	host.s.on(Msg::TransitionVote, [&](PeerId from, Reader& r) {
		VoteMsg v;
		CHECK(v.read(r));
		votes_from.push_back(from);
	});
	std::vector<StateMsg> boards;
	link.on(Msg::TransitionState, [&](PeerId from, Reader& r) {
		CHECK_EQ(from, kHostPeer);
		StateMsg m;
		CHECK(m.read(r));
		boards.push_back(m);
	});
	int waits = 0;
	link.on(Msg::LoadWait, [&](PeerId, Reader&) { ++waits; });
	Writer vote;
	vote_ready(kA).write(vote);
	REQUIRE(link.push_to_server(Msg::TransitionVote, Lane::Reliable, vote));
	Board b;
	b.claim(0, kA, 0);
	Writer board;
	state_message(b.tick(party({0}), kNear, 10), "l01_escape").write(board);
	host.s.broadcast(Lane::Reliable, Msg::TransitionState, board); // the server's broadcast reaches the host player too
	host.s.send(kHostPeer, Lane::Reliable, Msg::LoadWait, load_wait(levels::wire::LoadWaitMsg::Enter, 0, 7));
	host.s.update(t::now_ms());
	CHECK(votes_from == (std::vector<PeerId>{kHostPeer}));
	REQUIRE(boards.size() == 1);
	CHECK_EQ(boards[0].rows.size(), size_t(1));
	CHECK_EQ(waits, 1);
	CHECK_EQ(link.stats().refused, uint64_t(0));
	host.s.attach_local(nullptr);
}

namespace
{
// engine/src/xrGame/coop/<name>, next to this source file (tests\ -> ..\engine\src\xrGame\coop)
std::string coop_source(const char* name)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../engine/src/xrGame/coop/" + name, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

std::string coop_join_source() { return coop_source("coop_join.cpp"); }

// The text of the function whose definition starts with `head` (a declaration of it is skipped), up to its closing brace at
// the start of a line; "" if none.
std::string body_of(const std::string& src, const std::string& head)
{
	for (size_t at = src.find(head); at != std::string::npos; at = src.find(head, at + 1))
	{
		const size_t close = src.find(')', at);
		const size_t next = close == std::string::npos ? std::string::npos : src.find_first_not_of(" \t\r\n", close + 1);
		if (next == std::string::npos || src[next] != '{')
			continue; // a declaration
		const size_t end = src.find("\n}", at);
		return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
	}
	return std::string();
}
} // namespace

// Review Focus 1 (plan §5): with TransitionVote / TransitionState on the link the host player's claim and placard travel
// it; the host's process must not also claim for him on the board, release his claim or set his placard directly.
TEST(board_host_direct_path_gone)
{
	const std::string src = coop_join_source();
	REQUIRE(src.size() > 10000);
	CHECK(src.find("g.board.claim(0, goal, now)") == std::string::npos); // transition_step's own claim
	CHECK(src.find("g.board.release(0)") == std::string::npos); // transition_step / transition_cancel's own release
	CHECK(src.find("g.view = transition::state_message") == std::string::npos); // the host's placard from the board itself
	CHECK(src.find("Msg::TransitionVote, w);") != std::string::npos); // every player votes with the message
}

// ---------------------------------------------------------------- F3a T8, fix round 1

// R1 4: a frame of the old world never counts as the new world's readiness: the screen reaches Holding only in a world
// created after its LoadWait Prepared (the host player's process still runs the old level for a frame or two after the go).
TEST(load_screen_old_world_is_no_readiness)
{
	LoadScreen h;
	CHECK(h.prepared(5, false, 0, kOldWorld)); // the host player: his process is still in the old world
	CHECK(!h.world_up(100, kOldWorld)); // the old world is up: no LoadReady from it
	CHECK(h.stage == Load::Loading);
	CHECK(h.holds());
	CHECK(h.world_up(30000, kNewWorld)); // the transition's world
	CHECK(h.stage == Load::Holding);
	LoadScreen c;
	c.prepared(6, true, 0, kOldWorld);
	c.loading();
	CHECK(!c.world_up(500, kOldWorld));
	CHECK(c.world_up(20000, kNewWorld));
}

// R1 3: the pump before the host's reload is done when the movers' saves are handed to the network. The session counts the
// BlobChunk bytes it sends (2 bytes of type, 4 of blob id, then data); after the go's epoch move only the movers' saves
// stream (every other blob is cut by the move and ends with no chunk more), so the data bytes sent since the pump began
// reach the movers' total exactly when each mover's save is handed over (none can send more than its own size). Another
// peer's cut blob ending (a BlobEnd) does not count.
TEST(load_saves_handed_counts_the_movers_data_only)
{
	const uint64_t two_saves = 2000000 + 1500000;
	const uint64_t chunks = (2000000 + 65535) / 65536 + (1500000 + 65535) / 65536;
	CHECK(!saves_handed(0, 0, two_saves));
	CHECK(saves_handed(two_saves + chunks * kBlobChunkHeader, chunks, two_saves)); // every chunk of both went out
	// one save short of its last 100 bytes (sent in a chunk of its own): not yet, however many headers came with the rest
	CHECK(!saves_handed(two_saves - 100 + (chunks - 1) * kBlobChunkHeader, chunks - 1, two_saves));
	CHECK(!saves_handed(two_saves - 1 + chunks * kBlobChunkHeader, chunks, two_saves));
	CHECK(saves_handed(0, 0, 0)); // nothing to hand over
}

// R1 5: the reload follows the go within a frame or two (MakeReconnect is a deferred engine event); frames that still run
// kReloadWatchMs after the saves went out mean no reload is coming: the prepared load is called off, so a later unrelated
// world is not taken for the transition's.
TEST(load_reload_watchdog)
{
	CHECK(!reload_overdue(false, 1000, 1000 + kReloadWatchMs * 10)); // nothing pending
	CHECK(!reload_overdue(true, 0, 999999)); // the pump has not ended
	CHECK(!reload_overdue(true, 1000, 1000 + kReloadWatchMs - 1));
	CHECK(reload_overdue(true, 1000, 1000 + kReloadWatchMs));
	CHECK(kReloadWatchMs >= 5000 && kReloadWatchMs <= 30000);
}

// R1 6: the order of the go (host_prepare), read in the source: LoadWait Prepared to the movers while they are in the old
// epoch, then the epoch, then their saves (a blob carries the epoch it is queued in), then the host player's LoadWait over
// the link (a link packet of an older epoch is dropped). Each step of another order loses the message (tests above).
TEST(load_go_order_in_the_source)
{
	const std::string go = body_of(coop_join_source(), "void host_prepare(");
	REQUIRE(!go.empty());
	const size_t to_movers = go.find("host_load_send(m.peer, prepared)");
	const size_t epoch = go.find("s.set_world_epoch(epoch)");
	const size_t saves = go.find("s.send_blob(m.peer, BlobPreparedSave");
	const size_t to_host = go.find("host_load_send(kHostPeer, prepared)");
	CHECK(to_movers != std::string::npos && epoch != std::string::npos && saves != std::string::npos &&
	    to_host != std::string::npos);
	CHECK(to_movers < epoch);
	CHECK(epoch < saves);
	CHECK(saves < to_host);
}

// R1 1: behind a held loading screen nobody plays: the stock "press any key" pauses the game, a session never pauses
// (G18), so the hold itself keeps the player's actor out of harm (the CActor::Hit choke point) and the level from his input.
TEST(load_held_screen_blocks_hits_and_input)
{
	const std::string hit = body_of(coop_source("coop_events.cpp"), "bool client_block_actor_hit(");
	REQUIRE(!hit.empty());
	const size_t first = hit.find('{');
	const size_t held = hit.find("hold_loading_screen()");
	CHECK(held != std::string::npos);
	CHECK(held != std::string::npos && hit.find(';', first) > held); // the first statement of the hook
	const std::string join = coop_join_source();
	const std::string input = body_of(join, "void load_screen_input(");
	CHECK(input.find("g_bDisableAllInput = true") != std::string::npos);
	CHECK(input.find("DeactivateSoft") != std::string::npos);
	const std::string step = body_of(join, "void player_load_step(");
	CHECK(step.find("load_screen_input(g.screen.holds())") != std::string::npos);
	CHECK(body_of(join, "void load_screen_off(").find("load_screen_input(false)") != std::string::npos);
	CHECK(body_of(join, "void on_session_lost(").find("load_screen_input(false)") != std::string::npos);
}

// R1 2: the client's join time limit (kJoinTimeoutMs) measures his own download and load; a screen held for the others
// starts it again (that wait has its own bound: the server's minute, then alone()).
TEST(load_join_clock_restarts_on_the_held_screen)
{
	const std::string step = body_of(coop_join_source(), "void player_load_step(");
	REQUIRE(!step.empty());
	const size_t up = step.find("g.screen.world_up(now");
	const size_t clock = step.find("g.receive_started = now");
	CHECK(up != std::string::npos && clock != std::string::npos && up < clock);
}

// R1 5: the watchdog runs every frame on the host and calls the load off through the one way out (host_load_void); then
// everybody rejoins this world by the world-change path (a SessionReset of the epoch the go gave: a player still in the
// old epoch must hear it too, which a rejoin of the movers alone would miss).
TEST(load_reload_watchdog_in_the_source)
{
	const std::string join = coop_join_source();
	const std::string watch = body_of(join, "void host_load_watch(");
	REQUIRE(!watch.empty());
	CHECK(watch.find("reload_overdue(") != std::string::npos);
	CHECK(watch.find("host_load_void(") != std::string::npos);
	CHECK(watch.find("sync::host_begin_join(") != std::string::npos);
	CHECK(watch.find("g.reset_pending = true") != std::string::npos);
	CHECK(body_of(join, "void frame(").find("host_load_watch(") != std::string::npos);
}
