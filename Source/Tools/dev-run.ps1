# A check of the window without a mouse: closes the Debug copy of THIS project (picked by the
# full path of its exe - never by the name of the process: the owner's own copy may be open),
# builds, starts it again with a script of steps and takes a screenshot of its window.
#
#   Source\Tools\dev-run.ps1 -Shot C:\Temp\setup.png -Dev "section=setup"
#   Source\Tools\dev-run.ps1 -Reset -Dev "section=mirror;act=SyncPlanButton;idle" -Wait 40
#
# The steps are read by MainWindow.Dev.cs (Debug builds only). -Reset removes the settings of the
# Debug copy (bin\Debug\net10.0\config), so the window opens in its default size and theme.
param(
    [string]$Shot = '',
    [int]$Wait = 7,
    [int]$Width = 0,
    [int]$Height = 0,
    [switch]$NoBuild,
    [switch]$NoStart,
    [string]$Misses = '',
    [string]$Dev = '',
    # A throwaway data folder for the Debug copy: the wizards of SETUP write addresses, keys and configs.
    [string]$Data = '',
    [switch]$Reset,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$source = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $source 'bin\Debug\net10.0'
$exe = Join-Path $bin 'AudionSyncTools.exe'

$mine = @(Get-Process | Where-Object { $_.Path -eq $exe })
# A window with work in it is not closed: the owner may have pressed a button in this very copy
# (04.10.2026 - a restart took away the answer of an update he had just run). A script, a transfer
# or a wrapper started by the window is its child process; -Force closes it all the same.
if ($mine.Count -and -not $Force) {
    $ids = @($mine | ForEach-Object { $_.Id })
    $busy = @(Get-CimInstance Win32_Process | Where-Object { $ids -contains $_.ParentProcessId -and $_.Name -in 'AudionPs.exe', 'rclone.exe', 'cmd.exe' })
    if ($busy.Count) {
        'the window is at work ({0}) - not closed, nothing built' -f (($busy | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', ')
        exit 2
    }
}
foreach ($p in $mine) { [void]$p.CloseMainWindow() }
if ($mine.Count) {
    Start-Sleep -Milliseconds 1500
    Get-Process | Where-Object { $_.Path -eq $exe } | ForEach-Object { $_.Kill() }
    Start-Sleep -Milliseconds 400
}
if ($Reset) {
    Get-ChildItem (Join-Path $bin 'config') -Filter 'gui-settings.json*' -ErrorAction SilentlyContinue | Remove-Item -Force
}
if (-not $NoBuild) {
    $out = & dotnet build (Join-Path $source 'AudionSyncTools.csproj') -c Debug --nologo -v q 2>&1 | Out-String
    $bad = @($out -split "`r?`n" | Where-Object { $_ -match 'error|warning CS|warning AVLN' } |
        ForEach-Object { ($_ -replace ' \[[A-Z]:.*', '').Trim() } | Sort-Object -Unique)
    if ($bad.Count) { $bad | Select-Object -First 25; if ($out -match 'error') { exit 1 } }
    else { 'build ok' }
}
if ($NoStart) { exit 0 }

# AUDION_I18N_MISSES collects every Russian text the dictionary left untranslated (Core\Lang.cs).
if ($Misses) { $env:AUDION_I18N_MISSES = $Misses; if (Test-Path $Misses) { Remove-Item $Misses -Force } }
$env:AUDION_DEV_SCRIPT = $Dev
$env:AUDION_DEV_DATA = $Data
Start-Process -FilePath $exe
$env:AUDION_DEV_SCRIPT = $null
$env:AUDION_DEV_DATA = $null
$env:AUDION_I18N_MISSES = $null
Start-Sleep -Seconds $Wait
if ($Shot) {
    & (Join-Path $PSScriptRoot 'dev-shot.ps1') -Exe $exe -Out $Shot -Width $Width -Height $Height
}
