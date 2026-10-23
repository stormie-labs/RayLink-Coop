@echo off
rem GAMMA: second window (b) on this PC joins the host above
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\launch.ps1" b -Connect 127.0.0.1:27960 -GameDir E:\AnomalyCoopGamma
if errorlevel 1 pause
