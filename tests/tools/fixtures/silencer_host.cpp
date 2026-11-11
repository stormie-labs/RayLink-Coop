#include <cassert>
#include <cmath>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include "coop_wire.h"
using coop::Reader;
using coop::Writer;
using u8 = unsigned char;
using u16 = unsigned short;
using u32 = unsigned;
using PeerId = unsigned;
template<class K, class V> using xr_map = std::map<K, V>;
template<class T> using xr_deque = std::deque<T>;
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
bool _valid(float value) { return std::isfinite(value); }
constexpr u16 kNoId = 65535;
enum class Reason { Ok, Malformed, NotOwner, Offline, NotAllowed, BadSection, Engine, RateLimited };
struct Req { u32 seq = 7; PeerId from = 1; u16 proxy = 500; };
struct CSE_Abstract { virtual ~CSE_Abstract() = default; u16 ID_Parent = 500; };
struct CSE_ALifeInventoryItem : CSE_Abstract { float m_fCondition = 1; };
struct Vec { float x = 0, y = 0, z = 0; };
static std::string mode;
static int created_count = 0, destroyed = 0, committed = 0;
static int charged = 0;
static float loose_condition = -1;
static u32 world = 1;
static CSE_ALifeInventoryItem result;
struct CWeaponMagazined {
    virtual ~CWeaponMagazined() = default;
    bool attached = true;
    bool getDestroy() const { return mode == "destroying"; }
    bool SilencerAttachable() const { return mode != "permanent"; }
    bool IsSilencerAttached() const { return attached; }
    std::string GetSilencerName() const { return "wpn_sil_tgpv"; }
    Vec Position() const { return {}; }
    bool Detach(const char*, bool spawn) {
        assert(!spawn && created_count == 1); // Creation must succeed before removing the flag.
        if (mode == "detach-failure") return false;
        attached = false;
        return true;
    }
} weapon;
CWeaponMagazined* find_go(u16) { return mode == "offline" ? nullptr : &weapon; }
namespace events {
u16 root_of(u16) { return mode == "foreign" ? 999 : 500; }
CSE_Abstract* find_entity(u16) { return mode == "missing-result" ? nullptr : &result; }
}
namespace spawn {
struct ClassRule {} rule;
constexpr size_t kMaxSection = 128;
const ClassRule* class_rule(const char*) { return &rule; }
struct SectionFacts { unsigned cost = 2600; };
struct CostBudget {};
struct SpawnPolicy {};
enum class SpawnVerdict { Allow, OverBudget, Denied };
bool budget_free(const SectionFacts&) { return false; }
void refund(CostBudget&, unsigned, const SpawnPolicy&) { --charged; }
SpawnVerdict judge(const ClassRule*, const char*, const SectionFacts&, CostBudget&, const SpawnPolicy&, unsigned) {
    if (mode == "over-budget") return SpawnVerdict::OverBudget;
    if (mode == "denied") return SpawnVerdict::Denied;
    ++charged;
    return SpawnVerdict::Allow;
}
}
spawn::SectionFacts spawn_facts(const char*) { return {}; }
spawn::SpawnPolicy g_spawn_policy;
struct Budgets { spawn::CostBudget value; spawn::CostBudget& of(const std::string&) { return value; } } g_spawn_budgets;
std::string spawn_budget_key(u16) { return "owner"; }
struct Manager { unsigned now_ms() { return 1; } } manager;
Manager& mgr() { return manager; }
struct Missing { const char* line = nullptr; };
Missing missing_item_line(const char*, const spawn::ClassRule&) { return { mode == "bad-config" ? "visual" : nullptr }; }
struct Settings { const char* r_string(const char*, const char*) { return "WP_SILEN"; } } settings;
auto pSettings = &settings;
bool spawnable_section(const char*) { return mode != "missing-section"; }
Reason host_spawn_holder(const Req&, u16) { return Reason::Ok; }
CSE_Abstract* build_spawn(const Req&, u16, const char*, const float*, const u8*, size_t, Reason& why) {
    if (mode == "build-failure") { why = Reason::Engine; return nullptr; }
    return new CSE_ALifeInventoryItem;
}
void F_entity_Destroy(CSE_Abstract* entity) { delete entity; }
Reason host_spawn(CSE_Abstract* addon, u16, u16& id) {
    loose_condition = dynamic_cast<CSE_ALifeInventoryItem*>(addon)->m_fCondition;
    delete addon;
    if (mode == "spawn-failure") return Reason::Engine;
    ++created_count;
    id = 100;
    if (mode == "wrong-parent") result.ID_Parent = 777;
    return Reason::Ok;
}
Reason host_destroy(const Req&, u16) { ++destroyed; return Reason::Ok; }
namespace items { void host_silencer_detached(u16, PeerId) { ++committed; } }
float silencer_state(CWeaponMagazined*, bool commit) { assert(commit); return 1; }
namespace join { u32 world_generation() { return world; } }
namespace validate { bool resource_name_ok(const char* name, size_t max) { return *name && std::strlen(name) <= max; } }
enum { CatMisc };
bool allow(PeerId, int) { return mode != "rate-limited"; }
static Reason answered = Reason::Engine;
void reply(const Req&, Reason reason, u16) { answered = reason; }
struct ItemEventBody {
    u16 item = 50, type = 0, size = 0;
    u8 data[512];
    struct { u16 mechanic = kNoId; u32 paid = 0; } pay;
};
#include "silencer_host.inc"
int main(int argc, char** argv) {
    assert(argc == 2);
    mode = argv[1];
    if (mode == "stale-snapshot") {
        g_detached_silencers[50] = 1;
        ItemData state;
        state.has_addons = false;
        filter_detached_silencer(50, 1, state);
        assert(g_detached_silencers.count(50)); // An unrelated condition/ammo update is not an acknowledgement.
        state.has_addons = true;
        state.addons = 7;
        filter_detached_silencer(50, 1, state);
        assert(state.addons == 5 && g_detached_silencers.count(50));
        state.addons = 7;
        filter_detached_silencer(50, 2, state);
        assert(state.addons == 7); // A new owner is not fenced by the old owner's pending state.
        state.addons = 5;
        filter_detached_silencer(50, 1, state);
        assert(!g_detached_silencers.count(50));
        state.addons = 7;
        filter_detached_silencer(50, 1, state);
        assert(state.addons == 7); // A real reattach after acknowledgement is allowed.
        return 0;
    }
    Writer data;
    data.str(mode == "wrong-section" ? "wpn_sil_fake" : "wpn_sil_tgpv");
    data.f32(mode == "nan-condition" ? NAN : 0.37f);
    ItemEventBody body;
    body.size = static_cast<u16>(data.size());
    std::memcpy(body.data, data.ptr(), data.size());
    Req request;
    if (mode == "truncated") --body.size;
    if (mode == "unpaid") body.pay.paid = 1;
    host_on_silencer_detach(request, body);
    if (mode == "success" || mode == "repeat") {
        assert(answered == Reason::Ok && !weapon.attached && created_count == 1 && committed == 1);
        assert(loose_condition == 0.37f && charged == 1);
        if (mode == "repeat") {
            host_on_silencer_detach(request, body);
            assert(answered == Reason::Ok && created_count == 1 && committed == 1 && charged == 1);
            weapon.attached = true; // A later legitimate attachment must survive an old request replay.
            host_on_silencer_detach(request, body);
            assert(answered == Reason::Ok && weapon.attached && created_count == 1 && charged == 1);
            body.item = 51;
            host_on_silencer_detach(request, body);
            assert(answered == Reason::Malformed && created_count == 1);
        }
    } else {
        assert(answered != Reason::Ok && weapon.attached && committed == 0);
        assert(created_count == destroyed && charged == 0); // Failed detach leaves neither a free item nor a budget charge.
    }
}
