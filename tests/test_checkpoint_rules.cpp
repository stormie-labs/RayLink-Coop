// Anomaly Coop unit tests: checkpoint rules (coop_checkpoint_rules.h; F3 Task 3, CHECKPOINTS_DEATH.md §2):
// the record and its text/wire forms, the two-deep slot, the respawn choice, the campfire dwell timer and the
// custom-data ini helpers.
#include "test_util.h"

#include "coop_checkpoint_rules.h"

#include <cmath>
#include <limits>

using namespace coop::checkpoint;

namespace
{
Record make(Kind kind, uint16_t source, const char* level = "l01_escape", float x = 1.0f)
{
	Record r;
	r.level = level;
	r.pos[0] = x;
	r.pos[1] = 2.0f;
	r.pos[2] = 3.0f;
	r.level_vertex = 100;
	r.game_vertex = 7;
	r.kind = kind;
	r.source = source;
	r.game_time_ms = 1000;
	return r;
}

bool same(const Record& a, const Record& b)
{
	return a.level == b.level && a.pos[0] == b.pos[0] && a.pos[1] == b.pos[1] && a.pos[2] == b.pos[2] &&
		a.level_vertex == b.level_vertex && a.game_vertex == b.game_vertex && a.kind == b.kind &&
		a.source == b.source && a.game_time_ms == b.game_time_ms;
}

bool near_pos(const float a[3], const float b[3])
{
	for (int i = 0; i < 3; ++i)
		if (std::fabs(a[i] - b[i]) > 0.001f)
			return false;
	return true;
}

size_t count_of(const std::string& text, const std::string& needle)
{
	size_t n = 0;
	for (size_t at = text.find(needle); at != std::string::npos; at = text.find(needle, at + needle.size()))
		++n;
	return n;
}
} // namespace

TEST(cp_kind_names)
{
	CHECK_EQ(std::string(kind_name(Kind::None)), std::string("none"));
	CHECK_EQ(std::string(kind_name(Kind::Campfire)), std::string("campfire"));
	CHECK_EQ(std::string(kind_name(Kind::Rest)), std::string("rest"));
	CHECK_EQ(std::string(kind_name(Kind::Tent)), std::string("tent"));
	CHECK_EQ(std::string(kind_name(Kind::Arrival)), std::string("arrival"));
	CHECK_EQ(std::string(kind_name(Kind::Story)), std::string("story"));
	CHECK_EQ(std::string(kind_name(Kind::Mod)), std::string("mod"));
	CHECK_EQ(std::string(kind_name(static_cast<Kind>(99))), std::string("none"));
}

TEST(cp_level_ok)
{
	CHECK(level_ok("l01_escape"));
	CHECK(level_ok("a"));
	CHECK(level_ok(std::string(64, 'x')));
	CHECK(!level_ok(""));
	CHECK(!level_ok(std::string(65, 'x')));
	CHECK(!level_ok("l01 escape"));
	CHECK(!level_ok("l01|escape"));
	CHECK(!level_ok("l01-escape"));
	CHECK(!level_ok(std::string("l01\0x", 5)));
}

TEST(cp_record_valid)
{
	CHECK(make(Kind::Campfire, 1).valid());
	CHECK(!make(Kind::None, 1).valid());
	CHECK(!make(Kind::Campfire, 1, "bad level").valid());
	Record r = make(Kind::Campfire, 1);
	r.pos[1] = std::numeric_limits<float>::quiet_NaN();
	CHECK(!r.valid());
	r = make(Kind::Campfire, 1);
	r.pos[2] = std::numeric_limits<float>::infinity();
	CHECK(!r.valid());
	CHECK(!Record().valid());
}

