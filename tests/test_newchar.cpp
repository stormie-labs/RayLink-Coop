// Anomaly Coop unit tests: a player with a new key chooses his character before the world (protocol 8, coop_newchar.h):
// who is choosing on the host and for how long, the choice as the window gives it, where the character may appear.
#include "test_util.h"
#include "coop_newchar.h"

#include <algorithm>
#include <iterator>

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

// ---------------------------------------------------------------- game settings T3 (docs/GAME_SETTINGS.md §8)
// Owner, 2026-10-23: the faction is part of the world, not of the player. The host builds a new character from the
// world's faction; what the client sent in CharChoice::faction is never used, whoever the client is.

namespace
{
// The stock new-game list (coop_menu_char.FACTIONS) - every faction a hostile client could ask for.
const char* const kFactions[] = {"stalker", "bandit", "csky", "dolg", "freedom", "killer", "army", "ecolog",
	"monolith", "renegade", "greh", "isg"};
} // namespace

TEST(newchar_hostile_client_faction_ignored)
{
	// The world is stalker, the client asks for monolith: the character is stalker (a host actor of another faction
	// does not matter while the world has one).
	CHECK_EQ(newchar::character_faction("stalker", "", "monolith"), std::string("stalker"));
	CHECK_EQ(newchar::character_faction("stalker", "dolg", "monolith"), std::string("stalker"));
}

TEST(newchar_world_empty_uses_host_actor)
{
	// An old save without the world's faction: the faction of the host's own character.
	CHECK_EQ(newchar::character_faction("", "dolg", "monolith"), std::string("dolg"));
	// A world faction that is not a name (a corrupt record) is no faction either.
	CHECK_EQ(newchar::character_faction("a b", "dolg", "monolith"), std::string("dolg"));
	CHECK_EQ(newchar::character_faction(std::string(kMaxCharName + 1, 'x'), "dolg", "monolith"), std::string("dolg"));
}

TEST(newchar_nothing_valid_uses_stalker)
{
	CHECK_EQ(newchar::character_faction("", "a b", ""), std::string("stalker"));
	CHECK_EQ(newchar::character_faction("x/y", "a,b", "monolith"), std::string("stalker"));
	CHECK_EQ(newchar::character_faction("", std::string(kMaxCharName + 1, 'x'), "monolith"), std::string("stalker"));
}

TEST(newchar_no_level_and_no_actor_uses_stalker)
{
	// Ruling GS-2: host_actor_faction() answers "" when there is no level or no Actor() yet (a CharOffer in the main
	// menu, a world still loading). With a world that has no faction either the answer is stalker - and a hostile
	// client gets nothing of what it asked for.
	for (const char* sent : kFactions)
		CHECK_EQ(newchar::character_faction("", "", sent), std::string("stalker"));
	CHECK_EQ(newchar::character_faction("", "", ""), std::string("stalker"));
}

TEST(newchar_sent_never_used)
{
	// Security: whatever the client sends - any of the 12 factions, a stranger, nothing, a forged string - the answer
	// depends on the world and the host only.
	static_assert(sizeof(kFactions) / sizeof(kFactions[0]) == 12, "the stock list has 12 factions");
	std::vector<std::string> sent(std::begin(kFactions), std::end(kFactions));
	for (const char* odd : {"", "a b", "zombied", "..\\x", "%s"})
		sent.emplace_back(odd);
	sent.emplace_back(kMaxCharName + 1, 'x');
	for (const std::string& s : sent)
	{
		CHECK_EQ(newchar::character_faction("freedom", "", s), std::string("freedom"));
		CHECK_EQ(newchar::character_faction("freedom", "dolg", s), std::string("freedom"));
		CHECK_EQ(newchar::character_faction("", "dolg", s), std::string("dolg"));
		CHECK_EQ(newchar::character_faction("", "", s), std::string("stalker"));
	}
}
