"""Check the ReqSpawn rules (engine/src/xrCoop/coop_spawn.h, F2 T2) against the engine and the game's scripts.

A client may ask the host only for items of the game's item classes, and only for a section with every line the
item's server entity and game object read without line_exist (a missing one is FATAL on the host). Checked:
  1. the class table (kClassRules) holds exactly the item classes the game registers, each with the server entity
     class and the game object group the factory builds for it:
       engine   engine/src/xrServerEntities/object_factory_register.cpp: ADD(client, server, id, name) whose server
                class is CSE_ALifeItem* or CSE_Temporary (a launcher's rocket), before `if (!g_dedicated_server)
                return;` (the ADDs after it exist only on a dedicated server: in the game such an id names no class).
                Ids come from clsid_game.h (MK_CLSID) or TEXT2CLSID("...").
       scripts  the class registrators of the game: configs\\script.ltx [common] class_registrators with its DLTX
                mods (mod_script_*.ltx: `>class_registrators = ...` adds, `<` removes). Each cs_register(factory,
                "client", "module.class", "ID", name) whose Lua server class derives from a cse_alife_item* class
                (module.script); the engine classes behind the Lua names: xrServerEntities/xrServer_Objects*_script*.cpp.
     Every row cites its registration (`// engine :N`, `// <registrator script> :N`); a wrong citation is a difference.
  2. the game object lines (GameLine tables, Ruling F2-17): every cited read (file:line in engine/src/xrGame) reads that
     line (the literal, or its tail after a strconcat prefix) and is not a READ_IF_EXISTS;
  3. every class with its own Load(LPCSTR) above a row's client class (its bases in xrGame, up to the engine) is listed
     in the `loads` of the row's group (kGameGroups): the group's lines cover all of them.
For information only (not a difference): the `class` values the game's configs use that the table does not allow, and
the item sections of the game's configs (system.ltx with its includes and DLTX mods, inheritance resolved) that the
host would refuse for a missing line, by class and line.

Usage: python -I tools/check_spawn_classes.py [--game DIR] [--table FILE]
  no --game  the stock game as tools\\deploy.ps1 lays it out: Core (gamedata\\) over the engine layer
             (engine\\gamedata\\) over the stock unpacked Anomaly (../anomaly-ref/unpacked, the db archives);
  --game DIR a game folder (DIR\\gamedata over the stock unpacked Anomaly: an install, the GAMMA stand) or an
             unpacked folder (DIR\\scripts, DIR\\configs only).
Prints every difference and "N differences"; exit code 1 if there is any, 0 if none, 2 if a source is missing.
"""
import argparse
import fnmatch
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGINE = ROOT / "engine" / "src"
XRGAME = ENGINE / "xrGame"
TABLE = ENGINE / "xrCoop" / "coop_spawn.h"
FACTORY = ENGINE / "xrServerEntities" / "object_factory_register.cpp"
CLSIDS = ENGINE / "xrServerEntities" / "clsid_game.h"
LUA_EXPORTS = ENGINE / "xrServerEntities"
STOCK = ROOT.parent / "anomaly-ref" / "unpacked"
DEPLOYED_LAYERS = [ROOT / "gamedata", ROOT / "engine" / "gamedata", STOCK]

# Preprocessor symbols of the game build (xrGame, single player): none of these is defined.
DEFINED = set()

# The server entity's own lines (mirror of coop_spawn.h required_lines; its unit tests pin them).
CSE_LINES = {
    "": ["inv_weight", "cost"],
    "Weapon": ["hit_power", "hit_type", "ammo_class", "scope_status", "silencer_status", "grenade_launcher_status"],
    "Ammo": ["box_size"],
    "Detector": ["ef_detector_type"],
    "CustomOutfit": ["ef_equipment_type"],
}
WEAPON_CSE = {"Weapon", "WeaponMagazined", "WeaponMagazinedWGL", "WeaponShotGun", "WeaponAutoShotGun"}


class SourceMissing(Exception):
    pass


def read(path: Path) -> str:
    if not path.is_file():
        raise SourceMissing(str(path))
    return path.read_bytes().decode("latin-1")  # ids and names are ASCII; scripts and configs may be cp1251


