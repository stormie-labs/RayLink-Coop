"""Overlay this repository's top layers (Core gamedata\\, GAMMA gamedata_gamma\\) and the CI exe on a launcher-made
stand (a materialized game root with one merged gamedata\\), keeping everything it replaces.

    python -I tools/stand_overlay.py <stand> <backup dir> [--dry] [--no-exe]

- A file is copied only when the stand has none or its bytes differ.
- What is replaced goes to <backup dir>\\<relative path> first (never overwritten by a later run: the first backup is
  the stand's original). Files the stand did not have are listed in <backup dir>\\new_files.txt.
- The Engine layer (engine\\gamedata, the lowest priority in MO2) is NOT overlaid: on a merged root it would replace
  files that mods override. Deploy it by hand when engine\\gamedata changes.
- Revert: copy <backup dir> back over the stand and delete the files of new_files.txt.
"""
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_NAMES = {"axr_options.ltx", "cache_dbg.ltx"}
SKIP_EXT = {".bak", ".tmp", ".log", ".orig"}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    dry = "--dry" in sys.argv
    stand, backup = Path(args[0]), Path(args[1])
    if not (stand / "gamedata").is_dir() or not (stand / "bin").is_dir():
        sys.exit(f"not a game root: {stand}")
    jobs = []
    for layer in ("gamedata", "gamedata_gamma"):  # the later layer wins
        base = ROOT / layer
        if not base.is_dir():
            continue
        for src in sorted(base.rglob("*")):
            if not src.is_file() or src.name in SKIP_NAMES or src.suffix.lower() in SKIP_EXT:
                continue
            rel = src.relative_to(base)
            if "temp" in rel.parts or "__pycache__" in rel.parts:
                continue
            jobs.append((src, Path("gamedata") / rel))
    if "--no-exe" not in sys.argv:
        jobs.append((ROOT / "engine-ci/_build/_game/bin_dbg/AnomalyDX11AVX.exe", Path("bin/AnomalyCoopDX11AVX.exe")))
    latest = {}
    for src, rel in jobs:
        latest[rel] = src  # a GAMMA-layer file replaces the Core one of the same path
    copied, added = [], []
    for rel, src in latest.items():
        dst = stand / rel
        data = src.read_bytes()
        if dst.is_file() and dst.read_bytes() == data:
            continue
        if dst.is_file():
            keep = backup / rel
            if not keep.exists() and not dry:
                keep.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, keep)
            copied.append(rel)
        else:
            added.append(rel)
        if not dry:
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_bytes(data)
    if added and not dry:
        backup.mkdir(parents=True, exist_ok=True)
        listed = backup / "new_files.txt"
        known = set(listed.read_text(encoding="utf-8").splitlines()) if listed.exists() else set()
        listed.write_text("\n".join(sorted(known | {r.as_posix() for r in added})) + "\n", encoding="utf-8")
    print(f"{'would replace' if dry else 'replaced'} {len(copied)}, {'would add' if dry else 'added'} {len(added)}")
    for rel in copied:
        print("  ~", rel.as_posix())
    for rel in added:
        print("  +", rel.as_posix())


if __name__ == "__main__":
    main()
