// Ядро: без проверок режима (docs/MODES.md)
// Anomaly Coop unit tests: the decider of a player's car (F5-VEH-2, docs/VEHICLES.md §7-§10) - coop_vehicle_drive_rules.h.
// The driver's held keys and press counters become the stock calls of CarInput.cpp in a fixed order; what CCar::attach_Actor /
// detach_Actor do to a car is kept or dropped line by line; the checks of the client's word count and log as coop_trust does;
// releases, exit points, the seat table for a player who comes to the map, the coop_status counters. One set of rules for
// both modes: the decider is the co-op host or the map server of the player's level, the rules do not know which.
#include "test_util.h"

#include <algorithm>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#include "coop_vehicle_drive_rules.h"

namespace v = coop::vehicles;

namespace
{
const char* drive_key_name(v::DriveKey k)
{
	switch (k)
	{
	case v::DriveKey::Forward: return "forward";
	case v::DriveKey::Back: return "back";
	case v::DriveKey::Left: return "left";
	case v::DriveKey::Right: return "right";
	case v::DriveKey::Brake: return "brake";
	case v::DriveKey::TransUp: return "trans_up";
	case v::DriveKey::TransDown: return "trans_down";
	case v::DriveKey::Fire: return "fire";
	case v::DriveKey::WeaponSwitch: return "weapon_switch";
	case v::DriveKey::Engine: return "engine";
	case v::DriveKey::Lights: return "lights";
	case v::DriveKey::Aim: return "aim";
	}
	return "?";
}

// "release forward, press back, aim": what plan_drive calls, readable in a failed CHECK_EQ.
std::string calls_text(const std::vector<v::DriveCall>& calls)
{
	std::string out;
	for (const v::DriveCall& c : calls)
		out += (out.empty() ? "" : ", ") + std::string(c.key == v::DriveKey::Aim ? "" : (c.press ? "press " : "release ")) +
		    drive_key_name(c.key);
	return out;
}

v::InputStep step(uint16_t before, uint16_t held, uint8_t engine = 0, uint8_t lights = 0)
{
	v::InputStep s;
	s.drop = v::InputDrop::None;
	s.before = before;
	s.held = held;
	s.engine_toggles = engine;
	s.lights_toggles = lights;
	return s;
}

std::string plan(const v::InputStep& s, bool has_weapon = false, bool weapon_active = false)
{
	return calls_text(v::plan_drive(s, has_weapon, weapon_active));
}

v::InputMsg input(uint16_t car, uint8_t seq, uint16_t held, uint8_t edges = 0)
{
	v::InputMsg m;
	m.car = car;
	m.seq = seq;
	m.held = held;
	m.edges = edges;
	return m;
}
} // namespace

// ---------------------------------------------------------------------------------------------- keys -> stock calls

TEST(vehicle_drive_each_key_is_its_stock_call)
{
	// CarInput.cpp OnKeyboardPress / OnKeyboardRelease: one press and one release per key, nothing for a key held on.
	struct Key
	{
		uint16_t bit;
		const char* name;
	};
	const Key keys[] = {{v::kHeldForward, "forward"}, {v::kHeldBack, "back"}, {v::kHeldLeft, "left"}, {v::kHeldRight, "right"},
	    {v::kHeldBrake, "brake"}, {v::kHeldTransUp, "trans_up"}, {v::kHeldTransDown, "trans_down"}, {v::kHeldFire, "fire"}};
	for (const Key& k : keys)
	{
		CHECK_EQ(plan(step(0, k.bit)), "press " + std::string(k.name));
		CHECK_EQ(plan(step(k.bit, 0)), "release " + std::string(k.name));
		CHECK_EQ(plan(step(k.bit, k.bit)), std::string());
	}
	// a key the driver does not hold is never released: ReleaseForward is not a no-op (Car.cpp:1476-1489)
	CHECK_EQ(plan(step(v::kHeldBack, v::kHeldBack)), std::string());
}

