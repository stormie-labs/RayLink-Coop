// Anomaly Coop unit tests: the shared sleep decision (coop_rest_rules.h; F3 Task 5, CHECKPOINTS_DEATH.md §4): sleep
// starts only when everybody present rests, nobody fights, nobody is dead and the world allows it.
#include "test_util.h"

#include "coop_rest_rules.h"

using namespace coop::rest;

namespace
{
Member member(uint16_t id, State state, uint8_t hours, bool in_combat = false, bool alive = true)
{
	return Member{id, state, hours, in_combat, alive};
}
} // namespace

TEST(rest_state_names)
{
	CHECK_EQ(std::string(state_name(State::Awake)), std::string("awake"));
	CHECK_EQ(std::string(state_name(State::Resting)), std::string("resting"));
	CHECK_EQ(std::string(state_name(State::Sleeping)), std::string("sleeping"));
}

TEST(rest_all_resting_starts)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 5)}, false);
	CHECK(d.start);
	CHECK_EQ(int(d.hours), 5); // the shortest wish: nobody sleeps longer than they asked
	CHECK(d.block == Block::None);

	// The order of the members does not matter.
	const Decision r = decide({member(2, State::Resting, 5), member(1, State::Resting, 8)}, false);
	CHECK(r.start);
	CHECK_EQ(int(r.hours), 5);

	const Decision three = decide({member(1, State::Resting, 12), member(2, State::Resting, 4), member(3, State::Resting, 9)}, false);
	CHECK(three.start);
	CHECK_EQ(int(three.hours), 4);
}

TEST(rest_one_awake_waits)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Awake, 8)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::NotAll);
	CHECK_EQ(int(d.hours), 0);
}

TEST(rest_newcomer_blocks)
{
	// Review Focus 5: two are resting, a third joins awake: the sleep does not start until they rest too.
	const Decision before = decide({member(1, State::Resting, 8), member(2, State::Resting, 8)}, false);
	CHECK(before.start);
	const Decision after = decide({member(1, State::Resting, 8), member(2, State::Resting, 8), member(3, State::Awake, 8)}, false);
	CHECK(!after.start);
	CHECK(after.block == Block::NotAll);
	const Decision joined = decide(
		{member(1, State::Resting, 8), member(2, State::Resting, 8), member(3, State::Resting, 6)}, false);
	CHECK(joined.start);
	CHECK_EQ(int(joined.hours), 6);
}

TEST(rest_already_sleeping_does_not_restart)
{
	// Somebody already asleep is not "resting": the decision is made once, on the transition.
	const Decision d = decide({member(1, State::Sleeping, 8), member(2, State::Sleeping, 8)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::NotAll);
	const Decision m = decide({member(1, State::Sleeping, 8), member(2, State::Resting, 8)}, false);
	CHECK(!m.start);
}

TEST(rest_combat_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8, true)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::Combat);
	CHECK_EQ(int(d.hours), 0);
}

TEST(rest_world_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8)}, true);
	CHECK(!d.start);
	CHECK(d.block == Block::World);
	CHECK_EQ(int(d.hours), 0);
	// A single player too.
	CHECK(decide({member(1, State::Resting, 8)}, true).block == Block::World);
}

TEST(rest_dead_blocks)
{
	const Decision d = decide({member(1, State::Resting, 8), member(2, State::Resting, 8, false, false)}, false);
	CHECK(!d.start);
	CHECK(d.block == Block::Dead);
	CHECK_EQ(int(d.hours), 0);
	// A dead player who is "awake" blocks as dead, not as "not all".
	CHECK(decide({member(1, State::Resting, 8), member(2, State::Awake, 8, false, false)}, false).block == Block::Dead);
}

TEST(rest_block_priority)
{
	// Dead > Combat > World > NotAll.
	const std::vector<Member> all = {
		member(1, State::Resting, 8, true, true),   // fighting
		member(2, State::Awake, 8, false, false),   // dead
		member(3, State::Awake, 8, false, true),    // not resting
	};
	CHECK(decide(all, true).block == Block::Dead);

	const std::vector<Member> no_dead = {
		member(1, State::Resting, 8, true, true),
		member(3, State::Awake, 8, false, true),
	};
	CHECK(decide(no_dead, true).block == Block::Combat);

	const std::vector<Member> no_fight = {
		member(1, State::Resting, 8, false, true),
		member(3, State::Awake, 8, false, true),
	};
	CHECK(decide(no_fight, true).block == Block::World);
	CHECK(decide(no_fight, false).block == Block::NotAll);
}

