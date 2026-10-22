@echo off
rem Anomaly Coop: builds and runs the xrCoop unit tests (no framework, MSVC command line).
rem   tools\build_tests.cmd [test-name-substring ...]     extra arguments are passed to coop_tests.exe
rem Output: anomaly-coop\temp\tests\coop_tests.exe. Exit code: build error code, else the test exe exit code.
setlocal

set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
set "SRC=%ROOT%\engine\src"
set "COOP=%SRC%\xrCoop"
set "ENET=%SRC%\3rd party\enet"
set "OUT=%ROOT%\temp\tests"

if not defined VCVARS set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
	echo [build_tests] vcvars64.bat not found: "%VCVARS%" ^(set VCVARS to override^)
	exit /b 2
)
call "%VCVARS%" >nul
if errorlevel 1 (
	echo [build_tests] vcvars64.bat failed
	exit /b 2
)

if not exist "%OUT%\obj_enet" mkdir "%OUT%\obj_enet"
if not exist "%OUT%\obj" mkdir "%OUT%\obj"
if exist "%OUT%\coop_tests.exe" del /q "%OUT%\coop_tests.exe"

rem --- ENet (C, upstream code, warnings are not ours to fix)
pushd "%OUT%\obj_enet"
cl /nologo /c /O2 /MD /W3 /DNDEBUG /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS /D_WINSOCK_DEPRECATED_NO_WARNINGS ^
	/wd4005 /wd4244 /wd4267 /wd4018 /wd4146 /wd4996 /wd5287 ^
	/I"%ENET%\include" ^
	"%ENET%\callbacks.c" "%ENET%\compress.c" "%ENET%\host.c" "%ENET%\list.c" ^
	"%ENET%\packet.c" "%ENET%\peer.c" "%ENET%\protocol.c" "%ENET%\win32.c"
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
	echo [build_tests] ENet compile failed
	exit /b %RC%
)

rem --- xrCoop + tests (C++17, /W4)
pushd "%OUT%\obj"
cl /nologo /std:c++17 /EHsc /MD /O2 /W4 /utf-8 /DNDEBUG /DWIN32 /D_WINDOWS /D_CRT_SECURE_NO_WARNINGS /D_WINSOCK_DEPRECATED_NO_WARNINGS ^
	/I"%COOP%" /I"%ENET%\include" /I"%ROOT%\tests" ^
	"%COOP%\coop_wire.cpp" "%COOP%\coop_protocol.cpp" "%COOP%\coop_transport.cpp" "%COOP%\coop_session.cpp" ^
	"%ROOT%\tests\test_*.cpp" ^
	"%OUT%\obj_enet\callbacks.obj" "%OUT%\obj_enet\compress.obj" "%OUT%\obj_enet\host.obj" "%OUT%\obj_enet\list.obj" ^
	"%OUT%\obj_enet\packet.obj" "%OUT%\obj_enet\peer.obj" "%OUT%\obj_enet\protocol.obj" "%OUT%\obj_enet\win32.obj" ^
	/Fe"%OUT%\coop_tests.exe" ^
	/link /nologo ws2_32.lib winmm.lib bcrypt.lib
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="0" (
	echo [build_tests] build failed ^(%RC%^)
	exit /b %RC%
)

echo [build_tests] running "%OUT%\coop_tests.exe" %*
"%OUT%\coop_tests.exe" %*
exit /b %ERRORLEVEL%
