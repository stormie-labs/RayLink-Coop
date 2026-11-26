"""The trader catalogue of the Lua trader tests: every trader profile's buy_supplies selector and the scripts that inject
or select supplies, for stock Anomaly (../anomaly-ref/unpacked) and for the G.A.M.M.A. tree.

  python -B tests/lua/support/trader_catalog.py <catalog.lua>     (test_trader_rep_modes.lua, test_trader_supplies.lua)

The G.A.M.M.A. tree is the one tools/check_gates.py gamma_scripts names (GAMMA_SCRIPTS, else the stand's), two levels up
from its gamedata/scripts. Scanning both config trees takes about a minute, so the catalogue is built once per state of
its inputs. The cache key covers the bytes of this script and trader_inputs.py, plus the path, size and time of
every config and script file the scan reads. A changed file gives a new stamp and a
new scan; the catalogue is copied to the path the test names, so parallel runs never read a half-written file."""
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
import check_gates  # noqa: E402
from trader_inputs import Game, Ltx, read  # noqa: E402

CACHE = ROOT / "temp" / "trader_catalog"


def games():
    scripts = check_gates.gamma_scripts()
    if scripts is None:
        sys.exit("trader_catalog: the G.A.M.M.A. scripts are required (GAMMA_SCRIPTS, or the stand's gamedata/scripts)")
    return (("stock", Game(ROOT.parent / "anomaly-ref/unpacked")), ("gamma", Game(scripts.parents[1])))


def stamp(all_games) -> str:
    digest = hashlib.sha1()
    for path in (Path(__file__), Path(__file__).with_name("trader_inputs.py")):
        digest.update(path.read_bytes())
    for label, game in all_games:
        digest.update(label.encode())
        for layer in game.layers:
            for folder, pattern in ((layer / "configs", "**/*.ltx"), (layer / "scripts", "*.script")):
                for path in sorted(folder.glob(pattern)) if folder.is_dir() else ():
                    info = path.stat()
                    digest.update(f"{path}|{info.st_size}|{info.st_mtime_ns}\n".encode("utf-8", "replace"))
    return digest.hexdigest()[:16]


def scan(game):
    configs = game.configs()
    candidates = set()
    for key, path in configs.items():
        text = read(path)
        if re.search(r"^\s*\[trader\]", text, re.M):
            candidates.add(key)
        for reference in re.findall(r"\btrade\s*=\s*([\w\\/.-]+\.ltx)", text):
            candidates.add(reference.replace("\\", "/").lower())
    profiles = []
    for key in sorted(candidates):
        path = game.config(key)
        if path is None:
            continue
        ltx = Ltx(game)
        parent = key.rpartition("/")[0]
        prefix = parent + "/" if parent else ""
        ltx.load(path, prefix)
        for mod in game.config_glob(prefix + "mod_" + path.stem + "_*.ltx"):
            ltx.load(mod, prefix)
        trader = ltx.resolved("trader") or {}
        source = trader.get("buy_supplies")
        if source:
            profiles.append({"path": key, "source": source,
                             "functions": sorted(set(re.findall(r"[=!]([\w]+)\(", source)))})
    scripts = {}
    for layer in reversed(game.layers):
        for path in (layer / "scripts").glob("*.script"):
            scripts[path.name] = path
    injectors, non_tier_injectors, selectors = [], [], []
    for name, path in sorted(scripts.items()):
        source = re.sub(r"--\[\[.*?\]\]", "", read(path), flags=re.S)
        source = re.sub(r"--[^\n]*", "", source)
        if re.search(r"trader_autoinject\.supply_level\s*\(", source):
            injectors.append(name)
        elif name != "trader_autoinject.script" and re.search(r"trader_autoinject\.", source):
            non_tier_injectors.append(name)
        if re.search(r'''xr_logic\.parse_condlist\([^\n]*["']buy_supplies["']''', source):
            selectors.append(name)
    return {"profiles": profiles, "injectors": injectors, "non_tier_injectors": non_tier_injectors,
            "selectors": selectors}


def catalog_lua(report) -> str:
    rows = ["return {"]
    for label, entry in report.items():
        rows.append(label + " = {")
        for profile in entry["profiles"]:
            rows.append("{path=" + json.dumps(profile["path"]) + ",source=" + json.dumps(profile["source"]) + "},")
        rows.append("},")
    rows.append("}")
    return "\n".join(rows)


def main() -> int:
    target = Path(sys.argv[1])
    all_games = games()
    cached = CACHE / f"{stamp(all_games)}.lua"
    if not cached.is_file():
        report = {}
        for label, game in all_games:
            report[label] = entry = scan(game)
            print(label, len(entry["profiles"]), "profiles",
                  sum("actor_goodwill_ge" in p["functions"] for p in entry["profiles"]), "rep-gated",
                  len(entry["injectors"]), "supply_level callers")
        CACHE.mkdir(parents=True, exist_ok=True)
        part = cached.with_name(f"{cached.stem}.{os.getpid()}.part")
        part.write_text(catalog_lua(report), encoding="utf8")
        try:
            os.replace(part, cached)  # whole or not there: a parallel run reads no half-written catalogue
            (CACHE / f"{cached.stem}.coverage.json").write_text(json.dumps(report, indent=2), encoding="utf8")
        except PermissionError:  # a parallel run of the same stamp put the same catalogue there and is reading it
            part.unlink(missing_ok=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(cached, target)
    return 0


if __name__ == "__main__":
    sys.exit(main())