TEST(rest_single_player)
{
	const Decision d = decide({member(7, State::Resting, 3)}, false);
	CHECK(d.start);
	CHECK_EQ(int(d.hours), 3);
	CHECK(d.block == Block::None);
	CHECK(!decide({member(7, State::Awake, 3)}, false).start);
}

TEST(rest_nobody_present)
{
	const Decision d = decide({}, false);
	CHECK(!d.start);
	CHECK_EQ(int(d.hours), 0);
	CHECK(d.block == Block::NotAll);
	CHECK(decide({}, true).block == Block::World);
}

TEST(rest_hours_clamp)
{
	CHECK_EQ(int(clamp_hours(0)), 1);
	CHECK_EQ(int(clamp_hours(30)), 24);
	CHECK_EQ(int(clamp_hours(-5)), 1);
	CHECK_EQ(int(clamp_hours(1)), 1);
	CHECK_EQ(int(clamp_hours(12)), 12);
	CHECK_EQ(int(clamp_hours(24)), 24);
	CHECK_EQ(int(clamp_hours(25)), 24);
	CHECK_EQ(int(clamp_hours(1000000)), 24);
	CHECK_EQ(int(clamp_hours(-1000000)), 1);
}

TEST(rest_hours_of_the_decision_are_in_range)
{
	// A member who sent 0 or too much does not make the whole group sleep 0 or 255 hours.
	const Decision zero = decide({member(1, State::Resting, 0), member(2, State::Resting, 8)}, false);
	CHECK(zero.start);
	CHECK_EQ(int(zero.hours), 1);
	const Decision big = decide({member(1, State::Resting, 200), member(2, State::Resting, 255)}, false);
	CHECK(big.start);
	CHECK_EQ(int(big.hours), 24);
}

// ---------------------------------------------------------------- F3 Task 11: refusals, messages, the host's book

namespace
{
coop::Writer request_bytes(uint8_t op, uint8_t hours, uint8_t forced)
{
	coop::Writer w;
	w.u8(op);
	w.u8(hours);
	w.u8(forced);
	return w;
}

bool parse_request(const coop::Writer& w, Request& out)
{
	coop::Reader rd(w.ptr(), w.size());
	return read_request(rd, out);
}

bool parse_state(const coop::Writer& w, StateMsg& out)
{
	coop::Reader rd(w.ptr(), w.size());
	return read_state(rd, out);
}

bool parse_sleep(const coop::Writer& w, uint8_t& out)
{
	coop::Reader rd(w.ptr(), w.size());
	return read_sleep(rd, out);
}

Entry entry(uint16_t character, State state, uint8_t hours)
{
	Entry e;
	e.character = character;
	e.state = state;
	e.hours = hours;
	return e;
}

// RestState bytes written by hand: u8 block, u8 n, n x {u16, u8, u8}, u8 refused.
coop::Writer state_bytes(uint8_t block, std::initializer_list<Entry> entries, uint8_t refused, int n_override = -1)
{
	coop::Writer w;
	w.u8(block);
	w.u8(n_override >= 0 ? uint8_t(n_override) : uint8_t(entries.size()));
	for (const Entry& e : entries)
	{
		w.u16(e.character);
		w.u8(uint8_t(e.state));
		w.u8(e.hours);
	}
	w.u8(refused);
	return w;
}

Seen seen(uint16_t id, bool alive = true, bool in_combat = false)
{
	Seen s;
	s.id = id;
	s.alive = alive;
	s.in_combat = in_combat;
	return s;
}

bool cancelled_with(const Tick& t, uint16_t id, Refusal reason)
{
	for (const Cancel& c : t.cancelled)
		if (c.id == id)
			return c.reason == reason;
	return false;
}
} // namespace

TEST(rest_refusal_names)
{
	CHECK_EQ(std::string(refusal_name(Refusal::Place)), std::string("place"));
	CHECK_EQ(std::string(refusal_name(Refusal::Combat)), std::string("combat"));
	CHECK_EQ(std::string(refusal_name(Refusal::Dead)), std::string("dead"));
	CHECK_EQ(std::string(refusal_name(Refusal::Busy)), std::string("busy"));
	CHECK_EQ(std::string(refusal_name(Refusal::None)), std::string("none"));
	CHECK(refusal_from_name("place") == Refusal::Place);
	CHECK(refusal_from_name("combat") == Refusal::Combat);
	CHECK(refusal_from_name("dead") == Refusal::Dead);
	CHECK(refusal_from_name("busy") == Refusal::Busy);
	// host_cancel with a reason nobody knows still tells the player something he can show.
	CHECK(refusal_from_name("none") == Refusal::Busy);
	CHECK(refusal_from_name("") == Refusal::Busy);
	CHECK(refusal_from_name("Place") == Refusal::Busy);
	CHECK(refusal_from_name(nullptr) == Refusal::Busy);
}

