// Anomaly Coop unit tests: the layout of a player's equipment (coop_gear.h).
// Live bug 2026-10-23 (build 9, GAMMA, owner): "all my gear came off and lay in the backpack, as if I had just entered
// the game as a new player". Cause: the client's slots and belt exist only on his machine. A player who comes back
// (reconnect after a device reset, a level change, a restarted game) loads the host's save, where his character is a
// CAI_Stalker proxy that went offline (its items lose their client data, so their place), and every item with
// default_to_ruck (outfit, helmet, backpack, artefacts, detector, PDA) lands in the backpack. The client now reports
// the layout with PlayerVitals, the host keeps it in the proxy's custom data, and the client's items are placed by it
// when they spawn.
#include "test_util.h"

#include "coop_checkpoint_rules.h"
#include "coop_gear.h"

#include <algorithm>
#include <string>
#include <vector>

using namespace coop;
using namespace coop::gear;

namespace
{
constexpr uint8_t kLastSlot = 13; // BACKPACK_SLOT in stock Anomaly (inventory_space.h)

Entry slot_of(uint16_t item, const char* section, uint8_t slot)
{
	Entry e;
	e.item = item;
	e.tag = tag_of(section);
	e.place = Place::Slot;
	e.slot = slot;
	return e;
}

Entry belt_of(uint16_t item, const char* section)
{
	Entry e;
	e.item = item;
	e.tag = tag_of(section);
	e.place = Place::Belt;
	return e;
}

Entry ruck_of(uint16_t item, const char* section)
{
	Entry e;
	e.item = item;
	e.tag = tag_of(section);
	e.place = Place::Ruck;
	return e;
}

// What a player has on: armour, helmet, backpack, a rifle and a pistol, a detector, two artefacts, a spare rifle he
// keeps in the backpack on purpose.
std::vector<Entry> sample_layout()
{
	return {
		slot_of(34100, "wpn_ak74", 3),        slot_of(34101, "wpn_pm", 2),     slot_of(34102, "wpn_knife", 1),
		slot_of(34103, "outfit_stalker_m1", 7), slot_of(34104, "helm_battle", 12), slot_of(34105, "backpack_1", 13),
		slot_of(34106, "detector_advanced", 9), belt_of(34107, "af_medusa"),    belt_of(34108, "af_soul"),
		ruck_of(34109, "wpn_mp5"),
	};
}

std::vector<uint8_t> vitals_prefix()
{
	Writer w(32);
	for (int i = 0; i < 6; ++i)
		w.f32(0.5f);
	return w.data();
}
} // namespace

TEST(gear_tag_tells_sections_apart_and_is_stable)
{
	CHECK_EQ(tag_of("wpn_ak74"), tag_of("wpn_ak74"));
	CHECK(tag_of("wpn_ak74") != tag_of("wpn_akm"));
	CHECK(tag_of("outfit_stalker_m1") != tag_of("outfit_stalker_m2"));
	CHECK(tag_of("") == tag_of(""));
}

TEST(gear_wire_round_trip)
{
	const std::vector<Entry> in = sample_layout();
	Writer w(64);
	write_tail(w, in);
	CHECK(w.size() < 4 + 5 * in.size()); // a layout is a few dozen bytes, not a message of its own

	Reader r(w.ptr(), w.size());
	std::vector<Entry> out;
	CHECK(read_tail(r, out, kLastSlot) == TailRead::Ok);
	CHECK(out == in);
	CHECK_EQ(r.remaining(), size_t(0));
}

TEST(gear_wire_old_sender_has_no_tail)
{
	// A PlayerVitals of a client without this tail ends after the six floats: not an error, the host keeps what it has.
	const std::vector<uint8_t> prefix = vitals_prefix();
	Reader r(prefix.data() + prefix.size(), 0);
	std::vector<Entry> out = {slot_of(1, "x", 1)};
	CHECK(read_tail(r, out, kLastSlot) == TailRead::Absent);
	CHECK(out.empty());
}

TEST(gear_wire_tail_follows_the_vitals)
{
	Writer w(96);
	for (int i = 0; i < 6; ++i)
		w.f32(0.25f * float(i));
	write_tail(w, sample_layout());

	Reader r(w.ptr(), w.size());
	for (int i = 0; i < 6; ++i)
		CHECK(r.f32() == 0.25f * float(i));
	std::vector<Entry> out;
	CHECK(read_tail(r, out, kLastSlot) == TailRead::Ok);
	CHECK_EQ(out.size(), sample_layout().size());
}

