@echo off
rem Double-click wrapper: raise the tunnel from THIS machine to the home router.
rem While it is up, the home network is visible as if the machine stood at home -
rem the desktop and the files of BASE are reached by their home addresses.
rem
rem First run needs a config file issued by the router itself: in the router,
rem WG server -> add a user -> download its .conf. Put it in Downloads
rem and just run this, or pass the path:
rem     setup-base-vpn.cmd -From "C:\path\to\wg-laptop.conf"
rem
rem -Check looks without changing anything, -Remove takes the tunnel down.
rem The script asks for administrator rights (UAC) on its own.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0Setup-BaseVpn.ps1"

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
