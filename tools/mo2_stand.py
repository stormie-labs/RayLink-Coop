"""Materialize a Mod Organizer 2 profile into a plain game folder (test stand) with hard links.

Two game instances through MO2's USVFS on one machine are unreliable, so the stand is a real folder: the files of
the enabled mods of a profile are hard-linked into --out in MO2's priority order, the way the game sees them in MO2.
Layers, lowest priority first (docs/MO2_GAMMA.md §3):
  1. the game folder (--game; in GAMMA its gamedata holds the modded exes), without its appdata\\;
  2. --layer-bottom (our engine: Anomaly Coop - Engine);
  3. the enabled mods of the profile (modlist.txt: first line = highest priority);
  4. MO2's overwrite folder;
  5. --layer-top, in the given order (Anomaly Coop - Core, then Anomaly Coop - GAMMA).
Paths are compared without case (Windows); meta.ini in a mod's root and *.mohidden files are left out, as in MO2.

Hard links share the data with the original, so a write into a linked file would change the mod in MO2's folder.
Files the game or mod scripts write at runtime are therefore copied (see runtime_written), our own layers are
copied as well (the repo lives on another volume), and nothing is ever written into an existing file: a changed
entry is unlinked first. The stand is rebuilt incrementally: the manifest (.mo2_stand.json in --out) remembers what
was placed, entries whose source did not change are left alone, entries no longer wanted are removed. Files the
stand did not place (appdata_a, bin_b, fsgame_a.ltx ...) are never touched.

Usage: python tools/mo2_stand.py --mo2 E:\\GAMMA --profile G.A.M.M.A --game E:\\Anomaly --out E:\\AnomalyCoopGamma
         [--layer-bottom [PREFIX=]DIR ...] [--layer-top [PREFIX=]DIR ...] [--report temp\\mo2_stand_report.txt]
PREFIX is where the layer's root lands in the stand: gamedata=D:\\...\\engine\\gamedata puts it into gamedata\\.
"""
import argparse
import json
import os
import shutil
import stat
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

MANIFEST = ".mo2_stand.json"
TOP_CONFLICTS = 20
TOP_LAYERS = 6  # layers shown per conflict in the report, the winner last


@dataclass
class Layer:
    name: str
    root: Path
    prefix: str = ""  # where the layer's root lands in the stand, "/"-separated; "" = the stand's root
    copy: bool = False  # copy instead of hard-linking (our layers)
    kind: str = "mod"  # game | mod | overwrite | ours


@dataclass
class Report:
    files: int = 0
    conflicts: dict[str, list[str]] = field(default_factory=dict)  # path as the winner spells it -> layers, low to high
    removed: int = 0
    seconds: float = 0.0
    mods: int = 0  # mod layers that exist on disk
    linked: int = 0
    copied: int = 0
    unchanged: int = 0
    changed: list[str] = field(default_factory=list)  # sources that changed since the last run
    missing: list[str] = field(default_factory=list)  # enabled mods without a folder


def read_modlist(path) -> list[str]:
    """Enabled mods of an MO2 modlist.txt, lowest priority first, without separators.
    MO2 writes the highest priority first; '+' enabled, '-' disabled, '*' unmanaged (not in the mods folder)."""
    mods = []
    for line in Path(path).read_text(encoding="utf-8-sig").splitlines():
        if not line.startswith("+"):
            continue
        name = line[1:].strip()
        if name and not name.endswith("_separator"):
            mods.append(name)
    mods.reverse()
    return mods


def parse_layer_spec(spec: str) -> Layer:
    """[PREFIX=]DIR -> one of our layers (always copied)."""
    prefix, sep, rest = spec.partition("=")
    if not sep:
        prefix, rest = "", spec
    root = Path(rest)
    return Layer(name=str(root), root=root, prefix=prefix.replace("\\", "/").strip("/"), copy=True, kind="ours")