def lines_of(path: Path):
    """The file's lines as an editor numbers them (only \\n ends a line: latin-1 text may hold \\x85)."""
    return [line.rstrip("\r") for line in read(path).split("\n")]


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
        self._configs = None

    def script(self, name: str) -> Path:
        for layer in self.layers:
            path = layer / "scripts" / name
            if path.is_file():
                return path
        raise SourceMissing(f"scripts\\{name} in {', '.join(str(x) for x in self.layers)}")

    def configs(self):
        """Every .ltx the game sees, by its lowercase path under configs\\ (an upper layer hides a lower one)."""
        if self._configs is None:
            seen = {}
            for layer in reversed(self.layers):
                base = layer / "configs"
                if base.is_dir():
                    for path in base.rglob("*.ltx"):
                        seen[str(path.relative_to(base)).replace("\\", "/").lower()] = path
            self._configs = seen
        return self._configs

    def config(self, rel_path: str):
        return self.configs().get(rel_path.replace("\\", "/").lower())

    def config_glob(self, pattern: str):
        pattern = pattern.replace("\\", "/").lower()
        return [self.configs()[k] for k in sorted(self.configs()) if fnmatch.fnmatchcase(k, pattern)]


def ltx_lines(text: str):
    for raw in text.split("\n"):
        line = raw.split(";", 1)[0].strip()
        if line:
            yield line