TEST(vehicle_drive_two_edges_in_one_packet)
{
	// forward let go and back pressed in one message: the release first, as a keyboard does it
	CHECK_EQ(plan(step(v::kHeldForward, v::kHeldBack)), "release forward, press back");
	// two presses: in the order of the cases of OnKeyboardPress (kR_STRAFE before kL_STRAFE, kJUMP last of the keys)
	CHECK_EQ(plan(step(0, v::kHeldBrake | v::kHeldLeft | v::kHeldForward)), "press forward, press left, press brake");
	CHECK_EQ(plan(step(0, v::kHeldLeft | v::kHeldRight)), "press right, press left");
	CHECK_EQ(plan(step(0, v::kHeldTransDown | v::kHeldTransUp | v::kHeldBack)), "press trans_up, press trans_down, press back");
	// two releases: in the order of the cases of OnKeyboardRelease (kACCEL, kFWD, kBACK, kL_STRAFE, kR_STRAFE, kJUMP, kWPN_FIRE)
	const uint16_t all = v::kHeldForward | v::kHeldBack | v::kHeldLeft | v::kHeldRight | v::kHeldBrake | v::kHeldFire |
	    v::kHeldTransUp | v::kHeldTransDown;
	CHECK_EQ(plan(step(all, 0)),
	    "release trans_up, release forward, release back, release left, release right, release brake, release fire, release trans_down");
	// steering swapped while the throttle stays
	CHECK_EQ(plan(step(v::kHeldForward | v::kHeldLeft, v::kHeldForward | v::kHeldRight)), "release left, press right");
}

TEST(vehicle_drive_two_edges_through_the_input_track)
{
	// The decider's real path: InputTrack::accept gives the step, plan_drive its calls.
	v::InputTrack t;
	t.start(77, 1000);
	v::InputStep s = t.accept(input(77, 1, v::kHeldForward), 1010);
	CHECK_EQ(plan(s), "press forward");
	s = t.accept(input(77, 2, v::kHeldBack | v::kHeldRight), 1040);
	CHECK_EQ(plan(s), "release forward, press back, press right");
	s = t.accept(input(77, 2, v::kHeldBack), 1050); // a repeat of seq 2: dropped, no call
	CHECK(s.drop == v::InputDrop::Old);
	CHECK_EQ(plan(s), std::string());
	s = t.accept(input(78, 3, 0), 1060); // another car
	CHECK(s.drop == v::InputDrop::WrongCar);
	CHECK_EQ(plan(s), std::string());
}

TEST(vehicle_drive_stale_releases_every_key_and_brakes)
{
	v::InputTrack t;
	t.start(5, 0);
	v::InputStep s = t.accept(input(5, 1, v::kHeldForward | v::kHeldLeft | v::kHeldFire | v::kHeldWeapon), 100);
	CHECK(s.applied());
	CHECK_EQ(plan(t.tick(599)), std::string()); // 499 ms: not stale yet
	s = t.tick(600);
	CHECK(s.stale);
	// every Release* of a held key, then PressBreaks; the weapon switch stays (its release does nothing in stock)
	CHECK_EQ(plan(s, true, true), "release forward, release left, release fire, press brake");
	CHECK_EQ(plan(t.tick(5000), true, true), std::string()); // once per gap
	// the first input after the gap is taken whatever its seq: the hand brake goes, his keys come back
	s = t.accept(input(5, 40, v::kHeldForward | v::kHeldWeapon), 5100);
	CHECK(s.resync);
	CHECK_EQ(plan(s, true, true), "release brake, press forward");
	// a driver who held the hand brake already: the stale step presses nothing again
	v::InputTrack b;
	b.start(6, 0);
	b.accept(input(6, 1, v::kHeldBrake | v::kHeldBack), 10);
	CHECK_EQ(plan(b.tick(510)), "release back");
}