TEST(gear_wire_truncated_tail_is_refused_whole)
{
	Writer w(64);
	write_tail(w, sample_layout());
	for (size_t cut = 1; cut < w.size(); ++cut)
	{
		Reader r(w.ptr(), cut);
		std::vector<Entry> out;
		const TailRead res = read_tail(r, out, kLastSlot);
		CHECK(res == TailRead::Bad);
		CHECK(out.empty()); // half a layout would move half of the player's things
	}
}

TEST(gear_wire_hostile_count_is_refused_without_reading_on)
{
	Writer w(16);
	w.u8(1); // version
	w.varu(0xffffff); // millions of entries
	Reader r(w.ptr(), w.size());
	std::vector<Entry> out;
	CHECK(read_tail(r, out, kLastSlot) == TailRead::Bad);
	CHECK(out.empty());

	Writer v(16);
	v.u8(99); // a version this build does not know
	v.varu(0);
	Reader rv(v.ptr(), v.size());
	CHECK(read_tail(rv, out, kLastSlot) == TailRead::Bad);
}

TEST(gear_wire_drops_entries_that_make_no_sense)
{
	// A modified client: a slot that does not exist, place 0, the same item twice, the same slot twice.
	Writer w(64);
	w.u8(1);
	w.varu(5);
	const auto put = [&](uint16_t item, uint16_t tag, uint8_t place, uint8_t slot)
	{
		w.u16(item);
		w.u16(tag);
		w.u8(uint8_t((place << 6) | slot));
	};
	put(10, 1, 1, 3); // fine
	put(11, 1, 1, 40); // no such slot
	put(10, 1, 1, 4); // the same item again
	put(12, 1, 1, 3); // the same slot again
	put(13, 1, 2, 0); // fine, the belt
	Reader r(w.ptr(), w.size());
	std::vector<Entry> out;
	CHECK(read_tail(r, out, kLastSlot) == TailRead::Ok);
	REQUIRE(out.size() == 2);
	CHECK_EQ(out[0].item, uint16_t(10));
	CHECK_EQ(out[1].item, uint16_t(13));
}

TEST(gear_sanitize_keeps_the_first_of_each_and_the_cap)
{
	std::vector<Entry> v = sample_layout();
	v.push_back(slot_of(34100, "wpn_ak74", 5)); // item again
	v.push_back(slot_of(40000, "wpn_x", 3)); // slot 3 again
	v.push_back(slot_of(40001, "wpn_y", 0)); // slot 0 is "no slot"
	v.push_back(slot_of(40002, "wpn_z", 14)); // past the last slot
	Entry bad_belt = belt_of(40003, "af_x");
	bad_belt.slot = 5; // a belt item has no slot: normalized, not refused
	v.push_back(bad_belt);
	const size_t dropped = sanitize(v, kLastSlot);
	CHECK_EQ(dropped, size_t(4));
	CHECK_EQ(v.size(), sample_layout().size() + 1);
	CHECK_EQ(v.back().item, uint16_t(40003));
	CHECK_EQ(v.back().slot, uint8_t(0));

	std::vector<Entry> many;
	for (uint16_t i = 0; i < 400; ++i)
		many.push_back(ruck_of(uint16_t(1000 + i), "wpn_pm"));
	sanitize(many, kLastSlot);
	CHECK_EQ(many.size(), kMaxEntries);
	CHECK_EQ(many.front().item, uint16_t(1000)); // the front stays: slots and belt come first in a capture

	std::vector<Entry> none_id = {slot_of(0xffff, "wpn_pm", 2)};
	CHECK_EQ(sanitize(none_id, kLastSlot), size_t(1));
	CHECK(none_id.empty());
}

TEST(gear_text_round_trip)
{
	const std::vector<Entry> in = sample_layout();
	const std::string text = to_text(in);
	CHECK(!text.empty());
	CHECK(text.find('\n') == std::string::npos); // one ini line
	CHECK(text.find(';') == std::string::npos); // ';' starts a comment in an ini
	CHECK(text.find('=') == std::string::npos);
	std::vector<Entry> out;
	CHECK_EQ(from_text(text, out, kLastSlot), size_t(0));
	CHECK(out == in);
}

TEST(gear_text_of_nothing_is_nothing)
{
	CHECK(to_text({}).empty());
	std::vector<Entry> out = {slot_of(1, "x", 1)};
	CHECK_EQ(from_text("", out, kLastSlot), size_t(0));
	CHECK(out.empty());
}

TEST(gear_text_skips_garbage_and_keeps_the_rest)
{
	std::vector<Entry> in = {slot_of(34103, "outfit_stalker_m1", 7), belt_of(34107, "af_medusa")};
	std::string text = to_text(in);
	const std::string garbage = "zz.1.S3,,8e1f.3a7c.Q9,12345678.1.S2,1.2,8e1f.3a7c.S99," + text + ",";
	std::vector<Entry> out;
	const size_t bad = from_text(garbage, out, kLastSlot);
	CHECK(bad >= 5);
	CHECK(out == in);
}

