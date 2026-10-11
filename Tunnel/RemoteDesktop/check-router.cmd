@echo off
rem Double-click wrapper: talk to the router over its own API and only read.
rem Shows model, firmware and the peers of the WG server.
rem
rem Nothing is changed - this is the groundwork for issuing a client config
rem automatically, and its job is to prove the router answers as expected.
rem The password is asked with a hidden prompt and never written anywhere.
rem
rem Another router: check-router.cmd -Address 192.168.2.1
rem Over KeenDNS:   check-router.cmd -Address https://name.netcraze.link
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Check-Router.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
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
