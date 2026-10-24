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
Export-ModuleMember -Function Find-AbkRclone,Get-AbkRcloneArgs,Invoke-AbkRcloneCommand
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
    foreach ($name in 'Backup-AudionArchives.ps1') {
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
    # SYNC ALL is tested with actual nested tar archives, Git repositories and
    # filesystem rollback in Test-LibrarySync.ps1, not a synthetic Python stub.
    Write-Host 'Backup safety checks passed using local fixtures only.'
} finally {
    $resolved=[IO.Path]::GetFullPath($stand)
    $allowed=[IO.Path]::GetFullPath($runtime).TrimEnd('\')+'\backup-safety-'
    if ($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