def build_layers(game, bottom, mods_dir, mods, overwrite, tops) -> list[Layer]:
    layers = [Layer(name="<game>", root=Path(game), kind="game")]
    layers += list(bottom)
    layers += [Layer(name=m, root=Path(mods_dir) / m) for m in mods]
    if overwrite is not None:
        layers.append(Layer(name="<overwrite>", root=Path(overwrite), kind="overwrite"))
    layers += list(tops)
    return layers


def runtime_written(rel: str) -> bool:
    """Places the game and GAMMA's scripts write into while running (checked 2026-10-22): the stand's root (MCM
    appends fsgame.ltx), appdata\\ (presets, Ironman state), gamedata\\ root (ZCP's awr_table.txt),
    gamedata\\configs\\ root (axr_options.ltx, 3DSS and laser caches - some of them shipped by the mods) and the
    text files next to the exe (ReShade writes ReShade.ini, its presets and dxgi.log there)."""
    parts = rel.lower().split("/")
    if len(parts) == 1 or parts[0] == "appdata":
        return True
    if parts[0] == "bin" and len(parts) == 2 and parts[1].endswith((".ini", ".log", ".txt")):
        return True
    return parts[0] == "gamedata" and (len(parts) == 2 or (len(parts) == 3 and parts[1] == "configs"))


def layer_files(layer: Layer):
    """(rel, source, size, mtime_ns) of every file of a layer; rel is "/"-separated and carries the prefix."""
    base = str(layer.root)
    stack = [(base, "")]
    while stack:
        folder, rel_dir = stack.pop()
        with os.scandir(folder) as it:
            for e in it:
                rel = f"{rel_dir}/{e.name}" if rel_dir else e.name
                if e.is_dir(follow_symlinks=False):
                    if layer.kind == "game" and not rel_dir and e.name.lower() == "appdata":
                        continue  # the owner's own appdata; the instances get appdata_a/_b
                    if e.name.lower() == ".git":
                        continue  # a mod's git checkout (350- Ledge Grabbing): never game data, read-only objects
                    stack.append((e.path, rel))
                    continue
                if not e.is_file(follow_symlinks=False):
                    continue
                low = e.name.lower()
                if low.endswith(".mohidden") or (not rel_dir and low == "meta.ini" and layer.kind == "mod"):
                    continue
                # os.stat, not the directory entry: NTFS updates the entry only for the name that was written, so a
                # game write through the stand's link would stay invisible here
                st = os.stat(e.path)
                yield (f"{layer.prefix}/{rel}" if layer.prefix else rel), e.path, st.st_size, st.st_mtime_ns


def _inside(path: str, folder: str) -> bool:
    path, folder = os.path.normcase(path).rstrip("\\/"), os.path.normcase(folder).rstrip("\\/")
    return path == folder or path.startswith(folder + os.sep)


def _overlaps(a: str, b: str) -> bool:
    return _inside(a, b) or _inside(b, a)


class _Dirs:
    """Creates the stand's folders; refuses to go through a junction or symlink (the stock deploy makes db a
    junction to the real game: a hard link through it would land in the game's folder)."""

    def __init__(self, out: Path):
        self.out = out
        self.ok: set[str] = set()

    def ensure(self, rel_dir: str) -> None:
        cur = self.out
        for part in rel_dir.split("/") if rel_dir else []:
            cur = cur / part
            key = os.path.normcase(str(cur))
            if key in self.ok:
                continue
            if os.path.islink(cur) or os.path.isjunction(cur):
                raise SystemExit(f"refusing to write through a link: {cur} (remove it, the stand builds a real folder)")
            if not cur.exists():
                cur.mkdir()
            elif not cur.is_dir():
                raise SystemExit(f"a file stands where the stand needs a folder: {cur}")
            self.ok.add(key)


