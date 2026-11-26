// Runs the production script relay over session and transport stubs.
// A map server's event to everybody (target -1) reaches the players only, each with his own copy (origin 0, his id as the
// target, what the map server's own flush_outbox would have sent), never the other map servers; a player's and the host
// player's event to everybody, a map server's event to one player, to the world and to another map server are unchanged.
#include "xrCoop/coop_lua_errors.h"
#include "xrCoop/coop_protocol.h"
#include "xrCoop/coop_wire.h"

#include <atomic>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

// X-Ray's PCH gives these types to the engine's units that include coop_script.h.
using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using s32 = int32_t;
using s64 = int64_t;
using LPCSTR = const char*;
using xr_string = std::string;
#include "xrGame/coop/coop_script.h"

#define CHECK(condition)                                                                                                      \
	do                                                                                                                        \
	{                                                                                                                         \
		if (!(condition))                                                                                                     \
		{                                                                                                                     \
			std::cerr << "line " << __LINE__ << ": " << #condition << '\n';                                                   \
			std::exit(1);                                                                                                     \
		}                                                                                                                     \
	} while (0)

void Msg(const char*, ...) {}

namespace coop
{
constexpr PeerId kGuest = 1;
constexpr PeerId kListener = 2;
constexpr PeerId kBridge = 0x101;
constexpr PeerId kOtherBridge = 0x102;

// What the relay reads of a player row (xrCoop/coop_session.h PeerInfo).
struct PeerInfo
{
	PeerId id = kInvalidPeer;
};

// The world server's session: players (rows) and the map servers' bridges (joined connections without a row).
class Session
{
public:
	bool host_plays = false; // the co-op host's process: the host player over the internal channel
	std::vector<PeerId> players{kGuest, kListener};
	std::vector<PeerId> bridges{kBridge, kOtherBridge};

