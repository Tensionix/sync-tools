<#
.SYNOPSIS
    The summary of the state the window writes into its journal, as JSON.

.DESCRIPTION
    Nothing is changed. Files of the data folder are looked at, services of this machine are
    asked, and the far end of a tunnel of ours that is up is pinged once - inside the tunnel.
    One line of JSON:

    snapshot     the latest archive of Snapshots: name, time, bytes, hours of age; null - none
    r2           the pair of keys to the R2 bucket is stored
    cloudflared  the version of Tunnel\Bin\cloudflared.exe; empty - no file, ? - it did not say
    task         the nightly task of earlier versions is still registered
    sshd         the service of sshd: none, running, or its status as Windows names it
    vpn          WG BASE-ROUTER: the name of the tunnel, whether its service is installed,
                 whether a config lies in the data folder
    clients      the tunnel clients of this machine: WG, AWG, RS AWG
    pick         the client a tunnel of ours is installed on; empty - there is none
    tunnels      every tunnel service of this machine, the ones of another VPN too - they share
                 one driver with ours, and the one that took it first decides for the rest:
                 name       the name of the tunnel
                 power      on or off, by the adapter
                 foreign    not ours: no config of it lies in the data folder
                 lost       the path of the client the service is started by, when it is gone
                 handshake  seconds since the last one; -1 - never; null - nobody could be asked
                 peer, alive, ms   the far end inside the tunnel and its answer - for a tunnel
                            of ours that is up

    The dots of the buttons are told by Get-SetupState.ps1: that one is asked after every job
    and must be quick. This one is asked at the start of the window and by its button.

.EXAMPLE
    .\Get-StateSummary.ps1 -Root "E:\TOOLS\Audion Backup Laptop"
#>
[CmdletBinding()]
param(
    [string]$Root
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The services of the tunnels, their power and their handshakes.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

function Test-Quietly([scriptblock]$Question) {
    # A line that cannot be asked says "no", it does not stop the summary.
    try { return [bool](& $Question) } catch { return $false }
}

$snapshot = $null
$archives = @(Get-ChildItem -LiteralPath (Join-Path $data 'Snapshots') -File -Filter '*.tar.gz' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
if ($archives.Count) {
    $latest = $archives[0]
    $snapshot = [ordered]@{
        name  = [string]$latest.Name
        time  = $latest.LastWriteTime.ToString('s')
        bytes = [long]$latest.Length
        hours = [int]((Get-Date) - $latest.LastWriteTime).TotalHours
    }
}

$cloudflared = ''
$client = Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'
if (Test-Path -LiteralPath $client) {
    $cloudflared = '?'
    try {
        $said = [string](@(& $client --version 2>&1)[0])
        if ($said -match 'version\s+(\S+)') { $cloudflared = $Matches[1] }
    } catch { }
}

# The task is only asked about: the program registers none. The exit code answers - the text of schtasks is localized.
$task = $false
try {
    $null = & schtasks.exe /Query /TN 'Audion Backup Sync' /FO LIST 2>&1
    $task = ($LASTEXITCODE -eq 0)
} catch { }

$sshd = 'none'
$service = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
if ($service) { $sshd = $(if ($service.Status -eq 'Running') { 'running' } else { [string]$service.Status }) }

$tunnel = [string](Get-AbkVpnService)
$confs = @(Get-ChildItem -LiteralPath (Join-Path $data 'Tunnel\WG') -Filter '*.conf' -ErrorAction SilentlyContinue)
$ready = @($confs | Where-Object { $_.BaseName -eq 'router-base-wg' -or $_.Name -like 'wg-srv_*' })

# The folders are looked into by hand: Get-Command of a program that is not there costs seconds of command discovery.
$wireguard = ''
foreach ($place in @("$env:ProgramFiles\WireGuard", "${env:ProgramFiles(x86)}\WireGuard") + @($env:PATH -split ';' | Where-Object { $_ })) {
    $path = Join-Path $place 'wireguard.exe'
    if ([System.IO.File]::Exists($path)) { $wireguard = $path; break }
}
$awg = [string](Find-AbkAwgExe)
$clients = @()
if ($wireguard) { $clients += 'WG' }
if ($awg) { $clients += $(if ($awg -match 'rsvamneziawg') { 'RS AWG' } else { 'AWG' }) }
# AmneziaWG gives way only where it must: where it is there, a tunnel of ours is installed on it.
$pick = $(if (-not $clients.Count) { '' } elseif ($awg) { $clients[-1] } else { 'WG' })

# A tunnel of ours is known by its config in the data folder.
$ours = @{}
foreach ($conf in $confs) { $ours[$conf.BaseName] = $true }

$services = @(Get-AbkTunnelServices)
$shakes = @{}
if ($services.Count) { try { $shakes = Get-AbkHandshakes } catch { } }
$cards = @()
if ($services.Count) { $cards = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) }

$tunnels = @()
foreach ($one in $services) {
    $name = $one -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    $row = [ordered]@{
        name      = [string]$name
        power     = 'off'
        foreign   = [bool](Test-AbkForeignTunnel -Name $name -Ours $ours)
        lost      = ''
        handshake = $null
        peer      = ''
        alive     = $false
        ms        = 0
    }
    # Up or down is read off the adapter, as Get-AbkTunnelPower reads it - but asked of .NET:
    # Get-NetAdapter costs seconds a tunnel, and a disabled adapter is simply not in this list.
    $card = @($cards | Where-Object { $_.Name -eq $name })
    if ($card.Count -and $card[0].OperationalStatus -eq 'Up') { $row.power = 'on' }
    if ($shakes.ContainsKey($name)) {
        $row.handshake = $(if ($null -ne $shakes[$name]) { [int]$shakes[$name] } else { -1 })
    }
    # A tunnel of another VPN is not taken apart: neither its client nor its far end is ours to ask.
    if (-not $row.foreign) {
        # The client may be gone while the service stays: then the tunnel "just does not switch on".
        $row.lost = [string](Test-AbkTunnelOrphan -Service $one)
        if ($row.power -eq 'on' -and -not $row.lost) {
            # The far end is the first address of the tunnel's own network.
            if ($card.Count) {
                $own = @($card[0].GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
                if ($own.Count) {
                    $parts = $own[0].Address.ToString().Split('.')
                    if ($parts.Count -eq 4) { $row.peer = '{0}.{1}.{2}.1' -f $parts[0], $parts[1], $parts[2] }
                }
            }
            if ($row.peer) {
                $answer = Test-AbkTunnelAlive -Peer $row.peer -Wait 700
                $row.alive = [bool]$answer.Alive
                $row.ms = [int]$answer.Ms
            }
        }
    }
    $tunnels += $row
}

[ordered]@{
    snapshot    = $snapshot
    r2          = Test-Quietly { Test-Path -LiteralPath (Get-AbkCredentialsPath -AppRoot $AppRoot -DataRoot $data) }
    cloudflared = [string]$cloudflared
    task        = [bool]$task
    sshd        = [string]$sshd
    vpn         = [ordered]@{
        name      = ($tunnel -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', '')
        installed = [bool]($tunnel -and (Get-Service -Name $tunnel -ErrorAction SilentlyContinue))
        conf      = [bool]$ready.Count
    }
    clients     = @($clients)
    pick        = [string]$pick
    tunnels     = @($tunnels)
} | ConvertTo-Json -Compress -Depth 5
exit 0
