// Anomaly Coop unit tests: the rules behind the fixes of the enemy audit (coop_enemy_rules.h, 2026-10-31).
#include "test_util.h"

#include <cmath>

#include "coop_enemy_rules.h"

using namespace coop::enemy_rules;

namespace
{
bool near_value(float a, float b, float eps = 0.001f) { return std::fabs(a - b) <= eps; }
} // namespace

// F1: the player's own view and his own line of sight decide. The monster's vision is not an input: one that sleeps or
// has its back turned sees nothing, and that is the monster this path is meant to alert.
TEST(enemy_a_player_looking_at_a_monster_that_sees_nothing_notices_it)
{
	CHECK(player_notices(8.f, true, 0.9f, true));
}

TEST(enemy_a_monster_outside_the_view_cone_is_not_noticed)
{
	CHECK(!player_notices(8.f, true, 0.1f, true));
	CHECK(!player_notices(8.f, true, kViewCos - 0.01f, true));
	CHECK(player_notices(8.f, true, kViewCos, true));
}

TEST(enemy_a_wall_hides_a_monster_at_any_distance)
{
	CHECK(!player_notices(8.f, true, 1.f, false));
	CHECK(!player_notices(1.f, true, 1.f, false));
	CHECK(!player_notices(8.f, false, 0.f, false));
}

TEST(enemy_at_arms_length_the_view_does_not_matter)
{
	CHECK(player_notices(kAwareDistance, true, -1.f, true));
	CHECK(!player_notices(kAwareDistance + 0.1f, true, -1.f, true));
}

TEST(enemy_an_unknown_view_counts_as_looking_when_the_line_is_clear)
{
	CHECK(player_notices(20.f, false, 0.f, true));
}

// F4: a thrown object is sampled once a frame at tens of m/s, a whole metre or more per sample.
TEST(enemy_a_thrown_object_is_found_between_two_samples)
{
	const Point a{0.f, 1.f, 0.f}, b{10.f, 1.f, 0.f}, player{5.f, 1.f, 0.5f};
	const Point c = closest_on_segment(a, b, player);
	CHECK(near_value(c.x, 5.f));
	CHECK(near_value(c.y, 1.f));
	CHECK(near_value(c.z, 0.f));
	CHECK(distance(c, player) <= kThrowReach);
	CHECK(distance(b, player) > kThrowReach); // neither end of the step is near the player
	CHECK(distance(a, player) > kThrowReach);
}

TEST(enemy_the_closest_point_stays_on_the_step)
{
	const Point a{0.f, 0.f, 0.f}, b{1.f, 0.f, 0.f};
	CHECK(near_value(closest_on_segment(a, b, Point{-5.f, 0.f, 0.f}).x, 0.f));
	CHECK(near_value(closest_on_segment(a, b, Point{6.f, 0.f, 0.f}).x, 1.f));
	// no movement: the object itself
	CHECK(near_value(closest_on_segment(b, b, Point{6.f, 0.f, 0.f}).x, 1.f));
}

// F4: the numbers of GAMMA's actor.ltx (crash speeds 15..41, mass 94), a 100 kg object at 30 m/s.
TEST(enemy_the_contact_speed_is_the_stock_share_of_the_energy)
{
	CHECK(near_value(contact_speed(30.f, 100.f, 94.f), 30.f * std::sqrt(100.f / 194.f)));
	CHECK(near_value(contact_speed(30.f, 0.f, 94.f), 0.f));
	CHECK(near_value(contact_speed(30.f, 100.f, 0.f), 0.f));
}

TEST(enemy_a_burers_throw_hurts_by_the_stock_crash_formula)
{
	const float contact = 41.f;
	CHECK(near_value(thrown_power(contact, 15.f, 41.f, kThrowPowerBySpeed), 1.f));
	CHECK(near_value(thrown_power(28.f, 15.f, 41.f, kThrowPowerBySpeed), 0.5f));
	CHECK(near_value(thrown_power(15.f, 15.f, 41.f, kThrowPowerBySpeed), 0.f)); // at the crash speed, as stock: no damage
}

TEST(enemy_a_measured_speed_never_hurts_more_than_a_full_crash)
{
	CHECK(near_value(thrown_power(100.f, 15.f, 41.f, kThrowPowerBySpeed), 1.f));
}

TEST(enemy_a_poltergeists_throw_hurts_by_its_own_value)
{
	CHECK(near_value(thrown_power(10.f, 15.f, 41.f, 0.5f), 0.5f)); // over half the crash speed: the stock callback's gate
	CHECK(near_value(thrown_power(7.f, 15.f, 41.f, 0.5f), 0.f));
}

TEST(enemy_bad_crash_speeds_hurt_nobody)
{
	CHECK(near_value(thrown_power(30.f, 41.f, 41.f, kThrowPowerBySpeed), 0.f));
}

// F5: the look of a monster rides in the snapshot's creature flags. The bits that bring data after the anims
// (CreatureHolds, CreatureAims) stay clear: the reader takes those for any creature.
TEST(enemy_a_monster_look_survives_the_snapshot_flags)
{
	for (MonsterLook look : {MonsterLook::Shown, MonsterLook::CloakPartial, MonsterLook::CloakFull, MonsterLook::Hidden})
	{
		const uint8_t flags = look_flags(look);
		CHECK((flags & (coop::CreatureHolds | coop::CreatureAims)) == 0);
		CHECK(look_of(flags) == look);
		const uint8_t packed = coop::pack_anim_byte(3, flags);
		CHECK(coop::creature_flags_of(packed) == flags);
		CHECK(coop::anim_count_of(packed) == 3);
	}
}

TEST(enemy_a_shown_monster_sends_no_flags) { CHECK(look_flags(MonsterLook::Shown) == 0); }

TEST(enemy_the_looks_differ)
{
	CHECK(look_flags(MonsterLook::CloakPartial) != look_flags(MonsterLook::CloakFull));
	CHECK(look_flags(MonsterLook::CloakPartial) != look_flags(MonsterLook::Hidden));
	CHECK(look_flags(MonsterLook::CloakFull) != look_flags(MonsterLook::Hidden));
}

// F3c: only the start of a client's reload reaches the host.
TEST(enemy_a_reload_counts_for_a_while_after_it_was_reported)
{
	CHECK(reload_shown(100000u, 100000u));
	CHECK(reload_shown(100000u + kReloadShownMs - 1u, 100000u));
	CHECK(!reload_shown(100000u + kReloadShownMs, 100000u));
}

TEST(enemy_no_reload_reported_is_no_reload) { CHECK(!reload_shown(100u, 0u)); }

// F10: a shot by any player dispels a phantom; a puppet waits for the host.
TEST(enemy_a_phantom_vanishes_for_any_players_shot)
{
	CHECK(phantom_dispelled(true, true, false, false)); // its own target (stock)
	CHECK(phantom_dispelled(true, false, true, false)); // the other player
	CHECK(!phantom_dispelled(true, false, false, false)); // an NPC's stray shot
	CHECK(!phantom_dispelled(false, false, false, false)); // no author
}

TEST(enemy_a_puppet_phantom_is_not_dispelled_here) { CHECK(!phantom_dispelled(true, true, true, true)); }
