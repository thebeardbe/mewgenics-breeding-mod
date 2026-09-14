@echo off
rem Double-click wrapper: runs install.ps1 and pauses so the report stays on
rem screen. Arguments pass through, e.g.:
rem
rem     install.bat -DryRun
rem     install.bat -Uninstall
rem     install.bat -GameDir "D:\Games\Mewgenics"
rem     install.bat -BundledLoader
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set "rc=%ERRORLEVEL%"

echo.
if not "%rc%"=="0" echo Installer exited with code %rc%.
pause
endlocal & exit /b %rc%