TEST(cp_encode_roundtrip)
{
	Record a;
	a.level = "l01_escape";
	a.pos[0] = -123.456f;
	a.pos[1] = 7.5f;
	a.pos[2] = 88.125f;
	a.level_vertex = 12345;
	a.game_vertex = 77;
	a.kind = Kind::Campfire;
	a.source = 4321;
	a.game_time_ms = 3600000;

	const std::string line = encode(a);
	CHECK_EQ(line, std::string("v1|l01_escape|-123.456|7.500|88.125|12345|77|1|4321|3600000"));

	Record b;
	REQUIRE(decode(line, b));
	CHECK_EQ(b.level, a.level);
	CHECK(near_pos(a.pos, b.pos));
	CHECK_EQ(b.level_vertex, a.level_vertex);
	CHECK_EQ(b.game_vertex, a.game_vertex);
	CHECK(b.kind == a.kind);
	CHECK_EQ(b.source, a.source);
	CHECK_EQ(b.game_time_ms, a.game_time_ms);

	// The "no vertex, no source" defaults and the largest time survive too.
	Record c = make(Kind::Arrival, kNoSource);
	c.level_vertex = 0xffffffff;
	c.game_vertex = 0xffff;
	c.game_time_ms = 0xffffffffffffffffull;
	Record d;
	REQUIRE(decode(encode(c), d));
	CHECK(same(c, d));

	// A record that is not valid has no text form.
	CHECK_EQ(encode(Record()), std::string());
	CHECK_EQ(encode(make(Kind::Campfire, 1, "bad|level")), std::string());
}

TEST(cp_decode_rejects)
{
	const std::string lvl65(65, 'x');
	const std::string bad[] = {
		"",
		"v2|l01_escape|1.000|2.000|3.000|1|2|1|3|4",
		"v1|l01_escape|1.000|2.000|3.000|1|2|1|3",         // 9 fields
		"v1|l01_escape|1.000|2.000|3.000|1|2|1|3|4|5",     // 11 fields
		"v1|l01_escape|nan|2.000|3.000|1|2|1|3|4",        // nan in x
		"v1|l01_escape|1.000|inf|3.000|1|2|1|3|4",        // inf in y
		"v1|l01_escape|1.000|2.000|1e999|1|2|1|3|4",      // overflows to inf
		"v1|l01_escape|1.000|2.000|3.000x|1|2|1|3|4",     // trailing junk
		"v1|l01_escape| 1.000|2.000|3.000|1|2|1|3|4",     // blank in a number
		"v1|l01_escape||2.000|3.000|1|2|1|3|4",           // empty number
		"v1|l01 escape|1.000|2.000|3.000|1|2|1|3|4",      // blank in the level
		"v1||1.000|2.000|3.000|1|2|1|3|4",                // empty level
		"v1|" + lvl65 + "|1.000|2.000|3.000|1|2|1|3|4",   // 65-char level
		"v1|l01_escape|1.000|2.000|3.000|1|2|7|3|4",      // kind 7
		"v1|l01_escape|1.000|2.000|3.000|1|2|0|3|4",      // kind none is no record
		"v1|l01_escape|1.000|2.000|3.000|1|2|-1|3|4",     // negative kind
		"v1|l01_escape|1.000|2.000|3.000|abc|2|1|3|4",    // lv = abc
		"v1|l01_escape|1.000|2.000|3.000|-1|2|1|3|4",     // negative lv
		"v1|l01_escape|1.000|2.000|3.000|4294967296|2|1|3|4", // lv over 32 bits
		"v1|l01_escape|1.000|2.000|3.000|1|65536|1|3|4",  // gv over 16 bits
		"v1|l01_escape|1.000|2.000|3.000|1|2|1|65536|4",  // source over 16 bits
		"v1|l01_escape|1.000|2.000|3.000|1|2|1|3|4x",     // trailing junk in the time
		"v1|l01_escape|1.000|2.000|3.000|1|2|1|3|18446744073709551616", // time over 64 bits
	};
	for (const std::string& line : bad)
	{
		Record out = make(Kind::Tent, 9, "l05_bar", 5.0f);
		const Record before = out;
		const bool ok = decode(line, out);
		if (ok)
			t::report_failure(__FILE__, __LINE__, "decode accepted: " + line);
		if (!same(out, before))
			t::report_failure(__FILE__, __LINE__, "decode touched out on: " + line);
	}
}

