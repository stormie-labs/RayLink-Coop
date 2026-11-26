"""Layered game inputs for the trader catalogue."""
import fnmatch
import re
from pathlib import Path

STOCK = Path(__file__).resolve().parents[4] / "anomaly-ref" / "unpacked"


class SourceMissing(Exception):
    pass


def read(path: Path) -> str:
    if not path.is_file():
        raise SourceMissing(str(path))
    return path.read_bytes().decode("latin-1")  # ids and names are ASCII; scripts and configs may be cp1251


class Game:
    """Where the game's scripts and configs are: the first layer that has a file wins."""

    def __init__(self, folder):
        self._configs = None
        self.layers = [folder / "gamedata", STOCK] if (folder / "gamedata").is_dir() else [folder]

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


class Ltx:
    """Read layered LTX configs with include and DLTX section handling."""

    def __init__(self, game):
        self.game = game
        self.sections = {}
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
