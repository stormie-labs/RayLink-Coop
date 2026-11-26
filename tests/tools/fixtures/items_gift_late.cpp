// Runs the engine's own host_track_proxies, host_push and late_report_of_gift (engine/src/xrGame/coop/coop_items.cpp, cut out by
// tests/tools/test_items_gift_late.py) over stubs of the ALife copy and the item state capture.
// The giver's last ItemState of an item he has just given to another player (or to the co-op host's player) arrives after the
// gift: host_access says Denied, and builds 55-58 printed "! item state from peer N for N refused: not owner" - an automatic
// error report of a gift that went right. The item left his character within kGraceMs (g_left) or in this very frame (his
// g_proxy_items list still has it): his report is dropped silently and counted. The giver's g_left entry must survive the
// recipient's host_push whatever order the peers' slots are walked in.
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <string>
#include <vector>

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using PeerId = uint32_t;
constexpr u16 kNoId = 65535;
constexpr PeerId kInvalidPeer = 0xFFFFFFFFu;
constexpr u32 kMaxPeerSlots = 5;
constexpr u32 kGraceMs = 3000;
constexpr u8 kFlagAuthority = 1;
template <class T> using xr_vector = std::vector<T>;
template <class T> using xr_set = std::set<T>;
template <class K, class V> using xr_map = std::map<K, V>;
template <class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }

void require(bool ok, const char* reason)
{
	if (!ok)
	{
		std::fprintf(stderr, "%s\n", reason);
		std::exit(1);
	}
}

struct CSE_Abstract
{
	virtual ~CSE_Abstract() = default;
	u16 ID = 0;
};
struct CSE_ALifeInventoryItem : CSE_Abstract
{
};
struct CSE_ALifeDynamicObject : CSE_Abstract
{
	xr_vector<u16> children;
};
struct CInventoryItem
{
	u16 id = 0;
};
struct ItemData
{
	u32 condition = 0;
};
struct Blob
{
};

// the world: two players' characters and one item
std::map<u16, CSE_ALifeDynamicObject> characters; // proxy -> its server object
std::map<PeerId, u16> proxies; // peer -> his character
CSE_ALifeInventoryItem gun;
CInventoryItem gun_item;
u64 clock_ms = 0;
u32 pushes_sent = 0;

struct Manager
{
	u64 now_ms() const { return clock_ms; }
};
Manager mgr() { return {}; }
namespace join
{
u16 proxy_of_peer(PeerId peer)
{
	const auto it = proxies.find(peer);
	return it == proxies.end() ? kNoId : it->second;
}
} // namespace join
namespace sync
{
bool host_peer_joining(PeerId) { return false; }
} // namespace sync
struct Objects
{
	CSE_ALifeDynamicObject* object(u16 id, bool)
	{
		const auto it = characters.find(id);
		return it == characters.end() ? nullptr : &it->second;
	}
};
struct Alife
{
	Objects objects() { return {}; }
};
struct AI
{
	Alife alife() { return {}; }
};
AI ai() { return {}; }
namespace world { CSE_Abstract* alife_entity(u16 id) { return id == gun.ID ? &gun : nullptr; } }
CInventoryItem* find_item(u16 id) { return id == gun.ID ? &gun_item : nullptr; }
void capture_object(CInventoryItem*, ItemData& d, bool = true) { d.condition = 1; }
bool capture_entity(CSE_Abstract*, ItemData& d, bool = true)
{
	d.condition = 1;
	return true;
}
namespace ledger
{
void host_keeps_own_upgrades(ItemData&) {}
} // namespace ledger
void host_send_view(u16, CSE_Abstract*, CInventoryItem*, const Blob*, u8, PeerId) { ++pushes_sent; }

struct Owned
{
	PeerId peer = kInvalidPeer;
	ItemData data;
	bool stuck = false;
};
xr_map<u16, Owned> g_owned;
struct Left
{
	PeerId peer = kInvalidPeer;
	u64 time = 0;
};
xr_map<u16, Left> g_left;
struct ProxyItems
{
	xr_vector<u16> children;
	xr_vector<u16> sorted;
};
xr_map<u16, ProxyItems> g_proxy_items;
xr_vector<u16> g_track_sorted;
struct Stream
{
	u32 stream = 0;
	u32 seq = 0;
};
xr_map<PeerId, Stream> g_streams;
struct Stats
{
	u64 pushed = 0;
} g_stats;

#include "items_gift_late.inc"

void hold(u16 proxy, std::initializer_list<u16> items) { characters[proxy].children.assign(items); }

int main(int argc, char** argv)
{
	require(argc == 2, "scenario required");
	const std::string mode = argv[1];
	// giver-first: the giver's slot comes before the recipient's in host_track_proxies' walk (the order build 58 lost the entry in)
	const bool giver_first = mode.find("recipient-first") == std::string::npos;
	const PeerId giver = giver_first ? 1 : 2, recipient = giver_first ? 2 : 1;
	proxies[giver] = 501;
	proxies[recipient] = 502;
	proxies[3] = 503; // a third player
	characters[501].ID = 501;
	characters[502].ID = 502;
	characters[503].ID = 503;
	gun.ID = 100;
	gun_item.id = 100;
	hold(501, {100});
	hold(502, {});
	hold(503, {});
	clock_ms = 1000;
	host_track_proxies(clock_ms); // first sight: the baseline
	// (an item he holds is Owned: host_access never asks late_report_of_gift about it)
	require(!late_report_of_gift(3, 503, 100), "a player who never held it has no grace");
	// the gift (WP2 applied the move): his report may come before this frame's walk noticed it
	hold(501, {});
	hold(502, {100});
	if (mode == "same-frame")
	{
		require(late_report_of_gift(giver, 501, 100), "the giver's report in the frame of the gift is his last word on it");
		require(!late_report_of_gift(3, 503, 100), "another player's report is no giver's");
		return 0;
	}
	clock_ms = 1100;
	host_track_proxies(clock_ms);
	require(pushes_sent == 1, "the recipient gets the host's state of his new item");
	clock_ms = 1100 + kGraceMs;
	require(late_report_of_gift(giver, 501, 100), "the giver's report within the grace window is his last word on a gift");
	// (the recipient's report is Owned: never asked here)
	require(!late_report_of_gift(3, 503, 100), "another player's report is no giver's");
	if (mode == "expired" || mode == "expired-recipient-first")
	{
		clock_ms = 1100 + kGraceMs + 1;
		require(!late_report_of_gift(giver, 501, 100), "after the grace window it is a refusal again");
	}
	if (mode == "given-back")
	{
		// the recipient hands it back at once: it left him now (host_access says Owned to the first giver again: his report
		// never asks late_report_of_gift)
		hold(502, {});
		hold(501, {100});
		clock_ms = 1200;
		host_track_proxies(clock_ms);
		require(pushes_sent == 2, "the first giver gets the host's state of it again");
		require(g_left.count(100) && g_left[100].peer == recipient, "the grace is the one's who gave it back");
		require(late_report_of_gift(recipient, 502, 100), "the one who gave it back has the grace now");
	}
	return 0;
}
