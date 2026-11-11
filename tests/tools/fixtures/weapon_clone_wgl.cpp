#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <map>
#include <string>
#include <vector>
#include <mutex>
#include <memory>
#include <set>
#include "lua.hpp"
#include "coop_item_tags.h"
#include "coop_wire.h"
#include "coop_replacement.h"

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using PeerId = u16;
using UpgradeList = std::vector<std::string>;
using Blob = std::vector<u8>;
template<class T> using xr_vector = std::vector<T>;
using coop::Reader;
using coop::Writer;
using coop::kMaxItemState;
namespace itemtags = coop::itemtags;
namespace replacement = coop::replacement;
constexpr u16 kNoId = 65535;
constexpr u8 kBlobVersion = 1;
constexpr std::size_t kMaxBlob = 8192;
enum Tag : u8 { TagCondition = 1, TagUpgrades, TagBox, TagAddons, TagScope, TagMain, TagLauncher, TagUses, TagMode, TagFireMode, TagCartridges };
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
template<class T> T _min(T a, T b) { return std::min(a, b); }
template<class T> T _max(T a, T b) { return std::max(a, b); }
using shared_str = std::string;
struct Fvector {};
struct Flags {
    u8 flags = 0;
    u8 get() const { return flags; }
    void assign(u8 value) { flags = value; }
};
struct NET_Packet;
struct CSE_Abstract {
    virtual ~CSE_Abstract() = default;
    u16 ID = kNoId;
    u16 ID_Parent = kNoId;
    std::string s_name = "wpn_variant";
    std::string name;
    const char* name_replace() const { return name.c_str(); }
    void Spawn_Write(NET_Packet&, bool);
};
struct CSE_ALifeInventoryItem : CSE_Abstract {
    float m_fCondition = 0.83f;
    UpgradeList m_upgrades;
};
struct CSE_ALifeItemAmmo : CSE_ALifeInventoryItem { u16 a_elapsed = 0, m_boxSize = 30; };
struct CSE_ALifeItemWeapon : CSE_ALifeInventoryItem {
    enum { eWeaponAddonScope = 1 };
    u16 a_elapsed = 0;
    u8 ammo_type = 0, wpn_flags = 0;
    Flags m_addon_flags;
    struct Grenades {
        u8 grenades_count : 6;
        u8 grenades_type : 2;
    } a_elapsed_grenades = {};
    u16 get_ammo_elapsed() const { return a_elapsed; }
    void set_ammo_elapsed(u16 value) { a_elapsed = value; }
};
struct CSE_ALifeItemWeaponMagazined : CSE_ALifeItemWeapon { u8 m_u8CurFireMode = 0; };
struct CSE_ALifeItemWeaponShotGun : CSE_ALifeItemWeaponMagazined { std::vector<u8> m_AmmoIDs; };
struct CSE_ALifeItemWeaponMagazinedWGL : CSE_ALifeItemWeaponMagazined { bool m_bGrenadeMode = false; };
struct CInventoryItem {
    virtual ~CInventoryItem() = default;
    float GetCondition() const { return 0.83f; }
    UpgradeList get_upgrades() const { return {}; }
    void SetCondition(float) {}
};
struct CWeaponAmmo : CInventoryItem { u16 m_boxCurr = 0, m_boxSize = 30; struct Inventory* m_pInventory = nullptr; };
struct Inventory { void InvalidateState() {} };
struct CCartridge {
    u8 m_LocalAmmoType = 0;
    void Load(const char*, u8 type, float) { m_LocalAmmoType = type; }
};
struct AmmoName : std::string { using std::string::string; AmmoName() = default; operator const char*() const { return c_str(); } };
struct CWeapon : CInventoryItem {
    int count = 0;
    u8 m_ammoType = 0, m_cur_scope = 0;
    std::vector<int> m_scopes;
    std::vector<AmmoName> m_ammoTypes = {"fmj", "ap", "third"};
    std::vector<CCartridge> m_magazine;
    CCartridge m_DefaultCartridge;
    float m_APk = 1.f;
    void SetAmmoElapsed(int value) { count = value; m_magazine.resize(value); for (auto& c : m_magazine) c.m_LocalAmmoType = m_ammoType; }
    bool ScopeAttachable() const { return false; }
    void SetAddonsState(u8) {} void UpdateAddonsVisibility() {} void InitAddons() {}
    void ForceUpdateAmmo() {}
    int GetAmmoElapsed() const { return count; }
    u8 GetAddonsState() const { return 0; }
protected:
    virtual void FireEnd() {}
};
struct CWeaponMagazined : CWeapon {
    void FireEnd() override { CWeapon::FireEnd(); }
    int fire_mode = 2;
    int GetFireModeIndex() const { return fire_mode; }
    void SetFireMode(int value) { fire_mode = value < 3 ? value : 0; }
};
struct CWeaponMagazinedWGrenade : CWeaponMagazined {
    bool m_bGrenadeMode = false;
    u8 m_ammoType2 = 0;
    std::vector<CCartridge> m_magazine2;
    std::vector<AmmoName> m_ammoTypes2 = {"vog1", "vog2", "vog3"};
    void SetAmmoElapsed2(int value) { m_magazine2.resize(value); for (auto& c : m_magazine2) c.m_LocalAmmoType = m_ammoType2; }
    bool IsGrenadeLauncherAttached() const { return true; }
    void PerformSwitchGL() { m_bGrenadeMode = !m_bGrenadeMode; std::swap(m_ammoType, m_ammoType2); m_ammoTypes.swap(m_ammoTypes2); m_magazine.swap(m_magazine2); count = int(m_magazine.size()); }
};
struct CEatableItem : CInventoryItem { u8 GetRemainingUses() const { return 0; } u8 GetMaxUses() const { return 4; } void SetRemainingUses(u8) {} };
std::map<u16, CInventoryItem*> objects;
CInventoryItem* find_item(u16 id) {
    auto it = objects.find(id);
    return it == objects.end() ? nullptr : it->second;
}
CInventoryItem* find_go(u16 id) { return find_item(id); }
u16 quant(float value) { return u16(std::lround(value * 65535.f)); }
float dequant(u16 value) { return value / 65535.f; }
bool is_map_authority() { return false; }
// ITEM_DATA
UpgradeList spawn_upgrade_list(const std::string&, const UpgradeList& list, bool) { return list; }
struct Caps { u32 main_cap = 60, gl_cap = 3, main_types = 3, gl_types = 3; };
void weapon_caps(CSE_ALifeItemWeapon*, CInventoryItem*, Caps&) {}
void host_sanitize(CSE_Abstract*, CInventoryItem*, ItemData&) {}
void install_upgrades(CInventoryItem*, const UpgradeList&) {}
namespace items {
std::mutex g_lock;
std::map<u16, Blob> g_spawn_states;
std::map<u16,int> g_sent, g_pending, g_take_base, g_owned, g_left, g_unload_used;
std::map<u16,int> g_detached_silencers;
std::set<u16> g_releasing;
std::set<u32> g_logged_tags;
std::map<u16,std::vector<u16>> g_proxy_items;
struct SpawnReq {u16 weapon, parent;};
std::vector<SpawnReq> g_spawns;
std::vector<u16> g_touched, g_made_here, g_forgotten, g_clear_pending;
void restore_item_state(CSE_Abstract*, const Blob&, CInventoryItem* object = nullptr);
// ITEM_METHODS
}
struct Lock {} g_out_lock;
struct xrCriticalSectionGuard { explicit xrCriticalSectionGuard(Lock&) {} };
struct LeasedTemp { u16 id, source; };
std::vector<CSE_Abstract*> g_lua_temps;
std::map<CSE_Abstract*, LeasedTemp> g_temp_leases;
std::map<u16, replacement::Snapshot> g_clone_prepared;
std::map<std::pair<u16, u16>, std::vector<u8>> g_clone_committed;
std::set<u16> g_clone_confirmed, g_clone_canonical;
bool mirror_role = true;
bool is_live_mirror() { return mirror_role; }
u64 g_clone_nonce = 0;
struct Manager { bool online = true; bool active() { return online; } u64 now_ms() { return 1000; } } manager;
Manager& mgr() { return manager; }
namespace join { u16 to_host(u16 id) { return id; } u16 to_local(u16 id) { return id; } }
lua_State* test_lua = nullptr;
struct ScriptEngine { lua_State* lua() { return test_lua; } } script_engine;
struct Ai { ScriptEngine& script_engine() { return ::script_engine; } } ai_state;
Ai& ai() { return ai_state; }
std::map<u16, CSE_Abstract*> entities;
namespace events { CSE_Abstract* find_entity(u16 id) { auto it=entities.find(id); return it == entities.end() ? nullptr : it->second; } }
bool clone_export(u16, std::string&, const char* stamp = nullptr);
bool clone_stage(u16, u16, const char*, const std::string&, int, const std::string&);
bool write_clone_initial(Writer&, CSE_Abstract*);
bool before_clone_register(CSE_Abstract*);
bool after_clone_register(u16, bool);
void name_with_id(CSE_Abstract* entity) { entity->name = entity->s_name + std::to_string(entity->ID); }
bool run_lua(const std::string& code) {
    if (luaL_dostring(test_lua, code.c_str()) == 0) return true;
    std::cerr << lua_tostring(test_lua, -1) << '\n'; lua_pop(test_lua, 1); return false;
}
enum class Reason { Ok, Malformed, NotAllowed, Engine };
struct Req { u16 from = 1, proxy = 501; };
bool fail_spawn = false, fail_source = false;
bool plain_target = false, shotgun_target = false;
namespace syncapi { void on_entity_destroyed(u16) {} }
namespace levels { void xfer_on_released(u16) {} }
bool host_records() { return false; }
enum class HostEventKind { Released };
struct HostEvent { HostEventKind kind; u16 id; bool online; };
std::vector<HostEvent> g_host_events;
// RELEASE_HOOK
Reason host_destroy(const Req&, u16 id) {
    if (fail_source && id == 800) return Reason::Engine;
    entities.erase(id);
    objects.erase(id);
    host_on_entity_released(id);
    run_lua("native_destroy(" + std::to_string(id) + ")");
    return Reason::Ok;
}
std::vector<std::unique_ptr<CWeaponMagazined>> spawned;
Reason host_spawn(CSE_Abstract* entity, u16, u16& created, u16 target) {
    if (fail_spawn) { delete entity; return Reason::Engine; }
    entity->ID = target;
    entities[target] = entity;
    created = target;
    if (!run_lua("native_spawn(" + std::to_string(target) + ", 'wpn_variant')")) return Reason::Engine;
    std::unique_ptr<CWeaponMagazined> weapon = shotgun_target ? std::make_unique<CWeaponMagazined>() : std::make_unique<CWeaponMagazinedWGrenade>();
    objects[target] = weapon.get();
    items::restore_spawn_state(weapon.get(), entity, true);
    spawned.push_back(std::move(weapon));
    return Reason::Ok;
}
struct { int clones_refused = 0, not_variant = 0, temps = 0; } g_lc;
void temps_sync_world() {}
bool lease_waiting(u16) { return false; }
bool clone_variant(const char*, const char*) { return true; }
CSE_Abstract* make_temp(const char*, const Fvector&, u32, u16, u16) {
    if (shotgun_target) return new CSE_ALifeItemWeaponShotGun;
    return plain_target ? static_cast<CSE_Abstract*>(new CSE_ALifeItemWeaponMagazined)
                        : new CSE_ALifeItemWeaponMagazinedWGL;
}
void F_entity_Destroy(CSE_Abstract* entity) { delete entity; }
CSE_Abstract* lua_refuse(const char*, const char*) { return nullptr; }
namespace callgate { bool is_own(u16) { return true; } }
u16 take_lease(const char*, u16) { return 900; }
bool create_leased(CSE_Abstract*, u16, u16) { return false; }
void return_unused_lease(u16) {}
void lua_forward(CSE_Abstract*, const char*) {}
// CLONE_METHOD