def _delete_ignoring_readonly(path: str) -> None:
    """Delete one name of a read-only file without touching the attribute, which a hard link shares with the mod's
    original (FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE, Windows 10 1809+, NTFS)."""
    import ctypes
    from ctypes import wintypes

    k32 = ctypes.WinDLL("kernel32", use_last_error=True)
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID, wintypes.DWORD,
                                wintypes.DWORD, wintypes.HANDLE]
    k32.SetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    k32.CloseHandle.argtypes = [wintypes.HANDLE]
    delete_access, share_all, open_existing, open_reparse_point = 0x00010000, 0x7, 3, 0x00200000
    file_disposition_info_ex = 21
    flags = ctypes.c_ulong(0x1 | 0x2 | 0x10)  # DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
    handle = k32.CreateFileW(path, delete_access, share_all, None, open_existing, open_reparse_point, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        if not k32.SetFileInformationByHandle(handle, file_disposition_info_ex, ctypes.byref(flags),
                                              ctypes.sizeof(flags)):
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        k32.CloseHandle(handle)


def _unlink(path: Path) -> None:
    try:
        os.unlink(path)
    except PermissionError:
        if sys.platform != "win32" or os.access(path, os.W_OK):
            raise
        _delete_ignoring_readonly(str(path))


def _place(src: str, dst: Path, copy: bool) -> None:
    if os.path.lexists(dst):
        if dst.is_dir() and not os.path.islink(dst):
            raise SystemExit(f"a folder stands where the stand needs a file: {dst}")
        _unlink(dst)  # never write into an existing file: it may be a hard link to a mod's original
    if copy:
        shutil.copy2(src, dst)
        if not os.access(dst, os.W_OK):
            os.chmod(dst, stat.S_IWRITE | stat.S_IREAD)  # our own copy: the game must be able to write it
        return
    try:
        os.link(src, dst)
    except OSError as e:
        raise SystemExit(f"hardlink impossible: {src} -> {dst} ({e}). The stand must be on the same volume as the "
                         f"game and the mods; nothing is copied instead.") from e


def _prune_empty(path: Path, out: Path) -> None:
    for parent in path.parents:
        if parent == out or out not in parent.parents:
            return
        try:
            parent.rmdir()
        except OSError:
            return


def materialize(layers: list[Layer], out) -> Report:
    started = time.perf_counter()
    out = Path(out)
    report = Report()
    real_out = os.path.realpath(out)
    for layer in layers:
        if _overlaps(real_out, os.path.realpath(layer.root)):
            raise SystemExit(f"--out {out} overlaps layer {layer.name} ({layer.root})")

    # what the game would see: the highest layer wins, paths compared without case
    want: dict[str, tuple[str, str, int, int, bool]] = {}  # key -> rel, src, size, mtime_ns, copy
    providers: dict[str, list[str]] = {}
    for layer in layers:
        if not layer.root.is_dir():
            if layer.kind == "mod":
                report.missing.append(layer.name)
            elif layer.kind != "overwrite":
                raise SystemExit(f"layer folder not found: {layer.root}")
            continue
        if layer.kind == "mod":
            report.mods += 1
        for rel, src, size, mtime in layer_files(layer):
            key = rel.lower()
            want[key] = (rel, src, size, mtime, layer.copy or runtime_written(rel))
            providers.setdefault(key, []).append(layer.name)

    manifest_path = out / MANIFEST
    old: dict[str, list] = {}
    if manifest_path.is_file():
        old = json.loads(manifest_path.read_text(encoding="utf-8"))
    elif out.is_dir() and any(out.iterdir()):
        raise SystemExit(f"{out} is not a stand built by mo2_stand: not empty and no {MANIFEST} (a stock deploy "
                         f"root?); use an empty folder")
    out.mkdir(parents=True, exist_ok=True)

    # 1. every folder first: a junction or a symlink anywhere stops the run before a single file is written
    dirs = _Dirs(out)
    for parent in {rel.rpartition("/")[0] for rel, *_ in want.values()}:
        dirs.ensure(parent)

    state = dict(old)  # what really lies in the stand; saved even when a step below fails
    try:
        # 2. remove what is no longer wanted (before placing: a file may have turned into a folder)
        real_out = os.path.realpath(out)
        for key, prev in old.items():
            if key in want:
                continue
            dst = out / prev[0]
            if not _inside(os.path.realpath(dst.parent), real_out):
                raise SystemExit(f"refusing to delete through a link: {dst} resolves outside {out}")
            if os.path.lexists(dst) and not dst.is_dir():
                _unlink(dst)
                _prune_empty(dst, out)
            del state[key]
            report.removed += 1

        # 3. place what changed
        for key, (rel, src, size, mtime, copy) in want.items():
            entry = [rel, src, size, mtime, "copy" if copy else "link"]
            dst = out / rel
            prev = old.get(key)
            if prev is not None and prev[1:] == entry[1:] and os.path.lexists(dst):
                report.unchanged += 1
                continue
            if prev is not None and prev[1] == src and prev[2:4] != entry[2:4]:
                report.changed.append(rel)
            _place(src, dst, copy)
            state[key] = entry
            if copy:
                report.copied += 1
            else:
                report.linked += 1
    finally:
        tmp = manifest_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, manifest_path)

    report.files = len(want)
    report.conflicts = {want[k][0]: names for k, names in providers.items() if len(names) > 1}
    report.changed.sort()
    report.seconds = round(time.perf_counter() - started, 1)
    return report


