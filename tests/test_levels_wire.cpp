// Anomaly Coop unit tests: the wire formats of the F3a messages (xrCoop/coop_levels_wire.h; plan §2.1 of
// docs/plans/2026-10-24-f3a-split-levels.md). Every format round-trips byte for byte, a cut packet is refused wherever it
// is cut, and what a reader bounds (counts, ids, enums, floats, strings) is refused at the limit and accepted at the last
// good value.
#include "test_util.h"
#include "srv/coop_journal_wire.h"
#include "coop_protocol.h"
#include "coop_spawn.h" // kMaxItemState: the bound of an ItemFacts blob
#include "srv/coop_mapserver_rules.h" // R32: where the journal and its Ack go (map_server_sends, bridge_takes)
#include "srv/coop_xfer.h" // the core's ops: every one has its wire value (levels_wire_xfer_ops_*)

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
// write() as the message has it: a bool for the formats that have a limit and can refuse, nothing for the fixed layouts
template <class M>
bool wrote(const M& m, Writer& w)
{
	if constexpr (std::is_void_v<decltype(m.write(w))>)
	{
		m.write(w);
		return true;
	}
	else
		return m.write(w);
}

template <class M>
std::vector<uint8_t> bytes_of(const M& m)
{
	Writer w;
	CHECK(wrote(m, w)); // a message of the tests is within its limits
	return w.data();
}

template <class M>
bool read_all(M& m, const std::vector<uint8_t>& b)
{
	Reader r(b.data(), b.size());
	return m.read(r) && r.remaining() == 0;
}

std::string verdict(const std::string& what, bool ok)
{
	return what + (ok ? " is read" : " is refused");
}

// The message round-trips: the expected size, read back whole, written again the same bytes; with `cuts`, every proper
// prefix of the packet is refused (a format with a free tail, cargo or a packet, has its own cut test).
template <class M>
void check_roundtrip(const std::string& what, const M& m, size_t expected_size, bool cuts = true)
{
	const std::vector<uint8_t> b = bytes_of(m);
	CHECK_EQ(what + " is " + std::to_string(b.size()) + " bytes", what + " is " + std::to_string(expected_size) + " bytes");
	M back;
	CHECK_EQ(verdict(what + " read back", read_all(back, b)), verdict(what + " read back", true));
	CHECK(bytes_of(back) == b);
	if (!cuts)
		return;
	for (size_t cut = 0; cut < b.size(); ++cut)
	{
		M part;
		Reader r(b.data(), cut);
		CHECK_EQ(verdict(what + " cut at " + std::to_string(cut), part.read(r)),
		    verdict(what + " cut at " + std::to_string(cut), false));
	}
}

// A message over a limit is not written at all: write() says no and the Writer is as it was (never a shortened message that
// a reader would take for a whole one)
template <class M>
void check_write_refused(const std::string& what, const M& m)
{
	Writer w;
	w.u8(0xAA); // what was in the writer before stays, and nothing follows it
	const bool ok = wrote(m, w);
	CHECK_EQ(what + (ok ? " is written" : " is not written"), what + " is not written");
	CHECK_EQ(what + " leaves " + std::to_string(w.size()) + " bytes", what + " leaves 1 bytes");
}

// ... and a message at the limit is written and read back whole
template <class M>
void check_write_at_limit(const std::string& what, const M& m)
{
	M back;
	CHECK_EQ(verdict(what + " at its limit", read_all(back, bytes_of(m))), verdict(what + " at its limit", true));
}

// A packet of the format, built by hand, for what the writer never produces.
template <class M>
std::string refused(const Writer& w)
{
	M m;
	Reader r(w.ptr(), w.size());
	return m.read(r) && r.remaining() == 0 ? "read" : "refused";
}

LevelMapMsg sample_map()
{
	LevelMapMsg m;
	m.flags = LevelMapMsg::Split;
	m.players = {{0, 3, kHelloRolePlayer}, {1, 3, kHelloRolePlayer}, {2, 7, kHelloRolePlayer}};
	m.servers = {{3, LevelMapMsg::MapServerProcess, uint8_t(ServerState::Ready)},
	    {7, LevelMapMsg::MapServerProcess, uint8_t(ServerState::Loading)}};
	m.gates = {{3, 0, ""}, {9, 2, "st_coop_gate_story"}};
	return m;
}

// The map as bytes: flags, then the three lists with counts that may lie.
Writer map_bytes(uint8_t flags, const std::vector<std::vector<uint8_t>>& players,
	    const std::vector<std::vector<uint8_t>>& servers, const std::vector<std::string>& gates_raw = {})
{
	Writer w;
	w.u8(flags);
	w.u8(uint8_t(players.size()));
	for (const auto& p : players)
		w.bytes(p.data(), p.size());
	w.u8(uint8_t(servers.size()));
	for (const auto& s : servers)
		w.bytes(s.data(), s.size());
	w.u8(uint8_t(gates_raw.size()));
	for (const std::string& g : gates_raw)
		w.bytes(g.data(), g.size());
	return w;
}

std::vector<uint8_t> player_row(uint32_t peer, uint16_t level, uint8_t in_world, uint16_t proxy = 500)
{
	Writer w;
	w.u32(peer);
	w.u16(level);
	w.u8(in_world);
	w.u16(proxy);
	w.u32(1000);
	return w.data();
}

std::vector<uint8_t> server_row(uint16_t level, uint8_t server, uint8_t state)
{
	Writer w;
	w.u16(level);
	w.u8(server);
	w.u8(state);
	return w.data();
}

std::string gate_row(uint16_t level, uint8_t gate, const std::string& reason)
{
	Writer w;
	w.u16(level);
	w.u8(gate);
	w.str(reason);
	return std::string(reinterpret_cast<const char*>(w.ptr()), w.size());
}
} // namespace

// ---------------------------------------------------------------------------------------------- LevelMap

TEST(levels_wire_map_roundtrip)
{
	// flags + n + 3 x (u32 + u16 + u8 + u16 + u32) + m + 2 x (u16 + u8 + u8) + g + (u16 + u8 + str "") + (u16 + u8 + str 18)
	check_roundtrip("LevelMap", sample_map(), 1 + 1 + 3 * 13 + 1 + 2 * 4 + 1 + (2 + 1 + 1) + (2 + 1 + (1 + 18)));

	LevelMapMsg empty; // nobody, no server, no gate: the shortest map
	check_roundtrip("empty LevelMap", empty, 4);

	// A player on no level yet (still loading) is a row too
	LevelMapMsg loading;
	loading.players = {{2, kNoLevel, 0, kNoObject, 0}};
	check_roundtrip("loading player", loading, 4 + 13);
}

TEST(levels_wire_map_limits)
{
	// a row per slot id: seat 0 and the client slots 1 .. 16 (a server's 16 clients, F5-SEAT-1)
	std::vector<std::vector<uint8_t>> all_slots, one_more;
	for (uint32_t p = 0; p < kMaxPeerSlots; ++p)
		all_slots.push_back(player_row(p, 1, 0));
	one_more = all_slots;
	one_more.push_back(player_row(1, 1, 0));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, all_slots, {})), std::string("read")); // kMaxPeerSlots rows
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, one_more, {})), std::string("refused"));

	std::vector<std::vector<uint8_t>> servers8, servers9;
	for (uint16_t l = 0; l < 9; ++l)
	{
		servers9.push_back(server_row(l, LevelMapMsg::MapServerProcess, 1));
		if (l < 8)
			servers8.push_back(servers9.back());
	}
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, servers8)), std::string("read")); // 8 map servers
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, servers9)), std::string("refused"));

	std::vector<std::string> gates128, gates129;
	for (uint16_t l = 0; l < 129; ++l)
	{
		gates129.push_back(gate_row(l, 1, ""));
		if (l < 128)
			gates128.push_back(gates129.back());
	}
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, gates128)), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, gates129)), std::string("refused"));

	// The writer keeps to the same limits by refusing: a map over one is not written, not cut down to a shorter one that
	// reads as a whole map (a player missing from it would be taken for gone).
	LevelMapMsg at_limit;
	for (uint32_t p = 0; p < kMaxPeerSlots; ++p)
		at_limit.players.push_back({p, 1, 1, 500, 1000});
	for (uint16_t l = 0; l < 8; ++l)
		at_limit.servers.push_back({l, uint8_t(LevelMapMsg::MapServerProcess), 1});
	for (uint16_t l = 0; l < 128; ++l)
		at_limit.gates.push_back({l, 1, ""});
	check_write_at_limit("LevelMap with 17 players, 8 servers, 128 gates", at_limit);

	LevelMapMsg over_players = at_limit;
	over_players.players.push_back({0, 1, 1, 500, 1000});
	check_write_refused("LevelMap with 18 players", over_players);
	LevelMapMsg nine_servers = at_limit;
	nine_servers.servers.push_back({8, LevelMapMsg::MapServerProcess, 1});
	check_write_refused("LevelMap with 9 servers", nine_servers);
	LevelMapMsg many_gates = at_limit;
	many_gates.gates.push_back({128, 1, ""});
	check_write_refused("LevelMap with 129 gates", many_gates);
	LevelMapMsg twenty;
	for (uint32_t p = 0; p < 20; ++p)
		twenty.players.push_back({p % 8, 1, 1, 500, 1000});
	check_write_refused("LevelMap with 20 players", twenty);
}

