#requires -Version 5.1
[CmdletBinding()]
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$runtime = Join-Path $AppRoot '._runtime'
$stand = Join-Path $runtime ('backup-safety-' + [guid]::NewGuid().ToString('N'))
$fixtureApp = Join-Path $stand 'app'
$hostExe = (Get-Process -Id $PID).Path
$rcloneExe = Join-Path $AppRoot 'Tools\rclone\rclone.exe'
if (-not (Test-Path -LiteralPath $rcloneExe)) { throw 'Bundled rclone is required for local-only backup tests.' }
$today = (Get-Date).ToString('yyyy-MM-dd')
$yesterday = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
$tomorrow = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
function Put([string]$Path, [string]$Text) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($stand + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture escaped its root' }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    [IO.File]::WriteAllText($full, $Text, [Text.UTF8Encoding]::new($true))
}
function Check([bool]$Ok, [string]$Message) {
    if (-not $Ok) {
        if ($script:lastLog -and (Test-Path -LiteralPath $script:lastLog)) { Get-Content -LiteralPath $script:lastLog -Tail 16 | Write-Host }
        throw $Message
    }
    Write-Host ('PASS ' + $Message)
}
$module = @'
function Quote([string]$Value) { '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"' }
function Find-AbkRclone { param($AppRoot) $env:ABK_TEST_RCLONE }
function Get-AbkRcloneArgs { param($AppRoot,[switch]$EnsureDirectories) @('--config', (Join-Path $PSScriptRoot 'empty.conf')) }
function Log-Call([string]$Text) { [IO.File]::AppendAllText((Join-Path $env:ABK_TEST_CASE 'calls.txt'), $Text + "`r`n") }
function Invoke-AbkRcloneCommand {
    param($AppRoot,[string[]]$Command,[switch]$PassThru)
    $verb = $Command[3]
    Log-Call $verb
    $fail = $env:ABK_TEST_MODE
    if (($fail -eq 'list-fail' -and $verb -eq 'lsf') -or
        ($fail -eq 'upload-fail' -and $verb -eq 'sync') -or
        ($fail -eq 'verify-fail' -and $verb -eq 'lsjson') -or
        ($fail -eq 'old-list-fail' -and $verb -eq 'lsjson' -and $Command[6] -notlike ('*' + (Get-Date).ToString('yyyy-MM-dd')))) {
        return @{ExitCode=9;Output=@('synthetic failure')}
    }
    if ($fail -eq 'wrong-file' -and $verb -eq 'lsjson') {
        $source = Get-ChildItem -LiteralPath (Join-Path $env:ABK_TEST_CASE 'release\_archives_private_full') -File | Select-Object -First 1
        return @{ExitCode=0;Output=@('[{"Path":"_archives_private_full/Wrong_v1.zip","Size":' + $source.Length + ',"IsDir":false}]')}
    }
    if ($fail -eq 'null-entry' -and $verb -eq 'lsjson') { return @{ExitCode=0;Output=@('[null]')} }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Command[0]
    $psi.Arguments = ($Command[1..($Command.Count-1)] | ForEach-Object { Quote $_ }) -join ' '
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p=[Diagnostics.Process]::Start($psi)
    try {
        $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
        if ($p.ExitCode -ne 0) { Write-Host $err }
        return @{ExitCode=$p.ExitCode;Output=@($out -split "`r?`n")}
    } finally { $p.Dispose() }
}
# Mirror tests exercise the real entry point, checksum, rotation and robocopy.
# Downloads and Python archive inspection are controlled fixtures, never network calls.
function Invoke-AbkRclone {
    param($AppRoot,$DataRoot,[string[]]$Arguments,[switch]$EnsureDirectories)
    Log-Call $Arguments[0]
    if ($Arguments[0] -eq 'lsf') { return ((Get-Date).ToString('yyyy-MM-dd') + '/') }
    if ($Arguments[0] -ne 'copy') { throw 'Unexpected mirror command' }
    $name = ($Arguments[1] -split '/')[-1]
    Copy-Item -LiteralPath (Join-Path $env:ABK_TEST_CASE ('download\' + $name)) -Destination $Arguments[2]
}
function py {
    Log-Call 'archive-check'
    if ($args[1] -like '*snapshot-check-*') {
        $global:LASTEXITCODE = if ($env:ABK_TEST_MODE -eq 'unusable') { 5 } else { 0 }
        return 'synthetic archive inspection'
    }
    $dest = [string]$args[4]
    if (-not ([IO.Path]::GetFullPath($dest)).StartsWith($env:TEMP + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Extraction escaped fixture temp' }
    [void][IO.Directory]::CreateDirectory($dest)
    [IO.File]::WriteAllText((Join-Path $dest 'new.txt'), 'new mirror data')
    $global:LASTEXITCODE=0
    return 1
}
Export-ModuleMember -Function Find-AbkRclone,Get-AbkRcloneArgs,Invoke-AbkRcloneCommand,Invoke-AbkRclone,py
'@
function Run-Case([string]$Case, [string]$Script, [string[]]$Arguments, [string]$Mode='') {
    $caseRoot = Join-Path $stand $Case
    [void][IO.Directory]::CreateDirectory((Join-Path $caseRoot 'temp'))
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$hostExe
    $argsList=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $fixtureApp ('Engine\Scripts\'+$Script))) + $Arguments + @('-NoPause')
    $psi.Arguments=($argsList | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' '
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['ABK_TEST_CASE']=$caseRoot
    $psi.EnvironmentVariables['ABK_TEST_RCLONE']=$rcloneExe
    $psi.EnvironmentVariables['ABK_TEST_MODE']=$Mode
    $psi.EnvironmentVariables['TEMP']=(Join-Path $caseRoot 'temp')
    $p=[Diagnostics.Process]::Start($psi)
    try {
        $out=$p.StandardOutput.ReadToEnd(); $err=$p.StandardError.ReadToEnd(); $p.WaitForExit()
        $script:lastLog=Join-Path $caseRoot 'run.log'; Put $script:lastLog ($out + $err)
        return $p.ExitCode
    } finally { $p.Dispose() }
}
try {
    Put (Join-Path $fixtureApp 'Engine\BackupRclone.psm1') $module
    Put (Join-Path $fixtureApp 'Engine\empty.conf') ''
    foreach ($name in 'Backup-AudionArchives.ps1','Sync-AudionBackup.ps1') {
        Put (Join-Path $fixtureApp ('Engine\Scripts\'+$name)) ([IO.File]::ReadAllText((Join-Path $AppRoot ('Engine\Scripts\'+$name))))
    }
    foreach ($case in 'rotate','partial','same-day','empty','list-fail','upload-fail','verify-fail','old-list-fail','wrong-file','null-entry','selected','keep-zero','kind-missing','foreign-file') {
        $root=Join-Path $stand $case; $release=Join-Path $root 'release'; $remote=Join-Path $root 'remote'
        $oldFile=Join-Path $remote ($yesterday+'\_archives_private_full\Alpha_v1_Full.zip')
        Put $oldFile 'old alpha'
        [void][IO.Directory]::CreateDirectory((Join-Path $release '_archives_private_full'))
        if ($case -ne 'empty') { Put (Join-Path $release '_archives_private_full\Alpha_v2_Full.zip') 'new alpha' }
        if ($case -in 'partial','same-day','empty') {
            $oldFile=Join-Path $remote ($(if($case -eq 'partial'){$yesterday}else{$today})+'\_archives_private_full\Beta_v1_Full.zip')
            Put $oldFile 'unique beta'
        }
        if ($case -eq 'kind-missing') { $oldFile=Join-Path $remote ($yesterday+'\_archives_private_git\Alpha_v1.zip'); Put $oldFile 'git alpha' }
        if ($case -eq 'foreign-file') { $oldFile=Join-Path $remote ($yesterday+'\manual.txt'); Put $oldFile 'keep manual' }
        if ($case -eq 'selected') {
            Put (Join-Path $release '_archives_private_full\Beta_v2_Full.zip') 'new beta'
            Put (Join-Path $release '_archives_private_full\Gamma_v2_Full.zip') 'not selected'
        }
        $argsList=@('-ArchiveRoot',$release,'-Remote',$remote,'-Publish')
        if ($case -eq 'selected') { $argsList+=@('-ProjectName','Alpha,Beta') }
        if ($case -eq 'keep-zero') { $argsList+=@('-Keep','0') }
        $code=Run-Case $case 'Backup-AudionArchives.ps1' $argsList $case
        if ($case -in 'same-day','empty','list-fail','upload-fail','verify-fail','wrong-file','null-entry','keep-zero') {
            Check ($code -ne 0) "$case refuses an unsafe run"
        } else { Check ($code -eq 0) "$case backup completes" }
        Check ((Test-Path -LiteralPath $oldFile) -eq ($case -ne 'rotate')) "$case retains every archive not safely superseded"
        $calls=@(); if(Test-Path (Join-Path $root 'calls.txt')){$calls=@(Get-Content (Join-Path $root 'calls.txt'))}
        if ($case -in 'same-day','empty','list-fail','keep-zero') { Check ($calls -notcontains 'sync') "$case does not start upload" }
        if ($case -eq 'rotate') {
            Check (($calls -join ',') -eq 'lsf,sync,lsjson,lsjson,delete') 'rotation uploads, verifies, checks old contents, then deletes'
        }
        if ($case -eq 'selected') {
            Check (Test-Path (Join-Path $remote ($today+'\_archives_private_full\Beta_v2_Full.zip'))) 'comma-separated selection uploads both projects'
            Check (-not(Test-Path (Join-Path $remote ($today+'\_archives_private_full\Gamma_v2_Full.zip')))) 'selection does not upload other projects'
        }
    }
    foreach ($case in 'mirror-ok','unusable','bad-checksum','empty-checksum') {
        $root=Join-Path $stand $case; $data=Join-Path $root 'data'
        Put (Join-Path $data 'config\mirror.json') '{"sources":[{"folder":"Mirror","from":"snapshot","part":"fixture.tar.gz","mirror":true,"note":"fixture"}]}'
        $old=Join-Path $data ('Snapshots\audion-main-server-recovery-'+$yesterday+'.tar.gz')
        $current=Join-Path $data ('Snapshots\audion-main-server-recovery-'+$today+'.tar.gz')
        $future=Join-Path $data ('Snapshots\audion-main-server-recovery-'+$tomorrow+'.tar.gz')
        Put $old 'old snapshot'; Put ($old+'.sha256') 'old sum'; Put $current 'good current'; Put $future 'newer snapshot'
        Put (Join-Path $data 'Snapshots\manual.txt') 'manual note'
        Put (Join-Path $data 'Snapshots\other-recovery.tar.gz') 'other archive'
        Put (Join-Path $data 'Mirror\old.txt') 'old mirror'
        Put (Join-Path $data 'Mirror\.git\keep.txt') 'git history'
        $download=Join-Path $root 'download\audion-main-server-recovery.tar.gz'
        Put $download 'new synthetic snapshot'
        $sum=(Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash
        if($case -eq 'bad-checksum'){$sum='0'*64}; if($case -eq 'empty-checksum'){$sum=''}
        Put ($download+'.sha256') $sum
        $code=Run-Case $case 'Sync-AudionBackup.ps1' @('-Root',$data) $case
        $ok=$case -eq 'mirror-ok'
        Check (($code -eq 0) -eq $ok) "$case accepts only a validated snapshot"
        Check ((Test-Path $old) -eq (-not $ok)) "$case rotates old snapshots only after validation"
        Check ((Test-Path ($old+'.sha256')) -eq (-not $ok)) "$case treats old checksum as part of the owned snapshot"
        Check (Test-Path $future) "$case keeps a newer local snapshot"
        Check (Test-Path (Join-Path $data 'Snapshots\manual.txt')) "$case keeps manually stored files"
        Check (Test-Path (Join-Path $data 'Snapshots\other-recovery.tar.gz')) "$case keeps archives with other names"
        Check (Test-Path (Join-Path $data 'Mirror\.git\keep.txt')) "$case preserves .git during MIR"
        Check ((Test-Path (Join-Path $data 'Mirror\old.txt')) -eq (-not $ok)) "$case runs MIR only with a validated source"
        if (-not $ok) { Check (([IO.File]::ReadAllText($current)) -eq 'good current') "$case preserves the previous snapshot of the same date" }
    }
    Write-Host 'Backup safety checks passed using local fixtures only.'
} finally {
    $resolved=[IO.Path]::GetFullPath($stand)
    $allowed=[IO.Path]::GetFullPath($runtime).TrimEnd('\')+'\backup-safety-'
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
