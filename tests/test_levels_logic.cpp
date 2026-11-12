// Anomaly Coop unit tests: what the binders of a level's static objects keep when its map server closes (xrCoop/coop_levels_logic.h,
// docs/SPLIT_LEVELS.md §7a). Which objects are watched, what counts as changed, the rounds of the look, what the world server takes, and
// the save a new map server may not start from.
#include "test_util.h"

#include "coop_levels_logic.h"
#include "coop_levels_wire.h"
#include "../engine/src/xrGame/coop/coop_levels_map.h" // pure: the rows of the world server's LevelMap

#include <string>
#include <vector>

using namespace coop;
using namespace coop::levels;

namespace
{
logic::Kind restrictor()
{
	logic::Kind k;
	k.keeps = true; // se_restrictor:keep_saved_data_anyway
	return k;
}

std::vector<uint8_t> bytes_of(const std::string& s) { return std::vector<uint8_t>(s.begin(), s.end()); }

uint64_t digest_of(const std::string& s)
{
	const std::vector<uint8_t> b = bytes_of(s);
	return logic::digest(b.data(), b.size());
}

// What CGameObject::net_Save leaves in a packet: u16 size, the chunk.
std::vector<uint8_t> chunk(const std::string& body)
{
	std::vector<uint8_t> out;
	out.push_back(uint8_t(body.size() & 0xff));
	out.push_back(uint8_t(body.size() >> 8));
	out.insert(out.end(), body.begin(), body.end());
	return out;
}

logic::Entity on_level(uint16_t level)
{
	logic::Entity e;
	e.exists = true;
	e.kind = restrictor();
	e.level = level;
	return e;
}

constexpr uint16_t kCordon = 1, kSwamp = 2;
} // namespace

// ---------------------------------------------------------------- which objects

TEST(logic_watches_what_the_stock_keeps_through_a_level_change)
{
	CHECK(logic::watched(restrictor(), true, true));
	logic::Kind changer; // se_level_changer does not keep it: its entity loses client_data with the level in the stock too
	CHECK(!logic::watched(changer, true, true));
}

TEST(logic_a_binder_that_saves_nothing_is_not_watched)
{
	CHECK(!logic::watched(restrictor(), false, true)); // no binder at all
	CHECK(!logic::watched(restrictor(), true, false)); // net_SaveRelevant false
}

TEST(logic_what_changes_hands_with_its_own_state_is_not_watched)
{
	logic::Kind eatable = restrictor(); // se_eatable keeps it, for the uses of the item
	eatable.item = true;
	CHECK(!logic::watched(eatable, true, true));
	logic::Kind creature = restrictor();
	creature.transfers = true;
	CHECK(!logic::watched(creature, true, true));
}

// ---------------------------------------------------------------- what changed

TEST(logic_digest_is_of_the_bytes)
{
	CHECK(digest_of("sr_idle@line_0") == digest_of("sr_idle@line_0"));
	CHECK(digest_of("sr_idle@line_0") != digest_of("sr_idle@line_1"));
	CHECK(digest_of("") != digest_of(std::string(1, '\0')));
}

TEST(logic_digest_skips_what_a_physics_object_writes_first)
{
	// CPhysicsShellHolder::save: enabled, disabled, not defined: it falls asleep by itself, that is no logic
	const std::vector<uint8_t> awake = bytes_of("\x01logic"), asleep = bytes_of("\x02logic"), other = bytes_of("\x01other");
	CHECK(logic::digest(awake.data(), awake.size(), 1) == logic::digest(asleep.data(), asleep.size(), 1));
	CHECK(logic::digest(awake.data(), awake.size(), 1) != logic::digest(other.data(), other.size(), 1));
	CHECK(logic::digest(awake.data(), awake.size()) != logic::digest(asleep.data(), asleep.size()));
}

TEST(logic_digest_of_less_than_it_skips_is_of_nothing)
{
	const std::vector<uint8_t> one = bytes_of("x");
	CHECK(logic::digest(one.data(), one.size(), 5) == logic::digest(nullptr, 0));
}

