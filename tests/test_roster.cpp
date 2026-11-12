// Anomaly Coop unit tests: who is listed as a player and who carries the host's badge (xrCoop/coop_roster.h,
// docs/plans/2026-11-12-split-levels-native.md §1.3).
#include "test_util.h"
#include "coop_roster.h"

#include <string>
#include <vector>

using namespace coop;

namespace
{
PeerInfo seat(PeerId id, const char* nick, bool plays = true, bool rights = false)
{
	PeerInfo p;
	p.id = id;
	p.state = PeerState::Joined;
	p.nick = nick;
	p.plays = plays;
	p.host_rights = rights;
	return p;
}
} // namespace

TEST(roster_defaults_play_without_rights)
{
	const PeerInfo p;
	CHECK(p.plays); // every seat plays unless the host says its own does not
	CHECK(!p.host_rights);
}

TEST(roster_an_ordinary_host)
{
	// The host plays (seat 0 is his character), two friends: three players, the star on seat 0.
	const std::vector<PeerInfo> seats = {seat(0, "Boss"), seat(1, "Alice"), seat(2, "Bob")};
	CHECK_EQ(roster::player_count(seats), uint32_t(3));
	CHECK_EQ(roster::listed_only(seats).size(), size_t(3));
	CHECK(roster::host_plays_in(seats, false));
	CHECK(roster::host_badge(seats[0], true));
	CHECK(!roster::host_badge(seats[1], true));
	CHECK(!roster::host_badge(seats[2], true));
}

TEST(roster_a_world_server_with_an_operator)
{
	// A client's view of a world server: seat 0 plays no character, the creator (seat 1) holds the rights.
	const std::vector<PeerInfo> seats = {seat(0, "server", false), seat(1, "Creator", true, true), seat(2, "Friend")};
	CHECK(!roster::host_plays_in(seats, true));
	const bool plays = roster::host_plays_in(seats, true);
	CHECK(!roster::listed(seats[0]));
	CHECK_EQ(roster::player_count(seats), uint32_t(2));
	const std::vector<PeerInfo> listed = roster::listed_only(seats);
	REQUIRE(listed.size() == 2);
	CHECK_EQ(listed[0].nick, std::string("Creator"));
	CHECK_EQ(listed[1].nick, std::string("Friend"));
	CHECK(!roster::host_badge(seats[0], plays)); // no star on the server
	CHECK(roster::host_badge(seats[1], plays)); // the star on the creator
	CHECK(!roster::host_badge(seats[2], plays));
}

TEST(roster_a_world_server_alone)
{
	// One friend on a world server nobody operates: one player, no star at all.
	const std::vector<PeerInfo> seats = {seat(0, "server", false), seat(1, "Friend")};
	CHECK_EQ(roster::player_count(seats), uint32_t(1));
	for (const PeerInfo& p : seats)
		CHECK(!roster::host_badge(p, false));
}

TEST(roster_the_host_side_of_a_world_server)
{
	// The server's own peers(): no seat 0 in it, host_plays comes from its configuration.
	const std::vector<PeerInfo> seats = {seat(1, "Creator", true, true), seat(2, "Friend")};
	CHECK(!roster::host_plays_in(seats, false));
	CHECK(roster::host_plays_in(seats, true));
	CHECK_EQ(roster::player_count(seats), uint32_t(2));
	CHECK(roster::host_badge(seats[0], false));
}

TEST(roster_a_seat_that_does_not_play_carries_no_badge)
{
	// Rights without a character (cannot happen today: only a player's Hello makes an operator) show no star: the star is on a
	// row of the list, and that seat has none.
	CHECK(!roster::host_badge(seat(0, "server", false, true), false));
	CHECK(!roster::host_badge(seat(0, "server", false, false), true));
	CHECK_EQ(roster::player_count({}), uint32_t(0));
}