TEST(rest_block_names)
{
	CHECK_EQ(std::string(block_name(Block::None)), std::string("none"));
	CHECK_EQ(std::string(block_name(Block::NotAll)), std::string("not_all"));
	CHECK_EQ(std::string(block_name(Block::Combat)), std::string("combat"));
	CHECK_EQ(std::string(block_name(Block::World)), std::string("world"));
	CHECK_EQ(std::string(block_name(Block::Dead)), std::string("dead"));
}

TEST(rest_lie_down_checks)
{
	// alive, group asleep, forced, in a fight, at a rest place
	CHECK(check_lie_down(true, false, false, false, true) == Refusal::None);
	CHECK(check_lie_down(false, false, false, false, true) == Refusal::Dead);
	CHECK(check_lie_down(true, true, false, false, true) == Refusal::Busy);
	CHECK(check_lie_down(true, false, false, true, true) == Refusal::Combat);
	CHECK(check_lie_down(true, false, false, false, false) == Refusal::Place);
	// The order: dead, busy, combat, place.
	CHECK(check_lie_down(false, true, false, true, false) == Refusal::Dead);
	CHECK(check_lie_down(true, true, false, true, false) == Refusal::Busy);
	CHECK(check_lie_down(true, false, false, true, false) == Refusal::Combat);
	// Passing out of tiredness: no fight or place check, but a dead player or a running sleep still refuse it.
	CHECK(check_lie_down(true, false, true, true, false) == Refusal::None);
	CHECK(check_lie_down(false, false, true, false, false) == Refusal::Dead);
	CHECK(check_lie_down(true, true, true, false, false) == Refusal::Busy);
}

TEST(rest_request_message)
{
	Request in;
	in.op = Op::LieDown;
	in.hours = 7;
	in.forced = true;
	coop::Writer w;
	write_request(w, in);
	CHECK_EQ(int(w.size()), 3);
	Request out;
	REQUIRE(parse_request(w, out));
	CHECK(out.op == Op::LieDown);
	CHECK_EQ(int(out.hours), 7);
	CHECK(out.forced);

	CHECK(parse_request(request_bytes(2, 0, 0), out));
	CHECK(out.op == Op::GetUp);
	CHECK(!out.forced);
	CHECK(parse_request(request_bytes(1, 200, 0), out)); // hours are the host's to clamp
	CHECK_EQ(int(out.hours), 200);

	CHECK(!parse_request(request_bytes(0, 8, 0), out)); // no such op
	CHECK(!parse_request(request_bytes(3, 8, 0), out));
	CHECK(!parse_request(request_bytes(1, 8, 2), out)); // forced is 0 / 1
	coop::Writer longer = request_bytes(1, 8, 0);
	longer.u8(0);
	CHECK(!parse_request(longer, out)); // nothing after
	coop::Writer shorter;
	shorter.u8(1);
	shorter.u8(8);
	CHECK(!parse_request(shorter, out));
}

TEST(rest_state_message)
{
	StateMsg in;
	in.block = Block::Combat;
	in.entries = {entry(0, State::Resting, 8), entry(5, State::Awake, 0), entry(9, State::Sleeping, 3)};
	in.refused = Refusal::Place;
	coop::Writer w;
	write_state(w, in);
	CHECK_EQ(int(w.size()), 3 + 3 * 4);
	StateMsg out;
	REQUIRE(parse_state(w, out));
	CHECK(out.block == Block::Combat);
	REQUIRE(out.entries.size() == 3);
	CHECK(out.entries[0] == entry(0, State::Resting, 8));
	CHECK(out.entries[1] == entry(5, State::Awake, 0));
	CHECK(out.entries[2] == entry(9, State::Sleeping, 3));
	CHECK(out.refused == Refusal::Place);

	// An empty list (nobody present) is a state too.
	CHECK(parse_state(state_bytes(0, {}, 0), out));
	CHECK(out.entries.empty());
	CHECK(out.refused == Refusal::None);
}

