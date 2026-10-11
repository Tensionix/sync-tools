@echo off
rem Direct LAN connection to the LAPTOP desktop - no MAIN VPS, no SECOND VPS,
rem no tunnel, no probing.
rem The address is the "lan" field of LAPTOP in config\targets.json, written by the
rem ADDRESSES button. Fastest path; it works only while both machines are in the
rem same network or while the way home is up.
rem mstsc will ask for the target machine's Windows sign-in (login + password).
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

setlocal
set "TARGETS=%~dp0config\targets.json"
rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
set "ADDR="
for /f "usebackq delims=" %%A in (`call "%PS%" -NoProfile -Command "(Get-Content -LiteralPath '%TARGETS%' -Raw -Encoding UTF8 | ConvertFrom-Json).laptop.lan"`) do set "ADDR=%%A"
if not defined ADDR (
    echo No LAN address for LAPTOP in config\targets.json - write it with the ADDRESSES button.
    pause
    exit /b 2
)
mstsc /v:%ADDR%
