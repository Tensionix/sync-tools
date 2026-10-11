@echo off
rem Snapshot of the private Build-stack archives into r2:audion-backup/Projects.
rem
rem The archive root is where _archives_private_full and _archives_private_git
rem live - the folder the orchestrator builds into.
rem
rem   backup.cmd -ArchiveRoot "E:\Releases"           - plan only, writes nothing
rem   backup.cmd -ArchiveRoot "E:\Releases" -Publish  - upload and rotate
rem   backup.cmd -ArchiveRoot "E:\Releases" -ProjectName "Audion TC" -Publish
rem
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Backup-AudionArchives.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"

rem The script honours -NoPause, and so must the wrapper: a background run has
rem no keyboard, and a pause here kept a finished backup alive for an hour.
rem Without the switch the pause stays - an early refusal exits the script
rem without waiting, and a window opened by double click would just vanish.
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%

echo.
pause
exit /b %RC%
