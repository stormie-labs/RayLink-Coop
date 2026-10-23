@echo off
rem Stock Anomaly: second window (b) on this PC joins the host above
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tools\launch.ps1" b -Connect 127.0.0.1:27960
if errorlevel 1 pause