TEST(logic_chunk_body_is_what_the_entity_keeps)
{
	const std::vector<uint8_t> p = chunk("restrictor state");
	const uint8_t* body = nullptr;
	size_t size = 0;
	CHECK(logic::chunk_body(p.data(), p.size(), body, size));
	CHECK_EQ(size, size_t(16));
	CHECK(body == p.data() + 2);
}

TEST(logic_chunk_body_refuses_what_is_not_one_chunk)
{
	const uint8_t* body = nullptr;
	size_t size = 0;
	std::vector<uint8_t> p = chunk("abc");
	CHECK(!logic::chunk_body(p.data(), 1, body, size)); // no size
	CHECK(!logic::chunk_body(p.data(), p.size() - 1, body, size)); // cut
	p.push_back(0);
	CHECK(!logic::chunk_body(p.data(), p.size(), body, size)); // a tail: CPhysicObject::net_Save, not this call
}

TEST(logic_book_nothing_is_changed_before_it_is_met)
{
	logic::Book book;
	CHECK(!book.met(7));
	CHECK(!book.changed(7, 1)); // its binder never ran here: nothing happened to it
	CHECK(book.ids().empty());
}

// The defect: on_game_timer = 20 | sr_idle@line_1 %=create_squad(...)%: the first look must come before the first update of its logic.
TEST(logic_book_a_section_that_moved_is_changed_once)
{
	logic::Book book;
	const uint64_t before = digest_of("first update has not run");
	book.meet(7, true, before);
	CHECK(book.met(7));
	CHECK(!book.changed(7, before)); // a look with nothing done: nothing goes up
	const uint64_t moved = digest_of("sr_idle@line_1");
	CHECK(book.changed(7, moved));
	book.told(7, moved);
	CHECK(!book.changed(7, moved)); // the world server has it: the next round and the last one send nothing
	CHECK(book.changed(7, before));
}

TEST(logic_book_an_object_not_watched_is_never_changed)
{
	logic::Book book;
	book.meet(9, false, 5);
	CHECK(book.met(9)); // not looked at again
	CHECK(!book.changed(9, 6));
	CHECK(book.ids().empty());
	CHECK_EQ(book.watched(), size_t(0));
}

TEST(logic_book_lists_what_it_watches)
{
	logic::Book book;
	book.meet(3, true, 1);
	book.meet(4, false, 1);
	book.meet(5, true, 1);
	CHECK(book.ids() == std::vector<uint16_t>({3, 5}));
	CHECK_EQ(book.watched(), size_t(2));
	book.clear();
	CHECK(book.ids().empty());
	CHECK(!book.met(3));
}

// ---------------------------------------------------------------- the rounds

TEST(logic_round_takes_a_few_a_frame)
{
	logic::Round r;
	const std::vector<uint16_t> ids = {1, 2, 3, 4, 5};
	CHECK(r.take(ids, 100, 2, 1000) == std::vector<uint16_t>({1, 2}));
	CHECK(r.take(ids, 101, 2, 1000) == std::vector<uint16_t>({3, 4}));
	CHECK(r.take(ids, 102, 2, 1000) == std::vector<uint16_t>({5}));
}

TEST(logic_round_rests_between_rounds)
{
	logic::Round r;
	const std::vector<uint16_t> ids = {1, 2};
	CHECK(r.take(ids, 100, 2, 1000).size() == 2);
	CHECK(!r.due(101));
	CHECK(r.take(ids, 1099, 2, 1000).empty());
	CHECK(r.due(1100));
	CHECK(r.take(ids, 1100, 2, 1000).size() == 2);
}

TEST(logic_round_of_nothing_rests_too)
{
	logic::Round r;
	CHECK(r.take(std::vector<uint16_t>(), 100, 2, 1000).empty());
	CHECK(!r.due(500)); // the book is asked for its list once a round, not every frame
}