TEST(rest_state_message_malformed)
{
	StateMsg out;
	const Entry ok = entry(3, State::Resting, 8);
	CHECK(parse_state(state_bytes(1, {ok}, 0), out));
	CHECK(!parse_state(state_bytes(5, {ok}, 0), out)); // no such block
	CHECK(!parse_state(state_bytes(1, {ok}, 6), out)); // no such refusal (5 is Camp since round 1)
	CHECK(!parse_state(state_bytes(1, {entry(3, State(3), 8)}, 0), out)); // no such state
	CHECK(!parse_state(state_bytes(1, {entry(3, State::Awake, 8)}, 0), out)); // awake has no hours
	CHECK(!parse_state(state_bytes(1, {entry(3, State::Resting, 0)}, 0), out)); // resting has 1..24
	CHECK(!parse_state(state_bytes(1, {entry(3, State::Sleeping, 25)}, 0), out));
	CHECK(!parse_state(state_bytes(1, {entry(0xffff, State::Awake, 0)}, 0), out)); // no object
	CHECK(!parse_state(state_bytes(1, {entry(4, State::Awake, 0), entry(3, State::Awake, 0)}, 0), out)); // order
	CHECK(!parse_state(state_bytes(1, {entry(3, State::Awake, 0), entry(3, State::Awake, 0)}, 0), out)); // twice
	CHECK(!parse_state(state_bytes(1, {ok}, 0, 2), out)); // n says more than follows
	coop::Writer longer = state_bytes(1, {ok}, 0);
	longer.u8(0);
	CHECK(!parse_state(longer, out)); // nothing after
	coop::Writer no_refused;
	no_refused.u8(1);
	no_refused.u8(0);
	CHECK(!parse_state(no_refused, out));

	// More players than a session has.
	coop::Writer many;
	many.u8(0);
	many.u8(uint8_t(coop::kMaxPlayers + 1));
	for (uint16_t i = 0; i <= coop::kMaxPlayers; ++i)
	{
		many.u16(i);
		many.u8(0);
		many.u8(0);
	}
	many.u8(0);
	CHECK(!parse_state(many, out));
}

TEST(rest_state_message_writes_at_most_a_session)
{
	StateMsg in;
	for (uint16_t i = 0; i < 12; ++i)
		in.entries.push_back(entry(i, State::Awake, 0));
	coop::Writer w;
	write_state(w, in);
	StateMsg out;
	REQUIRE(parse_state(w, out));
	CHECK_EQ(out.entries.size(), size_t(coop::kMaxPlayers));
}

TEST(rest_sleep_message)
{
	coop::Writer w;
	write_sleep(w, 6);
	CHECK_EQ(int(w.size()), 1);
	uint8_t h = 0;
	REQUIRE(parse_sleep(w, h));
	CHECK_EQ(int(h), 6);
	coop::Writer zero;
	zero.u8(0);
	CHECK(!parse_sleep(zero, h));
	coop::Writer big;
	big.u8(25);
	CHECK(!parse_sleep(big, h));
	coop::Writer longer;
	longer.u8(5);
	longer.u8(0);
	CHECK(!parse_sleep(longer, h));
	coop::Writer empty;
	CHECK(!parse_sleep(empty, h));
}

TEST(rest_group_lie_down_get_up)
{
	Group g;
	CHECK(g.state_of(1) == State::Awake);
	CHECK(g.lie_down(1, 8, false, false));
	CHECK(g.state_of(1) == State::Resting);
	CHECK_EQ(int(g.hours_of(1)), 8);
	CHECK(!g.forced(1));
	CHECK_EQ(g.resting(), size_t(1));
	// Lying down again takes the new wish.
	CHECK(g.lie_down(1, 5, true, false));
	CHECK_EQ(int(g.hours_of(1)), 5);
	CHECK(g.forced(1));
	// Hours are clamped.
	CHECK(g.lie_down(2, 0, false, false));
	CHECK_EQ(int(g.hours_of(2)), 1);
	CHECK(g.lie_down(3, 30, false, false));
	CHECK_EQ(int(g.hours_of(3)), 24);
	CHECK(g.get_up(1));
	CHECK(g.state_of(1) == State::Awake);
	CHECK_EQ(int(g.hours_of(1)), 0);
	CHECK(!g.get_up(1)); // awake already
}

TEST(rest_group_bounded)
{
	Group g;
	for (uint16_t i = 0; i < coop::kMaxPlayers; ++i)
		CHECK(g.lie_down(i, 8, false, false));
	CHECK(!g.lie_down(100, 8, false, false)); // a ninth rest: more than a session has
	CHECK(g.state_of(100) == State::Awake);
	CHECK(g.lie_down(0, 4, false, false)); // one who rests already may change his wish
}