TEST(cp_slot_set_shift)
{
	const Record A = make(Kind::Campfire, 5, "l01_escape", 1.0f);
	const Record B = make(Kind::Tent, 10, "l01_escape", 2.0f);
	Slot s;
	CHECK(!s.cur.valid());
	CHECK(!s.prev.valid());

	set(s, A);
	CHECK(same(s.cur, A));
	CHECK(!s.prev.valid());

	set(s, B);
	CHECK(same(s.cur, B));
	CHECK(same(s.prev, A));

	// The same source and kind again refreshes the current record only.
	Record B2 = B;
	B2.pos[0] = 9.0f;
	B2.game_time_ms = 5000;
	set(s, B2);
	CHECK(same(s.cur, B2));
	CHECK(same(s.prev, A));

	// The same kind of another source shifts; so does the same source of another kind.
	set(s, make(Kind::Tent, 11));
	CHECK_EQ(s.cur.source, uint16_t(11));
	CHECK(same(s.prev, B2));
	set(s, make(Kind::Rest, 11));
	CHECK(s.cur.kind == Kind::Rest);
	CHECK(s.prev.kind == Kind::Tent);

	// An arrival point has no source: a second one replaces the first.
	Slot a;
	set(a, make(Kind::Campfire, 5));
	set(a, make(Kind::Arrival, kNoSource, "l02_garbage", 1.0f));
	set(a, make(Kind::Arrival, kNoSource, "l03_agroprom", 4.0f));
	CHECK(a.cur.level == "l03_agroprom");
	CHECK(a.prev.kind == Kind::Campfire);

	// A record that is not valid is ignored.
	Slot z;
	set(z, A);
	set(z, Record());
	CHECK(same(z.cur, A));
	CHECK(!z.prev.valid());
}

TEST(cp_slot_source_lost)
{
	const Record fire = make(Kind::Campfire, 5, "l01_escape", 1.0f);
	const Record tent = make(Kind::Tent, 10, "l01_escape", 2.0f);

	// The current record's source is gone: the previous one takes over.
	Slot s;
	s.cur = tent;
	s.prev = fire;
	CHECK(source_lost(s, 10));
	CHECK(same(s.cur, fire));
	CHECK(!s.prev.valid());

	// Nothing from that source: unchanged.
	Slot u;
	u.cur = tent;
	u.prev = fire;
	CHECK(!source_lost(u, 99));
	CHECK(same(u.cur, tent));
	CHECK(same(u.prev, fire));

	// Only the previous record was from it.
	Slot p;
	p.cur = fire;
	p.prev = tent;
	CHECK(source_lost(p, 10));
	CHECK(same(p.cur, fire));
	CHECK(!p.prev.valid());

	// The only record is gone: the slot is empty.
	Slot o;
	o.cur = fire;
	CHECK(source_lost(o, 5));
	CHECK(!o.cur.valid());
	CHECK(!o.prev.valid());

	// Records without a source (arrival, story) are never lost with "no source".
	Slot n;
	n.cur = make(Kind::Arrival, kNoSource);
	n.prev = make(Kind::Story, kNoSource);
	CHECK(!source_lost(n, kNoSource));
	CHECK(n.cur.valid());
	CHECK(n.prev.valid());

	// Both records from one source (a rest spot and a campfire share an id): both go.
	Slot b;
	b.cur = make(Kind::Rest, 8);
	b.prev = make(Kind::Campfire, 8);
	CHECK(source_lost(b, 8));
	CHECK(!b.cur.valid());
	CHECK(!b.prev.valid());
}

