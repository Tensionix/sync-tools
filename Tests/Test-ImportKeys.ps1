#requires -Version 5.1
[CmdletBinding()]
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$failed = 0
function Check([bool]$Ok, [string]$Message) {
    if ($Ok) { Write-Host ('PASS ' + $Message) }
    else { Write-Host ('FAIL ' + $Message); $script:failed++ }
}
function Put([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($Path.EndsWith('.ps1')))
}
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-import-force-' + [guid]::NewGuid().ToString('N'))
$fixtureApp = Join-Path $lab 'program'
$fixtureScript = Join-Path $fixtureApp 'Engine\Scripts\Import-AudionKeys.ps1'
$hostExe = (Get-Process -Id $PID).Path
$readOnlyFixture = ''
function New-Case([string]$Name) {
    $dir = Join-Path $lab $Name
    $data = Join-Path $dir 'data'
    $profile = Join-Path $dir 'profile'
    Put (Join-Path $profile 'config') "# synthetic profile`r`n"
    foreach ($key in @('a_test', 'z_test')) {
        Put (Join-Path $data ('Tunnel\Export\SSH\' + $key)) ('NEW-' + $key)
        Put (Join-Path $data ('Tunnel\Export\SSH\' + $key + '.pub')) ('public-NEW-' + $key)
    }
    Put (Join-Path $profile 'a_test') 'OLD-a_test'
    Put (Join-Path $profile 'a_test.pub') 'public-OLD-a_test'
    return @{ Dir=$dir; Data=$data; Profile=$profile; Key=(Join-Path $profile 'a_test') }
}
function Run-Import($Case, [string]$Options) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $hostExe
    $command = '[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); & ''' +
        $fixtureScript.Replace("'", "''") + ''' -Root ''' + $Case.Data.Replace("'", "''") + ''' ' + $Options
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables.Remove('PSModulePath')
    $info.EnvironmentVariables['ABK_IMPORT_TEST_PROFILE'] = $Case.Profile
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Import fixture timed out' }
        $output = $stdout.Result + $stderr.Result
        Put (Join-Path $Case.Dir 'run.log') $output
        return @{ Exit=$process.ExitCode; Output=$output }
    } finally { $process.Dispose() }
}
try {
    $source = [IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Import-AudionKeys.ps1'))
    $anchor = '$SshDir = Join-Path $HOME ''.ssh'''
    if ([regex]::Matches($source, [regex]::Escape($anchor)).Count -ne 1) { throw 'Profile isolation anchor changed' }
    # Run the entire script with both profile writes and legacy host discovery isolated.
    $source = $source.Replace($anchor, '$SshDir = $env:ABK_IMPORT_TEST_PROFILE')
    $lookup = 'Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $Root'
    if ([regex]::Matches($source, [regex]::Escape($lookup)).Count -ne 1) { throw 'SSH discovery isolation anchor changed' }
    Put $fixtureScript ($source.Replace($lookup, $lookup + ' -SshConfig $SshConfig'))
    foreach ($name in @('Secrets.ps1', 'Targets.ps1', 'DataRoot.ps1', 'SshProfile.ps1')) {
        Copy-Item -LiteralPath (Join-Path $AppRoot ('Engine\' + $name)) -Destination (Join-Path $fixtureApp ('Engine\' + $name))
    }
    . (Join-Path $AppRoot 'Engine\Secrets.ps1')

    $case = New-Case 'identical-readonly'
    Put $case.Key 'NEW-a_test'
    Put (Join-Path $case.Profile 'a_test.pub') 'public-NEW-a_test'
    (Get-Item -LiteralPath $case.Key).LastWriteTimeUtc = [datetime]'2020-01-02T03:04:05Z'
    if (-not (Protect-AbkSshPrivateKey $case.Key)) { throw 'Cannot protect fixture' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $case.Key /grant:r ('*' + $sid + ':R') /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot make fixture read-only' }
    $readOnlyFixture = $case.Key
    $beforeAcl = (Get-Acl -LiteralPath $case.Key).Sddl
    $beforeTime = (Get-Item -LiteralPath $case.Key).LastWriteTimeUtc
    $handle = [IO.File]::Open($case.Key, 'Open', 'Read', 'Read')
    try { $result = Run-Import $case '-Force' } finally { $handle.Dispose() }
    Check ($result.Exit -eq 0) 'Force succeeds with an identical read-only key'
    Check ((Get-Acl -LiteralPath $case.Key).Sddl -eq $beforeAcl -and (Get-Item -LiteralPath $case.Key).LastWriteTimeUtc -eq $beforeTime) 'identical key keeps its ACL and modification time'
    Check (Test-Path -LiteralPath (Join-Path $case.Profile 'z_test')) 'next key is imported after the identical key'

    $case = New-Case 'changed'
    $result = Run-Import $case '-Force'
    Check ($result.Exit -eq 0 -and [IO.File]::ReadAllText($case.Key) -eq 'NEW-a_test') 'Force replaces different content of the same length'

    $case = New-Case 'kept'
    $result = Run-Import $case ''
    Check ($result.Exit -eq 0 -and [IO.File]::ReadAllText($case.Key) -eq 'OLD-a_test') 'without Force existing content stays intact'

    $case = New-Case 'dry-run'
    $beforeAcl = (Get-Acl -LiteralPath $case.Key).Sddl
    $beforeTime = (Get-Item -LiteralPath $case.Key).LastWriteTimeUtc
    $result = Run-Import $case '-Force -Check'
    Check ($result.Exit -eq 0 -and [IO.File]::ReadAllText($case.Key) -eq 'OLD-a_test' -and (Get-Acl -LiteralPath $case.Key).Sddl -eq $beforeAcl -and (Get-Item -LiteralPath $case.Key).LastWriteTimeUtc -eq $beforeTime -and -not (Test-Path -LiteralPath (Join-Path $case.Profile 'z_test'))) 'Force Check changes neither bytes, ACL, timestamps nor missing keys'

    $case = New-Case 'locked-key'
    $handle = [IO.File]::Open($case.Key, 'Open', 'Read', 'Read')
    try { $result = Run-Import $case '-Force' } finally { $handle.Dispose() }
    Check ($result.Exit -eq 1 -and $result.Output -match 'failed: 1 - import is incomplete') 'failed overwrite is reported with a nonzero exit code'
    Check ([IO.File]::ReadAllText($case.Key) -eq 'OLD-a_test' -and [IO.File]::ReadAllText((Join-Path $case.Profile 'a_test.pub')) -eq 'public-OLD-a_test') 'failed private copy leaves its public half unchanged'
    Check (Test-Path -LiteralPath (Join-Path $case.Profile 'z_test')) 'one failed key does not stop the next pair'

    $case = New-Case 'locked-credentials'
    Put (Join-Path $case.Data 'Tunnel\Export\rclone\r2.credentials') 'NEW synthetic credentials'
    $credentials = Join-Path $case.Data 'config\rclone\r2.credentials'
    Put $credentials 'OLD synthetic credentials'
    $handle = [IO.File]::Open($credentials, 'Open', 'Read', 'Read')
    try { $result = Run-Import $case '-Force' } finally { $handle.Dispose() }
    Check ($result.Exit -eq 1 -and (Test-Path -LiteralPath (Join-Path $case.Profile 'z_test')) -and [IO.File]::ReadAllText($credentials) -eq 'OLD synthetic credentials') 'one failed credential file does not stop SSH imports'
} finally {
    $resolved = [IO.Path]::GetFullPath($lab)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'abk-import-force-*') { throw 'Unsafe fixture cleanup' }
    if ($readOnlyFixture -and (Test-Path -LiteralPath $readOnlyFixture)) {
        if (-not (Protect-AbkSecret -Path $readOnlyFixture)) { throw 'Cannot restore fixture write access for cleanup' }
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
if ($failed) { throw ('Failed import checks: ' + $failed) }
Write-Host 'All import checks passed.'
