#requires -Version 5.1
[CmdletBinding()]
# -NoPause - ключ враппера из Runs: паузу держит он; здесь ключ только принимается.
param([string]$Root, [switch]$Force, [ValidateRange(1,30)][int]$TimeoutSeconds=5, [switch]$NoPause)
$ErrorActionPreference='Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\SshHosts.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$targetsPath = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $data -Rel 'Tunnel\RemoteDesktop\config\targets.json'
$knownPath = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $data -Rel 'config\rclone\known_hosts'
Initialize-AbkHostScanLifetime
$targets = [IO.File]::ReadAllText($targetsPath) | ConvertFrom-Json
$result = Update-AbkHostKeys -Targets $targets -Path $knownPath -Force:$Force -TimeoutSeconds $TimeoutSeconds
if ($result.Fresh -eq 0 -and $result.Held -eq 0) { exit 1 }
. (Join-Path $AppRoot 'Engine\SshProfile.ps1')
$null = Update-AbkSshProfileTrust -DataRoot $data -SshConfig (Join-Path $HOME '.ssh\config')
