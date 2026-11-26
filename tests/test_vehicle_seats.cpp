// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: passengers (F5-VEH-5, docs/VEHICLES.md sections 4, 5 and 12) - xrCoop/coop_vehicle_seats.h, the places of
// configs/coop_vehicles.ltx and the ride of a player's machine. The parser of a car's section (good, missing and malformed lines, the
// seat count, the exit side), the transforms (bone or point, offset, yaw, the car's XFORM), the door point, the passenger's eye and
// free look; then the real ltx, and the engine wiring read from the source: the decider's seat_transform / seat counts / exit point,
// the Ride step of a player's machine, the hooks in Actor.cpp / ActorInput.cpp and the port of the stock attach / detach. One set of
// rules for both modes: the decider is whoever leads the player's level, the rules do not know which.
#include "test_util.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <vector>

#include "coop_text.h"
#include "coop_vehicle_seats.h"

namespace v = coop::vehicles;

namespace
{
using Lines = std::map<std::string, std::string>;

v::SeatLine lines_of(const Lines& m)
{
	return [&m](const char* key, std::string& value)
	{
		auto it = m.find(key);
		if (it == m.end())
			return false;
		value = it->second;
		return true;
	};
}

v::CarSeats parse(const Lines& m) { return v::parse_car_seats(lines_of(m)); }

bool near(float a, float b, float eps = 1e-4f) { return std::fabs(a - b) <= eps; }

bool near_vec(const v::SeatVec& a, float x, float y, float z, float eps = 1e-4f)
{
	return near(a.x, x, eps) && near(a.y, y, eps) && near(a.z, z, eps);
}

bool has_error(const v::CarSeats& s, const std::string& start)
{
	for (const std::string& e : s.errors)
		if (e.compare(0, start.size(), start) == 0)
			return true;
	return false;
}

// anomaly-coop/<rel> (tests\ -> ..), without '\r'
std::string seats_project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// From `head` to the first "\n}" at column 0 after it ("" when `head` is not there).
std::string seats_body(const std::string& src, const std::string& head)
{
	const size_t at = src.find(head);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\n}", at);
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

// Each token found after the previous one: the order of the stock lines kept.
bool in_order(const std::string& text, const std::vector<std::string>& tokens, std::string& missing)
{
	size_t at = 0;
	for (const std::string& t : tokens)
	{
		const size_t found = text.find(t, at);
		if (found == std::string::npos)
		{
			missing = t;
			return false;
		}
		at = found + t.size();
	}
	return true;
}

// A minimal ltx reader for the data test: [section] (a ":parent" is cut), key = value, ';' starts a comment.
std::map<std::string, Lines> read_ltx(const std::string& text)
{
	const auto trim = [](std::string_view s) { return std::string(coop::ascii::trim(s, coop::ascii::space_or_eol)); };
	std::map<std::string, Lines> out;
	std::string section;
	size_t at = 0;
	while (at < text.size())
	{
		size_t end = text.find('\n', at);
		if (end == std::string::npos)
			end = text.size();
		std::string line = text.substr(at, end - at);
		at = end + 1;
		const size_t semi = line.find(';');
		if (semi != std::string::npos)
			line.resize(semi);
		line = trim(line);
		if (line.empty())
			continue;
		if (line[0] == '[')
		{
			const size_t close = line.find(']');
			section = line.substr(1, close == std::string::npos ? std::string::npos : close - 1);
			out[section];
			continue;
		}
		const size_t eq = line.find('=');
		if (eq == std::string::npos || section.empty())
			continue;
		out[section][trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
	}
	return out;
}
} // namespace

// ---------------------------------------------------------------------------------------------- the parser

TEST(vehicle_seats_parse_every_form)
{
	const v::CarSeats s = parse({{"seats", "6"},
	    {"seat_1", "driver, 0.8, 0, 0"},
	    {"seat_2", "seat_right"},
	    {"seat_3", "seat_back_left, 180"},
	    {"seat_4", "driver, 0.05, 0.1, -0.85, -15"},
	    {"seat_5", "-0.6, 2.0, -1.5, 90"},
	    {"exit_1", "right"},
	    {"exit_3", "back"},
	    {"exit_5", "left"}});
	CHECK(s.errors.empty());
	CHECK_EQ(int(s.count), 6);
	CHECK(s.seat[1].bone == "driver" && near_vec(s.seat[1].offset, 0.8f, 0.f, 0.f) && near(s.seat[1].yaw_deg, 0.f));
	CHECK(s.seat[1].exit_given && s.seat[1].exit == v::ExitSide::Right);
	CHECK(s.seat[2].bone == "seat_right" && near_vec(s.seat[2].offset, 0.f, 0.f, 0.f) && near(s.seat[2].yaw_deg, 0.f));
	CHECK(!s.seat[2].exit_given);
	CHECK(s.seat[3].bone == "seat_back_left" && near(s.seat[3].yaw_deg, 180.f) && s.seat[3].exit == v::ExitSide::Back);
	CHECK(s.seat[4].bone == "driver" && near_vec(s.seat[4].offset, 0.05f, 0.1f, -0.85f) && near(s.seat[4].yaw_deg, -15.f));
	CHECK(s.seat[5].bone.empty() && near_vec(s.seat[5].offset, -0.6f, 2.f, -1.5f) && near(s.seat[5].yaw_deg, 90.f));
	CHECK(s.seat[5].exit_given && s.seat[5].exit == v::ExitSide::Left);
	CHECK(!s.eye_given);
}

TEST(vehicle_seats_missing_lines)
{
	// no section line at all: the driver alone, nothing to say
	const v::CarSeats none = parse({});
	CHECK_EQ(int(none.count), 1);
	CHECK(none.errors.empty());
	// seats = 1: the driver alone, said
	const v::CarSeats one = parse({{"seats", "1"}, {"seat_1", "driver, 0.8, 0, 0"}});
	CHECK_EQ(int(one.count), 1);
	CHECK(one.errors.empty());
	// seat_2 missing: the places end before it, seat_3 is never read
	const v::CarSeats gap = parse({{"seats", "4"}, {"seat_1", "driver, 0.8, 0, 0"}, {"seat_3", "driver, 0.8, 0, -0.9"}});
	CHECK_EQ(int(gap.count), 2);
	CHECK(has_error(gap, "seat_2: missing"));
	// no exit line: the side of the seat (decided with its position, exit_side_of)
	CHECK(!gap.seat[1].exit_given);
	// no eye line: the driver's
	CHECK(!gap.eye_given);
}

TEST(vehicle_seats_malformed_lines)
{
	for (const char* bad : {"abc", "0", "9", "2.5", "", "-1", "3 4"})
	{
		const v::CarSeats s = parse({{"seats", bad}, {"seat_1", "driver"}});
		CHECK_EQ(int(s.count), 1);
		CHECK(has_error(s, "seats:"));
	}
	v::SeatPlace p;
	// the bone form takes 0, 1, 3 or 4 numbers; the point form exactly 4
	CHECK(!v::parse_seat_line("driver, 1, 2", p));
	CHECK(!v::parse_seat_line("driver, 1, 2, 3, 4, 5", p));
	CHECK(!v::parse_seat_line("1, 2", p));
	CHECK(!v::parse_seat_line("1, 2, 3", p));
	CHECK(!v::parse_seat_line("1, 2, 3, 4, 5", p));
	// numbers are whole tokens and finite
	CHECK(!v::parse_seat_line("driver, 1x, 0, 0", p));
	CHECK(!v::parse_seat_line("driver, nan, 0, 0", p));
	CHECK(!v::parse_seat_line("0, inf, 0, 0", p));
	CHECK(!v::parse_seat_line("1e40, 0, 0, 0", p));
	CHECK(!v::parse_seat_line("driver, 0, , 0", p));
	// a bone is a name: letters, digits, '_', not starting with a digit
	CHECK(!v::parse_seat_line("seat left", p));
	CHECK(!v::parse_seat_line("seat-left", p));
	CHECK(!v::parse_seat_line("", p));
	CHECK(!v::parse_seat_line(",", p));
	// bounds: an offset within kSeatMaxOffset, a yaw within a turn
	CHECK(!v::parse_seat_line("driver, 25, 0, 0", p));
	CHECK(!v::parse_seat_line("0, -21, 0, 0", p));
	CHECK(!v::parse_seat_line("driver, 361", p));
	CHECK(v::parse_seat_line("driver, 20, -20, 20, -360", p));
	// a malformed seat ends the places there
	const v::CarSeats cut = parse({{"seats", "4"}, {"seat_1", "driver, 0.8, 0, 0"}, {"seat_2", "driver, 1, 2"}, {"seat_3", "driver"}});
	CHECK_EQ(int(cut.count), 2);
	CHECK(has_error(cut, "seat_2: malformed"));
	// a malformed exit keeps the seat on the side it is on
	const v::CarSeats side = parse({{"seats", "2"}, {"seat_1", "driver, 0.8, 0, 0"}, {"exit_1", "up"}});
	CHECK_EQ(int(side.count), 2);
	CHECK(!side.seat[1].exit_given);
	CHECK(has_error(side, "exit_1:"));
	// a malformed eye is left out
	for (const char* bad : {"0, 0.8", "0, 3, 0", "a, b, c", "0, 0.8, 0, 1"})
	{
		const v::CarSeats e = parse({{"seats", "1"}, {"eye", bad}});
		CHECK(!e.eye_given);
		CHECK(has_error(e, "eye:"));
	}
	const v::CarSeats eye = parse({{"seats", "1"}, {"eye", " 0.05, 0.8, 0.1 "}});
	CHECK(eye.eye_given && near_vec(eye.eye, 0.05f, 0.8f, 0.1f));
	CHECK(eye.errors.empty());
}

TEST(vehicle_seats_count_and_bounds)
{
	Lines m{{"seats", "8"}};
	for (int i = 1; i < 8; ++i)
		m["seat_" + std::to_string(i)] = "driver, 0, 0, " + std::to_string(-0.5 * i);
	const v::CarSeats eight = parse(m);
	CHECK(eight.errors.empty());
	CHECK_EQ(int(eight.count), int(v::kMaxSeats));
	// more places than a car may have in the table: the driver alone
	m["seats"] = "9";
	m["seat_8"] = "driver";
	const v::CarSeats nine = parse(m);
	CHECK_EQ(int(nine.count), 1);
	CHECK(has_error(nine, "seats:"));
	// spaces and tabs around the count
	const v::CarSeats spaced = parse({{"seats", "\t2 "}, {"seat_1", "driver,0.8,0,0"}});
	CHECK_EQ(int(spaced.count), 2);
	CHECK(spaced.errors.empty());
}

TEST(vehicle_seats_exit_side)
{
	v::ExitSide s = v::ExitSide::Left;
	CHECK(v::parse_exit_line("right", s) && s == v::ExitSide::Right);
	CHECK(v::parse_exit_line(" left ", s) && s == v::ExitSide::Left);
	CHECK(v::parse_exit_line("back", s) && s == v::ExitSide::Back);
	CHECK(!v::parse_exit_line("Right", s));
	CHECK(!v::parse_exit_line("front", s));
	CHECK(!v::parse_exit_line("", s));
	CHECK(std::string(v::exit_side_name(v::ExitSide::Back)) == "back");

	v::SeatPlace p;
	// no exit line: by the side the seat is on in the car's space
	CHECK(v::exit_side_of(p, v::seat_vec(-0.4f, 0.6f, 0.f)) == v::ExitSide::Left);
	CHECK(v::exit_side_of(p, v::seat_vec(0.4f, 0.6f, 0.f)) == v::ExitSide::Right);
	CHECK(v::exit_side_of(p, v::seat_vec(0.f, 0.6f, -1.f)) == v::ExitSide::Right);
	p.exit = v::ExitSide::Back;
	p.exit_given = true;
	CHECK(v::exit_side_of(p, v::seat_vec(-0.4f, 0.6f, 0.f)) == v::ExitSide::Back);

	// the door point: beside the box on that side, level with the seat, at the box's middle height
	const v::SeatVec lo = v::seat_vec(-0.8f, 0.f, -2.f), hi = v::seat_vec(0.8f, 1.6f, 2.f);
	const v::SeatVec seat = v::seat_vec(0.4f, 0.6f, -0.9f);
	CHECK(near_vec(v::seat_exit_local(lo, hi, seat, v::ExitSide::Left), -0.8f - v::kSeatExitClearance, 0.8f, -0.9f));
	CHECK(near_vec(v::seat_exit_local(lo, hi, seat, v::ExitSide::Right), 0.8f + v::kSeatExitClearance, 0.8f, -0.9f));
	CHECK(near_vec(v::seat_exit_local(lo, hi, seat, v::ExitSide::Back), 0.4f, 0.8f, -2.f - v::kSeatExitClearance));
	// a seat outside the box (on the roof's edge, a bad offset) still gets a point beside the box
	CHECK(near_vec(v::seat_exit_local(lo, hi, v::seat_vec(3.f, 0.f, 5.f), v::ExitSide::Left), -1.5f, 0.8f, 2.f));
	CHECK(near_vec(v::seat_exit_local(lo, hi, v::seat_vec(3.f, 0.f, 5.f), v::ExitSide::Back), 0.8f, 0.8f, -2.7f));
}

// ---------------------------------------------------------------------------------------------- the transforms

TEST(vehicle_seats_transform_composition)
{
	// turn_y: positive to the right; a seat facing +z turned by 90 degrees faces +x, its right is -z
	const v::SeatXform r = v::turn_y(v::seat_rad(90.f));
	CHECK(near_vec(r.k, 1.f, 0.f, 0.f));
	CHECK(near_vec(r.i, 0.f, 0.f, -1.f));
	CHECK(near_vec(r.j, 0.f, 1.f, 0.f));

	// compose = Fmatrix::mul_43(a, b): b first, then a
	v::SeatXform a = v::turn_y(v::seat_rad(90.f));
	a.c = v::seat_vec(10.f, 0.f, 0.f);
	v::SeatXform b;
	b.c = v::seat_vec(0.f, 0.f, 1.f);
	const v::SeatXform ab = v::compose(a, b);
	CHECK(near_vec(v::apply(ab, v::seat_vec(0.f, 0.f, 0.f)), 11.f, 0.f, 0.f)); // (0,0,1) turned to (1,0,0), then +10 x
	CHECK(near_vec(v::apply(ab, v::seat_vec(0.f, 0.f, 1.f)), 12.f, 0.f, 0.f));

	// the bone form: the driver's bone (here at -0.4, 0.6, 0.2 facing forward) moved 0.8 to the right in the car's space
	v::SeatXform bone;
	bone.c = v::seat_vec(-0.4f, 0.6f, 0.2f);
	v::SeatPlace right;
	v::parse_seat_line("driver, 0.8, 0, 0", right);
	const v::SeatXform front_right = v::seat_local(bone, right);
	CHECK(near_vec(front_right.c, 0.4f, 0.6f, 0.2f));
	CHECK(near_vec(front_right.k, 0.f, 0.f, 1.f));
	// the offset is in the car's space even when the bone is turned: a bone turned to face +x, moved +1 z, stays turned
	v::SeatXform side_bone = v::turn_y(v::seat_rad(90.f));
	side_bone.c = v::seat_vec(0.f, 1.f, 0.f);
	v::SeatPlace moved;
	v::parse_seat_line("bench, 0, 0, 1, 90", moved);
	const v::SeatXform bench = v::seat_local(side_bone, moved);
	CHECK(near_vec(bench.c, 0.f, 1.f, 1.f));
	CHECK(near_vec(bench.k, 0.f, 0.f, -1.f)); // +90 then +90: facing back
	// the point form: a point of the car's space, the car's axes turned
	v::SeatPlace roof;
	v::parse_seat_line("-0.6, 2.0, -1.5, -90", roof);
	const v::SeatXform roof_local = v::seat_local(v::SeatXform(), roof);
	CHECK(near_vec(roof_local.c, -0.6f, 2.f, -1.5f));
	CHECK(near_vec(roof_local.k, -1.f, 0.f, 0.f)); // facing the left side

	// the world: the car's XFORM after the seat (as CCar::VisualUpdate puts the Owner); a car at (100, 5, 50) facing +x
	v::SeatXform car = v::turn_y(v::seat_rad(90.f));
	car.c = v::seat_vec(100.f, 5.f, 50.f);
	const v::SeatXform world = v::compose(car, front_right);
	// the seat's (0.4 right, 0.6 up, 0.2 forward): forward is +x, right is -z
	CHECK(near_vec(world.c, 100.2f, 5.6f, 49.6f));
	CHECK(near_vec(world.k, 1.f, 0.f, 0.f));
	// back into the seat's space: unapply undoes apply
	const v::SeatVec p = v::seat_vec(1.f, 2.f, 3.f);
	CHECK(near_vec(v::unapply(world, v::apply(world, p)), 1.f, 2.f, 3.f));
}

TEST(vehicle_seats_eye)
{
	// the driver's camera (car space) in his seat's space: the passenger's eye over his seat
	v::SeatXform driver;
	driver.c = v::seat_vec(-0.4f, 0.65f, -0.1f);
	const v::SeatVec eye = v::seat_eye(nullptr, true, v::seat_vec(-0.4f, 1.42f, 0.02f), driver);
	CHECK(near_vec(eye, 0.f, 0.77f, 0.12f));
	// a camera far from the seat (a chase camera over a turret): the default
	CHECK(near_vec(v::seat_eye(nullptr, true, v::seat_vec(0.f, 3.45f, 1.f), driver), 0.f, 0.75f, 0.1f));
	// no camera_pos: the default
	CHECK(near_vec(v::seat_eye(nullptr, false, v::seat_vec(-0.4f, 1.42f, 0.02f), driver), 0.f, 0.75f, 0.1f));
	// the section's eye wins
	const v::CarSeats s = parse({{"seats", "1"}, {"eye", "0, 0.9, 0"}});
	CHECK(near_vec(v::seat_eye(&s, true, v::seat_vec(-0.4f, 1.42f, 0.02f), driver), 0.f, 0.9f, 0.f));
	// a turned driver's seat: the camera is read in its axes
	v::SeatXform turned = v::turn_y(v::seat_rad(90.f));
	turned.c = v::seat_vec(0.f, 0.6f, 0.f);
	CHECK(near_vec(v::seat_eye(nullptr, true, v::seat_vec(0.1f, 1.35f, 0.f), turned), 0.f, 0.75f, 0.1f));
	CHECK(v::seat_eye_sane(v::default_seat_eye()));
}

TEST(vehicle_seats_look_limits_and_the_car_turning)
{
	const v::LookLimits lim; // the stock car_firsteye_cam: yaw -2..2, pitch -0.5..0.3
	v::RideLook l = v::ride_look_start(lim);
	CHECK(near(l.rel_yaw, 0.f));
	CHECK(near(l.rel_pitch, -0.1f)); // the middle of the pitch limits, as CCameraBase::Load starts a clamped camera
	v::SeatXform seat; // facing +z
	float yaw = 0.f, pitch = 0.f;
	v::look_follow(l, 5.f, 5.f, lim); // the first frame takes nothing from the camera's old angles
	v::look_world(seat, l, yaw, pitch);
	CHECK(near(yaw, 0.f));
	CHECK(near(pitch, -0.1f));

	// the mouse turns the camera 0.5 right: the look follows
	v::look_follow(l, yaw + 0.5f, pitch, lim);
	v::look_world(seat, l, yaw, pitch);
	CHECK(near(l.rel_yaw, 0.5f));
	CHECK(near(yaw, 0.5f));

	// the car turns 90 degrees left: the look turns with it (still 0.5 right of the seat), the mouse did nothing
	v::SeatXform turned = v::turn_y(v::seat_rad(-90.f));
	v::look_follow(l, yaw, pitch, lim);
	v::look_world(turned, l, yaw, pitch);
	CHECK(near(l.rel_yaw, 0.5f));
	CHECK(near(yaw, -v::kSeatPi / 2.f + 0.5f, 1e-3f));

	// far to the right: held at the limit
	v::look_follow(l, yaw + 3.f, pitch, lim);
	CHECK(near(l.rel_yaw, lim.yaw_hi));
	// up and down: held at the limits (camera pitch: positive is down)
	v::look_follow(l, yaw, pitch + 2.f, lim);
	CHECK(near(l.rel_pitch, lim.pitch_hi));
	v::look_world(turned, l, yaw, pitch);
	v::look_follow(l, yaw, pitch - 3.f, lim);
	CHECK(near(l.rel_pitch, lim.pitch_lo));

	// the camera's yaw wraps across pi: a small turn stays small
	v::RideLook w = v::ride_look_start(lim);
	v::SeatXform back = v::turn_y(v::kSeatPi - 0.01f); // facing almost -z
	v::look_follow(w, 0.f, 0.f, lim);
	v::look_world(back, w, yaw, pitch);
	v::look_follow(w, yaw + 0.05f, pitch, lim); // across the wrap
	CHECK(near(w.rel_yaw, 0.05f, 1e-3f));

	// world angles: a camera's direction is setHP(-yaw, -pitch); a look up from a level seat has a negative camera pitch
	v::RideLook up = v::ride_look_start(lim);
	up.rel_pitch = -0.4f;
	v::look_world(seat, up, yaw, pitch);
	CHECK(near(pitch, -0.4f));
	// a car on a slope (nose up 0.2): the look straight ahead tilts with it
	v::SeatXform slope;
	slope.k = v::seat_vec(0.f, std::sin(0.2f), std::cos(0.2f));
	slope.j = v::seat_vec(0.f, std::cos(0.2f), -std::sin(0.2f));
	v::RideLook ahead = v::ride_look_start(lim);
	ahead.rel_pitch = 0.f;
	v::look_world(slope, ahead, yaw, pitch);
	CHECK(near(pitch, -0.2f, 1e-3f));
	CHECK(near(yaw, 0.f, 1e-3f));
}

// ---------------------------------------------------------------------------------------------- configs/coop_vehicles.ltx

// Every car section GAMMA spawns (grok_vehicles_spawner, the tm_military BTRs) has its places, and every section of the file reads
// without an error: the places of every car section of the stock vehicles.ltx are there.
TEST(vehicle_seats_ltx_reads_clean)
{
	const std::string text = seats_project_file("gamedata/configs/coop_vehicles.ltx");
	REQUIRE(!text.empty());
	const std::map<std::string, Lines> ltx = read_ltx(text);
	for (const char* need : {"veh_tr13", "veh_zaz_968", "veh_niva", "veh_uaz_01", "veh_uaz_02", "veh_kamaz", "veh_zaz", "veh_btr",
	         "veh_uaz_buhanka", "veh_moskvich", "veh_zil_130", "veh_zil_131", "veh_kamaz_fura", "veh_laz", "veh_kavz", "veh_gaz",
	         "veh_hl2baggi"})
	{
		auto it = ltx.find(need);
		CHECK(it != ltx.end());
		if (it == ltx.end())
		{
			std::printf("    no section [%s]\n", need);
			continue;
		}
		const v::CarSeats s = parse(it->second);
		for (const std::string& e : s.errors)
			std::printf("    [%s] %s\n", need, e.c_str());
		CHECK(s.errors.empty());
		CHECK(it->second.count("seats") == 1);
		// every line of the section is one the parser reads: a typo in a key is not a silent driver-alone car
		for (const auto& kv : it->second)
		{
			const std::string& k = kv.first;
			const bool known = k == "seats" || k == "eye" || (k.compare(0, 5, "seat_") == 0 && k.size() == 6) ||
			    (k.compare(0, 5, "exit_") == 0 && k.size() == 6);
			CHECK(known);
			if (k.size() == 6 && (k.compare(0, 5, "seat_") == 0 || k.compare(0, 5, "exit_") == 0))
				CHECK(k[5] >= '1' && k[5] < char('0' + s.count));
		}
	}
	// the cars GAMMA spawns carry passengers, the tractor's cab is one place
	auto count = [&ltx](const char* section)
	{
		auto it = ltx.find(section);
		return it == ltx.end() ? 0 : int(parse(it->second).count);
	};
	for (const char* car : {"veh_niva", "veh_uaz_01", "veh_uaz_02", "veh_zaz_968", "veh_zaz", "veh_kamaz", "veh_btr"})
		CHECK(count(car) >= 2);
	CHECK_EQ(count("veh_tr13"), 1);
	// no section names a car twice with different places
	size_t sections = 0;
	for (size_t at = text.find("\n["); at != std::string::npos; at = text.find("\n[", at + 1))
		++sections;
	CHECK_EQ(sections + (text[0] == '[' ? 1 : 0), ltx.size());
}

// ---------------------------------------------------------------------------------------------- the engine, read from the source

// The decider: the seat count of a car is its places in the ltx, a passenger's seat transform and door come from them.
TEST(vehicle_seats_the_decider_reads_the_places)
{
	const std::string seat = seats_project_file("engine/src/xrGame/coop/coop_vehicles_seat.cpp");
	REQUIRE(!seat.empty());
	CHECK(seat.find("#include \"coop_vehicles_ride.h\"") != std::string::npos);
	const std::string count = seats_body(seat, "u8 seat_count(CCar* car)");
	CHECK(count.find("return car_seat_count(car);") != std::string::npos);
	const std::string xf = seats_body(seat, "bool seat_transform(CCar* car, u8 seat, Fmatrix& out)");
	REQUIRE(!xf.empty());
	const size_t passenger = xf.find("return passenger_seat(car, seat, out);");
	const size_t driver = xf.find("car_definition");
	CHECK(passenger != std::string::npos && driver != std::string::npos && passenger < driver);
	const std::string exitp = seats_body(seat, "Fvector exit_position(CCar* car, const Sitter& s)");
	const size_t door = exitp.find("passenger_exit(car, s.seat, stock);");
	const size_t candidates = exitp.find("exit_candidates(");
	CHECK(door != std::string::npos && candidates != std::string::npos && door < candidates);

	const std::string api = seats_project_file("engine/src/xrGame/coop/coop_vehicles.h");
	CHECK(api.find("void ride_begin(u16 car, u8 seat, const RideLink& link);") != std::string::npos);
	CHECK(api.find("void ride_frame();") != std::string::npos);
	CHECK(api.find("bool riding();") != std::string::npos);
	// the link gap: the bodies the hubs call
	const std::string ride = seats_project_file("engine/src/xrGame/coop/coop_vehicles_ride.cpp");
	REQUIRE(!ride.empty());
	CHECK(ride.find("// Ядро: без проверок режима (docs/MODES.md)\n") == 0);
	for (const char* body : {"\nvoid ride_frame()", "\nbool riding()", "\nvoid ride_begin(u16 car, u8 seat, const RideLink& link)",
	         "\nu8 car_seat_count(CCar* car)", "\nbool passenger_seat(CCar* car, u8 seat, Fmatrix& out)",
	         "\nbool passenger_exit(CCar* car, u8 seat, Fvector& out)", "\nbool ride_camera(CActor* actor, float fov)",
	         "\nvoid ride_actor_died()", "\nbool ride_key(int cmd)", "\nbool ride_hold(int cmd)", "\nvoid ride_print_status()"})
		CHECK(ride.find(body) != std::string::npos);
	const std::string sync = seats_project_file("engine/src/xrGame/coop/coop_sync.cpp");
	CHECK(sync.find("vehicles::ride_frame();") != std::string::npos);
}

// A player's machine: VehicleSeat granted to me for a seat >= 1 starts the ride instead of asking out (rv_F5-VEH-3).
TEST(vehicle_seats_the_ride_step_starts_the_ride)
{
	const std::string client = seats_project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp");
	REQUIRE(!client.empty());
	const size_t from = client.find("case SeatStep::Ride:");
	const size_t to = client.find("case SeatStep::Leave:", from);
	REQUIRE(from != std::string::npos && to != std::string::npos);
	const std::string step = client.substr(from, to - from);
	CHECK(step.find("ride_begin(m.car, m.seat, link);") != std::string::npos);
	CHECK(step.find("not in this build") == std::string::npos);
	// the seat stays this machine's (coop.vehicle.status, F asks out of it, a release or a loss ends it)
	const size_t keep_car = step.find("g_mine.car = m.car;");
	const size_t begin = step.find("ride_begin(");
	CHECK(keep_car != std::string::npos && keep_car < begin);
	CHECK(step.find("link.still_mine = [](u16 car, u8 seat) { return g_mine.car == car && g_mine.seat == seat && !g_mine.leave_due; };") !=
	    std::string::npos);
	CHECK(step.find("link.ask_out = [] { want_exit(now32()); };") != std::string::npos);
}

// The ride ports CActor::attach_Vehicle / detach_Vehicle line by line for an actor who is not the copy's Owner: the stock lines in
// the stock order (m_holder, the Owner, the car's attach_Actor / detach_Actor and the decider's own-actor rows left out).
TEST(vehicle_seats_the_ride_ports_the_stock_attach_and_detach)
{
	const std::string actor = seats_project_file("engine/src/xrGame/Actor.cpp");
	const std::string ride = seats_project_file("engine/src/xrGame/coop/coop_vehicles_ride.cpp");
	REQUIRE(!actor.empty() && !ride.empty());
	const std::string stock_in = seats_body(actor, "bool CActor::attach_Vehicle(CHolderCustom *object, bool bForce)");
	const std::string stock_out = seats_body(actor, "void CActor::detach_Vehicle(bool bForce)");
	const std::string sit = seats_body(ride, "void sit(CActor* a, CCar* car)");
	const std::string out = seats_body(ride, "bool stand_up(CActor* a, CCar* car, const Fvector& at, bool box_test)");
	REQUIRE(!stock_in.empty() && !stock_out.empty() && !sit.empty() && !out.empty());
	const std::vector<std::string> in_lines = {"SetPrevActiveSlot(", "GetActiveSlot()", "SetActiveSlot(NO_ACTIVE_SLOT)",
	    "SetWeaponHideState(INV_STATE_BLOCK_ALL, true)", "DestroyCharacter()", "destroy_physics_shell(actor_camera_shell)",
	    "LL_BoneID(\"bip01_spine\")).reset_callback()", "LL_BoneID(\"bip01_spine1\")).reset_callback()",
	    "LL_BoneID(\"bip01_spine2\")).reset_callback()", "IsRemoteControl() == false", "DriverAnimationType()",
	    "m_vehicles_type_collections[anim_type]", "PlayCycle(anims.idles[0], FALSE)", "on_animation_start(MotionID(), 0)",
	    "callback(GameObject::eAttachVehicle)(", "lua_game_object())"};
	std::string missing;
	CHECK(in_order(stock_in, in_lines, missing));
	if (!missing.empty())
		std::printf("    stock attach_Vehicle: no %s\n", missing.c_str());
	missing.clear();
	CHECK(in_order(sit, in_lines, missing));
	if (!missing.empty())
		std::printf("    ride sit: no %s\n", missing.c_str());
	// the Owner's parts are not the passenger's
	CHECK(sit.find("m_holder") == std::string::npos && sit.find("attach_Actor") == std::string::npos);
	CHECK(sit.find("own_actor_attached") == std::string::npos);

	const std::vector<std::string> out_lines = {"SplitterHolderDeactivate()", "ActivateBoxDynamic(0)", "SplitterHolderActivate()",
	    "return", "SplitterHolderActivate()", "SetWeaponHideState(INV_STATE_BLOCK_ALL, false)", "SetActiveSlot(",
	    "GetPrevActiveSlot()", "SetPrevActiveSlot(NO_ACTIVE_SLOT)", "CreateCharacter()", "SetPosition(", "SetVelocity(",
	    "ExitVelocity()", "Direction().set(Fvector().setHP(", "Direction().getH(), 0.0F))", "SetCallbacks()",
	    "PlayCycle(", "m_normal.legs_idle)", "PlayCycle(", "m_normal.m_torso_idle)", "callback(GameObject::eDetachVehicle)(",
	    "lua_game_object())"};
	missing.clear();
	CHECK(in_order(stock_out, out_lines, missing));
	if (!missing.empty())
		std::printf("    stock detach_Vehicle: no %s\n", missing.c_str());
	missing.clear();
	CHECK(in_order(out, out_lines, missing));
	if (!missing.empty())
		std::printf("    ride stand_up: no %s\n", missing.c_str());
	CHECK(out.find("m_holder") == std::string::npos && out.find("detach_Actor") == std::string::npos);
	CHECK(out.find("own_actor_detached") == std::string::npos);
}

// The hooks: one call each, at the place where the stock treats its driver (m_holder) the same way.
TEST(vehicle_seats_actor_hooks)
{
	const std::string actor = seats_project_file("engine/src/xrGame/Actor.cpp");
	REQUIRE(!actor.empty());
	CHECK(actor.find("#include \"coop/coop_vehicles_ride.h\"") != std::string::npos);
	// Die: the stock driver leaves his car first (use_HolderEx(NULL, true)), then the body dies
	const std::string die = seats_body(actor, "void CActor::Die(CObject* who)");
	const size_t holder = die.find("use_HolderEx(NULL, true);");
	const size_t ride_died = die.find("coop::vehicles::ride_actor_died();");
	const size_t dies = die.find("inherited::Die(who);");
	CHECK(holder != std::string::npos && ride_died != std::string::npos && dies != std::string::npos);
	CHECK(holder < ride_died && ride_died < dies);
	// UpdateCL: cam_Update returns for a holder; a passenger's camera is the ride's
	const std::string update = seats_body(actor, "void CActor::UpdateCL()");
	const size_t cam = update.find("if (!coop::vehicles::ride_camera(this, currentFOV()))");
	const size_t stock_cam = update.find("cam_Update(float(Device.dwTimeDelta) / 1000.0f, currentFOV());");
	CHECK(cam != std::string::npos && stock_cam != std::string::npos && cam < stock_cam);
	CHECK(update.find(";", cam) > stock_cam); // the stock call is the hook's own statement
	// shedule_Update: as `if (m_holder ...)`, before it: no controls, no physics, no walking sway of his own
	const std::string shed = seats_body(actor, "void CActor::shedule_Update(u32 DT)");
	const size_t riding = shed.find("if (coop::vehicles::riding())");
	const size_t stock_holder = shed.find("if (m_holder || !getEnabled() || !Ready())");
	const size_t controls = shed.find("g_cl_CheckControls(");
	REQUIRE(riding != std::string::npos && stock_holder != std::string::npos && riding < stock_holder && stock_holder < controls);
	const std::string block = shed.substr(riding, stock_holder - riding);
	CHECK(block.find("Cameras().RemoveCamEffector(eCEBobbing);") != std::string::npos);
	CHECK(block.find("pCamBobbing = NULL;") != std::string::npos);
	CHECK(block.find("inherited::shedule_Update(DT);") != std::string::npos);
	CHECK(block.find("return;") != std::string::npos);
	// the first-person legs hang on the camera: none in a seat, as none for the stock driver
	const std::string legs = seats_body(actor, "bool canRenderLegs(CActor* actor, CHolderCustom* m_holder) noexcept");
	CHECK(legs.find("&& !coop::vehicles::riding()") != std::string::npos);

	const std::string input = seats_project_file("engine/src/xrGame/ActorInput.cpp");
	REQUIRE(!input.empty());
	CHECK(input.find("#include \"coop/coop_vehicles_ride.h\"") != std::string::npos);
	const std::string press = seats_body(input, "void CActor::IR_OnKeyboardPress(int cmd)");
	const size_t alive = press.find("if (!g_Alive()) return;");
	const size_t key = press.find("if (coop::vehicles::ride_key(cmd)) return;");
	const size_t press_holder = press.find("if (m_holder && kUSE != cmd)");
	const size_t use = press.find("ActorUse();");
	CHECK(alive != std::string::npos && key != std::string::npos && press_holder != std::string::npos);
	CHECK(alive < key && key < press_holder && press_holder < use);
	const std::string release = seats_body(input, "void CActor::IR_OnKeyboardRelease(int cmd)");
	const size_t rel_riding = release.find("if (coop::vehicles::riding()) return;");
	const size_t rel_holder = release.find("if (m_holder)");
	CHECK(rel_riding != std::string::npos && rel_holder != std::string::npos && rel_riding < rel_holder);
	CHECK(release.find("if (g_Alive())") < rel_riding);
	const std::string hold = seats_body(input, "void CActor::IR_OnKeyboardHold(int cmd)");
	const size_t ride_hold = hold.find("if (coop::vehicles::ride_hold(cmd)) return;");
	const size_t hold_holder = hold.find("if (m_holder)");
	CHECK(ride_hold != std::string::npos && hold_holder != std::string::npos && ride_hold < hold_holder);
}

// ---------------------------------------------------------------------------------------------- the integration (rv_F5-VEH-5)

// Blocker 1 of rv_F5-VEH-5: the stock actor's hooks run in every process and world, ride_frame only inside a session (sync::frame). A
// ride keeps the world it sat in: of another world (a load, a level change) or of a session that is over it answers false everywhere
// and is cleared, so a single player loaded after a co-op session in which he sat as a passenger moves, acts and looks as the stock
// actor does. The session's end (sync::reset) clears it too, next to the decider's session_over().
TEST(vehicle_seats_the_ride_keeps_its_world)
{
	const std::string ride = seats_project_file("engine/src/xrGame/coop/coop_vehicles_ride.cpp");
	REQUIRE(!ride.empty());
	// the record keeps the world it sat in (and the world a granted seat waits in), stored where he sits
	CHECK(ride.find("u32 world = 0; // join::world_generation() of the world he sat in") != std::string::npos);
	CHECK(ride.find("u32 due_world = 0; // join::world_generation() of the world the seat was granted in") != std::string::npos);
	const std::string begin = seats_body(ride, "void begin(CActor* a, u32 now)");
	REQUIRE(!begin.empty());
	const size_t fresh = begin.find("g = Ride();");
	const size_t world = begin.find("g.world = join::world_generation();");
	CHECK(fresh != std::string::npos && world != std::string::npos && fresh < world);
	const std::string granted = seats_body(ride, "\nvoid ride_begin(u16 car, u8 seat, const RideLink& link)");
	CHECK(granted.find("g.due_world = join::world_generation();") != std::string::npos);
	// one test of a ride that is this world's, asked by every hook of the stock actor; none of them reads g.on alone
	const std::string here = seats_body(ride, "bool on_here()");
	CHECK(here.find("return g.on && g.world == join::world_generation();") != std::string::npos);
	CHECK(ride.find("bool riding() { return on_here(); }") != std::string::npos);
	const std::string camera = seats_body(ride, "\nbool ride_camera(CActor* actor, float fov)");
	CHECK(camera.find("if (!on_here() || !actor || actor != g.actor)") != std::string::npos);
	const std::string died = seats_body(ride, "\nvoid ride_actor_died()");
	CHECK(died.find("if (!on_here())") != std::string::npos);
	const std::string key = seats_body(ride, "\nbool ride_key(int cmd)");
	CHECK(key.find("if (!on_here())\n\t\treturn false;") != std::string::npos);
	const std::string hold = seats_body(ride, "\nbool ride_hold(int cmd)");
	CHECK(hold.find("if (!on_here())\n\t\treturn false;") != std::string::npos);
	for (const std::string* body : {&camera, &died, &key, &hold})
	{
		REQUIRE(!body->empty());
		CHECK(body->find("!g.on") == std::string::npos);
	}
	// ride_frame clears a ride of another world, or a seat granted in one, before anything else
	const std::string frame = seats_body(ride, "\nvoid ride_frame()");
	const size_t stale = frame.find("(g.on && (a != g.actor || g.world != join::world_generation()))");
	const size_t stale_due = frame.find("(g.due && g.due_world != join::world_generation())");
	const size_t forget = frame.find("forget();");
	const size_t first_use = frame.find("const u32 now = now32();");
	CHECK(stale != std::string::npos && stale_due != std::string::npos && forget != std::string::npos);
	CHECK(stale < forget && stale_due < forget && forget < first_use);
	// the session's end: declared with the module's session_over, called by sync::reset next to it, forgets the ride
	const std::string api = seats_project_file("engine/src/xrGame/coop/coop_vehicles.h");
	CHECK(api.find("void ride_session_over();") != std::string::npos);
	const std::string over = seats_body(ride, "\nvoid ride_session_over()");
	REQUIRE(!over.empty());
	const size_t stand = over.find("if (on_here() && world_up())");
	const size_t forgotten = over.find("forget();");
	CHECK(stand != std::string::npos && forgotten != std::string::npos && stand < forgotten);
	CHECK(over.find("a == g.actor") != std::string::npos && over.find("leave(a, car_copy(g.car), now32(), true);") != std::string::npos);
	const std::string sync = seats_project_file("engine/src/xrGame/coop/coop_sync.cpp");
	const std::string reset = seats_body(sync, "\nvoid reset()");
	const size_t decider = reset.find("vehicles::session_over();");
	const size_t passenger = reset.find("vehicles::ride_session_over();");
	CHECK(decider != std::string::npos && passenger != std::string::npos && decider < passenger);
}

// Should-fix 1 of rv_F5-VEH-5: a passenger stands where the decider stood his character (VehicleSeat released carries the point, as for a
// driver, docs/VEHICLES.md 5.8): the client's Leave case hands it to the ride before its record of the seat goes; the copy's own door
// and free point only when the decider sent none (a loss, a refusal that crossed a release).
TEST(vehicle_seats_the_passenger_stands_at_the_deciders_point)
{
	const std::string api = seats_project_file("engine/src/xrGame/coop/coop_vehicles.h");
	CHECK(api.find("void ride_exit_point(u16 car, u8 seat, const Fvector& at);") != std::string::npos);
	const std::string client = seats_project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp");
	REQUIRE(!client.empty());
	const size_t from = client.find("case SeatStep::Leave:");
	const size_t to = client.find("case SeatStep::Lost:", from);
	REQUIRE(from != std::string::npos && to != std::string::npos);
	const std::string step = client.substr(from, to - from);
	const size_t point = step.find("g_mine.exit.set(m.exit[0], m.exit[1], m.exit[2]);");
	const size_t passenger = step.find("if (g_mine.seat != kDriverSeat)");
	const size_t handed = step.find("ride_exit_point(m.car, m.seat, g_mine.exit);");
	CHECK(point != std::string::npos && passenger != std::string::npos && handed != std::string::npos);
	CHECK(point < passenger && passenger < handed);
	// the other cases hand nothing: a loss and a refusal stand him at the copy's own point
	CHECK(client.find("ride_exit_point(") == from + handed);

	const std::string ride = seats_project_file("engine/src/xrGame/coop/coop_vehicles_ride.cpp");
	const std::string take = seats_body(ride, "\nvoid ride_exit_point(u16 car, u8 seat, const Fvector& at)");
	REQUIRE(!take.empty());
	CHECK(take.find("if (!on_here() || g.car != car || g.seat != seat)") != std::string::npos);
	CHECK(take.find("g.decider_exit = true;") != std::string::npos && take.find("g.decider_at = at;") != std::string::npos);
	const std::string leave = seats_body(ride, "bool leave(CActor* a, CCar* car, u32 now, bool force_now)");
	REQUIRE(!leave.empty());
	const size_t own = leave.find("if (!g.decider_exit)\n\t\trefresh_exit(car, now, true);");
	const size_t at = leave.find("const Fvector at = g.decider_exit ? g.decider_at : g.has_exit ? g.exit : a->Position();");
	const size_t stands = leave.find("stand_up(a, car, at, !force)");
	CHECK(own != std::string::npos && at != std::string::npos && stands != std::string::npos && own < at && at < stands);
	// a switch of seat in the same car forgets a point of the old seat
	const std::string frame = seats_body(ride, "\nvoid ride_frame()");
	const size_t moved = frame.find("g.seat = g.due_seat;");
	const size_t dropped = frame.find("g.decider_exit = false;", moved);
	CHECK(moved != std::string::npos && dropped != std::string::npos);
}

// Should-fix 2 of rv_F5-VEH-5: the copy gone, he still stands up with actor_on_detach_vehicle fired (nil: there is no car), so the flags
// G.A.M.M.A.'s mods keep from it clear (move_effects MovementAllowed, LevelChangeCars / YACS InCar). It goes to SendScriptCallback
// directly: the stock binder's own handler (bind_stalker_ext.actor_on_detach_vehicle) calls obj:section() after it and would raise a
// Lua error on nil. With the copy here the stock object callback stays, with the car.
TEST(vehicle_seats_the_detach_callback_without_the_copy)
{
	const std::string ride = seats_project_file("engine/src/xrGame/coop/coop_vehicles_ride.cpp");
	REQUIRE(!ride.empty());
	CHECK(ride.find("#include \"coop_script.h\"") != std::string::npos);
	const std::string out = seats_body(ride, "bool stand_up(CActor* a, CCar* car, const Fvector& at, bool box_test)");
	REQUIRE(!out.empty());
	const size_t stock = out.find("if (car)\n\t\ta->callback(GameObject::eDetachVehicle)(car->lua_game_object());\n\telse");
	const size_t nil = out.find("script::queue_callback(\"actor_on_detach_vehicle\", {script::cb_nil()});");
	CHECK(stock != std::string::npos && nil != std::string::npos && stock < nil);
	// never a nil game object into the stock binder's callback
	CHECK(out.find("eDetachVehicle)(nullptr") == std::string::npos && out.find("eDetachVehicle)(NULL") == std::string::npos);
	CHECK(out.find("eDetachVehicle)(0") == std::string::npos && out.find("(CScriptGameObject*)") == std::string::npos);
}

// Should-fix 3 of rv_F5-VEH-5: the multi-item pickup (F held, AF_MULTI_ITEM_PICKUP) is gated on `!m_holder` for the stock driver; a
// passenger has no holder, so the gate asks the ride too.
TEST(vehicle_seats_no_pickup_mode_in_a_seat)
{
	const std::string actor = seats_project_file("engine/src/xrGame/Actor.cpp");
	REQUIRE(!actor.empty());
	const std::string update = seats_body(actor, "void CActor::UpdateCL()");
	REQUIRE(!update.empty());
	const size_t gate = update.find("StopAnyMove())) && !m_holder && !coop::vehicles::riding())");
	const size_t pickup = update.find("const bool allowed = psActorFlags.test(AF_MULTI_ITEM_PICKUP);");
	CHECK(gate != std::string::npos && pickup != std::string::npos && gate < pickup);
}

// The integration of F5-VEH-4 / F5-VEH-5: their status lines in coop_status, and their bodies compiled into xrGame (the link gap:
// state_frame, state_on_state, copy_sound_scale, doll_frame, ride_frame, riding, ride_begin ...).
TEST(vehicle_seats_the_hubs_and_the_project)
{
	const std::string sync = seats_project_file("engine/src/xrGame/coop/coop_sync.cpp");
	REQUIRE(!sync.empty());
	CHECK(sync.find("#include \"coop_vehicles_state.h\"") != std::string::npos);
	CHECK(sync.find("#include \"coop_vehicles_ride.h\"") != std::string::npos);
	const std::string status = seats_body(sync, "\nvoid print_status()");
	const size_t client = status.find("vehicles::client_print_status();");
	const size_t state = status.find("vehicles::state_print_status();");
	const size_t ride = status.find("vehicles::ride_print_status();");
	CHECK(client != std::string::npos && state != std::string::npos && ride != std::string::npos);
	CHECK(client < state && state < ride);

	const std::string project = seats_project_file("engine/src/xrGame/xrGame.vcxproj");
	const std::string filters = seats_project_file("engine/src/xrGame/xrGame.vcxproj.filters");
	REQUIRE(!project.empty() && !filters.empty());
	for (const char* cpp : {"coop\\coop_vehicles_state.cpp", "coop\\coop_vehicles_ride.cpp", "coop\\coop_vehicles_seat.cpp",
	         "coop\\coop_vehicles_client.cpp"})
	{
		CHECK(project.find(std::string("<ClCompile Include=\"") + cpp + "\" />") != std::string::npos);
		CHECK(filters.find(std::string("<ClCompile Include=\"") + cpp + "\">\n      <Filter>Coop</Filter>") != std::string::npos);
	}
	for (const char* h : {"coop\\coop_vehicles_state.h", "coop\\coop_vehicles_ride.h"})
	{
		CHECK(project.find(std::string("<ClInclude Include=\"") + h + "\" />") != std::string::npos);
		CHECK(filters.find(std::string("<ClInclude Include=\"") + h + "\">\n      <Filter>Coop</Filter>") != std::string::npos);
	}
}

// Should-fix S1 of F5-REV-1 (both modes): the player's mirror of the decider's seat table and his own seat record belong to one world.
// The decider forgets its table at a world change without a released message, and arrivals send only the sitters of the new world: a
// stale row kept another player seated (drawn in the car, his snapshots skipped) after a load (co-op) or after a trip to another map and
// back (Server). A player's machine now forgets the mirror, the request, the input, the latch and its own seat when the world changes:
// before it applies a VehicleSeat and at the start of its frame; a session's start takes the world it starts in.
TEST(vehicle_seats_the_mirror_forgets_an_old_world)
{
	const std::string client = seats_project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp");
	REQUIRE(!client.empty());
	CHECK(client.find("\nu32 g_world = 0;") != std::string::npos);
	const std::string world = seats_body(client, "\nvoid client_world()");
	REQUIRE(!world.empty());
	std::string missing;
	CHECK(in_order(world,
	          {"const u32 w = join::world_generation();", "if (w == g_world)", "return;", "g_world = w;", "g_table.clear();",
	              "g_req.reset();", "g_input.stop();", "g_tap.reset();", "g_mine = Mine();"},
	          missing));
	CHECK_EQ(missing, std::string());

	const std::string seat = seats_body(client, "\nvoid client_on_seat(PeerId, Reader& r)");
	missing.clear();
	CHECK(in_order(seat, {"if (!is_mirror())", "return;", "client_world();", "g_table.apply(m);"}, missing));
	CHECK_EQ(missing, std::string());

	const std::string frame = seats_body(client, "\nvoid client_frame()");
	missing.clear();
	CHECK(in_order(frame, {"if (!is_mirror() || !world_up())", "return;", "client_world();", "CActor* actor = Actor();"}, missing));
	CHECK_EQ(missing, std::string());

	const std::string install = seats_body(client, "\nvoid install_client(Endpoint& e)");
	CHECK(install.find("g_tap.reset();") != std::string::npos);
	CHECK(install.find("g_world = join::world_generation();") != std::string::npos);
}
