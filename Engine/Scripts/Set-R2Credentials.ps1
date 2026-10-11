<#
.SYNOPSIS
    R2 CREDS: lays the pair of keys of the R2 bucket where rclone looks for it and reads the buckets at once.

.DESCRIPTION
    The pair - an identifier and a secret from the Cloudflare panel (R2 - Manage API tokens) -
    is written as a file of the data folder, the one rclone reads. A key without a check is a
    promise, not an access: the list of buckets is asked for right after the writing.

    The values never appear on a command line or in the output: they come in the variables
    ABK_R2_ID and ABK_R2_SECRET of this process alone.

.PARAMETER Describe
    Print as JSON what the window shows before asking: the file, the profile, whether the file is there.

.EXAMPLE
    $env:ABK_R2_ID = '...'; $env:ABK_R2_SECRET = '...'; .\Set-R2Credentials.ps1 -Root "E:\TOOLS\Audion Backup Laptop"
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Describe
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

$path = Get-AbkCredentialsPath -AppRoot $AppRoot -DataRoot $data
# The name of the profile, not $profile: that is PowerShell's own automatic variable.
$account = 'audion_r2'
try {
    $conf = Get-Content -LiteralPath (Get-AbkWorkPath -AppRoot $AppRoot -Rel 'config\rclone\rclone.conf' -DataRoot $data) -ErrorAction Stop
    $named = $conf | Where-Object { $_ -match '^\s*profile\s*=\s*(\S+)' } | Select-Object -First 1
    if ($named -and $named -match '=\s*(\S+)') { $account = $Matches[1] }
} catch { }

if ($Describe) {
    [ordered]@{ path = $path; profile = $account; exists = [bool](Test-Path -LiteralPath $path) } | ConvertTo-Json -Compress
    exit 0
}

$id = $env:ABK_R2_ID
$secret = $env:ABK_R2_SECRET
$env:ABK_R2_ID = $null
$env:ABK_R2_SECRET = $null
if (-not $id -or -not $secret) { Write-Host '[keys] empty - nothing is written'; exit 1 }

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $body = @(
        ('[{0}]' -f $account),
        ('aws_access_key_id = {0}' -f $id),
        ('aws_secret_access_key = {0}' -f $secret)
    ) -join "`n"
    [System.IO.File]::WriteAllText($path, $body + "`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host ('stored: ' + $path)
} catch {
    Write-Host ('[keys] not written: ' + $_.Exception.Message)
    exit 1
}

# The check: the list of buckets is asked of the bucket itself.
$result = Invoke-AbkRcloneCommand -AppRoot $AppRoot -DataRoot $data -PassThru -Command @(
    (Find-AbkRclone -AppRoot $AppRoot),
    (Get-AbkRcloneArgs -AppRoot $AppRoot -DataRoot $data),
    'lsjson', 'r2:'
).ForEach({ $_ }) 2>$null

if ($result.ExitCode -eq 0) {
    $names = @()
    try { $names = @($result.Output -join "`n" | ConvertFrom-Json | ForEach-Object { $_.Name }) } catch { }
    Write-Host ('R2 buckets: {0}' -f $(if ($names.Count) { $names -join ', ' } else { 'the answer is empty' }))
    exit 0
}
foreach ($line in @($result.Output)) { Write-Host ([string]$line) }
Write-Host '[keys] the R2 bucket did not answer - check the pair and the rights of the token'
exit 1
