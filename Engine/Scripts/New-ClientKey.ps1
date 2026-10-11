<#
.SYNOPSIS
    SSH-KEYGEN: the key pair of THIS machine, into the profile, into CLIENTS and into Export Keys.

.DESCRIPTION
    The private half stays on this machine. Both halves are also laid into the data folder: the
    public one into CLIENTS, from where SSH-COPY-ID hands it out, and the pair into CLIENTS and
    into Export Keys - the profile lives on the system disk and dies with a reinstall of Windows,
    the data folder lies on another partition and IMPORT KEYS brings the pair back.

    The name of the machine becomes the name of the key file and the signature in
    authorized_keys on every target: lower-case Latin letters, digits, dash and underscore only.

.PARAMETER Describe
    Print as JSON what the window shows before asking: the suggested name, the names already there.

.PARAMETER Fix
    Print as JSON how a name would be written: whether it is fit, and its fit form.

.PARAMETER Name
    The name of the machine. A name that is not fit is refused: ask with -Fix first.

.PARAMETER SshDir
    Where the profile keeps its keys. ~\.ssh by default; a test names a throwaway folder.

.EXAMPLE
    .\New-ClientKey.ps1 -Root "E:\TOOLS\Audion Backup Laptop" -Name audion-carbon
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Describe,
    [string]$Fix = '',
    [string]$Name = '',
    [string]$SshDir = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# The rules of a machine name.
Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking
# The module keeps what it dot-sources to itself: the same files are read here for this script.
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\KeyPair.ps1')

if ($Fix) {
    $fixed = ConvertTo-AbkClientName -Name $Fix
    [ordered]@{ valid = [bool](Test-AbkClientName -Name $Fix); fixed = [string]$fixed; fixedValid = [bool](Test-AbkClientName -Name $fixed) } | ConvertTo-Json -Compress
    exit 0
}

$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$store = Join-Path $data 'Tunnel\SSH\clients'

if ($Describe) {
    $known = @(Get-ChildItem -LiteralPath $store -Filter '*.pub' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
    [ordered]@{ guess = [string](Get-AbkSuggestedName); known = $known; user = $env:USERNAME; computer = $env:COMPUTERNAME } | ConvertTo-Json -Compress
    exit 0
}

$Name = $Name.Trim()
if (-not (Test-AbkClientName -Name $Name)) {
    Write-Host ('[keys] the name is not fit: {0}' -f $Name)
    Write-Host '[keys] fit are lower-case Latin letters, digits, dash and underscore'
    exit 1
}
if (-not (Test-Path -LiteralPath $data -PathType Container)) { Write-Host ('[keys] no data folder: {0}' -f $data); exit 1 }
New-Item -ItemType Directory -Path $store -Force | Out-Null

if (-not $SshDir) { $SshDir = Join-Path $HOME '.ssh' }
# The name of the file is the name of the machine itself.
$key = Join-Path $SshDir ('{0}_ed25519' -f $Name)

if (Test-Path -LiteralPath $key) {
    Write-Host ('already there: {0}' -f $key)
} else {
    New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $made = New-AbkKeyPair -Path $key -Comment $Name } finally { $ErrorActionPreference = $was }
    if (-not (Test-Path -LiteralPath $key)) {
        foreach ($line in @($made.Said)) { Write-Host ([string]$line) }
        Write-Host '[keys] the pair was not made'
        exit 1
    }
    Write-Host ('made: {0}' -f $key)
}

function Set-PrivateHalf([string]$From, [string]$To) {
    <#
        The private half laid into the data folder: read-only for its one reader, so a copy over
        it is refused. The same half already there is left as it is - a second press of the
        button said "access denied" about a key that lay in its place. Another key under the
        same name is never overwritten: it may be the only copy of a machine that still works.
    #>
    if (Test-Path -LiteralPath $To) {
        if ((Get-FileHash -LiteralPath $From).Hash -eq (Get-FileHash -LiteralPath $To).Hash) { return }
        throw ('another key is already kept under this name: {0}' -f $To)
    }
    Copy-Item -LiteralPath $From -Destination $To
    # The private half stays private here too: inheritance off, one reader.
    & icacls $To /inheritance:r /grant:r ('{0}:(R)' -f $env:USERNAME) *>$null
    # The key is in its place either way; that it is left open is said, not swallowed.
    if ($LASTEXITCODE -ne 0) { Write-Host ('[keys] icacls failed to close the private key (code {0}): {1}' -f $LASTEXITCODE, $To) }
}

# Into CLIENTS - both halves. The public one, to have what to hand out; the private one, so
# that after a reinstall of the system the machine comes back to work by a file, not by a trip.
try {
    # The private half first: when another key is kept under this name, its public half must not be replaced either.
    Set-PrivateHalf -From $key -To (Join-Path $store ($Name + '_ed25519'))
    Copy-Item -LiteralPath ($key + '.pub') -Destination (Join-Path $store ($Name + '.pub')) -Force
    Write-Host ('into CLIENTS: {0}.pub and the private key' -f $Name)
} catch {
    Write-Host ('[keys] did not get into CLIENTS: {0}' -f $_.Exception.Message)
}

# Both halves - into Export Keys, at once: this machine once had its key in a single copy for half a year.
try {
    $kit = Join-Path $data 'Tunnel\Export\SSH'
    New-Item -ItemType Directory -Path $kit -Force | Out-Null
    Set-PrivateHalf -From $key -To (Join-Path $kit ('{0}_ed25519' -f $Name))
    Copy-Item -LiteralPath ($key + '.pub') -Destination (Join-Path $kit ('{0}_ed25519.pub' -f $Name)) -Force
    Write-Host ('into Export Keys: {0}_ed25519 (it outlives a reinstall of the system)' -f $Name)
} catch {
    Write-Host ('[keys] did not get into Export Keys: {0}' -f $_.Exception.Message)
}
exit 0
