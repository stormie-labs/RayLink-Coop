// Test harness for the xrGame definitions inserted by test_s6_npc_paths.py.
// ALife storage and logging are local. Routing, queue writes, and the spawn handler come from production.
#include "test_util.h"
#include "support/fake_mode.h"
#include "srv/coop_levels_journal.h"
#include "srv/coop_levels_wire.h"
#include "coop_mirror.h"
#include "coop_reconcile.h"

#include <algorithm>
#include <limits>
#include <optional>
#include <string_view>

void Msg(const char*, ...) {}

namespace npc_fixture
{
using coop::EntityUp;
using coop::Msg;
using coop::PeerId;
using coop::Reader;
using coop::Where;
using coop::Writer;
using coop::kHostPeer;
using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using string64 = char[64];
template <typename T> using xr_vector = std::vector<T>;
namespace wire = coop::levels::wire;
namespace mirror = coop::mirror;
namespace reconcile = coop::reconcile;

constexpr u16 kActor = 0, kNoId = 0xffff;
constexpr u16 kSpawn = 100, kReleased = 101, kItem = 102, kOldParent = 103, kNewParent = 104, kVictim = 105, kKiller = 106;
constexpr float flt_max = std::numeric_limits<float>::max();

struct Fvector
{
	float x = 0.f;
	void set(float x_, float, float) { x = x_; }
	float distance_to(const Fvector& pos) const { return x >= pos.x ? x - pos.x : pos.x - x; }
};

struct NET_Packet
{
	struct { u8 data[32]; u16 count; } B{};
	u32 r_pos = 0;
	void r_begin(u16& type) { type = 0; }
	void r_stringZ(string64& section) { std::copy_n("fixture", sizeof("fixture"), section); }
};

struct CSE_Abstract { virtual ~CSE_Abstract() = default; };
struct CSE_ALifeDynamicObject : CSE_Abstract
{
	u16 ID = kNoId, ID_Parent = kNoId, m_tGraphID = kNoId;
	u32 m_tNodeID = 0;
	bool m_bOnline = false;
	std::string s_name = "fixture";
	Fvector o_Position, o_Angle;
	xr_vector<u16> children;
	const char* name_replace() const { return "fixture"; }
	void Spawn_Read(NET_Packet&) {}
};
struct CSE_ALifeCreatureActor : CSE_ALifeDynamicObject {};
struct CSE_ALifeOnlineOfflineGroup : CSE_ALifeDynamicObject {};
template <typename T> T smart_cast(CSE_Abstract* p) { return dynamic_cast<T>(p); }

struct FixtureAlife
{
	CSE_ALifeCreatureActor local_actor;
	std::map<u16, CSE_ALifeDynamicObject*> registered;
	unsigned switches = 0;
	unsigned object_reads = 0;