TEST(levels_wire_map_bad_rows)
{
	const auto ok_player = player_row(1, 4, 0);
	// flags: only the known bit; bit 2 stays reserved (the story levels together of the hybrid, build 57 and before)
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(1, {}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(2, {}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(3, {}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(4, {}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0x80, {}, {})), std::string("refused"));

	// players: a peer is a slot (< kMaxPeerSlots: slot 16 is a server's 16th client), listed once; in the world or not
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {ok_player}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(8, 4, 0)}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(16, 4, 0)}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(17, 4, 0)}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {ok_player, ok_player}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(1, 4, 2)}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(1, 4, 1)}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(1, 4, 1, kNoObject)}, {})), std::string("read")); // no character yet

	// servers: a real level, listed once; 1 map server (0 stays reserved: the host's process of the hybrid); the state is one of four
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 1, 3)})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 1, 4)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 0, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 2, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(kNoLevel, 1, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 1, 1), server_row(4, 1, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 1, 1), server_row(5, 1, 1)})), std::string("read"));

	// gates: a real level, listed once; the reason is empty or a name (it picks a string id)
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 2, "st_gate-1.x")})), std::string("read"));
	// the gate is one of T3's three (coop_levels_rules.h Gate: Free 0, BetterTogether 1, Together 2)
	for (uint8_t gate = 0; gate < 6; ++gate)
	{
		const bool want = gate <= uint8_t(coop::levels::Gate::Together);
		CHECK_EQ("gate " + std::to_string(gate) + " " + refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, gate, "")})),
		    "gate " + std::to_string(gate) + (want ? " read" : " refused"));
	}
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(kNoLevel, 1, "")})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 1, ""), gate_row(4, 2, "")})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 1, "has space")})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 1, std::string(kMaxGateReason, 'r'))})),
	    std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 1, std::string(kMaxGateReason + 1, 'r'))})),
	    std::string("refused"));

	// a failed read leaves nothing half-filled
	LevelMapMsg m = sample_map();
	Writer bad = map_bytes(0, {ok_player, ok_player}, {});
	Reader r(bad.ptr(), bad.size());
	CHECK(!m.read(r));
	CHECK(m.players.empty() && m.servers.empty() && m.gates.empty());

	// and a map with trailing bytes is not a map
	std::vector<uint8_t> b = bytes_of(sample_map());
	b.push_back(0);
	LevelMapMsg tail;
	CHECK(!read_all(tail, b));
}

// ---------------------------------------------------------------------------------------------- LevelMove, result

TEST(levels_wire_move_roundtrip)
{
	LevelMoveMsg exit;
	exit.seq = 0xA1B2C3D4u;
	exit.kind = LevelMoveMsg::Exit;
	exit.changer = 412;
	check_roundtrip("LevelMove Exit", exit, 4 + 1 + 2);

	LevelMoveMsg trip;
	trip.seq = 7;
	trip.kind = LevelMoveMsg::Trip;
	trip.graph = 1234;
	trip.node = 0x00ABCDEFu;
	trip.pos[0] = 10.5f;
	trip.pos[1] = -3.25f;
	trip.pos[2] = 440.f;
	trip.dir[0] = 0.f;
	trip.dir[1] = 0.f;
	trip.dir[2] = -1.f;
	check_roundtrip("LevelMove Trip", trip, 4 + 1 + 2 + 4 + 12 + 12);

	// the other kind's fields are not on the wire: they come back empty
	LevelMoveMsg back;
	REQUIRE(read_all(back, bytes_of(exit)));
	CHECK(back.changer == 412 && back.graph == kNoObject && back.node == kNoNode);
	LevelMoveMsg back_trip;
	REQUIRE(read_all(back_trip, bytes_of(trip)));
	CHECK(back_trip.changer == kNoObject);
	CHECK(back_trip.graph == 1234 && back_trip.node == 0x00ABCDEFu && back_trip.pos[0] == 10.5f && back_trip.dir[2] == -1.f);
}

TEST(levels_wire_move_refused)
{
	auto move_bytes = [](uint8_t kind, uint16_t id, uint32_t node, float x, float dir_x) {
		Writer w;
		w.u32(1);
		w.u8(kind);
		if (kind == 1)
			w.u16(id);
		else
		{
			w.u16(id);
			w.u32(node);
			const float pos[3] = {x, 0.f, 0.f}, dir[3] = {dir_x, 0.f, 1.f};
			w.vec3(pos);
			w.vec3(dir);
		}
		return w;
	};
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(1, 5, 0, 0, 0)), std::string("read"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(0, 5, 0, 0, 0)), std::string("refused")); // no kind 0
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(3, 5, 0, 0, 0)), std::string("refused"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(1, 0xFFFF, 0, 0, 0)), std::string("refused")); // an exit is an object
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, 1.f, 0.f)), std::string("read"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 0xFFFF, 5, 1.f, 0.f)), std::string("refused")); // a graph vertex
	// Live 2026-11-01: a stock ChangeLevel asks level.vertex_id of a point on another level and gets none. Refused here, the host
	// said nothing back and the client stayed in the dark of the route's fade.
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 0xFFFFFFFFu, 1.f, 0.f)), std::string("read"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, std::nanf(""), 0.f)), std::string("refused"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, std::numeric_limits<float>::infinity(), 0.f)), std::string("refused"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, 2.0e6f, 0.f)), std::string("refused")); // beyond any level
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, 1.f, std::nanf(""))), std::string("refused"));
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 5, 1.f, 5.0e6f)), std::string("refused"));
}

TEST(levels_wire_move_result_roundtrip)
{
	LevelMoveResultMsg go;
	go.seq = 99;
	go.verdict = LevelMoveResultMsg::Go;
	go.level = 12;
	check_roundtrip("LevelMoveResult Go", go, 4 + 1 + 1 + 2);

	LevelMoveResultMsg no;
	no.seq = 100;
	no.verdict = LevelMoveResultMsg::Refused;
	no.reason = LevelMoveResultMsg::Gate;
	no.level = 13;
	check_roundtrip("LevelMoveResult Refused", no, 8);

	// a verdict and its reason are one story: Go and Together have none, Refused always has one
	LevelMoveResultMsg together;
	together.verdict = LevelMoveResultMsg::Together;
	together.level = 4;
	check_roundtrip("LevelMoveResult Together", together, 8);
	for (uint8_t reason : {LevelMoveResultMsg::Cap, LevelMoveResultMsg::Gate, LevelMoveResultMsg::Invalid})
	{
		LevelMoveResultMsg refused_with;
		refused_with.verdict = LevelMoveResultMsg::Refused;
		refused_with.reason = reason;
		refused_with.level = 4;
		check_roundtrip("LevelMoveResult Refused " + std::to_string(reason), refused_with, 8);
	}

	for (uint8_t verdict_byte = 0; verdict_byte < 6; ++verdict_byte)
		for (uint8_t reason = 0; reason < 6; ++reason)
		{
			Writer w;
			w.u32(1);
			w.u8(verdict_byte);
			w.u8(reason);
			w.u16(3);
			const bool want = verdict_byte <= LevelMoveResultMsg::Refused && reason <= LevelMoveResultMsg::Invalid &&
			    ((verdict_byte == LevelMoveResultMsg::Refused) == (reason != LevelMoveResultMsg::None));
			CHECK_EQ("verdict " + std::to_string(verdict_byte) + " reason " + std::to_string(reason) + " " +
			        refused<LevelMoveResultMsg>(w),
			    "verdict " + std::to_string(verdict_byte) + " reason " + std::to_string(reason) + (want ? " read" : " refused"));
		}
}

// ---------------------------------------------------------------------------------------------- LevelFlush

TEST(levels_wire_flush_roundtrip)
{
	for (uint8_t why : {uint8_t(LevelFlushMsg::Save), uint8_t(LevelFlushMsg::Move), uint8_t(LevelFlushMsg::Stop),
	         uint8_t(LevelFlushMsg::HostMove)})
	{
		LevelFlushMsg m;
		m.round = 0xDEADBEEFu;
		m.why = why;
		check_roundtrip("LevelFlush why " + std::to_string(why), m, 5);
	}
	for (uint8_t why : {uint8_t(0), uint8_t(5), uint8_t(255)})
	{
		Writer w;
		w.u32(1);
		w.u8(why);
		CHECK_EQ(refused<LevelFlushMsg>(w), std::string("refused"));
	}
}

// ---------------------------------------------------------------------------------------------- Level{Snapshot,Entity}

TEST(levels_wire_snapshot_and_entity_headers_leave_the_body)
{
	// The two headers are read off the front; what follows is the layout of EntitySnapshot / Entity* / ItemState and
	// stays for its own reader.
	LevelSnapshotHead s;
	s.level = 9;
	s.round = 0; // the stream
	Writer w;
	s.write(w);
	w.u16(0xBEEF); // the body
	Reader r(w.ptr(), w.size());
	LevelSnapshotHead back;
	CHECK(back.read(r));
	CHECK(back.level == 9 && back.round == 0);
	CHECK_EQ(r.remaining(), size_t(2));
	CHECK_EQ(r.u16(), uint16_t(0xBEEF));

	check_roundtrip("LevelSnapshot head", LevelSnapshotHead{4, 77}, 2 + 4);
	LevelSnapshotHead nowhere;
	nowhere.level = kNoLevel;
	Writer wn;
	nowhere.write(wn);
	CHECK_EQ(refused<LevelSnapshotHead>(wn), std::string("refused"));

	for (uint8_t op = 0; op < 12; ++op)
	{
		Writer we;
		we.u8(op);
		LevelEntityHead e;
		Reader re(we.ptr(), we.size());
		const bool want = op <= LevelEntityHead::Logic;
		CHECK_EQ(std::string("op ") + std::to_string(op) + (e.read(re) ? " read" : " refused"),
		    std::string("op ") + std::to_string(op) + (want ? " read" : " refused"));
	}
	LevelEntityHead e;
	e.op = LevelEntityHead::Died;
	check_roundtrip("LevelEntity head", e, 1);
}

// ---------------------------------------------------------------------------------------------- LevelXferUp / Down

