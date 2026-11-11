#include <cassert>
#include <string>
namespace ALife { enum { eAddonAttachable = 2 }; }
struct CSE_ALifeItemWeapon { enum { eWeaponAddonScope = 1, eWeaponAddonSilencer = 2, eWeaponAddonGrenadeLauncher = 4 }; };
static int spawned = 0;
static bool client = false;
struct CInventoryItemObject {
    bool Detach(const char*, bool spawn) { spawned += spawn ? 1 : 0; return true; }
};
struct Hud { void detach_item(int*) {} } hud;
auto g_player_hud = &hud;
template<class T> void xr_delete(T*& value) { value = nullptr; }
void Msg(const char*) {}
struct CWeaponMagazined : CInventoryItemObject {
    using inherited = CInventoryItemObject;
    int m_eScopeStatus = 0, m_eSilencerStatus = 2, m_eGrenadeLauncherStatus = 0;
    int m_flagsAddOnState = 2, m_zoomtype = 0;
    int* m_scopeItem = nullptr;
    bool m_modular_attachments = false;
    std::string m_sSilencerName = "wpn_sil_tgpv", m_sGrenadeLauncherName;
    bool DetachScope(const char*, bool) { return false; }
    void UpdateAddonsVisibility() {}
    void InitAddons() {}
    void SetZoomTypeAndParams(int) {}
    bool Detach(const char*, bool);
};
namespace coop {
namespace items { void touch(CWeaponMagazined*) {} }
namespace requests { bool client_detach_silencer(CWeaponMagazined*, const char*) { return client; } }
}
#include "detach.inc"
int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string mode = argv[1];
    CWeaponMagazined gun;
    client = mode != "host";
    if (mode == "already-detached") gun.m_flagsAddOnState = 0;
    const bool spawn = mode != "accepted";
    const bool result = gun.Detach("wpn_sil_tgpv", spawn);
    if (mode == "client") {
        assert(!result); // Pending/refused: do not tell the script that detach completed.
        assert(gun.m_flagsAddOnState == 2);
        assert(spawned == 0);
    } else {
        assert(result);
        assert(gun.m_flagsAddOnState == 0);
        assert(spawned == (mode == "host" ? 1 : 0));
    }
}
