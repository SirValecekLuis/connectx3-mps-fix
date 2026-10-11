@echo off
rem STEP 1 - Is my Mellanox ConnectX-3 affected? Read-only, changes nothing.
rem Asks for administrator rights, then runs the PowerShell script from the windows folder.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Check-MyCard.ps1"
echo.
pause
