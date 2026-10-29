param([string]$SourceRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$file=Join-Path $SourceRoot 'Tunnel\RemoteDesktop\Setup-SshServer.ps1'
$source=[IO.File]::ReadAllText($file)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
foreach($name in @('Test-Admin','Install-OpenSshFromGithub','Test-SshdAnswers')){
    $f=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0]
    $replacement=switch($name){
        'Test-Admin'{'function Test-Admin { return $true }'}
        'Install-OpenSshFromGithub'{'function Install-OpenSshFromGithub { Record-Event "install-mock"; $script:ServicePresent=$true; return $true }'}
        'Test-SshdAnswers'{'function Test-SshdAnswers { return ($scenario -ne ''no-listener'') }'}
    }
    $source=$source.Replace($f.Extent.Text,$replacement)
}
$source=$source.Replace('$env:ProgramData','$FixtureProgramData')
$preamble=@'
$fixtureBase=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$FixtureProgramData=Join-Path $fixtureBase 'ProgramData'
$scenario=Split-Path -Leaf $fixtureBase
$eventLog=Join-Path $fixtureBase 'events.log'
$script:ServicePresent=($scenario -ne 'new-install')
$script:MockStatus='Running'
function Record-Event([string]$Event){Add-Content -LiteralPath $eventLog -Value $Event -Encoding UTF8}
function Get-Service { param($Name,$ErrorAction) if($script:ServicePresent){[pscustomobject]@{Name='sshd';Status=$script:MockStatus;StartType='Automatic'}} }
function Set-Service { param($Name,$StartupType) Record-Event 'set-automatic' }
function New-FixtureSsh {
    $folder=Join-Path $FixtureProgramData 'ssh'
    New-Item -ItemType Directory -Path $folder -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $folder 'sshd_config'),'synthetic-bootstrap-config')
    [IO.File]::WriteAllText((Join-Path $folder 'ssh_host_ed25519_key'),'synthetic-bootstrap-hostkey-marker')
    $script:MockStatus='Running'
}
function Restart-Service { param($Name,[switch]$Force) Record-Event 'restart';New-FixtureSsh }
function Start-Service { param($Name) Record-Event 'start';New-FixtureSsh }
function Get-NetFirewallRule { param($Name,$DisplayName,$ErrorAction) }
function Disable-NetFirewallRule { param($ErrorAction) Record-Event 'disable-default-firewall-mock' }
function Remove-NetFirewallRule { param($DisplayName) Record-Event 'remove-firewall-mock' }
function New-NetFirewallRule { param($DisplayName,$Direction,$Protocol,$LocalPort,$Action,$Profile,$RemoteAddress) Record-Event 'new-firewall-mock' }
function Start-Sleep { param($Seconds,$Milliseconds) }
function icacls { Record-Event 'icacls-mock'; if($scenario -eq 'acl-failure'){$global:LASTEXITCODE=5;'synthetic ACL denied'}else{$global:LASTEXITCODE=0;'synthetic ACL success'} }
function Invoke-RestMethod { throw 'FORBIDDEN network' }
function Invoke-WebRequest { throw 'FORBIDDEN network' }
function Start-Process { throw 'FORBIDDEN process or elevation' }
function Get-WindowsCapability { throw 'FORBIDDEN servicing' }
function Start-Job { throw 'FORBIDDEN servicing job' }
function ssh { throw 'FORBIDDEN SSH' }
'@
# The parameter block is unchanged by replacing definitions below it.
$offset=$ast.ParamBlock.Extent.EndOffset
$runner=$source.Substring(0,$offset)+"`r`n"+$preamble+"`r`n"+$source.Substring($offset)
$stand=Join-Path ([IO.Path]::GetTempPath()) ('abk-sshd-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stand | Out-Null
$results=@()
# The cases run under the PowerShell that runs this test - the one the program carries, or the
# builder's - not under Windows PowerShell 5.1 whatever the caller: the script is tried under
# the shell that really runs it.
$hostExe=(Get-Process -Id $PID).Path
try {
foreach($case in @('new-install','running-empty','acl-failure','no-listener','no-clients')){
    $dir=Join-Path (Join-Path $stand 'sshd-fixtures') $case
    if(Test-Path -LiteralPath $dir){throw 'Fixture already exists'}
    $app=Join-Path $dir 'Audion Sync Tools';$data=Join-Path $dir 'Audion Backup Synthetic'
    $scriptDir=Join-Path $app 'Tunnel\RemoteDesktop'
    New-Item -ItemType Directory -Path $scriptDir,(Join-Path $app 'Engine'),$data -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'Engine\DataRoot.ps1') -Destination (Join-Path $app 'Engine\DataRoot.ps1')
    # Service/firewall orchestration here; real-key recovery is tested separately.
    $identityStub = @'
function Restore-AbkSshHostIdentity { param($DataRoot) Record-Event 'identity-before-install'; 'not-saved' }
function Save-AbkSshHostIdentity { param($DataRoot) Record-Event 'identity-after-start'; 'saved' }
'@
    [IO.File]::WriteAllText((Join-Path $app 'Engine\SshHostIdentity.ps1'), $identityStub, [Text.UTF8Encoding]::new($true))
    if($case -ne 'no-clients'){
        $clients=Join-Path $data 'Tunnel\SSH\clients'
        New-Item -ItemType Directory -Path $clients -Force|Out-Null
        [IO.File]::WriteAllText((Join-Path $clients 'synthetic.pub'),'ssh-ed25519 SYNTHETIC synthetic',[Text.UTF8Encoding]::new($false))
    }
    $scriptFile=Join-Path $scriptDir 'Setup-SshServer.ps1'
    [IO.File]::WriteAllText($scriptFile,$runner,[Text.UTF8Encoding]::new($true))
    $log=Join-Path $dir 'stdout.log'
    # The output is taken as text, not sent to a file by ">": PowerShell 7 puts the bytes of a
    # native command into the file as they are (code page 866 of the console), 5.1 re-encodes
    # them. Read back as UTF-8, the Russian word the test looks for was there under 5.1 and gone
    # under 7 - three good cases of five failed on 04.10.2026 though the script had done its work.
    $stdout=(& $hostExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptFile -Root $data 2>(Join-Path $dir 'stderr.log') | Out-String)
    $exit=$LASTEXITCODE
    [IO.File]::WriteAllText($log,$stdout,[Text.UTF8Encoding]::new($false))
    $events=@([IO.File]::ReadAllLines((Join-Path $dir 'events.log')))
    if ($events[0] -ne 'identity-before-install' -or $events -notcontains 'identity-after-start') { throw 'SSHD identity restore/save order broken' }
    $keyFile=Join-Path $dir 'ProgramData\ssh\administrators_authorized_keys'
    $keyExists=Test-Path -LiteralPath $keyFile
    $keyAdded=$keyExists -and [IO.File]::ReadAllText($keyFile).Contains('SYNTHETIC')
    $results+=@{case=$case;exit=$exit;events=$events;programDataInitiallyAbsent=$true;keyFileCreated=$keyExists;clientAdded=$keyAdded;reportsReady=($stdout -match '(?m)^  ГОТОВО:');warnsAcl=$stdout.Contains('не удалось закрыть права');warnsNoListener=$stdout.Contains('порт 22 не слушается');forbiddenInvoked=$stdout.Contains('FORBIDDEN')}
    Write-Output ($case+': exit='+$exit+' key='+$keyAdded+' ready='+($stdout -match '(?m)^  ГОТОВО:'))
}
    $failed=@($results | Where-Object {
        $expectedFailure=$_.case -in @('acl-failure','no-listener')
        $_.forbiddenInvoked -or -not $_.keyFileCreated -or
        ($_.case -ne 'no-clients' -and -not $_.clientAdded) -or
        ($expectedFailure -and ($_.exit -eq 0 -or $_.reportsReady)) -or
        (-not $expectedFailure -and ($_.exit -ne 0 -or -not $_.reportsReady))
    })
    if ($failed.Count) { throw ('SSHD install cases failed: '+($failed.case -join ', ')) }
} finally {
    $resolved=[IO.Path]::GetFullPath($stand)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-sshd-install-*') { throw 'Unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'All five isolated SSHD installation cases passed'
exit 0
