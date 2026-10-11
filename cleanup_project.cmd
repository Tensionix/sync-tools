@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

title Audion Sync Tools - Project Cleanup

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%A in ("%SCRIPT_DIR%") do set "ROOT=%%~fA"

set "ASSUME_YES=0"
set "NO_PAUSE=0"
set "DRY_RUN=0"

:PARSE_ARGS
if "%~1"=="" goto ARGS_DONE
if /I "%~1"=="/Y" set "ASSUME_YES=1"
if /I "%~1"=="/YES" set "ASSUME_YES=1"
if /I "%~1"=="--yes" set "ASSUME_YES=1"
if /I "%~1"=="/NOPAUSE" set "NO_PAUSE=1"
if /I "%~1"=="--no-pause" set "NO_PAUSE=1"
if /I "%~1"=="/DRYRUN" set "DRY_RUN=1"
if /I "%~1"=="--dry-run" set "DRY_RUN=1"
shift
goto PARSE_ARGS

:ARGS_DONE
if defined AUDION_UNATTENDED set "ASSUME_YES=1"
if defined AUDION_NO_PAUSE set "NO_PAUSE=1"

if not exist "%ROOT%\Engine\BackupEngine.psm1" (
  echo [ERROR] This does not look like the Audion Sync Tools root:
  echo   %ROOT%
  call :PAUSE_IF_NEEDED
  exit /b 1
)

rem The data folder is never a target. It lives beside the program, not inside
rem it, and this script does not leave its own root - but say it out loud, since
rem that folder holds keys and the only local copy of MAIN VPS.
echo ======================================================================
echo   AUDION SYNC TOOLS - PROJECT CLEANUP
echo ======================================================================
echo Root:
echo   %ROOT%
echo.
echo Removed - what the program downloads again by itself:
echo   - portable rclone        Tools\rclone
echo   - portable terminal      Tools\terminal
echo   - tunnel client          Tunnel\Bin
echo   - archiver, editors      Tools\PeaZip, Tools\edit, Tools\micro
echo   - build caches           Source\bin, Source\obj, Source\Ps\bin, Source\Ps\obj
echo.
echo Removed - what belongs to this machine, not to the program:
echo   - pointer to the data    config\profile.json
echo   - window settings        config\gui-settings.json
echo   - logs and scratch       logs, ._runtime
echo   - stray files            *.tmp, *.bak, Thumbs.db, desktop.ini
echo.
echo Preserved:
echo   - Start.exe              the launcher is not downloaded, it stays
echo   - App                    the built window and its PowerShell: builder_main.cmd build_app makes it anew
echo   - config                 samples, version.json, colors, terminal settings
echo   - the data folder        Audion Backup ^<Machine^> beside the program - never touched
echo.
echo After a cleanup the window asks for DATA FOLDER again: the pointer is gone.
echo Tools come back through the program: SETTINGS - UPDATE downloads whatever is
echo missing. From a console the same is builder_main.cmd install_rclone,
echo install_terminal, install_cloudflared, install_extras.
echo.

call :MEASURE
if defined FREED_MB echo Reclaimable now: %FREED_MB% MB
echo.

if "%DRY_RUN%"=="1" (
  echo Mode: DRY RUN - nothing will be deleted.
) else if not "%ASSUME_YES%"=="1" (
  choice /C YNQ /N /M "Proceed with project cleanup? [Y/N/Q]: "
  if errorlevel 3 goto QUIT
  if errorlevel 2 goto CANCELLED
)

echo.
echo [CLEAN] Starting...
set "ERROR_COUNT=0"

call :REMOVE_DIR "Tools\rclone"
call :REMOVE_DIR "Tools\rclone.prev"
call :REMOVE_DIR "Tools\terminal"
call :REMOVE_DIR "Tools\terminal.prev"
call :REMOVE_DIR "Tunnel\Bin"
call :REMOVE_DIR "Tools\PeaZip"
call :REMOVE_DIR "Tools\edit"
call :REMOVE_DIR "Tools\micro"

call :REMOVE_DIR "Source\bin"
call :REMOVE_DIR "Source\obj"
call :REMOVE_DIR "Source\Ps\bin"
call :REMOVE_DIR "Source\Ps\obj"

call :REMOVE_FILE "config\profile.json"
call :REMOVE_FILE "config\gui-settings.json"

call :CLEAR_DIR "logs"
call :REMOVE_DIR "._runtime"

echo [FILES] Stray files...
for /r "%ROOT%" %%F in (*.tmp *.bak Thumbs.db desktop.ini) do (
  call :IS_PROTECTED "%%~fF"
  if errorlevel 1 if exist "%%~fF" (
    if "%DRY_RUN%"=="1" (
      echo   del "%%~fF"
    ) else (
      del /f /q "%%~fF" >nul 2>nul
      if errorlevel 1 (
        echo [ERROR] Cannot remove: %%~fF
        set /a ERROR_COUNT+=1
      )
    )
  )
)

