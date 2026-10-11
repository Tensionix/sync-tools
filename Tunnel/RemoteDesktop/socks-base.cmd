@echo off
rem Double-click wrapper: a SOCKS proxy into the home network through BASE.
rem
rem The port is carried over ssh: nothing is added to the network stack - no
rem adapter, no routes, no DNS of its own. Closing the client window drops it.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Open-Forward.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" base socks %*

exit /b %ERRORLEVEL%
