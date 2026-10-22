// Anomaly Coop unit tests: which item-state tags differ between the host copy and the owner (coop_item_tags.h, R3 В1).
#include "test_util.h"

#include "coop_item_tags.h"

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

using namespace coop;

namespace
{
using UpgradeList = std::vector<std::string>;

// Same field names as ItemData in coop_items.cpp (diverged() reads exactly these).
struct Item
{
	bool has_cond = false;
	std::uint16_t cond = 0;
	bool has_upgrades = false;
	UpgradeList upgrades;
	bool has_box = false;
	std::uint16_t box = 0;
	bool has_addons = false;
	std::uint8_t addons = 0;
	bool has_scope = false;
	std::uint8_t scope = 0;
	bool has_main = false;
	std::uint16_t main_count = 0;
	std::uint8_t main_type = 0;
	bool has_launcher = false;
	std::uint16_t gl_count = 0;
	std::uint8_t gl_type = 0;
	bool has_uses = false;
	std::uint8_t uses = 0;
};

// Upgrade order does not matter, like same_upgrades() in coop_items.cpp.
bool same_upgrades(const UpgradeList& a, const UpgradeList& b)
{
	if (a.size() != b.size())
		return false;
	for (const std::string& s : a)
		if (std::find(b.begin(), b.end(), s) == b.end())
			return false;
	return true;
}

std::uint32_t diff(const Item& cur, const Item& owner)
{
	return itemtags::diverged(cur, owner, same_upgrades);
}

// A weapon the way capture_object() reports it: every tag but the scope one.
Item weapon_without_scopes()
{
	Item d;
	d.has_cond = true;
	d.cond = 65535;
	d.has_upgrades = true;
	d.has_addons = true;
	d.addons = 0;
	d.has_main = true;
	d.main_count = 8;
	d.main_type = 1;
	return d;
}

Item food()
{
	Item d;
	d.has_cond = true;
	d.cond = 65535;
	d.has_upgrades = true;
	d.has_uses = true;
	d.uses = 4;
	return d;
}
} // namespace

TEST(item_tags_scope_rules)
{
	CHECK(!itemtags::scope_tag_applies(0)); // pistols, knife
	CHECK(itemtags::scope_tag_applies(1));
	CHECK(itemtags::scope_tag_applies(5));
	CHECK(!itemtags::scope_index_ok(0, 0)); // a weapon without scopes takes no scope index
	CHECK(!itemtags::scope_index_ok(255, 0));
	CHECK(itemtags::scope_index_ok(0, 1));
	CHECK(!itemtags::scope_index_ok(1, 1));
	CHECK(itemtags::scope_index_ok(4, 5));
	CHECK(!itemtags::scope_index_ok(5, 5));
}

TEST(item_tags_equal_states_do_not_differ)
{
	CHECK_EQ(diff(weapon_without_scopes(), weapon_without_scopes()), 0u);
	CHECK_EQ(diff(food(), food()), 0u);
	CHECK_EQ(diff(Item(), Item()), 0u);

	Item scoped = weapon_without_scopes();
	scoped.has_scope = true;
	scoped.scope = 2;
	CHECK_EQ(diff(scoped, scoped), 0u);
}

// R3 В1: the host copy of a pistol reported a scope tag, the owner's state had none -> never equal, "stuck" forever.
TEST(item_tags_scope_tag_the_owner_never_sent_is_not_enforced)
{
	const Item owner = weapon_without_scopes();
	Item host = weapon_without_scopes();
	host.has_scope = true;
	host.scope = 0;
	CHECK_EQ(diff(host, owner), 0u);
	host.scope = 3;
	CHECK_EQ(diff(host, owner), 0u);
}

// The same holds for any tag the owner left out (a partial state enforces only what it says).
TEST(item_tags_tags_the_owner_left_out_are_not_compared)
{
	const Item owner = weapon_without_scopes();
	Item host = weapon_without_scopes();
	host.has_uses = true;
	host.uses = 2;
	host.has_box = true;
	host.box = 30;
	host.has_launcher = true;
	host.gl_count = 1;
	CHECK_EQ(diff(host, owner), 0u);
}

