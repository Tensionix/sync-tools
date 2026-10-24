<# One-time offline migration; no credentials, collector, server or cloud is opened. #>
[CmdletBinding()]
param([string]$Root, [switch]$IncludeProgram)
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\StorageLayout.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$moved = @(Move-AbkRuntimeStorage -AppRoot $AppRoot -DataRoot $data -IncludeProgram:$IncludeProgram)
[ordered]@{ moved = $moved.Count; verified = $true } | ConvertTo-Json -Compress
exit 0
