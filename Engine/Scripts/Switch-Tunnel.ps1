<#
.SYNOPSIS
    WG BASE-ROUTER: switches the tunnel to the router of BASE on or off.

.DESCRIPTION
    The power button of the tunnel. Before it is raised, the networks the tunnel would take are
    compared with the network this machine stands in: at home the tunnel is not needed - the
    addresses are beside anyway - and in a network of somebody else it would take these addresses
    away from it. A clash stops the raising; -Force raises it all the same.

.PARAMETER Force
    Raise the tunnel in spite of a clash of networks: the owner knows what he wants.

.EXAMPLE
    .\Switch-Tunnel.ps1 -Root "E:\TOOLS\Audion Backup Laptop"
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The switch of the tunnel service.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

$service = Get-AbkVpnService
if (-not $service) { Write-Host '[tunnel] nothing to switch on - the tunnel is not set up'; exit 1 }

$was = Get-AbkTunnelPower -Service $service
# The name of the service is known even where it was never installed: there is nothing to switch then.
if ($was -eq 'none') { Write-Host '[tunnel] nothing to switch on - the service of the tunnel is not installed: WG BASE-ROUTER raises it'; exit 1 }
$conf = Join-Path $data 'Tunnel\WG\router-base-wg.conf'
$routes = Join-Path $AppRoot 'Engine\Routes.ps1'
if ($was -ne 'on' -and (Test-Path -LiteralPath $routes)) {
    . $routes
    $clash = @(Test-AbkTunnelClash -ConfPath $conf)
    if ($clash.Count) {
        Write-Host '[tunnel] it would cover addresses of the network this machine stands in:'
        foreach ($c in $clash) { Write-Host ('  {0} -> already in the network {1} ({2})' -f $c.Wanted, $c.Local, $c.Alias) }
        if (-not $Force) {
            Write-Host '[tunnel] at home this means it is not needed - the addresses are beside anyway'
            Write-Host '[tunnel] in a network of somebody else - that it would take these addresses away from it'
            Write-Host '[tunnel] to raise it all the same: press the button with Ctrl'
            exit 1
        }
        Write-Host '[tunnel] raising it by your decision'
    }
}

$result = Switch-AbkTunnel -Service $service
if ($result.Ok) {
    Write-Host ('was: {0}, now: {1}' -f $was, $result.State)
    exit 0
}
Write-Host ('did not work: {0}' -f $result.Why)
Write-Host ('the state stayed: {0}' -f $result.State)
exit 1
