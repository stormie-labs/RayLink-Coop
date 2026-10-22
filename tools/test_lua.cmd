@echo off
rem Anomaly Coop: runs the Lua stub-test suites (tests\lua\test_*.lua) on the engine's own LuaJIT 2.0.4.
rem   tools\test_lua.cmd [name-substring ...]     e.g.  tools\test_lua.cmd w5   |   tools\test_lua.cmd menu_options
rem Every test file runs in its own Lua state with the repository root as the working directory (the tests read the
rem real scripts from gamedata\scripts by relative path). One row per file: "<n> passed, <m> failed".
rem Builds temp\lua\runlua.exe from tests\lua\runlua.c when it is missing (set LUA_REBUILD=1 to force a rebuild).
rem   LUA51_LIB   path to the engine's static lua51.lib (default: engine\_build, then engine-ci\_build, Release-AVX)
rem   VCVARS      path to vcvars64.bat
rem Per-file output: temp\lua\out\<name>.txt. Exit code: number of failed files; 255 = could not build/start the runner.
setlocal

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "OUT=%ROOT%\temp\lua"
set "LUAJIT=%ROOT%\engine\src\3rd party\luajit-2\src"

if not exist "%OUT%\out" mkdir "%OUT%\out"
if defined LUA_REBUILD if exist "%OUT%\runlua.exe" del /q "%OUT%\runlua.exe"
if exist "%OUT%\runlua.exe" goto run

rem --- build runlua.exe (the engine's LuaJIT, static lua51.lib)
if not defined VCVARS set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
	echo [test_lua] vcvars64.bat not found: "%VCVARS%" ^(set VCVARS to override^)
	exit /b 255
)
if not defined LUA51_LIB set "LUA51_LIB=%ROOT%\engine\_build\_game\bin_dbg\x64\Release-AVX\lua51.lib"
if not exist "%LUA51_LIB%" set "LUA51_LIB=%ROOT%\engine-ci\_build\_game\bin_dbg\x64\Release-AVX\lua51.lib"
if not exist "%LUA51_LIB%" (
	echo [test_lua] lua51.lib not found ^(build the engine first or set LUA51_LIB^)
	exit /b 255
)
call "%VCVARS%" >nul
if errorlevel 1 (
	echo [test_lua] vcvars64.bat failed
	exit /b 255
)
pushd "%OUT%"
cl /nologo /MD /O1 /I"%LUAJIT%" "%ROOT%\tests\lua\runlua.c" "%LUA51_LIB%" /Fe"%OUT%\runlua.exe"
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
	echo [test_lua] runlua build failed ^(%RC%^)
	exit /b 255
)

:run
rem The driver is a Lua script too: it lists tests\lua\test_*.lua, runs each through runlua.exe and judges the output.
set "COOP_LUA_RUNLUA=temp\lua\runlua.exe"
set "COOP_LUA_FILTER=%*"
pushd "%ROOT%"
"%OUT%\runlua.exe" tests\lua\run_all.lua
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
