#requires -Version 5.1
[CmdletBinding()]
param([string]$Root, [ValidateRange(1,30)][int]$TimeoutSeconds = 20)
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\SshHosts.ps1')
. (Join-Path $AppRoot 'Engine\Targets.ps1')
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root

function Test-ProbeAnswer {
    param($Request, $Answer)
    if (-not $Answer -or $Answer.TimedOut -or $Answer.ExitCode -ne 0) { return $false }
    if ($Request.Key.StartsWith('sftp:')) {
        # A root stat returns a nonempty JSON object even for an empty directory.
        try { return (($Answer.Out | ConvertFrom-Json).IsDir -eq $true) } catch { return $false }
    }
    return ($Answer.Out -match '(?m)^AUDION_RESTORE_OK\s*$')
}

function Get-ProbeReason {
    <# One line a person can act on: the last error line, the exit code, or the silence. #>
    param($Answer)
    if (-not $Answer) { return 'did not run' }
    if ($Answer.TimedOut) { return ('no answer in {0} s' -f $TimeoutSeconds) }
    # rclone's notice about host keys is noise here: ssh checks them itself.
    # OpenSSH marks its advisory warnings with two asterisks.
    $lines = @(([string]$Answer.Err -split "`r?`n") | ForEach-Object { ($_ -replace '^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d\s+', '').Trim() } |
        Where-Object { $_ -and $_ -notmatch 'No host key validation is being performed' -and $_ -notmatch '^\*\*' })
    $last = if ($lines.Count) { $lines[-1] } else { '' }
    if ($last.Length -gt 160) { $last = $last.Substring(0, 160) + '...' }
    if ($Answer.ExitCode -ne 0) {
        if ($last) { return ('exit {0}: {1}' -f $Answer.ExitCode, $last) }
        return ('exit {0}' -f $Answer.ExitCode)
    }
    $out = ([string]$Answer.Out).Trim()
    if (-not $out) { return 'empty answer' }
    return ('unexpected answer: ' + ($out -split "`r?`n")[0])
}
$targets = [IO.File]::ReadAllText((Join-Path $data 'Tunnel\RemoteDesktop\config\targets.json')) | ConvertFrom-Json
$profileConfig = Join-Path $HOME '.ssh\config'
$known = Join-Path $data 'config\rclone\known_hosts'
if (-not (Test-Path -LiteralPath $profileConfig) -or -not (Test-Path -LiteralPath $known)) { throw 'SSH config or retained DATA known_hosts is missing' }
# This dedicated child owns a job: timed-out SSH proxies die when it exits.
Initialize-AbkHostScanLifetime
$strictConfig = Join-Path ([IO.Path]::GetTempPath()) ('abk-restore-' + [guid]::NewGuid().ToString('N') + '.sshconfig')
try {
    $quotedKnown = $known.Replace('\','/').Replace('%','%%')
    $quotedProfile = $profileConfig.Replace('\','/').Replace('%','%%')
    [IO.File]::WriteAllText($strictConfig, "Host *`r`n    BatchMode yes`r`n    StrictHostKeyChecking yes`r`n    UpdateHostKeys no`r`n    ConnectTimeout 8`r`n    ConnectionAttempts 1`r`n    UserKnownHostsFile `"$quotedKnown`"`r`nInclude `"$quotedProfile`"`r`n", [Text.UTF8Encoding]::new($false))
    $hosts = @(Read-AbkSshConfig -Path $profileConfig)
    $requests = @(); $missing = @()
    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    $rclone = Find-AbkRclone -AppRoot $AppRoot
    if (-not $rclone) { throw 'rclone is missing: run UPDATE before testing SFTP' }
    $rcloneConfig = Join-Path $data 'config\rclone\rclone.conf'
    foreach ($prop in $targets.PSObject.Properties) {
        if ($prop.Name.StartsWith('_') -or $prop.Name.StartsWith('router-') -or $prop.Value.keyAuth -eq $false) { continue }
        $target = $prop.Value
        if (-not $target.host -and -not $target.lan -and -not $target.user -and
            (-not $target.sshHost -or -not @($hosts | Where-Object { $_.Names -contains $target.sshHost }).Count)) { continue }
        $alias = if ($target.sshHost) { [string]$target.sshHost } else { $prop.Name }
        if ($alias -notmatch '^[a-zA-Z0-9_.-]+$' -or $alias.StartsWith('-')) { throw 'Invalid SSH alias in DATA' }
        if (-not @($hosts | Where-Object { $_.Names -contains $alias }).Count) {
            # ssh -G is not sufficient: an unknown alias is also accepted as a DNS name.
            $missing += [pscustomobject]@{ Route=$alias; SSH='NOT CONFIGURED'; SFTP='NOT CONFIGURED' }
            continue
        }
        $requests += [pscustomobject]@{ Key=$alias; File=$ssh; Arguments=@('-F', $strictConfig, '-T', $alias, 'echo AUDION_RESTORE_OK') }
        # Probe SFTP through the identical authenticated SSH route, including jumps.
        # A root stat returns a nonempty JSON object even for an empty directory.
        # --sftp-shell-type: an on-the-fly :sftp: remote otherwise detects the
        # shell and rewrites rclone.conf; seven parallel rewrites on Windows made
        # every SFTP probe fail at random (BASE, 26.09.2026).
        $sshCommand = '"' + $ssh + '" -F "' + $strictConfig + '" ' + $alias
        $requests += [pscustomobject]@{ Key=('sftp:' + $alias); File=$rclone; Arguments=@('lsjson', '--stat', ':sftp:/', '--config', $rcloneConfig, '--sftp-ssh', $sshCommand, '--sftp-disable-hashcheck', '--sftp-shell-type', 'none', '--retries', '1', '--low-level-retries', '1', '--contimeout', '8s', '--timeout', '12s') }
    }
    $first = Invoke-AbkHostScanBatch -Requests $requests -TimeoutSeconds $TimeoutSeconds -Detailed
    $ok = @{}
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($request in $requests) {
        $answer = $first[$request.Key]
        if (Test-ProbeAnswer $request $answer) { $ok[$request.Key] = $true; continue }
        $reason = Get-ProbeReason $answer
        # A fast failure is rechecked alone before the route is called dead.
        # Inside RESTORE MIRROR on 26.09.2026 every SFTP probe failed at once,
        # while each route answered when asked again: the table said FAILED
        # and nothing else. The first reason is kept either way.
        $again = $null
        if (-not $answer.TimedOut) { $again = (Invoke-AbkHostScanBatch -Requests @($request) -TimeoutSeconds $TimeoutSeconds -Detailed)[$request.Key] }
        $ok[$request.Key] = [bool]($again -and (Test-ProbeAnswer $request $again))
        $what = if ($request.Key.StartsWith('sftp:')) { $request.Key.Substring(5) + ' SFTP' } else { $request.Key + ' SSH' }
        if ($ok[$request.Key]) { $notes.Add(('  {0}: OK on the second try; the first failed with {1}' -f $what, $reason)) }
        elseif ($again) { $notes.Add(('  {0}: {1}' -f $what, (Get-ProbeReason $again))) }
        else { $notes.Add(('  {0}: {1}' -f $what, $reason)) }
    }
    $rows = @($missing)
    foreach ($request in $requests) {
        if ($request.Key.StartsWith('sftp:')) { continue }
        $rows += [pscustomobject]@{ Route=$request.Key; SSH=$(if ($ok[$request.Key]) { 'OK' } else { 'FAILED' }); SFTP=$(if ($ok['sftp:' + $request.Key]) { 'OK' } else { 'FAILED' }) }
    }
    $rows | Format-Table -AutoSize | Out-Host
    if ($notes.Count) {
        Write-Host 'Why:'
        foreach ($note in $notes) { Write-Host $note }
    }
    if (-not $rows.Count -or @($rows | Where-Object { $_.SSH -ne 'OK' -or $_.SFTP -ne 'OK' }).Count) { exit 2 }
} finally {
    # Exact file created above, no directory cleanup or profile mutation.
    if (Test-Path -LiteralPath $strictConfig) { Remove-Item -LiteralPath $strictConfig -Force }
}