TEST(levels_wire_xfer_up_roundtrip_and_cargo_limit)
{
	LevelXferUpMsg m;
	m.op = LevelXferUpMsg::ReleasePrepare;
	m.id = 4321;
	m.gen = 0x01020304u;
	check_roundtrip("LevelXferUp without cargo", m, 1 + 2 + 4);

	m.cargo = t::random_bytes(300, 7);
	check_roundtrip("LevelXferUp with cargo", m, 1 + 2 + 4 + 300, false);
	LevelXferUpMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK(back.cargo == m.cargo && back.id == 4321 && back.gen == 0x01020304u);

	// the cargo is the rest of the packet; the header is not optional
	const std::vector<uint8_t> b = bytes_of(m);
	for (size_t cut = 0; cut < 7; ++cut)
	{
		LevelXferUpMsg part;
		Reader r(b.data(), cut);
		CHECK(!part.read(r));
	}

	// 32 KiB is the most a packet carries; beyond it the sender uses a blob
	LevelXferUpMsg max;
	max.id = 1;
	max.cargo.assign(kMaxXferCargo, 0xAB);
	LevelXferUpMsg max_back;
	CHECK(read_all(max_back, bytes_of(max)));
	CHECK_EQ(max_back.cargo.size(), kMaxXferCargo);
	LevelXferUpMsg over = max;
	over.cargo.push_back(0);
	Writer w;
	w.u8(over.op);
	w.u16(over.id);
	w.u32(over.gen);
	w.bytes(over.cargo.data(), over.cargo.size());
	CHECK_EQ(refused<LevelXferUpMsg>(w), std::string("refused"));
	// ... and the writer does not cut such a cargo to 32 KiB: a partial Release or Spawn would be applied as the whole one
	check_write_refused("LevelXferUp with 32 KiB + 1 of cargo", over);

	// every op of the table reads, the next does not; no id is no object
	for (uint8_t op = 0; op < 12; ++op)
	{
		Writer wo;
		wo.u8(op);
		wo.u16(5);
		wo.u32(1);
		const bool want = op <= LevelXferUpMsg::Snapshot;
		CHECK_EQ(std::string("up op ") + std::to_string(op) + " " + refused<LevelXferUpMsg>(wo),
		    std::string("up op ") + std::to_string(op) + (want ? " read" : " refused"));
	}
	Writer none;
	none.u8(0);
	none.u16(0xFFFF);
	none.u32(1);
	CHECK_EQ(refused<LevelXferUpMsg>(none), std::string("refused"));
}

TEST(levels_wire_xfer_down_roundtrip_and_cargo_limit)
{
	LevelXferDownMsg grant;
	grant.op = LevelXferDownMsg::Grant;
	grant.id = 77;
	grant.gen = 12;
	grant.cargo = t::random_bytes(1000, 3);
	LevelXferDownMsg back;
	REQUIRE(read_all(back, bytes_of(grant)));
	CHECK(back.op == LevelXferDownMsg::Grant && back.id == 77 && back.gen == 12 && back.cargo == grant.cargo);

	LevelXferDownMsg ack;
	ack.op = LevelXferDownMsg::Ack;
	ack.id = 77;
	ack.gen = 13;
	check_roundtrip("LevelXferDown Ack", ack, 1 + 2 + 4);

	LevelXferDownMsg max;
	max.id = 1;
	max.cargo.assign(kMaxXferCargo, 1);
	LevelXferDownMsg max_back;
	CHECK(read_all(max_back, bytes_of(max)));
	Writer w;
	w.u8(max.op);
	w.u16(max.id);
	w.u32(max.gen);
	std::vector<uint8_t> over(kMaxXferCargo + 1, 1);
	w.bytes(over.data(), over.size());
	CHECK_EQ(refused<LevelXferDownMsg>(w), std::string("refused"));
	// a Grant cut to 32 KiB would be applied as the whole object
	LevelXferDownMsg too_much = max;
	too_much.cargo.push_back(1);
	check_write_refused("LevelXferDown with 32 KiB + 1 of cargo", too_much);

	// the ack of a snapshot stream (and the resync request of the auditor): Snapshot, a small cargo of the sequence number
	LevelXferDownMsg snap;
	snap.op = LevelXferDownMsg::Snapshot;
	snap.id = 9;
	snap.gen = 3;
	snap.cargo = {1, 0, 0, 0};
	check_roundtrip("LevelXferDown Snapshot", snap, 1 + 2 + 4 + 4, false);
	LevelXferDownMsg snap_back;
	REQUIRE(read_all(snap_back, bytes_of(snap)));
	CHECK(snap_back.op == LevelXferDownMsg::Snapshot && snap_back.cargo == snap.cargo);

	// every op of the table reads (0..5), the next does not
	for (uint8_t op = 0; op < 9; ++op)
	{
		Writer wo;
		wo.u8(op);
		wo.u16(5);
		wo.u32(1);
		const bool want = op <= LevelXferDownMsg::Snapshot;
		CHECK_EQ(std::string("down op ") + std::to_string(op) + " " + refused<LevelXferDownMsg>(wo),
		    std::string("down op ") + std::to_string(op) + (want ? " read" : " refused"));
	}
}

// The ops of the transfer core (coop_xfer.h, T2) and their values on the wire. The core's Ledger (the world server) sends the
// ops of LevelXferDown, the Holder (the map server) the ops of LevelXferUp; Snapshot goes both ways (the map server's stream,
// the world server's ack and the resync request of the auditor). Every op of the core must have a value in the message of its
// direction: one that has none cannot be sent, and the transfer it belongs to hangs.
TEST(levels_wire_report_body_roundtrip_and_limits)
{
	LevelReportBody m;
	m.buckets = 0x80000001u;
	m.rows.push_back({7, 900});
	m.rows.push_back({70, 1});
	Writer w;
	CHECK(m.write(w));
	Reader r(w.data().data(), w.data().size());
	LevelReportBody back;
	CHECK(back.read(r));
	CHECK_EQ(back.buckets, m.buckets);
	CHECK_EQ(back.rows.size(), size_t(2));
	CHECK_EQ(back.rows[1].id, uint16_t(70));
	CHECK_EQ(back.rows[0].gen, 900u);

	LevelReportBody too_many;
	too_many.rows.resize(LevelReportBody::kMaxRows + 1);
	Writer none;
	CHECK(!too_many.write(none));
	CHECK(none.data().empty());

	Writer cut;
	cut.u32(1);
	cut.u16(2); // two rows promised, none there
	Reader short_of(cut.data().data(), cut.data().size());
	CHECK(!back.read(short_of));
	CHECK(back.rows.empty());
}

TEST(levels_wire_xfer_ops_cover_the_core)
{
	struct Row
	{
		xfer::Op core;
		bool up, down; // the directions the core sends it
		int up_wire, down_wire; // its value in LevelXferUp / LevelXferDown, -1 where it is not sent
	};
	const Row rows[] = {
		{xfer::Op::TakeReq, true, false, LevelXferUpMsg::TakeReq, -1},
		{xfer::Op::Grant, false, true, -1, LevelXferDownMsg::Grant},
		{xfer::Op::TakeCommit, true, false, LevelXferUpMsg::TakeCommit, -1},
		{xfer::Op::Done, false, true, -1, LevelXferDownMsg::Done},
		{xfer::Op::ReleasePrepare, true, false, LevelXferUpMsg::ReleasePrepare, -1},
		{xfer::Op::Ack, false, true, -1, LevelXferDownMsg::Ack},
		{xfer::Op::ReleaseCommit, true, false, LevelXferUpMsg::ReleaseCommit, -1},
		{xfer::Op::SpawnPrepare, true, false, LevelXferUpMsg::SpawnPrepare, -1},
		{xfer::Op::Destroy, true, false, LevelXferUpMsg::Destroy, -1},
		{xfer::Op::Abort, false, true, -1, LevelXferDownMsg::Abort},
		{xfer::Op::AbortAck, true, false, LevelXferUpMsg::AbortAck, -1},
		{xfer::Op::Drop, false, true, -1, LevelXferDownMsg::Drop},
		{xfer::Op::Snapshot, true, true, LevelXferUpMsg::Snapshot, LevelXferDownMsg::Snapshot},
	};
	// every op the core names is in the table (an op added to the core after Snapshot is found by its name)
	size_t named = 0;
	for (unsigned v = 0; v < 256; ++v)
	{
		const xfer::Op op = static_cast<xfer::Op>(v);
		if (std::string(xfer::op_name(op)) == "?")
			continue;
		++named;
		size_t listed = 0;
		for (const Row& r : rows)
			listed += r.core == op ? 1 : 0;
		CHECK_EQ(std::string(xfer::op_name(op)) + " is in the table " + std::to_string(listed) + " time(s)",
		    std::string(xfer::op_name(op)) + " is in the table 1 time(s)");
	}
	CHECK_EQ(named, sizeof(rows) / sizeof(rows[0]));

	// each value is read by its message and no value is used twice in a direction
	for (const Row& r : rows)
	{
		for (int dir = 0; dir < 2; ++dir)
		{
			const bool sent = dir == 0 ? r.up : r.down;
			const int wire_value = dir == 0 ? r.up_wire : r.down_wire;
			if (!sent)
				continue;
			REQUIRE(wire_value >= 0);
			Writer w;
			w.u8(uint8_t(wire_value));
			w.u16(5);
			w.u32(1);
			const std::string what = std::string(xfer::op_name(r.core)) + (dir == 0 ? " up" : " down") + " (" +
			    std::to_string(wire_value) + ")";
			CHECK_EQ(what + " " + (dir == 0 ? refused<LevelXferUpMsg>(w) : refused<LevelXferDownMsg>(w)), what + " read");
		}
		for (const Row& other : rows)
		{
			if (&other == &r)
				continue;
			CHECK(!(r.up && other.up && r.up_wire == other.up_wire));
			CHECK(!(r.down && other.down && r.down_wire == other.down_wire));
		}
	}
}

// ---------------------------------------------------------------------------------------------- LevelBrain

