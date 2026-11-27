@echo off
rem Anomaly Coop: N and L of docs/MODES.md section 10 in one run, and the gate mark temp\gates\tests.ok when both pass.
rem   tools\run_all_tests.cmd          (no arguments: always the full suites)
rem 1. python -I tools\check_gates.py --tests-mark begin: drops the old tests.ok, records both HEAD ids and how many
rem    uncommitted files the tests read (product, tests\, the runners) into temp\gates\tests.state
rem 2. G once: tools\check_layers.py (the layer border, docs/MODES.md section 5). When it passes, the runners below skip
rem    their own copy of it (COOP_LAYERS_CHECKED=1); when it refuses, they refuse too (exit 254) and no test runs there.
rem 3. N, the native tests: tools\build_tests.cmd (xrCoop), tools\test_luajit.cmd (the engine's own LuaJIT), every
rem    engine slice (a Python test that cuts engine functions out of engine\src and runs them over stubs: the ones in
rem    tests\tools through pytest, the scripts in tests\ one by one; a slice file that is missing fails N). Then L,
rem    tools\test_lua.cmd (the Lua tests). build_tests.cmd also runs the static checks of the sources.
rem 4. python -I tools\check_gates.py --tests-mark write: tests.ok (mode=tests, both HEAD ids, dirty=0, native=0, lua=0)
rem    only when N and L exit 0, the tree was clean before and after, neither HEAD moved, and the Lua runner
rem    temp\lua\runlua.exe holds the stamp of its sources and its lua51.lib now (when tools\test_lua.cmd cannot rebuild
rem    it, it runs the old runner and still exits 0). The gate reads exit codes only. tools\check_gates.py demands
rem    tests.ok of the same HEADs for a release (the release rule).
rem COOP_SKIP_LAYERS=1 (the lead's emergency, see build_tests.cmd) runs the tests but writes no tests.ok.
rem Exit code: 0 when both suites passed (and the mark was written, or refused with its reason printed), else 1;
rem 2 when the HEADs could not be read.
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "GATES=%ROOT%\temp\gates"
set "STATE=%GATES%\tests.state"
if not exist "%GATES%" mkdir "%GATES%"

python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --tests-mark begin > "%STATE%"
if errorlevel 1 (
	type "%STATE%"
	echo [run_all_tests] cannot read the HEAD ids: no run
	exit /b 2
)
type "%STATE%"

set "COOP_LAYERS_CHECKED="
if /i "%COOP_SKIP_LAYERS%"=="1" goto layers_done
python -I "%ROOT%\tools\check_layers.py" --root "%ROOT%"
if not errorlevel 1 set "COOP_LAYERS_CHECKED=1"
:layers_done

call "%ROOT%\tools\build_tests.cmd"
set "NRC=%ERRORLEVEL%"
rem The tests of the engine's own LuaJIT (tests\luajit) count as native tests.
call "%ROOT%\tools\test_luajit.cmd"
set "JRC=%ERRORLEVEL%"
if not "%JRC%"=="0" if "%NRC%"=="0" set "NRC=%JRC%"
rem The engine slices, every one of them (tests\tools\test_gates.py fails when a slice under tests\ is not named here).
set "SRC=0"
python -B -m pytest -q -p no:cacheprovider ^
	"%ROOT%\tests\tools\test_campfire_damage.py" ^
	"%ROOT%\tests\tools\test_client_ammo_reload.py" ^
	"%ROOT%\tests\tools\test_clone_pending_fire.py" ^
	"%ROOT%\tests\tools\test_clone_placement_hooks.py" ^
	"%ROOT%\tests\tools\test_console_writer_wiring.py" ^
	"%ROOT%\tests\tools\test_container_reject.py" ^
	"%ROOT%\tests\tools\test_exit_reason.py" ^
	"%ROOT%\tests\tools\test_items_gift_late.py" ^
	"%ROOT%\tests\tools\test_levels_body_wiring.py" ^
	"%ROOT%\tests\tools\test_local_zone_release.py" ^
	"%ROOT%\tests\tools\test_move_admission_wiring.py" ^
	"%ROOT%\tests\tools\test_proxy_ammo_supply.py" ^
	"%ROOT%\tests\tools\test_script_relay_slice.py" ^
	"%ROOT%\tests\tools\test_silencer_detach.py" ^
	"%ROOT%\tests\tools\test_sound_core_start.py" ^
	"%ROOT%\tests\tools\test_texture_descr_slice.py" ^
	"%ROOT%\tests\tools\test_trade_delivery.py" ^
	"%ROOT%\tests\tools\test_trader_identity_api.py" ^
	"%ROOT%\tests\tools\test_weapon_brief_info.py" ^
	"%ROOT%\tests\tools\test_weapon_clone_wgl.py" ^
	"%ROOT%\tests\tools\test_native_build.py" ^
	"%ROOT%\tests\tools\test_world_events_slice.py"
if errorlevel 1 set "SRC=1"
rem The tools' own tests that nothing else runs: the layer check and the stand's scripts. A stand script or an allow-list row
rem that breaks its rule is found here, not at the next stand run. tests\tools\test_gates.py stays out: it takes 20 minutes.
python -B -m pytest -q -p no:cacheprovider ^
	"%ROOT%\tests\tools\test_layers.py" ^
	"%ROOT%\tests\tools\test_stand_cleanup.py" ^
	"%ROOT%\tests\tools\test_stand_dump.py" ^
	"%ROOT%\tests\tools\test_stand_guard.py" ^
	"%ROOT%\tests\tools\test_stand_patterns.py"
if errorlevel 1 set "SRC=1"
python -I "%ROOT%\tests\test_s6_hub_paths.py"
if errorlevel 1 set "SRC=1"
python -I "%ROOT%\tests\test_s6_npc_paths.py"
if errorlevel 1 set "SRC=1"
python -I "%ROOT%\tests\test_story_worldstate.py"
if errorlevel 1 set "SRC=1"
python -I "%ROOT%\tests\test_survival_s6_paths.py"
if errorlevel 1 set "SRC=1"
if not "%SRC%"=="0" if "%NRC%"=="0" set "NRC=%SRC%"
call "%ROOT%\tools\test_lua.cmd"
set "LRC=%ERRORLEVEL%"
echo [run_all_tests] native tests: exit %NRC% (LuaJIT tests: exit %JRC%, engine slices: exit %SRC%); Lua tests: exit %LRC%

if /i "%COOP_SKIP_LAYERS%"=="1" (
	echo [run_all_tests] ******************************************************************************************
	echo [run_all_tests] COOP_SKIP_LAYERS=1: the layer check was skipped, so this run writes NO tests.ok
	echo [run_all_tests] ******************************************************************************************
	goto done
)
python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --tests-mark write --state "%STATE%" --native %NRC% --lua %LRC%

:done
if not "%NRC%"=="0" exit /b 1
if not "%LRC%"=="0" exit /b 1
exit /b 0
