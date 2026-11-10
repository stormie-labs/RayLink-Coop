// Compile the production spawn/drop methods; only engine dependencies are stubbed.
#include <cstdlib>
#include <iostream>
#include <string>
#define VERIFY(value) do { if (!(value)) std::abort(); } while (0)
using BOOL = bool;
constexpr bool FALSE = false, TRUE = true;
template <class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
struct shared_str {
    std::string value;
    shared_str(const char* text = "") : value(text) {}
    const char* operator*() const { return value.c_str(); }
};
struct CSE_Abstract { virtual ~CSE_Abstract() = default; bool player = false; };
struct CSE_ALifeTraderAbstract : CSE_Abstract {
    enum { eTraderFlagInfiniteAmmo = 1 };
    struct { bool test(int) const { return true; } } m_trader_flags;
};
namespace coop::world {
bool is_player_character(const CSE_Abstract* object) { return object->player; }
}
struct CInventoryItem {
    virtual ~CInventoryItem() = default;
    int rounds = 0;
    bool useful_for_NPC() const { return rounds > 0; }
    shared_str cNameSect() const { return shared_str("ammo_5.45x39_fmj"); }
};
struct CWeaponAmmo : CInventoryItem { int m_boxSize = 15; };
struct Actor {
    bool alive = true;
    bool g_Alive() const { return alive; }
    int Position() const { return 0; }
    int ID() const { return 8524; }
    struct Location { int level_vertex_id() const { return 0; } };
    Location ai_location() const { return {}; }
};
struct Planner {
    Actor actor;
    int removed = 0;
    Actor& object() { return actor; }
    void remove_item(CInventoryItem*) { ++removed; }
};
struct GameLevel {
    int supplied = 0;
    void spawn_item(const char*, int, int, int) { ++supplied; }
} game_level;
GameLevel& Level() { return game_level; }
int g_ai_unlimited_ammo = 1;
struct Base {
    int dropped = 0;
    BOOL net_Spawn(CSE_Abstract*) { return true; }
    void OnItemDrop(CInventoryItem*, bool) { ++dropped; }
};
struct CObjectHandler : Base {
    using inherited = Base;
    bool m_infinite_ammo = false, m_inventory_actual = true;
    shared_str m_item_to_spawn;
    int m_ammo_in_box_to_spawn = 0, torches = 0;
    Planner plan;
    Planner& planner() { return plan; }
    void switch_torch(CInventoryItem*, bool) { ++torches; }
    BOOL net_Spawn(CSE_Abstract*);
    void OnItemDrop(CInventoryItem*, bool);
};
#include "ammo_supply_methods.inc"
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const std::string mode = argv[1];
    CSE_ALifeTraderAbstract entity;
    entity.player = mode == "player" || mode == "parked-player";
    CObjectHandler handler;
    handler.plan.actor.alive = mode != "npc-dead";
    g_ai_unlimited_ammo = mode != "npc-disabled";
    if (!handler.net_Spawn(&entity)) return 3;
    CWeaponAmmo first, second;
    first.rounds = second.rounds = mode == "full-box" ? 15 : mode == "partial-box" ? 4 : 0;
    handler.OnItemDrop(&first, true);
    handler.OnItemDrop(&second, true);
    const int expected = mode == "npc" ? 2 : 0;
    if (game_level.supplied != expected) {
        std::cerr << mode << ": destroyed 2 boxes, expected " << expected
                  << " replacements, got " << game_level.supplied << '\n';
        return 4;
    }
    if (handler.dropped != 2 || handler.plan.removed != 2 || handler.torches != 2 || handler.m_inventory_actual)
        return 5;
    if (entity.player && handler.m_infinite_ammo) return 6;
    return 0;
}
