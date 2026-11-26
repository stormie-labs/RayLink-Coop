// Anomaly Coop unit tests: split levels, every map is computed on the host's PC (docs/SPLIT_LEVELS.md §7a). Who computes a level,
// the verdict on a move, the roles of a process, which messages reach a player on another level, the vote of the switch
// manager on a map server, and the world server's book of objects held by a map server (coop_levels_keeper.h) against the
// real Holder of the transfer core.
#include "test_util.h"

#include "srv/coop_levels_keeper.h"
#include "coop_levels_rules.h"
#include "coop_roles.h"
#include "support/scope_listed.h"

#include <vector>

using namespace coop;
using namespace coop::levels;

namespace
{
constexpr uint16_t kCordon = 1;
constexpr uint16_t kGarbage = 2;
constexpr uint16_t kAgroprom = 3;
constexpr uint64_t kT0 = 1000;

Seat seat(uint32_t peer, uint16_t level, bool in_world = true, bool plays = true)
{
	Seat s;
	s.peer = peer;
	s.level = level;
	s.in_world = in_world;
	s.plays = plays;
	return s;
}

xfer::Bytes state_of(uint8_t v) { return xfer::Bytes{v, uint8_t(v + 1)}; }

// One map server on one level against the keeper, packets delivered by hand.
struct Rig
{
	Keeper keeper;
	xfer::Holder holder{7}; // what the map server's Holder calls itself; the wire carries no peer
	uint32_t peer = 0x101; // its bridge
	uint64_t now = kT0;
	std::vector<Keeper::Change> changes;

	Rig() { keeper.connect(peer); }

	void to_client(const std::vector<xfer::Packet>& down)
	{
		for (const xfer::Packet& p : down)
		{
			xfer::Packet c = p;
			c.from = xfer::kWorld;
			c.to = holder.self();
			to_world(holder.on_packet(c, now));
		}
	}
	void to_world(const std::vector<xfer::Packet>& up, const xfer::Bytes* fresh = nullptr)
	{
		for (const xfer::Packet& p : up)
			to_client(keeper.on_up(peer, p, fresh, now));
		drain();
	}
	void drain()
	{
		for (Keeper::Change& c : keeper.take_changes())
			changes.push_back(std::move(c));
	}
	bool saw(Keeper::Kind kind, uint16_t id) const
	{
		for (const Keeper::Change& c : changes)
			if (c.kind == kind && c.id == id)
				return true;
		return false;
	}
	void take(uint16_t id, uint8_t v)
	{
		const xfer::Bytes fresh = state_of(v);
		to_world(holder.want_online(id, now), &fresh);
	}
};
} // namespace

// ---------------------------------------------------------------- who computes a level

// The owner's decision (2026-10-24, again 2026-11-01): the maps are computed on the host's PC, a client never is an authority.
// Owner 2026-11-18: no hybrid. The world server plays nobody and leads no level: every level with players has a map server.
TEST(server_a_level_of_clients_alone_has_a_map_server_however_many_there_are)
{
	Table t;
	t.set(seat(0, kCordon, true, /*plays*/ false)); // the world server's own seat
	t.set(seat(2, kGarbage));
	t.set(seat(1, kGarbage));
	CHECK(t.server_of(kGarbage) == Server::MapServer);
	CHECK(t.server_of(kCordon) == Server::None);
	CHECK(t.server_of(kAgroprom) == Server::None);
	CHECK(t.server_of(kNoLevel) == Server::None);
	t.remove(2);
	CHECK(t.server_of(kGarbage) == Server::MapServer);
	t.remove(1);
	CHECK(t.server_of(kGarbage) == Server::None);
}

TEST(server_a_seat_that_does_not_play_keeps_no_level_served)
{
	Table t;
	t.set(seat(1, kGarbage, true, false));
	CHECK(t.server_of(kGarbage) == Server::None);
}

// Seat 0 that plays is a player like any other (no host's process leads a level any more): his level is a map server's.
TEST(server_seat_zero_that_plays_is_led_by_a_map_server_too)
{
	Table t;
	t.set(seat(1, kGarbage));
	t.set(seat(0, kGarbage));
	CHECK(t.server_of(kGarbage) == Server::MapServer);
	CHECK_EQ(t.map_players(kGarbage), uint32_t(2));
	CHECK_EQ(t.map_server_levels(), (std::vector<uint16_t>{kGarbage}));
}

