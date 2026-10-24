@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

title Audion Sync Tools - Builder

set "BASE_DIR=%~dp0"
if "%BASE_DIR:~-1%"=="\" set "BASE_DIR=%BASE_DIR:~0,-1%"
cd /d "%BASE_DIR%" || exit /b 1

rem What the build does: makes App\ - the window and the PowerShell the program
rem carries (App\AudionPs.exe) - fetches the portable tools the program brings
rem along and runs the self-tests. The tools do not live in the sources:
rem cleanup_project.cmd removes them, and these steps bring them back.
rem
rem One PowerShell for everything: App\AudionPs.exe. No PowerShell of the system
rem takes part, neither the orchestrator's nor Windows PowerShell 5.1. Step 01
rem makes it and is therefore plain cmd and dotnet; every other step runs on it
rem and says so when it is not there yet.
rem
rem Start.exe is not a build product of this file: it is not downloaded, and
rem it stays through a cleanup.
rem
rem Step bodies are read by the orchestrator, not only run from the menu: it
rem cuts everything between a label and `goto MAIN` into its own batch file.
rem So a body must stand alone - no `call :LABEL`, no jumps to shared labels.
rem Nor does a body see what this header sets: every step names its PowerShell
rem in its own body.

set "DIRECT=0"
set /a EMPTY_TRIES=0
if not "%~1"=="" (
  set "RAW=%~1"
  set "DIRECT=1"
  goto DISPATCH
)

:MAIN
set /a EMPTY_TRIES+=1
rem Without a console the prompt reads nothing and the menu would redraw for
rem ever. Three empty answers in a row mean there is nobody to ask.
if !EMPTY_TRIES! GTR 3 (
  echo [ERROR] No input available - run the builder from a console, or pass a step id.
  exit /b 2
)
cls
echo ======================================================================
echo   AUDION SYNC TOOLS - BUILDER
echo ======================================================================
echo Root: %BASE_DIR%
echo.
echo [01] BUILD APP                             ^| build_app           ^| the window and its PowerShell into App\
echo.
echo [06] RCLONE                                ^| install_rclone      ^| portable rclone into Tools\rclone
echo [07] TERMINAL                              ^| install_terminal    ^| portable terminal into Tools\terminal
echo [08] CLOUDFLARED                           ^| install_cloudflared ^| tunnel client into Tunnel\Bin
echo [09] ARCHIVER AND EDITORS                  ^| install_extras      ^| PeaZip, Edit and micro into Tools
echo.
echo [10] SELF-TESTS                            ^| tests               ^| run Tests\Test-*.ps1 under App\AudionPs.exe
echo [11] VERIFY / DOCTOR                       ^| verify              ^| report what is installed and what is missing
echo.
echo [70] CLEAN CACHE                           ^| clean_cache         ^| remove the download scratch and the build caches
echo.
echo [96] OPEN Tools                            ^| open_tools          ^| explorer Tools
echo [97] OPEN logs                             ^| open_logs           ^| explorer logs
echo.
echo [00] EXIT                                  ^| exit                ^| close builder
echo.
set "RAW="
set /p RAW="Select step number or id: "

:DISPATCH
call :TRIM RAW
if not defined RAW goto MAIN
set /a EMPTY_TRIES=0
if /I "%RAW%"=="01" goto BUILD_APP
if /I "%RAW%"=="1" goto BUILD_APP
if /I "%RAW%"=="01:build_app" goto BUILD_APP
if /I "%RAW%"=="build_app" goto BUILD_APP
if /I "%RAW%"=="06" goto INSTALL_RCLONE
if /I "%RAW%"=="6" goto INSTALL_RCLONE
if /I "%RAW%"=="06:install_rclone" goto INSTALL_RCLONE
if /I "%RAW%"=="install_rclone" goto INSTALL_RCLONE
if /I "%RAW%"=="07" goto INSTALL_TERMINAL
if /I "%RAW%"=="7" goto INSTALL_TERMINAL
if /I "%RAW%"=="07:install_terminal" goto INSTALL_TERMINAL
if /I "%RAW%"=="install_terminal" goto INSTALL_TERMINAL
if /I "%RAW%"=="08" goto INSTALL_CLOUDFLARED
if /I "%RAW%"=="8" goto INSTALL_CLOUDFLARED
if /I "%RAW%"=="08:install_cloudflared" goto INSTALL_CLOUDFLARED
if /I "%RAW%"=="install_cloudflared" goto INSTALL_CLOUDFLARED
if /I "%RAW%"=="09" goto INSTALL_EXTRAS
if /I "%RAW%"=="9" goto INSTALL_EXTRAS
if /I "%RAW%"=="09:install_extras" goto INSTALL_EXTRAS
if /I "%RAW%"=="install_extras" goto INSTALL_EXTRAS
if /I "%RAW%"=="10" goto TESTS
if /I "%RAW%"=="10:tests" goto TESTS
if /I "%RAW%"=="tests" goto TESTS
if /I "%RAW%"=="11" goto VERIFY
if /I "%RAW%"=="11:verify" goto VERIFY
if /I "%RAW%"=="verify" goto VERIFY
if /I "%RAW%"=="70" goto CLEAN_CACHE
if /I "%RAW%"=="70:clean_cache" goto CLEAN_CACHE
if /I "%RAW%"=="clean_cache" goto CLEAN_CACHE
if /I "%RAW%"=="96" goto OPEN_TOOLS
if /I "%RAW%"=="96:open_tools" goto OPEN_TOOLS
if /I "%RAW%"=="open_tools" goto OPEN_TOOLS
if /I "%RAW%"=="97" goto OPEN_LOGS
if /I "%RAW%"=="97:open_logs" goto OPEN_LOGS
if /I "%RAW%"=="open_logs" goto OPEN_LOGS
if /I "%RAW%"=="00" exit /b 0
if /I "%RAW%"=="0" exit /b 0
if /I "%RAW%"=="exit" exit /b 0
echo [WARN] Unknown step: %RAW%
if "%DIRECT%"=="1" exit /b 2
pause
goto MAIN

