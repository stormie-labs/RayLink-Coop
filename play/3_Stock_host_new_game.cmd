@echo off
rem Stock Anomaly: host window (a), new game, hosts a coop session at once
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\launch.ps1" a -NewGame -HostSession
if errorlevel 1 pause
