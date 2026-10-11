@echo off
rem Collect host keys in the selected machine data. Does not edit the SSH profile.
chcp 65001 >nul
setlocal
set "SCRIPT=%~dp0..\Engine\Scripts\Update-SshHosts.ps1"
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
