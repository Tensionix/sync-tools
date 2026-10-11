#requires -Version 5.1
[CmdletBinding()]
param([string]$Root, [switch]$Check, [switch]$RestoreConfig, [switch]$SkipProbe, [switch]$NoPause,
    # MIRROR: C: becomes exactly what DATA describes (Engine\RestoreMirror.ps1).
    [switch]$Mirror,
    # MIRROR without questions: UAC is requested once, logins are only reported.
    [switch]$NoPrompt)
$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $AppRoot 'Engine\DataRoot.ps1')
. (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1')
. (Join-Path $AppRoot 'Engine\SshProfile.ps1')
$data = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
if ($Mirror) { . (Join-Path $AppRoot 'Engine\RestoreMirror.ps1') }
$LegacyTask = 'Audion Backup Sync'

function Invoke-RestoreStep {
    param([string]$RelativeScript, [string[]]$Arguments = @(), [switch]$ReturnExitCode)
    # Separate scopes are required: component scripts return using exit.
    $scriptFile = Join-Path $AppRoot $RelativeScript
    $quoted = "'" + $scriptFile.Replace("'", "''") + "'"
    $command = '$global:LASTEXITCODE = 0; & ' + $quoted
    foreach ($arg in $Arguments) {
        if ($arg -in @('-Root','-NoPause','-RestoreConfig','-Check','-SkipSshConfig','-Rclone')) { $command += ' ' + $arg }
        else { $command += " '" + $arg.Replace("'", "''") + "'" }
    }
    $command += '; if (-not $?) { exit 1 }'
    # A step that ran to its end is a step that succeeded. `exit $LASTEXITCODE` stood here, and
    # that variable also holds the code of the last program the step started: a step that dealt
    # with a refusal of a tool and ended without an exit of its own failed the whole restore
    # (tried 08.10.2026: codes 2, 3, 4 and 9 out of scripts that -File ends with 0). An exit
    # that is not zero is caught by the line above.
    $command += '; exit 0'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded | Out-Host
    if ($ReturnExitCode) { return [int]$LASTEXITCODE }
    if ($LASTEXITCODE -ne 0) { throw ("Restore step failed: $RelativeScript (exit=$LASTEXITCODE)") }
}

function Test-LegacyTask {
    & cmd.exe /d /c ('schtasks /Query /TN "' + $LegacyTask + '" >nul 2>&1')
    return ($LASTEXITCODE -eq 0)
}

function Invoke-MirrorSshd {
    <# SSHD as administrator: DATA host keys, exactly CLIENTS as access keys. #>
    param([string]$Backup)
    $script = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshServer.ps1'
    $log = Join-Path $Backup 'sshd.log'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $script -Root $data -Mirror -MirrorBackup $Backup -NoPause | Out-Host
        $code = $LASTEXITCODE
    } else {
        Write-Host 'SSHD: нужны права администратора - подтвердите UAC' -ForegroundColor Cyan
        $quote = { param($Value) '"' + ($Value -replace '(\\+)$', '$1$1') + '"' }
        $arguments = @('-Root', (& $quote $data), '-Mirror', '-MirrorBackup', (& $quote $Backup),
            '-LogPath', (& $quote $log), '-Elevated', '-NoPause')
        $code = Invoke-AbkElevatedStep -Script $script -Arguments $arguments -NoPrompt:$NoPrompt
        # The elevated window closes by itself; its transcript is shown here.
        if (Test-Path -LiteralPath $log) {
            $inside = $false
            foreach ($line in [IO.File]::ReadAllLines($log)) {
                if ($line -match '^\*{10}') { $inside = -not $inside; continue }
                if (-not $inside -and $line -notmatch '^Transcript started') { Write-Host $line }
            }
        }
    }
    return $code
}