TEST(cp_resolve_chain)
{
	const float body[3] = {10, 20, 30};
	const float anchor[3] = {40, 50, 60};
	const float arrival[3] = {70, 80, 90};
	const std::string here = "l01_escape";

	// The current record is on this level.
	{
		Slot s;
		s.cur = make(Kind::Campfire, 1, "l01_escape", 5.0f);
		s.prev = make(Kind::Tent, 2, "l01_escape", 6.0f);
		const Choice c = resolve(s, here, anchor, arrival, body);
		CHECK(c.pick == Pick::Current);
		CHECK(near_pos(c.pos, s.cur.pos));
	}
	// The current one is on another level, the previous one is here.
	{
		Slot s;
		s.cur = make(Kind::Campfire, 1, "l02_garbage", 5.0f);
		s.prev = make(Kind::Tent, 2, "l01_escape", 6.0f);
		const Choice c = resolve(s, here, anchor, arrival, body);
		CHECK(c.pick == Pick::Previous);
		CHECK(near_pos(c.pos, s.prev.pos));
	}
	// Both on another level: the anchor, then the arrival point, then the body.
	{
		Slot s;
		s.cur = make(Kind::Campfire, 1, "l02_garbage", 5.0f);
		s.prev = make(Kind::Tent, 2, "l02_garbage", 6.0f);
		const Choice a = resolve(s, here, anchor, arrival, body);
		CHECK(a.pick == Pick::Anchor);
		CHECK(near_pos(a.pos, anchor));
		const Choice b = resolve(s, here, nullptr, arrival, body);
		CHECK(b.pick == Pick::Arrival);
		CHECK(near_pos(b.pos, arrival));
		const Choice c = resolve(s, here, nullptr, nullptr, body);
		CHECK(c.pick == Pick::Body);
		CHECK(near_pos(c.pos, body));
	}
	// Nothing recorded at all.
	{
		const Slot s;
		const Choice c = resolve(s, here, nullptr, nullptr, body);
		CHECK(c.pick == Pick::Body);
		CHECK(near_pos(c.pos, body));
		CHECK(resolve(s, here, anchor, nullptr, body).pick == Pick::Anchor);
		CHECK(resolve(s, here, nullptr, arrival, body).pick == Pick::Arrival);
	}
	// A previous record alone on this level.
	{
		Slot s;
		s.prev = make(Kind::Rest, 3, "l01_escape", 7.0f);
		CHECK(resolve(s, here, anchor, arrival, body).pick == Pick::Previous);
	}
	// The level compares exactly, not by prefix or case.
	{
		Slot s;
		s.cur = make(Kind::Campfire, 1, "l01_escape_2", 5.0f);
		CHECK(resolve(s, here, nullptr, nullptr, body).pick == Pick::Body);
		s.cur = make(Kind::Campfire, 1, "L01_ESCAPE", 5.0f);
		CHECK(resolve(s, here, nullptr, nullptr, body).pick == Pick::Body);
	}
}

TEST(cp_dwell)
{
	constexpr uint32_t kDwell = 5000;

	// Standing at source 7: once, at 5 s; leaving and coming back starts a new visit.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, false, 0, kDwell));
		CHECK(!dwell_update(d, 7, false, 4999, kDwell));
		CHECK(dwell_update(d, 7, false, 5000, kDwell));
		CHECK(!dwell_update(d, 7, false, 6000, kDwell));
		CHECK(!dwell_update(d, kNoSource, false, 6500, kDwell));
		CHECK(!dwell_update(d, 7, false, 7000, kDwell));
		CHECK(!dwell_update(d, 7, false, 11999, kDwell));
		CHECK(dwell_update(d, 7, false, 12000, kDwell));
		CHECK(!dwell_update(d, 7, false, 20000, kDwell));
	}
	// A fight restarts the count: not before 5 s after the last fight tick.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, false, 0, kDwell));
		CHECK(!dwell_update(d, 7, true, 3000, kDwell));
		CHECK(!dwell_update(d, 7, false, 7999, kDwell));
		CHECK(dwell_update(d, 7, false, 8000, kDwell));
	}
	// A fight that lasts keeps pushing the count.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, false, 0, kDwell));
		for (uint64_t tick = 1000; tick <= 20000; tick += 1000)
			CHECK(!dwell_update(d, 7, true, tick, kDwell));
		CHECK(!dwell_update(d, 7, false, 24999, kDwell));
		CHECK(dwell_update(d, 7, false, 25000, kDwell));
	}
	// Arriving in the middle of a fight: the count starts when the fight ends.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, true, 1000, kDwell));
		CHECK(!dwell_update(d, 7, false, 5999, kDwell));
		CHECK(dwell_update(d, 7, false, 6000, kDwell));
	}
	// Another source starts over, and its own count is full.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, false, 0, kDwell));
		CHECK(!dwell_update(d, 7, false, 4000, kDwell));
		CHECK(!dwell_update(d, 8, false, 4500, kDwell));
		CHECK(!dwell_update(d, 8, false, 9499, kDwell));
		CHECK(dwell_update(d, 8, false, 9500, kDwell));
		// ... and after firing at 7, moving to 8 fires there too.
		Dwell e;
		CHECK(!dwell_update(e, 7, false, 0, kDwell));
		CHECK(dwell_update(e, 7, false, 5000, kDwell));
		CHECK(!dwell_update(e, 8, false, 5100, kDwell));
		CHECK(dwell_update(e, 8, false, 10100, kDwell));
	}
	// A fight after the checkpoint was set does not set it again in the same visit.
	{
		Dwell d;
		CHECK(!dwell_update(d, 7, false, 0, kDwell));
		CHECK(dwell_update(d, 7, false, 5000, kDwell));
		CHECK(!dwell_update(d, 7, true, 6000, kDwell));
		CHECK(!dwell_update(d, 7, false, 20000, kDwell));
	}
	// No dwell time: fires on the first tick; the clock never runs backwards into a false fire.
	{
		Dwell d;
		CHECK(dwell_update(d, 3, false, 100, 0));
		CHECK(!dwell_update(d, 3, false, 200, 0));
		Dwell e;
		CHECK(!dwell_update(e, 3, false, 10000, kDwell));
		CHECK(!dwell_update(e, 3, false, 100, kDwell));
		CHECK(!dwell_update(e, 3, false, 5099, kDwell));
		CHECK(dwell_update(e, 3, false, 5100, kDwell));
	}
}

