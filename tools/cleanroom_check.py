"""Clean-room check: no block of lines of our scripts is shared with another project's scripts.

Owner 2026-10-29: "the scripts may mean the same, the code must be ours - no line-for-line copy". The 2026-10-20 port of
another co-op's behaviour (W4) had kept 21 short blocks identical to it; this check found them and now guards the rule.

A block is BLOCK (default 3) consecutive meaningful lines (comments stripped, whitespace and trailing ';' ignored, at
least MIN_LEN characters) that also stand consecutively in one of the other project's files. Code both have from stock
Anomaly (--stock) is not counted: both may keep the game's own code. Single identical lines are API idioms
(pcall(function(), time_global(), RegisterScriptCallback...) and are only counted.

  python -I tools/cleanroom_check.py --theirs D:/Projects/ForEverything/xrRazom-RE/extracted
      [--theirs <more dirs>] [--stock ../anomaly-ref/unpacked/scripts] [--ours gamedata/scripts]

Exit 0: no shared block. Exit 1: shared blocks, listed. Exit 2: a folder is missing.
"""
import argparse
import pathlib
import re
import sys

MIN_LEN = 20


def norm(line):
    s = re.sub(r"--.*$", "", line.strip()).strip()
    return re.sub(r"\s+", "", s).rstrip(";")


def meaningful(path):
    out = []
    text = path.read_bytes().decode("utf-8", "replace")
    for number, line in enumerate(text.splitlines(), 1):
        n = norm(line)
        if len(n) >= MIN_LEN:
            out.append((number, n))
    return out


def windows(lines, size):
    return {tuple(x[1] for x in lines[i:i + size]) for i in range(len(lines) - size + 1)}


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--theirs", action="append", required=True, help="a folder of the other project (repeatable)")
    ap.add_argument("--stock", default=str(root.parent / "anomaly-ref" / "unpacked" / "scripts"))
    ap.add_argument("--ours", default=str(root / "gamedata" / "scripts"))
    ap.add_argument("--block", type=int, default=3)
    args = ap.parse_args()

    for folder in [args.stock, args.ours] + args.theirs:
        if not pathlib.Path(folder).is_dir():
            print(f"missing folder: {folder}")
            return 2

    stock = set()
    for p in pathlib.Path(args.stock).glob("*.script"):
        stock |= windows(meaningful(p), args.block)
    theirs = {}
    for folder in args.theirs:
        for p in pathlib.Path(folder).rglob("*"):
            if p.suffix not in (".script", ".ltx", ".lua"):
                continue
            for w in windows(meaningful(p), args.block):
                if w not in stock:
                    theirs.setdefault(w, p.name)

    shared = []
    singles = 0
    their_lines = {line for w in theirs for line in w}
    for p in sorted(pathlib.Path(args.ours).glob("coop_*.script")):
        lines = meaningful(p)
        singles += sum(1 for _, n in lines if n in their_lines)
        i = 0
        while i <= len(lines) - args.block:
            w = tuple(x[1] for x in lines[i:i + args.block])
            if w in theirs:
                j = i
                while j + args.block <= len(lines) and tuple(x[1] for x in lines[j:j + args.block]) in theirs:
                    j += 1
                shared.append((p.name, lines[i][0], lines[j + args.block - 2][0], theirs[w]))
                i = j + args.block - 1
            else:
                i += 1

    print(f"shared blocks of {args.block}+ consecutive lines: {len(shared)}; single identical lines: {singles}")
    for name, first, last, other in shared:
        print(f"  {name}:{first}-{last}  (as in {other})")
    return 1 if shared else 0


if __name__ == "__main__":
    sys.exit(main())
