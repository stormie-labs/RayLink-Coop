// Anomaly Coop unit tests: the wire formats of the F3a messages (xrCoop/coop_levels_wire.h; plan §2.1 of
// docs/plans/2026-10-24-f3a-split-levels.md). Every format round-trips byte for byte, a cut packet is refused wherever it
// is cut, and what a reader bounds (counts, ids, enums, floats, strings) is refused at the limit and accepted at the last
// good value.
#include "test_util.h"
#include "coop_levels_wire.h"
#include "coop_protocol.h"

#include <cmath>
#include <limits>
#include <string>
#include <vector>

using namespace coop;
using namespace coop::levels::wire;

namespace
{
template <class M>
std::vector<uint8_t> bytes_of(const M& m)
{
	Writer w;
	m.write(w);
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
	m.flags = LevelMapMsg::Split | LevelMapMsg::StoryTogether;
	m.players = {{0, 3, kHelloRolePlayer}, {1, 3, kHelloRolePlayer}, {2, 7, kHelloRolePlayer}};
	m.servers = {{3, LevelMapMsg::HostProcess, uint8_t(ServerState::Ready)},
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

std::vector<uint8_t> player_row(uint32_t peer, uint16_t level, uint8_t role)
{
	Writer w;
	w.u32(peer);
	w.u16(level);
	w.u8(role);
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
	// flags + n + 3 x (u32 + u16 + u8) + m + 2 x (u16 + u8 + u8) + g + (u16 + u8 + str "") + (u16 + u8 + str 18)
	check_roundtrip("LevelMap", sample_map(), 1 + 1 + 3 * 7 + 1 + 2 * 4 + 1 + (2 + 1 + 1) + (2 + 1 + (1 + 18)));

	LevelMapMsg empty; // nobody, no server, no gate: the shortest map
	check_roundtrip("empty LevelMap", empty, 4);

	// A player on no level yet (still loading) is a row too
	LevelMapMsg loading;
	loading.players = {{2, kNoLevel, kHelloRolePlayer}};
	check_roundtrip("loading player", loading, 4 + 7);
}

TEST(levels_wire_map_limits)
{
	std::vector<std::vector<uint8_t>> eight, nine;
	for (uint32_t p = 0; p < 9; ++p)
		(p < 8 ? eight : nine).push_back(player_row(p, 1, kHelloRolePlayer));
	nine.insert(nine.begin(), eight.begin(), eight.end());
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, eight, {})), std::string("read")); // kMaxPlayers rows
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, nine, {})), std::string("refused"));

	std::vector<std::vector<uint8_t>> servers8, servers9;
	for (uint16_t l = 0; l < 9; ++l)
	{
		// one host process at the most: the rest are map servers
		servers9.push_back(server_row(l, l == 0 ? LevelMapMsg::HostProcess : LevelMapMsg::MapServerProcess, 1));
		if (l < 8)
			servers8.push_back(servers9.back());
	}
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, servers8)), std::string("read")); // the host + 7 map servers
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

	// the writer keeps to the limits too: 12 players of a bad caller go out as 8
	LevelMapMsg big;
	for (uint32_t p = 0; p < 12; ++p)
		big.players.push_back({p % 8, 1, kHelloRolePlayer});
	LevelMapMsg back;
	CHECK(read_all(back, bytes_of(big)));
	CHECK_EQ(back.players.size(), size_t(8));
}

