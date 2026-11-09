"""Execute engine zone transitions and hit creation with a local-server transport stub."""
import os
from pathlib import Path
import re
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]


def definition(source, signature):
    start = source.index(signature)
    depth = 0
    for match in re.finditer(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|[{}]', source[start:], re.DOTALL):
        if match.group() == "{":
            depth += 1
        elif match.group() == "}":
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise ValueError(signature)


@pytest.fixture(scope="function")
def campfire_runner(work):
    game = ROOT / "engine/src/xrGame"
    custom = (game / "CustomZone.cpp").read_text(encoding="utf-8-sig")
    fire = (game / "ZoneCampfire.cpp").read_text(encoding="utf-8-sig")
    overrides = [name for name in ("SwitchZoneState", "OnStateSwitch")
                 if f"void CZoneCampfire::{name}(" in fire]
    methods = [definition(custom, signature) for signature in (
        "bool CCustomZone::AwakingState(", "bool CCustomZone::BlowoutState(",
        "bool CCustomZone::AccumulateState(", "void CCustomZone::CheckForAwaking(",
        "void CCustomZone::SwitchZoneState(", "void CCustomZone::OnStateSwitch(",
        "void CCustomZone::CreateHit(")]
    methods += [definition(fire, f"void CZoneCampfire::{name}(") for name in overrides]
    declarations = "\n".join(f"void {name}(EZoneState) override;" for name in overrides)
    source = HARNESS.replace("// FIRE_DECLARATIONS", declarations).replace("// ENGINE_METHODS", "\n".join(methods))
    fixture = work / "campfire.cpp"
    fixture.write_text(source, encoding="utf-8")
    runner = work / ("campfire.exe" if os.name == "nt" else "campfire")
    if os.name == "nt":
        vcvars = Path(os.environ.get("VCVARS", r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"))
        assert vcvars.exists(), "MSVC Build Tools required for this regression"
        command = work / "compile.cmd"
        command.write_text(
            f'@echo off\ncall "{vcvars}" >nul\nif errorlevel 1 exit /b 1\n'
            f'cl /nologo /EHsc /std:c++17 /Od /utf-8 "{fixture}" /Fe"{runner}"\n'
            'exit /b %ERRORLEVEL%\n', encoding="utf-8")
        build = ["cmd", "/d", "/c", str(command)]
    else:
        compiler = shutil.which("c++")
        assert compiler, "C++17 compiler required for this regression"
        build = [compiler, "-std=c++17", str(fixture), "-o", str(runner)]
    result = subprocess.run(build, cwd=work, capture_output=True, text=True, errors="replace", timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    return runner


@pytest.mark.parametrize("mode", ["mirror", "host", "map-server", "single", "ordinary-zone"])
def test_campfire_damage_cycle(campfire_runner, mode):
    result = subprocess.run([str(campfire_runner), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr


HARNESS = r'''
#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
using u8 = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using s16 = int16_t;
struct Fvector {};
namespace ALife { enum EHitType { burn }; }
enum { GE_ZONE_STATE_CHANGE = 1, GE_HIT = 2, eZoneIsActive = 1, eBlowoutDisableIdle = 2 };
bool mirror = false, active = true;
int actor_hits = 0, npc_hits = 0, relayed_states = 0;
struct NET_Packet { int type = 0; u16 target = 0; u8 state = 0; void w_u8(u8 s) { state = s; } };
class CCustomZone;
namespace coop {
bool is_mirror() { return mirror; }
namespace objects {
bool zone_switch_blocked(CCustomZone*) { return mirror; }
int on_zone_state(CCustomZone*, u8) { if (active && !mirror) ++relayed_states; return 0; }
// Existing ownership contract: local actor 0, player proxy 10, NPC 20.
bool zone_hit_blocked(CCustomZone*, u16 target) {
    return active && (mirror ? target != 0 : target == 10);
}
}}
bool OnServer() { return true; } // Coop runs a single-player local server on every process.
struct SHit {
    u16 whoID = 0, weaponID = 0, target = 0;
    SHit(float, Fvector, CCustomZone*, s16, Fvector, float, ALife::EHitType, float, bool) {}
    void GenHeader(int, u16 id) { target = id; }
    void Write_Packet(NET_Packet& p) { p.type = GE_HIT; p.target = target; }
};
struct Flags { unsigned bits = eZoneIsActive; bool test(unsigned b) { return (bits & b) != 0; } };
class CCustomZone {
public:
    enum EZoneState { eZoneStateIdle, eZoneStateAwaking, eZoneStateBlowout, eZoneStateAccumulate, eZoneStateDisabled };
    using inherited = CCustomZone;
    EZoneState m_eZoneState = eZoneStateIdle;
    int m_iStateTime = 0, m_iPreviousStateTime = 0;
    int m_StateTime[5] = {0, 1, 2, 1, 0};
    Flags m_zone_flags;
    bool m_bBlowoutOnce = false;
    u32 m_owner_id = u32(-1);
    virtual ~CCustomZone() = default;
    virtual void SwitchZoneState(EZoneState);
    virtual void OnStateSwitch(EZoneState);
    void CheckForAwaking();
    bool AwakingState(); bool BlowoutState(); bool AccumulateState();
    void Enable() {} void Disable() {} void PlayAccumParticles() {} void PlayAwakingParticles() {}
    void PlayIdleParticles() {} void StopIdleParticles() {} void ZoneDisable() { SwitchZoneState(eZoneStateDisabled); }
    u16 ID() { return 123; } EZoneState ZoneState() { return m_eZoneState; }
    void CreateHit(u16, u16, const Fvector&, float, s16, const Fvector&, float, ALife::EHitType);
    void u_EventGen(NET_Packet& p, int type, u16 id) { p.type = type; p.target = id; }
    void u_EventSend(NET_Packet& p) {
        if (p.type == GE_ZONE_STATE_CHANGE) OnStateSwitch(EZoneState(p.state));
        else if (p.target == 0) ++actor_hits;
        else ++npc_hits;
    }
    // Scheduler boundary. The phase methods and CreateHit below come from the engine unchanged.
    void tick() {
        ++m_iStateTime;
        switch (m_eZoneState) {
        case eZoneStateIdle: CheckForAwaking(); break;
        case eZoneStateAwaking: AwakingState(); break;
        case eZoneStateBlowout:
            if (m_iStateTime == 1) {
                for (u16 target : {0, 10, 20})
                    CreateHit(target, ID(), {}, 0.5f, 0, {}, 0, ALife::burn);
            }
            BlowoutState(); break;
        case eZoneStateAccumulate: AccumulateState(); break;
        default: break;
        }
    }
};
class CZoneCampfire : public CCustomZone {
public:
    using inherited = CCustomZone;
    // FIRE_DECLARATIONS
};
// ENGINE_METHODS
int main(int argc, char** argv) {
    assert(argc == 2);
    std::string mode = argv[1];
    mirror = mode == "mirror" || mode == "ordinary-zone";
    active = mode != "single";
    CZoneCampfire fire;
    CCustomZone ordinary;
    CCustomZone& zone = mode == "ordinary-zone" ? ordinary : fire;
    for (int i = 0; i < 16; ++i) zone.tick();
    if (mode == "ordinary-zone") {
        assert(actor_hits == 0 && zone.ZoneState() == CCustomZone::eZoneStateIdle);
        return 0;
    }
    if (actor_hits == 0) {
        std::cerr << "lit campfire failed to hurt local actor, phase=" << zone.ZoneState() << "\n";
        return 1;
    }
    if (mirror) {
        assert(actor_hits == 5 && npc_hits == 0 && relayed_states == 0);
        auto state = zone.ZoneState();
        zone.OnStateSwitch(CCustomZone::eZoneStateIdle); // bulk host snapshot while client stands in fire
        assert(zone.ZoneState() == state);
        zone.OnStateSwitch(CCustomZone::eZoneStateBlowout);
        assert(zone.ZoneState() == state);
    } else {
        assert(npc_hits > 0);
        assert(!active || relayed_states > 0);
    }
    zone.OnStateSwitch(CCustomZone::eZoneStateDisabled); // host extinguishes
    int before = actor_hits;
    for (int i = 0; i < 8; ++i) zone.tick();
    assert(actor_hits == before);
    zone.OnStateSwitch(CCustomZone::eZoneStateIdle); // host relights
    for (int i = 0; i < 8; ++i) zone.tick();
    assert(actor_hits > before);
    std::cout << mode << " damage cycle OK\n";
}
'''
