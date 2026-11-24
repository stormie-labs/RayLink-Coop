// Anomaly Coop unit tests: the game-settings patch in the protocol (docs/GAME_SETTINGS.md §6 T3, §8): protocol 9, the
// world's faction in CharOffer. The choice window shows it; the host never reads the faction of a CharChoice.
#include "test_util.h"
#include "coop_protocol.h"

#include <string>
#include <vector>

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
	// 31 (split levels native, stage 1): Welcome.flags (HostSeatPlays), PeerList rows end with u8 flags (Operator), core
	// OperatorCommand.
	// 33 (two modes, step S3; the only bump of build 57): Welcome ends with u8 mode (SessionMode), test below.
	// 35 (TZ R90): TradeOp Deal flag 2, the Lua trade window's deal, carries the sums its window showed.
	CHECK_EQ(kProtocolVersion, 35u);
}

// ---------------------------------------------------------------- protocol 31: a seat without a character, the operator

TEST(protocol_31_welcome_flags_roundtrip)
{
	WelcomeMsg d;
	CHECK(d.flags == WelcomeMsg::HostSeatPlays); // an ordinary host's seat plays

	// protocol 33: the mode goes with the seat (a co-op host plays, a world server's seat does not)
	for (const uint8_t flags : {uint8_t(0), uint8_t(WelcomeMsg::HostSeatPlays)})
	{
		WelcomeMsg m;
		m.slot = 3;
		m.session_token = 0x1122334455667788ull;
		m.host_nick = "server";
		m.max_players = 8;
		m.world_epoch = 5;
		m.flags = flags;
		m.mode = flags ? SessionMode::Coop : SessionMode::Server;
		Writer w;
		m.write(w);
		// u32 slot, u64 token, str nick, u32 max, u32 epoch, u8 flags, u8 mode (protocol 33)
		CHECK_EQ(w.size(), size_t(4 + 8 + (1 + 6) + 4 + 4 + 1 + 1));
		WelcomeMsg back;
		back.flags = 0x7F;
		Reader r(w.ptr(), w.size());
		CHECK(back.read(r));
		CHECK_EQ(r.remaining(), size_t(0));
		CHECK_EQ(back.flags, flags);
		CHECK_EQ(back.slot, PeerId(3));
		CHECK_EQ(back.world_epoch, 5u);
		// cut anywhere: refused (the flags byte is not optional)
		for (size_t cut = 0; cut < w.size(); ++cut)
		{
			WelcomeMsg t;
			Reader rc(w.ptr(), cut);
			CHECK(!t.read(rc));
		}
	}
	// an unknown flag: refused
	WelcomeMsg m;
	m.flags = 0x80;
	m.mode = SessionMode::Coop;
	Writer w;
	m.write(w);
	WelcomeMsg back;
	Reader r(w.ptr(), w.size());
	CHECK(!back.read(r));
}

// ---------------------------------------------------------------- protocol 33: the session's mode in Welcome

namespace
{
WelcomeMsg welcome_of(SessionMode mode, uint8_t flags)
{
	WelcomeMsg m;
	m.slot = 2;
	m.session_token = 0x0102030405060708ull;
	m.host_nick = "Boss";
	m.max_players = 8;
	m.world_epoch = 9;
	m.flags = flags;
	m.mode = mode;
	return m;
}

bool reads(const Writer& w)
{
	WelcomeMsg back;
	Reader r(w.ptr(), w.size());
	return back.read(r);
}
} // namespace

TEST(protocol_33_session_mode_values)
{
	// the values are the wire's: append only
	static_assert(sizeof(SessionMode) == 1, "one byte on the wire");
	static_assert(static_cast<uint8_t>(SessionMode::None) == 0, "never on the wire");
	static_assert(static_cast<uint8_t>(SessionMode::Coop) == 1, "protocol 33");
	static_assert(static_cast<uint8_t>(SessionMode::Server) == 2, "protocol 33");
	CHECK_EQ(std::string(session_mode_name(SessionMode::Coop)), std::string("coop"));
	CHECK_EQ(std::string(session_mode_name(SessionMode::Server)), std::string("server"));
	CHECK_EQ(std::string(session_mode_name(SessionMode::None)), std::string("none"));
	CHECK_EQ(std::string(session_mode_name(static_cast<SessionMode>(7))), std::string("none"));
	// a WelcomeMsg nobody filled says no mode: a host that forgets it sends a Welcome every client refuses
	WelcomeMsg d;
	CHECK(d.mode == SessionMode::None);
}

