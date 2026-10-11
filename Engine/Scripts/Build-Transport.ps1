<#
.SYNOPSIS
    RCLONE.CONF: builds the working rclone.conf of the data folder from config\rclone.sample.conf.

.DESCRIPTION
    Addresses and accounts are taken from targets.json, the keys from CLIENTS and from the
    profile, the paths are the program's own. The one thing to ask is the identifier of the
    Cloudflare account - the one in the address of the bucket - and the profile of r2.credentials.

    A label nothing was found for stays a label in the file and is named aloud. The names of
    SECOND VPS are put in only when ssh knows them; an unknown name does not wipe a working
    section - its line is kept from the previous file. After the build three remotes are read:
    a config without a connection is a text, not a transport.

.PARAMETER Describe
    Print as JSON what the window shows before asking: what the file holds now and what it will be built from.

.PARAMETER Account
    The identifier of the Cloudflare account.

.PARAMETER Profile
    The profile of r2.credentials; audion_r2 when empty.

.PARAMETER ClientName
    The name of this machine, as a hint for finding its key.

.EXAMPLE
    .\Build-Transport.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -Account 0123abcd -Profile audion_r2
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Describe,
    [string]$Account = '',
    [string]$Profile = '',
    [string]$ClientName = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The builder of the transport and the search of the machine key.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
# The module keeps what it dot-sources to itself: the same files are read here for this script.
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\Targets.ps1')
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