TEST(cp_ini_keeps_other_sections)
{
	std::string text = "[coop]\nkey = abc\nnick = Bob\n";
	const std::string enc = "v1|l01_escape|-123.456|7.500|88.125|12345|77|1|4321|3600000";

	ini_set(text, "coop_checkpoint", "cur", enc);

	std::string v;
	REQUIRE(ini_get(text, "coop", "key", v));
	CHECK_EQ(v, std::string("abc"));
	REQUIRE(ini_get(text, "coop", "nick", v));
	CHECK_EQ(v, std::string("Bob"));
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, enc);
	CHECK(!ini_get(text, "coop", "cur", v)); // not in the other section
	CHECK(!ini_get(text, "coop_checkpoint", "key", v));
	CHECK(!ini_get(text, "nope", "cur", v));

	// A second set keeps exactly one line.
	const std::string enc2 = "v1|l02_garbage|1.000|2.000|3.000|1|2|3|4|5";
	ini_set(text, "coop_checkpoint", "cur", enc2);
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, enc2);
	CHECK_EQ(count_of(text, "cur ="), size_t(1));
	CHECK_EQ(count_of(text, "[coop_checkpoint]"), size_t(1));
	REQUIRE(ini_get(text, "coop", "key", v));
	CHECK_EQ(v, std::string("abc"));

	// A second key joins the same section.
	ini_set(text, "coop_checkpoint", "prev", enc);
	REQUIRE(ini_get(text, "coop_checkpoint", "prev", v));
	CHECK_EQ(v, enc);
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, enc2);
	CHECK_EQ(count_of(text, "[coop_checkpoint]"), size_t(1));

	// Erase removes only that key.
	ini_erase(text, "coop_checkpoint", "cur");
	CHECK(!ini_get(text, "coop_checkpoint", "cur", v));
	REQUIRE(ini_get(text, "coop_checkpoint", "prev", v));
	CHECK_EQ(v, enc);
	REQUIRE(ini_get(text, "coop", "nick", v));
	CHECK_EQ(v, std::string("Bob"));
	ini_erase(text, "coop_checkpoint", "prev");
	CHECK(!ini_get(text, "coop_checkpoint", "prev", v));
	CHECK_EQ(count_of(text, "cur ="), size_t(0));

	// Erasing what is not there changes nothing.
	const std::string before = text;
	ini_erase(text, "coop_checkpoint", "cur");
	ini_erase(text, "nope", "cur");
	CHECK_EQ(text, before);
}

TEST(cp_ini_pipe_value_intact)
{
	std::string text;
	ini_set(text, "coop_checkpoint", "cur", "a|b|c|1|2");
	std::string v;
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, std::string("a|b|c|1|2"));
	// A value never carries a line break into the text.
	ini_set(text, "coop_checkpoint", "cur", "x\ny\r\nz");
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK(v.find('\n') == std::string::npos);
	CHECK(v.find('\r') == std::string::npos);
	CHECK_EQ(count_of(text, "cur ="), size_t(1));
}