TEST(levels_wire_brain_roundtrip_and_limits)
{
	LevelBrainMsg m;
	m.squads = {{10, 20, 21, 1, 5000, "sim_default"}, {11, 0xFFFF, 0xFFFF, 0, 0, ""}};
	m.assigns = {{10, 30, 20}, {12, 31, 0xFFFF}};
	// u8 s + 2 squads (2+2+2+1+4 + str) + u8 a + 2 x 6
	check_roundtrip("LevelBrain", m, 1 + (11 + (1 + 11)) + (11 + 1) + 1 + 12);
	check_roundtrip("empty LevelBrain", LevelBrainMsg(), 2);

	// the scheme name of a squad is short and printable
	LevelBrainMsg longest;
	longest.squads = {{1, 2, 3, 4, 5, std::string(kMaxScripted, 's')}};
	LevelBrainMsg back;
	CHECK(read_all(back, bytes_of(longest)));
	CHECK_EQ(back.squads.at(0).scripted.size(), kMaxScripted);

	auto squad_bytes = [](const std::string& scripted) {
		Writer w;
		w.u8(1);
		w.u16(1);
		w.u16(2);
		w.u16(3);
		w.u8(0);
		w.u32(0);
		w.str(scripted);
		w.u8(0);
		return w;
	};
	CHECK_EQ(refused<LevelBrainMsg>(squad_bytes(std::string(kMaxScripted + 1, 's'))), std::string("refused"));
	CHECK_EQ(refused<LevelBrainMsg>(squad_bytes(std::string("a\nb"))), std::string("refused"));
	CHECK_EQ(refused<LevelBrainMsg>(squad_bytes(std::string("a\x01"))), std::string("refused"));
	CHECK_EQ(refused<LevelBrainMsg>(squad_bytes("sim_default")), std::string("read"));

	// a count that lies about the bytes behind it
	Writer lie;
	lie.u8(200);
	lie.u16(1);
	CHECK_EQ(refused<LevelBrainMsg>(lie), std::string("refused"));

	// the most a packet lists: 255 squads and 255 assignments
	LevelBrainMsg full;
	full.squads.assign(255, LevelBrainMsg::Squad{1, 2, 3, 0, 0, "x"});
	full.assigns.assign(255, LevelBrainMsg::Assign{1, 2, 3});
	LevelBrainMsg full_back;
	CHECK(read_all(full_back, bytes_of(full)));
	CHECK_EQ(full_back.squads.size(), size_t(255));
	CHECK_EQ(full_back.assigns.size(), size_t(255));

	// 256 of either do not fit in one packet: the sender splits them, the writer does not drop the 256th
	LevelBrainMsg many_squads = full;
	many_squads.squads.push_back(LevelBrainMsg::Squad{1, 2, 3, 0, 0, "x"});
	check_write_refused("LevelBrain with 256 squads", many_squads);
	LevelBrainMsg many_assigns = full;
	many_assigns.assigns.push_back(LevelBrainMsg::Assign{1, 2, 3});
	check_write_refused("LevelBrain with 256 assignments", many_assigns);
}

// ---------------------------------------------------------------------------------------------- LevelHash, LevelResync

TEST(levels_wire_hash_roundtrip)
{
	LevelHashMsg m;
	m.level = 5;
	m.n = 12345;
	m.set = 0x0123456789ABCDEFull;
	for (size_t i = 0; i < kHashBuckets; ++i)
		m.bucket[i] = uint32_t(i * 2654435761u);
	check_roundtrip("LevelHash", m, 2 + 4 + 8 + 32 * 4);

	LevelHashMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK(back.level == 5 && back.n == 12345 && back.set == m.set);
	for (size_t i = 0; i < kHashBuckets; ++i)
		CHECK_EQ(back.bucket[i], m.bucket[i]);

	LevelHashMsg nowhere = m;
	nowhere.level = kNoLevel;
	Writer w;
	nowhere.write(w);
	CHECK_EQ(refused<LevelHashMsg>(w), std::string("refused"));
}

TEST(levels_wire_resync_is_four_mask_bytes)
{
	LevelResyncMsg m;
	m.mask = 0x04030201u;
	check_roundtrip("LevelResync", m, 4);
	// u8 mask[4]: bucket 0 is the lowest bit of the first byte
	const std::vector<uint8_t> b = bytes_of(m);
	CHECK(b[0] == 1 && b[1] == 2 && b[2] == 3 && b[3] == 4);
	LevelResyncMsg back;
	REQUIRE(read_all(back, b));
	CHECK_EQ(back.mask, 0x04030201u);
	// 0x04030201: bits 0, 9, 16, 17, 26
	CHECK(back.wants(0) && !back.wants(1) && !back.wants(8) && back.wants(9) && back.wants(16) && back.wants(17) &&
	    back.wants(26) && !back.wants(31));
	CHECK(!back.wants(32)); // there are 32 buckets
}

// ---------------------------------------------------------------------------------------------- Tunnel

TEST(levels_wire_tunnel_roundtrip_and_refusals)
{
	// the packet inside is a whole game message: its 2-byte type, then its payload
	Writer inner;
	inner.u16(uint16_t(Msg::PlayerState));
	inner.u32(0x11223344u);

	TunnelMsg m;
	m.peer = 3;
	m.flags = 0;
	m.packet = inner.data();
	check_roundtrip("Tunnel", m, 4 + 1 + 2 + 6, false);
	TunnelMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK(back.peer == 3 && back.flags == 0 && back.packet == inner.data());
	CHECK_EQ(back.type(), Msg::PlayerState);

	TunnelMsg all;
	all.peer = 0;
	all.flags = TunnelMsg::AllOnMap;
	all.packet = inner.data();
	TunnelMsg all_back;
	CHECK(read_all(all_back, bytes_of(all)));
	CHECK(all_back.flags == TunnelMsg::AllOnMap);

	// cut anywhere before the end: the header is short, or the length no longer fits
	const std::vector<uint8_t> b = bytes_of(m);
	for (size_t cut = 0; cut < b.size(); ++cut)
	{
		TunnelMsg part;
		Reader r(b.data(), cut);
		CHECK(!part.read(r));
	}
	// a byte too many
	std::vector<uint8_t> extra = b;
	extra.push_back(0);
	TunnelMsg extra_back;
	CHECK(!read_all(extra_back, extra));

	auto tunnel_bytes = [](uint8_t flags, uint16_t type, size_t payload, uint32_t peer = 1) {
		Writer w;
		w.u32(peer);
		w.u8(flags);
		w.u16(uint16_t(2 + payload));
		w.u16(type);
		const std::vector<uint8_t> body(payload, 7);
		w.bytes(body.data(), body.size());
		return w;
	};
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4)), std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(8, uint16_t(Msg::PlayerState), 4)), std::string("refused")); // unknown flag
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(TunnelMsg::LaneUnreliable, uint16_t(Msg::PlayerState), 4)), std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(TunnelMsg::LaneBulk, uint16_t(Msg::PlayerState), 4)), std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(TunnelMsg::LaneUnreliable | TunnelMsg::LaneBulk, uint16_t(Msg::PlayerState), 4)),
	    std::string("refused")); // one lane
	// the peer is a session slot; for everybody on the map it is not looked at
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 7)), std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 8)), std::string("read")); // a world server's 8th client
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 16)), std::string("read")); // a server's 16th client
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 17)), std::string("refused"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, kInvalidPeer)), std::string("refused"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(TunnelMsg::AllOnMap, uint16_t(Msg::PlayerState), 4, kInvalidPeer)),
	    std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::Tunnel), 4)), std::string("refused")); // no tunnel in a tunnel
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::Chat), 4)), std::string("refused")); // a core message stays at the session
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::GameBase), 0)), std::string("read"));

	Writer one_byte;
	one_byte.u32(1);
	one_byte.u8(0);
	one_byte.u16(1);
	one_byte.u8(5);
	CHECK_EQ(refused<TunnelMsg>(one_byte), std::string("refused")); // not even a type
	Writer empty;
	empty.u32(1);
	empty.u8(0);
	empty.u16(0);
	CHECK_EQ(refused<TunnelMsg>(empty), std::string("refused"));

	// the biggest packet a u16 length holds
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::EntitySnapshot), 0xFFFF - 2)), std::string("read"));
	TunnelMsg biggest;
	biggest.packet.assign(0xFFFF, 0);
	biggest.packet[0] = uint8_t(uint16_t(Msg::PlayerState) & 0xFF);
	biggest.packet[1] = uint8_t(uint16_t(Msg::PlayerState) >> 8);
	check_write_at_limit("Tunnel with a packet of 65535 bytes", biggest);
	// one byte more is not a packet a u16 length can name: not written, not cut to a packet that reads as whole
	TunnelMsg too_big = biggest;
	too_big.packet.push_back(0);
	check_write_refused("Tunnel with a packet of 65536 bytes", too_big);
}

// ---------------------------------------------------------------------------------------------- MapServer*

TEST(levels_wire_map_server_state_and_order)
{
	MapServerStateMsg s;
	s.state = uint8_t(ServerState::Ready);
	s.level = 6;
	s.frame_avg_ms = 33;
	s.frame_max_ms = 180;
	s.online = 1500;
	s.mem_mb = 2200;
	check_roundtrip("MapServerState", s, 1 + 2 + 4 * 4);

	for (uint8_t state = 0; state < 7; ++state)
	{
		Writer w;
		w.u8(state);
		w.u16(6);
		for (int i = 0; i < 4; ++i)
			w.u32(1);
		const bool want = state <= uint8_t(ServerState::Stopped);
		CHECK_EQ(std::string("state ") + std::to_string(state) + " " + refused<MapServerStateMsg>(w),
		    std::string("state ") + std::to_string(state) + (want ? " read" : " refused"));
	}
	MapServerStateMsg nowhere = s;
	nowhere.level = kNoLevel;
	Writer wn;
	nowhere.write(wn);
	CHECK_EQ(refused<MapServerStateMsg>(wn), std::string("refused"));

	MapServerOrderMsg o;
	o.order = MapServerOrderMsg::Drain;
	o.level = 6;
	check_roundtrip("MapServerOrder", o, 3);
	for (uint8_t order = 0; order < 6; ++order)
	{
		Writer w;
		w.u8(order);
		w.u16(6);
		const bool want = order <= MapServerOrderMsg::Stop;
		CHECK_EQ(std::string("order ") + std::to_string(order) + " " + refused<MapServerOrderMsg>(w),
		    std::string("order ") + std::to_string(order) + (want ? " read" : " refused"));
	}
	MapServerOrderMsg order_nowhere = o;
	order_nowhere.level = kNoLevel;
	Writer wo;
	order_nowhere.write(wo);
	CHECK_EQ(refused<MapServerOrderMsg>(wo), std::string("refused"));
}

// ---------------------------------------------------------------------------------------------- LoadWait, LoadReady