	FixtureAlife& graph() { return *this; }
	FixtureAlife& objects() { return *this; }
	FixtureAlife& server() { return *this; }
	CSE_ALifeCreatureActor* actor() { return &local_actor; }
	CSE_ALifeDynamicObject* object(u16 id, bool)
	{
		++object_reads;
		const auto it = registered.find(id);
		return it == registered.end() ? nullptr : it->second;
	}
	CSE_ALifeDynamicObject* ID_to_entity(u16) { return nullptr; }
	bool IsFreeID(u16) { return true; }
	u16 PerformIDgen(u16 id) { return id; }
	void register_object(CSE_ALifeDynamicObject* e, bool) { registered.emplace(e->ID, e); }
	void switch_online(CSE_ALifeDynamicObject* e) { ++switches; e->m_bOnline = true; }
};

FixtureAlife alife;
struct FixtureAi
{
	FixtureAlife& alife() { return npc_fixture::alife; }
	FixtureAlife* get_alife() { return &alife(); }
	const FixtureAi& game_graph() const { return *this; }
	bool valid_vertex_id(u16 graph) const { return graph != kNoId; }
};
FixtureAi ai() { return {}; }
FixtureAlife& alife_rw() { return alife; }

struct Manager
{
	bool running = false;
	uint8_t roles = 0;
	bool active() const { return running; }
	unsigned now_ms() const { return 0; }
};
Manager& mgr() { static Manager manager; return manager; }
bool is_map_server() { return coop::has(mgr().roles, coop::ProcessRole::MapServer); }
bool is_mirror() { return coop::has(mgr().roles, coop::ProcessRole::Mirror); }
bool dedicated = false;
bool ghost_actor() { return dedicated || is_map_server(); }

namespace join
{
constexpr u32 kMaxPeerSlots = coop::kMaxPlayers + 1;
unsigned proxy_reads = 0;
std::map<PeerId, u16> proxies;
u16 proxy_of_peer(PeerId peer)
{
	++proxy_reads;
	const auto it = proxies.find(peer);
	return it == proxies.end() ? kNoId : it->second;
}
u16 to_local(u16 id) { return id; }
}
using join::kMaxPeerSlots;

struct xrCriticalSection {};
struct xrCriticalSectionGuard { explicit xrCriticalSectionGuard(xrCriticalSection&) {} };

namespace entities
{
int g_applying = 0;
struct ClientApply { ClientApply(); ~ClientApply(); };
// PRODUCTION_APPLY
}

namespace levels
{
namespace journal = coop::levels::journal;
namespace wire = npc_fixture::wire;
struct State
{
	// PRODUCTION_UP_RECORD
	std::vector<Up> up;
	journal::HeldMemory memory;
	std::set<u16> quiet;
	journal::ReleasesUnderWay releasing;
	u32 parents_unregistered = 0;
	xrCriticalSection lock;
} g;
// The fixture's objects are no creatures of a squad: the head carries the id alone, a death or a release goes at the end
journal::ObjectHead head_of(u16 local_id)
{
	journal::ObjectHead h;
	h.id = local_id;
	return h;
}
journal::ObjectHead head_before_move(u16 item, const journal::ParentBefore&) { return head_of(item); }
journal::CreaturePlace place_of_creature(u16, journal::ObjectHead&)
{
	journal::CreaturePlace p;
	p.at = g.up.size();
	return p;
}
void client_unadopt(u16) { CHECK(false); }
// PRODUCTION_UP_HOOKS
void up_member(u16, u16, bool) {}
void up_item_facts(u16) {}
u16 echo_now() { return reconcile::kNoEcho; }
}

struct LevelSide
{
	virtual ~LevelSide() = default;
	virtual void level_entity_up(EntityUp, u16, u16) = 0;
};
struct MapLevelSide final : LevelSide
{
	u32 m_nameless_infos = 0;
	// PRODUCTION_LEVEL_DISPATCH
} map_side;

struct Mode
{
	std::optional<t::FakeMode> answers;
	bool decides_world() const { return answers->decides_world(); }
	bool leads_level() const { return answers->leads_level(); }
	Where where(PeerId peer) const { return answers->where(peer); }
	LevelSide* level() { return answers->level() ? &map_side : nullptr; }
	bool online_elsewhere(u16 id) const { return answers->online_elsewhere(id); }
};
Mode& mode() { static Mode current; return current; }

// PRODUCTION_OBSERVER

namespace script { void note_released(u16) {} }
namespace items
{
void forget_item(u16) {}
bool read_initial(Reader&, CSE_Abstract*) { return true; } // the fixture's spawns carry no item state
}
namespace syncapi { void on_entity_destroyed(u16) {} }
namespace world
{
bool is_player_proxy(u16 id) { return id == kOldParent; }
bool is_player_character(const CSE_Abstract*) { return false; }
}
namespace writing { bool writes(u16) { return false; } }
namespace net { void client_send(coop::Msg, const Writer&) {} }
namespace requests
{
bool read_clone_initial(Reader&, u16, std::vector<u8>&) { return true; }
bool stage_clone_initial(CSE_ALifeDynamicObject*, const std::vector<u8>&, bool = false) { return true; }
bool clone_activate(u16) { return true; }
void clone_finish(u16, bool) {}
}

namespace entities
{
enum class HostEventKind { Registered, Released };
struct HostEvent { HostEventKind kind; u16 id; bool online; bool applied = false; };
std::vector<HostEvent> g_host_events;
// PRODUCTION_ENTITY_HOOKS

bool spawn_group = false;
CSE_ALifeDynamicObject normal_spawn;
CSE_ALifeOnlineOfflineGroup group_spawn;
CSE_Abstract* F_entity_Create(const char*) { return spawn_group ? &group_spawn : &normal_spawn; }
void F_entity_Destroy(CSE_Abstract* e) { CHECK(e == nullptr); }
void apply_update(CSE_ALifeDynamicObject*, const NET_Packet&) {}
void bring_child_online(CSE_ALifeDynamicObject* e) { alife.switch_online(e); }
void client_on_destroy(PeerId, Reader&) { CHECK(false); }
// every fixture spawn is new here: nothing is replaced, every clone state is empty
bool game_object_here(u16) { return false; }
void client_remove(u16) { CHECK(false); }
void squads_made_whole(const CSE_ALifeDynamicObject*) {}
bool mirror_log_allowed() { return false; }
bool log_allowed(unsigned&) { return false; }
struct { void add(u16, unsigned) {} void done(u16) {} } g_id_retry;
std::set<u16> g_refetched, g_online;
unsigned g_missing, g_mirror_stale, g_mirror_log_info, g_mirror_online_now, g_mirror_with_holder, g_mirror_broken_holder,
    g_client_spawns, g_stale_spawns, g_replaced;

// PRODUCTION_SPAWN
}

namespace events
{
u16 root_of(u16 id) { return id; }
xrCriticalSection g_lock;
// PRODUCTION_EVENT_RECORDS
std::map<u16, ParentChange> g_parent_changes;
std::map<u16, u16> g_last_holder;
std::vector<Death> g_deaths;
// PRODUCTION_EVENT_HOOKS
}

void process(const char* name, bool active)
{
	const auto& c = t::mode_case(name);
	mgr() = {active, active ? c.answers.roles : u8{0}};
	mode().answers.emplace(c);
	dedicated = std::string_view(name) == "world_server";
	mode().answers->place(2, t::Spot::Joining);
	mode().answers->place(3, t::Spot::Elsewhere);
	alife = {};
	join::proxies.clear();
	join::proxy_reads = 0;
}

void check_observer(const char* name, bool active, float expected_distance, bool walk, unsigned object_reads)
{
	process(name, active);
	alife.local_actor.o_Position.x = 20.f;
	CSE_ALifeDynamicObject joining, away;
	joining.o_Position.x = 7.f;
	away.o_Position.x = 2.f;
	join::proxies = {{PeerId{2}, u16{200}}, {PeerId{3}, u16{201}}};
	alife.registered = {{u16{200}, &joining}, {u16{201}, &away}};
	CHECK_EQ(observer_distance({}), expected_distance);
	CHECK_EQ(join::proxy_reads, walk ? kMaxPeerSlots - 1 : 0u);
	CHECK_EQ(alife.object_reads, object_reads);
}

void check_spawn(u8 word, mirror::Placement expected, bool group = false, u16 graph = kNoId)
{
	alife = {};
	entities::g_online.clear();
	entities::normal_spawn = {};
	entities::group_spawn = {};
	entities::spawn_group = group;
	Writer packet;
	packet.u16(kSpawn);
	packet.u16(kNoId);
	packet.u8(word);
	const float zero[3] = {};
	packet.vec3(zero);
	packet.vec3(zero);
	packet.u32(0); // level vertex
	packet.u16(graph);
	packet.u16(0); // spawn packet length (the stub supplies a stock entity)
	packet.u16(0); // update packet length
	Reader r(packet.ptr(), packet.size());
	entities::client_on_spawn(kHostPeer, r);
	CHECK(r.ok());
	CHECK_EQ(r.remaining(), size_t{0});
	const auto* spawned = alife.object(kSpawn, true);
	REQUIRE(spawned != nullptr);
	CHECK_EQ(entities::g_online.count(kSpawn) == 1, expected != mirror::Placement::Offline);
	CHECK_EQ(spawned->m_bOnline, expected == mirror::Placement::OnlineNow);
	CHECK_EQ(alife.switches, expected == mirror::Placement::OnlineNow ? 1u : 0u);
}

void check_reports(bool record_local, bool report_up)
{
	entities::g_host_events.clear();
	events::g_parent_changes.clear();
	events::g_last_holder.clear();
	events::g_deaths.clear();
	levels::g.up.clear();

	CSE_ALifeDynamicObject spawned, item;
	spawned.ID = kSpawn;
	item.ID = kItem;
	alife.registered[kItem] = &item; // a map server journals the moves of its own ALife's objects only
	entities::host_on_entity_registered(&spawned);
	entities::host_on_entity_released(kReleased);
	events::host_on_parent_changed(kItem, kOldParent, kNewParent);
	events::host_on_death(kVictim, kKiller);

	CHECK_EQ(entities::g_host_events.size(), record_local ? size_t{2} : size_t{0});
	CHECK_EQ(events::g_parent_changes.size(), record_local ? size_t{1} : size_t{0});
	CHECK_EQ(events::g_deaths.size(), record_local ? size_t{1} : size_t{0});
	if (record_local)
	{
		REQUIRE(entities::g_host_events.size() == 2);
		CHECK_EQ(entities::g_host_events[0].kind, entities::HostEventKind::Registered);
		CHECK_EQ(entities::g_host_events[0].id, kSpawn);
		CHECK(!entities::g_host_events[0].applied);
		CHECK_EQ(entities::g_host_events[1].kind, entities::HostEventKind::Released);
		CHECK_EQ(entities::g_host_events[1].id, kReleased);
		CHECK(events::g_parent_changes.count(kItem) && events::g_parent_changes.at(kItem).old_parent == kOldParent);
		CHECK(events::g_deaths.size() == 1 && events::g_deaths.front().victim == kVictim &&
		    events::g_deaths.front().killer == kKiller);
	}
	const levels::State::Up expected[] = {
	    {wire::LevelEntityHead::Spawn, kSpawn, kNoId},
	    {wire::LevelEntityHead::Destroy, kReleased, kNoId},
	    {wire::LevelEntityHead::Parent, kItem, kNewParent},
	    {wire::LevelEntityHead::Died, kVictim, kKiller},
	};
	REQUIRE(levels::g.up.size() == (report_up ? std::size(expected) : 0));
	for (size_t i = 0; i < levels::g.up.size(); ++i)
	{
		CHECK_EQ(levels::g.up[i].op, expected[i].op);
		CHECK_EQ(levels::g.up[i].a, expected[i].a);
		CHECK_EQ(levels::g.up[i].b, expected[i].b);
	}
}

// Expected results are the HEAD paths in each process. They do not depend on Mode answers.
using Placement = mirror::Placement;
struct Expected
{
	float min_distance;
	unsigned object_reads;
	Placement unmarked, marked;
	bool local_records, world_reports;
};
constexpr auto vote = Placement::SwitchVote, now = Placement::OnlineNow;
constexpr Expected coop_host{2.f, 2, vote, vote, true, false};
constexpr Expected coop_client{20.f, 0, now, now, false, false};
constexpr Expected world_server{7.f, 1, vote, vote, true, false};
constexpr Expected map_server{2.f, 2, vote, vote, true, true};
constexpr Expected server_client{20.f, 0, vote, now, false, false};
constexpr Expected none{20.f, 0, vote, vote, false, false};

#define NPC_PATHS(name) \
	TEST(npc_s6_observer_##name) \
	{ \
		check_observer(#name, std::string_view(#name) != "none", name.min_distance, name.object_reads != 0, name.object_reads); \
	} \
	TEST(npc_s6_spawn_##name) \
	{ \
		process(#name, std::string_view(#name) != "none"); \
		check_spawn(0, Placement::Offline); \
		check_spawn(1, name.unmarked); \
		check_spawn(wire::kSpawnOnlineAtYourLevel, name.marked); \
		check_spawn(wire::kSpawnOnlineAtYourLevel, vote, true); \
		check_spawn(wire::kSpawnOnlineAtYourLevel, vote, false, 1); \
	} \
	TEST(npc_s6_reports_##name) \
	{ \
		process(#name, std::string_view(#name) != "none"); \
		check_reports(name.local_records, name.world_reports); \
	}
MODE_CASES(NPC_PATHS)
#undef NPC_PATHS

TEST(npc_s6_reports_map_server_during_world_apply)
{
	process("map_server", true);
	{
		entities::ClientApply apply;
		check_reports(false, false);
	}
	check_reports(true, true);
}

TEST(npc_s6_observer_coop_host_startup)
{
	check_observer("coop_host", false, 20.f, false, 0);
}

TEST(npc_s6_observer_world_server_startup)
{
	check_observer("world_server", false, flt_max, false, 0);
}
} // namespace npc_fixture

namespace t
{
std::vector<TestCase>& registry() { static std::vector<TestCase> cases; return cases; }
int& failures_in_test() { static int failures; return failures; }
void report_failure(const char* file, int line, const std::string& what)
{
	++failures_in_test();
	std::printf("  %s:%d: %s\n", file, line, what.c_str());
}
}

int main()
{
	unsigned passed = 0, failed = 0;
	for (const auto& test : t::registry())
	{
		std::printf("[RUN ] %s\n", test.name);
		t::failures_in_test() = 0;
		try { test.fn(); }
		catch (const t::Abort&) {}
		if (t::failures_in_test())
			++failed;
		else
			++passed;
	}
	std::printf("%u passed, %u failed\n", passed, failed);
	return failed ? 1 : 0;
}
