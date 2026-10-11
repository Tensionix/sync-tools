#requires -Version 5.1
<#
    Переменные окружения после вызова rclone - убраны, а не пусты.

    Under PowerShell 7, [Environment]::SetEnvironmentVariable($name, $null)
    leaves an EMPTY variable ($null reaches .NET as ''). The window runs on
    PowerShell 7, so every rclone it started afterwards died on
    RCLONE_S3_NO_CHECK_BUCKET="" - the red SFTP column of RESTORE MIRROR on
    26.09.2026. Removal must go through [NullString]::Value.
#>
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $PSScriptRoot
$failed = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:failed++ }
}

# 1. No removal by $null anywhere in the program.
$hits = @(Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Engine') -Recurse -File -Include '*.ps1', '*.psm1' |
    Select-String -Pattern 'SetEnvironmentVariable\([^)]*,\s*\$null\s*\)')
Check ('no SetEnvironmentVariable(..., $null) in Engine (found ' + $hits.Count + ')') ($hits.Count -eq 0)

# 2. A real call through the module leaves nothing behind - on PowerShell 7,
# where the defect lives. The "rclone" here is cmd.exe: the module does not
# care what it runs, and nothing reaches the network.
$pwsh = @("$env:ProgramFiles\PowerShell\7\pwsh.exe", (Join-Path $AppRoot 'Tools\pwsh\pwsh.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($pwsh) {
    $module = (Join-Path $AppRoot 'Engine\BackupRclone.psm1').Replace("'", "''")
    $code = @"
Import-Module '$module' -Force -DisableNameChecking
foreach (`$n in 'RCLONE_S3_NO_CHECK_BUCKET', 'AWS_SHARED_CREDENTIALS_FILE') { [Environment]::SetEnvironmentVariable(`$n, [NullString]::Value) }
`$null = Invoke-AbkRcloneCommand -AppRoot '$($AppRoot.Replace("'", "''"))' -Command @("`$env:SystemRoot\System32\cmd.exe", '/c', 'exit 0') -PassThru
foreach (`$n in 'RCLONE_S3_NO_CHECK_BUCKET', 'AWS_SHARED_CREDENTIALS_FILE') { '{0}={1}' -f `$n, [Environment]::GetEnvironmentVariables().Contains(`$n) }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $answer = @(& $pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1 | ForEach-Object { "$_" })
    Check 'PowerShell 7: RCLONE_S3_NO_CHECK_BUCKET removed after an rclone call' ($answer -contains 'RCLONE_S3_NO_CHECK_BUCKET=False')
    Check 'PowerShell 7: AWS_SHARED_CREDENTIALS_FILE removed after an rclone call' ($answer -contains 'AWS_SHARED_CREDENTIALS_FILE=False')
} else {
    Write-Host '  SKIP  PowerShell 7 is not installed: the defect cannot show here'
}

if ($failed) { Write-Host "провалено проверок: $failed"; exit 1 }
Write-Host 'всё сходится'
exit 0