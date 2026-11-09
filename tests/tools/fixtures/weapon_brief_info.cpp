// Engine method bodies and II_BriefInfo are supplied from the current source by pytest.
#include <cassert>
#include <cstdio>
#include <string>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#endif

using u8 = unsigned char;
using u32 = unsigned int;
using LPCSTR = const char*;
using string32 = char[32];
#define IC inline
#define VERIFY(condition) ((void)0) // The reported crash is a release build.
constexpr int WEAPON_ININITE_QUEUE = -1;

struct shared_str : std::string
{
    using std::string::string;
    using std::string::operator=;
    void _set(const char* value) { assign(value); }
};

template <size_t N, typename... Args>
void xr_sprintf(char (&output)[N], const char* format, Args... args)
{
    std::snprintf(output, N, format, args...);
}

#include "brief_info_type.inc"

struct Inventory
{
    u32 frame = 10;
    u32 ModifyFrame() const { return frame; }
};

struct Settings
{
    const char* r_string(const char*, const char*) { return "ammo-short-name"; }
} settings;
Settings* pSettings = &settings;

struct CStringTable
{
    const char* translate(const char* text) { return text; }
};

struct Cartridge { u8 m_LocalAmmoType = 0; };

struct CWeaponMagazined
{
    Inventory* m_pInventory = nullptr;
    u32 m_BriefInfo_CalcFrame = 0;
    bool bHasBulletsToHide = false;
    int last_hide_bullet = 0, bullet_cnt = 10, m_iQueueSize = -1, ammo_elapsed = 7;
    std::vector<shared_str> m_ammoTypes = {"ammo-a", "ammo-b", "ammo-c"};
    std::vector<Cartridge> m_magazine;
    u8 m_ammoType = 0;
    int GetAmmoElapsed() const { return ammo_elapsed; }
    bool HasFireModes() const { return true; }
    bool unlimited_ammo() const { return false; }
    int GetSuitableAmmoTotal() { m_BriefInfo_CalcFrame = m_pInventory->ModifyFrame(); return 40; }
    int GetAmmoCount(u8 type) const { return 40 + type; }
    bool GetBriefInfo(II_BriefInfo& info);
};

struct CWeaponMagazinedWGrenade : CWeaponMagazined
{
    bool m_bGrenadeMode = false;
    std::vector<shared_str> m_ammoTypes2 = {"ammo-g"};
    u8 m_ammoType2 = 0;
    int GetAmmoCount2(u8 type) const { return 80 + type; }
    bool IsGrenadeLauncherAttached() const { return true; }
    bool GetBriefInfo(II_BriefInfo& info);
};

#include "brief_info_methods.inc"

template <typename Weapon>
void check_transfer(Weapon& weapon, const char* primary_ammo, const char* secondary_ammo,
    const char* third_ammo, const char* grenade_ammo)
{
    Inventory inventory;
    II_BriefInfo info;
    weapon.m_pInventory = &inventory;
    assert(weapon.GetBriefInfo(info));
    assert(info.cur_ammo == "7" && info.fire_mode == "A" && info.icon == "ammo-a");
    assert(info.fmj_ammo == primary_ammo && info.ap_ammo == secondary_ammo);
    assert(info.third_ammo == third_ammo && info.grenade == grenade_ammo);
    const auto icon = info.icon;
    weapon.ammo_elapsed = 4;
    assert(!weapon.GetBriefInfo(info));
    assert(info.cur_ammo == "4" && info.icon == icon);
    assert(info.fmj_ammo == primary_ammo && info.ap_ammo == secondary_ammo);
    assert(info.third_ammo == third_ammo && info.grenade == grenade_ammo);

    // HUD info can outlive inventory ownership during an arena gear exchange.
    weapon.m_pInventory = nullptr;
    info.name = info.icon = info.cur_ammo = info.fmj_ammo = "stale";
    info.ap_ammo = info.third_ammo = info.fire_mode = info.grenade = "stale";
    assert(!weapon.GetBriefInfo(info));
    assert(info.name.empty() && info.icon.empty() && info.cur_ammo.empty());
    assert(info.fmj_ammo.empty() && info.ap_ammo.empty() && info.third_ammo.empty());
    assert(info.fire_mode.empty() && info.grenade.empty());

    // Returning the weapon within the same modification frame must rebuild cleared info.
    weapon.m_pInventory = &inventory;
    assert(weapon.GetBriefInfo(info));
    assert(info.cur_ammo == "4" && info.icon == "ammo-a");
    assert(info.fmj_ammo == primary_ammo && info.ap_ammo == secondary_ammo);
    assert(info.third_ammo == third_ammo && info.grenade == grenade_ammo);
}

int main(int argc, char** argv)
{
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
#endif
    assert(argc == 2);
    if (std::string(argv[1]) == "magazine")
    {
        CWeaponMagazined weapon;
        check_transfer(weapon, "40", "41", "42", "");
    }
    else
    {
        CWeaponMagazinedWGrenade weapon;
        weapon.m_bGrenadeMode = std::string(argv[1]) == "launcher-grenades";
        if (weapon.m_bGrenadeMode)
            check_transfer(weapon, "80", "", "", "40");
        else
            check_transfer(weapon, "40", "41", "42", "80");
    }
    puts("attached, cached, detached and restored HUD info passed");
}