// ---------------------------------------------------------------- the verdict

TEST(move_a_free_level_goes_and_a_new_map_server_starts_for_it)
{
	CHECK(decide_move(Gate::Free, true, 0, 3) == MoveVerdict::Go);
	CHECK(decide_move(Gate::BetterTogether, true, 2, 3) == MoveVerdict::Go);
}

TEST(move_to_a_level_somebody_computes_goes_whatever_the_cap)
{
	CHECK(decide_move(Gate::Free, false, 3, 3) == MoveVerdict::Go); // the host's level, or a running map server's
	CHECK(decide_move(Gate::Free, false, 0, 0) == MoveVerdict::Go);
}

TEST(move_over_the_cap_of_map_servers_is_refused)
{
	CHECK(decide_move(Gate::Free, true, 3, 3) == MoveVerdict::RefuseCap);
	CHECK(decide_move(Gate::BetterTogether, true, 3, 3) == MoveVerdict::RefuseCap);
	CHECK(decide_move(Gate::Free, true, 0, 0) == MoveVerdict::RefuseCap); // coop_max_map_servers 0: nobody leaves the host's map
}

TEST(move_together_waits_at_the_board_and_a_bad_gate_is_refused)
{
	CHECK(decide_move(Gate::Together, true, 3, 3) == MoveVerdict::Board);
	CHECK(decide_move(Gate(9), true, 0, 3) == MoveVerdict::RefuseInvalid);
}

// ---------------------------------------------------------------- the roles

TEST(roles_of_the_host_and_of_a_client_as_before_split_levels)
{
	CHECK_EQ(int(host_roles()), int(uint8_t(ProcessRole::WorldServer) | uint8_t(ProcessRole::MapAuthority) | uint8_t(ProcessRole::Player)));
	CHECK(has(client_roles(), ProcessRole::Mirror));
	CHECK(has(client_roles(), ProcessRole::WorldClient));
	CHECK(has(client_roles(), ProcessRole::Player));
}

// A client mirrors, always and on every level: this test is the owner's decision in code. It has to fail the day a client may
// compute a map.
TEST(roles_a_client_never_is_a_map_authority)
{
	CHECK(!has(client_roles(), ProcessRole::MapAuthority));
	CHECK(!has(client_roles(), ProcessRole::MapServer));
	CHECK(!has(client_roles(), ProcessRole::WorldServer));
}

TEST(roles_of_a_map_server)
{
	const uint8_t r = map_server_roles();
	CHECK_EQ(int(r), int(uint8_t(ProcessRole::MapAuthority) | uint8_t(ProcessRole::MapServer) | uint8_t(ProcessRole::WorldClient)));
	CHECK(has(r, ProcessRole::MapAuthority)); // the objects of its level are its own
	CHECK(has(r, ProcessRole::WorldClient)); // time, story, money: it asks the world server
	CHECK(!has(r, ProcessRole::Player)); // its actor is a ghost, nobody plays it
	CHECK(!has(r, ProcessRole::Mirror));
	CHECK(!has(r, ProcessRole::WorldServer));
}

// ---------------------------------------------------------------- which messages reach another level

// The switch off is the contract of the whole feature: not one message may change its way.
TEST(passes_split_off_every_message_goes_as_before)
{
	uint32_t listed = 0;
	for (uint32_t v = 0; v <= 0xffff; ++v)
	{
		const Msg m = Msg(uint16_t(v));
		if (!scope_listed(m))
			continue;
		++listed;
		CHECK(level_passes(m, false, false));
		CHECK(level_passes(m, false, true));
	}
	CHECK(listed > 100);
}

TEST(passes_the_same_level_gets_everything)
{
	for (uint32_t v = 0; v <= 0xffff; ++v)
		if (scope_listed(Msg(uint16_t(v))))
			CHECK(level_passes(Msg(uint16_t(v)), true, true));
}