TEST(cp_ini_line_endings)
{
	// CRLF text stays CRLF; no bare LF appears.
	std::string text = "[coop]\r\nkey = abc\r\n";
	ini_set(text, "coop_checkpoint", "cur", "v1");
	ini_set(text, "coop", "extra", "1");
	ini_set(text, "coop_checkpoint", "prev", "v2");
	for (size_t i = 0; i < text.size(); ++i)
		if (text[i] == '\n' && (i == 0 || text[i - 1] != '\r'))
		{
			t::report_failure(__FILE__, __LINE__, "bare LF in a CRLF text");
			break;
		}
	std::string v;
	REQUIRE(ini_get(text, "coop", "key", v));
	CHECK_EQ(v, std::string("abc"));
	REQUIRE(ini_get(text, "coop", "extra", v));
	CHECK_EQ(v, std::string("1"));
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, std::string("v1"));
	REQUIRE(ini_get(text, "coop_checkpoint", "prev", v));
	CHECK_EQ(v, std::string("v2"));

	// LF text stays LF.
	std::string lf = "[a]\nx = 1\n";
	ini_set(lf, "b", "y", "2");
	CHECK(lf.find('\r') == std::string::npos);

	// A text without a final line break still gets a clean new section.
	std::string tail = "[coop]\nkey = abc";
	ini_set(tail, "coop_checkpoint", "cur", "v1");
	REQUIRE(ini_get(tail, "coop", "key", v));
	CHECK_EQ(v, std::string("abc"));
	REQUIRE(ini_get(tail, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, std::string("v1"));
}

TEST(cp_ini_section_in_the_middle)
{
	// The key joins its own section, not the one at the end of the text; a blank line before the next section stays.
	std::string text = "[a]\nx = 1\n\n[b]\ny = 2\n";
	ini_set(text, "a", "z", "3");
	std::string v;
	REQUIRE(ini_get(text, "a", "z", v));
	CHECK_EQ(v, std::string("3"));
	CHECK(!ini_get(text, "b", "z", v));
	REQUIRE(ini_get(text, "a", "x", v));
	CHECK_EQ(v, std::string("1"));
	REQUIRE(ini_get(text, "b", "y", v));
	CHECK_EQ(v, std::string("2"));
	CHECK(text.find("z = 3\n\n[b]") != std::string::npos);

	// Replacing a value in the middle keeps the neighbours; spaces and case in the file do not matter.
	std::string loose = "[Coop_Checkpoint]\n  Cur   =   old value  \nother=1\n";
	ini_set(loose, "coop_checkpoint", "cur", "new");
	REQUIRE(ini_get(loose, "coop_checkpoint", "cur", v));
	CHECK_EQ(v, std::string("new"));
	REQUIRE(ini_get(loose, "coop_checkpoint", "other", v));
	CHECK_EQ(v, std::string("1"));
	CHECK_EQ(count_of(loose, "="), size_t(2));

	// Duplicate keys collapse to one.
	std::string dup = "[a]\nk = 1\nk = 2\nm = 3\n";
	ini_set(dup, "a", "k", "9");
	REQUIRE(ini_get(dup, "a", "k", v));
	CHECK_EQ(v, std::string("9"));
	CHECK_EQ(count_of(dup, "k ="), size_t(1));
	REQUIRE(ini_get(dup, "a", "m", v));
	CHECK_EQ(v, std::string("3"));

	// Comments and unrelated text are left alone.
	std::string c = "; header\n[a]\n; k = fake\nx = 1\n";
	CHECK(!ini_get(c, "a", "k", v));
	ini_set(c, "a", "k", "5");
	CHECK(c.find("; k = fake") != std::string::npos);
	REQUIRE(ini_get(c, "a", "k", v));
	CHECK_EQ(v, std::string("5"));
}

