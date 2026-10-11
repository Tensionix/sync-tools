@echo off
rem Double-click wrapper: issue a WireGuard config for THIS machine by adding
rem a peer to the router itself - no browser, no manual download.
rem
rem The key pair is born here; the router only ever sees the public key.
rem Run it once with -WhatIf to see the commands without changing anything:
rem     new-router-peer.cmd -WhatIf
rem Another machine or router:
rem     new-router-peer.cmd -Name ROUTER 2 -Address 192.168.2.1
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0New-RouterPeer.ps1"

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
