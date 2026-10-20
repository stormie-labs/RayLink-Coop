"""Copy finished work from the main engine tree into the engine-ci worktree for a test build.

Files owned by work packages that are still in progress are skipped (patterns below), so their
half-written edits never reach a test build. New coop sources that are copied get registered in
the CI xrGame.vcxproj. Usage: python tools/ci_sync.py [--dry]
"""
import fnmatch
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "engine"
CI = ROOT / "engine-ci"

# Work packages still running: their files stay out of the test build.
SKIP = [
    # WP2 events & requests
    "src/xrGame/coop/coop_events.*", "src/xrGame/coop/coop_requests.*", "src/xrGame/Level_network.cpp",
    "src/xrGame/xrServer_process_event*.cpp", "src/xrGame/alife_simulator_script.cpp",
    "src/xrGame/ai/stalker/ai_stalker_fire.cpp", "src/xrGame/Actor.cpp",
    # WP6 dialogs / trade / containers
    "src/xrGame/coop/coop_dialog.*", "src/xrGame/coop/coop_trade.*", "src/xrGame/PhraseDialog*",
    "src/xrGame/AI_PhraseDialogManager.cpp", "src/xrGame/PhraseDialogManager.cpp", "src/xrGame/ui/UITalk*",
    "src/xrGame/ui/UIActorMenu*", "src/xrGame/Trade*.cpp", "src/xrGame/ai/trader/ai_trader.cpp",
    "src/xrGame/InventoryBox.cpp",
    # WP7 world objects
    "src/xrGame/coop/coop_objects.*", "src/xrGame/PhysicObject.cpp", "src/xrGame/BreakableObject.cpp",
    "src/xrGame/DestroyablePhysicsObject.cpp", "src/xrGame/PHDestroyable.cpp", "src/xrGame/CustomZone.cpp",
    "src/xrGame/ZoneCampfire.cpp", "src/xrGame/Artefact.cpp", "src/xrGame/artefact_activation.cpp",
    "src/xrGame/Explosive.cpp", "src/xrGame/Missile.cpp", "src/xrGame/Grenade.cpp", "src/xrGame/Bolt.cpp",
    "src/xrGame/Car*.cpp", "src/xrGame/Helicopter*.cpp", "src/xrGame/WeaponStatMgun*.cpp",
    # WP8 survival & presence
    "src/xrGame/coop/coop_survival.*", "src/xrGame/coop/coop_presence.*", "src/xrGame/ActorCondition.cpp",
    "src/xrGame/HUDManager.cpp", "src/xrGame/ui/UIHudStatesWnd*", "src/xrGame/Spectator.cpp",
    # WP9 owned item state
    "src/xrGame/coop/coop_items.*", "src/xrGame/Weapon*.cpp", "src/xrGame/inventory_item.cpp",
    "src/xrGame/eatable_item.cpp", "src/xrGame/ui/UIInvUpgrade*", "src/xrGame/inventory_upgrade*",
    # project files are patched separately
    "src/xrGame/xrGame.vcxproj", "src/xrGame/xrGame.vcxproj.filters",
]


def changed_files():
    out = subprocess.run(["git", "-C", str(MAIN), "status", "--porcelain", "-uall"], capture_output=True,
                         text=True, check=True).stdout
    for line in out.splitlines():
        path = line[3:].strip().strip('"')
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        yield path.replace("\\", "/")


def main():
    dry = "--dry" in sys.argv
    copied, skipped, new_coop = [], [], []
    for rel in changed_files():
        if any(fnmatch.fnmatch(rel, pat) for pat in SKIP):
            skipped.append(rel)
            continue
        src = MAIN / rel
        if not src.is_file():
            continue
        dst = CI / rel
        if not dry:
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        copied.append(rel)
        if rel.startswith("src/xrGame/coop/") and rel.endswith((".cpp", ".h")):
            new_coop.append("coop\\" + Path(rel).name)
    if new_coop and not dry:
        subprocess.run([sys.executable, str(ROOT / "tools" / "vcxproj_add.py"),
                        str(CI / "src/xrGame/xrGame.vcxproj"), "Coop", *new_coop], check=True)
    print(f"copied {len(copied)}:", *copied, sep="\n  ")
    print(f"skipped {len(skipped)} (work in progress):", *skipped, sep="\n  ")


if __name__ == "__main__":
    main()
