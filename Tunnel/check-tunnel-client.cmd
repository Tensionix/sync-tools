@echo off
rem Changes nothing: shows the cloudflared version, whether the keys are in place,
rem whether the cloudflared name of MAIN VPS resolves, whether the ssh routes are written, and
rem prints the Proxy command line for a Tabby profile.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Install-TunnelClient.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Check %*

set "RC=%ERRORLEVEL%"
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%
echo.
pause
exit /b %RC%
