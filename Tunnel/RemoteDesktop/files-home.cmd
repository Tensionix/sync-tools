@echo off
rem Double-click wrapper: open the files of the HOME machine over SFTP.
rem The script picks the path itself - straight to the machine when it answers
rem (at home, or while travelling with setup-home-vpn.cmd up), otherwise through
rem the SECOND VPS entry point. Turn the receiving side on once with
rem setup-ssh-server.cmd run on the HOME machine.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Connect-Files.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" home %*

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    pause
)
exit /b %RC%