TEST(levels_wire_load_wait_roundtrip_and_limits)
{
	LoadWaitMsg m;
	m.state = LoadWaitMsg::Waiting;
	m.epoch = 41;
	m.level = 8;
	m.rows = {{0, 1}, {2, 0}, {5, 1}};
	check_roundtrip("LoadWait", m, 1 + 4 + 2 + 1 + 1 + 3 * 5);
	check_roundtrip("LoadWait Enter", LoadWaitMsg{LoadWaitMsg::Enter, 42, 8, {}}, 9);
	LoadWaitMsg alone;
	alone.state = LoadWaitMsg::Prepared;
	alone.epoch = 43;
	alone.level = 9;
	alone.reason = LoadWaitMsg::HostAlone;
	check_roundtrip("LoadWait Prepared of a host who went alone", alone, 9);
	check_roundtrip("LoadWait Away", LoadWaitMsg{LoadWaitMsg::Away, 42, 8, {}}, 9);
	check_roundtrip("LoadWait Back", LoadWaitMsg{LoadWaitMsg::Back, 43, 8, {}}, 9);

	// a row of a LoadWait as the test writes it by hand
	struct WaitRow
	{
		uint32_t peer;
		uint8_t ready;
	};
	auto wait_bytes = [](uint8_t state, uint8_t count, const std::vector<WaitRow>& rows) {
		Writer w;
		w.u8(state);
		w.u32(1);
		w.u16(2);
		w.u8(LoadWaitMsg::Group);
		w.u8(count);
		for (const WaitRow& r : rows)
		{
			w.u32(r.peer);
			w.u8(r.ready);
		}
		return w;
	};
	// a row per slot id: seat 0 and the client slots 1 .. 16 (a server's 16 clients, F5-SEAT-1)
	std::vector<WaitRow> all_slots, one_more;
	for (uint32_t p = 0; p < kMaxPeerSlots; ++p)
		all_slots.push_back(WaitRow{p, 1});
	one_more = all_slots;
	one_more.push_back(WaitRow{1, 1});
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, uint8_t(kMaxPeerSlots), all_slots)), std::string("read")); // everybody in the session
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, uint8_t(kMaxPeerSlots + 1), one_more)), std::string("refused"));
	// the writer: a row of every slot is the most there is; one more is not cut away (a player missing from the list would
	// be taken for not waited for)
	LoadWaitMsg every_player;
	every_player.level = 8;
	for (uint32_t p = 0; p < kMaxPeerSlots; ++p)
		every_player.rows.push_back({p, 1});
	check_write_at_limit("LoadWait with a row for each of 17 slots", every_player);
	LoadWaitMsg over_rows = every_player;
	over_rows.rows.push_back({0, 1});
	check_write_refused("LoadWait with 18 rows", over_rows);
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 3, {{1, 1}})), std::string("refused")); // count over the bytes
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(6, 0, {})), std::string("refused")); // a state nobody knows
	Writer bad_reason;
	bad_reason.u8(0);
	bad_reason.u32(1);
	bad_reason.u16(2);
	bad_reason.u8(2);
	bad_reason.u8(0);
	CHECK_EQ(refused<LoadWaitMsg>(bad_reason), std::string("refused"));

	for (uint8_t state = 0; state < 8; ++state)
	{
		const bool want = state <= LoadWaitMsg::Back;
		CHECK_EQ(std::string("wait state ") + std::to_string(state) + " " + refused<LoadWaitMsg>(wait_bytes(state, 0, {})),
		    std::string("wait state ") + std::to_string(state) + (want ? " read" : " refused"));
	}
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{17, 1}})), std::string("refused")); // not a slot
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{16, 1}})), std::string("read")); // a server's 16th client (F5-SEAT-1)
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{8, 1}})), std::string("read")); // a world server's 8th client
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 2, {{3, 1}, {3, 0}})), std::string("refused")); // twice
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{3, 2}})), std::string("refused")); // ready is 0 or 1
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{3, 1}})), std::string("read"));
}

TEST(levels_wire_load_ready_roundtrip)
{
	LoadReadyMsg m;
	m.epoch = 0xFEDCBA98u;
	check_roundtrip("LoadReady", m, 4);
	LoadReadyMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK_EQ(back.epoch, 0xFEDCBA98u);
}

// ---------------------------------------------------------------------------------------------- blob

TEST(levels_wire_blob_kind_is_three)
{
	// BlobWorldSave is 1 (coop_join.h); the full state of a level is 3 (plan §2.1, LevelSnapshot round > 0)
	CHECK_EQ(kBlobLevelState, 3u);
}

// ---------------------------------------------------------------------------------------------- LevelJournal / Ack (protocol 34)
// TZ R32 W3 (temp/r30/design/R32-final.md sections 1 and 5): a map server's facts go up in one ordered batch, answered; the
// world server reads a batch whole before it applies any entry.

namespace
{
namespace jr = coop::levels::journal;
using Head = LevelEntityHead;

jr::ObjectHead head_of(uint16_t id, uint16_t crc, uint32_t gen = 0)
{
	jr::ObjectHead h;
	h.id = id;
	h.crc = crc;
	h.gen = gen;
	return h;
}

// an entry of a per-object op from today's LevelEntity layout (built by hand, as coop_levels_xfer.cpp writes it)
jr::Entry object_entry(uint8_t op, const jr::ObjectHead& h, const Writer& layout)
{
	jr::Entry e;
	CHECK_EQ(std::string(jr::op_name(op)) + (jr::object_entry(op, h, layout, e) ? " is made" : " is refused"),
	    std::string(jr::op_name(op)) + " is made");
	return e;
}

template <class B>
jr::Entry body_entry(uint8_t op, const B& body)
{
	jr::Entry e;
	CHECK_EQ(std::string(jr::op_name(op)) + (jr::body_entry(op, body, e) ? " is made" : " is refused"),
	    std::string(jr::op_name(op)) + " is made");
	return e;
}

// a raw entry, for what no builder makes
jr::Entry raw_entry(uint8_t op, const Writer& body)
{
	jr::Entry e;
	e.op = op;
	e.body = body.data();
	return e;
}

jr::ItemFactsBody sample_item_facts(uint16_t item)
{
	jr::ItemFactsBody f;
	f.item = item;
	f.section = "medkit";
	f.flags = 0;
	f.blob = {1, 8, 1, 3, 0}; // the ItemState blob's own version byte, then tag Uses 3
	f.source = jr::ItemFactsBody::Decider;
	return f;
}

Writer state_layout(uint16_t proxy)
{
	Writer w;
	w.u16(proxy);
	const float pos[3] = {10.f, 2.f, -30.f};
	const float ang[3] = {0.f, 1.f, 0.f};
	w.vec3(pos);
	w.vec3(ang);
	w.u32(1234);
	w.u16(77);
	LevelBodyFacts facts;
	facts.write(w);
	return w;
}

// One entry of every op a journal carries (Report is a LevelEntity of its own), with the size of its body.
struct Sample
{
	jr::Entry entry;
	size_t body;
};

std::vector<Sample> every_op()
{
	std::vector<Sample> out;
	const uint16_t crc = jr::section_crc("stalker_bandit_squad");
	{
		Writer l;
		l.u16(900);
		out.push_back({object_entry(Head::Destroy, head_of(900, crc, 3), l), 8 + 2});
	}
	{
		Writer l;
		l.u16(901);
		l.u16(17);
		const float pos[3] = {1.f, 2.f, 3.f};
		l.vec3(pos);
		out.push_back({object_entry(Head::Parent, head_of(901, crc), l), 8 + 2 + 2 + 12});
	}
	{
		Writer l;
		l.u16(902);
		l.u16(0xFFFF);
		const uint8_t st[3] = {9, 8, 7};
		l.bytes(st, 3);
		out.push_back({object_entry(Head::Died, head_of(902, crc, 5), l), 8 + 2 + 2 + 3});
	}
	out.push_back({object_entry(Head::State, head_of(903, crc), state_layout(903)), 8 + 2 + 12 + 12 + 4 + 2 + 28});
	{
		Writer l; // ItemFacts: the ItemState layout (u16 item, str section, u8 flags, varu n, blob) plus a source byte
		CHECK(sample_item_facts(904).write(l));
		out.push_back({object_entry(Head::Item, head_of(904, jr::section_crc("medkit")), l), 8 + 2 + (1 + 6) + 1 + 1 + 5 + 1});
	}
	{
		Writer l;
		l.u16(905);
		l.u16(0xFFFF);
		l.u8(1);
		l.u32(0xA5A5A5A5u);
		out.push_back({object_entry(Head::Spawn, head_of(905, crc), l), 8 + 2 + 2 + 1 + 4});
	}
	{
		Writer l;
		l.u32(3);
		l.u64(uint64_t(-250));
		l.u8(1);
		out.push_back({raw_entry(Head::Money, l), 4 + 8 + 1});
	}
	{
		Writer l;
		l.u16(906);
		l.u16(500);
		out.push_back({object_entry(Head::Tent, head_of(906, crc), l), 8 + 2 + 2});
	}
	{
		Writer l;
		l.u16(500);
		l.u8(1);
		out.push_back({object_entry(Head::Stash, head_of(500, crc), l), 8 + 2 + 1});
	}
	{
		LevelLogicBody b;
		b.id = 907;
		b.bytes = {1, 2, 3};
		Writer l;
		REQUIRE(b.write(l));
		out.push_back({object_entry(Head::Logic, head_of(907, crc), l), 8 + 2 + 2 + 3});
	}
	jr::MemberBody joined;
	joined.squad = 910;
	joined.member = 911;
	out.push_back({body_entry(Head::Joined, joined), 4});
	jr::MemberBody left = joined;
	left.member = 912;
	out.push_back({body_entry(Head::Left, left), 4});
	jr::InfoBody info;
	info.id = 911;
	info.on = 1;
	info.info = "jup_b4_said";
	out.push_back({body_entry(Head::Info, info), 2 + 1 + 1 + 11});
	jr::AskBody ask;
	ask.what = jr::AskBody::Release;
	ask.id = 913;
	ask.crc = crc;
	out.push_back({body_entry(Head::Ask, ask), 1 + 2 + 2});
	out.push_back({raw_entry(Head::IdAsk, Writer()), 0});
	jr::CarryBody carry;
	carry.part = 0;
	carry.total = 2;
	carry.blob = {'a', 'b', 'c', 'd'};
	out.push_back({body_entry(Head::Carry, carry), 2 + 2 + 4});
	jr::DoneBody done;
	done.origin = 500;
	done.op = 41;
	done.answer = "ok";
	out.push_back({body_entry(Head::Done, done), 4 + 4 + 1 + 2});
	jr::FlushedBody flushed;
	flushed.round = 12;
	out.push_back({body_entry(Head::Flushed, flushed), 4});
	return out;
}

LevelJournalMsg journal_of(uint32_t seq, const std::vector<jr::Entry>& entries)
{
	LevelJournalMsg m;
	m.seq = seq;
	m.entries = entries;
	return m;
}

// a batch as bytes, whatever its entries say
Writer batch_bytes(uint32_t seq, const std::vector<jr::Entry>& entries, uint16_t n_override = 0xFFFF)
{
	Writer w;
	w.u32(seq);
	w.u16(n_override == 0xFFFF ? uint16_t(entries.size()) : n_override);
	for (const jr::Entry& e : entries)
	{
		w.u8(e.op);
		w.varu(e.body.size());
		w.bytes(e.body.data(), e.body.size());
	}
	return w;
}

// The verdict on a batch: read whole, or refused with nothing kept.
std::string batch_verdict(const Writer& w)
{
	LevelJournalMsg m;
	m.seq = 99;
	m.entries.push_back(jr::Entry());
	Reader r(w.ptr(), w.size());
	if (m.read(r))
		return r.remaining() == 0 ? "read" : "read with bytes left";
	return m.seq == 0 && m.entries.empty() ? "refused whole" : "refused, but kept a part";
}
} // namespace

