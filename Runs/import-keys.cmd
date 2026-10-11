@echo off
rem Puts the keys from Export Keys into the places Windows programs read them from:
rem   ssh keys    -> %USERPROFILE%\.ssh
rem   R2 keys     -> the selected machine data's config\rclone
rem   Forgejo key -> core.sshCommand of the mirrored repositories
rem
rem Source: <data>\Tunnel\Export when it holds keys, otherwise <data>\Tunnel\SSH.
rem Auto supplements missing server pairs from <data>\Tunnel\SSH\servers.
rem
rem   import-keys.cmd                  - put what is missing into place
rem   import-keys.cmd -Check           - show the layout, change nothing
rem   import-keys.cmd -Force           - overwrite what is already there
rem   import-keys.cmd -Source Store    - take the Tunnel folder (golden copy), ignore Export
rem
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Import-AudionKeys.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"

rem -NoPause: a background run has no keyboard, so the pause is skipped.
rem Without the switch it stays - a window opened by double click must not vanish.
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%

echo.
pause
exit /b %RC%
