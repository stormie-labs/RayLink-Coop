// Anomaly Coop unit tests: the game-settings patch in the protocol (docs/GAME_SETTINGS.md §6 T3, §8): protocol 9, the
// world's faction in CharOffer. The choice window shows it; the host never reads the faction of a CharChoice.
#include "test_util.h"
#include "coop_protocol.h"

#include <string>

using namespace coop;

TEST(protocol_game_offer_roundtrip_faction)
{
	CharOfferMsg m;
	m.eco = 2;
	m.points = 700;
	m.flags = CharOfferMsg::StoryMode;
	m.level = "l01_escape";
	m.refusal = "points";
	m.faction = "csky";
	Writer w;
	m.write(w);
	// u8 eco, u32 points, u8 flags, str level, str refusal, str faction (varu length + bytes each)
	CHECK_EQ(w.size(), size_t(1 + 4 + 1 + (1 + 10) + (1 + 6) + (1 + 4)));
	CharOfferMsg back;
	back.faction = "stale";
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(back.faction, std::string("csky"));
	CHECK(back.eco == 2 && back.points == 700u && back.flags == CharOfferMsg::StoryMode);
	CHECK_EQ(back.level, std::string("l01_escape"));
	CHECK_EQ(back.refusal, std::string("points"));

	// A first offer (no refusal, no level) carries the faction too: the field is always there, after the refusal.
	CharOfferMsg first;
	first.faction = "monolith";
	Writer wf;
	first.write(wf);
	REQUIRE(wf.size() >= 9);
	CharOfferMsg first2;
	Reader rf(wf.ptr(), wf.size());
	CHECK(first2.read(rf));
	CHECK(first2.refusal.empty() && first2.level.empty());
	CHECK_EQ(first2.faction, std::string("monolith"));

	// The longest name the join flow carries
	CharOfferMsg longest;
	longest.faction = std::string(kMaxCharName, 'f');
	Writer wl;
	longest.write(wl);
	CharOfferMsg longest2;
	Reader rl(wl.ptr(), wl.size());
	CHECK(longest2.read(rl));
	CHECK_EQ(longest2.faction.size(), kMaxCharName);
}

TEST(protocol_game_offer_bad_faction_rejected)
{
	auto read_offer = [](const std::string& faction) {
		CharOfferMsg m;
		m.faction = faction;
		Writer w;
		m.write(w);
		CharOfferMsg back;
		Reader r(w.ptr(), w.size());
		return back.read(r);
	};
	CHECK(read_offer("stalker")); // the sound baseline: only the faction differs below
	CHECK(!read_offer("")); // the host always names a faction
	CHECK(!read_offer(std::string(kMaxCharName + 1, 'f'))); // 65 characters
	CHECK(!read_offer("a/b")); // the window picks a texture and a string id by it: a name only
	CHECK(!read_offer("a b"));
	CHECK(!read_offer("..\\x"));

	// An offer cut before or inside the faction (the protocol 8 layout has none) is not read
	CharOfferMsg good;
	good.faction = "dolg";
	Writer w;
	good.write(w);
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		CharOfferMsg m;
		Reader r(w.ptr(), cut);
		CHECK(!m.read(r));
	}
}

TEST(protocol_game_protocol_is_11)
{
	// 14: RestRequest carries the sleeping bag (test_rest_rules.cpp).
	// 13: EntitySnapshot carries a stalker's aim (CreatureAims + 3 quaternions after the item id).
	// 12: EntitySnapshot carries a stalker's item in hands (CreatureHolds + u16 id after the anims).
	// 11 (F3a, split levels): Msg 0x01D0..0x01DF, Hello carries a role and a token (test_protocol_f3a.cpp); a protocol 10
	// peer is refused at the handshake. 10: TransitionVote carries an op, TransitionState (host -> all) is new (the waiting
	// point of a level change). 9: CharOffer ends with `str faction` (the world's).
	CHECK_EQ(kProtocolVersion, 15u); // bounded instrument state, NPC prop kind, real invalid MotionID sentinel
}