TEST(passes_another_level_gets_the_world_and_the_registry_not_the_stream)
{
	// the stream of the host's level means nothing to a player on another one
	CHECK(!level_passes(Msg::EntitySnapshot, true, false));
	CHECK(!level_passes(Msg::EntitySwitch, true, false));
	CHECK(!level_passes(Msg::EntityAnim, true, false));
	CHECK(!level_passes(Msg::PlayerState, true, false));
	CHECK(!level_passes(Msg::ZoneState, true, false));
	CHECK(!level_passes(Msg::EntityHash, true, false));
	// the world is one
	CHECK(level_passes(Msg::TimeSync, true, false));
	CHECK(level_passes(Msg::InfoPortion, true, false));
	CHECK(level_passes(Msg::Emission, true, false));
	CHECK(level_passes(Msg::Chat, true, false));
	// every machine keeps the same registry with the same ids
	CHECK(level_passes(Msg::EntitySpawn, true, false));
	CHECK(level_passes(Msg::EntityDestroy, true, false));
	CHECK(level_passes(Msg::EntityParent, true, false));
	CHECK(level_passes(Msg::EntitySquad, true, false));
	// the sky is the authority's of each level: one cycle, but a cellar has no sun
	CHECK(!level_passes(Msg::WeatherSync, true, false));
	CHECK(!level_passes(Msg::Thunderbolt, true, false));
}

// ---------------------------------------------------------------- the vote

TEST(vote_what_the_host_does_not_simulate_is_not_transferred)
{
	const LeadAsk a = lead_vote(false, false, false, true);
	CHECK(a.vote == LeadVote::Stock);
	CHECK(!a.ask);
}

TEST(vote_a_creature_near_him_is_asked_for_and_stays_offline_until_granted)
{
	const LeadAsk a = lead_vote(true, false, false, true);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(a.ask);
}

TEST(vote_a_creature_far_from_him_is_left_alone)
{
	const LeadAsk a = lead_vote(true, false, false, false);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(!a.ask);
}

TEST(vote_a_creature_he_holds_follows_the_stock_rules)
{
	const LeadAsk a = lead_vote(true, true, false, false);
	CHECK(a.vote == LeadVote::Stock);
	CHECK(!a.ask);
}

TEST(vote_a_creature_on_its_way_back_stays_offline)
{
	const LeadAsk a = lead_vote(true, true, true, true);
	CHECK(a.vote == LeadVote::Offline);
	CHECK(!a.ask);
}

// ---------------------------------------------------------------- ids

TEST(ids_each_map_server_has_its_slice_and_nobody_shares_it)
{
	CHECK_EQ(int(leader_ids_of(0)), 0); // the world server keeps them out of its generator, it makes none of them
	CHECK_EQ(int(leader_ids_of(8)), 0);
	uint32_t next = kLeaderIdFirst;
	for (uint32_t peer = 1; peer <= kLeaderSlots; ++peer)
	{
		CHECK_EQ(uint32_t(leader_ids_of(peer)), next);
		next += kLeaderIdsEach;
	}
	CHECK(next - 1 < 0xffff); // 0xffff is no id
}

TEST(ids_a_slice_holds_a_busy_level_and_the_world_stays_below_them)
{
	// k00_marsh: four traders are some 570 objects, and 48 ids go to each player's lease
	CHECK(kLeaderIdsEach >= 4095u);
	CHECK(kLeaderIdFirst > 27296u); // GAMMA's world by the log, ids dense from the bottom of the generator
	CHECK_EQ(uint32_t(leader_ids_of(kLeaderSlots)) + kLeaderIdsEach - 1, 0xFFF8u);
	CHECK_EQ(0x10000u - kLeaderSlots * kLeaderIdsEach > 27296u, true); // even with every slice kept
}

TEST(ids_the_world_keeps_the_slices_that_can_be_used_and_no_more)
{
	CHECK_EQ(leader_slots_kept(3, 0), 3u); // the default: 12285 ids, the rest stays the world's
	CHECK_EQ(leader_slots_kept(0, 0), 0u);
	CHECK_EQ(leader_slots_kept(7, 2), 7u);
	CHECK_EQ(leader_slots_kept(3, 2), 3u);
	// a lost server keeps number 3 while its players wait, another level takes the free place under number 4
	CHECK_EQ(leader_slots_kept(3, 4), 4u);
	CHECK_EQ(leader_slots_kept(1, 3), 3u); // the console lowered the setting under a running server
	CHECK_EQ(leader_slots_kept(9, 0), kLeaderSlots);
	CHECK_EQ(leader_slots_kept(0, 9), kLeaderSlots);
}

