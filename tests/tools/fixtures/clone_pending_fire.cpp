// Rendering/input are framework doubles. FireEnd/UpdateCL and the firing predicate are production source.
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

using u32 = std::uint32_t;
#define PROF_EVENT() ((void)0)
template<class T, class U> T smart_cast(U* value) { return dynamic_cast<T>(value); }
template<class T> void clamp(T& value, T low, T high) { value = std::clamp(value, low, high); }
constexpr float flt_max = std::numeric_limits<float>::max();
struct { float fTimeDelta = 0.016f; } Device;
bool g_auto_reload = false;
bool pending = true;

struct CInventoryItem { virtual ~CInventoryItem() = default; };
struct CActor : CInventoryItem {};
struct CShootingObject {
    bool bWorking = true;
    void FireEnd();
};
struct CWeapon : CInventoryItem, CShootingObject {
    virtual void UpdateCL() {}
    void StopShotEffector() {}
    CInventoryItem* H_Parent() { return nullptr; }
    void* m_pInventory = nullptr;
    int iAmmoElapsed = 17;
protected:
    virtual void FireEnd();
};
namespace coop { namespace items { bool client_pending(CWeapon*) { return pending; } } }
struct CWeaponMagazined : CWeapon {
    using inherited = CWeapon;
    enum { eShowing, eHiding, eReload, eIdle, eFire };
    bool m_bFireSingleShot = true, m_pendingShot = true;
    int m_iQueueSize = -1, m_iShotNum = 0, state_fire_calls = 0;
    float fShotTimeCounter = -1.f;
    std::vector<int> m_magazine = std::vector<int>(17);
    int GetState() { return eFire; }
    int GetNextState() { return eFire; }
    bool IsWorking() { return bWorking; }
    void Reload() {}
    void UpdateSounds() {}
    void FireEnd() override;
    void UpdateCL() override;
    virtual void state_Fire(float) {
        ++state_fire_calls;
        while (ACTUAL_FIRE_PREDICATE) {
            m_bFireSingleShot = false;
            m_magazine.pop_back();
            --iAmmoElapsed;
            ++m_iShotNum;
        }
    }
};
struct CustomWeapon : CWeaponMagazined {
    void state_Fire(float) override { ++state_fire_calls; --iAmmoElapsed; }
};
// ACTUAL_METHODS

bool check(bool value, const char* message) {
    if (!value) std::cerr << message << '\n';
    return value;
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    const std::string mode = argv[1];
    CWeaponMagazined normal;
    CustomWeapon custom;
    CWeaponMagazined& weapon = mode == "custom-handler" ? custom : normal;
    pending = mode != "ordinary";
    weapon.FireEnd();
    if (!check(!weapon.bWorking, "FireEnd must stop bWorking")) return 1;
    if (mode == "latches")
        return check(!weapon.m_bFireSingleShot && !weapon.m_pendingShot, "pending FireEnd must cancel single-shot and deferred input latches") ? 0 : 1;
    if (pending) {
        // A queued eFire state can set the latch again after the first FireEnd.
        weapon.m_bFireSingleShot = true;
        weapon.m_pendingShot = true;
    }
    weapon.UpdateCL();
    if (!pending)
        return check(weapon.iAmmoElapsed == 16 && weapon.state_fire_calls == 1, "ordinary tap keeps its one-shot semantics") ? 0 : 1;
    return check(weapon.iAmmoElapsed == 17 && weapon.state_fire_calls == 0 && !weapon.m_bFireSingleShot && !weapon.m_pendingShot,
                 "pending UpdateCL must stop a queued shot before virtual state_Fire") ? 0 : 1;
}
