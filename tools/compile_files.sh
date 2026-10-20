#!/usr/bin/env bash
# Compile selected xrGame sources only (no link), against the existing Release-AVX intermediates.
# Fast check for compile errors while other parts of the tree are being edited.
#   tools/compile_files.sh coop/coop_join.cpp alife_dynamic_object.cpp
# Paths are relative to engine/src/xrGame. Prints error lines and the result.
set -u
MSBUILD="/c/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/engine/src"
files=""
for f in "$@"; do
	f="$(printf '%s' "$f" | tr '/' '\134')"
	files="${files:+$files;}$f"
done
mkdir -p "$ROOT/temp"
LOG="$ROOT/temp/compile_$$.log"
RSP="$ROOT/temp/compile_$$.rsp"
PROJ_W=$(cygpath -w "$SRC/xrGame/xrGame.vcxproj")
SOL_M=$(cygpath -m "$SRC")
{
	printf '"%s"\n' "$PROJ_W"
	printf '%s\n' "-t:ClCompile"
	printf -- '-p:SelectedFiles="%s"\n' "$files"
	printf '%s\n' "-p:Configuration=Release-AVX" "-p:Platform=x64"
	printf -- '-p:SolutionDir="%s/"\n' "$SOL_M"
	printf '%s\n' "-nologo" "-v:minimal" "-m"
} > "$RSP"
# One compile at a time: parallel agents share the same intermediate dir (pch, tlogs, pdb).
LOCK="$ROOT/temp/compile.lock"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
	sleep 2
	waited=$((waited + 2))
	if [ $waited -ge 1800 ]; then echo "lock wait timeout ($LOCK), remove it if stale"; exit 3; fi
done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
"$MSBUILD" "@$(cygpath -w "$RSP")" > "$LOG" 2>&1
rc=$?
rmdir "$LOCK" 2>/dev/null
grep -E "error [A-Z]+[0-9]+" "$LOG" | sed -E 's/ \[[^]]*vcxproj\]$//' | sort -u | head -80
echo "compile exit=$rc (log $LOG)"
rm -f "$RSP"
exit $rc
