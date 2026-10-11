@echo off
rem STEP 2 - Guided installation of the fix (run it twice: before and after booting the probe stick).
rem Asks for administrator rights, then runs the PowerShell script from the windows folder.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Fix-Wizard.ps1"