try {
    Write-Host ('RESTORE: ' + $data)
    $targets = Join-Path $data 'Tunnel\RemoteDesktop\config\targets.json'
    if (-not (Test-Path -LiteralPath $targets)) { throw 'Select the existing machine DATA folder: targets.json is missing' }
    $null = [IO.File]::ReadAllText($targets) | ConvertFrom-Json
    if ($Check) {
        Invoke-RestoreStep 'Engine\Scripts\Import-AudionKeys.ps1' @('-Root', $data, '-Check', '-NoPause')
        if ($Mirror) {
            Write-Host 'MIRROR: ~/.ssh is rebuilt from DATA as a whole; these leave C: for DATA\._runtime\mirror-<time>:'
            $profileSsh = (Join-Path $HOME '.ssh')
            if (Test-Path -LiteralPath $profileSsh) {
                foreach ($file in @(Get-ChildItem -LiteralPath $profileSsh -Force -Recurse -File)) {
                    Write-Host ('  ~\.ssh\' + $file.FullName.Substring($profileSsh.Length + 1))
                }
            }
            foreach ($item in @(Get-AbkMirrorLeftovers)) { Write-Host ('  ' + $item.Path + '  (' + $item.What + ')') }
            if (Test-LegacyTask) { Write-Host ('  scheduled task: ' + $LegacyTask) }
            Write-Host 'MIRROR: administrators_authorized_keys = CLIENTS exactly; SSHD host keys = Tunnel\SSHD'
            Write-Host 'MIRROR: then Cloudflare Access sign-in and missing router passwords, waiting for you'
        }
        Write-Host 'Plan: IMPORT KEYS -> SSHD identity/service/access -> enabled SSH TUN Startup -> route checks'
        $store = Join-Path $data 'Tunnel\SSHD'
        if (Test-Path -LiteralPath $store) {
            . (Join-Path $AppRoot 'Engine\SshHostIdentity.ps1')
            $null = Read-AbkHostIdentityManifest -Store $store
            Write-Host 'SSHD: saved identity verified'
        } else { Write-Host 'SSHD: no saved identity; run SSHD on the current Windows BEFORE reinstalling' }
        exit 0
    }
    $backup = $null
    if ($Mirror) {
        $backup = New-AbkMirrorBackup -DataRoot $data
        try { Start-Transcript -LiteralPath (Join-Path $backup 'restore.log') -Force | Out-Null } catch { }
        Write-Host ('MIRROR: everything removed from C: goes to ' + $backup) -ForegroundColor Cyan
    }
    # Install only the client binary. DATA/profile routes must never be regenerated
    # using installer defaults during recovery of an existing machine.
    $configs = @((Join-Path $data 'Tunnel\Export\SSH\config'), (Join-Path $data 'Tunnel\SSH\config'), (Join-Path $HOME '.ssh\config'))
    $needsCf = @($configs | Where-Object { (Test-Path -LiteralPath $_) -and ([IO.File]::ReadAllText($_) -match 'cloudflared') }).Count -gt 0
    if ($needsCf -and -not (Test-Path -LiteralPath (Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'))) {
        Invoke-RestoreStep 'Tunnel\Install-TunnelClient.ps1' @('-Root', $data, '-SkipSshConfig', '-NoPause')
    }
    if ($Mirror -and -not (Test-Path -LiteralPath (Join-Path $AppRoot 'Tools\rclone\rclone.exe'))) {
        Invoke-RestoreStep 'Engine\Scripts\Update-Tools.ps1' @('-Root', $data, '-Rclone', '-NoPause')
    }
    $movedProfile = $null
    if ($Mirror) {
        # /MIR: the profile is rebuilt from DATA, nothing old survives in it.
        $movedProfile = Move-AbkMirrorItem -Path (Join-Path $HOME '.ssh') -Backup $backup -Name 'profile-ssh'
        if ($movedProfile) { Write-Host '  moved: ~\.ssh -> profile-ssh' }
        foreach ($item in @(Get-AbkMirrorLeftovers)) {
            $null = Move-AbkMirrorItem -Path $item.Path -Backup $backup -Name $item.Name
            Write-Host ('  moved: ' + $item.Path + '  (' + $item.What + ')')
        }
        if (Test-LegacyTask) {
            $xml = Join-Path $backup 'leftovers\task-Audion Backup Sync.xml'
            New-Item -ItemType Directory -Path (Split-Path -Parent $xml) -Force | Out-Null
            & cmd.exe /d /c ('schtasks /Query /TN "' + $LegacyTask + '" /XML > "' + $xml + '" 2>nul')
            & cmd.exe /d /c ('schtasks /Delete /TN "' + $LegacyTask + '" /F >nul 2>&1')
            if ($LASTEXITCODE -eq 0) { Write-Host ('  removed: scheduled task ' + $LegacyTask) }
            else { Write-Host ('  NOT removed: scheduled task ' + $LegacyTask + ' - REMOVE TASK in the window') -ForegroundColor Yellow }
        }
    }
    $importArgs = @('-Root', $data, '-NoPause')
    if ($RestoreConfig -or $Mirror) { $importArgs += '-RestoreConfig' }
    try { Invoke-RestoreStep 'Engine\Scripts\Import-AudionKeys.ps1' $importArgs }
    catch {
        if ($movedProfile) {
            # A half-built profile is worse than the old one: put the old one back.
            $null = Move-AbkMirrorItem -Path (Join-Path $HOME '.ssh') -Backup $backup -Name 'profile-ssh.failed-import'
            Copy-Item -LiteralPath $movedProfile -Destination (Join-Path $HOME '.ssh') -Recurse -Force
            Write-Host 'MIRROR: import failed, the previous ~\.ssh is back in place' -ForegroundColor Yellow
        }
        throw
    }
    Write-Host (Repair-AbkRestoreDataPaths -DataRoot $data -SshDirectory (Join-Path $HOME '.ssh'))
    if ($Mirror) {
        $sshd = Invoke-MirrorSshd -Backup $backup
        if ($null -eq $sshd) { Write-Host 'SSHD: skipped - run SETUP -> SSHD later' -ForegroundColor Yellow }
        elseif ($sshd -ne 0) { throw ('Restore step failed: SSHD (exit=' + $sshd + ')') }
    } else {
        Invoke-RestoreStep 'Tunnel\RemoteDesktop\Setup-SshServer.ps1' @('-Root', $data, '-NoPause')
    }
    $beaconName = Restore-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data
    if ($beaconName) {
        $handle = Start-AbkBeaconRuntime -AppRoot $AppRoot -DataRoot $data -Name $beaconName
        if ($handle) { $handle.Process.Dispose() }
        Write-Host ('SSH TUN: enabled Startup restored: ' + $beaconName)
    } else { Write-Host 'SSH TUN: no enabled persistent channel for this machine' }
    if ($Mirror) {
        Write-Host ''
        Write-Host '===== SIGN-IN: Cloudflare Access and router passwords' -ForegroundColor Cyan
        $cf = Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'
        if (Test-Path -LiteralPath $cf) { $null = Invoke-AbkAccessLogins -Cloudflared $cf -SshConfig (Join-Path $HOME '.ssh\config') -NoPrompt:$NoPrompt }
        $null = Invoke-AbkRouterLogins -AppRoot $AppRoot -DataRoot $data -NoPrompt:$NoPrompt
        Write-Host ('MIRROR: what left C: is kept in ' + $backup)
    }
    if (-not $SkipProbe) {
        $probeExit = Invoke-RestoreStep 'Engine\Scripts\Test-RestoredRoutes.ps1' @('-Root', $data) -ReturnExitCode
        if ($probeExit -ne 0) {
            Write-Host 'RESTORE: local setup completed; some routes are unavailable or unconfigured. See SSH/SFTP results above.' -ForegroundColor Yellow
            exit 2
        }
    }
    Write-Host 'RESTORE: completed. Reopen Sync Tools to reload the profile.'
    exit 0
} catch {
    Write-Host ('RESTORE INCOMPLETE: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($Mirror -and $backup) { try { Stop-Transcript | Out-Null } catch { } }
}
