@echo off
rem Removes the fix (boot entry + \EFI\mpsfix). Nothing else.
rem Asks for administrator rights, then runs the PowerShell script from the windows folder.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\Uninstall-MpsFix.ps1"
echo.
pause
