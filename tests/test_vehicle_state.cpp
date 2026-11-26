// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: vehicles for players, a car's state on every copy and the dolls of sitters (F5-VEH-4, docs/VEHICLES.md
// sections 3, 5.4, 5.6 and 11): the quantization of the stock fields into VehicleState, when the decider sends it (a change, 2 Hz while
// the engine runs, silent when parked), what a copy does with it (the stock calls, the rpm of its engine sound), the doll's pose, the
// stock hooks (CarSound.cpp, coop_players.cpp, Car.h), who sends and who plays it in each process kind, and the items of the lead's
// list this unit owns: the session's rate rows of VehicleReq / VehicleInput (coop_limits.h) and the rv_F5-VEH-3 non-blocking items of
// coop_vehicles_client.cpp (no input once released, a tap of a gear is not lost, a "no answer" line for both modes).
// Real Sessions over 127.0.0.1 for the rate rows: ports 39410..39413.
#include "test_util.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "coop_limits.h"
#include "coop_vehicle_input_rules.h"
#include "coop_vehicle_state_rules.h"
#include "support/fake_mode.h"

namespace v = coop::vehicles;
namespace k = coop::vehicles::keys;
using coop::Msg;

namespace
{
// anomaly-coop/<rel> (tests\ -> ..), raw bytes
std::string project_bytes(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

// anomaly-coop/<rel> without '\r'
std::string project_file(const std::string& rel)
{
	std::string text = project_bytes(rel);
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// The text without /* */ and // comments (the string literals read here have neither).
std::string without_comments(const std::string& s)
{
	std::string out;
	for (size_t i = 0; i < s.size();)
	{
		if (s.compare(i, 2, "/*") == 0)
		{
			const size_t end = s.find("*/", i + 2);
			i = end == std::string::npos ? s.size() : end + 2;
			continue;
		}
		if (s.compare(i, 2, "//") == 0)
		{
			const size_t end = s.find('\n', i);
			i = end == std::string::npos ? s.size() : end;
			continue;
		}
		out += s[i++];
	}
	return out;
}

std::string between(const std::string& src, const std::string& from, const std::string& to)
{
	const size_t at = src.find(from);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find(to, at + from.size());
	return src.substr(at, end == std::string::npos ? std::string::npos : end - at);
}

std::vector<uint8_t> bytes_of(const v::StateMsg& m)
{
	coop::Writer w;
	v::write(w, m);
	return w.data();
}

bool read_bytes(const std::vector<uint8_t>& b, v::StateMsg& out)
{
	coop::Reader r(b.data(), b.size());
	return v::read(r, out);
}

v::CarReading driving(float rpm)
{
	v::CarReading r;
	r.engine = true;
	r.lights = false;
	r.handbrake = false;
	r.rpm = rpm;
	r.max_rpm = 600.f;
	r.transmission = 2;
	r.neutral = false;
	r.health = 0.9f;
	r.fuel = 30.f;
	r.tank = 60.f;
	r.damage = 0;
	r.sitter = true;
	return r;
}

constexpr uint16_t kCar = 0x0123;
} // namespace

// ---------------------------------------------------------------- quantization

TEST(vehicle_state_quantization_of_the_stock_fields)
{
	// rpm: of m_max_rpm, rounded; back to the copy's m_max_rpm within half a step
	CHECK_EQ(v::rpm_byte(0.f, 600.f), uint8_t(0));
	CHECK_EQ(v::rpm_byte(600.f, 600.f), uint8_t(255));
	CHECK_EQ(v::rpm_byte(900.f, 600.f), uint8_t(255)); // above the max (a script's SetRPM): clamped
	CHECK_EQ(v::rpm_byte(-5.f, 600.f), uint8_t(0));
	CHECK_EQ(v::rpm_byte(std::nanf(""), 600.f), uint8_t(0));
	CHECK_EQ(v::rpm_byte(300.f, 0.f), uint8_t(0)); // no max: nothing to measure against
	for (float rpm = 0.f; rpm <= 600.f; rpm += 7.3f)
		CHECK(std::fabs(v::fraction_of(v::rpm_byte(rpm, 600.f)) * 600.f - rpm) <= 600.f / 255.f / 2.f + 1e-3f);
	// health of 1.0
	CHECK_EQ(v::health_byte(1.f), uint8_t(255));
	CHECK_EQ(v::health_byte(0.5f), uint8_t(128));
	CHECK_EQ(v::health_byte(-1.f), uint8_t(0));
	// fuel rounds UP: any fuel at all is never 0 (StartEngine refuses an empty tank on the copy)
	CHECK_EQ(v::fuel_byte(0.f, 60.f), uint8_t(0));
	CHECK_EQ(v::fuel_byte(0.001f, 60.f), uint8_t(1));
	CHECK_EQ(v::fuel_byte(60.f, 60.f), uint8_t(255));
	CHECK_EQ(v::fuel_byte(80.f, 60.f), uint8_t(255));
	CHECK_EQ(v::fuel_byte(10.f, 0.f), uint8_t(0));
	CHECK(v::fuel_of(v::fuel_byte(0.001f, 60.f), 60.f) > 0.001f); // the copy's tank is never below the decider's
	CHECK(v::fuel_of(v::fuel_byte(30.f, 60.f), 60.f) >= 30.f);
	// gear: neutral 0, the stock transmission 0 (DriveBack) -1, forward gears as they are, capped at kMaxGear
	CHECK_EQ(v::gear_of(3, true), int8_t(0));
	CHECK_EQ(v::gear_of(0, false), int8_t(-1));
	CHECK_EQ(v::gear_of(1, false), int8_t(1));
	CHECK_EQ(v::gear_of(4, false), int8_t(4));
	CHECK_EQ(v::gear_of(99, false), v::kMaxGear);
	// damage: m_level_applied, 0..3; u16(-1) (before CDamagableItem::Init) is no damage
	CHECK_EQ(v::damage_stage(0), uint8_t(0));
	CHECK_EQ(v::damage_stage(2), uint8_t(2));
	CHECK_EQ(v::damage_stage(7), v::kMaxDamageStage);
	CHECK_EQ(v::damage_stage(uint16_t(-1)), uint8_t(0));
}

TEST(vehicle_state_what_the_decider_reads_goes_on_the_wire)
{
	v::CarReading r = driving(450.f);
	r.lights = true;
	r.damage = 1;
	const v::StateMsg m = v::state_of(kCar, r);
	CHECK_EQ(m.car, kCar);
	CHECK_EQ(m.flags, uint8_t(v::kStateEngine | v::kStateLights));
	CHECK_EQ(m.rpm, v::rpm_byte(450.f, 600.f));
	CHECK_EQ(m.gear, int8_t(2));
	CHECK_EQ(m.health, v::health_byte(0.9f));
	CHECK_EQ(m.fuel, v::fuel_byte(30.f, 60.f));
	CHECK_EQ(m.damage, uint8_t(1));
	// every reading makes a message the copies read (VehicleState read() bounds every field)
	const std::vector<uint8_t> b = bytes_of(m);
	CHECK_EQ(b.size(), size_t(8));
	v::StateMsg out;
	REQUIRE(read_bytes(b, out));
	CHECK(v::same_but_rpm(out, m) && out.rpm == m.rpm);
	v::CarReading odd = r;
	odd.transmission = 0;
	odd.neutral = false;
	odd.damage = 9;
	odd.handbrake = true;
	odd.health = 7.f;
	CHECK(read_bytes(bytes_of(v::state_of(kCar, odd)), out));
	CHECK_EQ(out.gear, int8_t(-1));
	CHECK_EQ(out.damage, v::kMaxDamageStage);
	CHECK(out.flags & v::kStateHandbrake);
	// live: a sitter or a running engine
	v::CarReading parked;
	CHECK(!v::live(parked));
	parked.sitter = true;
	CHECK(v::live(parked));
	parked.sitter = false;
	parked.engine = true;
	CHECK(v::live(parked));
}

// ---------------------------------------------------------------- the decider's cadence

TEST(vehicle_state_cadence_change_two_hz_and_silent_when_parked)
{
	v::StateCadence c;
	v::CarReading r;
	r.max_rpm = 600.f;
	r.tank = 60.f;
	r.fuel = 60.f;
	r.handbrake = true;
	// a parked car nobody used: never a word, however long
	for (uint32_t t = 0; t < 60000; t += 1000)
		CHECK(c.step(v::state_of(kCar, r), v::live(r), t) == v::StateSend::None);

	// he sits in it (engine off): its state at once, then nothing while nothing changes (no repeat without the engine)
	uint32_t now = 100000;
	r.sitter = true;
	r.handbrake = false;
	REQUIRE(c.step(v::state_of(kCar, r), true, now) == v::StateSend::Change);
	c.sent(v::state_of(kCar, r), now);
	for (uint32_t t = now; t < now + 10000; t += 50)
		CHECK(c.step(v::state_of(kCar, r), true, t) == v::StateSend::None);

	// the engine starts: a change, but no sooner than kStateMinIntervalMs after the last state
	now += 10000;
	c.sent(c.last(), now); // a state went at `now`
	r.engine = true;
	r.rpm = 50.f;
	CHECK(c.step(v::state_of(kCar, r), true, now + v::kStateMinIntervalMs - 1) == v::StateSend::None);
	REQUIRE(c.step(v::state_of(kCar, r), true, now + v::kStateMinIntervalMs) == v::StateSend::Change);
	now += v::kStateMinIntervalMs;
	c.sent(v::state_of(kCar, r), now);
	// the rpm alone: only at the repeat, every kStateRepeatMs (2 Hz)
	uint32_t sends = 0;
	for (uint32_t t = now + 1; t <= now + 10000; t += 16)
	{
		r.rpm = 50.f + float(t % 500); // revving all the time
		const v::StateSend s = c.step(v::state_of(kCar, r), true, t);
		CHECK(s != v::StateSend::Change);
		if (s == v::StateSend::Repeat)
		{
			++sends;
			c.sent(v::state_of(kCar, r), t);
		}
	}
	CHECK(sends >= 19 && sends <= 20); // 10 s at 2 Hz
	CHECK_EQ(1000u / v::kStateRepeatMs, 2u);

	// he gets out and stops the engine: the last state (engine off) goes, then silence however long
	now += 20000;
	r.engine = false;
	r.sitter = false;
	r.handbrake = true;
	r.rpm = 0.f;
	REQUIRE(c.step(v::state_of(kCar, r), false, now) == v::StateSend::Change);
	c.sent(v::state_of(kCar, r), now);
	for (uint32_t t = now; t < now + 60000; t += 250)
		CHECK(c.step(v::state_of(kCar, r), false, t) == v::StateSend::None);
	// a car that was used and stands parked: a change (it smokes under fire) still goes, its copies show the last word
	now += 60000;
	r.damage = 1;
	r.health = 0.6f;
	CHECK(c.step(v::state_of(kCar, r), false, now) == v::StateSend::Change);
}

TEST(vehicle_state_cadence_bounds_a_car_under_fire)
{
	// every bullet changes the health: at most one state per kStateMinIntervalMs, the newest one
	v::StateCadence c;
	v::CarReading r = driving(300.f);
	c.sent(v::state_of(kCar, r), 0);
	uint32_t sends = 0;
	for (uint32_t t = 1; t <= 10000; t += 10)
	{
		r.health -= 0.0005f;
		if (c.step(v::state_of(kCar, r), true, t) != v::StateSend::None)
		{
			++sends;
			c.sent(v::state_of(kCar, r), t);
		}
	}
	CHECK(sends <= 10000 / v::kStateMinIntervalMs);
	CHECK(sends >= 10000 / v::kStateMinIntervalMs / 2);
}

// ---------------------------------------------------------------- a copy

TEST(vehicle_state_copy_plays_the_stock_calls)
{
	v::CopyTrack c;
	v::CopyFacts f;
	v::StateMsg m = v::state_of(kCar, driving(300.f));
	// engine on, the copy's off: StartEngine; lights off: TurnOff (idempotent)
	v::CopyPlan p = c.apply(m, f, 0);
	CHECK(p.start && !p.stop);
	CHECK_EQ(p.lights, int8_t(-1));
	CHECK_EQ(p.damage_from, uint8_t(0));
	CHECK_EQ(p.damage_to, uint8_t(0));
	CHECK(!p.gear_sound); // the first gear a copy hears is no switch
	// running here already: nothing to start
	f.engine = true;
	p = c.apply(m, f, 500);
	CHECK(!p.start && !p.stop);
	// lights on
	m.flags = uint8_t(m.flags | v::kStateLights);
	CHECK_EQ(c.apply(m, f, 1000).lights, int8_t(1));
	// damage stage 2 on a copy that played none: stages 1 and 2 (Play1, Play2), as CDamagableItem::HitEffect plays them
	m.damage = 2;
	p = c.apply(m, f, 1500);
	CHECK_EQ(p.damage_from, uint8_t(0));
	CHECK_EQ(p.damage_to, uint8_t(2));
	// a copy whose own spawn played stage 2 already (RestoreEffect): nothing again; stages never go back
	f.damage = 2;
	p = c.apply(m, f, 2000);
	CHECK_EQ(p.damage_to, p.damage_from);
	m.damage = 1;
	p = c.apply(m, f, 2500);
	CHECK_EQ(p.damage_to, p.damage_from);
	// engine off: StopEngine (the stock stop sound and exhaust stop go through its AscCall)
	m.flags = uint8_t(m.flags & ~v::kStateEngine);
	p = c.apply(m, f, 3000);
	CHECK(p.stop && !p.start);
	// a wrecked copy: nothing switched on, the lights off (CarExplode)
	v::CopyFacts wreck;
	wreck.wrecked = true;
	m.flags = uint8_t(v::kStateEngine | v::kStateLights);
	p = c.apply(m, wreck, 3500);
	CHECK(!p.start);
	CHECK_EQ(p.lights, int8_t(-1));
}

TEST(vehicle_state_copy_sounds_a_change_of_gear_only)
{
	v::CopyTrack c;
	v::CopyFacts f;
	f.engine = true;
	v::StateMsg m = v::state_of(kCar, driving(300.f));
	auto gear = [&](int8_t g, uint32_t t) {
		m.gear = g;
		return c.apply(m, f, t).gear_sound;
	};
	CHECK(!gear(2, 0)); // the first word
	CHECK(!gear(2, 500)); // the repeat
	CHECK(gear(3, 1000)); // TransmissionUp
	CHECK(!gear(0, 1500)); // ReleaseForward: NeutralDrive, no switch sound in the stock
	CHECK(!gear(3, 2000)); // the same gear drives again
	CHECK(!gear(0, 2500));
	CHECK(gear(2, 3000)); // shifted down meanwhile: the switch is heard when it drives
	CHECK(gear(-1, 3500)); // DriveBack: Transmission(0)
	m.flags = 0; // the engine is off: the stock CCarSound::TransmissionSwitch plays nothing then
	CHECK(!gear(1, 4000));
}

TEST(vehicle_state_copy_engine_sound_follows_the_deciders_rpm)
{
	v::CopyTrack c;
	v::CopyFacts f;
	v::StateMsg m = v::state_of(kCar, driving(600.f)); // full rpm
	c.apply(m, f, 1000); // a start: from 0, as StartEngine sets m_current_rpm
	CHECK(std::fabs(c.rpm_fraction(1000) - 0.f) < 1e-4f);
	CHECK(std::fabs(c.rpm_fraction(1000 + v::kStateRepeatMs / 2) - 0.5f) < 0.01f);
	CHECK(std::fabs(c.rpm_fraction(1000 + v::kStateRepeatMs) - 1.f) < 1e-4f);
	CHECK(std::fabs(c.rpm_fraction(1000 + 10 * v::kStateRepeatMs) - 1.f) < 1e-4f); // holds the last word
	// the next state starts from what plays now
	f.engine = true;
	m.rpm = v::rpm_byte(300.f, 600.f);
	c.apply(m, f, 1000 + v::kStateRepeatMs / 2 + 10000);
	CHECK(std::fabs(c.rpm_fraction(1000 + v::kStateRepeatMs / 2 + 10000) - 1.f) < 1e-4f);
	CHECK(std::fabs(c.rpm_fraction(1000 + v::kStateRepeatMs + 10000 + v::kStateRepeatMs / 2) - v::fraction_of(m.rpm)) < 1e-4f);
	// the engine stops: the sound goes down to nothing
	m.flags = 0;
	c.apply(m, f, 50000);
	CHECK(std::fabs(c.rpm_fraction(50000 + v::kStateRepeatMs) - 0.f) < 1e-4f);
	// the pitch as CCarSound::UpdateDrive computes it from the rpm
	CHECK(std::fabs(v::sound_scale(300.f, 400.f) - (0.5f + 0.5f * 300.f / 400.f)) < 1e-6f);
	CHECK(std::fabs(v::sound_scale(300.f, 0.f) - 0.5f) < 1e-6f);
}

// ---------------------------------------------------------------- the stock hooks

TEST(vehicle_state_engine_sound_hook_in_car_sound)
{
	// CarSound.cpp UpdateDrive: the stock pitch line, then the copy's pitch from the decider's rpm, then the stock clamp. A copy's own
	// m_current_rpm is the physics step's (CCar::PhDataUpdate -> UpdatePower from the copy's fixed wheels), so the decider's rpm
	// reaches the sound only here; nothing writes the copy's m_current_rpm (its stall test would stop its engine).
	const std::string src = without_comments(project_file("engine/src/xrGame/CarSound.cpp"));
	const std::string drive = between(src, "void CCar::SCarSound::UpdateDrive()", "\n}\n");
	REQUIRE(!drive.empty());
	const size_t stock = drive.find("float scale = 0.5f + 0.5f * pcar->m_current_rpm / pcar->m_torque_rpm;");
	const size_t hook = drive.find("coop::vehicles::copy_sound_scale(pcar, scale);");
	const size_t clamp = drive.find("clamp(scale, 0.5f, 1.25f);");
	CHECK(stock != std::string::npos);
	CHECK(hook != std::string::npos && stock < hook);
	CHECK(clamp != std::string::npos && hook < clamp);
	CHECK(src.find("#include \"coop/coop_vehicles_state.h\"") != std::string::npos);
	// the hook keeps the stock formula (sound_scale)
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	CHECK(state.find("sound_scale(") != std::string::npos);
	CHECK(state.find("m_current_rpm =") == std::string::npos);
	CHECK(state.find("SetRPM(") == std::string::npos);
}

TEST(vehicle_state_car_has_the_state_friend)
{
	const std::string h = without_comments(project_file("engine/src/xrGame/Car.h"));
	const size_t driver = h.find("friend struct CoopCarDriver;");
	const size_t state = h.find("friend struct CoopCarState;");
	CHECK(driver != std::string::npos);
	CHECK(state != std::string::npos && driver < state);
	// CRLF kept: every line of the stock header ends with \r\n
	const std::string bytes = project_bytes("engine/src/xrGame/Car.h");
	CHECK(std::count(bytes.begin(), bytes.end(), '\n') == std::count(bytes.begin(), bytes.end(), '\r'));
	CHECK(bytes.find("friend struct CoopCarState;") != std::string::npos);
}

TEST(vehicle_state_copy_uses_the_stock_methods)
{
	// docs/VEHICLES.md section 5.6: StartEngine / StopEngine, the head lights, Play1 / Play2 as ApplyDamage, the switch sound as
	// Transmission asks it. ApplyDamage itself is not called on a copy: its stage 2 arms CDelayedActionFuse by the copy's health,
	// whose Update changes the copy's health (ChangeCondition) - the copy's health stays the stock's own.
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	const std::string apply = between(state, "static void apply(CCar& car, const coop::vehicles::StateMsg& m, const coop::vehicles::CopyPlan& p)", "\n\t}\n");
	REQUIRE(!apply.empty());
	const size_t fuel = apply.find("car.SetfFuel(");
	const size_t start = apply.find("car.StartEngine();");
	const size_t stop = apply.find("car.StopEngine();");
	const size_t on = apply.find("car.m_lights.TurnOnHeadLights();");
	const size_t off = apply.find("car.m_lights.TurnOffHeadLights();");
	const size_t play1 = apply.find("car.m_damage_particles.Play1(&car);");
	const size_t play2 = apply.find("car.m_damage_particles.Play2(&car);");
	const size_t gear = apply.find("car.AscCall(CCar::ascSndTransmission);");
	CHECK(fuel != std::string::npos && start != std::string::npos && fuel < start);
	CHECK(stop != std::string::npos && start < stop);
	CHECK(on != std::string::npos && off != std::string::npos && stop < on);
	CHECK(play1 != std::string::npos && play2 != std::string::npos && on < play1 && play1 < play2);
	CHECK(gear != std::string::npos && play2 < gear);
	CHECK(apply.find("ApplyDamage(") == std::string::npos);
	CHECK(apply.find("SetfHealth(") == std::string::npos && apply.find("ChangefHealth(") == std::string::npos);
	CHECK(apply.find("PPhysicsShell") == std::string::npos);
	// the stock pair of ApplyDamage: levels 1 and 2 play their particles (Car.cpp)
	const std::string car = without_comments(project_file("engine/src/xrGame/Car.cpp"));
	const std::string damage = between(car, "void CCar::ApplyDamage(u16 level)", "\n}\n");
	CHECK(damage.find("case 1: m_damage_particles.Play1(this);") != std::string::npos);
	CHECK(damage.find("m_damage_particles.Play2(this);") != std::string::npos);
	CHECK(damage.find("CDelayedActionFuse::CheckCondition(GetfHealth());") != std::string::npos);
	// StartEngine refuses an empty tank: the fuel is set first
	const std::string start_engine = between(car, "void CCar::StartEngine()", "\n}\n");
	CHECK(start_engine.find("if (m_fuel < EPS || b_engine_on) return;") != std::string::npos);
}

TEST(vehicle_state_dolls_sit_where_their_car_puts_them)
{
	// coop_players.cpp drive_avatar: the doll of a seated player is placed by the vehicles module before his snapshots are read
	// (players on another machine: F5-VEH-4 doll_frame; the decider's own proxy: F5-VEH-2 seated(), which doll_frame poses)
	const std::string players = without_comments(project_file("engine/src/xrGame/coop/coop_players.cpp"));
	const std::string drive = between(players, "bool drive_avatar(CAI_Stalker* avatar)", "\n}\n");
	REQUIRE(!drive.empty());
	const size_t doll = drive.find("if (vehicles::doll_frame(avatar))");
	const size_t seated = drive.find("if (vehicles::seated(avatar->ID()))");
	const size_t snapshots = drive.find("g_tracks.find(avatar->ID())");
	CHECK(doll != std::string::npos);
	CHECK(seated != std::string::npos && doll < seated);
	CHECK(snapshots != std::string::npos && seated < snapshots);
	CHECK(players.find("#include \"coop_vehicles_state.h\"") != std::string::npos);
	CHECK(project_bytes("engine/src/xrGame/coop/coop_players.cpp").find("if (vehicles::doll_frame(avatar))\r\n") != std::string::npos);

	// the pose: hidden as the stock Owner without driver_place, else the idle of the doll's own animations, else hidden
	CHECK(v::doll_pose(v::kDriverSeat, false, true) == v::DollPose::Hidden);
	CHECK(v::doll_pose(v::kDriverSeat, true, true) == v::DollPose::Idle);
	CHECK(v::doll_pose(v::kDriverSeat, true, false) == v::DollPose::Hidden);
	CHECK(v::doll_pose(1, false, true) == v::DollPose::Idle);
	CHECK(v::doll_pose(1, false, false) == v::DollPose::Hidden);
	// the idle the actor plays: idles[0] of SVehicleAnimCollection "steering_idle_<type>_<i>"
	CHECK_EQ(v::driver_idle_name(0), std::string("steering_idle_0_0"));
	CHECK_EQ(v::driver_idle_name(1), std::string("steering_idle_1_0"));
	const std::string anims = without_comments(project_file("engine/src/xrGame/ActorAnimation.cpp"));
	CHECK(anims.find("idles[i] = V->ID_Cycle_Safe(strconcat(sizeof(buf), buf, \"steering_idle_\", buff1, itoa(i, buff2, 10)));") !=
	      std::string::npos);
	const std::string actor = without_comments(project_file("engine/src/xrGame/Actor.cpp"));
	CHECK(actor.find("V->PlayCycle(anims.idles[0], FALSE);") != std::string::npos);
	// the doll plays it the same way, from its own kinematics (a missing motion: ID_Cycle_Safe, hidden)
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	CHECK(state.find("ID_Cycle_Safe(driver_idle_name(") != std::string::npos);
	CHECK(state.find("PlayCycle(idle, FALSE)") != std::string::npos);
	CHECK(state.find("seat_transform(where.car, where.seat, seat)") != std::string::npos); // F5-VEH-2's, F5-VEH-5 adds seats >= 1
	// a player's machine knows who sits where from the mirror of the decider's table (coop_vehicles_client.cpp)
	const std::string client = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp"));
	CHECK(between(client, "bool mirror_seat_of(u16 character, Seated& out)", "\n}\n").find("g_table.seat_of(character)") !=
	      std::string::npos);
}

// ---------------------------------------------------------------- who sends and who plays, per process kind

namespace
{
// state_frame's two halves (coop_vehicles_state.cpp): the decider's sends where this process leads its map, the copies' states are
// played where its objects are copies (VehicleState reaches state_on_state on a mirror only: coop_vehicles_client.cpp).
bool sends_state(const t::ModeCase& c) { return c.answers.leads_level; }
bool plays_state(const t::ModeCase& c) { return coop::has(c.answers.roles, coop::ProcessRole::Mirror); }

void check_frame_asks_only_these()
{
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	const std::string frame = between(state, "void state_frame()", "\n}\n");
	REQUIRE(!frame.empty());
	CHECK(frame.find("if (mode().leads_level())") != std::string::npos);
	CHECK(frame.find("if (is_mirror())") != std::string::npos);
	// the decider sends through the delivery of the mode, Reliable, as VehicleSeat goes
	CHECK(state.find("net::host_broadcast(Msg::VehicleState, w, Lane::Reliable);") != std::string::npos);
	CHECK(state.find("net::host_send(peer, Msg::VehicleState, w, Lane::Reliable);") != std::string::npos);
	const std::string client = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp"));
	const std::string handler = between(client, "e.on(Msg::VehicleState", "});");
	CHECK(handler.find("if (!is_mirror())") != std::string::npos && handler.find("state_on_state(r);") != std::string::npos);
}
} // namespace

TEST(vehicle_state_coop_the_host_sends_its_clients_play)
{
	// Co-op: the host decides (its own actor drives by the stock path, the clients' cars without an Owner): it sends for every car
	// with a sitter or a running engine, its own included; every client plays it on its copies; nobody else is in the game.
	const t::ModeCase& host = t::mode_case("coop_host");
	const t::ModeCase& client = t::mode_case("coop_client");
	CHECK(sends_state(host) && !plays_state(host)); // the host player's link ignores it: his cars are the real ones
	CHECK(!sends_state(client) && plays_state(client));
	// the host's own car: a sitter is the stock Owner (his actor), so his driving goes out
	v::CarReading own = driving(250.f);
	CHECK(v::live(own));
	v::StateCadence c;
	CHECK(c.step(v::state_of(kCar, own), v::live(own), 0) == v::StateSend::Change);
	check_frame_asks_only_these();
}

TEST(vehicle_state_server_the_map_server_sends_the_world_server_is_silent)
{
	// Server: the map server of the level decides and sends to the players of its level (Scope::Map); the world server has no map of
	// theirs and sends nothing; a player of a server world plays it; no session: nothing at all.
	const t::ModeCase& map = t::mode_case("map_server");
	const t::ModeCase& world = t::mode_case("world_server");
	const t::ModeCase& player = t::mode_case("server_client");
	const t::ModeCase& none = t::mode_case("none");
	CHECK(sends_state(map) && !plays_state(map));
	CHECK(!sends_state(world) && !plays_state(world));
	CHECK(!sends_state(player) && plays_state(player));
	CHECK(!sends_state(none) && !plays_state(none));
	CHECK(coop::scope_of(Msg::VehicleState) == coop::Scope::Map);
	CHECK(!coop::reaches_every_level(Msg::VehicleState));
	check_frame_asks_only_these();
}

// ---------------------------------------------------------------- rv_F5-VEH-3: a tap of a held key is not lost

namespace
{
// The driver's machine as coop_vehicles_client.cpp runs it: client_key (the sender's press / release, then the latch) and step_input
// (take, then the waiting releases).
struct Driver
{
	v::InputSender in;
	v::TapLatch tap;
	bool latch = true;

	void key(int key, bool pressed)
	{
		const uint16_t before = in.held();
		if (pressed)
			in.press(key);
		else
			in.release(key);
		if (!latch)
			return;
		const v::KeyRule* r = v::key_rule(key);
		if (!r || r->use != v::KeyUse::Held)
			return;
		if (pressed)
			tap.pressed(key, uint16_t(in.held() & ~before));
		else if (!tap.release_now(key, r->held))
			in.press(key);
	}

	bool next(uint32_t now, v::InputMsg& out)
	{
		if (!in.due(now))
			return false;
		out = in.take(now);
		for (int k : tap.taken())
			in.release(k);
		return true;
	}
};
} // namespace

TEST(vehicle_state_a_gear_tap_between_two_inputs_reaches_the_decider)
{
	for (int pass = 0; pass < 2; ++pass)
	{
		Driver d;
		d.latch = pass == 1;
		d.in.start(kCar, false);
		v::InputMsg m;
		REQUIRE(d.next(0, m)); // the first message at once
		// 10 FPS: the tap of the gear up key comes and goes inside one frame, before the next message may go (33 ms)
		d.key(k::kACCEL, true);
		d.key(k::kACCEL, false);
		uint32_t at = 100;
		while (!d.next(at, m) && at < 1000)
			at += 16;
		if (!d.latch)
		{
			// the bug of the review: nothing changed for the sender, the next message is the repeat, without the press
			CHECK_EQ(at, 100u + 7u * 16u); // the first frame at or after kInputRepeatMs
			CHECK(!(m.held & v::kHeldTransUp));
			continue;
		}
		CHECK_EQ(at, 100u); // at once (a change) ...
		CHECK(m.held & v::kHeldTransUp); // ... with its press ...
		v::InputMsg after;
		CHECK(!d.next(110, after)); // ... no message sooner than kInputMinIntervalMs ...
		REQUIRE(d.next(100 + v::kInputMinIntervalMs, after)); // ... and the release in the next one
		CHECK(!(after.held & v::kHeldTransUp));
		CHECK(v::seq_newer(after.seq, m.seq));
	}
}

TEST(vehicle_state_tap_latch_keeps_held_keys_held)
{
	Driver d;
	d.in.start(kCar, true);
	v::InputMsg m;
	REQUIRE(d.next(0, m));
	// a key held over a message: its release goes at once, nothing waits
	d.key(k::kFWD, true);
	REQUIRE(d.next(40, m));
	CHECK(m.held & v::kHeldForward);
	d.key(k::kFWD, false);
	CHECK_EQ(d.tap.waiting(), size_t(0));
	REQUIRE(d.next(80, m));
	CHECK(!(m.held & v::kHeldForward));
	// tap, then down again inside one message: it stays down (two taps inside one message are one press)
	d.key(k::kWPN_FIRE, true);
	d.key(k::kWPN_FIRE, false);
	d.key(k::kWPN_FIRE, true);
	REQUIRE(d.next(200, m));
	CHECK(m.held & v::kHeldFire);
	REQUIRE(d.next(400, m)); // the repeat
	CHECK(m.held & v::kHeldFire); // still held: no release was waiting
	d.key(k::kWPN_FIRE, false);
	REQUIRE(d.next(440, m));
	CHECK(!(m.held & v::kHeldFire));
	// the counters and the weapon switch are no held keys: the latch leaves them alone
	d.key(k::kDETECTOR, true);
	d.key(k::kDETECTOR, false);
	CHECK_EQ(d.tap.waiting(), size_t(0));
	REQUIRE(d.next(480, m));
	CHECK_EQ(v::edge_count(m.edges, v::Edge::Engine), uint8_t(1));
	// a tap of the brake and both gears at once: all three go out, then all three are released
	d.key(k::kJUMP, true);
	d.key(k::kACCEL, true);
	d.key(k::kCROUCH, true);
	d.key(k::kJUMP, false);
	d.key(k::kACCEL, false);
	d.key(k::kCROUCH, false);
	REQUIRE(d.next(600, m));
	CHECK((m.held & (v::kHeldBrake | v::kHeldTransUp | v::kHeldTransDown)) == (v::kHeldBrake | v::kHeldTransUp | v::kHeldTransDown));
	REQUIRE(d.next(640, m));
	CHECK((m.held & (v::kHeldBrake | v::kHeldTransUp | v::kHeldTransDown)) == 0);
	d.tap.reset();
	CHECK_EQ(d.tap.waiting(), size_t(0));
	CHECK_EQ(d.tap.unsent(), uint16_t(0));
}

TEST(vehicle_state_client_items_of_the_review)
{
	const std::string client = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_client.cpp"));
	// (a) released by the decider: no VehicleInput while the stock exit waits for room (the decider would drop it as NotDriving)
	const std::string leave = between(client, "void step_leave(CActor* actor, u32 now)", "\n}\n");
	REQUIRE(!leave.empty());
	const size_t due = leave.find("if (!g_mine.leave_due)");
	const size_t stop = leave.find("g_input.stop();");
	const size_t detach = leave.find("actor->detach_Vehicle(true);");
	CHECK(due != std::string::npos && stop != std::string::npos && due < stop);
	CHECK(detach != std::string::npos && stop < detach);
	// (b) the tap latch: after the sender's press / release in client_key, and the waiting releases after a message is taken
	const std::string key = between(client, "bool client_key(CCar* car, int key, bool pressed)", "\n}\n");
	const size_t took = key.find("const bool took = pressed ? g_input.press(key) : g_input.release(key);");
	const size_t latch = key.find("latch_tap(key, pressed, before);");
	CHECK(key.find("const u16 before = g_input.held();") < took);
	CHECK(took != std::string::npos && latch != std::string::npos && took < latch);
	const std::string input = between(client, "void step_input(u32 now)", "\n}\n");
	const size_t take = input.find("g_input.take(now);");
	const size_t released = input.find("for (int held_key : g_tap.taken())");
	CHECK(take != std::string::npos && released != std::string::npos && take < released);
	const std::string attach = between(client, "void step_attach(CActor* actor, u32 now)", "\n}\n");
	CHECK(attach.find("g_input.start(") < attach.find("g_tap.reset();"));
	CHECK(attach.find("g_tap.reset();") != std::string::npos);
	// (c) the line for a request with no answer is the same in both modes: no "map server" a co-op player never has
	CHECK(client.find("\"st_coop_f5_vehicles_no_answer\"") == std::string::npos);
	CHECK(client.find("\"st_coop_f5_vehstate_no_answer\"") != std::string::npos);
	for (const char* lang : {"eng", "rus"})
	{
		const std::string xml = project_bytes(std::string("gamedata/configs/text/") + lang + "/st_coop_f5_vehstate.xml");
		REQUIRE(!xml.empty());
		const std::string head = "<?xml version=\"1.0\" encoding=\"windows-1251\"?>";
		CHECK(xml.compare(0, head.size(), head) == 0);
		CHECK(xml.find("<string id=\"st_coop_f5_vehstate_no_answer\">") != std::string::npos);
		std::string no_crlf = xml;
		for (size_t at = no_crlf.find("\r\n"); at != std::string::npos; at = no_crlf.find("\r\n", at))
			no_crlf.erase(at, 2);
		CHECK(no_crlf.find('\n') == std::string::npos); // CRLF only
		const std::string text = between(xml, "<string id=\"st_coop_f5_vehstate_no_answer\">", "</string>");
		CHECK(!text.empty());
		CHECK(text.find("server") == std::string::npos && text.find("Server") == std::string::npos);
		CHECK(text.find("\xF1\xE5\xF0\xE2\xE5\xF0") == std::string::npos); // "сервер" in cp1251
	}
}

// ---------------------------------------------------------------- the session's rate rows of VehicleReq and VehicleInput

namespace
{
// The host's token bucket (coop_session.cpp within_rate): `burst` in a row, then one more every `refill_ms`. The arrivals are host
// times in ms; the result is how many it drops.
uint32_t bucket_drops(const coop::limits::RateRule& rule, std::vector<uint64_t> arrivals)
{
	std::sort(arrivals.begin(), arrivals.end());
	double tokens = double(rule.burst);
	uint64_t at = arrivals.empty() ? 0 : arrivals.front();
	uint32_t dropped = 0;
	for (uint64_t when : arrivals)
	{
		if (when > at)
		{
			tokens = std::min(double(rule.burst), tokens + double(when - at) / double(rule.refill_ms));
			at = when;
		}
		if (tokens >= 1.)
			tokens -= 1.;
		else
			++dropped;
	}
	return dropped;
}

// The driver's machine at its fastest (InputSender::due: something changes every frame at 60 FPS, so a message every
// kInputMinIntervalMs; aim of a turret moving all the time), `seconds` long; a lag spike holds what is sent in [stall, stall + len)
// and delivers it together.
std::vector<uint64_t> fastest_driver(uint32_t seconds, uint64_t stall, uint64_t len)
{
	v::InputSender in;
	in.start(kCar, true);
	std::vector<uint64_t> out;
	float yaw = 0.f;
	for (uint32_t now = 0; now < seconds * 1000; now += 16)
	{
		yaw += 0.01f;
		in.set_aim(yaw, 0.1f);
		if (!in.due(now))
			continue;
		in.take(now);
		out.push_back(now >= stall && now < stall + len ? stall + len : now);
	}
	return out;
}

// The seat requests at their fastest (RequestTrack: one at a time, the answer after `rtt` ms, the next no sooner than
// kRequestMinIntervalMs after the last).
std::vector<uint64_t> fastest_requests(uint32_t seconds, uint32_t rtt)
{
	v::RequestTrack req;
	std::vector<uint64_t> out;
	uint64_t answer_at = 0;
	for (uint32_t now = 0; now < seconds * 1000; now += 16)
	{
		if (req.pending() && now >= answer_at)
		{
			v::SeatMsg refused = v::SeatMsg::refused(kCar, v::kAnySeat, 7, v::Refusal::TooSoon);
			req.answer(refused, 7);
		}
		if (!req.may_send(now))
			continue;
		req.sent(v::ReqOp::Enter, kCar, now);
		answer_at = now + rtt;
		out.push_back(now + rtt / 2);
	}
	return out;
}

void host_and_join(t::Node& host, t::Node& client, uint16_t port)
{
	std::string err;
	host.cfg.mode = coop::SessionMode::Coop;
	REQUIRE(host.host(&err));
	REQUIRE(client.connect(port, &err));
	REQUIRE(t::pump_until({&host.s, &client.s}, 5000, [&] { return client.s.is_active() && host.s.peers().size() == 1; }));
	REQUIRE(t::pump_until({&host.s, &client.s}, 5000, [&] { return client.s.peers().size() == 1; }));
}

// The burst of the row passes, three more are dropped (counted, the sender kept), one passes a whole refill later: the game's table
// on a real host session.
void check_row_on_a_session(Msg type, uint16_t port)
{
	const coop::limits::RateRule* rule = coop::limits::client_rule(type);
	REQUIRE(rule != nullptr);
	t::Node host("Boss", port), a("Alice", port);
	for (const coop::limits::RateRule& r : coop::limits::kClientRateRules)
		host.s.limit_rate(r.type, r.burst, r.refill_ms);
	size_t handled = 0;
	host.s.on(type, [&](coop::PeerId, coop::Reader&) { ++handled; });
	host_and_join(host, a, port);
	uint64_t host_ms = t::now_ms();
	uint64_t sent = 0;
	auto send_at = [&](uint64_t when, uint32_t n) {
		for (uint32_t i = 0; i < n; ++i)
			a.s.send(coop::kHostPeer, coop::Lane::Reliable, type, coop::Writer());
		sent += n;
		const uint64_t start = t::now_ms();
		while (handled + host.s.stats(uint16_t(type)).rate_dropped < sent)
		{
			REQUIRE(t::now_ms() - start < 5000);
			a.s.update(t::now_ms());
			host.s.update(when);
			std::this_thread::yield();
		}
	};
	send_at(host_ms, rule->burst + 3);
	CHECK_EQ(handled, size_t(rule->burst));
	CHECK_EQ(host.s.stats(uint16_t(type)).rate_dropped, uint64_t(3));
	CHECK(host.logged(std::string("rate limit: ") + coop::msg_name(type)));
	host_ms += rule->refill_ms;
	send_at(host_ms, 1);
	CHECK_EQ(handled, size_t(rule->burst) + 1);
	CHECK(host.left.empty());
}
} // namespace

TEST(vehicle_state_rate_rows_are_twice_the_honest_rate)
{
	const coop::limits::RateRule* req = coop::limits::client_rule(Msg::VehicleReq);
	const coop::limits::RateRule* input = coop::limits::client_rule(Msg::VehicleInput);
	REQUIRE(req != nullptr && input != nullptr);
	CHECK_EQ(req->burst, 8u);
	CHECK_EQ(req->refill_ms, 125u);
	CHECK_EQ(input->burst, 24u);
	CHECK_EQ(input->refill_ms, 16u);
	// VehicleReq: honest at most one per kRequestMinIntervalMs (RequestTrack): the row is twice that
	CHECK_EQ(req->refill_ms * 2, v::kRequestMinIntervalMs);
	// VehicleInput: honest at most one per kInputMinIntervalMs (InputSender::due): the row is about twice that (62.5 vs 30.3 a second),
	// above the decider's own gate (RateGate 40 a second, burst kInputBurst: the trust check veh_input_rate writes a client between 40
	// and 62 a second before the session drops anything), its burst twice the gate's
	const double honest = 1000.0 / v::kInputMinIntervalMs;
	const double row = 1000.0 / input->refill_ms;
	CHECK(row >= 1.9 * honest && row <= 2.2 * honest);
	CHECK(row > double(v::kInputRatePerSec));
	CHECK_EQ(input->burst, 2 * v::kInputBurst);

	// the fastest honest driver for a minute, with a lag spike of 0.8 s delivered at once: nothing dropped
	CHECK_EQ(bucket_drops(*input, fastest_driver(60, 20000, 800)), 0u);
	// the fastest honest seat requests for a minute (a refusal comes back in 40 ms each time): nothing dropped
	const std::vector<uint64_t> asks = fastest_requests(60, 40);
	CHECK(asks.size() >= 200); // ~4 a second
	CHECK_EQ(bucket_drops(*req, asks), 0u);
	// three times the honest top rate is cut: a modified client cannot flood the decider (in Server the world server tunnels it)
	std::vector<uint64_t> flood;
	for (uint64_t t = 0; t < 10000; t += 11)
		flood.push_back(t);
	CHECK(bucket_drops(*input, flood) > 0);
	flood.clear();
	for (uint64_t t = 0; t < 10000; t += 83)
		flood.push_back(t);
	CHECK(bucket_drops(*req, flood) > 0);
}

TEST(vehicle_state_rate_row_vehicle_req_on_a_session) { check_row_on_a_session(Msg::VehicleReq, t::port(39410)); }

TEST(vehicle_state_rate_row_vehicle_input_on_a_session) { check_row_on_a_session(Msg::VehicleInput, t::port(39411)); }

// ---------------------------------------------------------------- the link gap

TEST(vehicle_state_gives_the_bodies_the_hubs_call)
{
	// coop_sync.cpp calls state_frame, coop_vehicles_client.cpp calls state_on_state: F5-VEH-4's bodies (integrate.md section 5)
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	CHECK(state.find("void state_frame()\n{") != std::string::npos);
	CHECK(state.find("void state_on_state(Reader& payload)\n{") != std::string::npos);
	CHECK(state.find("bool doll_frame(CAI_Stalker* doll)\n{") != std::string::npos);
	CHECK(state.find("void copy_sound_scale(CCar* car, float& scale)\n{") != std::string::npos);
	CHECK(state.find("void state_print_status()\n{") != std::string::npos);
	const char* const core = "// Ядро: без проверок режима (docs/MODES.md)";
	CHECK(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp").compare(0, std::strlen(core), core) == 0);
	// VehicleState is read with every bound (coop_vehicle_rules.h read) before anything is touched
	const std::string on = between(state, "void state_on_state(Reader& payload)", "\n}\n");
	CHECK(on.find("if (!read(payload, m))") != std::string::npos);
}

// Note 3 of F5-REV-1 (should-fix of rv_F5-VEH-4, both modes): the posed dolls belong to one world. After a load or a level change an id
// of the old world can name another stalker: release_doll would show it and turn its collision back on. A new world forgets the dolls
// without touching any object, before the sweep and before a doll is posed.
TEST(vehicle_state_dolls_forget_an_old_world)
{
	const std::string state = without_comments(project_file("engine/src/xrGame/coop/coop_vehicles_state.cpp"));
	CHECK(state.find("u32 g_dolls_world = 0;") != std::string::npos);
	const std::string forget = between(state, "void dolls_world()", "\n}\n");
	REQUIRE(!forget.empty());
	const size_t gen = forget.find("const u32 world = join::world_generation();");
	const size_t same = forget.find("if (world == g_dolls_world)");
	const size_t clear = forget.find("g_dolls.clear();");
	const size_t keep = forget.find("g_dolls_world = world;");
	CHECK(gen != std::string::npos && same != std::string::npos && clear != std::string::npos && keep != std::string::npos);
	CHECK(gen < same && same < clear && clear < keep);
	CHECK(forget.find("release_doll") == std::string::npos); // the old world's objects are not this world's: nothing is touched

	const std::string sweep = between(state, "void dolls_sweep()", "\n}\n");
	const size_t sweep_world = sweep.find("dolls_world();");
	const size_t sweep_loop = sweep.find("for (auto it = g_dolls.begin(); it != g_dolls.end();)");
	CHECK(sweep_world != std::string::npos && sweep_loop != std::string::npos && sweep_world < sweep_loop);

	const std::string frame = between(state, "bool doll_frame(CAI_Stalker* doll)", "\n}\n");
	const size_t guard = frame.find("if (!doll || !mgr().active() || !world_up())");
	const size_t frame_world = frame.find("dolls_world();");
	const size_t find = frame.find("auto it = g_dolls.find(doll->ID());");
	CHECK(guard != std::string::npos && frame_world != std::string::npos && find != std::string::npos);
	CHECK(guard < frame_world && frame_world < find);
}
