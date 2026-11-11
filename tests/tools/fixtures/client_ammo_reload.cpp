// Engine method extraction harness. Registries, ownership and transport are test doubles.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#include "coop_item_tags.h"
#include "coop_wire.h"
using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using PeerId = u16;
extern bool replacement_pending;
namespace requests { bool client_lease_waiting(u16) { return replacement_pending; } }
using LPCSTR = const char*;
constexpr u16 kNoId = 65535, kInvalidPeer = 65535;
using Blob = std::vector<u8>;
template<class T> using xr_vector = std::vector<T>;
template<class T> using xr_set = std::set<T>;
template<class K, class V> using xr_map = std::map<K, V>;
using std::size_t;
using std::uint32_t;
using coop::Writer;
using coop::Reader;
namespace itemtags = coop::itemtags;
#define VERIFY(x) assert(x)
#define TRUE true
template<class T> T _min(T a, T b) { return std::min(a,b); }
template<class T> T _max(T a, T b) { return std::max(a,b); }
template<class T, class U> T smart_cast(U* p) { return dynamic_cast<T>(p); }
int xr_strcmp(const char* a, const char* b) { return std::string(a).compare(b); }
struct shared_str {
    std::string value;
    shared_str(const char* s = "") : value(s) {}
    const char* c_str() const { return value.c_str(); }
    const char* operator*() const { return c_str(); }
    operator const char*() const { return c_str(); }
    bool operator==(const shared_str& b) const { return value == b.value; }
};
using UpgradeList = xr_vector<shared_str>;
struct Params {};
struct Flags { void set(int, bool) {} void assign(u8) {} };
struct CCartridge {
    enum { cfTracer };
    shared_str m_ammoSect, m_InvShortName;
    Params param_s;
    Flags m_flags;
    u8 m_LocalAmmoType = 0;
    int m_4to1_tracer = 0, bullet_material_idx = 0;
    void Load(const char* section, u8 type, float) { m_ammoSect = section; m_LocalAmmoType = type; }
};
class CInventory;
struct CInventoryItem {
    virtual ~CInventoryItem() = default;
    u16 id = 0, root = 0;
    shared_str section;
    float condition = 1.f;
    UpgradeList upgrades;
    CInventory* m_pInventory = nullptr;
    bool destroyed = false, dropped = false;
    u16 ID() const { return id; }
    u16 object_id() const { return id; }
    CInventoryItem& object() { return *this; }
    const shared_str& cNameSect() const { return section; }
    bool getDestroy() const { return destroyed; }
    float GetCondition() const { return condition; }
    void SetCondition(float n) { condition = n; }
    UpgradeList get_upgrades() const { return upgrades; }
    void SetDropManual(bool n) { dropped = n; }
    bool OnServer() const { return true; } // Both coop processes have an SP local server.
};
using PIItem = CInventoryItem*;
struct CWeaponAmmo : CInventoryItem {
    u16 m_boxCurr = 45, m_boxSize = 45;
    Params cartridge_param;
    bool m_tracer = false;
    int m_4to1_tracer = 0;
    shared_str NameShort() { return section; }
    bool Get(CCartridge&);
};
struct MaterialLibrary { int GetMaterialIdx(const char*) { return 0; } } GMLib;
constexpr const char* WEAPON_MATERIAL_NAME = "weapon";
class CInventory {
public:
    std::vector<PIItem> m_all;
    int invalidations = 0;
    void InvalidateState() { ++invalidations; }
    PIItem GetAny(const char* section) {
        for (auto* item : m_all) {
            auto* box = smart_cast<CWeaponAmmo*>(item);
            if (box && !box->destroyed && !box->dropped && box->m_boxCurr && !xr_strcmp(box->cNameSect(), section))
                return box;
        }
        return nullptr;
    }
};
struct CActor { CInventory inv; bool getDestroy() { return false; } CInventory& inventory() { return inv; } } actor;
CActor* Actor() { return &actor; }
struct CWeapon : CInventoryItem {
    std::vector<shared_str> m_ammoTypes = {"fmj", "ap"}, m_scopes;
    std::vector<CCartridge> m_magazine;
    CCartridge m_DefaultCartridge, m_lastCartridge;
    u8 m_ammoType = 0, m_cur_scope = 0;
    int iAmmoElapsed = 0, iMagazineSize = 15;
    float m_APk = 1.f;
    bool infinite = false;
    int GetAmmoElapsed() { return iAmmoElapsed; }
    u8 GetAddonsState() { return 0; }
    bool ScopeAttachable() { return false; }
    void SetAddonsState(u8) {} void UpdateAddonsVisibility() {} void InitAddons() {}
    void ForceUpdateAmmo() {}
    void SetAmmoElapsed(int n) {
        iAmmoElapsed = n;
        CCartridge round;
        round.Load(m_ammoTypes[m_ammoType], m_ammoType, m_APk);
        m_magazine.resize(n, round);
    }
    void consume_shot();
};
struct CWeaponMagazined : CWeapon {
    bool m_needReload = true, bMisfire = false, bClearJamOnly = false, m_bLockType = false;
    u32 m_BriefInfo_CalcFrame = 0;
    static constexpr u8 undefined_ammo_type = 255;
    u8 m_set_next_ammoType_on_reload = undefined_ammo_type;
    CWeaponAmmo* m_pCurrentAmmo = nullptr;
    bool IsMisfire() { return bMisfire; }
    bool unlimited_ammo() { return infinite; }
    // Type-changing unload is covered by the engine's separate SpawnAmmo protocol tests.
    void UnloadMagazine(bool) { assert(false && "unexpected unload in reload regression"); }
    void ReloadMagazine();
};
struct CWeaponMagazinedWGrenade : CWeaponMagazined {
    bool m_bGrenadeMode = false;
    std::vector<shared_str> m_ammoTypes2 = {"grenade"};
    std::vector<CCartridge> m_magazine2;
    u8 m_ammoType2 = 0;
    void SetAmmoElapsed2(int n) {
        CCartridge round;
        round.Load(m_ammoTypes2[m_ammoType2], m_ammoType2, m_APk);
        m_magazine2.resize(n, round);
    }
};
struct CWeaponShotgun : CWeaponMagazined {
    bool HaveCartridgeInInventory(u8) { return m_pInventory->GetAny(m_ammoTypes[m_ammoType]); }
    u8 AddCartridge(u8);
};
struct CEatableItem : CInventoryItem { u8 GetRemainingUses() { return 0; } void SetRemainingUses(u8) {} };
struct CSE_Abstract {
    virtual ~CSE_Abstract() = default;
    u16 ID = 0, root = 0;
    shared_str s_name;
};
struct CSE_ALifeInventoryItem : CSE_Abstract { float m_fCondition = 1.f; UpgradeList m_upgrades; };
struct CSE_ALifeItemAmmo : CSE_ALifeInventoryItem { u16 a_elapsed = 45, m_boxSize = 45; };
struct CSE_ALifeItemWeapon : CSE_ALifeInventoryItem {
    enum { eWeaponAddonScope = 1, eWeaponAddonSilencer = 2 };
    u16 a_elapsed = 0;
    u8 ammo_type = 0;
    Flags m_addon_flags;
    struct { u8 grenades_count = 0, grenades_type = 0; } a_elapsed_grenades;
};
struct CSE_ALifeItemWeaponMagazined : CSE_ALifeItemWeapon { u8 m_u8CurFireMode = 0; };
struct CSE_ALifeItemWeaponShotGun : CSE_ALifeItemWeaponMagazined { std::vector<u8> m_AmmoIDs; };
struct CSE_ALifeItemWeaponMagazinedWGL : CSE_ALifeItemWeaponMagazined { bool m_bGrenadeMode = false; };
bool replacement_pending = false;
namespace coop { namespace items { bool client_pending(CWeapon*) { return replacement_pending; } } }
// ITEM_TYPES
constexpr u32 kMaxBlob = 65535, kPendingMs = 30000, kGraceMs = 3000;
constexpr u32 kMadeHereMs = 120000, kTakeBaseMs = 30000;
constexpr u8 kBlobVersion = 1, kFlagAuthority = 1;
enum Tag : u8 { TagCondition=1, TagUpgrades, TagBox, TagAddons, TagScope, TagMain, TagLauncher, TagUses, TagMode, TagFireMode, TagCartridges };
enum class Op : u8 { State = 1 };
enum class Msg { ItemState };
enum class Reason { Malformed, NoProxy, Missing, Section, NotOwner, Moved, Insane };
enum class Access { Denied, Owned, Foreign };
bool host = false;
u64 now_ms = 1;
struct Manager {
    bool active() { return true; }
    bool is_live_client() { return !host; }
    u64 now_ms() { return ::now_ms; }
} manager;
Manager& mgr() { return manager; }
bool is_live_mirror() { return !host; }
bool is_map_authority() { return host; }
u16 quant(float n) { return u16(std::lround(n * 65535.f)); }
float dequant(u16 n) { return n / 65535.f; }
bool same_str(const shared_str& a, const char* b) { return a == shared_str(b); }
std::map<u16, PIItem> objects, client_objects, host_objects;
std::map<u16, CSE_Abstract*> entities, client_entities, host_entities;
PIItem find_item(u16 id) { auto it = objects.find(id); return it == objects.end() ? nullptr : it->second; }
CSE_Abstract* find_entity(u16 id) { auto it = entities.find(id); return it == entities.end() ? nullptr : it->second; }
u16 entity_root(CSE_Abstract* e) { return e->root; }
namespace join { u16 to_host(u16 n) { return n; } u16 to_local(u16 n) { return n; } u16 proxy_of_peer(PeerId) { return 10; } }
namespace sync { bool host_peer_joining(PeerId) { return false; } }
namespace ledger { void host_keeps_own_upgrades(ItemData& d) { d.has_upgrades = false; } }
namespace trade { void client_on_item_state(u16) {} }
std::vector<Blob> outgoing;
namespace net {
void client_send(Msg, Writer& w) { outgoing.push_back(w.data()); }
void host_broadcast(Msg, Writer&) {}
}
struct Stats {
    u64 sent=0, take_kept=0, authority_applied=0, authority_skipped=0, ignored=0, applied=0;
    u64 received=0, pending_dropped=0, relayed=0, enforced=0, rejected[7]={};
} g_stats;
std::map<u16, Blob> g_sent;
std::mutex g_lock;
xr_vector<u16> g_touched;
bool g_scan_now = false;
std::map<u16, TakeBase> g_take_base;
std::map<u16, Pending> g_pending;
std::map<u16, Owned> g_owned;
std::map<u16, PeerId> g_detached_silencers;
std::map<u16, int> g_unload_used;
std::set<u16> g_releasing;
std::set<u32> g_logged_tags;
struct Left { u64 time; };
std::map<u16, Left> g_left;
void drain_made_here() {}
void drain_forgotten() {}
void install_upgrades(PIItem item, const UpgradeList& list) { item->upgrades = list; }
UpgradeList spawn_upgrade_list(const shared_str&, const UpgradeList& list, bool) { return list; }
void reject(Reason, PeerId, u16, const char*) { assert(false && "unexpected rejected owner state"); }
Access host_access(PeerId, u16 proxy, CSE_Abstract* e) { return e->root == proxy ? Access::Owned : Access::Denied; }
// Production kind/count validation is unchanged. This harness focuses on state flow.
bool host_validate_kind(CSE_Abstract*, const ItemData&, const char*&) { return true; }
bool host_validate_counts(CSE_Abstract*, PIItem, const ItemData&, const char*&) { return true; }
void host_sanitize(CSE_Abstract*, PIItem, ItemData&) {}
void host_send_view(u16, CSE_Abstract*, PIItem, const Blob*, u8, PeerId) {}
void host_release_box(u16 id, CSE_Abstract*) { g_releasing.insert(id); }
void log_diverged(u16, const char*, u32, const ItemData&, const ItemData&) { assert(false); }
namespace coop { namespace items {
void touch(PIItem);
bool client_keep_empty_box(CWeaponAmmo*);
void client_before_take(u16);
}}
bool capture_entity(CSE_Abstract*, ItemData&, bool = true) { return false; }
// ENGINE_METHODS
namespace coop { namespace items {
// OWNER_HOOKS
}}

