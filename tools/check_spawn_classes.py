"""Check the ReqSpawn class table (engine/src/xrCoop/coop_spawn.h, kClassRules, F2 T2) against its sources.

A client may ask the host only for items of the game's item classes. The table must hold exactly those classes, each
with the server entity class the factory builds for it:
  engine  engine/src/xrServerEntities/object_factory_register.cpp: ADD(client, server, id, name) whose server class
          is CSE_ALifeItem* or CSE_Temporary (a launcher's rocket), before `if (!g_dedicated_server) return;` (the
          ADDs after it exist only on a dedicated server: in the game such an id names no class at all). Ids come
          from clsid_game.h (MK_CLSID) or TEXT2CLSID("...").
  scripts the class registrators of the game: configs\\script.ltx [common] class_registrators with its DLTX mods
          (mod_script_*.ltx: `>class_registrators = ...` adds, `<` removes), e.g. class_registrator.register and the
          engine layer's class_registrator_modded_exes.register. Each cs_register(factory, client, "module.class",
          "ID", name) whose Lua server class derives from a cse_alife_item* class (module.script); the engine
          classes behind the Lua names come from xrServerEntities/xrServer_Objects*_script*.cpp.
Every table row cites its source line (`// engine :N`, `// <registrator script> :N`); a wrong citation is a
difference too.

Usage: python -I tools/check_spawn_classes.py [--game DIR] [--table FILE]
  no --game  the stock game as tools\\deploy.ps1 lays it out: Core (gamedata\\) over the engine layer
             (engine\\gamedata\\) over the stock unpacked Anomaly (../anomaly-ref/unpacked, the db archives);
  --game DIR a game folder (DIR\\gamedata over the stock unpacked Anomaly: an install, the GAMMA stand) or an
             unpacked folder (DIR\\scripts, DIR\\configs only).
Prints every difference and "N differences"; exit code 1 if there is any, 0 if none, 2 if a source is missing.
For information only (not a difference): the `class` values the game's configs use that the table does not allow.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "engine" / "src"
TABLE = ENGINE / "xrCoop" / "coop_spawn.h"
FACTORY = ENGINE / "xrServerEntities" / "object_factory_register.cpp"
CLSIDS = ENGINE / "xrServerEntities" / "clsid_game.h"
LUA_EXPORTS = ENGINE / "xrServerEntities"
STOCK = ROOT.parent / "anomaly-ref" / "unpacked"
DEPLOYED_LAYERS = [ROOT / "gamedata", ROOT / "engine" / "gamedata", STOCK]

# Preprocessor symbols of the game build (xrGame, single player): none of these is defined.
DEFINED = set()


class SourceMissing(Exception):
    pass


def read(path: Path) -> str:
    if not path.is_file():
        raise SourceMissing(str(path))
    return path.read_bytes().decode("latin-1")  # ids and names are ASCII; scripts and configs may be cp1251


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


class Game:
    """Where the game's scripts and configs are: the first layer that has a file wins."""

    def __init__(self, folder):
        if folder is None:
            self.name = "stock (Core over the engine layer over the unpacked Anomaly)"
            self.layers = DEPLOYED_LAYERS
        elif (folder / "gamedata").is_dir():
            self.name = str(folder)
            self.layers = [folder / "gamedata", STOCK]
        else:
            self.name = str(folder)
            self.layers = [folder]

    def find(self, sub: str, name: str):
        for layer in self.layers:
            path = layer / sub / name
            if path.is_file():
                return path
        return None

    def script(self, name: str) -> Path:
        path = self.find("scripts", name)
        if path is None:
            raise SourceMissing(f"scripts\\{name} in {', '.join(str(x) for x in self.layers)}")
        return path

    def config_files(self, pattern="*.ltx", recursive=True):
        """The .ltx files the game sees: a file of an upper layer hides the lower layer's file of the same path."""
        seen = {}
        for layer in reversed(self.layers):
            base = layer / "configs"
            if not base.is_dir():
                continue
            for path in (base.rglob(pattern) if recursive else base.glob(pattern)):
                seen[str(path.relative_to(base)).lower()] = path
        return [seen[k] for k in sorted(seen)]