:BUILD_APP
echo [STEP] The window and the PowerShell it carries - into App\
rem The one step without PowerShell: it makes App\AudionPs.exe, the PowerShell
rem every other step runs on. Plain dotnet: the PowerShell first, the window is
rem published over it and brings its own files on top. The new copy is put
rem together in ._runtime\app_stage and checked there; App\ is replaced only by
rem a copy that starts, so a failed build leaves the working one in place.
set "STEP_ERROR=0"
set "STAGE=%BASE_DIR%\._runtime\app_stage"
set "OLD=%BASE_DIR%\Recovery\app-old"
if not exist "%BASE_DIR%\Recovery" md "%BASE_DIR%\Recovery"
rem An interrupted earlier install can always recover without the disposable scratch.
if not exist "%BASE_DIR%\App" if exist "!OLD!" move "!OLD!" "%BASE_DIR%\App" >nul 2>nul
set "DOTNET=%ProgramFiles%\dotnet\dotnet.exe"
if not exist "!DOTNET!" set "DOTNET="
if not defined DOTNET for %%P in (dotnet.exe) do if not defined DOTNET set "DOTNET=%%~$PATH:P"
if not defined DOTNET (
  echo [ERROR] .NET SDK was not found. Install the .NET 10 SDK: https://dotnet.microsoft.com/download
  set "STEP_ERROR=1"
)
if "!STEP_ERROR!"=="0" (
  if exist "!STAGE!" rd /s /q "!STAGE!"
  "!DOTNET!" publish "%BASE_DIR%\Source\Ps\AudionPs.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:DebugType=None -o "!STAGE!" --nologo
  if errorlevel 1 (
    echo [ERROR] dotnet publish of Source\Ps failed.
    set "STEP_ERROR=1"
  )
)
if "!STEP_ERROR!"=="0" (
  rem ReadyToRun: the window and Avalonia are compiled here, once, instead of at every start.
  "!DOTNET!" publish "%BASE_DIR%\Source\AudionSyncTools.csproj" -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false -p:PublishReadyToRun=true -p:DebugType=None -o "!STAGE!" --nologo
  if errorlevel 1 (
    echo [ERROR] dotnet publish of Source failed.
    set "STEP_ERROR=1"
  )
)
if "!STEP_ERROR!"=="0" (
  for %%F in ("AudionSyncTools.exe" "AudionPs.exe" "config\i18n.json" "config\bars.json" "Modules\Microsoft.PowerShell.Management") do (
    if not exist "!STAGE!\%%~F" (
      echo [ERROR] %%~F is missing in the build.
      set "STEP_ERROR=1"
    )
  )
)
if "!STEP_ERROR!"=="0" (
  rem Native packages bring their debug symbols along: about 100 MB nobody running the program needs.
  del /s /q "!STAGE!\*.pdb" >nul 2>nul
  rem The PowerShell of the build must be alive: asked before App\ is replaced.
  "!STAGE!\AudionPs.exe" -NoLogo -NoProfile -NonInteractive -Command "exit 0" >nul 2>nul
  if errorlevel 1 (
    echo [ERROR] The built AudionPs.exe does not start.
    set "STEP_ERROR=1"
  )
)
if "!STEP_ERROR!"=="0" (
  if exist "!OLD!" rd /s /q "!OLD!"
  if exist "%BASE_DIR%\App" move "%BASE_DIR%\App" "!OLD!" >nul 2>nul
  if exist "%BASE_DIR%\App" (
    echo [ERROR] App\ is in use and was not replaced: close the program and whatever it started, then run the step again. The new copy waits in ._runtime\app_stage.
    set "STEP_ERROR=1"
  ) else (
    move "!STAGE!" "%BASE_DIR%\App" >nul 2>nul
    if exist "%BASE_DIR%\App\AudionSyncTools.exe" (
      if exist "!OLD!" rd /s /q "!OLD!" >nul 2>nul
      echo [OK] App\ is built: AudionSyncTools.exe and AudionPs.exe.
    ) else (
      rem The new copy did not move in - something still holds a file of it. A program without
      rem its App\ starts nothing, so the working copy goes back before anything is said.
      if exist "!OLD!" move "!OLD!" "%BASE_DIR%\App" >nul 2>nul
      if exist "%BASE_DIR%\App\AudionSyncTools.exe" (
        echo [ERROR] The new App\ could not be moved into place; the former one was put back. The new copy waits in ._runtime\app_stage - run the step again.
      ) else (
        echo [ERROR] The new App\ could not be moved into place and there is no App\ now. The previous copy is retained in Recovery\app-old; it is outside disposable scratch.
      )
      set "STEP_ERROR=1"
    )
  )
)
if "%DIRECT%"=="1" exit /b !STEP_ERROR!
pause
goto MAIN

