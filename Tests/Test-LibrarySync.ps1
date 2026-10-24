# Real local Git/tar/filesystem fixtures; never contacts a server or R2.
param([string]$AppRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$python = Get-Command py.exe -ErrorAction SilentlyContinue
$prefix = @('-3')
if (-not $python) { $python = Get-Command python.exe -ErrorAction SilentlyContinue; $prefix = @() }
if (-not $python) { throw 'Python 3.10+ required for library tests.' }
& $python.Source @prefix (Join-Path $AppRoot 'Tests\test_library_sync.py')
exit $LASTEXITCODE