TEST(protocol_33_welcome_mode_roundtrip)
{
	struct Case
	{
		SessionMode mode;
		uint8_t flags;
	};
	// a co-op host (its seat plays), a world server (its seat plays no character); the world server's Welcome to its map
	// server (a bridge) is the same as to its players
	for (const Case c : {Case{SessionMode::Coop, uint8_t(WelcomeMsg::HostSeatPlays)}, Case{SessionMode::Server, uint8_t(0)}})
	{
		const WelcomeMsg m = welcome_of(c.mode, c.flags);
		Writer w;
		m.write(w);
		CHECK_EQ(w.size(), size_t(4 + 8 + (1 + 4) + 4 + 4 + 1 + 1));
		CHECK_EQ(w.data().back(), static_cast<uint8_t>(c.mode)); // the last byte, after the flags
		WelcomeMsg back;
		Reader r(w.ptr(), w.size());
		REQUIRE(back.read(r));
		CHECK_EQ(r.remaining(), size_t(0));
		CHECK(back.mode == c.mode);
		CHECK_EQ(back.flags, c.flags);
		CHECK_EQ(back.slot, PeerId(2));
		CHECK_EQ(back.session_token, 0x0102030405060708ull);
		CHECK_EQ(back.host_nick, std::string("Boss"));
		CHECK_EQ(back.world_epoch, 9u);
		// a Welcome of protocol 32 ends at the flags: refused (a 33 client never takes a 32 host's word for its mode)
		Reader old(w.ptr(), w.size() - 1);
		WelcomeMsg t;
		CHECK(!t.read(old));
	}
}

TEST(protocol_33_welcome_mode_bounds)
{
	// no mode, an unknown one, and a mode that contradicts the seat: refused
	for (const uint8_t raw : {uint8_t(0), uint8_t(3), uint8_t(0x7F), uint8_t(0xFF)})
	{
		Writer w;
		welcome_of(SessionMode::Coop, WelcomeMsg::HostSeatPlays).write(w);
		std::vector<uint8_t> bytes = w.data();
		bytes.back() = raw;
		WelcomeMsg back;
		Reader r(bytes.data(), bytes.size());
		CHECK(!back.read(r));
	}
	Writer none;
	welcome_of(SessionMode::None, WelcomeMsg::HostSeatPlays).write(none);
	CHECK(!reads(none));
	Writer coop_seatless; // a co-op host always plays
	welcome_of(SessionMode::Coop, 0).write(coop_seatless);
	CHECK(!reads(coop_seatless));
	Writer server_playing; // a world server's own seat never plays
	welcome_of(SessionMode::Server, WelcomeMsg::HostSeatPlays).write(server_playing);
	CHECK(!reads(server_playing));
	// the rule the reader holds a Welcome to
	CHECK(session_mode_of_seat(true) == SessionMode::Coop);
	CHECK(session_mode_of_seat(false) == SessionMode::Server);
}

TEST(protocol_31_peer_list_entry_roundtrip)
{
	PeerListEntry e;
	CHECK_EQ(e.flags, uint8_t(0));
	e.slot = 2;
	e.nick = "Creator";
	e.key_hash = 0xA1B2C3D4u;
	e.flags = PeerListEntry::Operator;
	Writer w;
	e.write(w);
	// u32 slot, str nick, u32 key hash, u8 flags
	CHECK_EQ(w.size(), size_t(4 + (1 + 7) + 4 + 1));
	CHECK(PeerListEntry::kMinWire == size_t(4 + 1 + 4 + 1));
	PeerListEntry back;
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(back.slot, PeerId(2));
	CHECK_EQ(back.nick, std::string("Creator"));
	CHECK_EQ(back.key_hash, 0xA1B2C3D4u);
	CHECK_EQ(back.flags, uint8_t(PeerListEntry::Operator));
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		PeerListEntry t;
		Reader rc(w.ptr(), cut);
		CHECK(!t.read(rc));
	}
	PeerListEntry bad = e;
	bad.flags = 0x02;
	Writer wb;
	bad.write(wb);
	Reader rb(wb.ptr(), wb.size());
	PeerListEntry t;
	CHECK(!t.read(rb));
}

TEST(protocol_31_operator_command)
{
	static_assert(static_cast<uint16_t>(Msg::OperatorCommand) == 0x000B, "core message, append only");
	static_assert(static_cast<uint16_t>(Msg::OperatorCommand) < static_cast<uint16_t>(Msg::GameBase), "handled by the session");
	CHECK_EQ(std::string(msg_name(Msg::OperatorCommand)), std::string("OperatorCommand"));
	OperatorCommandMsg m;
	m.line = "coop_kick 3";
	Writer w;
	m.write(w);
	CHECK_EQ(w.size(), size_t(1 + 11));
	OperatorCommandMsg back;
	Reader r(w.ptr(), w.size());
	CHECK(back.read(r));
	CHECK_EQ(back.line, m.line);
	for (size_t cut = 0; cut < w.size(); ++cut)
	{
		OperatorCommandMsg t;
		Reader rc(w.ptr(), cut);
		CHECK(!t.read(rc));
	}
}
