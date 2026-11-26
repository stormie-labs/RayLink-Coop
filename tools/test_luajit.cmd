@echo off
rem RayLink: builds the engine's own LuaJIT (engine\src\3rd party\luajit-2\src, the same sources and defines as
rem luajit.vcxproj, with its generated headers) and runs the tests of tests\luajit\*.c against it.
rem The generated VM object lj_vm.obj comes from python -I tools\check_gates.py --lj-vm, the one place that resolves it:
rem LJ_VM_OBJ, else engine-ci's (the engine build makes it), else the one gen_luajit_artifacts.bat made in engine.
rem   tools\test_luajit.cmd [test-name-substring]
rem Output: anomaly-coop\temp\tests_luajit (COOP_TEST_OUT=<dir> moves it). The LuaJIT objects go to <out>\luajit_obj and
rem lua51_test.lib packs exactly them: build_tests.cmd keeps its objects in <out>\obj of the same COOP_TEST_OUT.
rem The library is built again only when its stamp (check_gates.py --luajit-stamp: the LuaJIT sources, lj_vm.obj and this
rem file) differs from <out>\lua51_test.stamp, which is written after a whole build.
rem MSVC: vcvars64.bat from check_gates.py --vcvars (VCVARS, else the one vswhere names).
rem Exit code: 2 = setup, else build error, else the number of failed test programs.
setlocal EnableDelayedExpansion

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "LJ=%ROOT%\engine\src\3rd party\luajit-2\src"
set "TESTS=%ROOT%\tests\luajit"
set "OUT=%ROOT%\temp\tests_luajit"
if defined COOP_TEST_OUT for %%I in ("%COOP_TEST_OUT%") do set "OUT=%%~fI"

set "LJ_VM="
set "STAMP="
set "VCVARS_BAT="
for /f "tokens=1,* delims==" %%A in ('python -I "%ROOT%\tools\check_gates.py" --root "%ROOT%" --lj-vm --luajit-stamp --vcvars') do (
	if "%%A"=="lj_vm" set "LJ_VM=%%B"
	if "%%A"=="luajit_stamp" set "STAMP=%%B"
	if "%%A"=="vcvars" set "VCVARS_BAT=%%B"
)
if not defined LJ_VM (
	echo [test_luajit] python -I tools\check_gates.py --lj-vm named no lj_vm.obj ^(lines above^)
	exit /b 2
)
if not exist "%LJ_VM%" (
	echo [test_luajit] lj_vm.obj not found: "%LJ_VM%" ^(build the engine in engine-ci, run "%LJ%\gen_luajit_artifacts.bat" x64 once, or set LJ_VM_OBJ^)
	exit /b 2
)
if not exist "%LJ%\lj_bcdef.h" (
	echo [test_luajit] generated LuaJIT headers are missing: run "%LJ%\gen_luajit_artifacts.bat" x64 once
	exit /b 2
)

if not defined VCVARS_BAT (
	echo [test_luajit] no vcvars64.bat: install the Visual Studio C++ x64 tools or set VCVARS
	exit /b 2
)
if not exist "%VCVARS_BAT%" (
	echo [test_luajit] vcvars64.bat not found: "%VCVARS_BAT%" ^(set VCVARS to override^)
	exit /b 2
)
call "%VCVARS_BAT%" >nul
if errorlevel 1 (
	echo [test_luajit] vcvars64.bat failed
	exit /b 2
)

if not exist "%OUT%" mkdir "%OUT%"
set "HAVE=none"
if exist "%OUT%\lua51_test.lib" if exist "%OUT%\lua51_test.stamp" set /p HAVE=<"%OUT%\lua51_test.stamp"
if "%HAVE%"=="%STAMP%" goto run_tests

if exist "%OUT%\lua51_test.stamp" del /q "%OUT%\lua51_test.stamp"
if not exist "%OUT%\luajit_obj" mkdir "%OUT%\luajit_obj"
pushd "%OUT%\luajit_obj"
set "SRCS="
set "OBJS="
for %%F in ("%LJ%\lj_*.c" "%LJ%\lib_*.c" "%LJ%\xr_alloc.c") do (
	set "SRCS=!SRCS! "%%~fF""
	set "OBJS=!OBJS! "%%~nF.obj""
)
rem luajit.vcxproj, Release: WIN32;NDEBUG;_CRT_SECURE_NO_DEPRECATE, /O2. The upstream warnings are not ours to fix.
rem /MP6: several agents' runs share the machine.
cl /nologo /c /MP6 /O2 /MD /W1 /DWIN32 /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE /I"%LJ%" %SRCS% >"%OUT%\luajit_build.log" 2>&1
if errorlevel 1 (
	type "%OUT%\luajit_build.log"
	popd
	echo [test_luajit] the LuaJIT sources did not compile
	exit /b 3
)
lib /nologo /out:"%OUT%\lua51_test.lib" %OBJS% "%LJ_VM%" >>"%OUT%\luajit_build.log" 2>&1
if errorlevel 1 (
	type "%OUT%\luajit_build.log"
	popd
	echo [test_luajit] lib failed
	exit /b 3
)
popd
>"%OUT%\lua51_test.stamp" echo %STAMP%

:run_tests
set /a FAILED=0
set /a RAN=0
for %%T in ("%TESTS%\test_*.c") do (
	set "NAME=%%~nT"
	set "TAKE=1"
	if not "%~1"=="" (
		echo !NAME! | findstr /i /c:"%~1" >nul || set "TAKE=0"
	)
	if "!TAKE!"=="1" (
		pushd "%OUT%"
		cl /nologo /O2 /MD /W3 /DWIN32 /DNDEBUG /D_CRT_SECURE_NO_DEPRECATE /I"%LJ%" "%%~fT" /Fe"%OUT%\!NAME!.exe" ^
			/Fo"%OUT%\!NAME!.obj" /link "%OUT%\lua51_test.lib" >"%OUT%\!NAME!.build.log" 2>&1
		if errorlevel 1 (
			type "%OUT%\!NAME!.build.log"
			echo [test_luajit] !NAME!: build failed
			set /a FAILED+=1
		) else (
			echo [test_luajit] === !NAME!
			"%OUT%\!NAME!.exe"
			if errorlevel 1 (
				echo [test_luajit] !NAME!: FAIL
				set /a FAILED+=1
			) else (
				echo [test_luajit] !NAME!: PASS
			)
		)
		popd
		set /a RAN+=1
	)
)
echo [test_luajit] %RAN% test program^(s^), %FAILED% failed
exit /b %FAILED%
