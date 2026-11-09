// Engine functions are inserted verbatim. Only engine objects and transport endpoints are fixtures.
#include "coop_wire.h"
#include "coop_protocol.h"
#include "coop_limits.h"
#include "coop_ghost_rules.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>

using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using LPCSTR = const char*;
using CHARACTER_GOODWILL = int;
using CHARACTER_COMMUNITY_INDEX = int;
constexpr int NEUTRAL_GOODWILL = 0;
template<class T> using xr_vector = std::vector<T>;
template<class T> using xr_set = std::set<T>;
template<class... Args> void Msg(const char*, Args...) {}

struct SRelation {
    int value = 0;
    int Goodwill() const { return value; }
    void SetGoodwill(int next) { value = next; }
};
using PERSONAL_RELATION_MAP = std::map<u16, SRelation>;
using COMMUNITY_RELATION_MAP = std::map<int, SRelation>;
struct RELATION_DATA { PERSONAL_RELATION_MAP personal; COMMUNITY_RELATION_MAP communities; };
struct CRelationRegistry { using OBJECT_REGISTRY = std::map<u16, RELATION_DATA>; };
struct Store {
    CRelationRegistry::OBJECT_REGISTRY rows;
    RELATION_DATA& objects(u16 id) { return rows[id]; }
    const RELATION_DATA* objects_ptr(u16 id) const {
        const auto found = rows.find(id);
        return found == rows.end() ? nullptr : &found->second;
    }
};
struct World { bool host = false; coop::PeerId peer = 0; u16 proxy = 0xffff; Store store; };
World* current = nullptr;
struct Core { Store& registry() { return current->store; } };
class RELATION_REGISTRY {
public:
    static Core& relation_registry() { static Core core; return core; }
    int GetCommunityGoodwill(int community, u16 id) const;
    void SetCommunityGoodwill(int community, u16 id, int value);
    void ChangeCommunityGoodwill(int community, u16 id, int delta);
    int GetGoodwill(u16 from, u16 to) const { return current->store.rows[from].personal[to].Goodwill(); }
    void SetGoodwill(u16 from, u16 to, int value) { current->store.rows[from].personal[to].SetGoodwill(value); }
    void ChangeGoodwill(u16 from, u16 to, int delta) { SetGoodwill(from, to, GetGoodwill(from, to) + delta); }
    void ForceSetGoodwill(u16 from, u16 to, int value) { SetGoodwill(from, to, value); }
    int GetCommunityRelation(int, int) const { return 0; }
    void SetCommunityRelation(int, int, int) {}
};
struct CHARACTER_COMMUNITY {
    int value = -1;
    void set(LPCSTR name) { value = std::string(name) == "stalker" ? 0 : 1; }
    int index() const { return value; }
    static int GetMaxIndex() { return 1; }
};
struct Ivector2 { int x = -3000, y = 3000; };
struct Settings { Ivector2 r_ivector2(const char*, const char*) { return {}; } } settings;
Settings* pSettings = &settings;
constexpr auto ACTIONS_POINTS_SECT = "action_points";
template<class T> void clamp(T& value, T low, T high) { value = std::clamp(value, low, high); }
struct Manager {
    bool active() const { return true; }
    bool is_host() const { return current->host; }
    bool is_live_client() const { return !current->host; }
} manager;
Manager& mgr() { return manager; }
struct AI { World* get_alife() const { return current; } } ai_world;
AI& ai() { return ai_world; }

namespace coop { namespace story {
// GOODWILL_ENUM
bool on_community_goodwill(int, u16, int, GoodwillOp);
} }
// REGISTRY_FUNCTIONS
namespace coop { namespace join {
u16 my_proxy() { return current->proxy; }
// JOIN_MAPPING
} }
struct Outbound { coop::PeerId from; std::vector<u8> data; };
std::vector<Outbound> requests, replies;
namespace coop { namespace net {
void host_broadcast(coop::Msg, const Writer& value) { replies.push_back({ 0, value.data() }); }
} namespace story {
constexpr u16 kNoId = 0xffff;
// RELATION_CODES
// RELATION_KEY
xr_set<RelKey> g_rel_dirty;
struct Stats { unsigned action_dropped = 0, derived_dropped = 0, requests_out = 0, requests_in = 0, rel_out = 0; } g_stats;
int g_action_depth = 0;
bool applying_any() { return false; }
bool is_map_server() { return false; }
bool ghost_said(const ghost::Said&) { return false; }
bool is_player(u16 id) { return id == 0 || id == 501 || id == 502; }
struct ExecFor { explicit ExecFor(PeerId) {} };
const CRelationRegistry::OBJECT_REGISTRY* rel_all() { return &current->store.rows; }
void push_out(coop::Msg, Writer value, const limits::CommunityPair*) { requests.push_back({ current->peer, value.data() }); }
// STORY_FUNCTIONS
} }
// LUA_BINDINGS

