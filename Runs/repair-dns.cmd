@echo off
rem Double-click wrapper: bring name resolution back on this machine.
rem Looks first: which DNS the adapters use, who listens on port 53, whether a
rem name resolves. Then acts on what it found - starts the local resolver
rem service if it is down, or hands the adapters back to the router if no
rem resolver is installed at all. Tunnel adapters are left alone.
rem
rem     repair-dns.cmd -Check    look only, change nothing
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Repair-Dns.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*

exit /b %ERRORLEVEL%
