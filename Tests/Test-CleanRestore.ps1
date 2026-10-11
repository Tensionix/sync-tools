#requires -Version 5.1
param([string]$AppRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $AppRoot 'Engine\SshHostIdentity.ps1')
. (Join-Path $AppRoot 'Engine\SshProfile.ps1')
. (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1')
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Host ('PASS ' + $Message)
}
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($Path.EndsWith('.ps1')))
}
function Run-Child([string]$Script, [string[]]$Arguments) {
    $p = [Diagnostics.Process]::new()
    $p.StartInfo.FileName = (Get-Process -Id $PID).Path
    $p.StartInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + ($Arguments -join ' ')
    $p.StartInfo.UseShellExecute = $false; $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.RedirectStandardOutput = $true; $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.EnvironmentVariables.Remove('PSModulePath')
    [void]$p.Start()
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(45000)) { $p.Kill(); throw 'Fixture timeout' }
        return @{ Exit=$p.ExitCode; Text=($stdout.Result + $stderr.Result) }
    } finally { $p.Dispose() }
}
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-clean-restore-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($lab)
try {
    $data = Join-Path $lab 'DATA with spaces'
    $before = Join-Path $lab 'old ProgramData\ssh'
    $after = Join-Path $lab 'new ProgramData\ssh'
    [void][IO.Directory]::CreateDirectory($before)
    $private = Join-Path $before 'ssh_host_ed25519_key'
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command ssh-keygen.exe).Source
    $psi.Arguments = '-q -t ed25519 -N "" -f "' + $private + '"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $keygen = [Diagnostics.Process]::Start($psi)
    try { if (-not $keygen.WaitForExit(15000)) { $keygen.Kill(); throw 'Keygen timeout' }; Assert ($keygen.ExitCode -eq 0) 'synthetic host pair generated' } finally { $keygen.Dispose() }
    $hash = (Get-FileHash -LiteralPath $private).Hash
    Assert ((Save-AbkSshHostIdentity -DataRoot $data -SshDirectory $before) -eq 'saved') 'current Windows identity saved in DATA'
    $archive = Join-Path $data 'Tunnel\SSHD'
    $acl = Get-Acl -LiteralPath (Join-Path $archive 'ssh_host_ed25519_key')
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544')
    Assert ($acl.AreAccessRulesProtected -and @($acl.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed }).Count -eq 0) 'saved private host key has a restricted ACL'
    # Live sshd needs administrator ownership. This non-elevated fixture keeps
    # the same restrictive rules under its test owner; no real ProgramData writes.
    $protect = ${function:Protect-AbkHostIdentityFile}
    function Protect-AbkHostIdentityFile { param($Path, [switch]$Archive, [switch]$Directory) & $protect -Path $Path -Archive -Directory:$Directory }
    Assert ((Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $after) -eq 'restored') 'empty ProgramData gets retained identity'
    Assert ((Get-FileHash -LiteralPath (Join-Path $after 'ssh_host_ed25519_key')).Hash -eq $hash) 'host identity is byte-identical after reinstall'
    Assert ((Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $after) -eq 'verified') 'repeat restore is idempotent'
    Put (Join-Path $after 'ssh_host_ed25519_key') 'DIFFERENT SYNTHETIC KEY'
    $refused = $false
    try { $null = Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory $after } catch { $refused = $_.Exception.Message -like '*conflict*' }
    Assert ($refused -and [IO.File]::ReadAllText((Join-Path $after 'ssh_host_ed25519_key')) -eq 'DIFFERENT SYNTHETIC KEY') 'different live identity is preserved and fails closed'
    Put (Join-Path $archive 'ssh_host_ed25519_key.pub') 'CORRUPTED PUBLIC HALF'
    $refused = $false
    try { $null = Restore-AbkSshHostIdentity -DataRoot $data -SshDirectory (Join-Path $lab 'untouched') } catch { $refused = $true }
    Assert ($refused -and -not (Test-Path -LiteralPath (Join-Path $lab 'untouched'))) 'damaged archive is rejected before target writes'
    Copy-Item -LiteralPath ($private + '.pub') -Destination (Join-Path $archive 'ssh_host_ed25519_key.pub') -Force
    $bad = Join-Path $lab 'bad pair'; [void][IO.Directory]::CreateDirectory($bad)
    Copy-Item -LiteralPath $private -Destination $bad
    Put (Join-Path $bad 'ssh_host_ed25519_key.pub') 'ssh-ed25519 INVALID fixture'
    $refused = $false
    try { $null = Save-AbkSshHostIdentity -DataRoot (Join-Path $lab 'bad DATA') -SshDirectory $bad } catch { $refused = $true }
    Assert ($refused -and -not (Test-Path -LiteralPath (Join-Path $lab 'bad DATA\Tunnel\SSHD'))) 'mismatched pair is never published as a backup'

    $known = Join-Path $data 'config\rclone\known_hosts'
    Put $known ('fixture.invalid ' + [IO.File]::ReadAllText($private + '.pub'))
    $config = Join-Path $lab 'empty profile\config'
    Put $config "Host fixture`r`n    HostName fixture.invalid`r`n    ProxyJump fixture-jump`r`nHost fixture-jump`r`n    HostName jump.invalid`r`n"
    $beforeTrust = [IO.File]::ReadAllText($config)
    $null = Update-AbkSshProfileTrust -DataRoot $data -SshConfig $config -Check
    Assert ([IO.File]::ReadAllText($config) -ceq $beforeTrust) 'trust Check writes nothing'
    $null = Update-AbkSshProfileTrust -DataRoot $data -SshConfig $config
    $first = [IO.File]::ReadAllText($config)
    $null = Update-AbkSshProfileTrust -DataRoot $data -SshConfig $config
    Assert ([IO.File]::ReadAllText($config) -ceq $first) 'managed DATA trust block is idempotent'
    foreach ($alias in @('fixture', 'fixture-jump')) {
        $effective = @(& ssh.exe -G -F $config $alias 2>$null)
        Assert ($LASTEXITCODE -eq 0 -and @($effective | Where-Object { $_ -like 'userknownhostsfile*' -and $_.Contains($known.Replace('\','/')) }).Count -eq 1) ('OpenSSH and jump host see retained DATA trust: ' + $alias)
    }
    Put (Join-Path $lab 'empty profile\own_key') 'SYNTHETIC CLIENT KEY'
    $relocated = Repair-AbkImportedIdentityPaths -Text '    IdentityFile "Z:/missing/profile/own_key"' -SshDirectory (Join-Path $lab 'empty profile')
    Assert ($relocated.Contains('empty profile/own_key')) 'arbitrary client key paths relocate after profile loss'

    # Persistent/disabled channels and neighbouring backup states remain distinct.
    $beaconDir = Join-Path $data 'Tunnel\SSH\beacon'
    foreach ($name in @('local-fixture','neighbour-fixture','disabled-fixture')) {
        Put (Join-Path $beaconDir ($name + '_beacon_ed25519')) 'synthetic beacon key'
        Put (Join-Path $beaconDir ('beacon-' + $name + '.sshconfig')) '# synthetic config'
        Put (Join-Path $beaconDir ($name + '.beacon.json')) (@{Name=$name; Port=22345; User='fixture'; Servers=@('fixture.invalid'); Persistent=$true; AutoStart=($name -ne 'disabled-fixture'); KeyFile='Z:\old\key'; SshConfig='Z:\old\config'} | ConvertTo-Json)
    }
    $startup = Join-Path $lab 'empty Startup'; [void][IO.Directory]::CreateDirectory($startup)
    $name = Restore-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data -Name 'local-fixture' -StartupFolder $startup
    Assert ($name -eq 'local-fixture' -and @(Get-ChildItem -LiteralPath $startup -Filter '*.lnk').Count -eq 1) 'only selected enabled channel gets Startup restored'
    $name = Restore-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data -Name 'disabled-fixture' -StartupFolder $startup
    Assert (-not $name -and @(Get-ChildItem -LiteralPath $startup -Filter '*.lnk').Count -eq 1) 'disabled and neighbouring channels stay disabled'
    Assert ($null -ne (Get-AbkBeaconLaunchSpec -DataRoot $data -Name 'local-fixture')) 'relocated beacon state resolves inside current DATA'
    Assert ((Restore-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data -StartupFolder $startup) -eq 'local-fixture') 'custom channel name survives a different Windows computer name via DATA receipt'
    Assert ((Get-AbkBeaconLaunchSpec -DataRoot $data).Name -eq 'local-fixture' -and (Get-AbkLocalBeaconName -DataRoot $data) -eq 'local-fixture') 'GUI runtime and CLI resolve the same retained channel name'
    $null = Set-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data -Name 'local-fixture' -Enabled $false -StartupFolder $startup
    Assert (-not (Restore-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $data -StartupFolder $startup)) 'explicitly disabled Startup receipt cannot reactivate a saved channel'

    # Full CLI sequence, with only OS/service/network boundaries replaced.
    $app = Join-Path $lab 'clean program'
    $profile = Join-Path $lab 'clean profile'
    $cleanData = Join-Path $lab 'clean machine DATA'
    $cleanWindows = Join-Path $lab 'clean Windows\ssh'
    [void][IO.Directory]::CreateDirectory((Join-Path $app 'Engine\Scripts'))
    foreach ($name in @('DataRoot','Targets','Secrets','SshProfile','SshHostIdentity','BeaconLifecycle')) {
        Copy-Item -LiteralPath (Join-Path $AppRoot ('Engine\' + $name + '.ps1')) -Destination (Join-Path $app ('Engine\' + $name + '.ps1'))
    }
    Copy-Item -LiteralPath (Join-Path $AppRoot 'Engine\Scripts\Restore-Machine.ps1') -Destination (Join-Path $app 'Engine\Scripts\Restore-Machine.ps1')
    $import = [IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Import-AudionKeys.ps1'))
    $import = $import.Replace('$SshDir = Join-Path $HOME ''.ssh''', ('$SshDir = ''' + $profile.Replace("'","''") + ''''))
    $import = $import.Replace('Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $Root', 'Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $Root -SshConfig $SshConfig')
    Put (Join-Path $app 'Engine\Scripts\Import-AudionKeys.ps1') $import
    # Avoid consulting the actual user's profile even for deciding cloudflared needs.
    $restoreFile = Join-Path $app 'Engine\Scripts\Restore-Machine.ps1'
    $restore = [IO.File]::ReadAllText($restoreFile).Replace("(Join-Path `$HOME '.ssh\config')", ("'" + (Join-Path $profile 'config').Replace("'","''") + "'"))
    $restore = $restore.Replace("(Join-Path `$HOME '.ssh')", ("'" + $profile.Replace("'","''") + "'"))
    Put $restoreFile $restore
    Put (Join-Path $cleanData 'Tunnel\RemoteDesktop\config\targets.json') '{"fixture":{"host":"fixture.invalid","user":"fixture"}}'
    [void][IO.Directory]::CreateDirectory((Join-Path $cleanData 'Tunnel'))
    Copy-Item -LiteralPath $archive -Destination (Join-Path $cleanData 'Tunnel\SSHD') -Recurse
    Copy-Item -LiteralPath $private -Destination (Join-Path $lab 'client_key')
    Put (Join-Path $cleanData 'Tunnel\SSH\clients\client_key') ([IO.File]::ReadAllText($private))
    Put (Join-Path $cleanData 'Tunnel\SSH\clients\client_key.pub') ([IO.File]::ReadAllText($private + '.pub'))
    Put (Join-Path $cleanData 'Tunnel\SSH\config') "Host fixture`r`n    HostName fixture.invalid`r`n    IdentityFile Z:/old/profile/client_key`r`n"
    Put (Join-Path $cleanData 'config\rclone\known_hosts') ([IO.File]::ReadAllText($known))
    Put (Join-Path $cleanData 'config\rclone\rclone.conf') "[fixture]`r`ntype = sftp`r`nkey_file = Z:/lost/profile/client_key`r`nknown_hosts_file = Z:/lost/DATA/known_hosts`r`n"
    $service = @'
param([string]$Root,[switch]$NoPause)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'Engine\SshHostIdentity.ps1')
function Protect-AbkHostIdentityFile { param($Path,[switch]$Archive,[switch]$Directory) }
$destination = '__DESTINATION__'
$null = Restore-AbkSshHostIdentity -DataRoot $Root -SshDirectory $destination
if (-not (Test-Path -LiteralPath (Join-Path $destination 'ssh_host_ed25519_key'))) { throw 'Host identity missing BEFORE service start' }
[IO.File]::WriteAllText((Join-Path $destination 'service-started'), 'synthetic service')
$null = Save-AbkSshHostIdentity -DataRoot $Root -SshDirectory $destination
exit 0
'@
    Put (Join-Path $app 'Tunnel\RemoteDesktop\Setup-SshServer.ps1') ($service.Replace('__DESTINATION__', $cleanWindows.Replace("'","''")))
    $result = Run-Child $restoreFile @('-Root', ('"' + $cleanData + '"'), '-Check', '-NoPause')
    Assert ($result.Exit -eq 0 -and -not (Test-Path -LiteralPath $profile) -and -not (Test-Path -LiteralPath $cleanWindows)) 'RESTORE Check leaves clean Windows untouched'
    $result = Run-Child $restoreFile @('-Root', ('"' + $cleanData + '"'), '-SkipProbe', '-NoPause')
    if ($result.Exit -ne 0) { Write-Host $result.Text }
    Assert ($result.Exit -eq 0) 'clean Windows CLI sequence completes with explicit DATA containing spaces'
    Assert ((Get-FileHash -LiteralPath (Join-Path $cleanWindows 'ssh_host_ed25519_key')).Hash -eq $hash -and (Test-Path -LiteralPath (Join-Path $cleanWindows 'service-started'))) 'retained host identity installed before fixture service starts'
    Assert ((Test-Path -LiteralPath (Join-Path $profile 'client_key')) -and [IO.File]::ReadAllText((Join-Path $profile 'config')).Contains('audion-data-trust')) 'clean profile receives client keys, routes and retained trust'
    $rcloneText = [IO.File]::ReadAllText((Join-Path $cleanData 'config\rclone\rclone.conf'))
    Assert ($rcloneText.Contains($profile.Replace('\','/') + '/client_key') -and $rcloneText.Contains($cleanData.Replace('\','/') + '/config/rclone/known_hosts')) 'panels recover lost key/trust paths from selected DATA and profile'
    Put (Join-Path $cleanData 'config\rclone\rclone.conf') ($rcloneText + "`r`n[agent-only]`r`ntype = sftp`r`nkey_file =`r`nknown_hosts_file =`r`n")
    $null = Repair-AbkRestoreDataPaths -DataRoot $cleanData -SshDirectory $profile
    Assert ([IO.File]::ReadAllText((Join-Path $cleanData 'config\rclone\rclone.conf')).Contains("key_file =`r`nknown_hosts_file =")) 'empty agent key path does not consume the following INI field'

    Copy-Item -LiteralPath (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Destination (Join-Path $app 'Engine\BackupRclone.psm1')
    Put (Join-Path $app 'Tools\rclone\rclone.exe') 'never executed: process boundary stubbed'
    $probeFile = Join-Path $app 'Engine\Scripts\Test-RestoredRoutes.ps1'
    $probeSource = [IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Test-RestoredRoutes.ps1'))
    Put $probeFile ($probeSource.Replace("Join-Path `$HOME '.ssh\config'", ("Join-Path '" + $profile.Replace("'","''") + "' 'config'")))
    $network = @'
function Initialize-AbkHostScanLifetime { }
function Invoke-AbkHostScanBatch {
    param($Requests,$TimeoutSeconds,[switch]$Detailed)
    # Two at first; a failed one is asked again alone.
    if ($Requests.Count -lt 1 -or $Requests.Count -gt 2) { throw 'Expected one SSH and one SFTP request' }
    $results=@{}
    foreach($request in $Requests) {
        if ($request.Key -eq 'fixture') {
            $config=$request.Arguments[1]
            $text=[IO.File]::ReadAllText($config)
            if ($text -notmatch 'StrictHostKeyChecking yes' -or $text -notmatch 'UpdateHostKeys no' -or $text -notmatch 'BatchMode yes') { throw 'Unsafe restore probe' }
            $results[$request.Key]='AUDION_RESTORE_OK'
        } elseif($request.Key -eq 'sftp:fixture') {
            if ($request.Arguments -notcontains '--stat' -or $request.Arguments -notcontains ':sftp:/' -or $request.Arguments -notcontains '--sftp-ssh') { throw 'Wrong SFTP probe' }
            # Without a fixed shell type rclone rewrites rclone.conf on every probe.
            if ($request.Arguments -notcontains '--sftp-shell-type') { throw 'SFTP probe would rewrite rclone.conf' }
            $results[$request.Key]='{"IsDir":true}'
        } else { throw 'Unexpected network destination' }
        if ($Detailed) { $results[$request.Key] = [pscustomobject]@{ Out=$results[$request.Key]; Err=''; ExitCode=0; TimedOut=$false } }
    }
    $results
}
'@
    Put (Join-Path $app 'Engine\SshHosts.ps1') $network
    $result = Run-Child $restoreFile @('-Root', ('"' + $cleanData + '"'), '-NoPause')
    if ($result.Exit -ne 0) { Write-Host $result.Text }
    Assert ($result.Exit -eq 0 -and $result.Text -match 'fixture\s+OK\s+OK') 'RESTORE ends with SSH and SFTP results using strict bounded probes'
    Put (Join-Path $app 'Engine\SshHosts.ps1') ($network.Replace('''{"IsDir":true}''', ''''''))
    $result = Run-Child $restoreFile @('-Root', ('"' + $cleanData + '"'), '-NoPause')
    Assert ($result.Exit -eq 2 -and $result.Text.Contains('local setup completed')) 'SFTP failure is reported as partial connectivity, not successful restore verification'
    Put (Join-Path $profile 'config') "Host obsolete`r`n    HostName old.invalid`r`n"
    $result = Run-Child (Join-Path $app 'Engine\Scripts\Import-AudionKeys.ps1') @('-Root', ('"' + $cleanData + '"'), '-RestoreConfig', '-NoPause')
    Assert ($result.Exit -eq 0 -and [IO.File]::ReadAllText((Join-Path $profile 'config')).Contains('Host fixture') -and [IO.File]::ReadAllText((Join-Path $profile 'config.before-restore')).Contains('Host obsolete')) 'explicit RestoreConfig replaces old aliases and retains one previous copy'
} finally {
    $resolved = [IO.Path]::GetFullPath($lab)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-clean-restore-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'All isolated clean Windows restore checks passed.'