def ltx_lines(text: str):
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].strip()
        if line:
            yield line


def class_registrators(game):
    """configs\\script.ltx [common] class_registrators after the DLTX mods of script.ltx, and the files read."""
    base = game.find("configs", "script.ltx")
    if base is None:
        raise SourceMissing("configs\\script.ltx")
    items, files, section = [], [base], None
    for line in ltx_lines(read(base)):
        if line.startswith("["):
            section = line[1:].split("]", 1)[0]
        elif section == "common" and re.match(r"class_registrators\s*=", line):
            items = [x.strip() for x in line.split("=", 1)[1].split(",") if x.strip()]
    # DLTX (xrCore/xr_ini.cpp): mod_script_*.ltx in the root's folder, minus those meant for another root script_*.ltx
    roots = [p.stem for p in game.config_files("script_*.ltx", recursive=False)]
    for mod in game.config_files("mod_script_*.ltx", recursive=False):
        if any(re.fullmatch(f"mod_{re.escape(r)}_.+\\.ltx", mod.name, re.I) for r in roots):
            continue
        files.append(mod)
        section = None
        for line in ltx_lines(read(mod)):
            if line.startswith(("[", "![", "@[")):
                section = line.lstrip("!@")[1:].split("]", 1)[0]
                continue
            m = re.match(r"([<>]?)class_registrators\s*=(.*)", line)
            if section != "common" or not m:
                continue
            values = [x.strip() for x in m.group(2).split(",") if x.strip()]
            if m.group(1) == ">":
                items += [v for v in values if v not in items]
            elif m.group(1) == "<":
                items = [v for v in items if v not in values]
            else:
                items = values
    return items, files


def cse_name(server_class: str):
    """CseClass enumerator of an engine server class, None if it is not an item class."""
    if server_class == "CSE_Temporary":
        return "Temporary"
    m = re.fullmatch(r"CSE_ALifeItem(\w*)", server_class)
    if not m:
        return None
    return m.group(1) or "Item"


def parse_clsids():
    ids = {}
    for m in re.finditer(r"#define\s+(CLSID_\w+)\s+MK_CLSID\(([^)]*)\)", read(CLSIDS)):
        chars = re.findall(r"'([^']*)'", m.group(2))
        ids[m.group(1)] = "".join(chars).rstrip(" ")
    return ids


def parse_engine(clsids):
    """clsid -> [(cse, "engine", line)] of the item classes the game registers; every id it registers; the line of
    the dedicated-server return."""
    items, registered = {}, {}
    active = [True]
    add = re.compile(r'^\s*ADD\(\s*([\w:]+)\s*,\s*(\w+)\s*,\s*(CLSID_\w+|TEXT2CLSID\("([^"]+)"\))\s*,\s*"[^"]*"\s*\)')
    add_mp = re.compile(r"^\s*ADD_MP\(\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*(CLSID_\w+)")
    pp = re.compile(r"^\s*#\s*(ifndef|ifdef|if|elif|else|endif)\b\s*(\w*)")
    dedicated_line = 0
    for n, raw in enumerate(read(FACTORY).splitlines(), 1):
        line = raw.split("//", 1)[0]
        d = pp.match(line)
        if d:
            kind, sym = d.group(1), d.group(2)
            if kind == "ifndef":
                active.append(active[-1] and sym not in DEFINED)
            elif kind == "ifdef":
                active.append(active[-1] and sym in DEFINED)
            elif kind == "if":
                active.append(active[-1])  # no #if expression guards a registration here
            elif kind in ("else", "elif"):
                parent = active[-2] if len(active) > 1 else True
                active[-1] = parent and not active[-1]
            elif kind == "endif" and len(active) > 1:
                active.pop()
            continue
        if not active[-1]:
            continue
        if "if (!g_dedicated_server)" in line:
            dedicated_line = n
            break
        mp = add_mp.match(line)
        if mp:
            registered.setdefault(clsids.get(mp.group(1), mp.group(1)), []).append(("engine", n))
            continue
        m = add.match(line)
        if not m:
            continue
        clsid = m.group(4) if m.group(4) else clsids.get(m.group(3))
        if clsid is None:
            raise SourceMissing(f"{m.group(3)} (object_factory_register.cpp:{n}) is not in clsid_game.h")
        clsid = clsid.rstrip(" ")
        registered.setdefault(clsid, []).append(("engine", n))
        cse = cse_name(m.group(2))
        if cse:
            items.setdefault(clsid, []).append((cse, "engine", n))
    if not dedicated_line:
        raise SourceMissing("`if (!g_dedicated_server)` in object_factory_register.cpp")
    return items, registered, dedicated_line


