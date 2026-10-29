// Anomaly Coop unit tests: HUD v2.1 name tag over another player (coop_nametag.h, drawn by coop_presence.cpp).
// Owner 2026-10-23 19:40 on build 9: "make the tag presentable; the distance under the name; prettier; and let the
// transparency play" - the old tag was one line "player_b  2 m" in small Arial, its own colour, lost on a light sky.
#include "test_util.h"

#include "coop_nametag.h"

#include <cmath>
#include <cstring>
#include <string>

using namespace coop;
using nametag::Icon;
using nametag::Params;
using nametag::State;

namespace
{
bool near_f(float a, float b, float eps = 1e-4f) { return a - b <= eps && b - a <= eps; }

std::string line_of(State s, bool with_dist, float dist, uint32_t bleed_ms)
{
	char buf[64];
	nametag::format_line(buf, sizeof(buf), s, with_dist, dist, bleed_ms, "m", "km");
	return buf;
}
} // namespace

TEST(nametag_alpha_follows_the_distance_smoothly)
{
	const Params p;
	CHECK(near_f(nametag::distance_alpha(0.f, p), 1.f));
	CHECK(near_f(nametag::distance_alpha(p.near_m, p), 1.f)); // full up to near_m (20 m)
	CHECK(nametag::distance_alpha(p.near_m + 1.f, p) > 0.995f); // smooth start: no step at near_m
	CHECK(near_f(nametag::distance_alpha(p.far_m, p), p.far_alpha)); // 0.4 at 250 m
	CHECK(near_f(nametag::distance_alpha(399.f, p), p.far_alpha)); // and beyond (tags end at 400 m)
	float prev = 2.f;
	for (float d = 0.f; d <= 300.f; d += 5.f)
	{
		const float a = nametag::distance_alpha(d, p);
		CHECK(a <= prev + 1e-6f);
		prev = a;
	}
	const float mid = nametag::distance_alpha((p.near_m + p.far_m) / 2.f, p);
	CHECK(near_f(mid, (1.f + p.far_alpha) / 2.f, 1e-3f)); // smoothstep: halfway at the middle
}

TEST(nametag_steps_aside_at_the_crosshair)
{
	const Params p;
	const float h = 1080.f;
	// at the centre of the screen the tag must not hide the target: aim_alpha; a wounded one stays easy to find
	CHECK(near_f(nametag::aim_factor(0.f, 0.f, h, State::Alive, p), p.aim_alpha));
	CHECK(near_f(nametag::aim_factor(0.f, 0.f, h, State::Wounded, p), p.aim_alpha_down));
	CHECK(near_f(nametag::aim_factor(0.f, p.aim_inner * h * 0.9f, h, State::Alive, p), p.aim_alpha));
	CHECK(near_f(nametag::aim_factor(p.aim_outer * h, 0.f, h, State::Alive, p), 1.f));
	CHECK(near_f(nametag::aim_factor(400.f, 300.f, h, State::Dead, p), 1.f));
	const float mid = nametag::aim_factor(0.f, (p.aim_inner + p.aim_outer) / 2.f * h, h, State::Alive, p);
	CHECK(mid > p.aim_alpha && mid < 1.f);
	CHECK(near_f(nametag::aim_factor(0.f, 0.f, 0.f, State::Alive, p), 1.f)); // no screen: untouched
}

TEST(nametag_wounded_pulses_at_one_hertz)
{
	const Params p;
	CHECK(near_f(nametag::pulse(0, p), 1.f));
	CHECK(near_f(nametag::pulse(500, p), p.pulse_low));
	CHECK(near_f(nametag::pulse(1000, p), 1.f));
	for (uint64_t t = 0; t < 2000; t += 37)
	{
		const float v = nametag::pulse(t, p);
		CHECK(v >= p.pulse_low - 1e-5f && v <= 1.f + 1e-5f);
	}
}

