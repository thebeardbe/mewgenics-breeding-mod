@echo off
rem Double-click wrapper: runs scripts\install.ps1 and pauses so the report
rem stays on screen. An older flat unpack keeps install.ps1 beside this file, so
rem fall back to that. Arguments pass through, e.g.:
rem
rem     install.bat -DryRun
rem     install.bat -Uninstall
rem     install.bat -GameDir "D:\Games\Mewgenics"
rem     install.bat -BundledLoader
setlocal
cd /d "%~dp0"

set "PS1=%~dp0scripts\install.ps1"
if not exist "%PS1%" set "PS1=%~dp0install.ps1"
if not exist "%PS1%" (
  echo error: install.ps1 is missing. Unpack the whole release folder before running this.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "rc=%ERRORLEVEL%"

echo.
if not "%rc%"=="0" echo Installer exited with code %rc%.
pause
endlocal & exit /b %rc%
