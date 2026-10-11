@echo off
rem Double-click wrapper: open the disks plugged into the router itself.
rem This is NOT the files of a computer - it is the router's own storage. The
rem router has no desktop, so there is no connect- wrapper for it.
rem
rem Port 22 on the router is always open - that is its SSH console. File
rem transfer over that same port appears only once the "SFTP server" switch is
rem turned on in the router settings. Login is the router's own admin account.
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
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" router %*

set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
    echo.
    pause
)
exit /b %RC%