TEST(levels_wire_journal_is_protocol_34_and_its_two_messages)
{
	static_assert(kProtocolVersion >= 34u, "R32: the journal came with protocol 34");
	static_assert(uint16_t(Msg::LevelJournal) == 0x01E0 && uint16_t(Msg::LevelJournalAck) == 0x01E1, "the ids are the wire");
	CHECK_EQ(std::string(msg_name(Msg::LevelJournal)), std::string("LevelJournal"));
	CHECK_EQ(std::string(msg_name(Msg::LevelJournalAck)), std::string("LevelJournalAck"));
	// up from the bridge alone; down from the world server alone, addressed to one bridge (never a broadcast's)
	CHECK(msg_sender(Msg::LevelJournal) == MsgSender::TrunkOnly);
	CHECK(msg_sender(Msg::LevelJournalAck) == MsgSender::HostOnly);
	CHECK(scope_of(Msg::LevelJournal) == Scope::Trunk);
	CHECK(scope_of(Msg::LevelJournalAck) == Scope::Trunk);
	CHECK(mapserver::map_server_sends(Msg::LevelJournal));
	CHECK(!mapserver::bridge_takes(Msg::LevelJournal));
	CHECK(!mapserver::bridge_takes(Msg::LevelJournalAck));
}

TEST(levels_wire_journal_ops_follow_logic)
{
	// section 5: the new ops come after Logic = 10; LevelEntity itself carries today's ops alone (it stays for Report)
	static_assert(Head::Joined == 11 && Head::Left == 12 && Head::Info == 13 && Head::Ask == 14 && Head::IdAsk == 15 &&
	        Head::Carry == 16 && Head::Done == 17 && Head::Flushed == 18 && jr::kLastOp == 18,
	    "section 5: Joined = 11 .. Flushed = 18");
	for (unsigned op = 0; op < 256; ++op)
	{
		Writer w;
		w.u8(uint8_t(op));
		LevelEntityHead e;
		Reader r(w.ptr(), w.size());
		CHECK_EQ(std::string("LevelEntity op ") + std::to_string(op) + (e.read(r) ? " read" : " refused"),
		    std::string("LevelEntity op ") + std::to_string(op) + (op <= Head::Logic ? " read" : " refused"));
		const bool known = op <= 18 && op != Head::Report;
		CHECK_EQ(std::string("journal op ") + std::to_string(op) + (jr::known_op(uint8_t(op)) ? " known" : " unknown"),
		    std::string("journal op ") + std::to_string(op) + (known ? " known" : " unknown"));
		const bool object = op == Head::Destroy || op == Head::Parent || op == Head::Died || op == Head::State || op == Head::Item ||
		    op == Head::Spawn || op == Head::Tent || op == Head::Stash || op == Head::Logic;
		CHECK_EQ(std::string("journal op ") + std::to_string(op) + (jr::names_object(uint8_t(op)) ? " has a head" : " has none"),
		    std::string("journal op ") + std::to_string(op) + (object ? " has a head" : " has none"));
	}
	// every op has its own name for the logs, the rest is "?"
	std::vector<std::string> names;
	for (uint8_t op = 0; op <= jr::kLastOp; ++op)
	{
		const std::string n = jr::op_name(op);
		CHECK(n != "?");
		CHECK(std::find(names.begin(), names.end(), n) == names.end());
		names.push_back(n);
	}
	CHECK_EQ(std::string(jr::op_name(19)), std::string("?"));
}

TEST(levels_wire_journal_round_trip_of_every_op)
{
	const std::vector<Sample> samples = every_op();
	CHECK_EQ(samples.size(), size_t(18)); // 0 .. 18 but Report
	std::vector<jr::Entry> entries;
	size_t expected = 4 + 2;
	for (const Sample& s : samples)
	{
		CHECK_EQ(std::string(jr::op_name(s.entry.op)) + " body " + std::to_string(s.entry.body.size()),
		    std::string(jr::op_name(s.entry.op)) + " body " + std::to_string(s.body));
		CHECK(jr::body_ok(s.entry.op, s.entry.body));
		entries.push_back(s.entry);
		expected += 1 + 1 + s.body; // op, a one-byte varu length (every body here is under 128 bytes), the body
		// each op alone is a batch too
		check_roundtrip(std::string("journal of ") + jr::op_name(s.entry.op), journal_of(7, {s.entry}), 4 + 2 + 1 + 1 + s.body);
	}
	const LevelJournalMsg m = journal_of(0xC0FFEE01u, entries);
	CHECK(m.fits());
	CHECK_EQ(m.wire_size(), expected);
	check_roundtrip("journal of every op", m, expected);
	LevelJournalMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK_EQ(back.seq, 0xC0FFEE01u);
	REQUIRE(back.entries.size() == entries.size());
	for (size_t i = 0; i < entries.size(); ++i)
		CHECK(back.entries[i] == entries[i]);
}

TEST(levels_wire_journal_per_object_head_and_todays_layout)
{
	// A per-object entry: u16 id, u16 section crc, u32 keeper generation, then today's LevelEntity layout whole (it starts with the
	// same id), so today's readers (coop_levels_xfer.cpp host_on_level_entity) take it after the head unchanged.
	Writer l;
	l.u16(901);
	l.u16(17);
	const float pos[3] = {1.f, 2.f, 3.f};
	l.vec3(pos);
	const jr::Entry e = object_entry(Head::Parent, head_of(901, 0xBEEF, 0x01020304u), l);
	REQUIRE(e.body.size() == size_t(8 + 16));
	CHECK_EQ(int(e.body[0] | (e.body[1] << 8)), 901);
	CHECK_EQ(int(e.body[2] | (e.body[3] << 8)), 0xBEEF);
	CHECK_EQ(int(e.body[4]), 4); // the generation, little endian
	jr::ObjectHead h;
	REQUIRE(jr::object_of(e, h));
	CHECK_EQ(h.id, uint16_t(901));
	CHECK_EQ(h.crc, uint16_t(0xBEEF));
	CHECK_EQ(h.gen, 0x01020304u);
	Reader rest = jr::layout_of(e);
	CHECK_EQ(rest.remaining(), size_t(16));
	CHECK_EQ(rest.u16(), uint16_t(901)); // today's layout: item, parent, position
	CHECK_EQ(rest.u16(), uint16_t(17));
	// an op without a head has none
	jr::MemberBody mb;
	mb.squad = 1;
	mb.member = 2;
	const jr::Entry j = body_entry(Head::Joined, mb);
	CHECK(!jr::object_of(j, h));
	CHECK_EQ(jr::layout_of(j).remaining(), size_t(0));
	// the builder refuses what a reader refuses: a layout of another object, no id, a fixed layout of the wrong size
	jr::Entry out;
	Writer other;
	other.u16(902);
	other.u16(17);
	other.vec3(pos);
	CHECK(!jr::object_entry(Head::Parent, head_of(901, 1), other, out));
	CHECK(!jr::object_entry(Head::Parent, head_of(kNoObject, 1), l, out));
	Writer longer = l;
	longer.u8(0);
	CHECK(!jr::object_entry(Head::Parent, head_of(901, 1), longer, out));
	CHECK(!jr::object_entry(Head::Joined, head_of(901, 1), l, out)); // no head for a membership
	CHECK(!jr::object_entry(Head::Report, head_of(901, 1), l, out));
	CHECK(out.body.empty());
}

TEST(levels_wire_journal_section_crc)
{
	// FNV-1a 32 of the section name, its halves xor-ed: the same name is the same crc on every process of one exe
	CHECK_EQ(jr::section_crc("medkit"), jr::section_crc(std::string("medkit")));
	CHECK(jr::section_crc("medkit") != jr::section_crc("medkit_army"));
	CHECK(jr::section_crc("wpn_ak74") != jr::section_crc("wpn_ak74u"));
	CHECK_EQ(jr::section_crc(""), uint16_t((2166136261u >> 16) ^ (2166136261u & 0xFFFFu)));
	uint32_t h = 2166136261u;
	for (const char c : std::string("stalker_bandit_squad"))
		h = (h ^ uint8_t(c)) * 16777619u;
	CHECK_EQ(jr::section_crc("stalker_bandit_squad"), uint16_t((h >> 16) ^ (h & 0xFFFFu)));
}

