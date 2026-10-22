// Anomaly Coop unit tests: which hits on players' characters the host passes on as PlayerHit, and which hits the host's
// own player drops with friendly fire off (coop_hits.h; R-5.1, R3 В2 and the R3 minor on friendly fire).
#include "test_util.h"

#include "coop_hits.h"

using coop::hits::host_actor_drops;
using coop::hits::is_explosion;
using coop::hits::kHostActor;
using coop::hits::kNoObject;
using coop::hits::names_own_weapon;
using coop::hits::ProxyHit;
using coop::hits::Source;
using coop::hits::to_owner;

namespace
{
ProxyHit make(Source source, bool explosion, bool own_weapon)
{
	ProxyHit h;
	h.source = source;
	h.explosion = explosion;
	h.own_weapon = own_weapon;
	return h;
}
} // namespace

// R3 В2: a client's explosions are only a picture (WP7), so a blast or fragment reaches the player only as PlayerHit,
// whatever set the explosive off.
TEST(hits_explosion_without_creature_reaches_player)
{
	// A barrel or mine that went off by itself, or one an anomaly set off: the initiator is not a creature.
	CHECK(to_owner(make(Source::Object, true, true), true));
	CHECK(to_owner(make(Source::Object, true, true), false)); // nobody's friendly fire
	// The fragments of an explosive whose initiator is no longer online.
	CHECK(to_owner(make(Source::Missing, true, true), true));
	CHECK(to_owner(make(Source::Missing, true, false), false));
}

// What the player's own game computes stays there: anomalies, physics, artefacts (not explosions).
TEST(hits_local_damage_stays_local)
{
	for (const bool ff : {true, false})
	{
		CHECK(!to_owner(make(Source::Object, false, true), ff)); // black gravi artefact: who = weapon = the artefact
		CHECK(!to_owner(make(Source::Object, false, false), ff));
		CHECK(!to_owner(make(Source::Missing, false, true), ff)); // a shot whose shooter is gone
		CHECK(!to_owner(make(Source::Missing, false, false), ff));
		CHECK(!to_owner(make(Source::Self, false, false), ff)); // a fall: the character is its own weapon
	}
}

// Unchanged rules: creatures always, the character's own explosive always, other players only with friendly fire.
TEST(hits_creatures_self_and_players)
{
	for (const bool ff : {true, false})
	{
		CHECK(to_owner(make(Source::Creature, false, true), ff)); // a stalker's bullet
		CHECK(to_owner(make(Source::Creature, true, true), ff)); // a stalker's grenade
		CHECK(to_owner(make(Source::Self, true, true), ff)); // its own grenade or rocket
		CHECK(to_owner(make(Source::Self, false, true), ff)); // its own rocket's late fragment (rocket already gone)
	}
	CHECK(to_owner(make(Source::Player, false, true), true));
	CHECK(to_owner(make(Source::Player, true, true), true));
	CHECK(!to_owner(make(Source::Player, false, true), false));
	CHECK(!to_owner(make(Source::Player, true, true), false)); // another player's grenade, friendly fire off
}

// R3 minor: friendly fire off covers the explosions of a client too. Its shots and blows are refused as ReqHit; its
// grenade, rocket or the barrel it shot explode on the host and hit the host's actor directly.
TEST(hits_host_actor_friendly_fire)
{
	CHECK(host_actor_drops(Source::Player, false, false));
	CHECK(!host_actor_drops(Source::Player, false, true));
	for (const bool ff : {true, false})
	{
		CHECK(!host_actor_drops(Source::Self, false, ff)); // the host's own grenade or charge
		CHECK(!host_actor_drops(Source::Creature, false, ff));
		CHECK(!host_actor_drops(Source::Object, false, ff));
		CHECK(!host_actor_drops(Source::Missing, false, ff));
	}
}

// R3 В2 review 3: the host falling onto a client's character is the host's own fall (the contact object names itself
// as the weapon, Actor.cpp collision damage), not friendly fire.
TEST(hits_host_actor_collision_is_not_friendly_fire)
{
	for (const bool ff : {true, false})
		CHECK(!host_actor_drops(Source::Player, true, ff));
}

// R3 В2 review 4: the late fragments of an explosive that went off by itself (its initiator is the explosive) still
// count as an explosion when the explosive is already gone: explode_duration 0 (mines, IEDs, RPG rockets) removes it
// a few frames after the blast while its fragments fly.
TEST(hits_late_fragment_of_self_set_off_explosive)
{
	CHECK(is_explosion(true, true, 220, 900)); // the explosive is still there
	CHECK(is_explosion(false, false, 900, 900)); // gone; it was its own initiator
	CHECK(!is_explosion(false, true, 900, 900)); // online and its own weapon: an artefact, a poltergeist, a collision
	CHECK(!is_explosion(false, false, 220, 37)); // a bullet whose shooter is gone: the gun is the weapon
	CHECK(!is_explosion(false, false, kNoObject, kNoObject));
}

// R3 В2 review 2: a hit built without a weapon (SHit(), Lua hit(): weapon_id 0, the host's actor) is not the
// character's own explosive.
TEST(hits_own_weapon)
{
	CHECK(names_own_weapon(900, 500)); // its grenade / rocket / charge
	CHECK(!names_own_weapon(500, 500)); // the character itself
	CHECK(!names_own_weapon(kNoObject, 500));
	CHECK(!names_own_weapon(kHostActor, 500)); // Lua hit() with the default weapon_id
}