// ---------------------------------------------------------------- the world server's book

TEST(keeper_a_take_marks_the_object_and_the_client_gets_its_state)
{
	Rig r;
	r.take(100, 5);
	CHECK(r.keeper.away(100));
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
	CHECK(r.saw(Keeper::Kind::Mark, 100));
	CHECK(r.holder.authors(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Create);
	CHECK(ev[0].state == state_of(5));
	CHECK_EQ(r.keeper.ledger().journal_size(), size_t(0));
}

// Requirement 2: a save in the middle of a transfer, the host's load of it: every object exactly once, the handed-back state not lost.
TEST(keeper_a_journal_brings_a_release_in_flight_through_a_load)
{
	Rig r;
	r.take(50, 10);
	r.take(51, 20);
	CHECK(r.keeper.ledger().owner(50) != xfer::kWorld);

	// the world took the state of 50 and the map server's answer never came: the save falls here
	const xfer::Bytes last = state_of(77);
	r.holder.take_events();
	std::vector<xfer::Packet> up = r.holder.want_offline(50, last, r.now);
	CHECK(!up.empty());
	(void)r.keeper.on_up(r.peer, up.front(), nullptr, r.now);
	r.drain();
	const std::string text = r.keeper.journal();
	CHECK(text.find("[coop_xfer]") != std::string::npos);
	CHECK(text.find("n = 1") != std::string::npos);

	r.changes.clear();
	Keeper loaded;
	const uint32_t peer_before = r.keeper.ledger().next_peer();
	loaded.connect(0x102); // a process of the old world
	CHECK(loaded.resume(text));
	CHECK(!loaded.connected(0x102));
	std::vector<Keeper::Change> changes = loaded.take_changes();
	CHECK_EQ(changes.size(), size_t(1));
	CHECK(changes[0].kind == Keeper::Kind::State && changes[0].id == 50 && changes[0].state == last);
	CHECK(loaded.ledger().owner(50) == xfer::kWorld);
	CHECK(loaded.ledger().owner_count(50) <= 1);
	CHECK(loaded.ledger().next_peer() >= peer_before);
	// a garbled text changes nothing
	Keeper same;
	same.connect(0x101);
	CHECK(!same.resume("[coop_xfer]\nv = 9\n"));
	CHECK(same.connected(0x101));
}

TEST(keeper_a_release_brings_the_state_home_once)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.want_offline(100, state_of(9), r.now));
	CHECK(!r.keeper.away(100));
	CHECK(r.saw(Keeper::Kind::Unmark, 100));
	CHECK_EQ(r.changes.size(), size_t(1));
	CHECK(r.changes[0].state == state_of(9));
	CHECK(!r.holder.authors(100));
}

TEST(keeper_a_taken_object_is_nobody_elses)
{
	Rig r;
	r.keeper.connect(3);
	r.take(100, 5);
	r.holder.take_events();
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const xfer::Bytes fresh = state_of(1);
	CHECK(r.keeper.on_up(3, up, &fresh, r.now).empty()); // the other client repeats until it comes back
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
}

TEST(keeper_a_stream_change_reaches_the_host_without_moving_the_owner)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.changed(100, state_of(7), r.now));
	CHECK(r.saw(Keeper::Kind::State, 100));
	CHECK(r.changes[0].state == state_of(7));
	CHECK(r.keeper.away(100));
}

TEST(keeper_a_client_that_leaves_gives_everything_back_at_the_last_state)
{
	Rig r;
	r.take(100, 5);
	r.take(101, 6);
	r.holder.take_events();
	r.to_world(r.holder.changed(100, state_of(7), r.now));
	r.changes.clear();
	r.keeper.disconnect(r.peer, r.now);
	r.drain();
	CHECK(!r.keeper.away(100));
	CHECK(!r.keeper.away(101));
	CHECK(r.saw(Keeper::Kind::Unmark, 100));
	CHECK(r.saw(Keeper::Kind::Unmark, 101));
	for (const Keeper::Change& c : r.changes)
		CHECK(c.state == (c.id == 100 ? state_of(7) : state_of(6)));
	CHECK_EQ(r.keeper.held_by(r.peer), size_t(0));
}

