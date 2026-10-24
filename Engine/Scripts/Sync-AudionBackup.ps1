<# SYNC ALL: verified MIR for library folders; temporary rollback only. #>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string[]]$Only = @(),
    [switch]$WhatIf,
    [switch]$NoPause,
    [string]$Snapshot = ''
)
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root) {
    . (Join-Path $AppRoot 'Engine\DataRoot.ps1')
    $Root = Get-AbkDataRootPath -AppRoot $AppRoot
}
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
if (-not $WhatIf) {
    . (Join-Path $AppRoot 'Engine\StorageLayout.ps1')
    [void](Move-AbkRuntimeStorage -AppRoot $AppRoot -DataRoot $Root)
}
# Python 3.10+: `py -3` first, then python.exe on PATH. The python.exe of WindowsApps is the stub of
# the Microsoft Store - it opens the Store instead of running anything - and is skipped. Every
# candidate is asked for its version: an old one on PATH failed later, in the middle of the work.
$candidates = @()
$launcher = Get-Command py.exe -ErrorAction SilentlyContinue
if ($launcher) { $candidates += [pscustomobject]@{ Path = $launcher.Source; Prefix = @('-3') } }
foreach ($found in @(Get-Command python.exe -All -ErrorAction SilentlyContinue)) {
    if ($found.Source -match '\\WindowsApps\\') { continue }
    $candidates += [pscustomobject]@{ Path = $found.Source; Prefix = @() }
}
$python = $null
foreach ($candidate in $candidates) {
    $said = & $candidate.Path @($candidate.Prefix) -c 'import sys; print(sys.version_info >= (3, 10))' 2>$null
    if ($LASTEXITCODE -eq 0 -and [string]($said | Select-Object -Last 1) -eq 'True') { $python = $candidate; break }
}
if (-not $python) {
    throw 'Python 3.10+ is required for verified SYNC ALL (standard library only): install it, for example winget install Python.Python.3.12. The Microsoft Store stub python.exe does not count.'
}
# Git checks the mirrors and makes the checkouts; without it the engine stopped at its first clone with a bare "file not found".
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw 'Git is required for verified SYNC ALL: install Git for Windows, for example winget install Git.Git.'
}
$rclone = Find-AbkRclone -AppRoot $AppRoot
$nativeSsh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
if (-not (Test-Path -LiteralPath $nativeSsh)) { throw 'Windows OpenSSH is required.' }
$arguments = @((Join-Path $AppRoot 'Engine\library_sync.py'), '--app', $AppRoot, '--root', $Root,
    '--rclone', $rclone, '--ssh', $nativeSsh)
if ($Only.Count) { $arguments += @('--only', ($Only -join ',')) }
if ($WhatIf) { $arguments += '--what-if' }
if ($Snapshot) { $arguments += @('--snapshot', $Snapshot) }
$environment = Get-AbkRcloneEnvironment -AppRoot $AppRoot -DataRoot $Root
$environment['PYTHONIOENCODING'] = 'utf-8'
$previous = @{}
$code = 1
try {
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    & $python.Path @($python.Prefix) @arguments
    $code = $LASTEXITCODE
} finally {
    foreach ($name in $previous.Keys) {
        if ($null -eq $previous[$name]) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
        else { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
    }
}
if (-not $NoPause -and -not $env:CI) { Read-Host 'Enter - close' | Out-Null }
exit $code
