// Anomaly Coop unit tests: the F3a messages (split levels; docs/plans/2026-10-24-f3a-split-levels.md §2.1) in the protocol
// tables: their wire ids, names for logs and stats, who may send each one (msg_sender, checked by the Session on
// receipt), what each needs of a world (wgate::need_of), the client rows of the two a player sends, the Hello of
// protocol 11 and the version itself. The formats: test_levels_wire.cpp; the scopes: test_scope.cpp.
#include "test_util.h"
#include "coop_limits.h"
#include "coop_protocol.h"
#include "coop_world_gate.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace coop;

namespace
{
const char* f3a_sender_name(MsgSender s)
{
	switch (s)
	{
	case MsgSender::HostOnly: return "host only";
	case MsgSender::ClientOnly: return "client only";
	case MsgSender::Either: return "either";
	case MsgSender::TrunkOnly: return "trunk only";
	}
	return "?";
}

const char* f3a_need_name(wgate::Need n)
{
	switch (n)
	{
	case wgate::Need::Unclassified: return "unclassified";
	case wgate::Need::Free: return "free";
	case wgate::Need::Drop: return "drop";
	case wgate::Need::Hold: return "hold";
	}
	return "?";
}

struct F3aMsg
{
	Msg type;
	uint16_t wire;
	const char* name;
	MsgSender sender;
	wgate::Need need;
};

constexpr MsgSender kHost = MsgSender::HostOnly;
constexpr MsgSender kClient = MsgSender::ClientOnly;
constexpr MsgSender kTrunk = MsgSender::TrunkOnly;
constexpr MsgSender kEither = MsgSender::Either;
constexpr wgate::Need kFree = wgate::Need::Free;
constexpr wgate::Need kDrop = wgate::Need::Drop;
constexpr wgate::Need kHold = wgate::Need::Hold;

// F3a range 0x01D0..0x01DF (F3 has 0x01C0..0x01CF); the table of §2.1: id, name, sender, need_of.
constexpr F3aMsg kF3a[] = {
	{Msg::LevelMap, 0x01D0, "LevelMap", kHost, kFree}, // the world server -> players and map servers
	{Msg::LevelMove, 0x01D1, "LevelMove", kClient, kHold}, // a player asks to leave his level
	{Msg::LevelMoveResult, 0x01D2, "LevelMoveResult", kHost, kFree}, // the world server's answer
	{Msg::LevelFlush, 0x01D3, "LevelFlush", kHost, kFree}, // -> map server: send the full state
	{Msg::LevelSnapshot, 0x01D4, "LevelSnapshot", kTrunk, kHold}, // map server -> world server
	{Msg::LevelEntity, 0x01D5, "LevelEntity", kTrunk, kHold},
	{Msg::LevelXferUp, 0x01D6, "LevelXferUp", kTrunk, kHold},
	{Msg::LevelXferDown, 0x01D7, "LevelXferDown", kHost, kDrop}, // the world server repeats it
	{Msg::LevelBrain, 0x01D8, "LevelBrain", kHost, kDrop},
	{Msg::LevelHash, 0x01D9, "LevelHash", kTrunk, kDrop},
	{Msg::LevelResync, 0x01DA, "LevelResync", kHost, kDrop},
	{Msg::Tunnel, 0x01DB, "Tunnel", kEither, kFree}, // between the host's process and a map server, both ways
	{Msg::MapServerState, 0x01DC, "MapServerState", kTrunk, kFree},
	{Msg::MapServerOrder, 0x01DD, "MapServerOrder", kHost, kFree},
	{Msg::LoadWait, 0x01DE, "LoadWait", kHost, kFree}, // the world server -> a player on the loading screen
	{Msg::LoadReady, 0x01DF, "LoadReady", kClient, kHold}, // the same epoch is played after the world is up
};

std::string row(const F3aMsg& m, const std::string& what)
{
	return std::string(m.name) + ": " + what;
}
} // namespace

TEST(protocol_f3a_values)
{
	// The ids are the wire format: append only, never renumber.
	for (const F3aMsg& m : kF3a)
		CHECK_EQ(std::string(m.name) + " = " + std::to_string(static_cast<uint16_t>(m.type)),
		    std::string(m.name) + " = " + std::to_string(m.wire));
}

TEST(protocol_f3a_sixteen_messages_fill_the_range)
{
	CHECK_EQ(sizeof(kF3a) / sizeof(kF3a[0]), size_t(16));
	// 0x01D0..0x01DF in a row, none missing, none doubled
	for (uint16_t id = 0x01D0; id <= 0x01DF; ++id)
	{
		char hex[16];
		std::snprintf(hex, sizeof(hex), "0x%04X", unsigned(id));
		const bool named = std::strncmp(msg_name(id), "Msg_0x", 6) != 0;
		CHECK_EQ(std::string(hex) + (named ? " is named" : " has no name"), std::string(hex) + " is named");
	}
	// the neighbours are not ours: F3 ends at 0x01C6, the range after the F3a one is free
	CHECK(std::strncmp(msg_name(uint16_t(0x01E0)), "Msg_0x", 6) == 0);
	CHECK(std::strncmp(msg_name(uint16_t(0x01CF)), "Msg_0x", 6) == 0);
	CHECK(std::strncmp(msg_name(Msg::NewCharacter), "Msg_0x", 6) != 0);
}

TEST(protocol_f3a_names)
{
	for (const F3aMsg& m : kF3a)
		CHECK_EQ(std::string(msg_name(m.type)), std::string(m.name));
}