using LPCSTR = const char*;
namespace ALife { using _OBJECT_ID = u16; }
namespace GameGraph { using _GRAPH_ID = u16; }
constexpr bool FALSE = false;
constexpr u16 M_SPAWN = 1;
struct NET_Packet {
    u16 id = kNoId;
    std::string section;
    void w_begin(u16) {} void w_stringZ(const std::string&) {} void r_begin(u16&) {}
};
void CSE_Abstract::Spawn_Write(NET_Packet& packet, bool) { packet.id = ID; packet.section = s_name; }
struct ClientID { void set(u16) {} };
struct FakeServer {
    int freed = 0;
    void FreeID(u16, int) { ++freed; }
    CSE_Abstract* Process_spawn(NET_Packet& packet, ClientID) {
        auto* e = make_temp(packet.section.c_str(), Fvector{}, 0, 0, 0);
        e->s_name = packet.section;
        e->ID = packet.id;
        name_with_id(e);
        u16 created = kNoId;
        return host_spawn(e, 0, created, packet.id) == Reason::Ok ? e : nullptr;
    }
};
struct CALifeSimulator {
    FakeServer s;
    FakeServer& server() { return s; }
    CSE_Abstract* spawn_item(const char* section, const Fvector&, u32, u16, u16 parent, bool) {
        auto* e = make_temp(section, Fvector{}, 0, 0, parent);
        e->ID = 900; e->ID_Parent = parent; e->s_name = section; name_with_id(e);
        return e;
    }
    void release(CSE_Abstract* e, bool) { host_destroy(Req{}, e->ID); }
};
namespace coop {
namespace calls { enum class Gate { Request, Refuse, Run }; bool own_spawn(bool, bool) { return true; } }
namespace callgate { bool is_own(u16) { return true; } }
namespace requests {
using ::lua_clone; using ::prepare_local_clone; using ::before_clone_register; using ::after_clone_register;
CSE_Abstract* lua_register_spawn(CSE_Abstract*) { return nullptr; }
}
}
coop::calls::Gate coop_spawn_gate(const char*, bool, const Fvector*, const char*) { return coop::calls::Gate::Run; }
// GATE_METHODS

