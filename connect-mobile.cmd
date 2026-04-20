@echo off
setlocal
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0connect-mobile.ps1"
if errorlevel 1 pause
endlocal
