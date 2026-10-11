@echo off
rem Double-click wrapper: refresh the terminal that travels with this program.
rem Downloads the current build, unpacks it and puts it in place of the old one.
rem Settings and keys are untouched; the previous copy is kept aside until the
rem new one proves it starts.
rem
rem     update-terminal.cmd -Check    show versions, download nothing
rem Comments are ASCII on purpose - cmd reads .cmd files in the OEM codepage
rem and chokes on UTF-8 text before chcp has a chance to run.

chcp 65001 >nul
setlocal

set "SCRIPT=%~dp0..\Engine\Scripts\Update-Tools.ps1"

rem The PowerShell the program carries: no PowerShell of the system takes part.
set "PS=%~dp0..\App\AudionPs.exe"
if not exist "%PS%" (
    echo [ERROR] App\AudionPs.exe is missing. Unpack the program whole, or build it: builder_main.cmd build_app
    exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Terminal %*

exit /b %ERRORLEVEL%
