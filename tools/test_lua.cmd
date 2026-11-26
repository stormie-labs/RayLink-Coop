@echo off
rem Anomaly Coop: runs the Lua stub-test suites (tests\lua\test_*.lua) on the engine's own LuaJIT 2.0.4.
rem   tools\test_lua.cmd [name-substring ...]     e.g.  tools\test_lua.cmd w5   |   tools\test_lua.cmd menu_options
rem Every test file runs in its own Lua state with the repository root as the working directory (the tests read the
rem real scripts from gamedata\scripts by relative path). One row per file: "<n> passed, <m> failed". The files run in
rem parallel lanes, each with its own output and scratch folder (tests\lua\run_all.lua).
rem The runner temp\lua\runlua.exe is built from tests\lua\runlua.c and tests\lua\native_coop.cpp (the coop_native
rem module over the engine\src\xrCoop headers it includes) when it is missing or stale; LUA_REBUILD=1 forces a build.
rem   Stale: the stamp built into the exe (runlua.exe -stamp) differs from the stamp of the sources and the lua51.lib
rem   now. The lib and the stamp come from python -I tools\check_gates.py --lua-stamp, the one place that computes
rem   them: the tests.ok gate compares the same stamp, so a runner linked to another LuaJIT never passes it.
rem   Parallel runs: a build goes to its own folder temp\lua\b_<random> (own .obj and .exe), then replaces the shared
rem   exe with one "move /y" (no delete first, so there is no moment without an exe). While another run is using the
rem   shared exe the move fails: this run says so loudly and runs on its own fresh build; the next run that finds the
rem   shared exe free replaces it.
rem   LUA51_LIB   path to the engine's static lua51.lib (default: engine-ci\_build, Release-AVX, the build of the
rem               current engine sources; there is no older fallback)
rem   VCVARS      path to vcvars64.bat (default: the one vswhere names; check_gates.py --vcvars)
rem GAMMA_SCRIPTS: the real G.A.M.M.A. scripts the tests read (default: the stand's, check_gates.py --gamma-scripts, the
rem one place that names it); without them the G.A.M.M.A.-based tests stop and name GAMMA_SCRIPTS.
rem Per-file output: temp\lua\out\<name>.txt (COOP_LUA_OUT=<dir> moves it: tests\lua\run_all.lua reads the variable).
rem First step: tools\check_layers.py (the layer border, docs/MODES.md section 5); a refusal stops the run with exit 254
rem and its lines. COOP_SKIP_LAYERS=1 skips it: the lead's emergency only. tools\run_all_tests.cmd runs
rem the check once for the whole T and sets COOP_LAYERS_CHECKED=1 for the runners it calls.
rem Both skip settings print a banner so the caller can see that no layer check runs here.
rem Exit code: number of failed files; 255 = could not build/start the runner; 254 = check_layers refused the tree.
setlocal

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

if /i "%COOP_SKIP_LAYERS%"=="1" goto layers_skipped
if "%COOP_LAYERS_CHECKED%"=="1" goto layers_checked
where python >nul 2>nul
if errorlevel 1 goto no_python
python -I "%ROOT%\tools\check_layers.py" --root "%ROOT%"
if errorlevel 1 goto layers_failed
goto layers_done
:no_python
echo [test_lua] python is not on PATH: tools\check_layers.py and tools\check_gates.py cannot run, so no tests
exit /b 254
:layers_failed
echo [test_lua] tools\check_layers.py refused the tree ^(lines above, docs/MODES.md section 5^): no tests
exit /b 254
:layers_checked
set "LAYER_SKIP_REASON=COOP_LAYERS_CHECKED=1"
set "LAYER_SKIP_NOTE="
goto layer_skip_banner
:layers_skipped
set "LAYER_SKIP_REASON=COOP_SKIP_LAYERS=1"
set "LAYER_SKIP_NOTE= (the lead's emergency only)"
:layer_skip_banner
echo [test_lua] ******************************************************************************************
echo [test_lua] %LAYER_SKIP_REASON%: the layer check tools\check_layers.py is SKIPPED%LAYER_SKIP_NOTE%
echo [test_lua] ******************************************************************************************
:layers_done

set "OUT=%ROOT%\temp\lua"
set "LUAJIT=%ROOT%\engine\src\3rd party\luajit-2\src"
set "RUNREL=temp\lua\runlua.exe"
set "BDIR="

if not exist "%OUT%\out" mkdir "%OUT%\out"