TEST(nametag_look_by_state)
{
	const Params p;
	const uint32_t blue = 0x538CE0, down = 0xE23A30, dead = 0x969696;
	// alive: white nick, the player's colour on the chevron, the distance line dimmer
	nametag::Look a = nametag::look(State::Alive, 12.f, false, 0, blue, down, dead, p);
	CHECK(a.icon == Icon::Chevron);
	CHECK_EQ(a.icon_rgb, blue);
	CHECK_EQ(a.nick_rgb, nametag::kWhite);
	CHECK_EQ(a.line_rgb, nametag::kWhite);
	CHECK(near_f(a.alpha, 1.f));
	CHECK(near_f(a.line_alpha, p.line_alpha));
	CHECK(near_f(a.icon_px, p.icon_px));
	CHECK(near_f(a.icon_scale, 1.f));
	// far: everything dimmer by the distance curve
	nametag::Look af = nametag::look(State::Alive, 160.f, false, 0, blue, down, dead, p);
	CHECK(near_f(af.alpha, nametag::distance_alpha(160.f, p)));
	CHECK(af.alpha < 0.7f);
	// wounded: the down ring instead of the chevron, a red line (timer), the icon and the line pulse, bigger icon
	nametag::Look w0 = nametag::look(State::Wounded, 30.f, false, 0, blue, down, dead, p);
	nametag::Look w5 = nametag::look(State::Wounded, 30.f, false, 500, blue, down, dead, p);
	CHECK(w0.icon == Icon::Down);
	CHECK_EQ(w0.icon_rgb, down);
	CHECK_EQ(w0.line_rgb, down);
	CHECK_EQ(w0.nick_rgb, nametag::kWhite);
	CHECK(near_f(w0.icon_px, p.icon_state_px));
	CHECK(w0.icon_alpha > w5.icon_alpha && w0.icon_scale > w5.icon_scale);
	CHECK(near_f(w5.icon_alpha, w5.alpha * p.pulse_low));
	CHECK(w0.line_alpha > w0.alpha * p.line_alpha); // the timer line is brighter than a distance line
	// wounded behind a wall: still shown (to be found and raised), dimmer
	nametag::Look ww = nametag::look(State::Wounded, 30.f, true, 0, blue, down, dead, p);
	CHECK(near_f(ww.alpha, w0.alpha * p.wall_alpha));
	// dead (spectating, returning): skull, grey nick and line
	nametag::Look d = nametag::look(State::Dead, 30.f, false, 0, blue, down, dead, p);
	CHECK(d.icon == Icon::Skull);
	CHECK_EQ(d.icon_rgb, dead);
	CHECK_EQ(d.nick_rgb, dead);
	CHECK_EQ(d.line_rgb, dead);
}

TEST(nametag_argb_packs_alpha_and_colour)
{
	CHECK_EQ(nametag::argb(1.f, 0x538CE0), 0xFF538CE0u);
	CHECK_EQ(nametag::argb(0.f, 0x538CE0), 0x00538CE0u);
	CHECK_EQ(nametag::argb(0.5f, 0xFFFFFF), 0x80FFFFFFu);
	CHECK_EQ(nametag::argb(2.f, 0x000000), 0xFF000000u); // clamped
	CHECK_EQ(nametag::argb(-1.f, 0x123456), 0x00123456u);
}

TEST(nametag_line_under_the_nick)
{
	CHECK_EQ(line_of(State::Alive, true, 25.6f, 0), std::string("26 m"));
	CHECK_EQ(line_of(State::Alive, true, 123.f, 0), std::string("120 m")); // 10 m steps from 100 m (like the compass)
	CHECK_EQ(line_of(State::Alive, true, 1234.f, 0), std::string("1.2 km"));
	CHECK_EQ(line_of(State::Alive, false, 25.f, 0), std::string("")); // coop_nametags_dist 0: no line
	CHECK_EQ(line_of(State::Dead, true, 41.f, 0), std::string("41 m"));
	// wounded: the bleed-out timer first, then the distance (two spaces: safe in every font)
	CHECK_EQ(line_of(State::Wounded, true, 34.f, 42000), std::string("0:42  34 m"));
	CHECK_EQ(line_of(State::Wounded, true, 34.f, 41001), std::string("0:42  34 m")); // seconds rounded up
	CHECK_EQ(line_of(State::Wounded, false, 34.f, 61000), std::string("1:01"));
	CHECK_EQ(line_of(State::Wounded, true, 34.f, 0), std::string("34 m")); // no timer known: the distance
	char tiny[4];
	nametag::format_line(tiny, sizeof(tiny), State::Wounded, true, 34.f, 42000, "m", "km");
	CHECK_EQ(std::strlen(tiny), size_t(3)); // never past the buffer
}

