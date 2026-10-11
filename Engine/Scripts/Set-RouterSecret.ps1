<#
.SYNOPSIS
    ROUTER PASS: puts the password of a router account into the data folder and checks it at once.

.DESCRIPTION
    The password is kept portably, by the name of the router, in the data folder - not by DPAPI:
    that binding was lost at every reinstall and did not travel with the data. The file is of no
    use without access to the router itself. The value never appears on a command line or in the
    output: it comes in the variable ABK_ROUTER_PASSWORD of this process alone.

    A password without a check is a promise, not an access: after saving, the router is asked
    for its version. Whether all the routers of the owner share one password is the owner's
    choice, kept in targets.json of the data (_routers.sharedPassword): without an answer the
    password of one router is not even tried on another, and saved passwords are never rewritten.

.PARAMETER Describe
    Print as JSON what the window shows before asking: the routers that have an address, which of
    them have no saved password, and whether the question of a shared password was answered.

.PARAMETER Router
    The key of the router in targets.json: router-base, router-home, router-work.

.PARAMETER Shared
    yes - the password is the same for all routers, save it for the others too; no - each has its own.
    The answer is remembered in the data folder. Without it nothing is saved for the others.

.EXAMPLE
    $env:ABK_ROUTER_PASSWORD = '...'; .\Set-RouterSecret.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -Router router-base
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Describe,
    [string]$Router = '',
    [ValidateSet('', 'yes', 'no')][string]$Shared = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -Force -DisableNameChecking
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

# The routers there is something to talk to: those with an address written.
$targetsFile = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $data
$targets = $null
if (Test-Path -LiteralPath $targetsFile) { try { $targets = Get-Content -LiteralPath $targetsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
$routers = @()
foreach ($item in @(
    @{ Key = 'router-base'; Label = 'ROUTER-BASE'; Note = 'the router of BASE' }
    @{ Key = 'router-home'; Label = 'ROUTER-HOME'; Note = 'the router of HOME: seen through SECOND VPS' }
    @{ Key = 'router-work'; Label = 'ROUTER-WORK'; Note = 'the router at work' }
)) {
    $entry = $(if ($targets) { $targets.($item.Key) } else { $null })
    if (-not $entry) { continue }
    $address = [string]$(if ($entry.lan) { $entry.lan } else { $entry.host })
    if (-not $address) { continue }
    $routers += [ordered]@{ key = $item.Key; label = $item.Label; note = $item.Note; address = $address
                            saved = [bool](Get-RouterSecret -Router $item.Key -Root $data) }
}

if ($Describe) {
    [ordered]@{ routers = @($routers); shared = (Get-RouterPasswordShared -Root $data) } | ConvertTo-Json -Compress -Depth 4
    exit 0
}

$chosen = @($routers | Where-Object { $_.key -eq $Router })[0]
if (-not $chosen) { Write-Host ('[router] no such router with an address: {0} - write its address with ADDRESSES' -f $Router); exit 1 }
if (-not $env:ABK_ROUTER_PASSWORD) { Write-Host '[router] empty - nothing is saved'; exit 1 }
$password = ConvertTo-SecureString $env:ABK_ROUTER_PASSWORD -AsPlainText -Force
$env:ABK_ROUTER_PASSWORD = $null

$kept = $null
try {
    $kept = Save-RouterSecret -Router $chosen.key -Password $password -Root $data
    $session = Connect-Router -Address $chosen.address -Password $password
    $version = Invoke-Rci -Session $session -Path 'show/version'
    Disconnect-Router -Session $session

    Write-Host ('saved: ' + $kept)
    Write-Host ('the router answers: {0}, firmware {1}' -f $version.device, $version.title)

    if ($Shared) { Set-RouterPasswordShared -Shared ($Shared -eq 'yes') -Root $data }
    if ((Get-RouterPasswordShared -Root $data) -eq $true) {
        foreach ($other in @($routers | Where-Object { $_.key -ne $chosen.key -and -not $_.saved })) {
            $null = Save-RouterSecret -Router $other.key -Password $password -Root $data
            Write-Host ('the same password is saved for {0}: the routers share one password' -f $other.label)
        }
    }
    exit 0
} catch {
    Write-Host ('[router] did not work: ' + $_.Exception.Message.Split([Environment]::NewLine)[0])
    if ($kept) { Write-Host '[router] the password is saved, but the sign-in failed - check it or the address' }
    else { Write-Host '[router] the password is not saved - enter it once more' }
    exit 1
}
