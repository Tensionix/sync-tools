#requires -Version 5.1
[CmdletBinding()]
param([string]$AppRoot='')
$ErrorActionPreference='Stop'
if (-not $AppRoot) { $AppRoot=Split-Path -Parent $PSScriptRoot }
$failed=0
function Test-Step { param([string]$Title,[bool]$Ok)
    if($Ok){Write-Host ('PASS '+$Title)}else{Write-Host ('FAIL '+$Title);$script:failed++}
}
function Function-Text { param([string]$Path,[string]$Name)
    $t=$null;$e=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if($e.Count){throw ($e|Out-String)}
    $f=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($f.Count -ne 1){throw ('Missing function '+$Name)}
    $f[0].Extent.Text
}
function Put-File { param([string]$Path,[string]$Text)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
. (Join-Path $AppRoot 'Engine\Secrets.ps1')
. (Join-Path $AppRoot 'Engine\SshHosts.ps1')
$import=Join-Path $AppRoot 'Engine\Scripts\Import-AudionKeys.ps1'
foreach($name in 'Get-ImportPrivatePath','Get-ImportPublicKeys','Copy-Secret','Protect-KeyFile','Write-Note'){
    Invoke-Expression (Function-Text $import $name)
}
$beacon=Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
foreach($name in 'Get-BeaconHint','Repair-BeaconIdentity') { Invoke-Expression (Function-Text $beacon $name) }
function Write-Line { param($Text,$Color) }
$lab=Join-Path ([IO.Path]::GetTempPath()) ('abk-ssh-recovery-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $lab | Out-Null
$lifetime=$null
try {
    $key=Join-Path $lab 'private-fixture'
    Put-File $key 'synthetic private fixture, not a real key'
    & icacls.exe $key /grant '*S-1-1-0:R' /Q | Out-Null
    $hash=(Get-FileHash -LiteralPath $key).Hash
    Test-Step 'explicit foreign ACL is detected' (-not (Test-AbkSshPrivateKeyAcl $key))
    Test-Step 'repair closes inheritance and explicit foreign grants' (Protect-AbkSshPrivateKey $key)
    Test-Step 'ACL repair does not modify key bytes' ((Get-FileHash -LiteralPath $key).Hash -eq $hash)
    $acl=(Get-Acl -LiteralPath $key).Sddl
    Test-Step 'repeating ACL repair is idempotent' ((Protect-AbkSshPrivateKey $key) -and (Get-Acl -LiteralPath $key).Sddl -eq $acl)

    $DataRoot=Join-Path $lab 'machine'
    $selected=Join-Path $DataRoot 'Tunnel\SSH\servers\second_test_ed25519'
    Put-File $selected 'selected synthetic key'
    & icacls.exe $selected /grant '*S-1-1-0:R' /Q | Out-Null
    $script:Identity=$selected
    function ssh { if(@($args) -notcontains '-G'){throw 'Unexpected live SSH call'}; $global:LASTEXITCODE=0; 'identityfile '+$script:Identity }
    $hash=(Get-FileHash -LiteralPath $selected).Hash
    Test-Step 'beacon repairs the identity selected by ssh config' (Repair-BeaconIdentity -Target 'second-test')
    Test-Step 'selected server key is protected without changing bytes' ((Test-AbkSshPrivateKeyAcl $selected) -and (Get-FileHash -LiteralPath $selected).Hash -eq $hash)
    $outside=Join-Path $lab 'unrelated\private'
    Put-File $outside 'unrelated fixture'
    & icacls.exe $outside /grant '*S-1-1-0:R' /Q | Out-Null
    $before=(Get-Acl -LiteralPath $outside).Sddl
    $script:Identity=$outside
    Test-Step 'beacon leaves identities outside data/profile untouched' (-not (Repair-BeaconIdentity -Target 'second-test') -and (Get-Acl -LiteralPath $outside).Sddl -eq $before)
    Test-Step 'bad permissions get an ACL hint before authentication denial' ((Get-BeaconHint 'UNPROTECTED PRIVATE KEY FILE! bad permissions. Permission denied (publickey).') -match 'ACL')

    $export=Join-Path $lab 'Export\SSH'
    $store=Join-Path $lab 'Store\SSH'
    Put-File (Join-Path $export 'machine_ed25519') 'new-export-private'
    Put-File (Join-Path $export 'machine_ed25519.pub') 'ssh-ed25519 AAAA new-export'
    Put-File (Join-Path $store 'clients\machine_ed25519') 'old-store-private'
    Put-File (Join-Path $store 'clients\machine.pub') 'ssh-ed25519 BBBB old-store'
    Put-File (Join-Path $store 'servers\second_ed25519') 'server-private'
    Put-File (Join-Path $store 'servers\second_ed25519.pub') 'ssh-ed25519 CCCC server'
    $pairs=@(Get-ImportPublicKeys -Folders @($export,$store))
    Test-Step 'partial Export is supplemented by server pair from Store' ($pairs.Count -eq 2 -and @($pairs|Where-Object BaseName -eq 'second_ed25519').Count -eq 1)
    Test-Step 'Export wins when both sources contain the same pair' (@($pairs|Where-Object DirectoryName -eq $export).Count -eq 1 -and @($pairs|Where-Object BaseName -eq 'machine').Count -eq 0)
    $Check=$false;$Force=$false;$Placed=0;$Kept=0
    $destination=Join-Path $lab 'profile\second_ed25519'
    Put-File $destination 'existing profile key'
    & icacls.exe $destination /grant '*S-1-1-0:R' /Q | Out-Null
    $hash=(Get-FileHash -LiteralPath $destination).Hash
    $Check=$true;$before=(Get-Acl -LiteralPath $destination).Sddl
    Copy-Secret -From (Join-Path $store 'servers\second_ed25519') -To $destination -Title fixture -Protect
    Test-Step 'IMPORT KEYS Check does not change existing ACL' ((Get-Acl -LiteralPath $destination).Sddl -eq $before)
    $Check=$false
    Copy-Secret -From (Join-Path $store 'servers\second_ed25519') -To $destination -Title fixture -Protect
    Test-Step 'kept profile key has its ACL repaired without overwrite' ((Test-AbkSshPrivateKeyAcl $destination) -and (Get-FileHash -LiteralPath $destination).Hash -eq $hash)

    $targets=@{second=@{host='second.example.invalid';sshHost='second-test';sshPort=2222};work=@{lan='192.0.2.9';sshPort=22}}
    $plan=@(Get-AbkHostScanPlan $targets)
    $known=Join-Path $lab 'data\config\rclone\known_hosts'
    $say={param($Text)}
    $result=Save-AbkScannedHosts -Plan $plan -Answers @{second='second.example.invalid ssh-ed25519 AAAA';work='192.0.2.9 ssh-ed25519 BBBB'} -Path $known -Say $say
    $first=[IO.File]::ReadAllText($known)
    Test-Step 'SECOND VPS host keys use its configured SSH port' ($first.Contains('[second.example.invalid]:2222,[second-test]:2222 ssh-ed25519 AAAA'))
    $hash=(Get-FileHash -LiteralPath $known).Hash
    $result=Save-AbkScannedHosts -Plan $plan -Answers @{second='';work=''} -Path $known -Say $say
    Test-Step 'unreachable hosts preserve the entire known_hosts file' ((Get-FileHash -LiteralPath $known).Hash -eq $hash -and $result.Held -eq 2)
    $result=Save-AbkScannedHosts -Plan $plan -Answers @{second='second.example.invalid ssh-ed25519 CCCC';work=''} -Path $known -Say $say
    Test-Step 'changed host key is preserved without Force' ((Get-FileHash -LiteralPath $known).Hash -eq $hash -and $result.Changed -eq 1)
    $result=Save-AbkScannedHosts -Plan $plan -Answers @{second='ssh-ed25519 CCCC fixture';work=''} -Path $known -Say $say -Force
    Test-Step 'explicit Force updates one host and preserves its neighbour' ([IO.File]::ReadAllText($known).Contains('CCCC') -and [IO.File]::ReadAllText($known).Contains('BBBB'))
    Test-Step 'banners are not accepted as host keys' (@(ConvertFrom-AbkScannedKey -Text 'Permission denied (publickey).' -Who host).Count -eq 0)
    Test-Step 'DSA host keys are not collected' (@(ConvertFrom-AbkScannedKey -Text 'ssh-dss AAAA' -Who host).Count -eq 0)
    $vps=@(Get-AbkHostScanPlan @{server=@{host='vps.example.invalid';sshHost='vps-direct'};'router-base'=@{lan='192.0.2.1'}})
    Test-Step 'MAIN VPS keys are also written under HostKeyAlias audion-vps' ($vps[0].Who -eq 'vps.example.invalid,vps-direct,audion-vps')
    Test-Step 'SSH-KEYSCAN includes the router for FILES ROUTER' ($vps.Count -eq 2 -and $vps[1].Caption -eq 'ROUTER')

    # Real child processes, never SSH: parallel wait and deadline handling.
    $child=Join-Path $lab 'wait.ps1'
    Put-File $child 'param($Delay,$Marker); [IO.File]::WriteAllText($Marker,[string]$PID); Start-Sleep -Milliseconds ([int]$Delay); Write-Output done'
    $ps=(Get-Command powershell.exe -CommandType Application | Select-Object -First 1).Source
    $requests=@(1..4 | ForEach-Object { [pscustomobject]@{Key=[string]$_;File=$ps;Arguments=@('-NoProfile','-File',$child,'1200',(Join-Path $lab ('fast-'+$_)))} })
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $answers=Invoke-AbkHostScanBatch -Requests $requests -TimeoutSeconds 4
    $clock.Stop()
    Test-Step 'four probes wait in parallel instead of adding their timeouts' ($answers.Count -eq 4 -and @($answers.Values|Where-Object { $_.Trim() -eq 'done' }).Count -eq 4 -and $clock.Elapsed.TotalSeconds -lt 4)
    $requests=@(1..3 | ForEach-Object { [pscustomobject]@{Key=[string]$_;File=$ps;Arguments=@('-NoProfile','-File',$child,'60000',(Join-Path $lab ('slow-'+$_)))} })
    $clock.Restart();$answers=Invoke-AbkHostScanBatch -Requests $requests -TimeoutSeconds 2;$clock.Stop()
    Test-Step 'hung children obey one shared deadline' ($clock.Elapsed.TotalSeconds -lt 3 -and @($answers.Values|Where-Object {$_}).Count -eq 0)
    Start-Sleep -Milliseconds 200
    $alive=@(Get-ChildItem -LiteralPath $lab -Filter 'slow-*' | ForEach-Object { Get-Process -Id ([int][IO.File]::ReadAllText($_.FullName)) -ErrorAction SilentlyContinue })
    Test-Step 'timed out probe processes are gone' ($alive.Count -eq 0)

    # Lifetime job: killing the worker must also terminate its child.
    $lifetimeScript=Join-Path $lab 'lifetime.ps1'
    $helper=(Join-Path $AppRoot 'Engine\SshHosts.ps1').Replace("'","''")
    $marker=(Join-Path $lab 'job-child').Replace("'","''")
    $waitChild=$child.Replace("'","''")
    $text=". '$helper'; Initialize-AbkHostScanLifetime; & powershell.exe -NoProfile -File '$waitChild' 60000 '$marker'"
    Put-File $lifetimeScript $text
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ps
    $info.Arguments='-NoProfile -File '+(ConvertTo-AbkScanArgument $lifetimeScript)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $lifetime=[Diagnostics.Process]::Start($info)
    $deadline=(Get-Date).AddSeconds(8)
    while(-not (Test-Path -LiteralPath (Join-Path $lab 'job-child')) -and (Get-Date) -lt $deadline){Start-Sleep -Milliseconds 50}
    if(-not (Test-Path -LiteralPath (Join-Path $lab 'job-child'))){throw 'Lifetime fixture did not start'}
    $childId=[int][IO.File]::ReadAllText((Join-Path $lab 'job-child'))
    $lifetime.Kill();[void]$lifetime.WaitForExit(2000)
    Start-Sleep -Milliseconds 200
    Test-Step 'stopping the worker also stops its child via the job' (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue))
} finally {
    if($lifetime){try{if(-not $lifetime.HasExited){$lifetime.Kill()}}catch{};$lifetime.Dispose()}
    $resolved=[IO.Path]::GetFullPath($lab)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-ssh-recovery-*'){throw 'Unsafe test cleanup'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
if($failed){throw ('Failed recovery checks: '+$failed)}
Write-Host 'All SSH recovery checks passed.'
