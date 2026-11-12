"""Lists tracked engine sources (HEAD) outside ci_sync's SOURCE_DIRS whose text differs from the engine-ci copy."""
import subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
MAIN, CI = ROOT / "engine", ROOT / "engine-ci"
DIRS = ("src/xrGame", "src/xrCoop", "src/xrEngine", "src/xrServerEntities", "src/xrCore", "src/Layers", "src/xrSound")
EXT = (".cpp", ".h", ".hpp", ".inl", ".c", ".rc", ".vcxproj", ".props", ".sln", ".filters")
files = subprocess.run(["git", "-C", str(MAIN), "ls-files", "src"], capture_output=True, text=True, check=True).stdout.splitlines()
n = 0
for rel in files:
    rel = rel.strip('"')
    if rel.startswith(DIRS) or not rel.lower().endswith(EXT):
        continue
    r = subprocess.run(["git", "-C", str(MAIN), "show", f"HEAD:{rel}"], capture_output=True)
    if r.returncode != 0:
        continue
    dst = CI / rel
    if not dst.is_file():
        print("MISSING in ci:", rel); n += 1; continue
    if dst.read_bytes().replace(b"\r\n", b"\n") != r.stdout.replace(b"\r\n", b"\n"):
        print("DIFFERS:", rel); n += 1
print("total", n)