TEST(item_tags_each_differing_tag_is_reported_alone)
{
	struct Case
	{
		itemtags::Bit bit;
		void (*owner)(Item&); // makes the owner carry the tag
		void (*host)(Item&); // makes the host copy carry another value
	};
	const Case cases[] = {
		{itemtags::Cond, [](Item& d) { d.cond = 100; }, [](Item& d) { d.cond = 101; }},
		{itemtags::Upgrades, [](Item& d) { d.upgrades = {"up_a"}; }, [](Item& d) { d.upgrades = {"up_b"}; }},
		{itemtags::Box, [](Item& d) { d.has_box = true; d.box = 10; }, [](Item& d) { d.has_box = true; d.box = 11; }},
		{itemtags::Addons, [](Item& d) { d.addons = 1; }, [](Item& d) { d.addons = 3; }},
		{itemtags::Scope, [](Item& d) { d.has_scope = true; d.scope = 1; }, [](Item& d) { d.has_scope = true; d.scope = 2; }},
		{itemtags::Main, [](Item& d) { d.main_count = 5; }, [](Item& d) { d.main_count = 6; }},
		{itemtags::Launcher, [](Item& d) { d.has_launcher = true; d.gl_count = 1; d.gl_type = 0; },
			[](Item& d) { d.has_launcher = true; d.gl_count = 1; d.gl_type = 1; }},
		{itemtags::Uses, [](Item& d) { d.has_uses = true; d.uses = 3; }, [](Item& d) { d.has_uses = true; d.uses = 2; }},
	};
	std::uint32_t covered = 0;
	for (const Case& c : cases)
	{
		Item owner = weapon_without_scopes();
		Item host = weapon_without_scopes();
		c.owner(owner);
		c.host(host);
		CHECK_EQ(diff(host, owner), std::uint32_t(c.bit));
		covered |= c.bit;
	}
	CHECK_EQ(covered, itemtags::kAll);
}

// A tag the owner carries and the host copy cannot report is a difference (the copy cannot take it).
TEST(item_tags_tag_missing_on_the_host_copy_differs)
{
	Item owner = food();
	owner.has_scope = true;
	owner.scope = 1;
	CHECK_EQ(diff(food(), owner), std::uint32_t(itemtags::Scope));

	Item no_uses = food();
	no_uses.has_uses = false;
	CHECK_EQ(diff(no_uses, food()), std::uint32_t(itemtags::Uses));
}

TEST(item_tags_several_tags_and_upgrade_order)
{
	Item owner = food();
	owner.upgrades = {"a", "b"};
	Item host = food();
	host.upgrades = {"b", "a"};
	CHECK_EQ(diff(host, owner), 0u); // order does not matter

	host.upgrades = {"a"};
	host.uses = 1;
	host.cond = 7;
	CHECK_EQ(diff(host, owner), std::uint32_t(itemtags::Cond | itemtags::Upgrades | itemtags::Uses));
}

// The upgrade lists are only compared when the owner carries them.
TEST(item_tags_upgrades_compared_only_when_the_owner_has_them)
{
	int calls = 0;
	auto counting = [&](const UpgradeList& a, const UpgradeList& b)
	{
		++calls;
		return same_upgrades(a, b);
	};
	Item owner = food();
	Item host = food();
	owner.has_upgrades = false;
	host.upgrades = {"x"};
	CHECK_EQ(itemtags::diverged(host, owner, counting), 0u); // the host copy has the tag, the owner does not: ignored
	CHECK_EQ(calls, 0);

	owner.has_upgrades = true;
	CHECK_EQ(itemtags::diverged(host, owner, counting), std::uint32_t(itemtags::Upgrades));
	CHECK_EQ(calls, 1);
}

TEST(item_tags_names)
{
	for (std::uint32_t bit = 1; bit <= itemtags::Uses; bit <<= 1)
	{
		const char* n = itemtags::name(itemtags::Bit(bit));
		CHECK(n && *n && std::string(n) != "?");
	}
	CHECK_EQ(std::string(itemtags::name(itemtags::Scope)), std::string("scope"));
}