$template = Join-Path $AppRoot 'config\rclone.sample.conf'
$path = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\rclone.conf' -DataRoot $data
$targetsFile = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $data
$targets = $null
if (Test-Path -LiteralPath $targetsFile) { try { $targets = Get-Content -LiteralPath $targetsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

# What the working file holds now is a good hint.
$accountNow = ''
$profileNow = 'audion_r2'
if (Test-Path -LiteralPath $path) {
    $current = [System.IO.File]::ReadAllText($path)
    if ($current -match 'https://([a-z0-9]+)\.r2\.cloudflarestorage\.com') { $accountNow = $Matches[1] }
    if ($current -match '(?m)^\s*profile\s*=\s*(\S+)') { $profileNow = $Matches[1] }
}

$keys = Join-Path $HOME '.ssh'
# Empty, not the name of a key of the old scheme: a path to a file that is not there would give
# a transport with silent panels. An unfilled label, on the contrary, is named aloud.
$machineKey = ''
$serverKey = '~/.ssh/audion_vps_root_ed25519'
$own = Get-AbkMachineKey -Store (Join-Path $data 'Tunnel\SSH\clients') -SshDir $keys -Preferred $ClientName
foreach ($name in @($own)) {
    if ($name -and (Test-Path -LiteralPath (Join-Path $keys $name))) { $machineKey = '~/.ssh/' + $name; break }
}
foreach ($name in @('audion_vps_root_ed25519', 'audion_vps_audion_ed25519')) {
    if (Test-Path -LiteralPath (Join-Path $keys $name)) { $serverKey = '~/.ssh/' + $name; break }
}

if ($Describe) {
    [ordered]@{
        template   = [bool](Test-Path -LiteralPath $template)
        targets    = [bool]$targets
        account    = $accountNow
        profile    = $profileNow
        base       = [string]$targets.base.lan
        laptop     = [string]$targets.laptop.lan
        server     = [string]$targets.server.host
        machineKey = $machineKey
        serverKey  = $serverKey
    } | ConvertTo-Json -Compress
    exit 0
}

if (-not (Test-Path -LiteralPath $template)) { Write-Host ('[window] no file: {0}' -f $template); exit 1 }
if (-not $targets) { Write-Host ('[window] no targets.json: {0}' -f $targetsFile); exit 1 }

function Port($entry) { $(if ($entry.sshPort) { [int]$entry.sshPort } else { 22 }) }

$secondVps = Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $data
# Each name is checked apart: the direct one does not vouch for the one over cloudflared.
$secondKnown = Test-AbkSshHost -Name $secondVps.SshHost
$secondCfKnown = Test-AbkSshHost -Name $secondVps.SshHostCf
$values = @{
    R2_ACCOUNT         = $Account
    R2_PROFILE         = $(if ($Profile) { $Profile } else { 'audion_r2' })
    BASE_ADDRESS       = [string]$targets.base.lan
    BASE_USER          = [string]$targets.base.user
    BASE_PORT          = (Port $targets.base)
    LAPTOP_ADDRESS     = [string]$targets.laptop.lan
    LAPTOP_USER        = [string]$targets.laptop.user
    LAPTOP_PORT        = (Port $targets.laptop)
    # The work machine is one route, straight by the address of targets.json: host when written, else lan.
    WORK_ADDRESS       = [string]$(if ($targets.work.host) { $targets.work.host } else { $targets.work.lan })
    WORK_USER          = [string]$targets.work.user
    WORK_PORT          = (Port $targets.work)
    HOME_ADDRESS       = [string]$(if ($targets.home.lan) { $targets.home.lan } else { $targets.home.host })
    HOME_USER          = [string]$targets.home.user
    HOME_PORT          = (Port $targets.home)
    DAD_ADDRESS        = [string]$(if ($targets.dad.lan) { $targets.dad.lan } else { $targets.dad.host })
    DAD_USER           = [string]$targets.dad.user
    DAD_PORT           = (Port $targets.dad)
    MACHINE_KEY        = $machineKey
    SERVER_ADDRESS     = [string]$(if ($targets.server.host) { $targets.server.host } else { $targets.server.lan })
    SERVER_USER        = [string]$targets.server.user
    SERVER_PORT        = (Port $targets.server)
    SERVER_KEY         = $serverKey
    SERVER_SSH_HOST    = [string]$targets.server.sshHost
    SECOND_SSH_HOST    = $(if ($secondKnown) { $secondVps.SshHost } else { '' })
    SECOND_SSH_HOST_CF = $(if ($secondCfKnown) { $secondVps.SshHostCf } else { '' })
    KNOWN_HOSTS        = (Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\known_hosts' -DataRoot $data) -replace '\\', '/'
}

$built = @{}
$left = @(Build-AbkTransport -Template $template -Path $path -Values $values -KeepFrom $path -Report $built)
Write-Host ('built: {0}' -f $path)
if ($left.Count) {
    Write-Host ('not filled: {0}' -f ($left -join ', '))
    Write-Host '[window] labels are left in the file - fill in the addresses and build again'
}
$keptNames = @($built['Kept'] | Where-Object { $_ })
if ($keptNames.Count) { Write-Host ('kept from the working rclone.conf: {0}' -f ($keptNames -join ', ')) }
if (-not $secondKnown) {
    Write-Host ('SECOND VPS: ssh does not know the name {0} - write the address with ADDRESSES, press INSTALL in SETUP and build again' -f $secondVps.SshHost)
}
if (-not $secondCfKnown) {
    Write-Host ('SECOND VPS: ssh does not know the name {0} over cloudflared - describe it in ~\.ssh\config beside the direct host of SECOND VPS' -f $secondVps.SshHostCf)
}

# A check by reading: a config without a connection is a text, not a transport.
foreach ($remote in @('r2:', 'base:', 'server:')) {
    $result = Invoke-AbkRcloneCommand -AppRoot $AppRoot -DataRoot $data -PassThru -Command @(
        (Find-AbkRclone -AppRoot $AppRoot),
        (Get-AbkRcloneArgs -AppRoot $AppRoot -DataRoot $data),
        'lsjson', $remote, '--max-depth', '1'
    ).ForEach({ $_ }) 2>$null
    Write-Host ('{0,-9} {1}' -f $remote, $(if ($result.ExitCode -eq 0) { 'answers' } else { 'is silent' }))
}
# Unfilled labels are named above; they are the state of the addresses, not a failure of the build.
exit 0