TEST(rest_group_sleeps_when_all_rest)
{
	Group g;
	CHECK(g.lie_down(0, 8, false, false));
	CHECK(g.lie_down(7, 5, false, false));
	Tick t = g.tick({seen(0), seen(7)}, false, 1000);
	CHECK(t.started);
	CHECK_EQ(int(t.hours), 5);
	CHECK(t.block == Block::None);
	CHECK(t.cancelled.empty());
	CHECK(g.sleeping());
	CHECK(g.state_of(0) == State::Sleeping);
	CHECK(g.state_of(7) == State::Sleeping);

	// While the sleep runs nothing starts again and nobody wakes before kSleepMs.
	t = g.tick({seen(0), seen(7)}, false, 1000 + kSleepMs - 1);
	CHECK(!t.started);
	CHECK(!t.woke);
	CHECK(g.state_of(0) == State::Sleeping);
	CHECK(!g.lie_down(9, 8, false, false)); // nobody lies down into a running sleep

	t = g.tick({seen(0), seen(7)}, false, 1000 + kSleepMs);
	CHECK(t.woke);
	CHECK(!t.started);
	CHECK(!g.sleeping());
	CHECK(g.state_of(0) == State::Awake);
	CHECK(g.state_of(7) == State::Awake);
	CHECK(t.cancelled.empty()); // waking up is not a cancelled rest
}

TEST(rest_group_newcomer_waits)
{
	// Review Focus 5: two rest, a third comes in awake: no sleep, and the two keep resting.
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(4, 8, false, false);
	Tick t = g.tick({seen(0), seen(4), seen(9)}, false, 500);
	CHECK(!t.started);
	CHECK(t.block == Block::NotAll);
	CHECK(t.cancelled.empty());
	CHECK(g.state_of(0) == State::Resting);
	CHECK(g.state_of(4) == State::Resting);
	CHECK(g.block() == Block::NotAll);
	g.lie_down(9, 6, false, false);
	t = g.tick({seen(0), seen(4), seen(9)}, false, 1000);
	CHECK(t.started);
	CHECK_EQ(int(t.hours), 6);
}

TEST(rest_group_block_only_while_somebody_rests)
{
	Group g;
	// Nobody rests: whatever holds the sleep is nobody's business.
	Tick t = g.tick({seen(0, true, true), seen(3)}, true, 500);
	CHECK(t.block == Block::None);
	CHECK(!t.started);
	g.lie_down(3, 8, false, false);
	t = g.tick({seen(0, true, true), seen(3)}, true, 1000);
	CHECK(t.block == Block::Combat);
	t = g.tick({seen(0), seen(3)}, true, 1500);
	CHECK(t.block == Block::World); // an emission beats "not all"
	t = g.tick({seen(0), seen(3)}, false, 1600);
	CHECK(t.block == Block::NotAll); // the host is awake
	g.lie_down(0, 8, false, false);
	t = g.tick({seen(0), seen(3)}, true, 2000);
	CHECK(t.block == Block::World);
	CHECK(!t.started);
	t = g.tick({seen(0), seen(3)}, false, 2500);
	CHECK(t.started);
	CHECK(t.block == Block::None);
}

TEST(rest_group_dead_ends_the_rest)
{
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(5, 8, false, false);
	Tick t = g.tick({seen(0), seen(5, false)}, false, 500);
	CHECK(!t.started);
	CHECK(cancelled_with(t, 5, Refusal::Dead));
	CHECK_EQ(t.cancelled.size(), size_t(1));
	CHECK(g.state_of(5) == State::Awake);
	CHECK(g.state_of(0) == State::Resting);
	CHECK(t.block == Block::Dead); // a wounded player holds the sleep
}

TEST(rest_group_fight_ends_the_rest)
{
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(5, 8, false, false);
	Tick t = g.tick({seen(0), seen(5, true, true)}, false, 500);
	CHECK(cancelled_with(t, 5, Refusal::Combat));
	CHECK(g.state_of(5) == State::Awake);
	CHECK(!t.started);
	CHECK(t.block == Block::Combat);

	// Passing out in a fight: the fight he passed out in does not wake him, a new one does.
	Group f;
	f.lie_down(2, 4, true, true);
	t = f.tick({seen(2, true, true)}, false, 500);
	CHECK(t.cancelled.empty());
	CHECK(f.state_of(2) == State::Resting);
	CHECK(t.block == Block::Combat);
	t = f.tick({seen(2, true, false)}, false, 1000); // the fight is over: he sleeps (alone in the group)
	CHECK(t.started);
	CHECK(t.cancelled.empty());

	Group f2;
	f2.lie_down(2, 4, true, true);
	f2.lie_down(3, 4, false, false);
	f2.tick({seen(2, true, true), seen(3)}, false, 500);
	f2.tick({seen(2, true, false), seen(3, true, false)}, true, 1000); // fight over, emission holds the sleep
	CHECK(f2.state_of(2) == State::Resting);
	t = f2.tick({seen(2, true, true), seen(3)}, true, 1500); // a new fight
	CHECK(cancelled_with(t, 2, Refusal::Combat));
}

