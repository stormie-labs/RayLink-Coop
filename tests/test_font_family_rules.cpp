// Anomaly Coop unit tests: the tiers of a font family a script registers (xrEngine/font_family_rules.h). A family is the files
// <name>_h<N>.ini (an atlas authored for a screen N px high); which file is a tier, and which tier suits a target height, the
// screen's or, when a UI is laid out on a part of the screen, the height of that part (RegisterFont target_height, may be
// fractional). ResolveFontFamily in GameFont.cpp turns the answer into files.
#include "test_util.h"

#include "../engine/src/xrEngine/font_family_rules.h"

using namespace font_family;

namespace
{
std::vector<uint32_t> tiers(std::initializer_list<uint32_t> l)
{
	return std::vector<uint32_t>(l);
}

uint32_t best(float height, std::initializer_list<uint32_t> l = {720, 1080, 1440})
{
	const std::vector<uint32_t> v = by_preference(tiers(l), height);
	return v.empty() ? 0 : v[0];
}
} // namespace

TEST(font_family_parse_tier)
{
	CHECK_EQ(parse_tier_file("ui_font_x_h1080.ini", "ui_font_x", ""), uint32_t(1080));
	CHECK_EQ(parse_tier_file("ui_font_x_h720.ini", "ui_font_x", ""), uint32_t(720));
	CHECK_EQ(parse_tier_file("ui_font_x_h1.ini", "ui_font_x", ""), uint32_t(1));
	CHECK_EQ(parse_tier_file("ui_font_x_h99999.ini", "ui_font_x", ""), uint32_t(99999));

	// not a tier of this family
	const char* bad[] = {"ui_font_x_h100000.ini", "ui_font_x_h0.ini", "ui_font_x_h01080.ini", "ui_font_x_h.ini",
	                     "ui_font_x_h10a.ini", "ui_font_x_h1080.dds", "ui_font_x_h1080.ini.bak", "ui_font_x.ini",
	                     "ui_font_xy_h1080.ini", "ui_font_x_hh1080.ini", "ui_font_x_1080.ini", "ui_font_x_h1080_2.ini",
	                     ".ini", "", "ui_font_x_h", "ui_font_x_h-5.ini", "ui_font_x_h+5.ini", "ui_font_x_h 5.ini",
	                     "UI_FONT_X_H1080.INI"};
	for (const char* f : bad)
		if (parse_tier_file(f, "ui_font_x", "") != 0)
			t::report_failure(__FILE__, __LINE__, std::string("parse_tier_file accepted \"") + f + "\"");
}

TEST(font_family_parse_tier_language_suffix)
{
	// the string table's font_prefix is part of the file name: <name>_h<N><lang>.ini
	CHECK_EQ(parse_tier_file("ui_font_x_h1080_cn.ini", "ui_font_x", "_cn"), uint32_t(1080));
	CHECK_EQ(parse_tier_file("ui_font_x_h1080.ini", "ui_font_x", "_cn"), uint32_t(0));
	CHECK_EQ(parse_tier_file("ui_font_x_h1080_cn.ini", "ui_font_x", ""), uint32_t(0));
	CHECK_EQ(parse_tier_file("ui_font_x_h_cn.ini", "ui_font_x", "_cn"), uint32_t(0));
	CHECK_EQ(parse_tier_file("ui_font_x_h.ini", "ui_font_x", ""), uint32_t(0));
	// a suffix that starts with a digit does not blur the number: "_h10" + "80" is not "_h1080"
	CHECK_EQ(parse_tier_file("ui_font_x_h1080.ini", "ui_font_x", "80"), uint32_t(10));
}

TEST(font_family_nearest_tier_for_the_screen)
{
	CHECK_EQ(best(720), uint32_t(720));
	CHECK_EQ(best(1080), uint32_t(1080));
	CHECK_EQ(best(1440), uint32_t(1440));
	CHECK_EQ(best(768), uint32_t(720)); // 4:3 at 1024x768
	CHECK_EQ(best(900), uint32_t(1080)); // 900/720 = 1.25, 1080/900 = 1.2
	CHECK_EQ(best(864), uint32_t(720)); // 864/720 = 1.2, 1080/864 = 1.25
	CHECK_EQ(best(1200), uint32_t(1080));
	CHECK_EQ(best(1296), uint32_t(1440));
	CHECK_EQ(best(540), uint32_t(720));
	CHECK_EQ(best(2160), uint32_t(1440));
	CHECK_EQ(best(10000), uint32_t(1440));
	CHECK_EQ(best(1), uint32_t(720));
}

TEST(font_family_target_height_may_be_fractional)
{
	// A UI laid out for 1440x1080 on a 4:3 screen scales by 0.75: text is wanted for 1080 * 0.75 = 810 px, not for the 1080 of the
	// screen. 810 is nearer to 720 (ln 1.125) than to 1080 (ln 1.333).
	CHECK_EQ(best(1080.f * 0.75f), uint32_t(720));
	CHECK_EQ(best(810.f), uint32_t(720));
	CHECK_EQ(best(1080.f * 1.0f), uint32_t(1080));
	// the switch point between 720 and 1080 is their geometric mean, 881.8: just under it 720, just over it 1080
	CHECK_EQ(best(881.0f), uint32_t(720));
	CHECK_EQ(best(882.6f), uint32_t(1080));
	// and between 1080 and 1440 it is 1247.1 (closer than 1e-4 on the log scale counts as a tie, and a tie goes up)
	CHECK_EQ(best(1246.0f), uint32_t(1080));
	CHECK_EQ(best(1248.5f), uint32_t(1440));
	// fractions below one pixel change nothing the caller could see, but must not break the order
	CHECK_EQ(best(1079.5f), uint32_t(1080));
	CHECK_EQ(best(1080.4f), uint32_t(1080));
}

TEST(font_family_ties_and_edges)
{
	// an exact tie on the log scale (720 and 1620 around 1080) goes to the larger tier
	CHECK_EQ(best(1080.f, {720, 1620}), uint32_t(1620));
	// the same tier listed twice counts once
	CHECK_EQ(by_preference(tiers({1080, 1080, 720}), 1080.f).size(), size_t(2));
	// no tiers, no answer
	CHECK(by_preference({}, 1080.f).empty());
	// a target that is not a height (0, negative, NaN): every tier is equally far, the larger comes first and nothing is lost
	for (const float h : {0.f, -5.f, std::nanf("")})
	{
		const std::vector<uint32_t> v = by_preference(tiers({720, 1080, 1440}), h);
		CHECK_EQ(v.size(), size_t(3));
	}
	// one tier is every answer
	CHECK_EQ(best(300.f, {1080}), uint32_t(1080));
	CHECK_EQ(best(5000.f, {1080}), uint32_t(1080));
}

TEST(font_family_order_is_by_distance)
{
	// the whole list, not only the first: nearest to farthest, the fallbacks if a tier turns out to have no usable atlas
	const std::vector<uint32_t> v = by_preference(tiers({1440, 720, 1080}), 810.f);
	REQUIRE(v.size() == size_t(3));
	CHECK_EQ(v[0], uint32_t(720));
	CHECK_EQ(v[1], uint32_t(1080));
	CHECK_EQ(v[2], uint32_t(1440));

	const std::vector<uint32_t> w = by_preference(tiers({720, 1080, 1440}), 1300.f);
	REQUIRE(w.size() == size_t(3));
	CHECK_EQ(w[0], uint32_t(1440));
	CHECK_EQ(w[1], uint32_t(1080));
	CHECK_EQ(w[2], uint32_t(720));
}
