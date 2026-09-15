@echo off
rem Double-click wrapper for the uninstaller. It asks first, naming the game
rem folder it is about to clean, then runs install.ps1 -Uninstall and pauses so
rem the report stays on screen. Arguments pass through, e.g.:
rem
rem     uninstall.bat
rem     uninstall.bat -DryRun
rem     uninstall.bat -GameDir "D:\Games\Mewgenics"
rem
rem The folder is read from a read-only dry run of that same script, so the
rem Steam lookup lives in one place and the question names the real folder
rem instead of a guess.
setlocal EnableExtensions
cd /d "%~dp0"

rem The bundle keeps install.ps1 in scripts\; an older flat unpack keeps it
rem beside this wrapper. Prefer scripts\, fall back to beside.
set "INSTALL_PS1=%~dp0scripts\install.ps1"
if not exist "%INSTALL_PS1%" set "INSTALL_PS1=%~dp0install.ps1"
if not exist "%INSTALL_PS1%" (
  echo error: install.ps1 is missing. Unpack the whole release folder before running this.
  pause
  exit /b 1
)

rem Both calls below are built from the parsed flags, so no switch is ever
rem passed twice (PowerShell refuses a repeated switch). Neither set uses the
rem "var=value" quotes: a path braces its own quotes, and wrapping it in a
rem second pair would leave an "&" in the path outside any quote.
set "GAMEDIR="
set "DRYRUN="
:parse
if "%~1"=="" goto parsed
set "ARG=%~1"
if /i "%ARG%"=="-DryRun" (
  set "DRYRUN=1"
) else if /i "%ARG%"=="-GameDir" (
  if "%~2"=="" (
    echo error: -GameDir needs a folder, for example -GameDir "D:\Games\Mewgenics"
    pause
    exit /b 2
  )
  set "GAMEDIR=%~2"
  shift
) else if /i "%ARG%"=="-Uninstall" (
  rem This wrapper always uninstalls; accept the flag so an old habit works.
) else (
  echo error: unknown argument "%ARG%"
  echo        usage: uninstall.bat [-DryRun] [-GameDir "D:\Games\Mewgenics"]
  pause
  exit /b 2
)
shift
goto parse
:parsed

set "ARGS="
if defined GAMEDIR set ARGS=-GameDir "%GAMEDIR%"
set "DRYRUNARG="
if defined DRYRUN set "DRYRUNARG=-DryRun"
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_PS1%"

set "REPORT=%TEMP%\mewgenics-uninstall-%RANDOM%%RANDOM%.txt"
%PS% -Uninstall -DryRun %ARGS% > "%REPORT%" 2>&1
set "rc=%ERRORLEVEL%"
if not "%rc%"=="0" (
  type "%REPORT%"
  del "%REPORT%" >nul 2>&1
  echo.
  echo Nothing was removed. The uninstaller exited with code %rc%.
  pause
  exit /b %rc%
)

set "FOLDER="
for /f "usebackq delims=" %%L in ("%REPORT%") do call :grabdir "%%L"
del "%REPORT%" >nul 2>&1
if not defined FOLDER (
  echo error: could not read the game folder from the installer's report.
  echo        run install.ps1 -Uninstall directly.
  pause
  exit /b 1
)

echo This removes the Mewgenics Breeding mod from:
echo.
echo     "%FOLDER%"
echo.
set "ANSWER="
set /p "ANSWER=Remove the mod from that folder? [y/N] "
if /i not "%ANSWER%"=="y" if /i not "%ANSWER%"=="yes" (
  echo.
  echo Nothing was removed.
  pause
  exit /b 0
)

echo.
%PS% -Uninstall %ARGS% %DRYRUNARG%
set "rc=%ERRORLEVEL%"
echo.
if not "%rc%"=="0" echo The uninstaller exited with code %rc%.
pause
endlocal & exit /b %rc%

:grabdir
rem One line of the installer's report: keep the folder after the fixed
rem "       game folder: " prefix (7 spaces, then 13 characters).
if defined FOLDER exit /b 0
set "LINE=%~1"
if "%LINE:~0,20%"=="       game folder: " set "FOLDER=%LINE:~20%"
exit /b 0
