<#
.SYNOPSIS
    ADDRESSES: writes the addresses of the machines into targets.json of the data folder.

.DESCRIPTION
    What the ADDRESSES button of SETUP does once its table is filled in. The answers come as a
    JSON file (the window writes it, this script reads it and removes it):

        { "rows":   { "base": { "label": "BASE", "address": "192.168.10.50", "user": "user", "port": "22" }, ... },
          "second": { "sshHost": "second-vps", "sshHostCf": "second-vps-cf", "key": "second_vps_ed25519" },
          "server": { "cloudflaredHost": "<the name cloudflared goes to MAIN VPS by>" } }

    A row without an address is left alone: nobody goes to that machine. Every address written is
    knocked at once - a silent port is told, it is not an error of the writing. The names of
    SECOND VPS go after the addresses, and the routes of ~\.ssh\config are looked at: an address
    in targets.json is not yet a route.

    Only the named values of targets.json change; its order and its comments stay.

.PARAMETER Root
    The data folder of this machine.

.PARAMETER AnswerFile
    The JSON file with the answers. Removed once read.

.EXAMPLE
    .\Set-Targets.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -AnswerFile C:\Temp\answers.json
#>
[CmdletBinding()]
param(
    [string]$Root,
    [Parameter(Mandatory)][string]$AnswerFile
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The functions that edit targets.json.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
# The module keeps what it dot-sources to itself: the same files are read here for this script.
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\Targets.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

$answer = Get-Content -LiteralPath $AnswerFile -Raw -Encoding UTF8 | ConvertFrom-Json
Remove-Item -LiteralPath $AnswerFile -Force -ErrorAction SilentlyContinue

$file = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $data

function Test-Port([string]$Address, [int]$Port) {
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($Address, $Port)
        $ok = $task.Wait(2000) -and $client.Connected
        $client.Close()
        return $ok
    } catch { return $false }
}

$written = 0
$silent = @()
$secondAddress = ''
foreach ($row in @($answer.rows.PSObject.Properties)) {
    $name = $row.Name
    $address = ([string]$row.Value.address).Trim()
    if (-not $address) { continue }
    $label = $(if ($row.Value.label) { [string]$row.Value.label } else { $name })

    $port = 22
    [void][int]::TryParse([string]$row.Value.port, [ref]$port)
    if ($port -le 0 -or $port -gt 65535) { $port = 22 }

    # SECOND VPS has no home address: its address is "host".
    $slot = $(if ($name -eq 'second') { 'host' } else { 'lan' })
    if ($name -eq 'second') { $secondAddress = $address }
    if (Set-AbkTargetEntry -Path $file -Key $name -Address $address -Port $port -User ([string]$row.Value.user) -Field $slot) {
        Write-Host ('{0}: written {1}:{2}' -f $label, $address, $port)
        $written++
    } elseif (-not (Test-Path -LiteralPath $file)) {
        # A value that did not change is no trouble - only a missing file is.
        Write-Host ('[addresses] no file {0} - and no sample beside it' -f $file)
    }

    if (Test-Port -Address $address -Port $port) { Write-Host ('{0}: the port answers' -f $label) }
    else { $silent += $label }
}

if ($silent.Count) {
    Write-Host ('silent now: {0}' -f ($silent -join ', '))
    Write-Host 'this is not an error of the writing: the machine may be off, or behind a tunnel that is not up'
}

$namesWritten = $false
if ($answer.second) {
    $names = [ordered]@{
        SshHost   = [string]$answer.second.sshHost
        SshHostCf = [string]$answer.second.sshHostCf
        Key       = [string]$answer.second.key
    }
    $rejected = @()
    foreach ($field in @($names.Keys)) {
        if ($names[$field] -and $names[$field] -notmatch '^[A-Za-z0-9._-]+$') {
            $rejected += $names[$field]
            $names[$field] = ''
        }
    }
    if ($rejected.Count) { Write-Host ('SECOND VPS: names with spaces and signs are not written: {0}' -f ($rejected -join ', ')) }
    $namesWritten = Set-AbkSecondVpsNames -Path $file -SshHost $names.SshHost -SshHostCf $names.SshHostCf -Key $names.Key
    if ($namesWritten) { Write-Host 'SECOND VPS: the names are written into targets.json' }
}

# The name cloudflared goes to MAIN VPS by: an address of the household, so the program holds none.
$cloudWritten = $false
if ($answer.server -and [string]$answer.server.cloudflaredHost) {
    $cloudName = ([string]$answer.server.cloudflaredHost).Trim()
    if ($cloudName -notmatch '^[A-Za-z0-9.-]+$') {
        Write-Host ('MAIN VPS: a name with spaces and signs is not written: {0}' -f $cloudName)
    } elseif (Set-AbkMainVpsCloudflared -Path $file -Value $cloudName) {
        Write-Host 'MAIN VPS: the name for cloudflared is written into targets.json'
        $cloudWritten = $true
    }
}

if ($written -or $namesWritten -or $cloudWritten) {
    Write-Host 'next: SSH-KEYSCAN - collect the host keys, then RCLONE.CONF - build the config'
}

# SECOND VPS is written into targets.json, and ssh goes to it by a name of ~\.ssh\config. The
# tunnel client writes that name there; without that step the address is written and there is
# no route. So what is missing is said at once.
if ($secondAddress -or $namesWritten) {
    $secondVps = Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $data
    $described = @(Read-AbkSshConfig | Where-Object { $_.Names -contains $secondVps.SshHost })
    if (-not (Test-AbkSshHost -Name $secondVps.SshHost)) {
        Write-Host ('SECOND VPS: the name {0} is not in ~\.ssh\config yet - press INSTALL in SETUP, the tunnel client writes it from targets.json' -f $secondVps.SshHost)
    } elseif ($described.Count) {
        # A host without a Port line in ssh config means 22.
        $sshPort = $(if ([int]$described[0].Port) { [int]$described[0].Port } else { 22 })
        if ([string]$described[0].HostName -ne $secondVps.Host -or $sshPort -ne [int]$secondVps.Port) {
            if ($described[0].Managed) {
                Write-Host ('SECOND VPS: {0} has another address or port in ~\.ssh\config - INSTALL in SETUP rewrites it' -f $secondVps.SshHost)
            } else {
                Write-Host ('SECOND VPS: {0} is described in ~\.ssh\config outside the block of the tunnel client - correct the address and the port there by hand' -f $secondVps.SshHost)
            }
        }
    }
}
exit 0