TEST(levels_wire_journal_bodies_round_trip)
{
	jr::MemberBody mb;
	mb.squad = 910;
	mb.member = 911;
	check_roundtrip("Joined/Left", mb, 4);
	jr::InfoBody ib;
	ib.id = 911;
	ib.on = 0;
	ib.info = "esc_mechanic_flash_card";
	check_roundtrip("Info", ib, 2 + 1 + 1 + 23);
	jr::AskBody ab;
	ab.what = jr::AskBody::Release;
	ab.id = 913;
	ab.crc = 0x1234;
	check_roundtrip("Ask release", ab, 5);
	ab.what = jr::AskBody::GiveInfo;
	ab.info = "xcv_phantoms_gone";
	check_roundtrip("Ask give info", ab, 5 + 1 + 17);
	ab.what = jr::AskBody::DisableInfo;
	check_roundtrip("Ask disable info", ab, 5 + 1 + 17);
	jr::DoneBody db;
	db.origin = 0xFFFFFFFFu;
	db.op = 0;
	db.answer = "";
	check_roundtrip("Done, an empty answer", db, 4 + 4 + 1);
	db.answer = std::string(jr::DoneBody::kMaxAnswer, 'x');
	CHECK(db.fits());
	check_write_at_limit("Done at its longest answer", db);
	db.answer.push_back('x');
	check_write_refused("Done over its longest answer", db);
	jr::FlushedBody fb;
	fb.round = 0xFFFFFFFFu;
	check_roundtrip("Flushed", fb, 4);
	jr::ItemFactsBody f = sample_item_facts(904);
	check_roundtrip("ItemFacts", f, 2 + 7 + 1 + 1 + 5 + 1);
	for (uint8_t src : {uint8_t(jr::ItemFactsBody::Loot), uint8_t(jr::ItemFactsBody::Decider), uint8_t(jr::ItemFactsBody::Owner)})
	{
		f.source = src;
		jr::ItemFactsBody back;
		REQUIRE(read_all(back, bytes_of(f)));
		CHECK_EQ(back.source, src);
		CHECK(back.blob == f.blob && back.section == f.section && back.item == f.item);
	}
	// the blob bound is the ItemState's (coop_spawn.h kMaxItemState)
	static_assert(jr::ItemFactsBody::kMaxBlob == kMaxItemState, "the ItemState's bound");
	f.blob.assign(jr::ItemFactsBody::kMaxBlob, 1);
	check_write_at_limit("ItemFacts at its longest blob", f);
	f.blob.push_back(1);
	check_write_refused("ItemFacts over its longest blob", f);

	// Carry: the blob is the rest of the body, a part of `total`
	jr::CarryBody cb;
	cb.part = 1;
	cb.total = 3;
	cb.blob = {1, 2, 3};
	check_roundtrip("Carry", cb, 4 + 3, false);
	cb.blob.assign(jr::CarryBody::kMaxPart, 7);
	check_write_at_limit("Carry at its longest part", cb);
	cb.blob.push_back(7);
	check_write_refused("Carry over its longest part", cb);
	static_assert(jr::CarryBody::kMaxPart + 4 <= jr::kMaxBody, "a carry part fits an entry");
}

TEST(levels_wire_journal_bodies_refused)
{
	auto member = [](uint16_t squad, uint16_t member) {
		Writer w;
		w.u16(squad);
		w.u16(member);
		return refused<jr::MemberBody>(w);
	};
	CHECK_EQ(member(1, 2), std::string("read"));
	CHECK_EQ(member(kNoObject, 2), std::string("refused"));
	CHECK_EQ(member(1, kNoObject), std::string("refused"));
	CHECK_EQ(member(5, 5), std::string("refused")); // a squad is no member of itself

	auto info = [](uint16_t id, uint8_t on, const std::string& s) {
		Writer w;
		w.u16(id);
		w.u8(on);
		w.str(s);
		return refused<jr::InfoBody>(w);
	};
	CHECK_EQ(info(3, 1, "x"), std::string("read"));
	CHECK_EQ(info(kNoObject, 1, "x"), std::string("refused"));
	CHECK_EQ(info(3, 2, "x"), std::string("refused")); // on is 0 or 1
	CHECK_EQ(info(3, 1, ""), std::string("refused")); // no info named
	CHECK_EQ(info(3, 1, std::string("a\nb")), std::string("refused")); // not a name
	CHECK_EQ(info(3, 1, std::string(jr::InfoBody::kMaxInfo, 'a')), std::string("read"));
	CHECK_EQ(info(3, 1, std::string(jr::InfoBody::kMaxInfo + 1, 'a')), std::string("refused"));

	auto ask = [](uint8_t what, uint16_t id, const std::string* s) {
		Writer w;
		w.u8(what);
		w.u16(id);
		w.u16(0x1234);
		if (s)
			w.str(*s);
		return refused<jr::AskBody>(w);
	};
	const std::string name = "xcv_gone";
	const std::string empty;
	CHECK_EQ(ask(jr::AskBody::Release, 4, nullptr), std::string("read"));
	CHECK_EQ(ask(jr::AskBody::Release, 4, &name), std::string("refused")); // a release names no info: bytes left over
	CHECK_EQ(ask(jr::AskBody::GiveInfo, 4, &name), std::string("read"));
	CHECK_EQ(ask(jr::AskBody::GiveInfo, 4, nullptr), std::string("refused"));
	CHECK_EQ(ask(jr::AskBody::DisableInfo, 4, &empty), std::string("refused"));
	CHECK_EQ(ask(0, 4, nullptr), std::string("refused"));
	CHECK_EQ(ask(4, 4, nullptr), std::string("refused"));
	CHECK_EQ(ask(jr::AskBody::Release, kNoObject, nullptr), std::string("refused"));
	jr::AskBody a;
	a.what = jr::AskBody::Release;
	a.id = 4;
	a.info = "x"; // the writer refuses what the reader would
	check_write_refused("a release that names an info", a);
	a.what = jr::AskBody::GiveInfo;
	a.info.clear();
	check_write_refused("an info ask without its info", a);

	auto carry = [](uint16_t part, uint16_t total, size_t n) {
		Writer w;
		w.u16(part);
		w.u16(total);
		const std::vector<uint8_t> b(n, 1);
		w.bytes(b.data(), b.size());
		return refused<jr::CarryBody>(w);
	};
	CHECK_EQ(carry(0, 1, 1), std::string("read"));
	CHECK_EQ(carry(1, 1, 1), std::string("refused")); // part < total
	CHECK_EQ(carry(0, 0, 1), std::string("refused"));
	CHECK_EQ(carry(0, 1, 0), std::string("refused")); // an empty part carries nothing
	CHECK_EQ(carry(0, 1, jr::CarryBody::kMaxPart + 1), std::string("refused"));

	Writer fl;
	fl.u32(0); // round 0 is the snapshot stream, no flush round (FlushRound::start)
	CHECK_EQ(refused<jr::FlushedBody>(fl), std::string("refused"));

	auto facts = [](uint16_t item, const std::string& section, uint8_t flags, size_t n, uint8_t source) {
		Writer w;
		w.u16(item);
		w.str(section);
		w.u8(flags);
		w.varu(n);
		const std::vector<uint8_t> b(n, 1);
		w.bytes(b.data(), b.size());
		w.u8(source);
		return refused<jr::ItemFactsBody>(w);
	};
	CHECK_EQ(facts(4, "medkit", 0, 3, 0), std::string("read"));
	CHECK_EQ(facts(4, "medkit", 1, 3, 2), std::string("read")); // the authority flag of an ItemState
	CHECK_EQ(facts(kNoObject, "medkit", 0, 3, 0), std::string("refused"));
	CHECK_EQ(facts(4, "", 0, 3, 0), std::string("refused"));
	CHECK_EQ(facts(4, "med kit\t", 0, 3, 0), std::string("refused"));
	CHECK_EQ(facts(4, "medkit", 2, 3, 0), std::string("refused")); // a flag no ItemState has
	CHECK_EQ(facts(4, "medkit", 0, 0, 0), std::string("refused")); // an empty blob says nothing
	CHECK_EQ(facts(4, "medkit", 0, 3, 3), std::string("refused")); // a source none of the three
	CHECK_EQ(facts(4, "medkit", 0, jr::ItemFactsBody::kMaxBlob + 1, 0), std::string("refused"));
}

