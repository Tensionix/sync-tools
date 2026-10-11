#requires -Version 5.1
param([string]$AppRoot = '')
$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $AppRoot 'Engine\OpenVpn.ps1')
$lab = Join-Path ([IO.Path]::GetTempPath()) ('abk-openvpn-' + [guid]::NewGuid().ToString('N'))
$failed = 0
$script:systemClient = ''
$script:guiProcesses = @()
function Get-AbkSystemOpenVpn { $script:systemClient }
function Get-AbkOpenVpnProcesses { @($script:guiProcesses) }
function Check($Title, [bool]$Ok) {
    if ($Ok) { Write-Host ('PASS ' + $Title) } else { Write-Host ('FAIL ' + $Title); $script:failed++ }
}
function Reject($Title, [scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Check $Title $rejected
}
function Put($Path, $Text = '') {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}
function Fixture($Name) {
    $root = Join-Path $lab $Name
    foreach ($file in @('openvpn-portable.exe','app\win10\bin\openvpn-gui.exe','app\win10\bin\openvpn.exe','app\win7\bin\openvpn-gui.exe','app\win7\bin\openvpn.exe')) {
        Put (Join-Path $root ('OpenVPN Portable\' + $file))
    }
    Put (Join-Path $root 'OpenVPN Portable\data\config\office.ovpn') 'client'
    return $root
}
try {
    $a = Fixture 'Machine A with spaces'
    $b = Fixture 'Machine B'
    $planA = Get-AbkOpenVpnPlan -DataRoot $a
    $planB = Get-AbkOpenVpnPlan -DataRoot $b
    Check 'DATA selection isolates clients and profiles' ($planA.Client.Exe.StartsWith($a + '\') -and $planB.ProfilePath.StartsWith($b + '\'))
    Check 'portable receives only an explicit profile name' (($planA.Arguments -join '|') -eq '--connect|office.ovpn')
    Check 'planning does not write settings or logs' (-not (Test-Path -LiteralPath $planA.Layout.Settings) -and -not (Test-Path -LiteralPath $planA.Client.LogDir))
    Reject 'missing DATA does not use a neighbour' { Get-AbkOpenVpnPlan -DataRoot (Join-Path $lab 'missing') }
    Reject 'external portable cannot silently read its own different config' { Get-AbkOpenVpnPlan -DataRoot $a -ClientPath $planB.Client.Exe }
    foreach ($profile in @('..\office.ovpn','C:\office.ovpn','--connect.ovpn','office.ovpn" --command exit')) {
        Reject ('profile rejects path/options: ' + $profile) { Get-AbkOpenVpnPlan -DataRoot $a -Profile $profile }
    }
    Put (Join-Path $planA.Client.ConfigDir 'other.ovpn') 'client'
    Reject 'multiple profiles require selection' { Get-AbkOpenVpnPlan -DataRoot $a }
    Save-AbkOpenVpnSelection -Plan $planA
    $saved = Get-AbkOpenVpnSettings $planA.Layout
    Check 'portable path is relative for relocation' ($saved.ClientPath -eq 'OpenVPN Portable\openvpn-portable.exe' -and $saved.Profile -eq 'office.ovpn')
    Check 'saved profile resolves ambiguity' ((Get-AbkOpenVpnPlan -DataRoot $a).Profile -eq 'office.ovpn')
    $relocated = Join-Path $lab 'Moved data'
    Copy-Item -LiteralPath $a -Destination $relocated -Recurse
    Check 'moving DATA resolves the client and profile in the new root' ((Get-AbkOpenVpnPlan -DataRoot $relocated).Client.Exe.StartsWith($relocated + '\'))

    $gui = Join-Path $lab 'Installed GUI\openvpn-gui.exe'
    Put $gui
    Put (Join-Path (Split-Path -Parent $gui) 'openvpn.exe')
    $script:systemClient = $gui
    $systemPlan = Get-AbkOpenVpnPlan -DataRoot $b
    Check 'installed client auto-detection uses the selected DATA profile' ($systemPlan.Client.Exe -eq $gui -and $systemPlan.Arguments -contains $planB.Client.ConfigDir)
    Check 'saved explicit portable selection wins over auto-detection' ((Get-AbkOpenVpnPlan -DataRoot $a).Client.Exe -eq $planA.Client.Exe)
    $script:systemClient = ''

    $same = [pscustomobject]@{ ExecutablePath = $planA.Client.Gui; CommandLine = 'openvpn-gui.exe --config_dir "' + $planA.Client.ConfigDir + '"' }
    Assert-AbkOpenVpnInstance -Plan $planA -Processes @($same)
    Check 'same running GUI can receive an idempotent connect' $true
    Reject 'same profile name in another running DATA is refused' { Assert-AbkOpenVpnInstance -Plan $planB -Processes @($same) }
    Reject 'unreadable running command line is refused' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @([pscustomobject]@{ ExecutablePath=$planA.Client.Gui; CommandLine='' }) }
    $same.CommandLine += ' --config_dir "' + $planB.Client.ConfigDir + '"'
    Reject 'last config_dir wins as it does in Portapps' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($same) }
    $owned = [pscustomobject]@{
        ProcessId = 987654; SessionId = (Get-Process -Id $PID).SessionId
        CreationDate = [datetime]'2026-01-02T03:04:05.1234567Z'
        ExecutablePath = $planA.Client.Gui; CommandLine = '"' + $planA.Client.Gui
    }
    Reject 'truncated modern GUI arguments alone do not prove DATA ownership' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($owned) }
    Save-AbkOpenVpnInstance -Plan $planA -Process $owned
    $instancePath = Join-Path (Split-Path -Parent $planA.Layout.Settings) 'audion-instance.json'
    $instanceJson = Get-Content -LiteralPath $instancePath -Raw
    Assert-AbkOpenVpnInstance -Plan $planA -Processes @($owned)
    Check 'own launch record accepts modern GUI with erased arguments' $true
    foreach ($field in @('ProcessId','SessionId','CreationDate','ExecutablePath','CommandLine')) {
        $different = $owned.PSObject.Copy()
        switch ($field) {
            'ProcessId' { $different.ProcessId++ }
            'SessionId' { $different.SessionId++ }
            'CreationDate' { $different.CreationDate = $owned.CreationDate.AddTicks(1) }
            'ExecutablePath' { $different.ExecutablePath = $planB.Client.Gui }
            'CommandLine' { $different.CommandLine += '" --config_dir "' + $planB.Client.ConfigDir + '"' }
        }
        Reject ('launch record refuses changed identity or explicit conflict: ' + $field) { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($different) }
    }
    $hidden = $owned.PSObject.Copy(); $hidden.ExecutablePath = ''
    Reject 'receipt never bypasses unreadable elevated executable identity' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($hidden) }
    $reused = $owned.PSObject.Copy(); $reused.CreationDate = $null
    Reject 'receipt requires a creation time, not PID alone' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($reused) }
    foreach ($field in @('Root','ConfigDir','ExecutablePath','Version')) {
        $changed = $instanceJson | ConvertFrom-Json
        $changed.$field = 'different'
        Put $instancePath ($changed | ConvertTo-Json)
        Reject ('receipt from another context is refused: ' + $field) { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($owned) }
    }
    Put $instancePath '{broken'
    Reject 'corrupt launch record fails closed' { Assert-AbkOpenVpnInstance -Plan $planA -Processes @($owned) }
    Put $instancePath $instanceJson
    Put $planB.Layout.Settings '{broken'
    Reject 'corrupt saved settings are not silently discarded' { Get-AbkOpenVpnPlan -DataRoot $b }

    # Real native argument round trip, using a tiny inert GUI executable.
    # No OpenVPN process, adapter, server, real profile or key is used.
    $stub = Join-Path $lab 'Argument capture\openvpn-gui.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $stub) -Force | Out-Null
    $source = @'
using System;
using System.IO;
using System.Text;
public class Capture {
    public static void Main(string[] args) {
        string output = Environment.GetEnvironmentVariable("ABK_OPENVPN_TEST_OUTPUT");
        if (!String.IsNullOrEmpty(output)) using (var writer = new StreamWriter(output, false, Encoding.UTF8))
            foreach (string arg in args) writer.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
        if (Path.GetFileName(Environment.GetCommandLineArgs()[0]) == "openvpn-gui.exe" && Array.IndexOf(args, "--connect") >= 0)
            System.Threading.Thread.Sleep(1500);
        if (Path.GetFileName(Environment.GetCommandLineArgs()[0]) == "rclone.exe") {
            string mode = Environment.GetEnvironmentVariable("ABK_OPENVPN_TEST_MODE");
            if (mode == "timeout") System.Threading.Thread.Sleep(20000);
            if (mode == "denied") { Console.Error.WriteLine("SSH key rejected"); Environment.Exit(5); }
            Console.WriteLine(mode == "invalid" ? "not json" : "[{\"Name\":\"C:\",\"IsDir\":true}]");
        }
    }
}
'@
    # Framework compiler output also runs under inbox Windows PowerShell 5.1.
    $sourcePath = Join-Path $lab 'capture.cs'
    Put $sourcePath $source
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    & $compiler /nologo /target:winexe ('/out:' + $stub) $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'Fixture compiler failed' }
    Put (Join-Path (Split-Path -Parent $stub) 'openvpn.exe')
    $profileName = 'office & test [1].ovpn'
    Put (Join-Path $planA.Client.ConfigDir $profileName) 'client'
    $capturePlan = Get-AbkOpenVpnPlan -DataRoot $a -ClientPath $stub -Profile $profileName
    $oldOutput = $env:ABK_OPENVPN_TEST_OUTPUT
    $output = Join-Path $lab 'arguments.txt'
    $env:ABK_OPENVPN_TEST_OUTPUT = $output
    try {
        $nativeId = Start-AbkOpenVpn -Plan $capturePlan
        $deadline = (Get-Date).AddSeconds(5)
        while (-not (Test-Path -LiteralPath $output) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
        $nativeArgs = @(Get-Content -LiteralPath $output | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
        Check 'native launch preserves profile names and paths with spaces/metacharacters' (($nativeArgs -join '|') -eq ($capturePlan.Arguments -join '|'))
        $nativeRecord = Get-Content -LiteralPath $instancePath -Raw | ConvertFrom-Json
        Check 'direct GUI launch records the actual process and DATA in DATA only' ($nativeRecord.ProcessId -eq $nativeId -and $nativeRecord.Root -eq $a -and $nativeRecord.ConfigDir -eq $capturePlan.Client.ConfigDir -and $nativeRecord.CreatedUtc)
        Check 'argument quoting handles terminal backslashes' ((ConvertTo-AbkOpenVpnArgument 'C:\path with spaces\') -eq '"C:\path with spaces\\"')
        $script:guiProcesses = @([pscustomobject]@{ ExecutablePath=$capturePlan.Client.Gui; CommandLine='openvpn-gui.exe --config_dir "' + $capturePlan.Client.ConfigDir + '"' })
        $recordHash = (Get-FileHash -LiteralPath $instancePath).Hash
        $forwarded = Start-AbkOpenVpn -Plan $capturePlan
        Check 'IPC launch preserves the first GUI identity record' ((Get-FileHash -LiteralPath $instancePath).Hash -eq $recordHash)
        Start-Sleep -Milliseconds 1600
        Remove-Item -LiteralPath $output
        $sent = Stop-AbkOpenVpn -Plan $capturePlan
        $nativeArgs = @(Get-Content -LiteralPath $output | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
        Check 'disconnect native IPC addresses only the selected profile' ($sent -and ($nativeArgs -join '|') -eq '--command|disconnect|office & test [1]')
        Reject 'disconnect refuses a GUI belonging to other DATA' { Stop-AbkOpenVpn -Plan $planB }
        $script:guiProcesses = @()
        Remove-Item -LiteralPath $output
        Check 'disconnect without a GUI does not launch a new client' (-not (Stop-AbkOpenVpn -Plan $capturePlan) -and -not (Test-Path -LiteralPath $output))
    } finally { $env:ABK_OPENVPN_TEST_OUTPUT = $oldOutput }

    # Real native rclone stand-in exercises output, failure and bounded waiting.
    $fakeApp = Join-Path $lab 'App'
    $rclone = Join-Path $fakeApp 'Tools\rclone\rclone.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rclone) -Force | Out-Null
    & $compiler /nologo /target:exe ('/out:' + $rclone) $sourcePath
    if ($LASTEXITCODE -ne 0) { throw 'rclone fixture compiler failed' }
    Reject 'WORK readiness does not use a neighbouring config' { Get-AbkOpenVpnWorkPlan -AppRoot $fakeApp -DataRoot $b }
    $known = Join-Path $a 'config\rclone\known_hosts'
    Put $known 'synthetic-host-key'
    $workConfig = Join-Path $a 'config\rclone\rclone.conf'
    Put $workConfig ("[work]`r`ntype = sftp`r`nhost = 192.0.2.10`r`nknown_hosts_file = " + $known)
    $workPlan = Get-AbkOpenVpnWorkPlan -AppRoot $fakeApp -DataRoot $a
    $oldMode = $env:ABK_OPENVPN_TEST_MODE
    try {
        $env:ABK_OPENVPN_TEST_MODE = ''
        $read = Read-AbkOpenVpnWork -Plan $workPlan
        Check 'WORK readiness requires a parsed rclone disk listing' ($read.Ready -and $read.Count -eq 1)
        $env:ABK_OPENVPN_TEST_MODE = 'denied'
        $read = Read-AbkOpenVpnWork -Plan $workPlan
        Check 'SSH rejection is not a successful VPN/panel result' (-not $read.Ready -and $read.Error -eq 'SSH key rejected')
        Reject 'unavailable WORK ends the bounded readiness wait' { Wait-AbkOpenVpnWork -Plan $workPlan -TimeoutSeconds 1 }
        $env:ABK_OPENVPN_TEST_MODE = 'invalid'
        Reject 'exit zero with invalid output is not a ready panel' { Read-AbkOpenVpnWork -Plan $workPlan }
        $env:ABK_OPENVPN_TEST_MODE = 'timeout'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $read = Read-AbkOpenVpnWork -Plan $workPlan -TimeoutMs 200
        Check 'hung rclone is stopped within its per-attempt deadline' (-not $read.Ready -and $clock.Elapsed.TotalSeconds -lt 4)
    } finally { $env:ABK_OPENVPN_TEST_MODE = $oldMode }
    Remove-Item -LiteralPath $known
    Reject 'missing trusted host keys cannot be silently bypassed' { Get-AbkOpenVpnWorkPlan -AppRoot $fakeApp -DataRoot $a }

    # Invoke the actual CLI configuration door, without starting the inert client.
    $entry = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Start-OpenVpn.ps1'
    $hostExe = (Get-Process -Id $PID).Path
    $result = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $entry -Root $a -Configure -ClientPath $stub -Profile $profileName -NoPause 2>&1)
    Check 'CLI saves the same selected client/profile with no connection' ($LASTEXITCODE -eq 0 -and (Get-AbkOpenVpnSettings $planA.Layout).Profile -eq $profileName)
    $snapshot = Get-FileHash -LiteralPath $planA.Layout.Settings
    $bad = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $entry -Root $a -Configure -Check -NoPause 2>&1)
    Check 'CLI invalid action leaves saved settings intact' ($LASTEXITCODE -ne 0 -and (Get-FileHash -LiteralPath $planA.Layout.Settings).Hash -eq $snapshot.Hash)
    $receipt = Join-Path $lab 'failed-action.json'
    $bad = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $entry -Root $a -Connect -Disconnect -ResultPath $receipt -NoPause 2>&1)
    $reply = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    Check 'conflicting connect/disconnect reports failure to the GUI without starting VPN' ($LASTEXITCODE -ne 0 -and $reply.Code -eq 1 -and -not $reply.Ready)

} finally {
    # Only this test's generated directory is eligible for recursive cleanup.
    $full = [IO.Path]::GetFullPath($lab)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $full) -like 'abk-openvpn-*') {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if ($failed) { Write-Host ('FAILED: ' + $failed); exit 1 }
Write-Host 'OpenVPN checks passed'; exit 0
