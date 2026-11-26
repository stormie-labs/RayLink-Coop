// Runs the engine's own local_zone_release (engine/src/xrGame/coop/coop_requests.cpp, cut out by
// tests/tools/test_local_zone_release.py) over stubs of the ALife copy, the server's id generator and the lease pool. The book
// and the pool are the real ones (xrCoop/coop_local_zones.h, coop_id_lease.h).
// Report #859 (builds 56, 57): a client leaving the world (a disconnect, a rejoin, a load) got one red line per personal map zone,
// "a personal map zone N is not an offline object of ours here: left to the stock release", and then the stock release that a
// client's world call cannot make. The world that holds the zones is going: they are retired quietly.
#include "coop_local_zones.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include <vector>

using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
namespace zones = coop::zones;
namespace lease = coop::lease;

void require(bool ok, const char* reason)
{
	if (!ok)
	{
		std::fprintf(stderr, "%s\n", reason);
		std::exit(1);
	}
}

std::vector<std::string> lines; // the formats ::Msg was given
template <class... T> void Msg(const char* format, T...) { lines.push_back(format); }
bool red_line()
{
	for (const std::string& l : lines)
		if (l.rfind("! ", 0) == 0)
			return true;
	return false;
}

struct xrCriticalSection
{
};
struct xrCriticalSectionGuard
{
	explicit xrCriticalSectionGuard(xrCriticalSection&) {}
};
xrCriticalSection g_out_lock, g_quarantine_lock;

struct CSE_Abstract
{
	virtual ~CSE_Abstract() = default;
	u16 ID = 0;
};
struct CSE_ALifeDynamicObject : CSE_Abstract
{
	bool m_bOnline = false;
};
std::set<CSE_Abstract*> g_quarantine_marks;

lease::ClientPool g_pool;
zones::Book g_zones;
struct LeaseCounters
{
	u64 not_created = 0, zones_left = 0;
} g_lc;

bool world_ready = true; // lease_world_ready: a live mirror, the world up, its server there
u32 syncs = 0;
void lease_sync_world_locked() { ++syncs; }
bool lease_world_ready() { return world_ready; }
struct { bool allow() { return true; } } g_log;

CSE_ALifeDynamicObject zone; // the zone this client made (local_zone_create), registered in its ALife copy
bool registered = true;
u32 released = 0;
struct Objects
{
	CSE_ALifeDynamicObject* object(u16 id, bool) { return registered && id == zone.ID ? &zone : nullptr; }
};
struct Alife
{
	Objects objects() { return {}; }
	void release(CSE_ALifeDynamicObject* e, bool)
	{
		require(e == &zone, "only the zone is released");
		++released;
		registered = false;
	}
};
struct AI
{
	Alife alife() { return {}; }
};
AI ai() { return {}; }
Alife alife_rw() { return {}; }
namespace entities
{
struct ClientApply
{
};
} // namespace entities
struct xrServer
{
	std::set<u16> reserved; // ids the generator holds
	bool IsFreeID(u16 id) const { return reserved.count(id) == 0; }
	void PerformIDgen(u16 id) { reserved.insert(id); }
} server;
struct GameLevel
{
	xrServer* Server = &server;
};
GameLevel Level() { return {}; }

#include "local_zone_release.inc"

int main(int argc, char** argv)
{
	require(argc == 2, "scenario required");
	const std::string mode = argv[1];
	std::vector<u16> ids, rejected;
	for (u16 i = 0; i < 20; ++i)
		ids.push_back(u16(300 + i));
	g_pool.add(1, ids, [](u16 id) { server.PerformIDgen(id); return true; }, rejected);
	const u16 id = g_zones.issue(g_pool); // local_zone_create
	require(id == 300, "the zone takes the first leased id");
	zone.ID = id;
	if (mode == "ready-ours")
	{
		server.reserved.erase(id); // the release frees it in the generator
		const bool handled = local_zone_release(&zone);
		require(handled && released == 1, "a zone of ours in a ready world is released here");
		require(!g_zones.has(id) && g_pool.has(id), "its id goes back to the pool");
		require(!red_line(), "nothing to report");
	}
	else if (mode == "ready-online")
	{
		zone.m_bOnline = true;
		const bool handled = local_zone_release(&zone);
		require(!handled && released == 0, "an online object under a zone's id is left to the stock release");
		require(red_line(), "an online zone is a fault: reported");
		require(g_zones.has(id), "the book keeps it");
	}
	else if (mode == "not-ours")
	{
		CSE_ALifeDynamicObject other;
		other.ID = 9000;
		const bool handled = local_zone_release(&other);
		require(!handled && released == 0 && lines.empty(), "an object that is no zone of ours goes on as before");
	}
	else if (mode == "world-going" || mode == "world-going-gone")
	{
		// #859: the client leaves the world (a disconnect, a rejoin, a load): Personal Adjustable Waypoint lets go of its zones
		world_ready = false;
		if (mode == "world-going-gone")
			registered = false; // the old ALife is half torn down already
		const bool handled = local_zone_release(&zone);
		require(handled, "a zone of ours in a world that is going is handled here: no stock release");
		require(released == 0, "nothing is released from a world that is going");
		require(!red_line(), "no red line: the world that holds the zone is going");
		require(!g_zones.has(id) && !g_pool.has(id), "out of the book; the id goes with that world's pool");
		require(g_lc.zones_left == 1, "counted");
		require(!local_zone_release(&zone), "a second release of it is no zone of ours any more");
		require(g_lc.zones_left == 1 && !red_line(), "counted once");
	}
	else if (mode == "world-going-not-ours")
	{
		world_ready = false;
		CSE_ALifeDynamicObject other;
		other.ID = 9000;
		require(!local_zone_release(&other) && lines.empty() && g_lc.zones_left == 0, "not a zone of ours: as before");
	}
	else
		require(false, "unknown scenario");
	return 0;
}
