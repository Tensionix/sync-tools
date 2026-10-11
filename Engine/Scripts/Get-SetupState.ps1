<#
.SYNOPSIS
    What the dots of the SETUP and TUNNEL buttons and the power button of the tunnel show, as JSON.

.DESCRIPTION
    Nothing is changed and no network is touched: files of the data folder are looked at, services
    of this machine are asked. One line of JSON:

    r2         the pair of keys to the R2 bucket is stored
    store      the data folder holds keys: Tunnel\SSH or Tunnel\Export
    targets    BASE and LAPTOP have their addresses in targets.json
    newKey     the key of this machine lies in the profile. Which key is this machine's the
               data folder tells: its public half lies in CLIENTS and the private one beside
               it in the profile. The name the window remembers is only a hint
    keys       the profile holds a key of a machine of CLIENTS
    hosts      known_hosts of the transport is there
    transport  rclone.conf is built: no label is left in it
    router     the password of a router is stored
    archive    the folder of the private backup holds an archive
    sshd       the service of sshd: none, running, or its status as Windows names it
    wireguard, awg   the tunnel clients installed (paths; empty - none)
    vpn        WG BASE-ROUTER: the name of the tunnel, whether its service is installed, whether
               a config lies in the data folder, and its power - on, off or none

    The state of REVERSE SSH TUN is told by Get-BeaconState.ps1.

.PARAMETER ClientName
    The name of the key of this machine, as the window keeps it. May be empty: a fresh copy of
    the program has no settings yet, and pointing at the data folder must be the whole setup.

.PARAMETER ArchiveRoot
    The folder of the private backup, as the window keeps it.

.PARAMETER SshDir
    Where the profile keeps its keys. ~\.ssh by default; a test names a throwaway folder.

.EXAMPLE
    .\Get-SetupState.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -ClientName audion-carbon
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$ClientName = '',
    [string]$ArchiveRoot = '',
    [string]$SshDir = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The key of a machine and the service of the tunnel.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
if (-not $SshDir) { $SshDir = Join-Path $HOME '.ssh' }
$own = $ClientName -replace '_ed25519$', ''
# The key of this machine, by the data folder and the profile: its public half lies in CLIENTS
# and the private one beside it in the profile. The name the window remembers is only a hint -
# a fresh copy of the program has none, and pointing at the data folder must be the whole setup.
# Asked once: both dots of the keys stand on the answer.
$machineKey = ''
try { $machineKey = [string](Get-AbkMachineKey -Store (Join-Path $data 'Tunnel\SSH\clients') -SshDir $SshDir -Preferred $own) } catch { }

function Test-Quietly([scriptblock]$Question) {
    # A dot that cannot be asked is a grey dot, not a stopped script.
    try { return [bool](& $Question) } catch { return $false }
}

$targets = Test-Quietly {
    $file = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $data
    $known = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $known.base.lan -and $known.laptop.lan
}
$transport = Test-Quietly {
    $conf = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\rclone.conf' -DataRoot $data
    (Test-Path -LiteralPath $conf) -and -not ([System.IO.File]::ReadAllText($conf) -match '\{\{[A-Z_]+\}\}')
}
$router = Test-Quietly {
    Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -DisableNameChecking
    Test-RouterSecretStored -Root $data
}
$archive = Test-Quietly {
    $ArchiveRoot -and @('_archives_private_full', '_archives_private_git' | Where-Object { Test-Path -LiteralPath (Join-Path $ArchiveRoot $_) }).Count
}

$sshd = 'none'
$service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
if ($service) { $sshd = $(if ($service.Status -eq 'Running') { 'running' } else { [string]$service.Status }) }

# The folders are looked into by hand: Get-Command of a program that is not there costs seconds of command discovery.
$wireguard = ''
foreach ($place in @("$env:ProgramFiles\WireGuard", "${env:ProgramFiles(x86)}\WireGuard") + @($env:PATH -split ';' | Where-Object { $_ })) {
    $path = Join-Path $place 'wireguard.exe'
    if ([System.IO.File]::Exists($path)) { $wireguard = $path; break }
}

$tunnel = [string](Get-AbkVpnService)
$installed = [bool]($tunnel -and (Get-Service -Name $tunnel -ErrorAction SilentlyContinue))
$confs = @(Get-ChildItem -LiteralPath (Join-Path $data 'Tunnel\WG') -Filter '*.conf' -ErrorAction SilentlyContinue |
    Where-Object { $_.BaseName -eq 'router-base-wg' -or $_.Name -like 'wg-srv_*' })
# The adapter is asked for only where the service stands: the question costs seconds.
$power = $(if ($installed) { [string](Get-AbkTunnelPower -Service $tunnel) } else { 'none' })

[ordered]@{
    r2        = Test-Quietly { Test-Path -LiteralPath (Get-AbkCredentialsPath -AppRoot $AppRoot -DataRoot $data) }
    store     = [bool]((Test-Path -LiteralPath (Join-Path $data 'Tunnel\SSH')) -or (Test-Path -LiteralPath (Join-Path $data 'Tunnel\Export')))
    targets   = $targets
    newKey    = [bool]$machineKey
    keys      = [bool]$machineKey
    hosts     = Test-Quietly { Test-Path -LiteralPath (Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\known_hosts' -DataRoot $data) }
    transport = $transport
    router    = $router
    archive   = $archive
    sshd      = $sshd
    wireguard = [string]$wireguard
    awg       = [string](Find-AbkAwgExe)
    vpn       = [ordered]@{
        name      = ($tunnel -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', '')
        installed = $installed
        conf      = [bool]$confs.Count
        power     = $power
    }
} | ConvertTo-Json -Compress -Depth 4
exit 0
