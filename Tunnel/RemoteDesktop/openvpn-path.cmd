@echo off
setlocal
chcp 65001 >nul
set "SCRIPT=%~dp0Start-OpenVpn.ps1"
rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -STA -ExecutionPolicy Bypass -File "%SCRIPT%" -Configure %*
exit /b %ERRORLEVEL%
