@echo off
rem Double-click wrapper: sign in to a cloud again, keeping its settings.
rem Only the token changes - the name and your own application key stay. Needed when the token
rem expired, was revoked, or the first sign-in did not finish.
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Manage-Clouds.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Reconnect %*

set "RC=%ERRORLEVEL%"

rem -NoPause: a background run has no keyboard, so the pause is skipped.
rem Without the switch it stays - a window opened by double click must not vanish.
set "NOPAUSE="
for %%A in (%*) do if /I "%%~A"=="-NoPause" set "NOPAUSE=1"
if defined NOPAUSE exit /b %RC%

echo.
pause
exit /b %RC%