TEST(levels_wire_journal_a_malformed_batch_is_refused_whole)
{
	const std::vector<Sample> samples = every_op();
	std::vector<jr::Entry> good;
	for (const Sample& s : samples)
		good.push_back(s.entry);
	CHECK_EQ(batch_verdict(batch_bytes(5, good)), std::string("read"));

	// one bad entry in the middle: the batch goes, the good entries before it with it (a frame is applied whole or not at all)
	auto with = [&](const jr::Entry& bad) {
		std::vector<jr::Entry> v = good;
		v.insert(v.begin() + 3, bad);
		return batch_verdict(batch_bytes(5, v));
	};
	Writer none;
	CHECK_EQ(with(raw_entry(19, none)), std::string("refused whole")); // no such op
	CHECK_EQ(with(raw_entry(255, none)), std::string("refused whole"));
	{
		Writer b;
		b.u32(1);
		b.u16(0);
		CHECK_EQ(with(raw_entry(Head::Report, b)), std::string("refused whole")); // Report stays a LevelEntity of its own
	}
	{
		Writer b; // a head of no object
		head_of(kNoObject, 1).write(b);
		b.u16(kNoObject);
		CHECK_EQ(with(raw_entry(Head::Destroy, b)), std::string("refused whole"));
	}
	{
		Writer b; // the head names 900, today's layout 901
		head_of(900, 1).write(b);
		b.u16(901);
		CHECK_EQ(with(raw_entry(Head::Destroy, b)), std::string("refused whole"));
	}
	{
		Writer b; // a head and nothing after it
		head_of(900, 1).write(b);
		CHECK_EQ(with(raw_entry(Head::Spawn, b)), std::string("refused whole"));
	}
	{
		Writer b; // a destroy is its id alone
		head_of(900, 1).write(b);
		b.u16(900);
		b.u8(0);
		CHECK_EQ(with(raw_entry(Head::Destroy, b)), std::string("refused whole"));
	}
	{
		Writer b; // a cut head
		b.u16(900);
		b.u16(1);
		CHECK_EQ(with(raw_entry(Head::Died, b)), std::string("refused whole"));
	}
	{
		Writer b; // a parent without its position
		head_of(901, 1).write(b);
		b.u16(901);
		b.u16(17);
		CHECK_EQ(with(raw_entry(Head::Parent, b)), std::string("refused whole"));
	}
	{
		Writer b; // ItemFacts of another item than its head
		head_of(904, 1).write(b);
		REQUIRE(sample_item_facts(905).write(b));
		CHECK_EQ(with(raw_entry(Head::Item, b)), std::string("refused whole"));
	}
	{
		Writer b; // money with a trade byte of 2 (host_on_level_entity refuses it too)
		b.u32(3);
		b.u64(10);
		b.u8(2);
		CHECK_EQ(with(raw_entry(Head::Money, b)), std::string("refused whole"));
		Writer c; // money of no player slot
		c.u32(kMaxPeerSlots);
		c.u64(10);
		c.u8(0);
		CHECK_EQ(with(raw_entry(Head::Money, c)), std::string("refused whole"));
	}
	{
		Writer b;
		b.u16(5);
		b.u16(5);
		CHECK_EQ(with(raw_entry(Head::Joined, b)), std::string("refused whole"));
	}
	{
		Writer b;
		b.u8(0);
		CHECK_EQ(with(raw_entry(Head::IdAsk, b)), std::string("refused whole")); // an id ask has no body
	}
	{
		Writer b;
		b.u32(0);
		CHECK_EQ(with(raw_entry(Head::Flushed, b)), std::string("refused whole"));
		Writer c;
		c.u32(4);
		c.u8(0); // more than its round
		CHECK_EQ(with(raw_entry(Head::Flushed, c)), std::string("refused whole"));
	}
	{
		Writer b;
		b.u32(1);
		b.u32(2);
		b.str(std::string(jr::DoneBody::kMaxAnswer + 1, 'x'));
		CHECK_EQ(with(raw_entry(Head::Done, b)), std::string("refused whole"));
	}
	{
		jr::Entry big; // a body over kMaxBody
		big.op = Head::Carry;
		big.body.assign(jr::kMaxBody + 1, 1);
		big.body[0] = 0;
		big.body[1] = 0;
		big.body[2] = 1;
		big.body[3] = 0;
		CHECK_EQ(with(big), std::string("refused whole"));
	}

	// the batch's own fields
	CHECK_EQ(batch_verdict(batch_bytes(0, good)), std::string("refused whole")); // batches count from 1
	CHECK_EQ(batch_verdict(batch_bytes(5, {})), std::string("refused whole")); // an empty batch says nothing
	CHECK_EQ(batch_verdict(batch_bytes(5, good, uint16_t(good.size() + 1))), std::string("refused whole")); // n lies
	CHECK_EQ(batch_verdict(batch_bytes(5, good, uint16_t(jr::kMaxEntries + 1))), std::string("refused whole"));
	{
		Writer w = batch_bytes(5, {good[0]});
		w.bytes("\x05\x80", 2); // an entry's length that runs on past the packet: a cut entry
		std::vector<uint8_t> b = w.data();
		b[4] = 2; // n = 2
		Writer w2;
		w2.bytes(b.data(), b.size());
		CHECK_EQ(batch_verdict(w2), std::string("refused whole"));
	}
	{
		Writer w = batch_bytes(5, good);
		w.u8(0); // bytes after the last entry: the caller's to refuse, as for every message of this file
		CHECK_EQ(batch_verdict(w), std::string("read with bytes left"));
	}
	// a cut anywhere refuses it whole
	const Writer whole = batch_bytes(5, good);
	for (size_t cut = 0; cut < whole.size(); ++cut)
	{
		Writer w;
		w.bytes(whole.ptr(), cut);
		CHECK_EQ(std::string("cut at ") + std::to_string(cut) + ": " + batch_verdict(w),
		    std::string("cut at ") + std::to_string(cut) + ": refused whole");
	}
}

TEST(levels_wire_journal_the_writer_never_writes_what_a_reader_refuses)
{
	std::vector<jr::Entry> good;
	for (const Sample& s : every_op())
		good.push_back(s.entry);
	std::vector<jr::Entry> with_bad = good;
	Writer b;
	b.u16(5);
	b.u16(5);
	with_bad.push_back(raw_entry(Head::Joined, b));
	check_write_refused("a batch with an entry that does not read", journal_of(5, with_bad));
	check_write_refused("an empty batch", journal_of(5, {}));
	check_write_refused("a batch of seq 0", journal_of(0, good));
	check_write_refused("a batch with a Report", journal_of(5, {raw_entry(Head::Report, Writer())}));
	// over kMaxBatch bytes: not written (a frame that big goes as two batches, in order)
	jr::CarryBody cb;
	cb.total = 1;
	cb.blob.assign(jr::CarryBody::kMaxPart, 3);
	const jr::Entry part = body_entry(Head::Carry, cb);
	std::vector<jr::Entry> many;
	size_t bytes = 6;
	while (bytes <= jr::kMaxBatch)
	{
		many.push_back(part);
		bytes += 1 + 3 + part.body.size();
	}
	LevelJournalMsg huge = journal_of(5, many);
	CHECK_EQ(huge.wire_size(), bytes);
	check_write_refused("a batch over kMaxBatch", huge);
	huge.entries.pop_back();
	CHECK(huge.fits());
	check_write_at_limit("a batch under kMaxBatch", huge);
	// the entry builders refuse a body that would not read
	jr::Entry out;
	jr::FlushedBody fb;
	fb.round = 0;
	CHECK(!jr::body_entry(Head::Flushed, fb, out));
	jr::MemberBody mb;
	mb.squad = 3;
	mb.member = 4;
	CHECK(!jr::body_entry(Head::Info, mb, out)); // the layout of another op
	CHECK(!jr::body_entry(Head::Destroy, mb, out)); // a per-object op takes its head
	CHECK(out.body.empty());
}

TEST(levels_wire_journal_ack_round_trip)
{
	LevelJournalAckMsg m;
	m.upto = 7;
	m.refusals = {{5, Head::Spawn, 900, jr::IdRange}, {7, Head::Destroy, 901, jr::NotWriter}};
	m.has_block = true;
	m.first = 30000;
	m.count = 512;
	// u32 upto, u8 n, n x {u32 seq, u8 op, u16 id, u8 why}, u8 has_block, u16 first, u16 count
	check_roundtrip("LevelJournalAck", m, 4 + 1 + 2 * 8 + 1 + 2 + 2);
	LevelJournalAckMsg back;
	REQUIRE(read_all(back, bytes_of(m)));
	CHECK_EQ(back.upto, 7u);
	REQUIRE(back.refusals.size() == 2);
	CHECK_EQ(back.refusals[1].seq, 7u);
	CHECK_EQ(int(back.refusals[1].op), int(Head::Destroy));
	CHECK_EQ(back.refusals[1].id, uint16_t(901));
	CHECK_EQ(int(back.refusals[1].why), int(jr::NotWriter));
	CHECK(back.has_block && back.first == 30000 && back.count == 512);

	LevelJournalAckMsg plain; // a batch applied whole, no block
	plain.upto = 1;
	check_roundtrip("LevelJournalAck plain", plain, 4 + 1 + 1);
	// a refusal of an op with no object (Money, Done, Carry) names none
	plain.refusals = {{1, Head::Money, kNoObject, jr::Refused}};
	check_roundtrip("LevelJournalAck of a deal", plain, 4 + 1 + 8 + 1);

	// every reason has a name, and 255 refusals is the most one Ack carries
	for (uint8_t why = 1; why <= jr::kLastWhy; ++why)
		CHECK(std::string(jr::why_name(why)) != "?");
	CHECK_EQ(std::string(jr::why_name(0)), std::string("?"));
	LevelJournalAckMsg full;
	full.upto = 9;
	full.refusals.assign(LevelJournalAckMsg::kMaxRefusals, {9, Head::Destroy, 1, jr::Identity});
	check_write_at_limit("an Ack of 255 refusals", full);
	full.refusals.push_back({9, Head::Destroy, 1, jr::Identity});
	check_write_refused("an Ack of 256 refusals", full);
}

TEST(levels_wire_journal_ack_refusals)
{
	auto ack = [](uint32_t upto, uint32_t seq, uint8_t op, uint8_t why, uint8_t has_block, uint16_t first, uint16_t count) {
		Writer w;
		w.u32(upto);
		w.u8(seq ? 1 : 0);
		if (seq)
		{
			w.u32(seq);
			w.u8(op);
			w.u16(42);
			w.u8(why);
		}
		w.u8(has_block);
		if (has_block)
		{
			w.u16(first);
			w.u16(count);
		}
		return refused<LevelJournalAckMsg>(w);
	};
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, 100, 10), std::string("read"));
	CHECK_EQ(ack(0, 0, 0, 0, 0, 0, 0), std::string("refused")); // every Ack answers a batch: batches count from 1
	CHECK_EQ(ack(7, 8, Head::Destroy, jr::NotWriter, 0, 0, 0), std::string("refused")); // a refusal past what it acknowledges
	CHECK_EQ(ack(7, 0xFFFFFFFFu, Head::Destroy, jr::NotWriter, 0, 0, 0), std::string("refused"));
	CHECK_EQ(ack(7, 7, 19, jr::NotWriter, 0, 0, 0), std::string("refused")); // no such op
	CHECK_EQ(ack(7, 7, Head::Report, jr::NotWriter, 0, 0, 0), std::string("refused"));
	CHECK_EQ(ack(7, 7, Head::Destroy, 0, 0, 0, 0), std::string("refused")); // a refusal has a reason
	CHECK_EQ(ack(7, 7, Head::Destroy, uint8_t(jr::kLastWhy + 1), 0, 0, 0), std::string("refused"));
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::kLastWhy, 0, 0, 0), std::string("read"));
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 2, 100, 10), std::string("refused")); // has_block is 0 or 1
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, kNoObject, 1), std::string("refused"));
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, 100, 0), std::string("refused")); // an empty block
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, 0xFFF0, 0x10), std::string("refused")); // runs into kNoObject
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, 0xFFF0, 0x0F), std::string("read")); // the last id 0xFFFE
	CHECK_EQ(ack(7, 7, Head::Destroy, jr::NotWriter, 1, 0, 1), std::string("read"));
	// the writer refuses the same
	LevelJournalAckMsg m;
	m.upto = 0;
	check_write_refused("an Ack of upto 0", m);
	m.upto = 3;
	m.refusals = {{4, Head::Destroy, 1, jr::NotWriter}};
	check_write_refused("an Ack with a refusal past upto", m);
	m.refusals.clear();
	m.has_block = true;
	m.first = 100;
	m.count = 0;
	check_write_refused("an Ack with an empty block", m);
}
