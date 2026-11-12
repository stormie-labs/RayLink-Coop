@echo off
rem Anomaly Coop: writes gamedata\configs\coop\game_schema.json (the settings catalog for the launcher's new world form) from the
rem catalog as it is now: tools\export_game_schema.lua on the Lua host of the test suite (temp\lua\runlua.exe), repository root
rem as the working directory. The host is built by tools\test_lua.cmd; run that once when it is missing.
rem   COOP_SCHEMA_OUT  other output file   COOP_STOCK_TEXT  folder with <lang>\st_mm_faction_select.xml of the stock game
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
if not exist "%ROOT%\temp\lua\runlua.exe" (
	echo export_game_schema: ERROR temp\lua\runlua.exe is missing: run tools\test_lua.cmd once to build it
	exit /b 255
)
pushd "%ROOT%"
"temp\lua\runlua.exe" tools\export_game_schema.lua
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
