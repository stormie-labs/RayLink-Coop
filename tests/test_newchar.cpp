// Anomaly Coop unit tests: a player with a new key chooses his character before the world (protocol 8, coop_newchar.h):
// who is choosing on the host and for how long, the choice as the window gives it, where the character may appear.
#include "test_util.h"
#include "coop_newchar.h"

#include <algorithm>

using namespace coop;

TEST(newchar_choosers_offer_take_forget)
{
	newchar::Choosers c;
	CHECK(!c.choosing(1) && c.count() == 0);
	CHECK(!c.take(1)); // a choice nobody asked for

	c.offer(1, 1000);
	CHECK(c.choosing(1) && !c.choosing(2) && c.count() == 1);
	CHECK(c.in_choice(1) && !c.in_choice(2));
	CHECK(c.take(1)); // his choice is taken: the host checks it now
	CHECK(!c.choosing(1));
	CHECK(c.in_choice(1)); // still his join: not timed out as a world load
	CHECK(!c.take(1)); // a second choice for the same offer is not taken
	c.offer(1, 5000); // refused: asked again
	CHECK(c.choosing(1));
	CHECK(c.take(1));
	c.forget(1); // he got his character
	CHECK(c.count() == 0 && !c.take(1) && !c.in_choice(1));

	c.offer(2, 0);
	c.offer(3, 0);
	c.forget(2); // left the session
	CHECK(!c.choosing(2) && c.choosing(3) && c.count() == 1);
}

TEST(newchar_choosers_time_limit_from_the_first_offer)
{
	newchar::Choosers c;
	static_assert(newchar::kChoiceTimeoutMs == 10ull * 60 * 1000, "ten minutes in the window");
	const uint64_t t0 = 50000;
	c.offer(1, t0);
	c.offer(2, t0 + 1000);
	CHECK(c.expired(t0 + newchar::kChoiceTimeoutMs).empty());
	// refusals and new offers do not move the limit: a player cannot hold his slot for ever by choosing wrong
	CHECK(c.take(1));
	c.offer(1, t0 + newchar::kChoiceTimeoutMs - 10);
	const std::vector<PeerId> late = c.expired(t0 + newchar::kChoiceTimeoutMs + 1);
	CHECK(late == std::vector<PeerId>{1});
	// a choice under way counts too (taken, not answered yet)
	CHECK(c.take(1));
	CHECK(c.expired(t0 + newchar::kChoiceTimeoutMs + 1) == std::vector<PeerId>{1});
	const std::vector<PeerId> both = c.expired(t0 + 1000 + newchar::kChoiceTimeoutMs + 1);
	CHECK(both.size() == 2 && std::count(both.begin(), both.end(), PeerId(2)) == 1);
	// the clock is in the past (a host whose tick count went back): never expired
	CHECK(c.expired(0).empty());
}

TEST(newchar_choosers_world_replaced)
{
	// A load or a level change: every player rejoins after SessionReset and is offered a character again (new clock).
	newchar::Choosers c;
	c.offer(1, 0);
	c.offer(4, 0);
	CHECK(c.take(4));
	c.world_replaced();
	CHECK(c.count() == 0 && !c.choosing(1) && !c.take(1) && !c.take(4));
	CHECK(c.expired(newchar::kChoiceTimeoutMs * 2).empty());
	c.offer(1, newchar::kChoiceTimeoutMs * 2);
	CHECK(c.expired(newchar::kChoiceTimeoutMs * 2 + 1).empty());
}

TEST(newchar_choice_from_the_window)
{
	CharChoiceMsg m;
	CHECK(newchar::make_choice("bandit", "wpn_ak74_old,ammo_5.45x39_fmj, wpn_ak74_old ", m));
	CHECK_EQ(m.faction, std::string("bandit"));
	CHECK(m.buy == (std::vector<std::string>{"wpn_ak74_old", "ammo_5.45x39_fmj", "wpn_ak74_old"}));
	CHECK_EQ(newchar::buy_csv(m), std::string("wpn_ak74_old,ammo_5.45x39_fmj,wpn_ak74_old"));
	CHECK(newchar::make_choice("stalker", "", m) && m.buy.empty() && newchar::buy_csv(m).empty());
	CHECK(newchar::make_choice("stalker", ",,", m) && m.buy.empty()); // empty entries are no items
	// what the host would refuse to read is not sent
	CHECK(!newchar::make_choice("", "wpn_pm", m));
	CHECK(!newchar::make_choice("stalker", "wpn pm", m));
	std::string many;
	for (size_t i = 0; i <= CharChoiceMsg::kMaxBuy; ++i)
		many += "medkit,";
	CHECK(!newchar::make_choice("stalker", many, m));
}

TEST(newchar_start_on_the_hosts_level_until_split_levels)
{
	// F2: every player is on the host's level, so a faction start on another level (or a bad point) puts the new
	// character next to the host. F3a turns kOwnLevels on and lets him start on his faction's level.
	static_assert(!newchar::kOwnLevels, "F3a (split levels) is not there yet");
	CHECK(newchar::point_usable(true, true));
	CHECK(!newchar::point_usable(true, false));
	CHECK(!newchar::point_usable(false, true));
	CHECK(!newchar::point_usable(false, false));
}