TEST(vehicle_drive_engine_toggle_while_moving)
{
	// SwitchEngine per press (kDETECTOR), the throttle held on: the engine stops under the held key, nothing else is called
	CHECK_EQ(plan(step(v::kHeldForward, v::kHeldForward, 1)), "press engine");
	CHECK_EQ(plan(step(v::kHeldForward, v::kHeldForward, 2)), "press engine, press engine");
	// engine on and forward in one message: the engine first, else PressForward drives nothing (Car.cpp:1193)
	CHECK_EQ(plan(step(0, v::kHeldForward, 1)), "press engine, press forward");
	// forward let go and the engine stopped in one message: the release first
	CHECK_EQ(plan(step(v::kHeldForward, 0, 1)), "release forward, press engine");
	// the lights after the engine, three presses at most (2-bit counters)
	CHECK_EQ(plan(step(0, 0, 1, 3)), "press engine, press lights, press lights, press lights");
	// through the track: the counters of two messages
	v::InputTrack t;
	t.start(9, 0);
	uint8_t edges = v::bump_edge(0, v::Edge::Engine);
	v::InputStep s = t.accept(input(9, 1, v::kHeldForward, edges), 10);
	CHECK_EQ(plan(s), "press engine, press forward");
	edges = v::bump_edge(v::bump_edge(edges, v::Edge::Engine), v::Edge::Lights);
	s = t.accept(input(9, 2, v::kHeldForward, edges), 40);
	CHECK_EQ(plan(s), "press engine, press lights");
	s = t.accept(input(9, 3, v::kHeldForward, edges), 70); // the same counters again: nothing more
	CHECK_EQ(plan(s), std::string());
}

TEST(vehicle_drive_weapon_switch_fire_and_aim)
{
	// the switch bit turns the weapon on when it is off (kWPN_FUNC: Action(eWpnActivate, !IsActive()))
	CHECK_EQ(plan(step(0, v::kHeldWeapon), true, false), "press weapon_switch");
	CHECK_EQ(plan(step(v::kHeldWeapon, 0), true, true), "press weapon_switch");
	// already in the bit's position (a script turned it): no press, it would turn it back
	CHECK_EQ(plan(step(0, v::kHeldWeapon), true, true), std::string());
	CHECK_EQ(plan(step(v::kHeldWeapon, 0), true, false), std::string());
	// no edge of the bit: never pressed, whatever the weapon is now
	CHECK_EQ(plan(step(v::kHeldWeapon, v::kHeldWeapon), true, false), std::string());
	// no weapon: stock kWPN_FUNC does nothing, so nothing is pressed
	CHECK_EQ(plan(step(0, v::kHeldWeapon), false, false), std::string());
	// on and firing in one message: the switch first (its case is before kWPN_FIRE)
	CHECK_EQ(plan(step(0, v::kHeldWeapon | v::kHeldFire | v::kHeldForward), true, false),
	    "press forward, press weapon_switch, press fire");
	// the aim comes last and only with a weapon (SetParam eWpnDesiredDir)
	v::InputStep s = step(v::kHeldWeapon, v::kHeldWeapon | v::kHeldFire);
	s.aim = true;
	CHECK_EQ(plan(s, true, true), "press fire, aim");
	CHECK_EQ(plan(s, false, false), "press fire"); // stock OnKeyboardPress checks HasWeapon itself
	// a dropped or quiet step calls nothing
	v::InputStep q;
	CHECK_EQ(plan(q, true, true), std::string());
}

// ---------------------------------------------------------------------------------------------- attach / detach lines

TEST(vehicle_drive_attach_detach_keep_the_stock_order)
{
	// The kept lines of CCar::attach_Actor / detach_Actor, in the order of Car.cpp, exactly these (docs/VEHICLES.md §8).
	std::vector<v::CarStep> attach, detach;
	uint16_t last = 0;
	for (const v::StockLine& l : v::kAttachLines)
	{
		CHECK(l.line > last); // Car.cpp order
		last = l.line;
		CHECK(l.code && *l.code);
		CHECK(l.why != nullptr);
		if (l.step != v::CarStep::None)
			attach.push_back(l.step);
		else
			CHECK(*l.why); // a dropped line says why
	}
	last = 0;
	for (const v::StockLine& l : v::kDetachLines)
	{
		CHECK(l.line > last);
		last = l.line;
		if (l.step != v::CarStep::None)
			detach.push_back(l.step);
		else
			CHECK(*l.why);
	}
	CHECK(attach == (std::vector<v::CarStep>{v::CarStep::EnablePhysics, v::CarStep::AddObstacleCallback,
	                    v::CarStep::ProcessingActivate, v::CarStep::ReleaseHandBreak}));
	CHECK(detach == (std::vector<v::CarStep>{v::CarStep::RemoveObstacleCallback, v::CarStep::NeutralDrive, v::CarStep::Unclutch,
	                    v::CarStep::ResetKeys, v::CarStep::RpmToMin, v::CarStep::HandBreak, v::CarStep::ProcessingDeactivate}));
	// the Owner is never set or cleared for a client driver
	for (const v::StockLine& l : v::kAttachLines)
		if (l.line == 792)
			CHECK(l.step == v::CarStep::None);
	for (const v::StockLine& l : v::kDetachLines)
		if (l.line == 766)
			CHECK(l.step == v::CarStep::None);
}