def parse_lua_exports():
    names = {}
    for path in sorted(LUA_EXPORTS.glob("xrServer_Objects*_script*.cpp")):
        for m in re.finditer(r'\(\s*(CSE_\w+)\s*,\s*"(cse_\w+)"', read(path)):
            names[m.group(2)] = m.group(1)
    if "cse_alife_item" not in names:
        raise SourceMissing("cse_alife_item in xrServer_Objects*_script*.cpp")
    return names


def lua_base(game, module_class, lua_names, cache, depth=0):
    """Engine server class behind a Lua server class "module.class" (None if it derives from no engine class)."""
    module, _, cls = module_class.partition(".")
    if module not in cache:
        classes = {}
        for m in re.finditer(r'^\s*class\s+"(\w+)"\s*\(\s*([\w.]+)\s*\)', read(game.script(module + ".script")), re.M):
            classes[m.group(1)] = m.group(2)
        cache[module] = classes
    seen = set()
    while cls and cls not in seen and depth < 16:
        seen.add(cls)
        base = cache[module].get(cls)
        if base is None:
            return None
        if base in lua_names:
            return lua_names[base]
        if "." in base:
            return lua_base(game, base, lua_names, cache, depth + 1)
        cls = base
    return None


def parse_registrators(game, registrators, lua_names):
    """clsid -> [(cse, script, line)] of the item classes the registrator scripts register; every id they register."""
    items, registered, used, problems = {}, {}, [], []
    cs = re.compile(r'^\s*cs_register\s*\(\s*\w+\s*,\s*"[^"]*"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    s = re.compile(r'^\s*s_register\s*\(\s*\w+\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    direct = re.compile(r':\s*register\s*\(\s*"[^"]*"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    cache = {}
    for entry in registrators:
        module = entry.split(".", 1)[0]
        try:
            path = game.script(module + ".script")
        except SourceMissing as e:
            problems.append(f"class registrator {entry}: {e}")
            continue
        used.append(path)
        for n, raw in enumerate(read(path).splitlines(), 1):
            line = raw.split("--", 1)[0]
            m = cs.match(line) or s.match(line) or direct.search(line)
            if not m:
                continue
            module_class, clsid = m.group(1), m.group(2)
            registered.setdefault(clsid, []).append((module, n))
            try:
                server = lua_base(game, module_class, lua_names, cache)
            except SourceMissing as e:
                problems.append(f"{module} :{n} {clsid}: Lua server class {module_class} not found ({e})")
                continue
            cse = cse_name(server) if server else None
            if cse:
                items.setdefault(clsid, []).append((cse, module, n))
    return items, registered, used, problems


def parse_table(path: Path):
    text = read(path)
    enum = re.search(r"enum class CseClass : uint8_t\s*\{(.*?)\};", text, re.S)
    if not enum:
        raise SourceMissing("enum class CseClass in coop_spawn.h")
    names = set(re.findall(r"^\s*(\w+)\s*,", re.sub(r"//[^\n]*", "", enum.group(1)), re.M))
    block = re.search(r"kClassRules\[\]\s*=\s*\{(.*?)\n\};", text, re.S)
    if not block:
        raise SourceMissing("kClassRules in coop_spawn.h")
    rows, bad = [], []
    for raw in block.group(1).splitlines():
        if not raw.strip() or raw.strip().startswith("//"):
            continue
        m = re.match(r'\s*\{"([^"]*)",\s*CseClass::(\w+)\},\s*//\s*(\w+)\s*:(\d+)\s*$', raw)
        if not m:
            bad.append(raw.strip())
            continue
        rows.append((m.group(1), m.group(2), m.group(3), int(m.group(4))))
    return names, rows, bad


def scan_configs(game):
    classes, files = Counter(), game.config_files()
    for path in files:
        for m in re.finditer(r"^[ \t]*class[ \t]*=[ \t]*([^;\s]+)", read(path), re.M):
            classes[m.group(1)] += 1
    return classes, len(files)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", type=Path, help="game folder or unpacked game (default: the deployed stock layers)")
    ap.add_argument("--table", type=Path, default=TABLE, help="the header with kClassRules (default: coop_spawn.h)")
    args = ap.parse_args()
    game = Game(args.game.resolve() if args.game else None)
    try:
        clsids = parse_clsids()
        engine_items, engine_registered, dedicated_line = parse_engine(clsids)
        lua_names = parse_lua_exports()
        registrators, registrator_files = class_registrators(game)
        script_items, script_registered, script_files, problems = parse_registrators(game, registrators, lua_names)
        enum_names, rows, bad_rows = parse_table(args.table)
        configs, config_count = scan_configs(game)
    except SourceMissing as e:
        print(f"source missing: {e}")
        return 2

    print(f"game:    {game.name}")
    print(f"table:   {rel(args.table.resolve())} ({len(rows)} rules)")
    print(f"engine:  {rel(FACTORY)} ({len(engine_items)} item classes in ADDs before line {dedicated_line})")
    print(f"scripts: class_registrators = {', '.join(registrators)}  (from {', '.join(map(str, registrator_files))})")
    for path in script_files:
        n = sum(1 for regs in script_items.values() for r in regs if r[1] == path.stem)
        print(f"         {path} ({n} item classes)")

    diffs = list(problems)
    diffs += [f"table row without a `// <source> :N` citation: {r}" for r in bad_rows]
    expected = {}
    for source in (engine_items, script_items):
        for clsid, regs in source.items():
            expected.setdefault(clsid, []).extend(regs)
    all_registered = {}
    for source in (engine_registered, script_registered):
        for clsid, regs in source.items():
            all_registered.setdefault(clsid, []).extend(regs)
    for clsid, regs in sorted(all_registered.items()):
        if len(regs) > 1:
            diffs.append(f"{clsid}: registered {len(regs)} times {regs} (the factory keeps one)")
    table = {}
    for clsid, cse, src, line in rows:
        if cse not in enum_names:
            diffs.append(f"{clsid}: CseClass::{cse} is not in the enum")
        if clsid in table:
            diffs.append(f"{clsid}: two rows in the table")
        table[clsid] = (cse, src, line)
    for clsid, regs in sorted(expected.items()):
        cse, src, line = regs[0]
        if cse not in enum_names:
            diffs.append(f"{clsid}: needs CseClass::{cse}, which the enum does not have ({src} :{line})")
        if clsid not in table:
            diffs.append(f"missing from the table: {{\"{clsid}\", CseClass::{cse}}}, // {src} :{line}")
            continue
        t_cse, t_src, t_line = table[clsid]
        if t_cse != cse:
            diffs.append(f"{clsid}: table says CseClass::{t_cse}, {src} :{line} builds CseClass::{cse}")
        if (t_src, t_line) != (src, line):
            diffs.append(f"{clsid}: table cites {t_src} :{t_line}, registered at {src} :{line}")
    for clsid in sorted(set(table) - set(expected)):
        t_cse, t_src, t_line = table[clsid]
        what = "registered, but not an item class" if clsid in all_registered else "not registered in the game"
        diffs.append(f"{clsid} (table: CseClass::{t_cse}, {t_src} :{t_line}): {what}")

    for d in diffs:
        print(f"  DIFF {d}")
    print(f"{len(diffs)} differences")

    # Information: what the game's sections use.
    allowed = {c: n for c, n in configs.items() if c in table}
    print(f"info: {sum(configs.values())} `class` lines in {config_count} config files; {len(allowed)} of the "
          f"table's {len(table)} classes are used ({sum(allowed.values())} lines)")
    other = sorted((-n, c) for c, n in configs.items() if c not in table)
    for label, known in (("registered classes that are not items", True),
                         ("classes the game does not register (no section of one can be created)", False)):
        listed = [f"{c} {-n}" for n, c in other if (c in all_registered) == known]
        if listed:
            print(f"info: {label} (`class =` lines): " + ", ".join(listed))
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
