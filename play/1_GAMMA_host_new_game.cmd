@echo off
rem GAMMA: host window (a), new game, hosts a coop session at once
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\launch.ps1" a -NewGame -HostSession -GameDir E:\AnomalyCoopGamma
if errorlevel 1 pause
