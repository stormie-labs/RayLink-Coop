#include <cstdint>
#include <iostream>
#include <map>
#include <vector>
#include "coop_clone_slot.h"
using u16 = std::uint16_t;
using u64 = std::uint64_t;
namespace cloneslot = coop::cloneslot;
constexpr u16 kNoId = 65535, kActor = 0, NO_ACTIVE_SLOT = 65535;
constexpr int eItemPlaceRuck = 0, eItemPlaceSlot = 1;
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
struct CGameObject { virtual ~CGameObject() = default; };
struct CInventory;
struct CInventoryItem : CGameObject {
    CInventory* m_pInventory = nullptr;
    int place = eItemPlaceRuck;
    int CurrPlace() const { return place; }
};
struct CInventory {
    bool occupied = false;
    int restores = 0;
    u16 LastSlot() const { return 10; }
    bool ItemFromSlot(u16) const { return occupied; }
    void Slot(u16 slot, CInventoryItem* item) {
        if (slot != 2) throw 1;
        ++restores;
        item->place = eItemPlaceSlot;
    }
};
struct CActor : CGameObject {
    CInventory inv;
    CInventory& inventory() { return inv; }
};
struct Registry {
    std::map<u16, CGameObject*> entries;
    CGameObject* net_Find(u16 id) { return entries[id]; }
};
struct ServerRegistry {
    bool present = false;
    bool ID_to_entity(u16) const { return present; }
};
struct LevelState {
    Registry Objects;
    ServerRegistry server;
    ServerRegistry* Server = &server;
} level;
LevelState& Level() { return level; }
struct AlifeRegistry {
    bool present = false;
    bool object(u16, bool) const { return present; }
} alife_registry;
struct Alife { AlifeRegistry& objects() { return alife_registry; } } alife;
struct Ai { Alife& alife() { return ::alife; } } ai_state;
Ai& ai() { return ai_state; }
struct Lock {} g_out_lock;
struct xrCriticalSectionGuard { explicit xrCriticalSectionGuard(Lock&) {} };
cloneslot::Book g_clone_slots;
std::vector<u16> g_give_back_wait, g_give_back;
// SLOT_METHODS

bool check(bool passed, const char* description) {
    if (!passed) std::cerr << "FAILED " << description << '\n';
    return passed;
}
int main() {
    CActor actor;
    CInventoryItem source;
    CGameObject clone;
    source.m_pInventory = &actor.inv;
    level.Objects.entries[0] = &actor;
    level.Objects.entries[800] = &source;
    level.Objects.entries[900] = &clone; // clone in the rucksack, its source's slot is free
    g_clone_slots.plan(900, 800, 2, 1000);
    g_clone_slots.spawn_slot(900, false);
    g_clone_slots.refused(900, 1100);
    g_give_back_wait.push_back(900);
    poll_removals(1200);
    clone_slots_frame(1200);
    bool ok = check(actor.inv.restores == 0 && g_give_back.empty(), "live game object blocks restore and id return");
    level.Objects.entries[900] = nullptr;
    level.server.present = true;
    poll_removals(1300);
    clone_slots_frame(1300);
    ok = check(actor.inv.restores == 0 && g_give_back.empty(), "server entity blocks restore") && ok;
    level.server.present = false;
    alife_registry.present = true;
    poll_removals(1400);
    clone_slots_frame(1400);
    ok = check(actor.inv.restores == 0 && g_give_back.empty(), "ALife entity blocks restore") && ok;
    alife_registry.present = false;
    poll_removals(1500);
    level.Objects.entries[800] = nullptr;
    clone_slots_frame(1500);
    ok = check(g_clone_slots.size() == 1, "missing source object keeps its restore") && ok;
    level.Objects.entries[800] = &source;
    actor.inv.occupied = true;
    clone_slots_frame(1600);
    ok = check(actor.inv.restores == 0 && g_clone_slots.size() == 1, "another item keeps its occupied slot") && ok;
    actor.inv.occupied = false;
    clone_slots_frame(1700);
    clone_slots_frame(1800);
    ok = check(actor.inv.restores == 1 && source.place == eItemPlaceSlot && g_clone_slots.size() == 0,
               "source restored once after clone removal") && ok;
    return ok ? 0 : 1;
}
