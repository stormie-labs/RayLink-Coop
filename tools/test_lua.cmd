@echo off
rem Anomaly Coop: runs the Lua stub-test suites (tests\lua\test_*.lua) on the engine's own LuaJIT 2.0.4.
rem   tools\test_lua.cmd [name-substring ...]     e.g.  tools\test_lua.cmd w5   |   tools\test_lua.cmd menu_options
rem Every test file runs in its own Lua state with the repository root as the working directory (the tests read the
rem real scripts from gamedata\scripts by relative path). One row per file: "<n> passed, <m> failed".
rem The runner temp\lua\runlua.exe is built from tests\lua\runlua.c and tests\lua\native_coop.cpp (the coop_native
rem module over the engine\src\xrCoop headers it includes) when it is missing or stale; LUA_REBUILD=1 forces a build.
rem   Stale: the stamp built into the exe (runlua.exe -stamp) differs from the stamp of the sources now, the first 8 hex
rem   digits of the SHA-1 of runlua.c, native_coop.cpp, every engine\src\xrCoop header native_coop.cpp includes and
rem   this script.
rem   Parallel runs: a build goes to its own folder temp\lua\b_<random> (own .obj and .exe), then replaces the shared
rem   exe with one "move /y" (no delete first, so there is no moment without an exe). While another run is using the
rem   shared exe the move fails: this run says so loudly and runs on its own fresh build; the next run that finds the
rem   shared exe free replaces it.
rem   LUA51_LIB   path to the engine's static lua51.lib (default: engine\_build, then engine-ci\_build, Release-AVX)
rem   VCVARS      path to vcvars64.bat
rem Per-file output: temp\lua\out\<name>.txt. Exit code: number of failed files; 255 = could not build/start the runner.
setlocal

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "OUT=%ROOT%\temp\lua"
set "LUAJIT=%ROOT%\engine\src\3rd party\luajit-2\src"
set "RUNREL=temp\lua\runlua.exe"
set "BDIR="

if not exist "%OUT%\out" mkdir "%OUT%\out"

rem --- is the shared runner up to date?
set "STAMP="
call :hash "%ROOT%\tests\lua\runlua.c"
call :hash "%ROOT%\tests\lua\native_coop.cpp"
for /f "tokens=2" %%I in ('findstr /b /c:"#include" "%ROOT%\tests\lua\native_coop.cpp"') do (
	if exist "%ROOT%\engine\src\xrCoop\%%~I" call :hash "%ROOT%\engine\src\xrCoop\%%~I"
)
call :hash "%~f0"
set "HAVE=none"
if exist "%OUT%\runlua.exe" for /f "tokens=1" %%S in ('call "%OUT%\runlua.exe" -stamp') do set "HAVE=%%S"
if defined LUA_REBUILD goto build
if "%HAVE%"=="%STAMP%" goto run
if exist "%OUT%\runlua.exe" echo [test_lua] temp\lua\runlua.exe is stale ^(built from %HAVE%, sources are %STAMP%^), rebuilding

:build
rem --- build runlua.exe (the engine's LuaJIT, static lua51.lib) in a private folder
if not defined VCVARS set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not defined LUA51_LIB set "LUA51_LIB=%ROOT%\engine\_build\_game\bin_dbg\x64\Release-AVX\lua51.lib"
if not exist "%LUA51_LIB%" set "LUA51_LIB=%ROOT%\engine-ci\_build\_game\bin_dbg\x64\Release-AVX\lua51.lib"
set "WHY="
if not exist "%VCVARS%" set "WHY=vcvars64.bat not found: %VCVARS% (set VCVARS to override)"
if not defined WHY if not exist "%LUA51_LIB%" set "WHY=lua51.lib not found (build the engine first or set LUA51_LIB)"
if defined WHY goto cannot_build
call "%VCVARS%" >nul
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
	echo [test_lua] runlua build failed ^(%RC%^)
	rd /s /q "%BDIR%" 2>nul
	exit /b 255
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
rem The driver is a Lua script too: it lists tests\lua\test_*.lua, runs each through runlua.exe and judges the output.
set "COOP_LUA_RUNLUA=%RUNREL%"
set "COOP_LUA_FILTER=%*"
pushd "%ROOT%"
"%RUNREL%" tests\lua\run_all.lua
set "RC=%ERRORLEVEL%"
popd
if defined BDIR rd /s /q "%BDIR%" 2>nul
exit /b %RC%

rem --- appends the first 8 hex digits of the SHA-1 of file %1 to STAMP ("missing" marks an unreadable file)
:hash
set "H="
for /f "skip=1 delims=" %%L in ('certutil -hashfile "%~1" SHA1 2^>nul') do if not defined H set "H=%%L"
if not defined H set "H=missing0"
set "H=%H: =%"
set "STAMP=%STAMP%%H:~0,8%"
exit /b 0