TEST(rest_group_left_ends_the_rest)
{
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(6, 8, false, false);
	Tick t = g.tick({seen(0)}, false, 500); // 6 left (or is loading the world again)
	CHECK(cancelled_with(t, 6, Refusal::None));
	CHECK(g.state_of(6) == State::Awake);
	// The one who stayed is alone now: he sleeps.
	CHECK(t.started);
	for (const Entry& e : g.entries())
		CHECK(e.character != 6);
}

TEST(rest_group_sleep_ends_when_nobody_sleeps)
{
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(1, 8, false, false);
	CHECK(g.tick({seen(0), seen(1)}, false, 0).started);
	CHECK(g.get_up(0));
	CHECK(g.get_up(1));
	const Tick t = g.tick({seen(0), seen(1)}, false, 500);
	CHECK(t.woke);
	CHECK(!g.sleeping());
	CHECK(g.lie_down(0, 8, false, false)); // a new rest may start
}

TEST(rest_group_sleeper_in_a_fight_wakes)
{
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(1, 8, false, false);
	CHECK(g.tick({seen(0), seen(1)}, false, 0).started);
	const Tick t = g.tick({seen(0), seen(1, true, true)}, false, 500);
	CHECK(cancelled_with(t, 1, Refusal::Combat));
	CHECK(g.state_of(1) == State::Awake);
	CHECK(g.state_of(0) == State::Sleeping);
	CHECK(g.sleeping());
}

TEST(rest_group_entries)
{
	Group g;
	CHECK(g.entries().empty());
	g.tick({seen(9), seen(0), seen(4)}, false, 0);
	g.lie_down(4, 6, false, false);
	const std::vector<Entry> e = g.entries();
	REQUIRE(e.size() == 3);
	CHECK(e[0] == entry(0, State::Awake, 0));
	CHECK(e[1] == entry(4, State::Resting, 6));
	CHECK(e[2] == entry(9, State::Awake, 0));
	// A player who lay down before the next tick is listed too.
	g.lie_down(2, 3, false, false);
	REQUIRE(g.entries().size() == 4);
	CHECK(g.entries()[1] == entry(2, State::Resting, 3));
}

TEST(rest_group_clear)
{
	// Review Focus 2: a world change or a reset wakes everybody and stops the sleep.
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(1, 8, false, false);
	g.tick({seen(0), seen(1)}, false, 0);
	REQUIRE(g.sleeping());
	g.clear();
	CHECK(!g.sleeping());
	CHECK(g.state_of(0) == State::Awake);
	CHECK(g.state_of(1) == State::Awake);
	CHECK(g.entries().empty());
	CHECK(g.block() == Block::None);
	CHECK(g.lie_down(0, 8, false, false));
}

TEST(rest_changes)
{
	const std::vector<Entry> before = {entry(0, State::Resting, 8), entry(3, State::Awake, 0), entry(5, State::Resting, 4),
		entry(7, State::Resting, 6)};
	const std::vector<Entry> after = {entry(0, State::Sleeping, 8), entry(3, State::Awake, 0), entry(5, State::Resting, 2),
		entry(9, State::Awake, 0), entry(11, State::Resting, 1)};
	const std::vector<Change> c = changes(before, after);
	REQUIRE(c.size() == 4);
	CHECK_EQ(int(c[0].id), 0); // state
	CHECK(c[0].state == State::Sleeping);
	CHECK_EQ(int(c[0].hours), 8);
	CHECK_EQ(int(c[1].id), 5); // hours
	CHECK_EQ(int(c[1].hours), 2);
	CHECK_EQ(int(c[2].id), 7); // gone: awake
	CHECK(c[2].state == State::Awake);
	CHECK_EQ(int(c[2].hours), 0);
	CHECK_EQ(int(c[3].id), 11); // new and resting (a new awake one, 9, is no change)
	CHECK(c[3].state == State::Resting);

	CHECK(changes(before, before).empty());
	// Review Focus 2: everything forgotten (a new world): every one who was not awake is told awake.
	const std::vector<Change> woke = changes(before, {});
	REQUIRE(woke.size() == 3);
	for (const Change& w : woke)
		CHECK(w.state == State::Awake);
}

TEST(rest_waiting)
{
	const std::vector<uint16_t> w = waiting(
		{entry(0, State::Resting, 8), entry(3, State::Awake, 0), entry(5, State::Sleeping, 4), entry(7, State::Awake, 0)});
	REQUIRE(w.size() == 2);
	CHECK_EQ(int(w[0]), 3);
	CHECK_EQ(int(w[1]), 7);
	CHECK(waiting({}).empty());
}