TEST(nametag_stack_goes_up_from_the_head)
{
	// screen px, y down; the anchor is the point over the head: icon, line, nick upwards
	const nametag::Stack s = nametag::stack(500.f, 18.f, 14.f, 10.f, 2.f, true);
	CHECK(near_f(s.icon_cy, 495.f)); // the icon's bottom on the anchor
	CHECK(near_f(s.line_y, 500.f - 10.f - 2.f - 14.f)); // the line's top: over the icon and the gap
	CHECK(near_f(s.nick_y, s.line_y - 1.f - 18.f)); // the nick right over the line
	const nametag::Stack n = nametag::stack(500.f, 18.f, 14.f, 10.f, 2.f, false);
	CHECK(near_f(n.nick_y, 500.f - 10.f - 2.f - 18.f)); // no line: the nick over the icon
}

TEST(nametag_params_from_the_layout_lines)
{
	Params p;
	CHECK(nametag::set_param(p, "tag_near", 30.f));
	CHECK(near_f(p.near_m, 30.f));
	CHECK(nametag::set_param(p, "tag_far_alpha", 0.25f));
	CHECK(near_f(p.far_alpha, 0.25f));
	CHECK(!nametag::set_param(p, "tag_far_alpha", 1.5f)); // out of its range: kept
	CHECK(near_f(p.far_alpha, 0.25f));
	CHECK(!nametag::set_param(p, "tag_no_such_key", 1.f));
	CHECK(!nametag::set_param(p, "tag_near", std::nanf(""))); // NaN refused
	size_t n = 0;
	const nametag::ParamKey* keys = nametag::param_keys(n);
	CHECK(n >= 10);
	for (size_t i = 0; i < n; ++i)
	{
		CHECK(std::strncmp(keys[i].key, "tag_", 4) == 0);
		Params d;
		CHECK(d.*(keys[i].field) >= keys[i].lo && d.*(keys[i].field) <= keys[i].hi); // the defaults are valid
	}
	// a far edge closer than the near one would divide by zero: refused
	Params q;
	CHECK(!nametag::set_param(q, "tag_far", 10.f));
	CHECK(near_f(q.far_m, Params().far_m));
}

// Owner 2026-10-29 (build 29): "remove the random names on each other" - a player's character is called by his nick.
// ChangeName -> TranslateName splits "x:lname_y" at ':' (and asserts on 3+ parts); '%' opens a UI colour code.
TEST(nametag_character_name_is_the_nick_the_engine_can_take)
{
	char buf[nametag::kMaxCharacterName];
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), "C3N50R3D"), size_t(8));
	CHECK(std::string(buf) == "C3N50R3D");
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), "a:lname_b:c"), size_t(9));
	CHECK(std::string(buf) == "alname_bc");
	nametag::character_name(buf, sizeof(buf), "%c[255,255,0,0]Red");
	CHECK(std::string(buf) == "c[255,255,0,0]Red");
	const char* cyr = "\xD0\xA1\xD0\xB5\xD1\x80\xD0\xB3\xD0\xB5\xD0\xB9"; // a Cyrillic nick (UTF-8) stays whole
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), cyr), std::strlen(cyr));
	CHECK(std::string(buf) == cyr);
	// nothing left, nothing given, no room: 0 (the caller keeps the name the character has)
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), ":%:"), size_t(0));
	CHECK(buf[0] == 0);
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), nullptr), size_t(0));
	CHECK_EQ(nametag::character_name(buf, 0, "abc"), size_t(0));
	// a short buffer never ends inside a UTF-8 sequence: "ab" + one 2-byte letter, the second does not fit
	char small[6];
	CHECK_EQ(nametag::character_name(small, sizeof(small), "ab\xD0\x96\xD0\x96"), size_t(4));
	CHECK(std::string(small) == "ab\xD0\x96");
	// the longest nick fits (sanitize_nick: 48 bytes)
	const std::string longest(48, 'x');
	CHECK_EQ(nametag::character_name(buf, sizeof(buf), longest.c_str()), size_t(48));
}