rem --- is the shared runner up to date? check_gates names the lib it links, the stamp of both, vcvars64.bat and the
rem G.A.M.M.A. scripts
set "STAMP="
set "VCVARS_BAT="
set "GAMMA_FOUND="
for /f "tokens=1,* delims==" %%A in ('python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --lua-stamp --vcvars --gamma-scripts') do (
	if "%%A"=="lib" set "LUA51_LIB=%%B"
	if "%%A"=="stamp" set "STAMP=%%B"
	if "%%A"=="vcvars" set "VCVARS_BAT=%%B"
	if "%%A"=="gamma" set "GAMMA_FOUND=%%B"
)
if not defined STAMP (
	echo [test_lua] python -I tools\check_gates.py --lua-stamp gave no stamp ^(lines above^): no runner, no tests
	exit /b 255
)
if not defined GAMMA_SCRIPTS if defined GAMMA_FOUND set "GAMMA_SCRIPTS=%GAMMA_FOUND%"
set "HAVE=none"
if exist "%OUT%\runlua.exe" for /f "tokens=1" %%S in ('call "%OUT%\runlua.exe" -stamp') do set "HAVE=%%S"
if defined LUA_REBUILD goto build
if "%HAVE%"=="%STAMP%" goto run
if exist "%OUT%\runlua.exe" echo [test_lua] temp\lua\runlua.exe is stale ^(built from %HAVE%, sources are %STAMP%^), rebuilding

:build
rem --- build runlua.exe (the engine's LuaJIT, static lua51.lib) in a private folder
set "WHY="
if not defined VCVARS_BAT set "WHY=no vcvars64.bat: install the Visual Studio C++ x64 tools or set VCVARS"
if not defined WHY if not exist "%VCVARS_BAT%" set "WHY=vcvars64.bat not found: %VCVARS_BAT% (set VCVARS to override)"
if not defined WHY if not exist "%LUA51_LIB%" set "WHY=lua51.lib not found: %LUA51_LIB% (build the engine in engine-ci or set LUA51_LIB)"
if defined WHY goto cannot_build
call "%VCVARS_BAT%" >nul
if errorlevel 1 set "WHY=vcvars64.bat failed"
if defined WHY goto cannot_build

rem mkdir fails when the folder exists, so two runs never share one (cmd started in the same second repeats %RANDOM%)
set /a TRIES=0
:new_folder
set /a TRIES+=1
set "BNAME=b_%RANDOM%%RANDOM%"
mkdir "%OUT%\%BNAME%" 2>nul && goto have_folder
if %TRIES% lss 20 goto new_folder
echo [test_lua] cannot create a build folder in "%OUT%"
exit /b 255
:have_folder
set "BDIR=%OUT%\%BNAME%"

pushd "%BDIR%"
cl /nologo /MD /O1 /EHsc /std:c++17 /utf-8 /DRUNLUA_STAMP=\"%STAMP%\" /I"%LUAJIT%" /I"%ROOT%\engine\src\xrCoop" ^
	/Fo"%BDIR%\\" /Fe"%BDIR%\runlua.exe" "%ROOT%\tests\lua\runlua.c" "%ROOT%\tests\lua\native_coop.cpp" "%LUA51_LIB%"
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
	rd /s /q "%BDIR%" 2>nul
	set "BDIR="
	set "WHY=runlua build failed (%RC%): a half-edited engine\src\xrCoop header of another task?"
	goto cannot_build
)
move /y "%BDIR%\runlua.exe" "%OUT%\runlua.exe" >nul 2>&1
if errorlevel 1 goto swap_failed
rd /s /q "%BDIR%" 2>nul
set "BDIR="
goto run

:swap_failed
echo [test_lua] ******************************************************************************************
echo [test_lua] temp\lua\runlua.exe is in use by another run and was NOT replaced.
echo [test_lua] This run uses its own fresh build temp\lua\%BNAME%\runlua.exe; a later free run replaces the shared one.
echo [test_lua] ******************************************************************************************
set "RUNREL=temp\lua\%BNAME%\runlua.exe"
goto run

:cannot_build
echo [test_lua] %WHY%
if not exist "%OUT%\runlua.exe" exit /b 255
echo [test_lua] ******************************************************************************************
echo [test_lua] cannot rebuild: this run uses the existing temp\lua\runlua.exe, which may be STALE.
echo [test_lua] ******************************************************************************************

:run
rem The driver is a Lua script too: it lists tests\lua\test_*.lua, runs them through runlua.exe and judges the output.
set "COOP_LUA_RUNLUA=%RUNREL%"
set "COOP_LUA_FILTER=%*"
pushd "%ROOT%"
"%RUNREL%" tests\lua\run_all.lua
set "RC=%ERRORLEVEL%"
popd
if defined BDIR rd /s /q "%BDIR%" 2>nul
exit /b %RC%