TEST(keeper_a_client_that_comes_back_is_a_new_connection)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.keeper.disconnect(r.peer, r.now);
	r.drain();
	r.keeper.connect(r.peer);
	r.holder = xfer::Holder(7);
	r.take(100, 5);
	CHECK(r.keeper.away(100));
	CHECK_EQ(r.keeper.holder_of(100), r.peer);
}

TEST(keeper_a_message_of_nobody_is_not_heard)
{
	Rig r;
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const xfer::Bytes fresh = state_of(1);
	CHECK(r.keeper.on_up(5, up, &fresh, r.now).empty()); // peer 5 never connected as a map server
	CHECK(!r.keeper.away(100));
}

TEST(keeper_an_object_the_world_does_not_have_is_refused)
{
	Rig r;
	r.to_world(r.holder.want_online(100, r.now), nullptr); // no state: no such object here
	CHECK(!r.keeper.away(100));
	CHECK(!r.holder.authors(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Refused);
}

TEST(keeper_a_destroyed_object_leaves_the_book)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	r.to_world(r.holder.destroyed(100, r.now));
	CHECK(r.saw(Keeper::Kind::Gone, 100));
	CHECK(!r.keeper.away(100));
}

// The host's copy says the object is not for him (it walked off his level, it is online on the host's level): an old record
// of the ledger does not change that.
TEST(keeper_an_object_that_is_not_his_to_take_is_refused_even_with_a_record)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.to_world(r.holder.want_offline(100, state_of(6), r.now));
	r.holder.take_events();
	r.to_world(r.holder.want_online(100, r.now), nullptr);
	CHECK(!r.keeper.away(100));
	const std::vector<xfer::Holder::Event> ev = r.holder.take_events();
	CHECK_EQ(ev.size(), size_t(1));
	CHECK(ev[0].kind == xfer::Holder::Event::Kind::Refused);
}

// His own request repeated (the Grant is on its way) is answered with the same grant, whatever the engine thinks of the
// object now that it is marked.
TEST(keeper_a_request_repeated_gets_the_same_grant)
{
	Rig r;
	const xfer::Bytes fresh = state_of(5);
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	const std::vector<xfer::Packet> first = r.keeper.on_up(r.peer, up, &fresh, r.now);
	const std::vector<xfer::Packet> second = r.keeper.on_up(r.peer, up, nullptr, r.now);
	CHECK_EQ(first.size(), size_t(1));
	CHECK_EQ(second.size(), size_t(1));
	CHECK(second[0].op == xfer::Op::Grant);
	CHECK_EQ(second[0].key.gen, first[0].key.gen);
	CHECK(second[0].payload == fresh);
}

// Every op of the transfer goes over the wire and comes back the same.
TEST(keeper_wire_every_op_of_both_directions)
{
	const xfer::Bytes cargo = state_of(3);
	for (xfer::Op op : {xfer::Op::TakeReq, xfer::Op::TakeCommit, xfer::Op::ReleasePrepare, xfer::Op::ReleaseCommit,
	         xfer::Op::SpawnPrepare, xfer::Op::Destroy, xfer::Op::AbortAck, xfer::Op::Snapshot})
	{
		wire::LevelXferUpMsg m;
		CHECK(up_of(xfer::Packet{op, xfer::Key{9, 77}, 1, xfer::kWorld, cargo}, m));
		const xfer::Packet back = packet_of(m);
		CHECK(back.op == op);
		CHECK_EQ(back.key.id, uint16_t(9));
		CHECK_EQ(back.key.gen, 77u);
		CHECK(back.payload == cargo);
	}
	for (xfer::Op op : {xfer::Op::Grant, xfer::Op::Ack, xfer::Op::Done, xfer::Op::Abort, xfer::Op::Drop, xfer::Op::Snapshot})
	{
		wire::LevelXferDownMsg m;
		CHECK(down_of(xfer::Packet{op, xfer::Key{9, 77}, xfer::kWorld, 1, cargo}, m));
		const xfer::Packet back = packet_of(m, 5);
		CHECK(back.op == op);
		CHECK_EQ(back.to, 5u);
		CHECK(back.payload == cargo);
	}
	wire::LevelXferUpMsg u;
	CHECK(!up_of(xfer::Packet{xfer::Op::Grant, xfer::Key{9, 77}, 1, xfer::kWorld, {}}, u));
	wire::LevelXferDownMsg d;
	CHECK(!down_of(xfer::Packet{xfer::Op::TakeReq, xfer::Key{9, 77}, xfer::kWorld, 1, {}}, d));
}

