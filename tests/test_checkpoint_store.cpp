// Anomaly Coop unit tests: the pure part of the host checkpoint store (coop_checkpoint_store.h; F3 Task 6,
// CHECKPOINTS_DEATH.md §2): the CheckpointState message, the slot in the character's custom data, the arrival spots of
// a group level change and the client's mirror of the records the host shares.
#include "test_util.h"

#include "coop_checkpoint_store.h"

#include <cmath>
#include <limits>

using namespace coop;
using namespace coop::checkpoint;

namespace
{
Record rec(Kind kind, uint16_t source, const char* level = "l01_escape", float x = 1.0f)
{
	Record r;
	r.level = level;
	r.pos[0] = x;
	r.pos[1] = 2.5f;
	r.pos[2] = -3.25f;
	r.level_vertex = 4242;
	r.game_vertex = 17;
	r.kind = kind;
	r.source = source;
	r.game_time_ms = 123456789;
	return r;
}

bool same(const Record& a, const Record& b)
{
	return a.level == b.level && std::fabs(a.pos[0] - b.pos[0]) < 0.001f && std::fabs(a.pos[1] - b.pos[1]) < 0.001f &&
		std::fabs(a.pos[2] - b.pos[2]) < 0.001f && a.level_vertex == b.level_vertex && a.game_vertex == b.game_vertex &&
		a.kind == b.kind && a.source == b.source && a.game_time_ms == b.game_time_ms;
}

bool read_back(const Writer& w, StateMsg& out)
{
	Reader rd(w.ptr(), w.size());
	return read_state(rd, out);
}

size_t count_of(const std::string& text, const std::string& needle)
{
	size_t n = 0;
	for (size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + needle.size()))
		++n;
	return n;
}
} // namespace

// ---------------------------------------------------------------- CheckpointState

TEST(cps_state_roundtrip)
{
	const Record r = rec(Kind::Campfire, 321);
	Writer w;
	write_state(w, 7, false, r);
	StateMsg m;
	CHECK(read_back(w, m));
	CHECK_EQ(m.character, uint16_t(7));
	CHECK_EQ(m.flags, uint8_t(0));
	CHECK(!m.cleared());
	CHECK(!m.rollback());
	CHECK(same(m.record, r));

	Writer w2;
	write_state(w2, 0, true, r);
	StateMsg m2;
	CHECK(read_back(w2, m2));
	CHECK_EQ(m2.character, uint16_t(0));
	CHECK(m2.rollback());
	CHECK(!m2.cleared());
}

TEST(cps_state_cleared)
{
	// "No checkpoint" is a flag on the wire, never a record of kind None (CHECKPOINTS_DEATH.md §2.3).
	Writer w;
	write_state(w, 12, true, Record());
	CHECK_EQ(w.size(), size_t(3)); // u16 character + u8 flags, no record
	StateMsg m;
	CHECK(read_back(w, m));
	CHECK_EQ(m.character, uint16_t(12));
	CHECK(m.cleared());
	CHECK(m.rollback());
	CHECK(!m.record.valid());
}

