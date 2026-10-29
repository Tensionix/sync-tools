#requires -Version 5.1
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1')
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-beacon-lifecycle-' + [guid]::NewGuid().ToString('N'))
$app = Join-Path $lab 'app with spaces'
$data = Join-Path $lab 'Audion Backup Work'
$name = 'fixture-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$beforeName = $env:COMPUTERNAME
$env:COMPUTERNAME = $name
$failed = 0
$control = @{ Handle=$null; After=[datetime]::MinValue }
$messages = New-Object System.Collections.Generic.List[string]
function Check($Title, [bool]$Ok) {
    if ($Ok) { Write-Host ('PASS ' + $Title) }
    else { Write-Host ('FAIL ' + $Title); $script:failed++ }
}
function Put($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($true)) }
function Wait-File($Path) {
    $end=(Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $Path) -and (Get-Date) -lt $end) { Start-Sleep -Milliseconds 50 }
    if (-not (Test-Path -LiteralPath $Path)) { throw ('Fixture did not start: ' + $Path) }
}
try {
    foreach ($dir in @((Join-Path $app 'Engine'),(Join-Path $app 'Tunnel\RemoteDesktop'),(Join-Path $data 'Tunnel\SSH\beacon'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $AppRoot 'Engine\BeaconLifecycle.ps1') -Destination (Join-Path $app 'Engine')
    $keydir=Join-Path $data 'Tunnel\SSH\beacon'
    $key=Join-Path $keydir 'fixture.key'; $conf=Join-Path $keydir 'fixture.config'
    Put $key 'not a real private key'; Put $conf 'not a real SSH config'
    $file=Join-Path $keydir ($name + '.beacon.json')
    $saved=@{Name=$name;Port=22345;User='fixture';Servers=@('fixture.invalid');KeyFile=$key;SshConfig=$conf;AutoStart=$true}
    Check 'empty data has no launch specification' ($null -eq (Get-AbkBeaconLaunchSpec -DataRoot $data -Name $name))
    Put $file ($saved | ConvertTo-Json)
    Check 'selected data with spaces resolves' ((Get-AbkBeaconLaunchSpec -DataRoot $data -Name $name).Root -eq $data)
    $saved.AutoStart=$false; Put $file ($saved | ConvertTo-Json)
    Check 'explicit stop disables automatic launch' ($null -eq (Get-AbkBeaconLaunchSpec -DataRoot $data -Name $name))
    $saved.AutoStart=$true; $saved.KeyFile=Join-Path $lab 'outside.key'; Put $saved.KeyFile 'fixture'; Put $file ($saved | ConvertTo-Json)
    $rejected=$false; try { Get-AbkBeaconLaunchSpec -DataRoot $data -Name $name | Out-Null } catch { $rejected=$true }
    Check 'key outside selected beacon directory rejected' $rejected
    $saved.KeyFile=$key; $saved.Name='another-machine'; Put $file ($saved | ConvertTo-Json)
    $rejected=$false; try { Get-AbkBeaconLaunchSpec -DataRoot $data -Name $name | Out-Null } catch { $rejected=$true }
    Check 'another machine state rejected' $rejected
    $saved.Name=$name; Put $file ($saved | ConvertTo-Json)

    $trace=Join-Path $lab 'ssh.log'
    Put $trace ('debug1: remote forward success for: listen 127.0.0.1:22345, connect 127.0.0.1:22' + "`r`n" + ('x' * 70000))
    Check 'later SSH traffic does not hide handshake acknowledgment' ((Read-AbkBeaconSshLog -Path $trace -Head).Contains('remote forward success'))
    Check 'diagnostic tail stays bounded' ((Read-AbkBeaconSshLog -Path $trace).Length -le 65536)
    $native=Join-Path $lab 'native stderr.ps1'
    Put $native '1..128 | ForEach-Object { [Console]::Error.WriteLine("fixture diagnostic " + $_) }; exit 7'
    Put $trace ''
    $checkpoints=Join-Path $lab 'native.trace.log'
    $rc=Invoke-AbkBeaconSsh -File (Get-Process -Id $PID).Path -Arguments @('-NoProfile','-ExecutionPolicy','Bypass','-File',$native) -Log $trace -TraceLog $checkpoints
    Check 'native stderr drained and exit code preserved' ($rc -eq 7 -and (Read-AbkBeaconSshLog -Path $trace).Contains('fixture diagnostic 128'))
    $steps=[IO.File]::ReadAllText($checkpoints)
    Check 'native launch and first stderr checkpoint persisted' ($steps.Contains('ssh.started') -and $steps.Contains('ssh.stderr.first-write.done') -and $steps.Contains('ssh.exited'))
    Check 'checkpoints do not copy native arguments or stderr' (-not $steps.Contains($native) -and -not $steps.Contains('fixture diagnostic'))
    $rc=Invoke-AbkBeaconSsh -File (Get-Process -Id $PID).Path -Arguments @('-NoProfile','-Command','exit 9') -Log $trace -TraceLog (Join-Path $lab 'missing\no.trace.log')
    Check 'unwritable checkpoint does not stop the native process' ($rc -eq 9)
    # A local version query exercises the actual Windows SSH client without
    # opening a connection, reading a profile or using any real key.
    $sshVersion=Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if(Test-Path -LiteralPath $sshVersion){
        Put $trace ''
        $rc=Invoke-AbkBeaconSsh -File $sshVersion -Arguments @('-V') -Log $trace -TraceLog $checkpoints
        Check 'Windows OpenSSH version output is drained without network' ($rc -eq 0 -and (Read-AbkBeaconSshLog -Path $trace).Contains('OpenSSH'))
    }

    # A synthetic worker launches local ssh -V inside its real job before a
    # long-lived child. No connection, real SSH profile or key is used.
    $fixture=Join-Path $app 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
    Put $fixture @'
param([switch]$Hold,[string]$Name,[string]$Root,[string]$RuntimeLog)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Engine\BeaconLifecycle.ps1')
$guard=Enter-AbkBeaconRuntime -DataRoot $Root -Name $Name
if(-not $guard){exit 0}
Initialize-AbkBeaconLifetime
[IO.File]::WriteAllText((Join-Path $Root 'worker-host.txt'),((Get-Process -Id $PID).Path + '|' + $PSVersionTable.PSVersion))
if(Test-Path -LiteralPath (Join-Path $Root 'fatal')){
    Write-AbkBeaconTrace -Path $RuntimeLog -Stage 'fixture.before-fatal'
    [Environment]::Exit(1073741845)
}
if(Test-Path -LiteralPath (Join-Path $Root 'fail')){throw 'intentional bootstrap failure'}
$ssh=Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
if(Test-Path -LiteralPath $ssh){
    $nativeLog=Join-Path $Root 'worker-ssh-version.log'
    $rc=Invoke-AbkBeaconSsh -File $ssh -Arguments @('-V') -Log $nativeLog -TraceLog $RuntimeLog
    if($rc -ne 0){throw ('Contained local ssh failed: ' + $rc)}
}
$exe=(Get-Process -Id $PID).Path
$child=Start-Process -FilePath $exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 90"' -WindowStyle Hidden -PassThru
[IO.File]::WriteAllText((Join-Path $Root 'child.pid'),[string]$child.Id)
[IO.File]::WriteAllText((Join-Path $Root 'worker.pid'),[string]$PID)
Start-Sleep -Seconds 90
'@
    $say={param($line) $messages.Add($line)}
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Wait-File (Join-Path $data 'worker.pid')
    $worker=$control.Handle.Process.Id
    $childId=[int][IO.File]::ReadAllText((Join-Path $data 'child.pid'))
    Check 'GUI supervisor launches configured worker directly' ($worker -gt 0 -and $control.Handle.Root -eq $data)
    $actualHost=[IO.File]::ReadAllText((Join-Path $data 'worker-host.txt'))
    Check 'worker uses inbox Windows PowerShell 5.1 even when pwsh is installed' ($actualHost -match '(?i)\\WindowsPowerShell\\v1\.0\\powershell\.exe\|5\.1\.')
    if(Test-Path -LiteralPath $sshVersion){
        Check 'contained worker launches Windows OpenSSH and records its PID' (([IO.File]::ReadAllText((Join-Path $data 'worker-ssh-version.log'))).Contains('OpenSSH') -and ([IO.File]::ReadAllText($control.Handle.TraceLog)).Contains('ssh.started childPID='))
    }
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'repeated update keeps the same process' ($control.Handle.Process.Id -eq $worker)
    Check 'existing worker prevents duplicate start' ($null -eq (Start-AbkBeaconRuntime -AppRoot $app -DataRoot $data -Name $name))
    $duplicate=Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$fixture+'" -Hold -Name '+$name+' -Root "'+$data+'"') -WindowStyle Hidden -PassThru
    try {
        [void]$duplicate.WaitForExit(10000)
        Check 'worker mutex also rejects a racing direct launch' ($duplicate.HasExited -and $duplicate.ExitCode -eq 0 -and [IO.File]::ReadAllText((Join-Path $data 'worker.pid')) -eq [string]$worker)
    } finally { if(-not $duplicate.HasExited){$duplicate.Kill()};$duplicate.Dispose() }

    $control.Handle.Process.Kill(); [void]$control.Handle.Process.WaitForExit(5000)
    Start-Sleep -Milliseconds 200
    Check 'worker death removes its native child' (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue))
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'unexpected exit logged and restart delayed' (-not $control.Handle -and $control.After -gt (Get-Date) -and $messages.Count -ge 2)
    $count=$messages.Count
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'backoff prevents repeated launches and log flood' (-not $control.Handle -and $messages.Count -eq $count)

    $control.After=[datetime]::MinValue
    $control.Suspended=$true
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'GUI STOP is not undone by supervisor' (-not $control.Handle)
    $control.Suspended=$false
    $laptop=Join-Path $lab 'Audion Backup Laptop'
    New-Item -ItemType Directory -Path $laptop | Out-Null
    Copy-Item -LiteralPath (Join-Path $data 'Tunnel') -Destination $laptop -Recurse
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $laptop -Say $say
    Check 'LAPTOP remnants are not restored' (-not $control.Handle)

    $exe=(Get-Process -Id $PID).Path
    $setup=Start-Process -FilePath $exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 60"' -WindowStyle Hidden -PassThru
    $control.SetupProcess=$setup
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'interactive setup is not raced by the GUI' (-not $control.Handle)
    $setup.Kill(); [void]$setup.WaitForExit(5000)
    Put (Join-Path $data 'fail') 'fixture'
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    if(-not $control.Handle){throw 'No restart after console exit'}
    [void]$control.Handle.Process.WaitForExit(15000)
    if(-not $control.Handle.Process.HasExited){throw 'Failure fixture stayed alive'}
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    Check 'bootstrap error reaches GUI diagnostics' (($messages -join "`n") -like '*intentional bootstrap failure*')

    Put (Join-Path $data 'fatal') 'fixture'
    $control.After=[datetime]::MinValue
    Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say
    if(-not $control.Handle){throw 'No fatal-exit fixture'}
    [void]$control.Handle.Process.WaitForExit(15000)
    if(-not $control.Handle.Process.HasExited){throw 'Fatal-exit fixture stayed alive'}
    $exitDetail=Get-AbkBeaconRuntimeExit $control.Handle
    if(-not $exitDetail.Contains('0x40000015')){ Write-Host ('fatal fixture: ' + $exitDetail) }
    Check 'silent fatal exit retains its last checkpoint and status' ($exitDetail.Contains('0x40000015') -and $exitDetail.Contains('fixture.before-fatal') -and $exitDetail.Contains('STATUS_FATAL_APP_EXIT'))
    Check 'silent fatal fixture writes no stderr' ((Get-Item -LiteralPath $control.Handle.ErrLog).Length -eq 0)
    Check 'each worker gets a separate checkpoint file' (([IO.File]::ReadAllText($control.Handle.TraceLog) -split 'launcher.start').Count -eq 2)

    # Exercise the actual -Hold entry point and full SSH arguments, not just
    # the synthetic worker's -V. A local ProxyCommand waits on anonymous pipes;
    # it never opens a socket or authenticates. targets.json and -F prevent
    # production bootstrap and OpenSSH from consulting the real SSH profile.
    if (Test-Path -LiteralPath $sshVersion) {
        $control.Handle.Process.Dispose(); $control.Handle=$null
        foreach ($dependency in 'DataRoot.ps1','Secrets.ps1','Targets.ps1','KeyPair.ps1','RestoreMirror.ps1') {
            Copy-Item -LiteralPath (Join-Path $AppRoot ('Engine\' + $dependency)) -Destination (Join-Path $app 'Engine')
        }
        Copy-Item -LiteralPath (Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1') -Destination $fixture
        $targetDir=Join-Path $data 'Tunnel\RemoteDesktop\config'
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        Put (Join-Path $targetDir 'targets.json') '{"second":{"host":"127.0.0.1","sshHost":"fixture.invalid"}}'
        $proxyPidFile=Join-Path $lab 'proxy.pid'
        $proxyCode='[IO.File]::WriteAllText(''' + $proxyPidFile.Replace("'","''") + ''',[string]$PID); Start-Sleep -Seconds 90'
        $proxyEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($proxyCode))
        $proxyExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Put $conf (@(
            'Host *', '    HostName 127.0.0.1', '    IdentityAgent none',
            '    UserKnownHostsFile NUL', '    GlobalKnownHostsFile NUL',
            ('    ProxyCommand "{0}" -NoProfile -NonInteractive -EncodedCommand {1}' -f $proxyExe.Replace('\','/'),$proxyEncoded)
        ) -join "`r`n")
        $saved.Name=$name; Put $file ($saved | ConvertTo-Json)
        $control.After=[datetime]::MinValue
        # The ssh of Git (usr\bin, an MSYS build) comes first in PATH of a Git Bash shell and stops at the BOM of this
        # config before its ProxyCommand. A dummy in a usr\bin of the lab stands for it, whatever shell runs the test.
        $fakeBin=Join-Path $lab 'usr\bin'
        New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
        Put (Join-Path $fakeBin 'ssh.exe') 'not an ssh'
        $beforePath=$env:PATH
        $env:PATH=$fakeBin + ';' + $env:PATH
        try { Update-AbkBeaconRuntime -Control $control -AppRoot $app -DataRoot $data -Say $say }
        finally { $env:PATH=$beforePath }
        if(-not $control.Handle){throw 'No production -Hold fixture'}
        $until=(Get-Date).AddSeconds(10)
        do {
            $productionTrace=Read-AbkBeaconSshLog -Path $control.Handle.TraceLog
            if($productionTrace.Contains('worker.ssh.resolved')){break}
            Start-Sleep -Milliseconds 50
        } while((Get-Date) -lt $until)
        $resolvedSsh=[regex]::Match($productionTrace,'worker\.ssh\.resolved ([^\r\n]+)').Groups[1].Value.Trim()
        Check 'production worker passes by an MSYS ssh first in PATH' ($resolvedSsh.Length -gt 0 -and -not $resolvedSsh.StartsWith($fakeBin,[StringComparison]::OrdinalIgnoreCase))
        Wait-File $proxyPidFile
        $proxyId=[int][IO.File]::ReadAllText($proxyPidFile)
        $productionTrace=Read-AbkBeaconSshLog -Path $control.Handle.TraceLog
        $sshPidMatch=[regex]::Match($productionTrace,'ssh.started childPID=(\d+)')
        Check 'production -Hold starts SSH with full tunnel arguments and local proxy' ($sshPidMatch.Success -and -not $control.Handle.Process.HasExited)
        $productionLog=Join-Path $app ('logs\ssh-beacon-' + $name + '-ssh.log')
        $until=(Get-Date).AddSeconds(5)
        do {
            $productionText=Read-AbkBeaconSshLog -Path $productionLog
            if($productionText.Contains('Executing proxy command')){break}
            Start-Sleep -Milliseconds 50
        } while((Get-Date) -lt $until)
        Check 'production -Hold exposes live SSH diagnostics without claiming a forward' ($productionText.Contains('Executing proxy command') -and -not $productionText.Contains('remote forward success'))
        $control.Handle.Process.Kill(); [void]$control.Handle.Process.WaitForExit(5000)
        $sshChildId=if($sshPidMatch.Success){[int]$sshPidMatch.Groups[1].Value}else{0}
        $until=(Get-Date).AddSeconds(5)
        do {
            $left=@(Get-Process -Id $proxyId,$sshChildId -ErrorAction SilentlyContinue)
            if(-not $left.Count){break}
            Start-Sleep -Milliseconds 50
        } while((Get-Date) -lt $until)
        Check 'production worker death removes SSH and its proxy grandchild' ($sshChildId -gt 0 -and $left.Count -eq 0)
    }
} finally {
    if($control.SetupProcess){try{if(-not $control.SetupProcess.HasExited){$control.SetupProcess.Kill()}}catch{};$control.SetupProcess.Dispose()}
    if($control.Handle){try{if(-not $control.Handle.Process.HasExited){$control.Handle.Process.Kill()}}catch{};$control.Handle.Process.Dispose()}
    $env:COMPUTERNAME=$beforeName
    $resolved=[IO.Path]::GetFullPath($lab)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'abk-beacon-lifecycle-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if($failed){exit 1}
exit 0
