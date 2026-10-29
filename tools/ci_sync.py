"""Copy finished work from the main engine tree into the engine-ci worktree for a test build.

Files owned by work packages that are still in progress are skipped (patterns below), so their
half-written edits never reach a test build. New coop sources that are copied get registered in
the CI xrGame.vcxproj. Usage: python tools/ci_sync.py [--dry] [--committed] [--build N]
  --committed  build only what is committed: a file changed in the working tree goes in as its HEAD version, an
               untracked file stays out (night runs while agents edit the tree, 2026-10-23)
  --build N    number this CI build: the exe calls itself "RayLink Engine bN" (window title, main menu, log, crash
               dialogs) and tools/package.ps1 -Version 0.N.0 accepts it. Without it the CI tree is a development build,
               "RayLink Engine dev". Only src/xrCore/raylink_build.h of the CI tree changes (the main tree keeps 0), and
               only when the number changes, so MSBuild recompiles just the few files that name the engine.
"""
import fnmatch
import re
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

# The engine's build number. Not copied: the CI tree's copy is written by --build (write_build_number).
BUILD_HEADER = "src/xrCore/raylink_build.h"
BUILD_DEFINE = re.compile(rb"^#define RAYLINK_BUILD[ \t]+\d+[ \t]*$", re.M)

# .rc: the exe's version resource (src/xrEngine/resource.rc names the engine in the file properties)
SOURCE_EXT = (".cpp", ".h", ".hpp", ".inl", ".c", ".md", ".rc")
SOURCE_DIRS = ("src/xrGame", "src/xrCoop", "src/xrEngine", "src/xrServerEntities", "src/xrCore", "src/Layers",
               "src/xrSound")  # Native instrument playback extends the sound interface as well as xrGame.


def same_text(a: Path, b: Path) -> bool:
    return b.is_file() and a.read_bytes().replace(b"\r\n", b"\n") == b.read_bytes().replace(b"\r\n", b"\n")


_TRACKED = None


def tracked_path(rel: str) -> str:
    """The path as git tracks it. The disk may spell it in another case (src/xrEngine/igame_persistent.h on disk,
    IGame_Persistent.h in git): git show is case-sensitive, so the committed header was skipped and the build failed
    (2026-10-23, build 10a)."""
    global _TRACKED
    if _TRACKED is None:
        out = subprocess.run(["git", "-C", str(MAIN), "ls-files"], capture_output=True, text=True, check=True).stdout
        _TRACKED = {line.lower(): line for line in out.splitlines()}
    return _TRACKED.get(rel.lower(), rel)


def head_bytes(rel: str):
    """The committed (HEAD) content of a main-tree file, or None when HEAD has no such file."""
    r = subprocess.run(["git", "-C", str(MAIN), "show", f"HEAD:{tracked_path(rel)}"], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def changed_files():
    """Uncommitted files plus every source file whose content differs from the CI tree: committed work
    in the main tree is not in the CI worktree either (git status alone missed it, 2026-10-20 19:45).
    Yields (path, untracked)."""
    out = subprocess.run(["git", "-C", str(MAIN), "status", "--porcelain", "-uall"], capture_output=True,
                         text=True, check=True).stdout
    seen = set()
    for line in out.splitlines():
        path = line[3:].strip().strip('"')
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.replace("\\", "/")
        seen.add(path)
        yield path, line.startswith("??")
    for d in SOURCE_DIRS:
        for src in (MAIN / d).rglob("*"):
            if src.suffix.lower() not in SOURCE_EXT or not src.is_file():
                continue
            rel = src.relative_to(MAIN).as_posix()
            if rel not in seen and not same_text(src, CI / rel):
                yield rel, False


def build_number_arg(argv) -> int:
    """--build N (N >= 1) gives N; no --build gives 0, a development build."""
    if "--build" not in argv:
        return 0
    i = argv.index("--build")
    value = argv[i + 1] if i + 1 < len(argv) else ""
    if not re.fullmatch(r"[1-9][0-9]{0,5}", value):
        sys.exit(f"ci_sync: --build needs a build number (1, 2, ...), got {value!r}")
    return int(value)


def write_build_number(build: int, dry: bool, committed: bool) -> str:
    """Makes the CI tree's raylink_build.h say RAYLINK_BUILD `build` (0 = dev): the main tree's file (its HEAD version
    with --committed) with the number replaced. Written only when the text changes: a fresh mtime makes MSBuild recompile
    every file that names the engine. Returns what happened."""
    base = head_bytes(BUILD_HEADER) if committed else None
    if base is None:
        base = (MAIN / BUILD_HEADER).read_bytes()
    text, n = BUILD_DEFINE.subn(b"#define RAYLINK_BUILD %d" % build, base.replace(b"\r\n", b"\n"), count=1)
    if n != 1:
        sys.exit(f"ci_sync: no '#define RAYLINK_BUILD <n>' line in {MAIN / BUILD_HEADER}")
    dst = CI / BUILD_HEADER
    if dst.is_file() and dst.read_bytes().replace(b"\r\n", b"\n") == text:
        return "unchanged"
    if dry:
        return "would be written"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(text.replace(b"\n", b"\r\n"))
    return "written"


def main():
    dry = "--dry" in sys.argv
    committed = "--committed" in sys.argv
    build = build_number_arg(sys.argv)
    copied, skipped, new_coop = [], [], []
    for rel, untracked in changed_files():
        if rel == BUILD_HEADER:
            continue  # the build number: write_build_number below
        if any(fnmatch.fnmatch(rel, pat) for pat in SKIP) or (committed and untracked):
            skipped.append(rel)
            continue
        src = MAIN / rel
        if not src.is_file():
            continue
        dst = CI / rel
        data = head_bytes(rel) if committed else src.read_bytes()
        if data is None:
            skipped.append(rel)
            continue
        if dst.is_file() and dst.read_bytes().replace(b"\r\n", b"\n") == data.replace(b"\r\n", b"\n"):
            continue  # already there: copying would only force a rebuild
        if not dry:
            dst.parent.mkdir(parents=True, exist_ok=True)
            # a fresh write (fresh mtime), or MSBuild keeps the old .obj of an older source
            dst.write_bytes(data)
        copied.append(rel)
        if rel.startswith("src/xrGame/coop/") and rel.endswith((".cpp", ".h")):
            new_coop.append("coop\\" + Path(rel).name)
    if new_coop and not dry:
        subprocess.run([sys.executable, str(ROOT / "tools" / "vcxproj_add.py"),
                        str(CI / "src/xrGame/xrGame.vcxproj"), "Coop", *new_coop], check=True)
    state = write_build_number(build, dry, committed)
    print(f"copied {len(copied)}:", *copied, sep="\n  ")
    print(f"skipped {len(skipped)} (work in progress):", *skipped, sep="\n  ")
    print(f"engine build: RayLink Engine {'b%d' % build if build else 'dev'} ({BUILD_HEADER} {state})")


if __name__ == "__main__":
    main()
