"""Current VFS trader selectors and injector callers for the Lua integration test."""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools"))
from check_spawn_classes import Game, Ltx, read

report = {}
for label, folder in (("stock", ROOT.parent / "anomaly-ref/unpacked"), ("gamma", Path("E:/RayLink2/gamma"))):
    game = Game(folder)
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
        ltx = object.__new__(Ltx)
        ltx.game, ltx.sections, ltx.deleted, ltx._resolved = game, {}, set(), {}
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
    report[label] = {"profiles": profiles, "injectors": injectors,
                     "non_tier_injectors": non_tier_injectors, "selectors": selectors}
    print(label, len(profiles), "profiles", sum("actor_goodwill_ge" in p["functions"] for p in profiles),
          "rep-gated", len(injectors), "supply_level callers")
out = ROOT / "temp/trader_reputation"
out.mkdir(parents=True, exist_ok=True)
(out / "coverage.json").write_text(json.dumps(report, indent=2), encoding="utf8")
rows = ["return {"]
for label, entry in report.items():
    rows.append(label + " = {")
    for profile in entry["profiles"]:
        rows.append("{path=" + json.dumps(profile["path"]) + ",source=" + json.dumps(profile["source"]) + "},")
    rows.append("},")
rows.append("}")
(out / "catalog.lua").write_text("\n".join(rows), encoding="utf8")