TEST(cp_ini_record_in_custom_data)
{
	// The way the host stores a slot: both records in one section of the character's custom data.
	std::string text = "[coop]\nnick = Bob\n";
	Slot s;
	set(s, make(Kind::Campfire, 5, "l01_escape", 1.0f));
	set(s, make(Kind::Tent, 10, "l01_escape", 2.0f));
	ini_set(text, "coop_checkpoint", "cur", encode(s.cur));
	ini_set(text, "coop_checkpoint", "prev", encode(s.prev));

	Slot back;
	std::string v;
	REQUIRE(ini_get(text, "coop_checkpoint", "cur", v));
	REQUIRE(decode(v, back.cur));
	REQUIRE(ini_get(text, "coop_checkpoint", "prev", v));
	REQUIRE(decode(v, back.prev));
	CHECK(near_pos(back.cur.pos, s.cur.pos));
	CHECK(back.cur.kind == Kind::Tent);
	CHECK(back.prev.kind == Kind::Campfire);
	CHECK_EQ(back.prev.source, uint16_t(5));
}

TEST(cp_wire_roundtrip)
{
	Record a = make(Kind::Mod, 321, "l11_pripyat", -55.25f);
	a.level_vertex = 0xfffffffe;
	a.game_vertex = 1234;
	a.game_time_ms = 123456789012ull;

	coop::Writer w;
	write(w, a);
	coop::Reader r(w.ptr(), w.size());
	Record b;
	REQUIRE(read(r, b));
	CHECK(same(a, b));
	CHECK_EQ(r.remaining(), size_t(0));

	// Several records back to back.
	coop::Writer w2;
	write(w2, a);
	write(w2, make(Kind::Arrival, kNoSource, "l01_escape", 3.0f));
	coop::Reader r2(w2.ptr(), w2.size());
	Record c, d;
	REQUIRE(read(r2, c));
	REQUIRE(read(r2, d));
	CHECK(same(a, c));
	CHECK(d.kind == Kind::Arrival);
	CHECK_EQ(d.source, kNoSource);
}

TEST(cp_wire_truncated)
{
	coop::Writer w;
	write(w, make(Kind::Campfire, 77, "l01_escape", 8.0f));
	REQUIRE(w.size() > 4);
	const Record sentinel = make(Kind::Tent, 9, "l05_bar", 5.0f);
	for (size_t n = 0; n < w.size(); ++n)
	{
		coop::Reader r(w.ptr(), n);
		Record out = sentinel;
		if (read(r, out))
			t::report_failure(__FILE__, __LINE__, "read accepted a packet cut to " + std::to_string(n) + " bytes");
		if (!same(out, sentinel))
			t::report_failure(__FILE__, __LINE__, "read touched out on a packet cut to " + std::to_string(n));
	}
}

TEST(cp_wire_rejects_bad_content)
{
	const Record sentinel = make(Kind::Tent, 9, "l05_bar", 5.0f);
	{
		// A kind past the last one.
		coop::Writer w;
		w.str("l01_escape");
		const float p[3] = {1, 2, 3};
		w.vec3(p);
		w.u32(1);
		w.u16(2);
		w.u8(7);
		w.u16(3);
		w.u64(4);
		coop::Reader r(w.ptr(), w.size());
		Record out = sentinel;
		CHECK(!read(r, out));
		CHECK(same(out, sentinel));
	}
	{
		// A level name that is not a level name.
		coop::Writer w;
		w.str("l01 escape");
		const float p[3] = {1, 2, 3};
		w.vec3(p);
		w.u32(1);
		w.u16(2);
		w.u8(1);
		w.u16(3);
		w.u64(4);
		coop::Reader r(w.ptr(), w.size());
		Record out = sentinel;
		CHECK(!read(r, out));
		CHECK(same(out, sentinel));
	}
	{
		// A position that is not finite.
		coop::Writer w;
		w.str("l01_escape");
		const float p[3] = {1, std::numeric_limits<float>::quiet_NaN(), 3};
		w.vec3(p);
		w.u32(1);
		w.u16(2);
		w.u8(1);
		w.u16(3);
		w.u64(4);
		coop::Reader r(w.ptr(), w.size());
		Record out = sentinel;
		CHECK(!read(r, out));
		CHECK(same(out, sentinel));
	}
	{
		// A 65-character level.
		coop::Writer w;
		w.str(std::string(65, 'x'));
		const float p[3] = {1, 2, 3};
		w.vec3(p);
		w.u32(1);
		w.u16(2);
		w.u8(1);
		w.u16(3);
		w.u64(4);
		coop::Reader r(w.ptr(), w.size());
		Record out = sentinel;
		CHECK(!read(r, out));
		CHECK(same(out, sentinel));
	}
}
