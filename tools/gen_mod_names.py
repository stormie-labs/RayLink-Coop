"""Refresh the L12 script inventory from an unpacked GAMMA stand and stock Anomaly."""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path
from typing import Sequence

# -I omits the script directory and ignores PYTHONDONTWRITEBYTECODE.
if __name__ == "__main__":
    sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import check_layers as layers


def script_stems(folder: Path) -> set[str]:
    return {path.stem for path in folder.glob("*.script") if path.is_file()}


def grep_import(engine: Path, commit: str, candidates: set[str], flags: Sequence[str]) -> str:
    if not candidates:
        return ""
    if commit.startswith("-"):
        raise layers.InputError(f"invalid import ref: {commit!r}")
    with tempfile.TemporaryDirectory(prefix="mod-names-") as temporary:
        patterns = Path(temporary) / "words.txt"
        with patterns.open("x", encoding="utf-8", newline="\n") as output:
            output.write("\n".join(sorted(candidates)) + "\n")
        done = subprocess.run(
            ["git", "-C", str(engine), "grep", "-I", *flags, "-w", "-F", "-f", str(patterns),
             commit, "--", "src", ":!src/3rd party"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
        )
    # git grep returns 1 when there are no matches.
    if done.returncode not in (0, 1) or done.stderr.strip():
        raise layers.InputError(f"git grep {commit} failed (exit {done.returncode}): {done.stderr.strip()}")
    return done.stdout


def read_import_words(engine: Path, commit: str, candidates: set[str]) -> set[str]:
    return set(grep_import(engine, commit, candidates, ("-h", "-o")).split()) & candidates


def read_import_code_words(engine: Path, commit: str, candidates: set[str]) -> set[str]:
    """For hand rows, confirm that the import hit is outside comments (3DSS is a comment in the import)."""
    sources = []
    for hit in grep_import(engine, commit, candidates, ("-l", "-z")).split("\0"):
        if not hit:
            continue
        path = hit.partition(":")[2]
        if Path(path).suffix.lower() not in layers.CPP_SUFFIXES:
            continue
        done = subprocess.run(["git", "-C", str(engine), "show", hit], capture_output=True)
        if done.returncode:
            raise layers.InputError(f"git show {hit} failed (exit {done.returncode}): {layers.decode(done.stderr)}")
        raw = layers.decode(done.stdout)
        sources.append(layers.Source(path, "stock", "cpp", raw, *layers.strip_both(raw, layers.CPP_TOKENS, "/")))
    return {token for line in layers.mod_lines(sources, candidates)
            for token in line.code_tokens + line.string_tokens}


def refresh(root: Path, stand: Path, stock: Path, build: str,
            import_ref: str, import_file: Path | None) -> int:
    if not layers.MOD_BUILD_TAG.fullmatch(build):
        raise layers.InputError(f"invalid build tag: {build!r}")
    for directory in (stand, stock):
        if not directory.is_dir():
            raise layers.InputError(f"missing scripts directory: {directory}")

    path = root / "tools/mod_names.txt"
    previous = path.read_bytes().decode("utf-8") if path.is_file() else ""
    raw_lines = previous.splitlines(keepends=True)
    rows = layers.parse_mod_names(previous)
    scripts = {row.token: row.build_or_debt for row in rows if row.kind == "script"}
    builds = {row.token: raw_lines[row.line - 1].rstrip("\r\n") for row in rows if row.kind == "build"}
    hand_words = [row for row in rows if row.kind == "name" or (row.kind == "debt" and not row.scope)]

    stand_stems = script_stems(stand)
    stock_stems = {stem.casefold() for stem in script_stems(stock)}
    local_stems = set().union(*(script_stems(root / folder)
                                for folder in (*layers.STOCK_LUA_ROOTS, "gamedata/scripts")))
    derived = {stem for stem in stand_stems - local_stems
               if stem.casefold() not in stock_stems and re.fullmatch(r"[A-Za-z_]\w*", stem)}
    candidates = derived | {row.token for row in hand_words}
    import_words = (set(layers.parse_names(import_file.read_text(encoding="utf-8"))) & candidates
                    if import_file is not None else read_import_words(root / "engine", import_ref, candidates))
    dropped = derived & import_words
    print(f"gen_mod_names: dropped {len(dropped)} import word(s): {', '.join(sorted(dropped)) or '(none)'}")
    import_hand = import_words.intersection(row.token for row in hand_words)
    if import_file is None and import_hand:
        import_hand = read_import_code_words(root / "engine", import_ref, import_hand)
    refused = [row for row in hand_words if row.token in import_hand]
    for row in refused:
        print(f"gen_mod_names: refusing tools/mod_names.txt:{row.line}: {row.kind} '{row.token}' "
              f"is spelled by the GSC import {import_ref}")
    if refused:
        return 1

    listed = derived - dropped
    ignored = {row.token for row in rows if row.kind == "ignore"}
    new = listed - scripts.keys()
    check = new - ignored
    if check:
        layer_map = layers.parse_layers((root / "tools/layers.txt").read_text(encoding="utf-8"), root)
        sources = layers.collect(root, layer_map)
        collisions = set()
        for line in layers.mod_lines((src for src in sources if src.layer != "stock"), check):
            # Show the first collision for each stem.
            for token in sorted(set(line.code_tokens + line.string_tokens) - collisions):
                print(f"gen_mod_names: refusing script '{token}': {line.path}:{line.number} "
                      "already names it; add an ignore row if it is a plain word")
                collisions.add(token)
        if collisions:
            return 1

    absent = scripts.keys() - stand_stems
    print(f"gen_mod_names: keeping {len(absent)} earlier stem(s) absent from this stand: "
          f"{', '.join(sorted(absent)) or '(none)'}")
    for stem in new:
        scripts[stem] = build

    provenance = f"{stand.as_posix()} {len(stand_stems)} {len(listed)}"
    # Keep the original date when a rerun yields the same provenance for this tag.
    old_build = builds.get(build, "").split("#", 1)[0].split(None, 3)
    if len(old_build) != 4 or old_build[3] != provenance:
        builds[build] = f"build {build} {date.today().isoformat()} {provenance}"
    generated = "".join(builds[tag] + "\n" for tag in sorted(builds))
    generated += "".join(f"script {stem} {scripts[stem]}\n" for stem in sorted(scripts))
    generated_lines = {row.line for row in rows if row.kind in ("build", "script")}
    result = generated + "".join(line for n, line in enumerate(raw_lines, 1) if n not in generated_lines)
    layers.parse_mod_names(result)
    if result != previous:
        # Stage on the repository volume so replacing the inventory is atomic, even when TEMP is on another drive.
        staging = root / "temp"
        staging.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="mod-names-", dir=staging) as temporary:
            pending = Path(temporary) / path.name
            with pending.open("xb") as output:
                output.write(result.encode("utf-8"))
            pending.replace(path)
    print(f"gen_mod_names: {len(stand_stems)} stand stems, {len(derived)} candidates, {len(listed)} listed "
          f"for {build}, {len(scripts)} total ({'wrote' if result != previous else 'unchanged'} {path})")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stand-scripts", required=True, type=Path)
    parser.add_argument("--stock-scripts", required=True, type=Path)
    parser.add_argument("--build", required=True)
    parser.add_argument("--import", dest="import_ref", default="ad9d8416")
    parser.add_argument("--import-words", type=Path, help="read import matches from a file (test hook)")
    parser.add_argument("--root", type=Path, default=layers.ROOT)
    args = parser.parse_args(argv)
    try:
        return refresh(args.root.resolve(), args.stand_scripts.resolve(), args.stock_scripts.resolve(),
                       args.build, args.import_ref, args.import_words)
    except (OSError, UnicodeError, layers.InputError) as error:
        print(f"gen_mod_names: {error}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