// ---------------------------------------------------------------------------------------------- trust

TEST(vehicle_drive_trust_modes_count_and_log_as_coop_trust)
{
	v::TrustMode m = v::TrustMode::Off;
	CHECK(v::parse_trust_mode("log", m) && m == v::TrustMode::Log);
	CHECK(v::parse_trust_mode("refuse", m) && m == v::TrustMode::Refuse);
	CHECK(v::parse_trust_mode("off", m) && m == v::TrustMode::Off);
	CHECK(!v::parse_trust_mode("Refuse", m) && m == v::TrustMode::Off); // anything else keeps what was there
	CHECK(!v::parse_trust_mode(nullptr, m));
	CHECK_EQ(std::string(v::trust_mode_name(v::TrustMode::Log)), std::string("log"));

	// log: a failure is counted and let through
	v::TrustCount c;
	v::TrustResult r = v::trust_pass(v::TrustMode::Log, true, c);
	CHECK(r.pass && !r.log);
	r = v::trust_pass(v::TrustMode::Log, false, c);
	CHECK(r.pass && r.log);
	CHECK_EQ(c.checked, 2u);
	CHECK_EQ(c.failed, 1u);
	CHECK_EQ(c.refused, 0u);
	// refuse: refused and counted
	v::TrustCount d;
	r = v::trust_pass(v::TrustMode::Refuse, false, d);
	CHECK(!r.pass && r.log);
	CHECK_EQ(d.refused, 1u);
	r = v::trust_pass(v::TrustMode::Refuse, true, d);
	CHECK(r.pass);
	// off: nothing runs, nothing is counted
	v::TrustCount e;
	r = v::trust_pass(v::TrustMode::Off, false, e);
	CHECK(r.pass && !r.log);
	CHECK_EQ(e.checked, 0u);
	// the first 8 failures are written, then every 64th
	v::TrustCount f;
	std::vector<uint32_t> logged;
	for (uint32_t i = 1; i <= 130; ++i)
		if (v::trust_pass(v::TrustMode::Log, false, f).log)
			logged.push_back(i);
	CHECK(logged == (std::vector<uint32_t>{1, 2, 3, 4, 5, 6, 7, 8, 64, 128}));
	// the names are config keys: permanent
	CHECK_EQ(std::string(v::kTrustEnterDoor), std::string("veh_enter_door"));
	CHECK_EQ(std::string(v::kTrustSection), std::string("coop_trust"));
}

TEST(vehicle_drive_rules_first_then_trust)
{
	// enter_rules: what the game rules alone refuse; a request that is only too soon or too far passes them (the trust checks
	// run after, each with its own coop_trust line)
	v::EnterFacts f;
	f.car_known = true;
	f.supported = true;
	f.alive = true;
	f.seats = 1;
	f.seat = v::kAnySeat;
	f.seat_free = true;
	f.distance = 50.f;
	f.since_last_ms = 10;
	CHECK(v::enter(f) == v::Refusal::TooSoon);
	CHECK(v::enter_rules(f) == v::Refusal::None);
	f.enter_locked = true;
	CHECK(v::enter_rules(f) == v::Refusal::Locked);
	f.enter_locked = false;
	f.wounded = true;
	CHECK(v::enter_rules(f) == v::Refusal::Wounded);

	v::ExitFacts x;
	x.seated = true;
	x.since_last_ms = 0;
	CHECK(v::exit(x) == v::Refusal::TooSoon);
	CHECK(v::exit_rules(x) == v::Refusal::None);
	x.exit_locked = true;
	CHECK(v::exit_rules(x) == v::Refusal::ExitLocked);

	v::SwitchFacts s;
	s.seated = true;
	s.alive = true;
	s.seats = 2;
	s.from = 0;
	s.seat = 1;
	s.seat_free = true;
	s.since_last_ms = 0;
	CHECK(v::switch_to(s) == v::Refusal::TooSoon);
	CHECK(v::switch_rules(s) == v::Refusal::None);
	s.seat_free = false;
	CHECK(v::switch_rules(s) == v::Refusal::SeatTaken);
}

