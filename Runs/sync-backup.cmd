@echo off
rem Updates the local mirrors of MAIN VPS in the data folder.
rem
rem   sync-backup.cmd                       - update everything
rem   sync-backup.cmd -WhatIf               - show the plan, write nothing
rem   sync-backup.cmd -Only "Forgejo Mirror" - only the named folders
rem   sync-backup.cmd -Root "S:\TOOLS\Audion Backup" - other data folder
rem
rem See Engine\Scripts\Sync-AudionBackup.ps1 for what comes from where.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Sync-AudionBackup.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
