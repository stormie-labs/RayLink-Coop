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
    # all work packages landed (2026-10-20 17:59); project files are patched separately
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