def _noise(rel: str) -> bool:
    """Readmes, images and fomod folders in the mods' roots: MO2 shows them too, the game never reads them."""
    return "/" not in rel or rel.lower().startswith("fomod/")


def format_report(report: Report, out, layers: list[Layer]) -> str:
    kinds = [layer.kind for layer in layers]
    lines = [
        f"mo2 stand   {out}",
        f"layers      {len(layers)} (game {kinds.count('game')}, mods {report.mods}, overwrite "
        f"{kinds.count('overwrite')}, ours {kinds.count('ours')}); enabled mods without a folder: {len(report.missing)}",
        f"files       {report.files} (linked {report.linked}, copied {report.copied}, unchanged {report.unchanged}), "
        f"removed {report.removed}",
        f"time        {report.seconds} s",
    ]
    for name in report.missing:
        lines.append(f"missing     {name!r}")
    if report.changed:
        lines.append(f"changed     {len(report.changed)} sources changed since the last run (a game write through a "
                     f"link shows up here too):")
        lines += [f"  {rel}" for rel in report.changed[:50]]
    real = {rel: names for rel, names in report.conflicts.items() if not _noise(rel)}
    lines.append(f"conflicts   {len(report.conflicts)} paths come from more than one layer ({len(real)} outside the "
                 f"mods' readmes and fomod folders); top {TOP_CONFLICTS}, winner last:")
    for rel, names in sorted(real.items(), key=lambda kv: (-len(kv[1]), kv[0].lower()))[:TOP_CONFLICTS]:
        shown = names[-TOP_LAYERS:]
        more = f"(+{len(names) - len(shown)} below) " if len(names) > len(shown) else ""
        lines.append(f"  {rel}  [{len(names)}]  {more}{' > '.join(shown)}")
    return "\n".join(lines) + "\n"


def main(argv=None) -> Report:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mo2", required=True, help="MO2 instance folder (portable), with mods\\, overwrite\\, profiles\\")
    ap.add_argument("--profile", required=True)
    ap.add_argument("--game", required=True, help="the game folder MO2 manages")
    ap.add_argument("--out", required=True, help="stand folder; must be on the same volume as --game and the mods")
    ap.add_argument("--layer-bottom", action="append", default=[], metavar="[PREFIX=]DIR")
    ap.add_argument("--layer-top", action="append", default=[], metavar="[PREFIX=]DIR")
    ap.add_argument("--report", help="also write the report to this file")
    args = ap.parse_args(argv)

    mo2 = Path(args.mo2)
    modlist = mo2 / "profiles" / args.profile / "modlist.txt"
    if not modlist.is_file():
        raise SystemExit(f"modlist not found: {modlist}")
    layers = build_layers(Path(args.game), [parse_layer_spec(s) for s in args.layer_bottom], mo2 / "mods",
                          read_modlist(modlist), mo2 / "overwrite", [parse_layer_spec(s) for s in args.layer_top])
    report = materialize(layers, args.out)
    text = format_report(report, args.out, layers)
    sys.stdout.write(text)
    if args.report:
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(text, encoding="utf-8")
    return report


if __name__ == "__main__":
    main()