:INSTALL_RCLONE
echo [STEP] Portable rclone
rem The tool steps run the same script the UPDATE button runs; the build only
rem picks the tool and switches the closing prompt off.
set "PS_EXE=%BASE_DIR%\App\AudionPs.exe"
if not exist "!PS_EXE!" (
  echo [ERROR] App\AudionPs.exe is missing: run step 01 build_app first.
  if "%DIRECT%"=="1" exit /b 1
) else (
  "!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE_DIR%\Engine\Scripts\Update-Tools.ps1" -Rclone -NoPause
)
set "STEP_ERROR=%ERRORLEVEL%"
if "%DIRECT%"=="1" exit /b %STEP_ERROR%
pause
goto MAIN

:INSTALL_TERMINAL
echo [STEP] Portable terminal and its settings from config\terminal
set "PS_EXE=%BASE_DIR%\App\AudionPs.exe"
if not exist "!PS_EXE!" (
  echo [ERROR] App\AudionPs.exe is missing: run step 01 build_app first.
  if "%DIRECT%"=="1" exit /b 1
) else (
  "!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE_DIR%\Engine\Scripts\Update-Tools.ps1" -Terminal -NoPause
)
set "STEP_ERROR=%ERRORLEVEL%"
if "%DIRECT%"=="1" exit /b %STEP_ERROR%
pause
goto MAIN

:INSTALL_CLOUDFLARED
echo [STEP] Tunnel client
rem Not Tunnel\update-cloudflared.cmd: that wrapper runs Install-TunnelClient.ps1,
rem which also writes routes into the user's ssh profile. A build only downloads.
set "PS_EXE=%BASE_DIR%\App\AudionPs.exe"
if not exist "!PS_EXE!" (
  echo [ERROR] App\AudionPs.exe is missing: run step 01 build_app first.
  if "%DIRECT%"=="1" exit /b 1
) else (
  "!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE_DIR%\Engine\Scripts\Update-Tools.ps1" -Cloudflared -NoPause
)
set "STEP_ERROR=%ERRORLEVEL%"
if "%DIRECT%"=="1" exit /b %STEP_ERROR%
pause
goto MAIN

:INSTALL_EXTRAS
echo [STEP] Archiver and editors
rem PeaZip for ALT+F5 and ALT+F9, Edit and micro for F4: Update-Tools.ps1 hands
rem them to Install-Tools.ps1, which takes only what is newer or missing.
set "PS_EXE=%BASE_DIR%\App\AudionPs.exe"
if not exist "!PS_EXE!" (
  echo [ERROR] App\AudionPs.exe is missing: run step 01 build_app first.
  if "%DIRECT%"=="1" exit /b 1
) else (
  "!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE_DIR%\Engine\Scripts\Update-Tools.ps1" -PeaZip -Edit -Micro -NoPause
)
set "STEP_ERROR=%ERRORLEVEL%"
if "%DIRECT%"=="1" exit /b %STEP_ERROR%
pause
goto MAIN