// ---------------------------------------------------------------- F3 Task 11, review round 1 (task-11-review.md)

TEST(rest_refusal_camp)
{
	// M2: the camp could not be set where he lies down: a refusal of its own, on the wire as 5.
	CHECK_EQ(std::string(refusal_name(Refusal::Camp)), std::string("camp"));
	CHECK(refusal_from_name("camp") == Refusal::Camp);
	StateMsg out;
	REQUIRE(parse_state(state_bytes(1, {entry(3, State::Awake, 0)}, 5), out));
	CHECK(out.refused == Refusal::Camp);
	CHECK(!parse_state(state_bytes(1, {entry(3, State::Awake, 0)}, 6), out));
}

TEST(rest_group_refused_lie_down_ends_a_waiting_rest)
{
	// M1: he rested at a camp, walked away and asked again: refused, and no old consent stays in the book.
	Group g;
	g.lie_down(1, 8, false, false);
	CHECK(g.on_refused(1));
	CHECK(g.state_of(1) == State::Awake);
	CHECK(!g.on_refused(1)); // awake already
	// A running sleep is kept: the time is skipped already.
	g.lie_down(2, 8, false, false);
	g.lie_down(3, 8, false, false);
	REQUIRE(g.tick({seen(2), seen(3)}, false, 0).started);
	CHECK(!g.on_refused(2));
	CHECK(g.state_of(2) == State::Sleeping);
}

TEST(rest_group_may_lie_down)
{
	// M2: asked before the camp is set, so a camp never comes without a rest.
	Group g;
	CHECK(g.may_lie_down(1));
	for (uint16_t i = 0; i < coop::kMaxPlayers; ++i)
		g.lie_down(i, 8, false, false);
	CHECK(!g.may_lie_down(100)); // a ninth rest
	CHECK(g.may_lie_down(0)); // he rests already: he may change his wish
	Group s;
	s.lie_down(0, 8, false, false);
	REQUIRE(s.tick({seen(0)}, false, 0).started);
	CHECK(!s.may_lie_down(0)); // the sleep runs
	CHECK(!s.may_lie_down(5));
}

TEST(rest_group_start_checks_the_places)
{
	// M1: when everybody rests, each one's rest place is looked at once more (not on every tick); one who walked away
	// from his camp loses his rest ("place") and nobody sleeps.
	Group g;
	g.lie_down(1, 8, false, false);
	g.lie_down(2, 6, false, false);
	g.lie_down(3, 4, true, false); // passed out: no place to look at
	std::vector<uint16_t> asked;
	bool two_at_camp = false;
	const Group::PlaceCheck at_place = [&](uint16_t id) {
		asked.push_back(id);
		return id != 2 || two_at_camp;
	};
	Tick t = g.tick({seen(1), seen(2), seen(3), seen(4)}, false, 0, at_place); // 4 is awake
	CHECK(!t.started);
	CHECK(asked.empty());

	t = g.tick({seen(1), seen(2), seen(3)}, false, 500, at_place);
	CHECK(!t.started);
	CHECK(cancelled_with(t, 2, Refusal::Place));
	CHECK_EQ(t.cancelled.size(), size_t(1));
	CHECK(g.state_of(2) == State::Awake);
	CHECK(g.state_of(1) == State::Resting);
	CHECK(g.state_of(3) == State::Resting);
	CHECK(t.block == Block::NotAll);
	REQUIRE(asked.size() == 2); // 1 and 2; 3 passed out
	CHECK_EQ(int(asked[0]), 1);
	CHECK_EQ(int(asked[1]), 2);

	two_at_camp = true;
	asked.clear();
	g.lie_down(2, 6, false, false);
	t = g.tick({seen(1), seen(2), seen(3)}, false, 1000, at_place);
	CHECK(t.started);
	CHECK_EQ(int(t.hours), 4);
	CHECK(t.cancelled.empty());
	CHECK_EQ(asked.size(), size_t(2));

	asked.clear();
	g.tick({seen(1), seen(2), seen(3)}, false, 1500, at_place); // the sleep runs: nobody is looked at again
	CHECK(asked.empty());
}