TEST(protocol_f3a_senders)
{
	for (const F3aMsg& m : kF3a)
		CHECK_EQ(row(m, f3a_sender_name(msg_sender(m.type))), row(m, f3a_sender_name(m.sender)));
}

TEST(protocol_f3a_trunk_only_is_a_new_kind_of_sender)
{
	// MsgSender::TrunkOnly: sent by the bridge of a map server alone (a message from anybody else is a kick, T9)
	CHECK(MsgSender::TrunkOnly != MsgSender::Either);
	CHECK(MsgSender::TrunkOnly != MsgSender::HostOnly);
	CHECK(MsgSender::TrunkOnly != MsgSender::ClientOnly);
	int trunk_only = 0;
	for (const F3aMsg& m : kF3a)
		trunk_only += msg_sender(m.type) == MsgSender::TrunkOnly ? 1 : 0;
	CHECK_EQ(trunk_only, 5); // LevelSnapshot, LevelEntity, LevelXferUp, LevelHash, MapServerState
	// no older message changed its direction
	CHECK(msg_sender(Msg::EntitySpawn) == MsgSender::HostOnly);
	CHECK(msg_sender(Msg::ReqTake) == MsgSender::ClientOnly);
	CHECK(msg_sender(Msg::PlayerState) == MsgSender::Either);
	CHECK(msg_sender(Msg::NewCharacter) == MsgSender::ClientOnly);
}

TEST(protocol_f3a_world_gate_needs)
{
	// Free: works without a world; Hold: a request or a delta, waits for the world on the host; Drop: void without it.
	for (const F3aMsg& m : kF3a)
		CHECK_EQ(row(m, f3a_need_name(wgate::need_of(m.type))), row(m, f3a_need_name(m.need)));
}

TEST(protocol_f3a_client_rate_rows)
{
	// The two a player sends are limited like the other requests: 4 in a row, then one per second.
	for (Msg m : {Msg::LevelMove, Msg::LoadReady})
	{
		const limits::RateRule* rule = limits::client_rule(m);
		REQUIRE(rule != nullptr);
		CHECK_EQ(rule->burst, 4u);
		CHECK_EQ(rule->refill_ms, 1000u);
	}
	// nothing else of the sixteen has a row: the rest is sent by the host or the bridge (a row for a message that a client
	// never sends would be dead, and the session would kick the sender first)
	for (const F3aMsg& m : kF3a)
	{
		const bool has = limits::client_rule(m.type) != nullptr;
		const bool want = m.type == Msg::LevelMove || m.type == Msg::LoadReady;
		CHECK_EQ(row(m, has ? "has a rate row" : "has none"), row(m, want ? "has a rate row" : "has none"));
	}
}

TEST(protocol_f3a_version_is_11)
{
	// 11: the F3a messages, Hello carries a role and a token, PlayerState carries the vertices, TransitionState a flags
	// byte, WeatherSync a weather set; a protocol 10 peer is refused at the handshake.
	CHECK_EQ(kProtocolVersion, 11u);
}

TEST(protocol_f3a_hello_carries_a_role_and_a_token)
{
	HelloMsg h;
	// a player's Hello: role 0, no token
	CHECK_EQ(int(h.role), int(kHelloRolePlayer));
	for (const uint8_t b : h.token)
		CHECK_EQ(int(b), 0);
	h.build_id = "build-xyz";
	h.content_fp = 0x1122334455667788ull;
	for (size_t i = 0; i < h.key.size(); ++i)
		h.key[i] = uint8_t(i + 1);
	h.nick = "Mk";
	Writer player;
	h.write(player);

	// a map server's: role 1 and the token the host's process gave it on the command line
	h.role = kHelloRoleMapServer;
	for (size_t i = 0; i < kHelloTokenSize; ++i)
		h.token[i] = uint8_t(0xA0 + i);
	Writer server;
	h.write(server);
	CHECK_EQ(server.size(), player.size()); // fixed size: role byte and 16 token bytes either way

	HelloMsg back;
	Reader r(server.ptr(), server.size());
	CHECK(back.read(r));
	CHECK_EQ(r.remaining(), size_t(0));
	CHECK_EQ(int(back.role), int(kHelloRoleMapServer));
	CHECK(std::memcmp(back.token, h.token, kHelloTokenSize) == 0);
	CHECK(back.build_id == "build-xyz" && back.nick == "Mk" && back.content_fp == h.content_fp && back.key == h.key);
	CHECK_EQ(back.protocol, kProtocolVersion);

	// the tail is 17 bytes after the nick: u8 role + u8 token[16]
	Writer old_layout; // protocol 10
	old_layout.u32(10);
	old_layout.str(h.build_id);
	old_layout.u64(h.content_fp);
	old_layout.bytes(h.key.data(), h.key.size());
	old_layout.str(h.nick);
	CHECK_EQ(server.size(), old_layout.size() + 17);
	HelloMsg from_old;
	Reader ro(old_layout.ptr(), old_layout.size());
	CHECK(!from_old.read(ro)); // a protocol 10 Hello has no role: the session answers it with ProtocolMismatch first

	// cut inside the token or before the role
	for (size_t cut = server.size() - 17; cut < server.size(); ++cut)
	{
		HelloMsg part;
		Reader rc(server.ptr(), cut);
		CHECK(!part.read(rc));
	}

	// an unknown role is not read
	Writer unknown;
	h.write(unknown);
	std::vector<uint8_t> bytes = unknown.data();
	bytes[bytes.size() - 17] = 2;
	HelloMsg bad;
	Reader rb(bytes.data(), bytes.size());
	CHECK(!bad.read(rb));
}
