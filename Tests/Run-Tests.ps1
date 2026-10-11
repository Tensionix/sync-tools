# Every Tests\Test-*.ps1 under one PowerShell, as the builder runs them: -File, the exit code decides.
#
# By default the PowerShell is the one the program carries (App\AudionPs.exe), started the way the
# window starts it - without the module path of the shell that called it: a test started from an
# installed pwsh inherits that shell's modules and finds commands the program itself would not.
#
#   Tests\Run-Tests.ps1                      all tests under App\AudionPs.exe
#   Tests\Run-Tests.ps1 -Only Cli,Targets    the named ones
#   Tests\Run-Tests.ps1 -Shell pwsh.exe      the same under another PowerShell, to compare
#
# What every test printed is kept in ._runtime\tests\<shell>\<test>.log; here - one line a test.
param(
    [string]$Shell = '',
    [string[]]$Only = @(),
    [int]$Timeout = 300
)
$ErrorActionPreference = 'Stop'
# Started with -File, "Cli,Targets" arrives as one word: the names are taken apart here.
# A name is taken as "Cli", "Test-Cli" or "Test-Cli.ps1" alike.
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { ($_.Trim() -replace '^Test-', '') -replace '[.]ps1$', '' } | Where-Object { $_ })
$root = Split-Path -Parent $PSScriptRoot
if (-not $Shell) { $Shell = Join-Path $root 'App\AudionPs.exe' }
$found = Get-Command $Shell -ErrorAction SilentlyContinue
if (-not $found) { throw "No such PowerShell: $Shell" }
$exe = $found.Source
$logs = Join-Path $root ('._runtime\tests\' + [IO.Path]::GetFileNameWithoutExtension($exe))
New-Item -ItemType Directory -Force -Path $logs | Out-Null

$console = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$failed = 0
$ran = 0
foreach ($test in Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name) {
    $name = $test.BaseName -replace '^Test-', ''
    if ($Only.Count -and $Only -notcontains $name) { continue }
    $ran++
    $info = New-Object System.Diagnostics.ProcessStartInfo $exe
    foreach ($argument in '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $test.FullName) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # A PowerShell whose output is redirected writes in the code page of the console (866 here), not in UTF-8.
    $info.StandardOutputEncoding = $console
    $info.StandardErrorEncoding = $console
    $info.WorkingDirectory = $root
    [void]$info.Environment.Remove('PSModulePath')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $code = 'timeout'
    if ($process.WaitForExit($Timeout * 1000)) { $code = $process.ExitCode } else { try { $process.Kill($true) } catch {} }
    $watch.Stop()
    [IO.File]::WriteAllText((Join-Path $logs ($test.BaseName + '.log')), $out.Result + $err.Result, (New-Object Text.UTF8Encoding $true))
    $ok = "$code" -eq '0'
    if (-not $ok) { $failed++ }
    '{0}  {1,-18} {2,5:N1} s{3}' -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $name, $watch.Elapsed.TotalSeconds, $(if ($ok) { '' } else { "   exit $code" })
}
''
# Names that fit no test are a failure: "all passed" over zero tests once passed for a check (05.10.2026).
if ($ran -eq 0) { "no test was run: nothing is named $($Only -join ', ')"; exit 1 }
if ($failed) { "failed: $failed · logs: $logs"; exit 1 }
"all passed: $ran · logs: $logs"
exit 0
