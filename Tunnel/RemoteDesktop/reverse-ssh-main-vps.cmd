@echo off
rem Double-click wrapper: raise this machine REVERSE SSH TUN through MAIN VPS only.
rem MAIN VPS is abroad: slower to reach, but the traffic never lands on a host inside the country.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Setup-SshBeacon.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Server audion-vps-direct,audion-vps %*

set "RC=%ERRORLEVEL%"
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%
echo.
pause
exit /b %RC%