TEST(logic_round_a_list_that_shrank_does_not_read_past_it)
{
	logic::Round r;
	CHECK(r.take({1, 2, 3, 4}, 100, 3, 1000).size() == 3);
	CHECK(r.take({1, 2}, 101, 3, 1000).empty());
	CHECK(r.due(1101));
}

// ---------------------------------------------------------------- the world server

TEST(logic_host_takes_an_object_of_that_level)
{
	CHECK(logic::host_verdict(on_level(kSwamp), kSwamp) == logic::Verdict::Take);
}

TEST(logic_host_refuses_what_is_not_there)
{
	CHECK(logic::host_verdict(logic::Entity(), kSwamp) == logic::Verdict::NoObject);
}

TEST(logic_host_refuses_what_he_runs_himself)
{
	logic::Entity e = on_level(kSwamp);
	e.online = true; // his client_data comes from his own ClientSave
	CHECK(logic::host_verdict(e, kSwamp) == logic::Verdict::Online);
}

TEST(logic_host_refuses_another_level)
{
	CHECK(logic::host_verdict(on_level(kCordon), kSwamp) == logic::Verdict::OtherLevel);
	CHECK(logic::host_verdict(on_level(wire::kNoLevel), wire::kNoLevel) == logic::Verdict::OtherLevel);
}

TEST(logic_host_refuses_what_would_not_survive_his_load)
{
	logic::Entity e = on_level(kSwamp);
	e.kind.keeps = false; // CSE_ALifeDynamicObject::on_register would clear it on the next load
	CHECK(logic::host_verdict(e, kSwamp) == logic::Verdict::NotKept);
	e.kind = restrictor();
	e.kind.item = true;
	CHECK(logic::host_verdict(e, kSwamp) == logic::Verdict::NotKept);
	e.kind = restrictor();
	e.kind.transfers = true;
	CHECK(logic::host_verdict(e, kSwamp) == logic::Verdict::NotKept);
}

// The player came back while the map server of his level was still going: the save of his move is older than what it said last.
TEST(logic_a_save_older_than_the_last_word_of_the_level_is_stale)
{
	CHECK(!logic::save_is_stale(5000, false, 0)); // that level never said anything
	CHECK(!logic::save_is_stale(5000, true, 4999));
	CHECK(logic::save_is_stale(5000, true, 5000));
	CHECK(logic::save_is_stale(5000, true, 6000));
}

// ---------------------------------------------------------------- the wire

TEST(logic_wire_round_trip)
{
	wire::LevelLogicBody a;
	a.id = 4711;
	a.bytes = {1, 2, 3, 0, 255};
	Writer w;
	CHECK(a.write(w));
	Reader r(w.data().data(), w.size());
	wire::LevelLogicBody b;
	CHECK(b.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(b.id, a.id);
	CHECK(b.bytes == a.bytes);
}

TEST(logic_wire_a_writer_writes_nothing_it_cannot_send)
{
	wire::LevelLogicBody a;
	a.id = 1;
	a.bytes.assign(wire::LevelLogicBody::kMaxBytes + 1, 7);
	Writer w;
	CHECK(!a.write(w));
	CHECK_EQ(w.size(), size_t(0));
	a.bytes.clear();
	CHECK(!a.write(w)); // nothing to keep: an empty one would clear what the world server has
	a.bytes.assign(1, 7);
	a.id = wire::kNoObject;
	CHECK(!a.write(w));
	CHECK_EQ(w.size(), size_t(0));
}

TEST(logic_wire_the_last_good_size_goes)
{
	wire::LevelLogicBody a;
	a.id = 1;
	a.bytes.assign(wire::LevelLogicBody::kMaxBytes, 7);
	Writer w;
	CHECK(a.write(w));
	Reader r(w.data().data(), w.size());
	wire::LevelLogicBody b;
	CHECK(b.read(r));
	CHECK_EQ(b.bytes.size(), wire::LevelLogicBody::kMaxBytes);
}

TEST(logic_wire_a_cut_packet_is_refused)
{
	wire::LevelLogicBody a;
	a.id = 1;
	a.bytes = {1, 2, 3};
	Writer w;
	CHECK(a.write(w));
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		Reader r(w.data().data(), cut);
		wire::LevelLogicBody b;
		CHECK(!b.read(r));
		CHECK(b.bytes.empty());
	}
}

