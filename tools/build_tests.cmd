@echo off
rem Anomaly Coop: builds and runs the xrCoop unit tests (no framework, MSVC command line).
rem   tools\build_tests.cmd [test-name-substring ...]     extra arguments are passed to coop_tests.exe
rem Output: anomaly-coop\temp\tests\coop_tests.exe; COOP_TEST_OUT=<dir> moves it (parallel agents must not share one;
rem a second run on the same folder waits for the first).
rem The build is incremental: tools\native_build.py compares the recorded inputs of each object, with test_util.h
rem precompiled and /MP, then links and runs the exe.
rem Python is required before the layer check. tools\check_layers.py (docs/MODES.md section 5) stops the run with
rem exit 254 and its lines on refusal. COOP_SKIP_LAYERS=1 skips it: the lead's emergency only. tools\run_all_tests.cmd runs
rem the check once for the whole T and sets COOP_LAYERS_CHECKED=1 for the runners it calls.
rem Both skip settings print a banner so the caller can see that no layer check runs here.
rem Then the static checks tools\check_actor_compare.py and tools\check_font_atlas.py; a refusal stops the run with exit 253.
rem MSVC: vcvars64.bat from python -I tools\check_gates.py --vcvars (VCVARS, else the one vswhere names).
rem Exit code: 254 = check_layers refused the tree, 253 = a static check refused the sources, else the build error code,
rem else the test exe exit code.
setlocal

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"

where python >nul 2>nul
if errorlevel 1 goto no_python
if /i "%COOP_SKIP_LAYERS%"=="1" goto layers_skipped
if "%COOP_LAYERS_CHECKED%"=="1" goto layers_checked
python -I "%ROOT%\tools\check_layers.py" --root "%ROOT%"
if errorlevel 1 goto layers_failed
goto layers_done
:no_python
echo [build_tests] python is not on PATH: tools\check_layers.py and tools\native_build.py cannot run, so no build
exit /b 254
:layers_failed
echo [build_tests] tools\check_layers.py refused the tree ^(lines above, docs/MODES.md section 5^): no build, no tests
exit /b 254
:layers_checked
set "LAYER_SKIP_REASON=COOP_LAYERS_CHECKED=1"
set "LAYER_SKIP_NOTE="
goto layer_skip_banner
:layers_skipped
set "LAYER_SKIP_REASON=COOP_SKIP_LAYERS=1"
set "LAYER_SKIP_NOTE= (the lead's emergency only)"
:layer_skip_banner
echo [build_tests] ******************************************************************************************
echo [build_tests] %LAYER_SKIP_REASON%: the layer check tools\check_layers.py is SKIPPED%LAYER_SKIP_NOTE%
echo [build_tests] ******************************************************************************************
:layers_done

set "OUT=%ROOT%\temp\tests"
rem A relative COOP_TEST_OUT is made absolute against the current directory, trailing spaces dropped.
if defined COOP_TEST_OUT for %%I in ("%COOP_TEST_OUT%") do set "OUT=%%~fI"

if not exist "%OUT%" mkdir "%OUT%"
rem The static checks of hand-kept sources that no test runs on the real tree: the monsters' C++ compares no actor with
rem Actor() (tools\check_actor_compare.py) and the font atlases match their ini files (tools\check_font_atlas.py).
for %%C in (check_actor_compare check_font_atlas) do (
	python -I "%ROOT%\tools\%%C.py" >"%OUT%\%%C.log" 2>&1
	if errorlevel 1 (
		type "%OUT%\%%C.log"
		echo [build_tests] tools\%%C.py refused the sources ^(lines above^): no build, no tests
		exit /b 253
	)
)

set "VCVARS_BAT="
for /f "tokens=1,* delims==" %%A in ('python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --vcvars') do (
	if "%%A"=="vcvars" set "VCVARS_BAT=%%B"
)
if not defined VCVARS_BAT (
	echo [build_tests] no vcvars64.bat: install the Visual Studio C++ x64 tools or set VCVARS
	exit /b 2
)
if not exist "%VCVARS_BAT%" (
	echo [build_tests] vcvars64.bat not found: "%VCVARS_BAT%" ^(set VCVARS to override^)
	exit /b 2
)
call "%VCVARS_BAT%" >nul
if errorlevel 1 (
	echo [build_tests] vcvars64.bat failed
	exit /b 2
)

python -I "%ROOT%\tools\native_build.py" --root "%ROOT%" --out "%OUT%" -- %*
exit /b %ERRORLEVEL%
