#!/usr/bin/env bash
# Full engine build (DX11-AVX, x64) with the shared compile lock. Prints errors and the result.
#   tools/build.sh
set -u
MSBUILD="/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/engine/src"
mkdir -p "$ROOT/temp"
LOG="$ROOT/temp/build_$(date +%H%M%S).log"
LOCK="$ROOT/temp/compile.lock"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
	sleep 2
	waited=$((waited + 2))
	if [ $waited -ge 3600 ]; then echo "lock wait timeout ($LOCK)"; exit 3; fi
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
start=$(date +%s)
"$MSBUILD" "$(cygpath -w "$SRC/engine-vs2022.sln")" -p:Configuration=DX11-AVX -p:Platform=x64 -m -nologo -v:minimal \
	"-flp:logfile=$(cygpath -w "$LOG");verbosity=normal" > "$LOG.console" 2>&1
rc=$?
grep -E "error [A-Z]+[0-9]+" "$LOG.console" | sed -E 's/ \[[^]]*vcxproj\]$//' | sort -u | head -80
echo "build exit=$rc in $(( $(date +%s) - start ))s (log $LOG)"
exit $rc