// ---------------------------------------------------------------------------------------------- releases, exits, arrivals

TEST(vehicle_drive_release_reason_order)
{
	v::SitterFacts f;
	CHECK(v::release_reason(f) == v::Release(0)); // all well: he stays
	f.wounded = true;
	CHECK(v::release_reason(f) == v::Release::Wounded);
	f.alive = false;
	CHECK(v::release_reason(f) == v::Release::Death);
	f.car_destroyed = true;
	CHECK(v::release_reason(f) == v::Release::CarDestroyed); // the explosion is told before what it did to him
	f.car_online = false;
	CHECK(v::release_reason(f) == v::Release::CarGone);
	f.on_map = false;
	CHECK(v::release_reason(f) == v::Release::LeftLevel); // in the session, not on this map: co-op, he loads the world again
	f.same_character = false; // his player plays another character, or loads the world again for one: as before VEH-DISC
	CHECK(v::release_reason(f) == v::Release::LeftLevel);
	f.on_map = true;
	CHECK(v::release_reason(f) == v::Release::Disconnect);
	// VEH-DISC (tests/test_vehicle_departure.cpp): gone from the session, the mode's fact of how decides, wherever it places him
	f.in_session = false;
	f.gone = coop::Departure::Disconnected; // he quit (the co-op host: every peer that leaves; a map server: no row of his)
	CHECK(v::release_reason(f) == v::Release::Disconnect);
	f.on_map = false;
	CHECK(v::release_reason(f) == v::Release::Disconnect); // a map server's level session dropped him: still a quit
	f.gone = coop::Departure::LeftLevel; // a map server: the LevelMap lists him on another level
	CHECK(v::release_reason(f) == v::Release::LeftLevel);
	f.on_map = true;
	CHECK(v::release_reason(f) == v::Release::LeftLevel);
	f.gone = coop::Departure::Replaced; // a map server: the LevelMap lists him here with another character or none
	CHECK(v::release_reason(f) == v::Release::Disconnect);
	f.on_map = false;
	CHECK(v::release_reason(f) == v::Release::LeftLevel);
	v::SitterFacts g;
	g.body_online = false; // his character went from the map while his player stays: dead
	CHECK(v::release_reason(g) == v::Release::Death);
}

TEST(vehicle_drive_exit_candidates_start_at_the_stock_point)
{
	// a car at the origin facing +z (forward), right is +x, 2 m wide, 4 m long; the stock exit point at its left door
	v::Point3 stock{-1.6f, 0.2f, 0.5f}, centre{0.f, 0.8f, 0.f}, right{1.f, 0.f, 0.f}, forward{0.f, 0.f, 1.f};
	const std::vector<v::Point3> c = v::exit_candidates(stock, centre, right, forward, 1.f, 2.f);
	REQUIRE(c.size() == v::kExitCandidates);
	CHECK(c[0].x == stock.x && c[0].y == stock.y && c[0].z == stock.z);
	// then the left side (x = -2), nearest to the stock point; every next one no nearer than the one before
	CHECK(c[1].x == -2.f && c[1].z == 0.f && c[1].y == centre.y);
	auto d2 = [&stock](const v::Point3& p) { return (p.x - stock.x) * (p.x - stock.x) + (p.z - stock.z) * (p.z - stock.z); };
	for (size_t i = 2; i < c.size(); ++i)
		CHECK(d2(c[i]) >= d2(c[i - 1]));
	// every side point is clear of the car's box by kExitClearance
	for (size_t i = 1; i < c.size(); ++i)
		CHECK((c[i].x <= -2.f || c[i].x >= 2.f) || (c[i].z <= -3.f || c[i].z >= 3.f));
	// a turned car: the points turn with its axes (facing +x, right is -z)
	const std::vector<v::Point3> t = v::exit_candidates(v::Point3{0.f, 0.f, 5.f}, centre, v::Point3{0.f, 0.f, -1.f}, v::Point3{1.f, 0.f, 0.f}, 1.f, 2.f);
	CHECK(t[1].x == 0.f && t[1].z == 2.f); // the side nearest to (0, 5): its left (-right = +z)
}