echo.
if "%DRY_RUN%"=="1" (
  echo [OK] Dry run finished. Nothing was deleted.
  call :PAUSE_IF_NEEDED
  exit /b 0
)
if "%ERROR_COUNT%"=="0" (
  echo [OK] Cleanup finished.
  echo      Tools are gone on purpose: the UPDATE button of the program downloads them again.
  call :PAUSE_IF_NEEDED
  exit /b 0
)
echo [ERROR] Cleanup finished with %ERROR_COUNT% error^(s^).
call :PAUSE_IF_NEEDED
exit /b 1

:MEASURE
rem How much this would free. Counted by the PowerShell the program carries,
rem through a temporary script: `for /f` parses the command itself and eats the
rem quotes around the path. Without App\ there is nothing to count with, and
rem the cleanup goes on without the number.
set "FREED_MB="
set "MEASURE_PS=%ROOT%\App\AudionPs.exe"
if not exist "%MEASURE_PS%" exit /b 0

set "MEASURE_FILE=%TEMP%\audion-sync-tools-measure.ps1"
> "%MEASURE_FILE%" echo $root = $env:AUDION_MEASURE_ROOT
>> "%MEASURE_FILE%" echo $parts = @('Tools\rclone','Tools\terminal','Tunnel\Bin','Tools\PeaZip','Tools\edit','Tools\micro','Source\bin','Source\obj','Source\Ps\bin','Source\Ps\obj','logs','._runtime')
>> "%MEASURE_FILE%" echo $sum = 0
>> "%MEASURE_FILE%" echo foreach ($part in $parts) {
>> "%MEASURE_FILE%" echo $path = Join-Path $root $part
>> "%MEASURE_FILE%" echo if (Test-Path -LiteralPath $path) {
>> "%MEASURE_FILE%" echo $sum += (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue ^| Measure-Object Length -Sum).Sum
>> "%MEASURE_FILE%" echo }
>> "%MEASURE_FILE%" echo }
>> "%MEASURE_FILE%" echo [int]($sum / 1MB)

set "AUDION_MEASURE_ROOT=%ROOT%"
rem The path of the program has spaces: "call" in front keeps cmd from dropping the quotes of a line that begins with one.
for /f "usebackq tokens=*" %%S in (`call "%MEASURE_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%MEASURE_FILE%"`) do set "FREED_MB=%%S"
set "AUDION_MEASURE_ROOT="
del /f /q "%MEASURE_FILE%" >nul 2>nul
exit /b 0

:REMOVE_DIR
set "REL=%~1"
set "TARGET=%ROOT%\%REL%"
if not exist "%TARGET%\" exit /b 0
if "%DRY_RUN%"=="1" (
  echo   rmdir /s "%TARGET%"
  exit /b 0
)
echo [REMOVE] %REL%
rd /s /q "%TARGET%" >nul 2>nul
if exist "%TARGET%\" (
  echo [ERROR] Cannot remove: %TARGET%
  set /a ERROR_COUNT+=1
)
exit /b 0

:REMOVE_FILE
set "REL=%~1"
set "TARGET=%ROOT%\%REL%"
if not exist "%TARGET%" exit /b 0
if "%DRY_RUN%"=="1" (
  echo   del "%TARGET%"
  exit /b 0
)
echo [REMOVE] %REL%
del /f /q "%TARGET%" >nul 2>nul
if exist "%TARGET%" (
  echo [ERROR] Cannot remove: %TARGET%
  set /a ERROR_COUNT+=1
)
exit /b 0

:CLEAR_DIR
set "REL=%~1"
set "TARGET=%ROOT%\%REL%"
if not exist "%TARGET%\" exit /b 0
if "%DRY_RUN%"=="1" (
  echo   clear "%TARGET%"
  exit /b 0
)
echo [CLEAR] %REL%
for /d %%D in ("%TARGET%\*") do rd /s /q "%%~fD" >nul 2>nul
for %%F in ("%TARGET%\*") do del /f /q "%%~fF" >nul 2>nul
exit /b 0

:IS_PROTECTED
rem Nothing under config is a build product apart from the two files named
rem above, and the stray-file sweep must not reach into it.
set "FILE_ABS=%~f1"
echo "%FILE_ABS%" | findstr /I /C:"%ROOT%\config\" >nul 2>nul
if not errorlevel 1 exit /b 0
echo "%FILE_ABS%" | findstr /I /C:"%ROOT%\.git\" >nul 2>nul
if not errorlevel 1 exit /b 0
exit /b 1

:CANCELLED
echo.
echo [CANCELLED] Nothing was deleted.
call :PAUSE_IF_NEEDED
exit /b 0

:QUIT
echo.
echo [QUIT] Nothing was deleted.
exit /b 0

:PAUSE_IF_NEEDED
if "%NO_PAUSE%"=="1" exit /b 0
echo.
pause
exit /b 0
