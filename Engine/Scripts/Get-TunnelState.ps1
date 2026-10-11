<#
.SYNOPSIS
    The state of the tunnels of this machine, as JSON: what the TUNNEL buttons show before they ask.

.DESCRIPTION
    Nothing is changed here. One of three questions is answered:

    -Clients   which tunnel clients are installed: WireGuard, AmneziaWG. There is one driver in the
               system, and the client that took it first decides for the rest.
    -Tunnel    WG BASE-ROUTER: the service and its state, the address inside the tunnel, the config
               in the data folder, the last handshake, whether the far end answers, the networks
               the tunnel carries (Tunnel\WG\routes.txt) and the addresses of this machine.
    -Peers     who is registered on the WG server of a router and which address is free. The router
               is asked with the password kept in the data folder; without it, or without an
               answer, "answered" is false.

.EXAMPLE
    .\Get-TunnelState.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -Tunnel
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Clients,
    [switch]$Tunnel,
    [switch]$Peers,
    [string]$Router = 'router-base',
    [string]$Address = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The search of the clients and of the service of the tunnel.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

function Get-LocalAddresses {
    <# The IPv4 addresses of this machine with their masks. Asked of .NET: Get-NetIPAddress loads CIM for two seconds. #>
    $out = @()
    foreach ($card in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($card.OperationalStatus -ne 'Up') { continue }
        foreach ($one in $card.GetIPProperties().UnicastAddresses) {
            if ($one.Address.AddressFamily -ne 'InterNetwork') { continue }
            $out += [pscustomobject]@{ IPAddress = $one.Address.ToString(); PrefixLength = [int]$one.PrefixLength }
        }
    }
    return $out
}

if ($Clients) {
    # The folders are looked into by hand: Get-Command of a program that is not there costs seconds of command discovery.
    $wireguard = ''
    $places = @("$env:ProgramFiles\WireGuard", "${env:ProgramFiles(x86)}\WireGuard") + @($env:PATH -split ';' | Where-Object { $_ })
    foreach ($place in $places) {
        $path = Join-Path $place 'wireguard.exe'
        if ([System.IO.File]::Exists($path)) { $wireguard = $path; break }
    }
    [ordered]@{ wireguard = [string]$wireguard; awg = [string](Find-AbkAwgExe) } | ConvertTo-Json -Compress
    exit 0
}

if ($Tunnel) {
    $service = Get-AbkVpnService
    $short = $service -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    $live = Get-Service -Name $service -ErrorAction SilentlyContinue
    $addresses = @(Get-LocalAddresses)
    $inside = @($addresses | Where-Object { $_.IPAddress -like '172.16.*' })
    $confDir = Join-Path $data 'Tunnel\WG'
    $ready = @(Get-ChildItem -LiteralPath $confDir -Filter '*.conf' -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq 'router-base-wg' -or $_.Name -like 'wg-srv_*' })

    $state = [ordered]@{
        service   = [string]$service
        name      = [string]$short
        status    = $(if ($live) { [string]$live.Status } else { '' })
        inside    = $(if ($inside) { [string]$inside[0].IPAddress } else { '' })
        conf      = $(if ($ready) { [string]$ready[0].Name } else { '' })
        handshake = $false
        seconds   = -1
        peer      = ''
        alive     = $false
        ms        = 0
        routes    = @()
        local     = @()
    }
    $shakes = Get-AbkHandshakes
    if ($shakes.ContainsKey($short)) {
        $state.handshake = $true
        # -1: the tunnel is known but the ends never shook hands.
        $state.seconds = $(if ($null -ne $shakes[$short]) { [int]$shakes[$short] } else { -1 })
    }
    # The far end is the first address of the tunnel's own network. Read from what .NET already told: Get-AbkTunnelPeer asks CIM, seconds for one address.
    $peer = ''
    $card = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.Name -eq $short } | Select-Object -First 1
    if ($card) {
        $own = @($card.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' })
        if ($own.Count) {
            $parts = $own[0].Address.ToString().Split('.')
            if ($parts.Count -eq 4) { $peer = '{0}.{1}.{2}.1' -f $parts[0], $parts[1], $parts[2] }
        }
    }
    if ($peer) {
        $answer = Test-AbkTunnelAlive -Peer $peer -Wait 700
        $state.peer = [string]$peer
        $state.alive = [bool]$answer.Alive
        $state.ms = [int]$answer.Ms
    }

    # What the tunnel carries: a network a line; everything else goes past it.
    $routes = @()
    $routesFile = Join-Path $confDir 'routes.txt'
    if (Test-Path -LiteralPath $routesFile) {
        foreach ($line in (Get-Content -LiteralPath $routesFile)) {
            foreach ($net in (($line -split '#')[0] -split '[\s,;]+')) { if ($net.Trim()) { $routes += $net.Trim() } }
        }
    }
    if (-not $routes.Count) { $routes = @('192.168.10.0/24') }
    $state.routes = @($routes)
    $state.local = @($addresses |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -notlike '172.16.6.*' } |
        ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
    $state | ConvertTo-Json -Compress -Depth 4
    exit 0
}

