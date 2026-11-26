// Anomaly Coop unit tests: the text rules every place had before it moved onto xrCoop/coop_text.h and srv/coop_token.h.
// Each table row is what the old per-file helper answered for that input (run of the old code); the shared helper, with
// the variant that place chose, must answer the same. Two places that read alike but answered differently (a blank set,
// a word alphabet, a digit cap, a token spelling) keep two rows here, so merging them under one rule fails a test.
#include "test_util.h"

#include "coop_checkpoint_rules.h"
#include "coop_debug_rules.h"
#include "coop_mirror_pose_rules.h"
#include "coop_syncnet.h"
#include "coop_text.h"
#include "coop_validate.h"
#include "srv/coop_mapserver_rules.h"
#include "srv/coop_token.h"
#include "srv/coop_world_stage.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>

using namespace coop;

namespace
{
struct NumberRow
{
	const char* text;
	bool record_ok; // checkpoint::detail::parse_uint: <= 20 digits, leading zeros, no overflow
	uint64_t record;
	bool scope_ok; // syncnet::detail::parse_uint: <= 19 digits, no leading zero
	uint64_t scope;
	bool field_ok; // world_server parse_uint = xfer parse_u32: <= 10 digits, leading zeros
	uint32_t field;
	bool arg_ok; // mapserver::detail::read_number(max 0xffff): any digits, ends at a space
	uint32_t arg;
	int arg_end;
};

// The old code's answers, max = u64 max / u32 max / 0xffff.
const NumberRow kNumbers[] = {
	{"", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{"0", 1, 0ull, 1, 0ull, 1, 0u, 1, 0u, 1},
	{"00", 1, 0ull, 0, 0ull, 1, 0u, 1, 0u, 2},
	{"007", 1, 7ull, 0, 0ull, 1, 7u, 1, 7u, 3},
	{"42", 1, 42ull, 1, 42ull, 1, 42u, 1, 42u, 2},
	{"65535", 1, 65535ull, 1, 65535ull, 1, 65535u, 1, 65535u, 5},
	{"65536", 1, 65536ull, 1, 65536ull, 1, 65536u, 0, 0u, 0},
	{"4294967295", 1, 4294967295ull, 1, 4294967295ull, 1, 4294967295u, 0, 0u, 0},
	{"4294967296", 1, 4294967296ull, 1, 4294967296ull, 0, 0u, 0, 0u, 0},
	{"00000000001", 1, 1ull, 0, 0ull, 0, 0u, 1, 1u, 11},
	{"1234567890123456789", 1, 1234567890123456789ull, 1, 1234567890123456789ull, 0, 0u, 0, 0u, 0},
	{"9999999999999999999", 1, 9999999999999999999ull, 1, 9999999999999999999ull, 0, 0u, 0, 0u, 0},
	{"18446744073709551615", 1, 18446744073709551615ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{"18446744073709551616", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{"99999999999999999999", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{"000000000000000000001", 0, 0ull, 0, 0ull, 0, 0u, 1, 1u, 21},
	{"+1", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{"1 ", 0, 0ull, 0, 0ull, 0, 0u, 1, 1u, 2},
	{"1a", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
	{" 1", 0, 0ull, 0, 0ull, 0, 0u, 0, 0u, 0},
};

struct TrimRow
{
	const char* text;
	const char* space_tab; // checkpoint ini, staging file, base fields
	const char* space_tab_cr; // xfer journal
	const char* space_eol; // console line, vehicle seats, source lists
};

const TrimRow kTrims[] = {
	{"", "", "", ""},
	{" ", "", "", ""},
	{"\t\r\n ", "\r\n", "\n", ""},
	{" \t\r\n x y \n\r\t ", "\r\n x y \n\r", "\n x y \n", "x y"},
	{"\r a\r", "\r a\r", "a", "a"},
	{"\na\n", "\na\n", "\na\n", "a"},
	{"\ta\t", "a", "a", "a"},
	{"a", "a", "a", "a"},
	{" a b ", "a b", "a b", "a b"},
};

// Bit c of word c / 32: the character is in the set (the old helpers over 0..255).
const uint32_t kLowerIdent[8] = {0x00000000u, 0x03ff0000u, 0x80000000u, 0x07fffffeu, 0, 0, 0, 0}; // world_server word_char
const uint32_t kName[8] = {0x00000000u, 0x03ff6000u, 0x87fffffeu, 0x07fffffeu, 0, 0, 0, 0}; // world_stage word_char
const uint32_t kIdent[8] = {0x00000000u, 0x03ff0000u, 0x87fffffeu, 0x07fffffeu, 0, 0, 0, 0}; // debug ident_char
const uint32_t kSpaceEol[8] = {0x00002600u, 0x00000001u, 0, 0, 0, 0, 0, 0}; // debug / checkpoint source blank
const uint32_t kSpaceTab[8] = {0x00000200u, 0x00000001u, 0, 0, 0, 0, 0, 0}; // dedicated / world_stage blank

template <class F> bool same_set(F in_set, const uint32_t (&bits)[8])
{
	for (int c = 0; c < 256; ++c)
		if (in_set(char(c)) != (((bits[c / 32] >> (c % 32)) & 1u) != 0))
			return false;
	return true;
}
} // namespace

TEST(text_golden_decimal_parsers_keep_each_place_rules)
{
	for (const NumberRow& row : kNumbers)
	{
		const std::string s = row.text;
		uint64_t a = 0, b = 0;
		uint32_t c = 0, e = 0;
		const bool ra = checkpoint::detail::parse_uint(s, ~uint64_t(0), a);
		const bool rb = syncnet::detail::parse_uint(s, ~uint64_t(0), b);
		const bool rc = ascii::parse_u32(s, 0xffffffffu, c);
		const char* p = row.text;
		const bool re = mapserver::detail::read_number(p, 0xffffu, e);
		CHECK_EQ(ra, row.record_ok);
		CHECK_EQ(rb, row.scope_ok);
		CHECK_EQ(rc, row.field_ok);
		CHECK_EQ(re, row.arg_ok);
		if (ra)
			CHECK_EQ(a, row.record);
		if (rb)
			CHECK_EQ(b, row.scope);
		if (rc)
			CHECK_EQ(c, row.field);
		if (re)
			CHECK_EQ(e, row.arg);
		CHECK_EQ(int(p - row.text), row.arg_end);
	}
}

TEST(text_golden_three_blank_sets_trim_differently)
{
	for (const TrimRow& row : kTrims)
	{
		const std::string t = row.text;
		CHECK_EQ(std::string(ascii::trim(t, ascii::space_or_tab)), std::string(row.space_tab));
		CHECK_EQ(std::string(ascii::trim(t, ascii::space_tab_cr)), std::string(row.space_tab_cr));
		CHECK_EQ(std::string(ascii::trim(t, ascii::space_or_eol)), std::string(row.space_eol));
		size_t b = 0, e = t.size();
		checkpoint::detail::trim(t, b, e);
		CHECK_EQ(t.substr(b, e - b), std::string(row.space_tab));
		CHECK_EQ(world_stage::detail::trim(t), std::string(row.space_tab));
		CHECK_EQ(std::string(debug::detail::trim(t)), std::string(row.space_eol));
	}
}

TEST(text_golden_character_sets)
{
	CHECK(same_set(ascii::lower_ident_char, kLowerIdent));
	CHECK(same_set(ascii::name_char, kName));
	CHECK(same_set(ascii::ident_char, kIdent));
	CHECK(same_set(ascii::space_or_eol, kSpaceEol));
	CHECK(same_set(ascii::space_or_tab, kSpaceTab));
	CHECK_EQ(ascii::lowered("AbZ_1@[`{\xC0z"), std::string("abz_1@[`{\xC0z"));
}

TEST(text_golden_compares)
{
	// log_keep same_text(a, at, b): a[at..] starts with b, any letter case
	CHECK(ascii::istarts_with(std::string_view("xray_bob.LOG").substr(8), ".log"));
	CHECK(!ascii::istarts_with(std::string_view("ab").substr(1), "bc"));
	CHECK(ascii::istarts_with("Ab", "aB"));
	CHECK(ascii::istarts_with("", ""));
	CHECK(ascii::istarts_with(std::string_view("abc").substr(3), ""));
	// progress / vehicle_drive same_text: exact
	CHECK(ascii::equal("log", "log"));
	CHECK(!ascii::equal("Log", "log"));
	CHECK(!ascii::equal("lo", "log"));
	CHECK(ascii::equal("", ""));
	// mirror_pose same_name: stricmp, nullptr is no name
	CHECK(mirror_pose::fallback_motion("tORSO") != nullptr);
	CHECK(mirror_pose::fallback_motion(nullptr) == nullptr);
	CHECK(mirror_pose::fallback_motion("leg") == nullptr);
	// checkpoint ini ieq: a span equals a name, any letter case
	const std::string t = "[Coop_Base]";
	CHECK(checkpoint::detail::ieq(t, 1, 10, "coop_base"));
	CHECK(!checkpoint::detail::ieq(t, 1, 10, "coop_bas"));
	CHECK(!checkpoint::detail::ieq(t, 1, 9, "coop_base"));
}

TEST(text_golden_command_line_key_is_a_whole_word)
{
	const char* const key = "-coop_dedicated";
	const struct
	{
		const char* line;
		int after; // -1: not found
	} rows[] = {{"-coop_dedicated", 15}, {"x -coop_dedicated", 17}, {"x -coop_dedicatedX -coop_dedicated\t1", 34},
		{"x-coop_dedicated", -1}, {"-coop_dedicated_x", -1}, {"\t-coop_dedicated\t", 16}};
	for (const auto& row : rows)
	{
		const char* r = ascii::find_key(row.line, key);
		CHECK_EQ(r ? int(r - row.line) : -1, row.after);
	}
}

TEST(text_golden_two_token_spellings)
{
	const struct
	{
		const char* text;
		bool bridge; // the old mapserver::parse_token
		bool op; // the old op::parse_token
	} rows[] = {
		{"00112233445566778899aabbccddeeff", true, true},
		{"00112233445566778899AABBCCDDEEFF", false, true},
		{"00112233445566778899aabbccddeeff x", true, true},
		{"00112233445566778899aabbccddeeff\tx", false, true},
		{"00000000000000000000000000000000", true, false},
		{"00112233445566778899aabbccddeef", false, false},
		{"00112233445566778899aabbccddeeffa", false, false},
		{"0g112233445566778899aabbccddeeff", false, false},
	};
	for (const auto& row : rows)
	{
		srv::Token a{}, b{};
		CHECK_EQ(srv::parse_bridge_token(row.text, a), row.bridge);
		CHECK_EQ(srv::parse_operator_token(row.text, b), row.op);
		if (row.bridge && !srv::token_none(a))
			CHECK_EQ(srv::token_hex(a), std::string("00112233445566778899aabbccddeeff"));
	}
	uint8_t t[16];
	for (int i = 0; i < 16; ++i)
		t[i] = uint8_t(i * 17);
	CHECK_EQ(srv::token_hex(t, 16), std::string("00112233445566778899aabbccddeeff"));
}

TEST(text_golden_clamp01_and_finite3)
{
	CHECK_EQ(validate::clamp01(-1.f), 0.f);
	CHECK_EQ(validate::clamp01(0.25f), 0.25f);
	CHECK_EQ(validate::clamp01(2.f), 1.f);
	CHECK(std::isnan(validate::clamp01(std::numeric_limits<float>::quiet_NaN())));
	const float ok[3] = {0.f, 1.f, -2.f};
	const float bad[3] = {0.f, std::numeric_limits<float>::infinity(), 0.f};
	CHECK(validate::finite3(ok));
	CHECK(!validate::finite3(bad));
	CHECK(validate::finite3(0.f, 1.f, -2.f));
	CHECK(!validate::finite3(0.f, std::numeric_limits<float>::quiet_NaN(), 0.f));
}