TEST(levels_wire_map_bad_rows)
{
	const auto ok_player = player_row(1, 4, kHelloRolePlayer);
	// flags: only the two known bits
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(3, {}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(4, {}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0x80, {}, {})), std::string("refused"));

	// players: a peer is a slot (< kMaxPlayers), listed once; the role is a Hello role
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {ok_player}, {})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(8, 4, 0)}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {ok_player, ok_player}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(1, 4, 2)}, {})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {player_row(1, 4, kHelloRoleMapServer)}, {})), std::string("read"));

	// servers: a real level, listed once; 0 host process (one), 1 map server; the state is one of four
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 0, 3)})), std::string("read"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 0, 4)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 2, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(kNoLevel, 1, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 1, 1), server_row(4, 1, 1)})), std::string("refused"));
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 0, 1), server_row(5, 0, 1)})),
	    std::string("refused")); // two host processes
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {server_row(4, 0, 1), server_row(5, 1, 1)})), std::string("read"));

	// gates: a real level, listed once; the reason is empty or a name (it picks a string id)
	CHECK_EQ(refused<LevelMapMsg>(map_bytes(0, {}, {}, {gate_row(4, 9, "st_gate-1.x")})), std::string("read"));
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
	CHECK_EQ(refused<LevelMoveMsg>(move_bytes(2, 9, 0xFFFFFFFFu, 1.f, 0.f)), std::string("refused")); // a level vertex
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

	for (uint8_t verdict_byte = 0; verdict_byte < 6; ++verdict_byte)
		for (uint8_t reason = 0; reason < 6; ++reason)
		{
			Writer w;
			w.u32(1);
			w.u8(verdict_byte);
			w.u8(reason);
			w.u16(3);
			const bool want = verdict_byte <= LevelMoveResultMsg::Refused && reason <= LevelMoveResultMsg::Invalid;
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

	for (uint8_t op = 0; op < 8; ++op)
	{
		Writer we;
		we.u8(op);
		LevelEntityHead e;
		Reader re(we.ptr(), we.size());
		const bool want = op <= LevelEntityHead::Item;
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

	for (uint8_t op = 0; op < 9; ++op)
	{
		Writer wo;
		wo.u8(op);
		wo.u16(5);
		wo.u32(1);
		const bool want = op <= LevelXferDownMsg::Drop;
		CHECK_EQ(std::string("down op ") + std::to_string(op) + " " + refused<LevelXferDownMsg>(wo),
		    std::string("down op ") + std::to_string(op) + (want ? " read" : " refused"));
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
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(2, uint16_t(Msg::PlayerState), 4)), std::string("refused")); // unknown flag
	// the peer is a session slot; for everybody on the map it is not looked at
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 7)), std::string("read"));
	CHECK_EQ(refused<TunnelMsg>(tunnel_bytes(0, uint16_t(Msg::PlayerState), 4, 8)), std::string("refused"));
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
	TunnelMsg too_big;
	too_big.packet.assign(0x10000, 0);
	too_big.packet[0] = uint8_t(uint16_t(Msg::PlayerState) & 0xFF);
	too_big.packet[1] = uint8_t(uint16_t(Msg::PlayerState) >> 8);
	TunnelMsg too_big_back;
	CHECK(read_all(too_big_back, bytes_of(too_big))); // the writer keeps to what a u16 length holds, length and bytes alike
	CHECK_EQ(too_big_back.packet.size(), size_t(0xFFFF));
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
	check_roundtrip("LoadWait", m, 1 + 4 + 2 + 1 + 3 * 5);
	check_roundtrip("LoadWait Enter", LoadWaitMsg{LoadWaitMsg::Enter, 42, 8, {}}, 8);

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
		w.u8(count);
		for (const WaitRow& r : rows)
		{
			w.u32(r.peer);
			w.u8(r.ready);
		}
		return w;
	};
	std::vector<WaitRow> eight, nine;
	for (uint32_t p = 0; p < 9; ++p)
		(p < 8 ? eight : nine).push_back(WaitRow{p, 1});
	nine.insert(nine.begin(), eight.begin(), eight.end());
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 8, eight)), std::string("read")); // everybody in the session
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 9, nine)), std::string("refused"));
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 3, {{1, 1}})), std::string("refused")); // count over the bytes

	for (uint8_t state = 0; state < 7; ++state)
	{
		const bool want = state <= LoadWaitMsg::Cancel;
		CHECK_EQ(std::string("wait state ") + std::to_string(state) + " " + refused<LoadWaitMsg>(wait_bytes(state, 0, {})),
		    std::string("wait state ") + std::to_string(state) + (want ? " read" : " refused"));
	}
	CHECK_EQ(refused<LoadWaitMsg>(wait_bytes(1, 1, {{8, 1}})), std::string("refused")); // not a slot
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