unsigned checks = 0;
void require(bool value, const char* reason) {
    ++checks;
    if (!value) throw std::runtime_error(reason);
}
void deliver_requests(World& host) {
    current = &host;
    for (const auto& packet : requests) {
        coop::Reader reader(packet.data.data(), packet.data.size());
        const u8 op = reader.u8();
        coop::story::host_on_relation_request(packet.from, op, reader);
        require(reader.ok() && reader.remaining() == 0, "production host reader consumes relation payload");
    }
    requests.clear();
}
void deliver_replies(World& client) {
    current = &client;
    for (const auto& packet : replies) {
        coop::Reader reader(packet.data.data(), packet.data.size());
        const u8 op = reader.u8();
        const int community = reader.i32();
        const u16 target = reader.u16();
        const int value = reader.i32();
        require(op == coop::story::RelCommunity && reader.ok(), "host emits absolute faction goodwill");
        coop::story::client_set_community(community, target, value);
    }
}
void snapshot(std::ostream& out, World& host, const char* phase) {
    current = &host;
    out << phase << "={";
    for (u16 id : { 0, 501, 502 }) out << '[' << id << "]=" << g_community_goodwill("stalker", id) << ',';
    out << "},\n";
}
int main(int argc, char** argv) {
    try {
        if (argc != 2) return 2;
        World host{ true, 0, 0xffff, {} }, one{ false, 1, 501, {} }, two{ false, 2, 502, {} };
        current = &host;
        g_set_community_goodwill("stalker", 0, 1200);
        g_set_community_goodwill("stalker", 501, 600);
        g_set_community_goodwill("stalker", 502, 300);
        coop::story::g_rel_dirty.clear();
        std::ofstream out(argv[1]);
        out << "return {\n";
        snapshot(out, host, "before");
        one.store = host.store;
        two.store = host.store;
        current = &one;
        coop::story::client_swap_relations();
        require(g_community_goodwill("stalker", 0) == 600, "join swap puts this client's faction goodwill on its actor");
        require(g_community_goodwill("stalker", 501) == 1200, "join swap keeps host goodwill on the host avatar");
        current = &two;
        coop::story::client_swap_relations();
        require(g_community_goodwill("stalker", 0) == 300, "second client gets its own faction goodwill");
        current = &one;
        g_change_community_goodwill("stalker", 0, 300);
        require(requests.size() == 1, "client goodwill change uses the production Relation request");
        require(g_community_goodwill("stalker", 0) == 600, "client waits for host authority before committing goodwill");
        deliver_requests(host);
        require(g_community_goodwill("stalker", 501) == 900, "host stores the client's fresh goodwill at its avatar id");
        require(g_community_goodwill("stalker", 0) == 1200, "client request never replaces host goodwill");
        require(g_community_goodwill("stalker", 502) == 300, "client request never replaces another player's goodwill");
        snapshot(out, host, "changed");
        coop::story::host_flush_relations();
        deliver_replies(one);
        require(g_community_goodwill("stalker", 0) == 900, "absolute reply updates the correct local actor");
        deliver_replies(two);
        require(g_community_goodwill("stalker", 501) == 900, "other client sees the same remote goodwill");
        replies.clear();
        g_set_community_goodwill("stalker", 0, 600);
        deliver_requests(host);
        require(g_community_goodwill("stalker", 502) == 600, "second client's absolute setter targets its own avatar");
        require(g_community_goodwill("stalker", 501) == 900, "second client does not overwrite the first client");
        snapshot(out, host, "set");
        one.store = host.store;
        current = &one;
        coop::story::client_swap_relations();
        require(g_community_goodwill("stalker", 0) == 900, "rejoin restores the latest committed faction goodwill");
        snapshot(out, host, "rejoined");
        require(g_community_goodwill("stalker", 777) == 0, "unknown proxy is neutral, never a host fallback");
        out << "}\n";
        std::cout << "native faction-goodwill readpoint " << checks << " checks\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "trader native readpoint failed: " << error.what() << '\n';
        return 1;
    }
}
