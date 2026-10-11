<#
.SYNOPSIS
    REVERSE SSH TUN of this machine: is it set up, does its process live, does its own ssh hold the channel.

.DESCRIPTION
    Prints the state as JSON for the SSH TUN button of SETUP. No network is touched: a knock at a
    port of MAIN VPS or SECOND VPS would hold the window; whether the port lives is said by the
    inspection (reverse-ssh-check.cmd), which opens in its own console.

    The file of the state in the data folder makes the tunnel "set up". The holder is looked for
    the way Setup-SshBeacon.ps1 does it. The channel counts only for an ssh started by that
    holder, with the forward to the port of the state and with the key of the tunnel: the number
    of a port alone proves nothing - a connection of somebody else to another host may have the
    same. New launches need the acknowledgment of the forward in the log of OpenSSH; old
    processes without SshLog are judged by their age.

.EXAMPLE
    .\Get-BeaconState.ps1 -Root "E:\TOOLS\Audion Backup Laptop"
#>
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

$name = Get-AbkLocalBeaconName -DataRoot $data
$dir = Join-Path $data 'Tunnel\SSH\beacon'
$info = [ordered]@{
    name     = $name
    key      = [bool](Test-Path -LiteralPath (Join-Path $dir ('{0}_beacon_ed25519' -f $name)))
    made     = $false
    port     = 0
    via      = ''
    vps      = ''
    holder   = $false
    starting = $false
    alive    = $false
}
function Out-State { $info | ConvertTo-Json -Compress; exit 0 }

$file = Join-Path $dir ('{0}.beacon.json' -f $name)
if (-not (Test-Path -LiteralPath $file)) { Out-State }
try { $saved = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { Out-State }

$info.made = $true
$info.port = [int]$saved.Port
$info.via = [string]$saved.Via
# Which VPS the name of the host stands for: the window writes it on the button.
try {
    . (Join-Path $AppRoot 'Engine\Targets.ps1')
    $second = Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $data
    if (@($second.SshHost, $second.SshHostCf, 'second-vps', 'second-vps-cf') -contains $info.via) { $info.vps = 'SECOND VPS' }
    elseif ($info.via -like 'audion-vps*') { $info.vps = 'MAIN VPS' }
} catch { }

# The processes are asked for only when the tunnel is set up.
$holders = @(Get-AbkBeaconRuntimeProcesses -Name $name -DataRoot $data)
$info.holder = [bool]$holders.Count
if (-not $holders.Count -or -not $info.port) { Out-State }

$ids = @($holders | ForEach-Object { [int]$_.ProcessId })
$forward = '"?-R"?\s+"?127\.0\.0\.1:{0}:127\.0\.0\.1:22"?(\s|$)' -f $info.port
$keyFile = [string]$saved.KeyFile
$own = @(Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        ($ids -contains [int]$_.ParentProcessId) -and $_.CommandLine -and
        $_.CommandLine -match $forward -and
        ((-not $keyFile) -or $_.CommandLine.IndexOf($keyFile, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
if (-not $own.Count) { Out-State }

if ($saved.PSObject.Properties['SshLog']) {
    # A running ssh can still be in the handshake. OpenSSH's own acknowledgment proves the server accepted the forward.
    $expectedLog = Join-Path $AppRoot ('logs\ssh-beacon-' + $name + '-ssh.log')
    $info.starting = $true
    if ($saved.SshLog -eq $expectedLog -and (Test-Path -LiteralPath $expectedLog)) {
        $detail = Read-AbkBeaconSshLog -Path $expectedLog -Head
        if ($detail.Contains('remote forward success for: listen 127.0.0.1:' + $info.port + ',')) {
            $info.alive = $true; $info.starting = $false
        }
    }
    Out-State
}
$born = $own[0].CreationDate
$age = $(if ($born) { ((Get-Date) - $born).TotalSeconds } else { 0 })
if ($age -ge 20) { $info.alive = $true } else { $info.starting = $true }
Out-State