TEST(rest_news_order)
{
	// M4: one order on the host and on a client: the changes first, then why (coop_rest_refused).
	const std::vector<Entry> before = {entry(0, State::Resting, 8), entry(4, State::Resting, 6)};
	const std::vector<Entry> after = {entry(0, State::Awake, 0), entry(4, State::Resting, 2)};
	const std::vector<Note> n = news(before, after, Refusal::Place);
	REQUIRE(n.size() == 3);
	CHECK(!n[0].refusal);
	CHECK_EQ(int(n[0].change.id), 0);
	CHECK(n[0].change.state == State::Awake);
	CHECK(!n[1].refusal);
	CHECK_EQ(int(n[1].change.id), 4);
	CHECK_EQ(int(n[1].change.hours), 2);
	CHECK(n[2].refusal);
	CHECK(n[2].refused == Refusal::Place);
	CHECK_EQ(news(before, after, Refusal::None).size(), size_t(2));
	// A first lie-down refused changes nothing: the refusal alone.
	const std::vector<Note> alone = news(before, before, Refusal::Combat);
	REQUIRE(alone.size() == 1);
	CHECK(alone[0].refusal);
	CHECK(alone[0].refused == Refusal::Combat);
	CHECK(news(before, before, Refusal::None).empty());
}

TEST(rest_group_sleeper_leaves)
{
	// M6 a: a sleeper leaves: the others sleep on; every sleeper gone: the sleep is over in that tick.
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(1, 8, false, false);
	g.lie_down(2, 8, false, false);
	REQUIRE(g.tick({seen(0), seen(1), seen(2)}, false, 0).started);
	Tick t = g.tick({seen(0), seen(1)}, false, 500);
	CHECK(cancelled_with(t, 2, Refusal::None));
	CHECK(!t.woke);
	CHECK(g.sleeping());
	CHECK(g.state_of(0) == State::Sleeping);
	CHECK(g.state_of(1) == State::Sleeping);
	for (const Entry& e : g.entries())
		CHECK(e.character != 2);
	t = g.tick({seen(7)}, false, 1000);
	CHECK(cancelled_with(t, 0, Refusal::None));
	CHECK(cancelled_with(t, 1, Refusal::None));
	CHECK(t.woke);
	CHECK(!t.started);
	CHECK(!g.sleeping());
}

TEST(rest_group_sleeper_dies)
{
	// M6 b: a sleeper is down: his rest ends (dead), the others sleep on until kSleepMs.
	Group g;
	g.lie_down(0, 8, false, false);
	g.lie_down(1, 8, false, false);
	REQUIRE(g.tick({seen(0), seen(1)}, false, 0).started);
	const Tick t = g.tick({seen(0), seen(1, false)}, false, 500);
	CHECK(cancelled_with(t, 1, Refusal::Dead));
	CHECK(g.state_of(1) == State::Awake);
	CHECK(g.state_of(0) == State::Sleeping);
	CHECK(g.sleeping());
	CHECK(!t.woke);
	CHECK(t.block == Block::None); // nothing holds a sleep that runs
	const Tick end = g.tick({seen(0), seen(1, false)}, false, kSleepMs);
	CHECK(end.woke);
	CHECK(g.state_of(0) == State::Awake);
}

TEST(rest_group_present_duplicates_and_bound)
{
	// M6 c: an id twice counts once, the first word about him wins.
	Group g;
	g.lie_down(1, 8, false, false);
	Tick t = g.tick({seen(1), seen(1, false)}, false, 0);
	CHECK(t.cancelled.empty());
	CHECK(t.started);
	REQUIRE(g.entries().size() == 1);
	Group d;
	d.lie_down(1, 8, false, false);
	t = d.tick({seen(1, false), seen(1)}, false, 0);
	CHECK(cancelled_with(t, 1, Refusal::Dead));
	CHECK(!t.started);
	REQUIRE(d.entries().size() == 1);
	// More players than a session has: kMaxPlayers of them by id.
	Group b;
	std::vector<Seen> many;
	for (int i = 0; i < int(coop::kMaxPlayers) + 3; ++i)
		many.push_back(seen(uint16_t(20 - i))); // 20 down to 10
	b.tick(many, false, 0);
	const std::vector<Entry> e = b.entries();
	REQUIRE(e.size() == size_t(coop::kMaxPlayers));
	CHECK_EQ(int(e.front().character), 10);
	CHECK_EQ(int(e.back().character), 17);
}

TEST(rest_group_lie_down_again_takes_the_fight_now)
{
	// M6 d: lying down again (a second faint) takes the fight he is in now: that fight does not wake him.
	Group g;
	g.lie_down(2, 4, true, false);
	g.lie_down(2, 4, true, true);
	const Tick t = g.tick({seen(2, true, true)}, false, 0);
	CHECK(t.cancelled.empty());
	CHECK(g.state_of(2) == State::Resting);
	CHECK(t.block == Block::Combat);
}