void expect(bool ok, const char* message) {
    if (!ok) { std::cerr << message << '\n'; std::exit(1); }
}
void select_host(bool value) {
    host = value;
    objects = host ? host_objects : client_objects;
    entities = host ? host_entities : client_entities;
}
void flush_owner() {
    select_host(true);
    for (const auto& bytes : outgoing) {
        Reader r(bytes.data(), bytes.size());
        expect(r.u8() == 1, "unexpected operation");
        host_on_state(1, r);
    }
    outgoing.clear();
    // The host's cosmetic proxy changed the box after the owner's report.
    // Enforcement must put the owner's count back into both host representations.
    auto saved = g_owned.find(2);
    if (saved != g_owned.end() && saved->second.data.has_box) {
        smart_cast<CWeaponAmmo*>(host_objects.at(2))->m_boxCurr = 45;
        smart_cast<CSE_ALifeItemAmmo*>(host_entities.at(2))->a_elapsed = 45;
    }
    host_enforce(now_ms);
    select_host(false);
}
Blob state(PIItem item) { Blob blob; capture_blob(item, blob); return blob; }
void push(PIItem item, const Blob& blob, bool pending = false, u8 flags = kFlagAuthority) {
    Writer w;
    write_state(w, item->id, item->section, flags, blob);
    Reader r(w.ptr(), w.size());
    expect(r.u8() == 1, "bad push envelope");
    if (pending) {
        auto* entity = entities[item->id];
        entities.erase(item->id);
        client_on_state(r);
        expect(g_pending.size() == 1, "push should wait for entity");
        entities[item->id] = entity;
        process_pending(now_ms);
        expect(g_pending.empty(), "pending state should finish");
    } else client_on_state(r);
}
int main(int argc, char** argv) {
    expect(argc == 2, "mode required");
    std::string mode = argv[1];
    CWeaponMagazinedWGrenade weapon, host_weapon;
    CWeaponShotgun shotgun;
    CWeaponAmmo box, second, host_box, host_second;
    CSE_ALifeItemAmmo box_entity, second_entity, host_box_entity, host_second_entity;
    CSE_ALifeItemWeaponMagazinedWGL weapon_entity, host_weapon_entity;
    CWeaponMagazined* gun = mode == "shotgun-empty" ? static_cast<CWeaponMagazined*>(&shotgun) : &weapon;
    gun->id = 1; gun->section = "rifle"; gun->m_pInventory = &actor.inv;
    box.id = 2; box.section = "fmj"; box.m_pInventory = &actor.inv;
    second.id = 3; second.section = "ap"; second.m_pInventory = &actor.inv;
    box.m_boxCurr = mode == "empty-box" || mode == "shotgun-empty" ? 15 : 45;
    second.m_boxCurr = 25;
    if (mode == "two-boxes") { box.m_boxCurr = 5; second.section = "fmj"; }
    if (mode == "partial-reload") box.m_boxCurr = 5;
    if (mode == "fallback-type") box.m_boxCurr = 0;
    if (mode == "mixed-types") { gun->m_ammoType = 1; box.m_boxCurr = 31; }
    if (mode == "launcher-grenades" || mode == "launcher-shot-only") {
        weapon.m_bGrenadeMode = true;
        std::swap(weapon.m_ammoTypes, weapon.m_ammoTypes2);
        box.section = "grenade";
        weapon.iMagazineSize = 1;
        weapon.SetAmmoElapsed2(7);
    }
    if (mode == "launcher-bullets") weapon.SetAmmoElapsed2(1);
    gun->SetAmmoElapsed(gun->iMagazineSize);
    auto bind = [](PIItem item, CSE_Abstract& entity, u16 root) {
        item->root = root; entity.ID = item->id; entity.root = root; entity.s_name = item->section;
    };
    bind(gun, weapon_entity, 0); bind(&box, box_entity, 0); bind(&second, second_entity, 0);
    host_weapon = weapon; host_weapon.id = 1; host_weapon.section = "rifle"; host_weapon.m_pInventory = nullptr;
    host_box = box; host_box.m_pInventory = nullptr;
    host_second = second; host_second.m_pInventory = nullptr;
    bind(&host_weapon, host_weapon_entity, 10); bind(&host_box, host_box_entity, 10); bind(&host_second, host_second_entity, 10);
    actor.inv.m_all = {gun, &box, &second};
    client_objects = {{1, gun}, {2, &box}, {3, &second}};
    host_objects = {{1, &host_weapon}, {2, &host_box}, {3, &host_second}};
    client_entities = {{1, &weapon_entity}, {2, &box_entity}, {3, &second_entity}};
    host_entities = {{1, &host_weapon_entity}, {2, &host_box_entity}, {3, &host_second_entity}};
    select_host(false);
    const Blob old_box = state(&box), old_gun = state(gun), old_second = state(&second);
    if (mode == "pending-clone-push") {
        gun->SetAmmoElapsed(3);
        replacement_pending = true;
        push(gun, old_gun);
        expect(gun->GetAmmoElapsed() == 3 && g_pending.empty(), "native push cannot cross a replacement fence or wait for its reused id");
        return 0;
    }
    if (mode == "pending-reload") {
        replacement_pending = true;
        shotgun.id = 4;
        shotgun.m_pInventory = &actor.inv;
        shotgun.SetAmmoElapsed(0);
        gun->m_needReload = true;
        gun->ReloadMagazine();
        shotgun.bMisfire = true;
        expect(shotgun.AddCartridge(2) == 2 && shotgun.bMisfire, "pending shotgun cannot consume or clear state");
        expect(gun->m_needReload && state(gun) == old_gun && state(&box) == old_box, "pending replacement cannot reload or debit reserve");
        return 0;
    }
    if (mode == "take-baseline" || mode == "take-changed") {
        coop::items::client_before_take(box.ID());
        expect(g_take_base.count(box.ID()) == 1, "take must capture a real owner baseline");
        scan_local(false); // Baseline stays authoritative even after the first scan.
        ItemData baseline;
        capture_object(&box, baseline);
        baseline.box = 37;
        Blob incoming;
        write_data(baseline, incoming);
        if (mode == "take-changed") { CCartridge round; box.Get(round); }
        push(&box, incoming);
        expect(box.m_boxCurr == (mode == "take-changed" ? 44 : 37), "first take baseline/owner change lost");
    } else if (mode == "world-item") {
        box_entity.root = 99;
        box.m_boxCurr = 11;
        push(&box, old_box, false, 0);
        expect(box.m_boxCurr == 45, "world item must accept host ammo");
    } else {
        scan_local(true);
        flush_owner();
        if (mode == "duplicate-push") { push(&box, old_box); push(gun, old_gun); }
        const int old_total = box.m_boxCurr + second.m_boxCurr + gun->iAmmoElapsed + weapon.m_magazine2.size();
        const bool reload = mode != "shot-only" && mode != "launcher-shot-only";
        int expected_box = box.m_boxCurr;
        int expected_second = second.m_boxCurr;
        int rounds_to_load = reload ? gun->iMagazineSize : 0;
        const auto& loaded_type = gun->m_ammoTypes[mode == "fallback-type" ? 1 : gun->m_ammoType];
        if (box.section == loaded_type) {
            int count = std::min(rounds_to_load, expected_box);
            expected_box -= count;
            rounds_to_load -= count;
        }
        if (second.section == loaded_type) expected_second -= std::min(rounds_to_load, expected_second);
        for (int i = 0; i < gun->iMagazineSize; ++i) gun->consume_shot();
        if (mode == "shotgun-empty") {
            g_scan_now = false;
            g_touched.clear();
            shotgun.AddCartridge(15);
            expect(g_scan_now, "shotgun reload must request the next owner scan");
            expect(std::find(g_touched.begin(), g_touched.end(), box.ID()) != g_touched.end(),
                "empty box must request its zero state before removal");
            expect(std::find(g_touched.begin(), g_touched.end(), shotgun.ID()) != g_touched.end(),
                "shotgun must request its updated magazine state");
        }
        else if (reload) gun->ReloadMagazine();
        expect(box.m_boxCurr == expected_box && second.m_boxCurr == expected_second, "reload must debit selected boxes once");
        expect(!box.dropped, "empty client box dropped before zero state reached host");
        if (mode == "delayed-before-scan") { push(&box, old_box); push(gun, old_gun); }
        scan_local(false);
        flush_owner();
        expect(host_box.m_boxCurr == expected_box && host_second.m_boxCurr == expected_second, "host must retain owner reserve");
        expect(host_box_entity.a_elapsed == expected_box, "host entity must match online box");
        if (!expected_box) expect(g_releasing.count(2), "host should release empty box after zero report");
        if (mode == "offline-push") {
            // The local server exported the spent count, then the online object went away.
            ItemData current;
            capture_object(&box, current);
            apply_entity(&box_entity, current, false);
            objects.erase(2);
            push(&box, old_box);
            expect(box_entity.a_elapsed == expected_box, "late host push restored offline owner entity");
            objects[2] = &box;
        }
        if (mode == "mixed-magazine") {
            gun->m_magazine[0].m_LocalAmmoType = 1;
            gun->m_magazine[0].m_ammoSect = "ap";
        }
        if (mode != "delayed-before-scan" && mode != "shotgun-empty") {
            u8 flags = mode == "owner-relay" ? 0 : kFlagAuthority;
            push(&box, old_box, mode == "pending-push", flags);
            push(gun, old_gun, false, flags);
            push(&second, old_second, false, flags);
        }
        expect(box.m_boxCurr == expected_box && second.m_boxCurr == expected_second, "late host ItemState restored spent reserve");
        const int total = box.m_boxCurr + second.m_boxCurr + gun->iAmmoElapsed + weapon.m_magazine2.size();
        expect(total == old_total - gun->iMagazineSize, "fire + reload must spend exactly fired rounds");
        scan_local(false);
        flush_owner();
        expect(host_box.m_boxCurr == expected_box && host_second.m_boxCurr == expected_second, "owner echo refunded ammo on host");
        if (mode == "fallback-type") expect(gun->m_ammoType == 1 && host_weapon.m_ammoType == 1, "fallback ammo type lost on host round trip");
        if (mode == "mixed-magazine") expect(gun->m_magazine[0].m_LocalAmmoType == 1, "push homogenized mixed magazine");
        if (mode == "three-magazines") {
            for (int cycle = 0; cycle < 2; ++cycle) {
                for (int i = 0; i < gun->iMagazineSize; ++i) gun->consume_shot();
                gun->ReloadMagazine();
                expected_box -= gun->iMagazineSize;
                scan_local(false);
                flush_owner();
                push(&box, old_box); push(gun, old_gun);
                expect(box.m_boxCurr == expected_box && host_box.m_boxCurr == expected_box,
                       "repeated fire/reload refunded or double-charged reserve");
            }
        }
        if (mode == "ownership-return") {
            actor.inv.m_all.erase(actor.inv.m_all.begin() + 1);
            scan_local(false); // Leaving inventory retires g_sent's ownership entry.
            box_entity.root = 99;
            push(&box, old_box, false, 0);
            TakeBase base;
            capture_object(&box, base.data);
            g_take_base[2] = base;
            box_entity.root = 0;
            actor.inv.m_all.push_back(&box);
            scan_local(false);
            ItemData fresh;
            capture_object(&box, fresh);
            fresh.box = 21;
            Blob incoming;
            write_data(fresh, incoming);
            push(&box, incoming);
            expect(box.m_boxCurr == 21, "new ownership must receive its fresh host baseline");
        }
        if (mode == "launcher-bullets") expect(weapon.m_magazine2.size() == 1, "main reload changed grenade magazine");
        if (mode == "launcher-grenades") expect(weapon.m_magazine2.size() == 7, "GL reload changed bullet magazine");
    }
    std::cout << mode << " OK\n";
}