def class_registrators(game):
    """configs\\script.ltx [common] class_registrators after the DLTX mods of script.ltx, and the files read."""
    base = game.config("script.ltx")
    if base is None:
        raise SourceMissing("configs\\script.ltx")
    items, files, section = [], [base], None
    for line in ltx_lines(read(base)):
        if line.startswith("["):
            section = line[1:].split("]", 1)[0]
        elif section == "common" and re.match(r"class_registrators\s*=", line):
            items = [x.strip() for x in line.split("=", 1)[1].split(",") if x.strip()]
    # DLTX (xrCore/xr_ini.cpp): mod_script_*.ltx in the root's folder, minus those meant for another root script_*.ltx
    roots = [p.stem for p in game.config_glob("script_*.ltx")]
    for mod in game.config_glob("mod_script_*.ltx"):
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
    """clsid -> [(cse, "engine", line, client class)] of the item classes the game registers; every id it registers;
    the line of the dedicated-server return."""
    items, registered = {}, {}
    active = [True]
    add = re.compile(r'^\s*ADD\(\s*([\w:]+)\s*,\s*(\w+)\s*,\s*(CLSID_\w+|TEXT2CLSID\("([^"]+)"\))\s*,\s*"[^"]*"\s*\)')
    add_mp = re.compile(r"^\s*ADD_MP\(\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*\w+\s*,\s*(CLSID_\w+)")
    pp = re.compile(r"^\s*#\s*(ifndef|ifdef|if|elif|else|endif)\b\s*(\w*)")
    dedicated_line = 0
    for n, raw in enumerate(lines_of(FACTORY), 1):
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
            items.setdefault(clsid, []).append((cse, "engine", n, m.group(1)))
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
    """clsid -> [(cse, script, line, client class)] of the item classes the registrator scripts register; every id
    they register."""
    items, registered, used, problems = {}, {}, [], []
    cs = re.compile(r'^\s*cs_register\s*\(\s*\w+\s*,\s*"([^"]*)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    s = re.compile(r'^\s*s_register\s*\(\s*\w+\s*,\s*()"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    direct = re.compile(r':\s*register\s*\(\s*"([^"]*)"\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"[^"]*"\s*\)')
    cache = {}
    for entry in registrators:
        module = entry.split(".", 1)[0]
        try:
            path = game.script(module + ".script")
        except SourceMissing as e:
            problems.append(f"class registrator {entry}: {e}")
            continue
        used.append(path)
        for n, raw in enumerate(lines_of(path), 1):
            line = raw.split("--", 1)[0]
            m = cs.match(line) or s.match(line) or direct.search(line)
            if not m:
                continue
            client, module_class, clsid = m.group(1), m.group(2), m.group(3)
            registered.setdefault(clsid, []).append((module, n))
            try:
                server = lua_base(game, module_class, lua_names, cache)
            except SourceMissing as e:
                problems.append(f"{module} :{n} {clsid}: Lua server class {module_class} not found ({e})")
                continue
            cse = cse_name(server) if server else None
            if cse:
                items.setdefault(clsid, []).append((cse, module, n, client))
    return items, registered, used, problems


def parse_table(path: Path):
    """CseClass and GameClass names, the rows, rows without a citation, the GameLine tables and the groups."""
    text = read(path)
    enums = {}
    for name in ("CseClass", "GameClass", "When"):
        m = re.search(rf"enum class {name} : uint8_t\s*\{{(.*?)\}};", text, re.S)
        if not m:
            raise SourceMissing(f"enum class {name} in coop_spawn.h")
        enums[name] = set(re.findall(r"^\s*(\w+)\s*,", re.sub(r"//[^\n]*", "", m.group(1)), re.M))
    block = re.search(r"kClassRules\[\]\s*=\s*\{(.*?)\n\};", text, re.S)
    if not block:
        raise SourceMissing("kClassRules in coop_spawn.h")
    rows, bad = [], []
    for raw in block.group(1).split("\n"):
        if not raw.strip() or raw.strip().startswith("//"):
            continue
        m = re.match(r'\s*\{"([^"]*)",\s*CseClass::(\w+),\s*GameClass::(\w+)\},\s*//\s*(\w+)\s*:(\d+)\s*$', raw)
        if not m:
            bad.append(raw.strip())
            continue
        rows.append((m.group(1), m.group(2), m.group(3), m.group(4), int(m.group(5))))
    tables = {}
    for m in re.finditer(r"inline constexpr GameLine (\w+)\[\]\s*=\s*\{(.*?)\n\};", text, re.S):
        tables[m.group(1)] = [(a, b, c) for a, b, c in
                              re.findall(r'\{"([^"]+)",\s*When::(\w+),\s*"([^"]+)"\}', m.group(2))]
    groups = {}
    g = re.search(r"kGameGroups\[\]\s*=\s*\{(.*?)\n\};", text, re.S)
    if not g:
        raise SourceMissing("kGameGroups in coop_spawn.h")
    for m in re.finditer(r"\{GameClass::(\w+),\s*((?:\"[^\"]*\"\s*)+),\s*\{([^}]*)\}\}", g.group(1)):
        loads = "".join(re.findall(r'"([^"]*)"', m.group(2))).split()
        blocks = re.findall(r"block\((\w+)\)", m.group(3))
        groups[m.group(1)] = (loads, blocks)
    return enums, rows, bad, tables, groups


# ---------------------------------------------------------------- the game object's lines


def check_citations(tables):
    """Each cited read reads the line (literal, or its tail after a strconcat prefix) and is not READ_IF_EXISTS."""
    diffs, cache = [], {}
    for table, entries in sorted(tables.items()):
        for line, _when, src in entries:
            m = re.fullmatch(r"([\w.]+):(\d+)", src)
            if not m:
                diffs.append(f"{table} `{line}`: citation {src} is not file:line")
                continue
            path = XRGAME / m.group(1)
            if path not in cache:
                cache[path] = lines_of(path) if path.is_file() else None
            text = cache[path]
            n = int(m.group(2))
            if text is None or n < 1 or n > len(text):
                diffs.append(f"{table} `{line}`: {src} does not exist")
                continue
            here, before = text[n - 1], text[n - 2] if n > 1 else ""
            tails = [line] + [line[i + 1:] for i, c in enumerate(line) if c == "_"]
            literal = any(f'"{t}"' in here and (t == line or "strconcat" in here) for t in tails)
            reads = re.search(r"\br_\w+\s*\(", here) or re.search(r"\br_\w+\s*\(\s*$", before)
            if not literal or not reads or "READ_IF_EXISTS" in here:
                diffs.append(f"{table} `{line}`: {src} is not an unchecked read of it: {here.strip()[:100]}")
    return diffs


def parse_hierarchy():
    """Bases of every class declared in xrGame headers, and the classes with their own Load(LPCSTR) (file:line)."""
    bases = defaultdict(set)
    decl = re.compile(r"\b(?:class|struct)\s+(?:\w+\s+)?(\w+)\s*(?:final\s*)?:\s*([^{;()]*?)\{", re.S)
    for path in XRGAME.rglob("*.h"):
        text = re.sub(r"//[^\n]*", "", read(path))
        for m in decl.finditer(text):
            for base in m.group(2).split(","):
                words = re.sub(r"<.*", "", base).replace("public", " ").replace("protected", " ")
                words = words.replace("private", " ").replace("virtual", " ").split()
                if words:
                    bases[m.group(1)].add(words[-1].split("::")[-1])
    loads = {}
    load = re.compile(r"^[ 	]*void\s+(\w+)::Load\s*\(\s*(?:LPCSTR|const\s+char\s*\*)\s*\w*\s*\)", re.M)
    for path in XRGAME.rglob("*.cpp"):
        text = read(path)
        for m in load.finditer(text):
            loads.setdefault(m.group(1), f"{path.name}:{text.count(chr(10), 0, m.start()) + 1}")
    return bases, loads


def check_loads(rows, sources, groups, bases, loads):
    """Every Load above a row's client class is in the `loads` of the row's group."""
    diffs = []
    for name, (listed, _blocks) in sorted(groups.items()):
        for cls in listed:
            if cls not in loads:
                diffs.append(f"group {name}: {cls} is listed but has no Load(LPCSTR) in xrGame")
    for clsid, _cse, game_class, _src, _line in rows:
        client = sources.get(clsid)
        if not client or game_class not in groups:
            continue
        listed = set(groups[game_class][0])
        seen, todo = set(), [client]
        while todo:
            cls = todo.pop()
            if cls in seen:
                continue
            seen.add(cls)
            if cls in loads and cls not in listed:
                diffs.append(f"{clsid} ({client}, GameClass::{game_class}): {cls}::Load ({loads[cls]}) is not in the "
                             f"group's loads")
            todo.extend(bases.get(cls, ()))
        if client not in bases and client not in loads:
            diffs.append(f"{clsid}: client class {client} is not declared in xrGame")
    return diffs


# ---------------------------------------------------------------- the game's configs (information)


class Ltx:
    """system.ltx as CInifile loads it: #include (with *.ltx), DLTX mods of the root (mod_system_*.ltx), override
    sections ![x] / @[x], deleted sections !![x], deleted lines !key, list edits >key / <key; inheritance resolved at
    the end (DLTX defers it too)."""

    def __init__(self, game):
        self.game = game
        self.sections = {}  # lowercase name -> {"parents": [...], "items": {key: value}}
        self.deleted = set()
        root = game.config("system.ltx")
        if root is None:
            raise SourceMissing("configs\\system.ltx")
        self.load(root, "")
        roots = [p.stem for p in game.config_glob("system_*.ltx")]
        for mod in game.config_glob("mod_system_*.ltx"):
            if not any(re.fullmatch(f"mod_{re.escape(r)}_.+\\.ltx", mod.name, re.I) for r in roots):
                self.load(mod, "")
        self._resolved = {}

    def load(self, path, folder, depth=0):
        if depth > 32:
            return
        current = None
        for raw in read(path).split("\n"):
            line = raw.strip()
            if line.startswith("#include"):
                m = re.search(r'"([^"]+)"', line)
                if m:
                    inc = (folder + m.group(1)).replace("\\", "/")
                    inc_folder = inc.rsplit("/", 1)[0] + "/" if "/" in inc else ""
                    for f in (self.game.config_glob(inc) if "*" in inc else [self.game.config(inc)]):
                        if f is not None:
                            self.load(f, inc_folder, depth + 1)
                continue
            line = line.split(";", 1)[0].strip()
            if not line:
                continue
            if line.startswith("!!["):
                name = line[3:].split("]", 1)[0].strip().lower()
                self.sections.pop(name, None)
                self.deleted.add(name)
                current = None
                continue
            if line.startswith(("[", "![", "@[")):
                override = line[0] in "!@"
                body = line[1:] if override else line
                name, _, rest = body[1:].partition("]")
                name = name.strip().lower()
                parents = [p.strip().lower() for p in rest.split(":", 1)[1].split(",") if p.strip()] \
                    if rest.strip().startswith(":") else None
                sec = self.sections.get(name)
                if sec is None:
                    sec = {"parents": [], "items": {}}
                    self.sections[name] = sec
                # DLTX MergeParentSet (xrCore/xr_ini.cpp:302): parents are added, `!parent` takes one away.
                for parent in parents or []:
                    plain = parent.lstrip("!")
                    sec["parents"] = [p for p in sec["parents"] if p != plain]
                    if not parent.startswith("!"):
                        sec["parents"].append(plain)
                current = sec
                continue
            if current is None:
                continue
            if line.startswith("!"):
                current["items"].pop(line[1:].split("=", 1)[0].strip(), None)
                continue
            key, eq, value = line.partition("=")
            key = key.strip().lstrip("<>")
            if key:
                current["items"][key] = value.strip().strip('"') if eq else ""

    def resolved(self, name, depth=0):
        name = name.lower()
        if name in self._resolved:
            return self._resolved[name]
        sec = self.sections.get(name)
        if sec is None or depth > 32:
            return None
        items = {}
        for parent in sec["parents"]:
            p = self.resolved(parent, depth + 1)
            if p:
                items.update(p)
        items.update(sec["items"])
        self._resolved[name] = items
        return items


class SectionIni:
    """A resolved section as coop_spawn.h missing_line asks about it."""

    def __init__(self, ltx, items):
        self.ltx, self.items = ltx, items

    def has(self, line):
        return line in self.items

    def number(self, line):
        m = re.match(r"\s*([+-]?\d+)", self.items.get(line, "") or "")
        return int(m.group(1)) if m else 0

    def flag(self, line):
        return (self.items.get(line, "") or "")[:7].lower() in ("on", "yes", "true", "1")

    def ref(self, line):
        value = self.items.get(line, "")
        return self.ltx.resolved(value) if value else None

    def ref_exists(self, line):
        return self.ref(line) is not None

    def ref_has(self, line, other):
        r = self.ref(line)
        return r is not None and other in r


def holds(when, ini):
    """Mirror of coop_spawn.h holds()."""
    shot_light = not ini.flag("light_disabled")
    silencer = ini.number("silencer_status")
    scope = ini.number("scope_status")
    launcher = ini.number("grenade_launcher_status")
    return {
        "Always": True,
        "InSlotOrBelt": ini.number("slot") != -1 or ini.flag("belt"),
        "ShotLight": shot_light,
        "SilencerShotLight": shot_light and silencer in (1, 2),
        "ShellParticles": ini.has("shell_particles"),
        "FirstBullet": ini.flag("use_first_bullet"),
        "ScopeModular": scope == 2 and ini.flag("modular_attachments"),
        "ScopeOwnName": scope == 2 and not ini.flag("modular_attachments") and not ini.has("scopes_sect"),
        "SilencerAttachable": silencer == 2,
        "LauncherAttachable": launcher == 2,
        "LauncherPermanent": launcher == 1,
        "ArtefactLights": ini.flag("lights_enabled"),
    }[when]


def missing_line(cse, game_class, ini, tables, groups):
    """Mirror of coop_spawn.h missing_line: the first missing line, as text."""
    cse_lines = CSE_LINES[""] + (CSE_LINES["Weapon"] if cse in WEAPON_CSE else CSE_LINES.get(cse, []))
    for line in cse_lines:
        if not ini.has(line):
            return line
    lines = [entry for b in groups[game_class][1] for entry in tables[b]]
    for always in (True, False):
        for line, when, _src in lines:
            if (when == "Always") == always and not ini.has(line) and holds(when, ini):
                return line
    if not ini.ref_exists("immunities_sect"):
        return "immunities_sect (no such section)"
    for line, _when, _src in tables["kImmunityLines"]:
        if not ini.ref_has("immunities_sect", line):
            return f"{line} (in its immunities_sect)"
    return None


def scan_sections(game, table, tables, groups):
    """The item sections of the game's configs and the ones the host would refuse for a missing line."""
    ltx = Ltx(game)
    items, refused = 0, defaultdict(list)
    for name in sorted(ltx.sections):
        sec = ltx.resolved(name)
        clsid = (sec or {}).get("class")
        if not clsid or clsid not in table:
            continue
        items += 1
        cse, game_class = table[clsid][0], table[clsid][1]
        if game_class not in groups:
            continue
        missing = missing_line(cse, game_class, SectionIni(ltx, sec), tables, groups)
        if missing:
            refused[(clsid, missing)].append(name)
    return len(ltx.sections), items, refused


def scan_classes(game):
    classes, files = Counter(), list(game.configs().values())
    for path in files:
        for m in re.finditer(r"^[ \t]*class[ \t]*=[ \t]*([^;\s]+)", read(path), re.M):
            classes[m.group(1)] += 1
    return classes, len(files)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--game", type=Path, help="game folder or unpacked game (default: the deployed stock layers)")
    ap.add_argument("--table", type=Path, default=TABLE, help="the header with kClassRules (default: coop_spawn.h)")
    args = ap.parse_args()
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    game = Game(args.game.resolve() if args.game else None)
    try:
        clsids = parse_clsids()
        engine_items, engine_registered, dedicated_line = parse_engine(clsids)
        lua_names = parse_lua_exports()
        registrators, registrator_files = class_registrators(game)
        script_items, script_registered, script_files, problems = parse_registrators(game, registrators, lua_names)
        enums, rows, bad_rows, tables, groups = parse_table(args.table)
        bases, loads = parse_hierarchy()
        configs, config_count = scan_classes(game)
        table_by_id = {clsid: (cse, g) for clsid, cse, g, _s, _n in rows}
        section_count, item_sections, refused = scan_sections(game, table_by_id, tables, groups)
    except SourceMissing as e:
        print(f"source missing: {e}")
        return 2

    print(f"game:    {game.name}")
    print(f"table:   {rel(args.table.resolve())} ({len(rows)} rules, {len(groups)} game object groups, "
          f"{sum(len(t) for t in tables.values())} cited lines)")
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
    for clsid, cse, game_class, src, line in rows:
        if cse not in enums["CseClass"]:
            diffs.append(f"{clsid}: CseClass::{cse} is not in the enum")
        if game_class not in enums["GameClass"]:
            diffs.append(f"{clsid}: GameClass::{game_class} is not in the enum")
        if clsid in table:
            diffs.append(f"{clsid}: two rows in the table")
        table[clsid] = (cse, src, line)
    clients = {}
    for clsid, regs in sorted(expected.items()):
        cse, src, line, client = regs[0]
        clients[clsid] = client
        if cse not in enums["CseClass"]:
            diffs.append(f"{clsid}: needs CseClass::{cse}, which the enum does not have ({src} :{line})")
        if clsid not in table:
            diffs.append(f"missing from the table: {{\"{clsid}\", CseClass::{cse}, GameClass::?}}, // {src} :{line}"
                         f" (client {client})")
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
    # The game object lines (Ruling F2-17).
    for name in sorted(enums["GameClass"] - set(groups)):
        diffs.append(f"GameClass::{name} has no group in kGameGroups")
    for name, (_loads, blocks) in sorted(groups.items()):
        for b in blocks:
            if b not in tables:
                diffs.append(f"group {name}: block {b} is not a GameLine table")
    for table_name, entries in tables.items():
        for line, when, _src in entries:
            if when not in enums["When"]:
                diffs.append(f"{table_name} `{line}`: When::{when} is not in the enum")
    diffs += check_citations(tables)
    diffs += check_loads(rows, clients, groups, bases, loads)

    for d in diffs:
        print(f"  DIFF {d}")
    print(f"{len(diffs)} differences")

    # Information: what the game's sections use, and what the host would refuse.
    allowed = {c: n for c, n in configs.items() if c in table}
    print(f"info: {sum(configs.values())} `class` lines in {config_count} config files; {len(allowed)} of the "
          f"table's {len(table)} classes are used ({sum(allowed.values())} lines)")
    other = sorted((-n, c) for c, n in configs.items() if c not in table)
    for label, known in (("registered classes that are not items", True),
                         ("classes the game does not register (no section of one can be created)", False)):
        listed = [f"{c} {-n}" for n, c in other if (c in all_registered) == known]
        if listed:
            print(f"info: {label} (`class =` lines): " + ", ".join(listed))
    total = sum(len(v) for v in refused.values())
    print(f"info: system.ltx resolves {section_count} sections, {item_sections} of an item class; {total} of them "
          f"would be refused for a missing line:")
    for (clsid, missing), names in sorted(refused.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        shown = ", ".join(names[:8]) + (f", ... ({len(names)})" if len(names) > 8 else "")
        print(f"        {clsid:<9} no {missing}: {shown}")
    return 1 if diffs else 0


if __name__ == "__main__":
    sys.exit(main())