bool check(bool passed, const char* description) {
    if (!passed) std::cerr << "FAILED " << description << '\n';
    return passed;
}
bool magazines(const ItemData& data) {
    bool ok = check(data.has_main, "main magazine present");
    ok = check(data.main_count == 17, "main count 17") && ok;
    ok = check(data.main_type == 1, "main type A=1") && ok;
    ok = check(data.has_launcher, "launcher magazine present") && ok;
    ok = check(data.gl_count == 1, "launcher count 1") && ok;
    return check(data.gl_type == 2, "launcher type B=2") && ok;
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const std::string mode = argv[1];
    const bool grenade = mode.find("grenade") != std::string::npos;
    test_lua = luaL_newstate();
    luaL_openlibs(test_lua);
    if (!run_lua("dofile('tests/lua/support/clone_native_world.lua')")) return 1;
    if (mode.find("mixed-") != std::string::npos || mode == "invalid-cartridges") {
        shotgun_target = true;
        const std::vector<u8> order = mode.find("bm16") != std::string::npos ? std::vector<u8>{0, 1} : std::vector<u8>{0, 1, 2, 0, 2, 1};
        CSE_ALifeItemWeaponShotGun shotgun;
        shotgun.ID = 800;
        shotgun.name = "wpn_ak74m800";
        shotgun.a_elapsed = u16(order.size());
        shotgun.ammo_type = 1;
        shotgun.m_u8CurFireMode = 2;
        shotgun.m_AmmoIDs = order;
        CWeaponMagazined live_shotgun;
        live_shotgun.m_ammoType = 1;
        live_shotgun.SetAmmoElapsed(int(order.size()));
        for (size_t i = 0; i < order.size(); ++i) live_shotgun.m_magazine[i].m_LocalAmmoType = order[i];
        objects[800] = &live_shotgun;
        if (mode.find("offline-") == 0) objects.erase(800);
        CALifeSimulator alife;
        CSE_Abstract* target = mode.find("gate-") == 0
            ? try_to_clone_object(&alife, &shotgun, "wpn_variant", Fvector{}, 0, 0, 0, true)
            : lua_clone(&shotgun, "wpn_variant", Fvector{}, 0, 0, 0, false);
        if (!target) return 1;
        if (mode == "invalid-cartridges") {
            ItemData invalid;
            Blob data;
            items::capture_spawn_state(target, data);
            items::read_data(data.data(), data.size(), invalid);
            invalid.cartridges[0] = 99;
            items::write_data(invalid, data);
            const char* why = nullptr;
            return check(!items::host_apply_spawn_state(target, data.data(), data.size(), why), "unknown cartridge indices are rejected") ? 0 : 1;
        }
        CWeaponMagazined local;
        CWeaponMagazined* restored = mode.find("gate-") == 0 ? smart_cast<CWeaponMagazined*>(objects[900]) : &local;
        objects[900] = restored;
        items::restore_spawn_state(restored, target, false);
        auto* server = smart_cast<CSE_ALifeItemWeaponShotGun*>(target);
        bool ok = check(server->m_AmmoIDs == order, "typed CSE cartridge order survives");
        ok = check(server->m_u8CurFireMode == 2 && restored->GetFireModeIndex() == 2, "fire mode index survives") && ok;
        for (auto it = order.rbegin(); it != order.rend(); ++it) {
            ok = check(restored->m_magazine.back().m_LocalAmmoType == *it, "next fired cartridge retains its type") && ok;
            restored->m_magazine.pop_back();
        }
        Blob deferred{1};
        items::stage_spawn_state(900,deferred);
        items::g_pending[900]=1; items::g_take_base[900]=1; items::g_sent[900]=1;
        items::g_spawns.push_back({900,0}); items::g_touched.push_back(900); items::g_made_here.push_back(900);
        host_on_entity_released(900);
        items::drain_forgotten(); // the engine's next main-thread ItemState pass
        ok = check(items::g_spawn_states.count(900)==0, "actual ALife release hook purges deferred native state before id reuse") && ok;
        ok = check(!items::g_pending.count(900) && !items::g_take_base.count(900) && !items::g_sent.count(900) &&
            items::g_spawns.empty() && items::g_touched.empty() && items::g_made_here.empty(), "release purges native late pushes, baselines and speculative hook queues") && ok;
        delete target;
        return ok ? 0 : 1;
    }
    CSE_ALifeItemWeaponMagazinedWGL source;
    source.ID = 800;
    source.s_name = "wpn_ak74m";
    source.name = "wpn_ak74m800";
    entities[800] = &source;
    source.m_bGrenadeMode = grenade;
    source.a_elapsed = grenade ? 1 : 17;
    source.ammo_type = grenade ? 2 : 1;
    source.a_elapsed_grenades.grenades_count = 1;
    source.a_elapsed_grenades.grenades_type = 2;
    CWeaponMagazinedWGrenade live;
    live.m_bGrenadeMode = grenade;
    live.count = grenade ? 1 : 17;
    live.m_ammoType = grenade ? 2 : 1;
    live.m_ammoType2 = grenade ? 1 : 2;
    live.SetAmmoElapsed2(grenade ? 17 : 1);
    live.SetAmmoElapsed(live.count);
    if (mode.find("offline") == std::string::npos) objects[800] = &live;
    if (mode == "offline-grenade") {
        Blob blob;
        return check(!items::capture_spawn_state(&source, blob), "incomplete offline GL source must refuse a replacement") ? 0 : 1;
    }
    if (mode.find("gate-") == 0 || mode == "singleplayer") {
        mirror_role = false;
        CALifeSimulator alife;
        run_lua("native_select(0)");
        if (mode == "gate-unsupported") run_lua("NATIVE_WORLD.MDATA.se_object[800].bad=function() end");
        if (mode == "singleplayer") { manager.online = false; run_lua("coop_economy_mdata=nil"); }
        fail_spawn = mode == "gate-spawn-failure";
        auto* target = try_to_clone_object(&alife, &source, "wpn_variant", Fvector{}, 0, 0, 0, mode != "gate-cancel");
        if (mode == "gate-spawn-failure" || mode == "gate-unsupported")
            return check(!target && g_clone_prepared.empty(), "Gate::Run failure compensates") && run_lua("assert(native_parts_intact(800))") ? 0 : 1;
        if (!target) return 1;
        if (mode == "gate-cancel")
            return check(cancel_unregistered_clone(target) && g_clone_prepared.empty(), "unregistered native clone cancellation restores source") && run_lua("assert(native_parts_intact(800))") ? 0 : 1;
        ItemData state;
        items::capture_entity(target, state);
        return magazines(state) && check(state.grenade_mode == grenade, "Gate::Run active mode preserved") &&
            check(g_clone_prepared.empty(), "Gate::Run committed") && (mode == "singleplayer" || run_lua("assert(native_parts_intact(900))")) ? 0 : 1;
    }
    ItemData data;
    if (mode.find("capture") == 0 || mode == "offline-rifle") {
        items::capture_entity(&source, data);
        return magazines(data) ? 0 : 1;
    }
    if (mode.find("host") == 0) {
        Blob blob;
        if (!items::capture_spawn_state(&source, blob)) return 1;
        CSE_ALifeItemWeaponMagazinedWGL target;
        const char* why = nullptr;
        if (!items::host_apply_spawn_state(&target, blob.data(), blob.size(), why)) return 1;
        items::capture_entity(&target, data);
        return magazines(data) ? 0 : 1;
    }
    CSE_ALifeItemWeaponMagazined plain;
    plain.ID = 801;
    plain.a_elapsed = 17;
    plain.ammo_type = 1;
    plain_target = mode == "plain" || mode == "stale-cse-plain";
    CWeaponMagazined live_plain;
    if (mode == "stale-cse-plain") {
        plain.a_elapsed = 3;
        live_plain.m_ammoType = 1;
        live_plain.SetAmmoElapsed(17);
        objects[801] = &live_plain;
    }
    if (mode == "unsupported-metadata")
        run_lua("NATIVE_WORLD.MDATA.se_object[800].bad = function() end");
    if (mode == "oversize-metadata")
        run_lua("NATIVE_WORLD.MDATA.se_object[800].bad = string.rep('x',4096)");
    if (mode == "envelope-oversize")
        run_lua("local e=NATIVE_WORLD.MDATA.se_object[800]; for n=4096,3500,-1 do e.bad=string.rep('x',n); if coop_economy_mdata.clone_export(800) then break end end; assert(coop_economy_mdata.clone_export(800))");
    if (mode == "uninitialized-parts")
        run_lua("for _,w in pairs(WORLDS) do w.MDATA.se_object[800].parts=nil end");
    if (mode == "queued-unload") items::g_spawns.push_back({800,0});
    CSE_Abstract* result = lua_clone(plain_target ? static_cast<CSE_Abstract*>(&plain) : &source,
                                    "wpn_variant", Fvector{}, 0, 0, 0, false);
    if (mode == "queued-unload")
        return check(!result && g_clone_prepared.empty() && items::g_spawns.size()==1,
            "queued unload retains its source instance and ammunition until the normal host request goes out") && run_lua("assert(native_parts_intact(800))") ? 0 : 1;
    if (mode == "unsupported-metadata" || mode == "oversize-metadata" || mode == "envelope-oversize") {
        return check(!result && g_clone_prepared.empty(), "invalid snapshot refuses before a speculative clone") &&
               run_lua("assert(native_parts_intact(800))") ? 0 : 1;
    }
    if (!result) return 1;
    if (mode.find("atomic") == 0 || mode.find("failure") != std::string::npos || mode == "source-identity" || mode == "uninitialized-parts") {
        if (!before_clone_register(result)) return 1;
        u16 local_created = kNoId;
        if (host_spawn(result, 0, local_created, 900) != Reason::Ok) return 1;
        if (!run_lua("NATIVE_WORLD.se_save_var(800,nil,'parts',nil)")) return 1;
        auto snapshot = g_clone_prepared.at(900);
        if (mode == "source-identity") snapshot.source_name = "wrong-instance";
        Blob envelope;
        if (!replacement::encode(snapshot, envelope)) return 1;
        if (!run_lua("native_select(0)")) return 1;
        items::discard_spawn_state(900);
        objects.erase(900);
        source.m_upgrades = {"host_upgrade"};
        Blob native;
        const bool valid = clone_state(800, 900, envelope.data(), envelope.size(), native);
        if (mode == "source-identity") {
            return check(!valid, "source instance mismatch is refused") ? 0 : 1;
        }
        if (!valid) return 1;
        CSE_Abstract* target = make_temp("wpn_variant", Fvector{}, 0, 0, 501);
        const char* why = nullptr;
        if (!items::host_apply_spawn_state(target, native.data(), native.size(), why)) return 1;
        fail_spawn = mode == "spawn-failure";
        fail_source = mode == "source-failure";
        if (mode == "activate-failure")
            run_lua("coop_economy_mdata.declare_item_key('clone_test_rider',{apply=function() error('refuse rider') end})");
        u16 created = kNoId;
        const Reason accepted = host_replace(Req{}, target, 501, created, 900, 800, envelope.data(), envelope.size());
        if (mode.find("failure") != std::string::npos) {
            bool ok = check(accepted != Reason::Ok && entities.count(800), "failed transaction retains the source");
            ok = run_lua("assert(native_parts_intact(800)); assert(NATIVE_WORLD.MDATA.se_object[900]==nil)") && ok;
            run_lua("native_select(1)");
            after_clone_register(900, false);
            return run_lua("assert(native_parts_intact(800)); assert(NATIVE_WORLD.MDATA.clone_test_rider[800].mark=='green')") && ok ? 0 : 1;
        }
        if (!check(accepted == Reason::Ok && !entities.count(800), "target committed and source removed")) return 1;
        if (!check(clone_committed(1,900,envelope.data(),envelope.size()) && !clone_committed(2,900,envelope.data(),envelope.size()), "idempotent reply is scoped to the peer and exact envelope")) return 1;
        auto altered = envelope; altered.back() ^= 1;
        if (!check(!clone_committed(1,900,altered.data(),altered.size()), "different nonce or snapshot cannot replay a commit")) return 1;
        if (mode == "uninitialized-parts")
            if (!run_lua("assert(NATIVE_WORLD.RANDOM_CALLS>0); local p=NATIVE_WORLD.MDATA.se_object[900].parts; assert(p and p.barrel<100)")) return 1;
        if (mode != "uninitialized-parts" && !run_lua("assert(native_parts_intact(900)); assert(NATIVE_WORLD.MDATA.se_object[900].dont_release==true)")) return 1;
        items::capture_entity(target, data);
        bool ok = magazines(data) && check(data.grenade_mode == grenade, "host active mode survives the clone");
        Writer message;
        if (!write_clone_initial(message, target)) return 1;
        run_lua("native_select(2)");
        if (mode == "atomic-rejoin")
            run_lua("NATIVE_WORLD.MDATA={se_object={},game_object={}}; coop_economy_mdata.clone_reset()");
        Reader input(message.data().data(), message.size());
        Blob initial;
        CSE_ALifeItemWeaponMagazinedWGL mirror;
        mirror.ID = 900;
        mirror.name = "wpn_variant900";
        if (!read_clone_initial(input, 900, initial) || !stage_clone_initial(&mirror, initial, false)) return 1;
        objects.erase(900);
        if (!run_lua("native_spawn(900,'wpn_variant'); assert((NATIVE_WORLD.RANDOM_CALLS or 0)==0); assert(NATIVE_WORLD.coop_economy_core.pack(NATIVE_WORLD.MDATA.se_object[900].parts)==WORLDS[0].coop_economy_core.pack(WORLDS[0].MDATA.se_object[900].parts))")) return 1;
        CWeaponMagazinedWGrenade mirror_object;
        objects[900] = &mirror_object;
        items::restore_spawn_state(&mirror_object, &mirror, true);
        items::capture_object(&mirror_object, data);
        ok = magazines(data) && check(data.grenade_mode == grenade, "mirror active mode survives") && ok;
        clone_finish(900, true);
        run_lua("native_select(1)");
        if (mode == "atomic-result-first" || mode == "uninitialized-parts") {
            after_clone_register(900, true);
            if (!check(g_clone_prepared.count(900) && g_clone_confirmed.count(900), "success waits for canonical metadata before unblocking")) return 1;
        }
        if (!stage_clone_initial(result, initial, true)) return 1;
        run_lua("native_destroy(800)");
        after_clone_register(900, true);
        if (!check(g_clone_prepared.empty() && g_clone_confirmed.empty(), "both success and metadata complete the local transaction")) return 1;
        ok = run_lua("tick(WORLDS[0],400); deliver_all(); assert(NATIVE_WORLD.coop_economy_core.pack(NATIVE_WORLD.MDATA.se_object[900].parts)==WORLDS[0].coop_economy_core.pack(WORLDS[0].MDATA.se_object[900].parts))") && ok;
        return ok ? 0 : 1;
    }
    items::capture_entity(result, data);
    const bool ok = plain_target ? check(data.has_main && data.main_count == 17 && data.main_type == 1 && !data.has_launcher,
                                         "plain magazine clone remains unchanged") : magazines(data);
    delete result;
    return ok ? 0 : 1;
}