	const PeerInfo* peer(PeerId id) const
	{
		for (const PeerInfo& p : m_rows)
			if (p.id == id)
				return &p;
		return nullptr;
	}
	std::vector<PeerInfo> peers() const { return m_rows; }
	const PeerId* local() const { return host_plays ? &kHostPeer : nullptr; }
	bool joined(PeerId id) const
	{
		if (peer(id))
			return true;
		for (const PeerId b : bridges)
			if (b == id)
				return true;
		return false;
	}
	void sync_rows()
	{
		m_rows.clear();
		for (const PeerId id : players)
			m_rows.push_back(PeerInfo{id});
	}

private:
	std::vector<PeerInfo> m_rows;
};

struct Manager
{
	Session session_data;
	const Session& session() const { return session_data; }
	bool is_client() const { return false; }
	u64 now_ms() const { return 1000; }
};
Manager& mgr()
{
	static Manager manager;
	return manager;
}

namespace sync
{
bool host_peer_joining(PeerId) { return false; }
}

namespace net
{
// One send of the world server: to one peer (host_send), or to everybody the mode's delivery reaches (host_broadcast: on a
// world server the players and every map server's bridge, srv/coop_srv_mode.cpp WorldServerMode::deliver).
struct Delivery
{
	std::vector<uint8_t> bytes;
	std::optional<PeerId> to;
	std::optional<PeerId> except;
};
std::vector<Delivery> deliveries;

void host_broadcast(Msg kind, const Writer& wire, Lane lane, PeerId except)
{
	CHECK(kind == Msg::ScriptEvent && lane == Lane::Reliable);
	deliveries.push_back({wire.data(), std::nullopt, except});
}
void host_send(PeerId to, Msg kind, const Writer& wire)
{
	CHECK(kind == Msg::ScriptEvent);
	deliveries.push_back({wire.data(), to, std::nullopt});
}
} // namespace net

namespace script
{
namespace
{
constexpr size_t kMaxPayload = 16 * 1024;
constexpr size_t kMaxInbox = 4096;
constexpr size_t kMaxInboxBytes = 4 * 1024 * 1024;
constexpr s32 kTargetAll = -1;

bool decides_world() { return true; } // The relay scenarios run on the world's decider in both modes.

#include "script_relay_types.inc"

Stats g_stats;
WorldEventReservations g_world_events;
std::deque<Incoming> g_inbox;
size_t g_inbox_bytes = 0;
u32 g_lost_events = 0;
std::atomic<u64> g_tick{0};
} // namespace

#include "script_relay_methods.inc"

namespace
{
constexpr char kName[] = "mods.nim_held";
const std::string kPayload("p=1\0h=1:7:1", 11);

void ingress(PeerId sender, s32 target, const std::string& name = kName, PeerId claimed_origin = kHostPeer)
{
	Writer wire;
	wire.u32(claimed_origin);
	wire.i32(target);
	wire.str(name);
	wire.str(kPayload);
	Reader reader(wire.ptr(), wire.size());
	server_on_script_event(sender, reader);
}

// the i-th send: to `to` (nullopt: a broadcast except `except`), with this origin and target on the wire
void check_send(size_t i, std::optional<PeerId> to, std::optional<PeerId> except, PeerId origin, s32 target,
    const std::string& name = kName)
{
	CHECK(i < net::deliveries.size());
	const net::Delivery& sent = net::deliveries[i];
	CHECK(sent.to == to);
	CHECK(sent.except == except);
	Reader reader(sent.bytes.data(), sent.bytes.size());
	CHECK(reader.u32() == origin);
	CHECK(reader.i32() == target);
	CHECK(reader.str() == name);
	CHECK(reader.str() == kPayload);
	CHECK(reader.ok() && reader.remaining() == 0);
}

bool broadcast_sent()
{
	for (const net::Delivery& d : net::deliveries)
		if (!d.to)
			return true;
	return false;
}

bool sent_to(PeerId id)
{
	for (const net::Delivery& d : net::deliveries)
		if (d.to == id)
			return true;
	return false;
}

void check_world_lua(size_t n, PeerId from)
{
	CHECK(g_inbox.size() == n);
	if (n)
		CHECK(g_inbox.back().from == from && g_inbox.back().name == kName && g_inbox.back().payload == kPayload);
}
} // namespace

int run(std::string_view scenario)
{
	mgr().session_data.sync_rows();
	if (scenario == "bridge-broadcast")
	{
		// a map server's "everybody": each player his own copy as the world's word, the world's Lua the bridge's, no broadcast
		ingress(kBridge, -1, kName, kGuest);
		CHECK(!broadcast_sent());
		CHECK(net::deliveries.size() == 2);
		check_send(0, kGuest, std::nullopt, kHostPeer, s32(kGuest));
		check_send(1, kListener, std::nullopt, kHostPeer, s32(kListener));
		CHECK(!sent_to(kOtherBridge) && !sent_to(kBridge));
		check_world_lua(1, kBridge);
		CHECK(g_stats.received == 1 && g_stats.relayed == 2 && g_stats.drop_world_only == 0);
	}
	else if (scenario == "bridge-broadcast-no-players")
	{
		mgr().session_data.players.clear();
		mgr().session_data.sync_rows();
		ingress(kBridge, -1);
		CHECK(net::deliveries.empty());
		check_world_lua(1, kBridge);
	}
	else if (scenario == "bridge-reserved-broadcast")
	{
		// a reserved name stays dropped whole, before the relay (A-RELAY)
		CHECK(g_world_events.reserve(kName, sizeof(kName) - 1));
		ingress(kBridge, -1);
		CHECK(net::deliveries.empty());
		check_world_lua(0, kBridge);
		CHECK(g_stats.drop_world_only == 1 && g_stats.received == 0);
	}
	else if (scenario == "bridge-to-player")
	{
		ingress(kBridge, s32(kListener), kName, kGuest);
		CHECK(net::deliveries.size() == 1);
		check_send(0, kListener, std::nullopt, kHostPeer, s32(kListener));
		check_world_lua(0, kBridge);
	}
	else if (scenario == "bridge-to-world")
	{
		ingress(kBridge, s32(kHostPeer));
		CHECK(net::deliveries.empty());
		check_world_lua(1, kBridge);
	}
	else if (scenario == "bridge-to-bridge")
	{
		// another map server is no player: no way there
		ingress(kBridge, s32(kOtherBridge));
		CHECK(net::deliveries.empty());
		check_world_lua(0, kBridge);
		CHECK(g_stats.drop_invalid == 1);
	}
	else if (scenario == "player-broadcast")
	{
		// a player's "everybody" is unchanged: the mode's broadcast (the players and the bridges), his own id as the origin
		ingress(kGuest, -1, kName, kHostPeer);
		CHECK(net::deliveries.size() == 1);
		check_send(0, std::nullopt, kGuest, kGuest, -1);
		check_world_lua(1, kGuest);
	}
	else if (scenario == "coop-host-broadcast")
	{
		// the co-op host player's own event to everybody: a broadcast past him, not back to his Lua
		mgr().session_data.host_plays = true;
		mgr().session_data.bridges.clear();
		ingress(kHostPeer, -1, kName, kGuest);
		CHECK(net::deliveries.size() == 1);
		check_send(0, std::nullopt, kHostPeer, kHostPeer, -1);
		check_world_lua(0, kHostPeer);
	}
	else if (scenario == "coop-guest-broadcast")
	{
		mgr().session_data.host_plays = true;
		mgr().session_data.bridges.clear();
		ingress(kGuest, -1, kName, kHostPeer);
		CHECK(net::deliveries.size() == 1);
		check_send(0, std::nullopt, kGuest, kGuest, -1);
		check_world_lua(1, kGuest);
	}
	else
		return 2;
	return 0;
}
} // namespace script
} // namespace coop

int main(int argc, char** argv) { return argc == 2 ? coop::script::run(argv[1]) : 2; }