TEST(cps_state_rejects)
{
	const Record good = rec(Kind::Tent, 55);
	StateMsg untouched;
	untouched.character = 99;

	// unknown flag bit
	{
		Writer w;
		w.u16(5);
		w.u8(4);
		write(w, good);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
		CHECK_EQ(m.character, uint16_t(99));
	}
	// "cleared" followed by a record
	{
		Writer w;
		w.u16(5);
		w.u8(kStateCleared);
		write(w, good);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// a record announced but missing (short packet)
	{
		Writer w;
		w.u16(5);
		w.u8(0);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// a record that is not valid (blank in the level name)
	{
		Record bad = good;
		bad.level = "l01 escape";
		Writer w;
		w.u16(5);
		w.u8(0);
		write(w, bad);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// a coordinate far outside any map
	{
		Record bad = good;
		bad.pos[1] = 5.0e7f;
		Writer w;
		w.u16(5);
		w.u8(0);
		write(w, bad);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// trailing bytes after the record
	{
		Writer w;
		write_state(w, 5, false, good);
		w.u8(0);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// no character
	{
		Writer w;
		write_state(w, 0xffff, false, good);
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
	}
	// empty packet
	{
		Writer w;
		StateMsg m = untouched;
		CHECK(!read_back(w, m));
		CHECK_EQ(m.character, uint16_t(99));
	}
}

// ---------------------------------------------------------------- custom data

TEST(cps_ini_roundtrip_keeps_other_lines)
{
	std::string text = "[coop]\r\nkey = 0123abcd\r\n[logic]\r\nactive = walker\r\n";
	Slot s;
	s.cur = rec(Kind::Tent, 77, "l02_garbage", 10.0f);
	s.prev = rec(Kind::Campfire, 66, "l01_escape", -20.0f);
	slot_to_ini(text, s);

	CHECK_EQ(count_of(text, "[coop_checkpoint]"), size_t(1));
	CHECK_EQ(count_of(text, "key = 0123abcd"), size_t(1));
	CHECK_EQ(count_of(text, "active = walker"), size_t(1));
	CHECK_EQ(count_of(text, "\r\n"), count_of(text, "\n")); // the text keeps its own line breaks

	unsigned corrupt = 9;
	const Slot back = slot_from_ini(text, &corrupt);
	CHECK_EQ(corrupt, 0u);
	CHECK(same(back.cur, s.cur));
	CHECK(same(back.prev, s.prev));

	// rewriting does not duplicate lines
	s.cur = rec(Kind::Rest, kNoSource, "l02_garbage", 11.0f);
	slot_to_ini(text, s);
	CHECK_EQ(count_of(text, "cur = "), size_t(1));
	CHECK_EQ(count_of(text, "prev = "), size_t(1));
	CHECK(same(slot_from_ini(text).cur, s.cur));
}

TEST(cps_ini_empty_record_erases_its_key)
{
	std::string text;
	Slot s;
	s.cur = rec(Kind::Campfire, 5);
	s.prev = rec(Kind::Story, kNoSource);
	slot_to_ini(text, s);
	CHECK_EQ(count_of(text, "prev = "), size_t(1));

	s.prev = Record(); // rolled back: no previous camp
	slot_to_ini(text, s);
	CHECK_EQ(count_of(text, "prev"), size_t(0));
	CHECK_EQ(count_of(text, "cur = "), size_t(1));

	s.cur = Record();
	slot_to_ini(text, s);
	CHECK_EQ(count_of(text, "cur"), size_t(0));
	const Slot back = slot_from_ini(text);
	CHECK(!back.cur.valid());
	CHECK(!back.prev.valid());
}

TEST(cps_ini_corrupt_and_orphan_prev)
{
	// A line that does not decode is no record (and counted); a previous record without a current one moves up, so a
	// later set() cannot push the empty current record over it.
	const Record prev = rec(Kind::Campfire, 8);
	std::string text = "[coop_checkpoint]\ncur = v1|l01_escape|nan|0|0|1|1|1|1|1\nprev = " + encode(prev) + "\n";
	unsigned corrupt = 0;
	const Slot s = slot_from_ini(text, &corrupt);
	CHECK_EQ(corrupt, 1u);
	CHECK(same(s.cur, prev));
	CHECK(!s.prev.valid());

	std::string only_prev = "[coop_checkpoint]\nprev = " + encode(prev) + "\n";
	corrupt = 5;
	const Slot s2 = slot_from_ini(only_prev, &corrupt);
	CHECK_EQ(corrupt, 0u);
	CHECK(same(s2.cur, prev));
	CHECK(!s2.prev.valid());

	CHECK(!slot_from_ini("").cur.valid());
	CHECK(!slot_from_ini("[coop]\nkey = x\n").cur.valid());
}

TEST(cps_ini_arrival_key)
{
	std::string text = "[coop_checkpoint]\ncur = " + encode(rec(Kind::Tent, 3)) + "\n";
	const Record a = rec(Kind::Arrival, kNoSource, "l03_agroprom", 100.0f);
	arrival_to_ini(text, a);
	Record back;
	bool corrupt = true;
	CHECK(arrival_from_ini(text, back, &corrupt));
	CHECK(!corrupt);
	CHECK(same(back, a));
	CHECK(same(slot_from_ini(text).cur, rec(Kind::Tent, 3))); // the slot is not touched

	arrival_to_ini(text, Record());
	CHECK_EQ(count_of(text, "arrival"), size_t(0));
	Record none = a;
	CHECK(!arrival_from_ini(text, none, &corrupt));
	CHECK(!corrupt);
	CHECK(same(none, a)); // untouched

	std::string bad = "[coop_checkpoint]\narrival = v1|x\n";
	CHECK(!arrival_from_ini(bad, none, &corrupt));
	CHECK(corrupt);
}

// ---------------------------------------------------------------- arrival spots

TEST(cps_arrival_spot)
{
	const float host[3] = {10.0f, 1.5f, -4.0f};
	float out[3] = {0, 0, 0};
	arrival_spot(host, 0, out);
	CHECK_EQ(out[0], 10.0f);
	CHECK_EQ(out[1], 1.5f);
	CHECK_EQ(out[2], -4.0f);
	arrival_spot(host, 3, out);
	CHECK(std::fabs(out[0] - 12.4f) < 0.0001f);
	CHECK_EQ(out[1], 1.5f);
	CHECK_EQ(out[2], -4.0f);
}

// ---------------------------------------------------------------- client mirror

TEST(cps_mirror_apply_and_clear)
{
	Mirror m;
	StateMsg s;
	s.character = 0;
	s.record = rec(Kind::Campfire, 40);
	CHECK(m.apply(0, s));
	const Record* got = m.get(0);
	CHECK(got != nullptr);
	if (got)
		CHECK(same(*got, s.record));
	CHECK(m.get(1) == nullptr);

	s.record = rec(Kind::Tent, 41);
	CHECK(m.apply(0, s));
	CHECK(m.get(0) && m.get(0)->kind == Kind::Tent);
	CHECK_EQ(m.size(), size_t(1));

	StateMsg cleared;
	cleared.character = 0;
	cleared.flags = kStateCleared;
	CHECK(m.apply(0, cleared));
	CHECK(m.get(0) == nullptr);
	CHECK_EQ(m.size(), size_t(0));

	CHECK(m.apply(3, s));
	m.clear();
	CHECK(m.get(3) == nullptr);
}

TEST(cps_mirror_bounded)
{
	Mirror m;
	StateMsg s;
	s.record = rec(Kind::Story, kNoSource);
	for (uint16_t id = 0; id < kMaxSlots; ++id)
		CHECK(m.apply(id, s));
	CHECK_EQ(m.size(), kMaxSlots);

	// a new id over the bound is refused, known ids still update and clear
	CHECK(!m.apply(uint16_t(kMaxSlots), s));
	CHECK(m.get(uint16_t(kMaxSlots)) == nullptr);
	StateMsg tent;
	tent.record = rec(Kind::Tent, 9);
	CHECK(m.apply(5, tent));
	CHECK(m.get(5) && m.get(5)->kind == Kind::Tent);
	StateMsg cleared;
	cleared.flags = kStateCleared;
	CHECK(m.apply(6, cleared));
	CHECK_EQ(m.size(), kMaxSlots - 1);
	CHECK(m.apply(uint16_t(kMaxSlots), s)); // room again
	// clearing an id that is not kept is not an error and keeps nothing
	CHECK(m.apply(uint16_t(kMaxSlots + 1), cleared));
	CHECK_EQ(m.size(), kMaxSlots);
}