TEST(gear_text_of_the_biggest_layout_fits_an_ini_line)
{
	// CInifile reads a line into a 4096 byte buffer.
	std::vector<Entry> many;
	for (uint16_t i = 0; i < 400; ++i)
		many.push_back(ruck_of(uint16_t(0xf000 + i), "wpn_pm"));
	sanitize(many, kLastSlot);
	CHECK(to_text(many).size() < 3000);
}

TEST(gear_table_finds_by_item_and_section)
{
	Table t;
	t.load(sample_layout());
	CHECK_EQ(t.size(), sample_layout().size());
	const Entry* outfit = t.find(34103, tag_of("outfit_stalker_m1"));
	REQUIRE(outfit != nullptr);
	CHECK(outfit->place == Place::Slot);
	CHECK_EQ(outfit->slot, uint8_t(7));
	const Entry* af = t.find(34107, tag_of("af_medusa"));
	REQUIRE(af != nullptr);
	CHECK(af->place == Place::Belt);
	// the id was given to another thing since (a stash, a trade): not the item the layout means
	CHECK(t.find(34103, tag_of("wpn_pm")) == nullptr);
	CHECK(t.find(1, tag_of("outfit_stalker_m1")) == nullptr);
}

TEST(gear_custom_data_keeps_the_rest_of_the_character)
{
	// The proxy's custom data as the host writes it: the key, the nick, the vitals line, a checkpoint section.
	std::string ini =
	    "[coop]\nkey = 0123456789abcdef\nnick = player_b\nvitals = 1.000,0.890,0.000,1.000,1.000,0.000\n"
	    "[coop_checkpoint]\nslot_1 = l01_escape\n";
	const std::string before = ini;
	checkpoint::ini_set(ini, "coop", "gear", to_text(sample_layout()));

	std::string value;
	REQUIRE(checkpoint::ini_get(ini, "coop", "gear", value));
	std::vector<Entry> out;
	from_text(value, out, kLastSlot);
	CHECK(out == sample_layout());
	std::string nick, key, slot1;
	CHECK(checkpoint::ini_get(ini, "coop", "nick", nick) && nick == "player_b");
	CHECK(checkpoint::ini_get(ini, "coop", "key", key) && key == "0123456789abcdef");
	CHECK(checkpoint::ini_get(ini, "coop_checkpoint", "slot_1", slot1) && slot1 == "l01_escape");
	CHECK(ini.find("vitals = 1.000,0.890") != std::string::npos);

	// a second report replaces the first one, it does not pile up
	std::vector<Entry> now = {slot_of(34103, "outfit_stalker_m1", 7)};
	checkpoint::ini_set(ini, "coop", "gear", to_text(now));
	size_t lines = 0, at = 0;
	while ((at = ini.find("gear = ", at)) != std::string::npos)
	{
		++lines;
		at += 7;
	}
	CHECK_EQ(lines, size_t(1));
	REQUIRE(checkpoint::ini_get(ini, "coop", "gear", value));
	from_text(value, out, kLastSlot);
	CHECK(out == now);
	(void)before;
}

TEST(gear_rejoin_gives_every_item_the_place_it_had)
{
	// The client reports (wire), the host keeps it in the proxy's custom data (text), the client reads it back while its
	// items spawn (table). Every carried item must come out where it was; an item the layout does not know stays unplaced
	// (the engine puts it by its own default).
	const std::vector<Entry> carried = sample_layout();

	Writer w(128);
	for (int i = 0; i < 6; ++i)
		w.f32(1.f);
	write_tail(w, carried);

	Reader host(w.ptr(), w.size());
	for (int i = 0; i < 6; ++i)
		host.f32();
	std::vector<Entry> reported;
	REQUIRE(read_tail(host, reported, kLastSlot) == TailRead::Ok);
	std::string custom = "[coop]\nkey = 0123456789abcdef\n";
	checkpoint::ini_set(custom, "coop", "gear", to_text(reported));

	std::string value;
	REQUIRE(checkpoint::ini_get(custom, "coop", "gear", value));
	std::vector<Entry> stored;
	from_text(value, stored, kLastSlot);
	Table table;
	table.load(stored);

	for (const Entry& e : carried)
	{
		const Entry* found = table.find(e.item, e.tag);
		REQUIRE(found != nullptr);
		CHECK(found->place == e.place);
		CHECK_EQ(found->slot, e.slot);
	}
	CHECK(table.find(50000, tag_of("wpn_ak74")) == nullptr); // picked up after the last report
}