TEST(logic_wire_refuses_what_a_writer_would_not_write)
{
	Writer big;
	big.u16(1);
	big.u16(uint16_t(wire::LevelLogicBody::kMaxBytes + 1));
	Reader r1(big.data().data(), big.size());
	wire::LevelLogicBody b;
	CHECK(!b.read(r1));
	Writer empty;
	empty.u16(1);
	empty.u16(0);
	Reader r2(empty.data().data(), empty.size());
	CHECK(!b.read(r2));
	Writer nobody;
	nobody.u16(wire::kNoObject);
	nobody.u16(1);
	nobody.u8(9);
	Reader r3(nobody.data().data(), nobody.size());
	CHECK(!b.read(r3));
}

// ALife writes an object through a NET_Packet of 16 KiB (CALifeObjectRegistry::save), spawn data and state with it: the stock's limit
// for what the objects of a save message may hold (max_objects_size_in_save) is what an entity may be given.
TEST(logic_wire_what_it_carries_fits_an_object_of_a_save)
{
	CHECK_EQ(wire::LevelLogicBody::kMaxBytes, size_t(8 * 1024));
}

TEST(logic_wire_the_op_is_a_level_entity_op)
{
	Writer w;
	wire::LevelEntityHead h;
	h.op = wire::LevelEntityHead::Logic;
	h.write(w);
	Reader r(w.data().data(), w.size());
	wire::LevelEntityHead back;
	CHECK(back.read(r));
	CHECK_EQ(int(back.op), int(wire::LevelEntityHead::Logic));
}

// Plan 2026-11-12 §1.3 (stage 3): host_send_map lists the seats that play. The world server's own seat on a dedicated host (plays false,
// standing on fake_start) has no player row and its level no server row; an ordinary host's seat is listed as before.
namespace
{
Seat seat_of(uint32_t peer, uint16_t level, bool plays)
{
	Seat s;
	s.peer = peer;
	s.level = level;
	s.in_world = true;
	s.plays = plays;
	return s;
}
} // namespace

TEST(levels_map_leaves_out_a_seat_that_does_not_play)
{
	const uint16_t fake_start = 40, cordon = 1, garbage = 2;
	const std::vector<Seat> seats = {seat_of(0, fake_start, false), seat_of(1, cordon, true), seat_of(2, garbage, true),
	    seat_of(3, cordon, true)};
	const std::vector<Seat> rows = map_rows::listed_seats(seats);
	CHECK_EQ(rows.size(), size_t(3));
	CHECK_EQ(rows[0].peer, 1u);
	CHECK_EQ(rows[1].peer, 2u);
	CHECK_EQ(rows[2].peer, 3u);
	const std::vector<uint16_t> levels = map_rows::levels_of(seats);
	CHECK_EQ(levels.size(), size_t(2)); // fake_start has nobody who plays: no server row
	CHECK_EQ(levels[0], cordon);
	CHECK_EQ(levels[1], garbage);
}

TEST(levels_map_of_an_ordinary_host_is_unchanged)
{
	// every seat plays: the rows are the table, the levels those of the seats in order, a seat on no level adds none
	const std::vector<Seat> seats = {seat_of(0, 5, true), seat_of(1, 7, true), seat_of(2, kNoLevel, true), seat_of(3, 5, true)};
	const std::vector<Seat> rows = map_rows::listed_seats(seats);
	CHECK_EQ(rows.size(), seats.size());
	for (size_t i = 0; i < rows.size(); ++i)
		CHECK_EQ(rows[i].peer, seats[i].peer);
	const std::vector<uint16_t> levels = map_rows::levels_of(seats);
	CHECK_EQ(levels.size(), size_t(2));
	CHECK_EQ(levels[0], uint16_t(5));
	CHECK_EQ(levels[1], uint16_t(7));
	CHECK(map_rows::levels_of({}).empty());
}