TEST(vehicle_drive_arrivals_get_the_table_once_per_arrival)
{
	v::Arrivals a;
	// the first frame lists everybody who is on the map
	std::vector<coop::PeerId> came = a.update({{1, true}, {2, false}, {3, true}});
	CHECK(came == (std::vector<coop::PeerId>{1, 3}));
	// nothing new: nothing sent again
	CHECK(a.update({{1, true}, {2, false}, {3, true}}).empty());
	// 2 finished loading
	came = a.update({{1, true}, {2, true}, {3, true}});
	CHECK(came == (std::vector<coop::PeerId>{2}));
	// 3 left the map (Server: another level; co-op: he loads the world again), then came back: listed again
	CHECK(a.update({{1, true}, {2, true}, {3, false}}).empty());
	came = a.update({{1, true}, {2, true}, {3, true}});
	CHECK(came == (std::vector<coop::PeerId>{3}));
	// 1 left the session: forgotten; a new peer with his id later is new
	CHECK(a.update({{2, true}, {3, true}}).empty());
	CHECK_EQ(a.here(), size_t(2));
	came = a.update({{1, true}, {2, true}, {3, true}});
	CHECK(came == (std::vector<coop::PeerId>{1}));
	a.clear();
	CHECK_EQ(a.update({{2, true}}).size(), size_t(1));
}

// ---------------------------------------------------------------------------------------------- coop_status

TEST(vehicle_drive_status_counts_by_reason)
{
	v::SeatStats s;
	s.granted = 3;
	s.refuse(v::Refusal::TooFar);
	s.refuse(v::Refusal::TooFar);
	s.refuse(v::Refusal::Locked);
	s.refuse(v::Refusal(200)); // out of range: not counted, no overrun
	s.release(v::Release::Exit);
	s.release(v::Release::CarDestroyed);
	s.release(v::Release(0)); // "none" is not a release: not listed
	s.inputs_applied = 120;
	s.stale = 1;
	const std::string text = v::stats_text(s, 30);
	CHECK_EQ(text.substr(0, text.find(", inputs")),
	    std::string("granted 3, refused 3 (locked 1, too_far 2), released 2 (exit 1, car_destroyed 1)"));
	CHECK(text.find("inputs 30/s (applied 120, old 0, not driving 0, wrong car 0, over rate 0, bad 0)") != std::string::npos);
	CHECK(text.find("stale 1") != std::string::npos);
	v::SeatStats none;
	CHECK_EQ(v::stats_text(none, 0).substr(0, 35), std::string("granted 0, refused 0, released 0, i"));

	v::PerSecond rate;
	rate.add(1000);
	rate.add(1500);
	CHECK_EQ(rate.rate(1900), 0u); // the first second is not over
	CHECK_EQ(rate.rate(2000), 2u);
	CHECK_EQ(rate.rate(4500), 0u); // a quiet second
}

// ---------------------------------------------------------------------------------------------- the session's end (rv_F5-VEH-2 blocker 1)

namespace
{
// anomaly-coop/<rel> (tests\ -> ..), without '\r'
std::string drive_project_file(const std::string& rel)
{
	std::string here = __FILE__;
	const size_t slash = here.find_last_of("\\/");
	here.resize(slash == std::string::npos ? 0 : slash);
	std::ifstream f(here + "/../" + rel, std::ios::binary);
	std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
	text.erase(std::remove(text.begin(), text.end(), '\r'), text.end());
	return text;
}

// The body of the function whose definition starts with `head` (up to the first "\n}" at column 0), "" when none.
std::string drive_body(const std::string& src, const std::string& head)
{
	const size_t at = src.find("\n" + head);
	if (at == std::string::npos)
		return std::string();
	const size_t end = src.find("\n}", at + 1);
	return src.substr(at + 1, end == std::string::npos ? std::string::npos : end - at);
}
} // namespace