:TESTS
echo [STEP] Self-tests
rem Tests\Run-Tests.ps1 runs every Tests\Test-*.ps1 under the PowerShell that runs
rem it, a line a test; what each one printed stays in ._runtime\tests.
set "PS_EXE=%BASE_DIR%\App\AudionPs.exe"
if not exist "!PS_EXE!" (
  echo [ERROR] App\AudionPs.exe is missing: run step 01 build_app first.
  if "%DIRECT%"=="1" exit /b 1
) else (
  "!PS_EXE!" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BASE_DIR%\Tests\Run-Tests.ps1"
)
set "STEP_ERROR=%ERRORLEVEL%"
if "%DIRECT%"=="1" exit /b %STEP_ERROR%
pause
goto MAIN

:VERIFY
echo ======================================================================
echo   VERIFY / DOCTOR
echo ======================================================================
set "MISSING=0"
rem Inline on purpose: a step body travels into the orchestrator's own batch,
rem and a `call :LABEL` would look there for a label that does not exist.
for %%F in (
  "App\AudionSyncTools.exe"
  "App\AudionPs.exe"
  "Tools\rclone\rclone.exe"
  "Tools\terminal\wt.exe"
  "Tools\terminal\.portable"
  "Tools\terminal\settings\settings.json"
  "Tunnel\Bin\cloudflared.exe"
  "Tools\PeaZip\res\bin\7z\7z.exe"
  "Tools\edit\edit.exe"
  "Tools\micro\micro.exe"
  "Start.exe"
  "Engine\BackupEngine.psm1"
  "Engine\BackupRclone.psm1"
  "Engine\Scripts\Update-Tools.ps1"
  "Engine\Scripts\Install-Tools.ps1"
  "config\version.json"
  "config\mirror.sample.json"
  "config\rclone.sample.conf"
  "Tunnel\RemoteDesktop\config\targets.sample.json"
) do (
  if exist "%BASE_DIR%\%%~F" (
    echo   [ OK ] %%~F
  ) else (
    echo   [ -- ] %%~F
    set /a MISSING+=1
  )
)
echo.
rem Keys, the rclone profile and the machines live in the data folder beside the
rem program, never here: nothing about them is checked or reported by a build.
if "!MISSING!"=="0" (
  echo [OK] Everything the program carries is in place.
) else (
  echo [WARN] !MISSING! item^(s^) missing. Step 01 builds App, steps 06-09 fetch the tools.
)
if "%DIRECT%"=="1" exit /b 0
pause
goto MAIN

:CLEAN_CACHE
echo [STEP] Download scratch and build caches
rem What a build leaves behind and nobody needs after it: the stages of the
rem downloads and of App, and bin and obj of the two projects. App and the tools stay.
rem tools-aside holds a file an update could not replace because a process was
rem running from it; once that process is gone the copy is dead weight. While it
rem still runs, the folder stays and the step says so.
set "REMOVED=0"
for %%D in (
  "._runtime\tools-update"
  "._runtime\tools-aside"
  "._runtime\tools_stage"
  "._runtime\app_stage"
  "._runtime\app_old"
  "Source\bin"
  "Source\obj"
  "Source\Ps\bin"
  "Source\Ps\obj"
) do (
  if exist "%BASE_DIR%\%%~D" (
    rd /s /q "%BASE_DIR%\%%~D" >nul 2>nul
    if exist "%BASE_DIR%\%%~D" (
      echo [WARN] still present, something holds it: %%~D
    ) else (
      echo [OK] %%~D removed.
      set /a REMOVED+=1
    )
  )
)
if "!REMOVED!"=="0" echo [OK] Nothing to remove.
if "%DIRECT%"=="1" exit /b 0
pause
goto MAIN

:OPEN_TOOLS
if not exist "%BASE_DIR%\Tools" mkdir "%BASE_DIR%\Tools" >nul 2>nul
start "" explorer "%BASE_DIR%\Tools"
if "%DIRECT%"=="1" exit /b 0
goto MAIN

:OPEN_LOGS
if not exist "%BASE_DIR%\logs" mkdir "%BASE_DIR%\logs" >nul 2>nul
start "" explorer "%BASE_DIR%\logs"
if "%DIRECT%"=="1" exit /b 0
goto MAIN

:TRIM
call set "TRIM_VALUE=%%%~1%%"
for /f "tokens=* delims= " %%A in ("%TRIM_VALUE%") do set "TRIM_VALUE=%%A"
if defined TRIM_VALUE (
  for /l %%A in (1,1,64) do if defined TRIM_VALUE if "!TRIM_VALUE:~-1!"==" " set "TRIM_VALUE=!TRIM_VALUE:~0,-1!"
)
set "%~1=%TRIM_VALUE%"
exit /b 0