TEST(keeper_a_new_world_forgets_everything_and_reuses_no_peer)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	const xfer::Peer before = r.keeper.ledger().next_peer();
	r.keeper.restart();
	r.drain();
	CHECK(!r.keeper.away(100));
	CHECK_EQ(r.keeper.marked(), size_t(0));
	CHECK(!r.keeper.connected(r.peer));
	CHECK_EQ(r.keeper.ledger().next_peer(), before);
}

namespace
{
std::vector<xfer::Entry> report_of(const xfer::Holder& h) { return Keeper::bare(h.report()); }
} // namespace

TEST(keeper_audit_a_client_who_holds_what_the_ledger_says_is_clean)
{
	Rig r;
	r.take(100, 5);
	r.take(101, 6);
	r.holder.take_events();
	CHECK_EQ(r.keeper.differs(r.peer, xfer::hash_of(report_of(r.holder))), 0u);
}

// A stream change is no difference: the auditor asks who writes what, not how fresh the host's copy is.
TEST(keeper_audit_does_not_compare_states)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.holder.changed(100, state_of(9), r.now); // not delivered
	CHECK_EQ(r.keeper.differs(r.peer, xfer::hash_of(report_of(r.holder))), 0u);
}

// He lost it (a Holder that was replaced under the ledger): the ledger says it is his, he does not report it. It comes home, two-phase.
TEST(keeper_audit_a_lost_object_comes_home)
{
	Rig r;
	r.take(100, 5);
	r.holder.take_events();
	r.changes.clear();
	const std::vector<xfer::Entry> reported;
	const uint32_t mask = r.keeper.differs(r.peer, xfer::hash_of(reported));
	CHECK(mask != 0u);
	std::vector<xfer::Finding> found;
	std::vector<xfer::Packet> down = r.keeper.audit(r.peer, reported, mask, found);
	CHECK_EQ(found.size(), size_t(1));
	CHECK(found[0].kind == xfer::Violation::Lost);
	CHECK(r.keeper.away(100)); // until his answer: he may still hold it after all
	r.holder = xfer::Holder(7);
	r.to_client(down);
	CHECK(!r.keeper.away(100));
	CHECK(r.saw(Keeper::Kind::Unmark, 100));
	CHECK_EQ(r.keeper.ledger().counters().violations, uint64_t(1));
}

// He writes something the ledger gives nobody: he is told to let it go.
TEST(keeper_audit_a_duplicate_is_dropped_at_the_client)
{
	Rig r;
	r.keeper.connect(3);
	const xfer::Bytes fresh = state_of(5);
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	r.keeper.on_up(3, up, &fresh, r.now);
	r.drain();
	std::vector<xfer::Entry> reported;
	reported.push_back(Keeper::bare(xfer::Entry{100, 12345, xfer::kNoParent, true, 0}));
	std::vector<xfer::Finding> found;
	std::vector<xfer::Packet> down = r.keeper.audit(r.peer, reported, xfer::kAllBuckets, found);
	CHECK_EQ(found.size(), size_t(1));
	CHECK(found[0].kind == xfer::Violation::Duplicate);
	CHECK(!down.empty());
	CHECK(down[0].op == xfer::Op::Drop);
	CHECK_EQ(r.keeper.session_of(down[0].to), r.peer);
}

// A grant nobody commits (the client went quiet) comes home by itself, and the host's simulation goes on with it.
TEST(keeper_a_grant_lost_in_the_network_comes_home)
{
	Rig q;
	const xfer::Bytes fresh = state_of(5);
	xfer::Packet up{xfer::Op::TakeReq, xfer::Key{100, 0}, 7, xfer::kWorld, {}};
	std::vector<xfer::Packet> grant = q.keeper.on_up(q.peer, up, &fresh, q.now);
	CHECK_EQ(grant.size(), size_t(1));
	CHECK(q.keeper.away(100));
	q.now += xfer::kGrantTimeoutMs + 1;
	std::vector<xfer::Packet> abort = q.keeper.tick(q.now);
	CHECK(!abort.empty());
	CHECK(q.keeper.away(100)); // two-phase: frozen until his AbortAck
	q.to_client(abort);
	CHECK(!q.keeper.away(100));
}