// Manager::stop / a lost session run sync::reset() and then no sync::frame: server_frame never sees the session end. A client's car
// kept its pressed keys with the hand brake off, the own actor stayed refused at that car and seated() froze avatars with the old ids.
// sync::reset() now tells the decider (vehicles::session_over): the cars parked as detach_Actor parks them, the table forgotten.
TEST(vehicle_drive_session_end_forgets_the_seats)
{
	const std::string reset = drive_body(drive_project_file("engine/src/xrGame/coop/coop_sync.cpp"), "const Step kReset[]");
	CHECK(!reset.empty());
	CHECK(reset.find("&vehicles::session_over,") != std::string::npos);

	const std::string header = drive_project_file("engine/src/xrGame/coop/coop_vehicles.h");
	CHECK(header.find("void session_over();") != std::string::npos);
	CHECK(header.find("void release_all_seats(Release why);") != std::string::npos);

	const std::string seat = drive_project_file("engine/src/xrGame/coop/coop_vehicles_seat.cpp");
	const std::string over = drive_body(seat, "void session_over()");
	CHECK(!over.empty());
	const size_t drop = over.find("drop_quietly(world_up() && join::world_generation() == g.world)");
	const size_t clear = over.find("g = State();");
	CHECK(drop != std::string::npos);
	CHECK(clear != std::string::npos && drop < clear);
	CHECK(over.find("if (g.installed)") != std::string::npos);
	// nothing is sent at the session's end: no message out of session_over
	CHECK(over.find("send_all") == std::string::npos && over.find("release(") == std::string::npos);
}

TEST(vehicle_drive_group_transition_releases_the_seats)
{
	const std::string join = drive_project_file("engine/src/xrGame/coop/coop_join_transition_load.cpp");
	const std::string prepare = drive_body(join, "void host_prepare(const xr_vector<Mover>& movers, u16 level, const FILETIME& before, u64 save_ms)");
	CHECK(!prepare.empty());
	const size_t rel = prepare.find("vehicles::release_all_seats(vehicles::Release::LeftLevel);");
	const size_t join_begin = prepare.find("sync::host_begin_join(m.peer);");
	CHECK(rel != std::string::npos);
	CHECK(join_begin != std::string::npos && rel < join_begin);
	CHECK(join.find("#include \"coop_vehicles.h\"") != std::string::npos);

	const std::string seat = drive_project_file("engine/src/xrGame/coop/coop_vehicles_seat.cpp");
	const size_t own = seat.find("if (CCar* held = smart_cast<CCar*>(a->Holder()))");
	const size_t rows = seat.find("\tcheck_own_rows();");
	CHECK(own != std::string::npos && rows != std::string::npos && own < rows);
}

// Should-fix S2 of F5-REV-1 (both modes): CCar::Initiator names who did what the car did (a run-over hit, the explosion): the stock
// Owner, else the car. A car a client drives has no Owner on the decider, so his kills, the relation and reputation changes, the
// statistics and the task credit went to the car. The hook (docs/VEHICLES.md, coop_vehicles.h driver_of) names the client's character
// in seat 0 after the stock Owner; nothing is installed in single player (driver_of answers kNoCharacter): the stock answer.
TEST(vehicle_drive_initiator_is_the_client_driver)
{
	const std::string car = drive_project_file("engine/src/xrGame/Car.cpp");
	REQUIRE(!car.empty());
	const std::string initiator = drive_body(car, "u16 CCar::Initiator()");
	REQUIRE(!initiator.empty());
	const size_t owner = initiator.find("if (g_Alive() && Owner())");
	const size_t owner_id = initiator.find("return Owner()->ID();");
	const size_t driver = initiator.find("const u16 coop_driver = coop::vehicles::driver_of(u16(ID()));");
	const size_t seated = initiator.find("if (g_Alive() && coop_driver != coop::vehicles::kNoCharacter)");
	const size_t his = initiator.find("return coop_driver;");
	const size_t stock = initiator.find("return ID();");
	CHECK(owner != std::string::npos && owner_id != std::string::npos && driver != std::string::npos);
	CHECK(seated != std::string::npos && his != std::string::npos && stock != std::string::npos);
	CHECK(owner < owner_id && owner_id < driver && driver < seated && seated < his && his < stock);
	CHECK(car.find("#include \"coop/coop_vehicles.h\"") != std::string::npos);
}
