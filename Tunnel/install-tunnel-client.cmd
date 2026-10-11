@echo off
rem Double-click wrapper. Arguments are passed through to the script:
rem   install-tunnel-client.cmd          - portable, cloudflared into Bin\
rem   install-tunnel-client.cmd -Winget  - install into the system via winget
rem   install-tunnel-client.cmd -Check   - check only, change nothing
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Install-TunnelClient.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

set "RC=%ERRORLEVEL%"
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%
echo.
pause
exit /b %RC%