if ($Peers) {
    $out = [ordered]@{ answered = $false; busy = [ordered]@{}; free = ''; server = '' }
    function Out-Peers { $out | ConvertTo-Json -Compress -Depth 4; exit 0 }
    $conf = $null
    try {
        Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -Force -DisableNameChecking
        $password = Get-RouterSecret -Router $Router -Root $data
        if (-not $password -or -not $Address) { Out-Peers }
        $session = Connect-Router -Address $Address -Password $password
        try { $conf = Invoke-Rci -Session $session -Path 'show/running-config' }
        finally { Disconnect-Router -Session $session }
    } catch { Out-Peers }
    $text = $(if ($conf -is [string]) { $conf } else { ($conf.message -join [Environment]::NewLine) })
    if (-not $text) { Out-Peers }

    # The block of the WG server: the interface with a listen-port; every peer is a name and an address of one host.
    $inside = $false; $server = $false; $name = ''; $rows = [ordered]@{}; $subnet = ''
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*interface\s+Wireguard') { $inside = $true; $server = $false; $name = ''; $rows = [ordered]@{}; $subnet = ''; continue }
        if ($line -match '^\s*interface\s+') { $inside = $false; continue }
        if (-not $inside) { continue }
        if ($line -match '^\s*wireguard\s+listen-port') { $server = $true; continue }
        if ($line -match '^\s*ip\s+address\s+(\d{1,3}(?:\.\d{1,3}){3})') { $subnet = $Matches[1]; continue }
        if ($line -match '^\s*wireguard\s+peer\s+\S+\s+!(.+?)\s*$') { $name = $Matches[1].Trim(); continue }
        if ($line -match '^\s*allow-ips\s+(\d{1,3}(?:\.\d{1,3}){3})\s+255\.255\.255\.255') {
            $rows[$Matches[1]] = $(if ($name) { $name } else { '?' })
            $name = ''
            continue
        }
        if ($line -match '^!' -and $server -and $rows.Count) { $out.answered = $true; $out.busy = $rows; $out.server = $subnet }
    }
    if ($server -and $rows.Count -and -not $out.answered) { $out.answered = $true; $out.busy = $rows; $out.server = $subnet }
    if ($out.answered -and $out.server -match '^(\d{1,3}(?:\.\d{1,3}){2})\.\d{1,3}$') {
        $head = $Matches[1] + '.'
        for ($last = 2; $last -le 254; $last++) {
            $try = $head + $last
            if ($try -eq $out.server) { continue }
            if (-not $out.busy.Contains($try)) { $out.free = $try; break }
        }
    }
    Out-Peers
}

Write-Host 'name one question: -Clients, -Tunnel or -Peers'
exit 1
