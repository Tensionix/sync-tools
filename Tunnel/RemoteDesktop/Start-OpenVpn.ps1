#requires -Version 5.1
[CmdletBinding()]
param([string]$Root, [string]$ClientPath = '', [string]$Profile = '',
      [switch]$Configure, [switch]$Check, [switch]$Connect, [switch]$Disconnect,
      [string]$ResultPath = '', [switch]$AdminRetry, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $appRoot 'Engine\DataRoot.ps1')
. (Join-Path $appRoot 'Engine\OpenVpn.ps1')
function Select-AbkOpenVpnFile {
    <#
        The Open dialog of Windows itself (comdlg32), not the one of Windows Forms: the PowerShell
        the program carries (App\AudionPs.exe) has no Windows Forms, and the wrappers run under it.
        Returns the chosen file, or nothing when the dialog was closed.
    #>
    param([string]$Title, [string]$Filter, [string]$Folder)
    if (-not ('Abk.OpenFileDialog' -as [type])) {
        Add-Type -Namespace Abk -Name OpenFileDialog -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
struct OpenFileName
{
    public int structSize; public System.IntPtr owner; public System.IntPtr instance;
    public string filter; public string customFilter; public int maxCustomFilter; public int filterIndex;
    public System.IntPtr file; public int maxFile; public string fileTitle; public int maxFileTitle;
    public string initialDir; public string title; public int flags; public short fileOffset; public short fileExtension;
    public string defExt; public System.IntPtr custData; public System.IntPtr hook; public string templateName;
    public System.IntPtr reservedPtr; public int reservedInt; public int flagsEx;
}
[System.Runtime.InteropServices.DllImport("comdlg32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
static extern bool GetOpenFileNameW(ref OpenFileName ofn);

// The filter comes as "text|pattern", as Windows Forms takes it; the dialog wants the parts apart by a zero.
public static string Pick(string title, string filter, string folder)
{
    OpenFileName ofn = new OpenFileName();
    ofn.structSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(OpenFileName));
    ofn.filter = filter.Replace('|', '\0') + "\0\0";
    ofn.maxFile = 32768;
    ofn.file = System.Runtime.InteropServices.Marshal.AllocHGlobal(ofn.maxFile * 2);
    System.Runtime.InteropServices.Marshal.WriteInt16(ofn.file, 0);
    ofn.initialDir = folder;
    ofn.title = title;
    // explorer look, the file and the path must exist, the current folder stays, no read-only box
    ofn.flags = 0x00080000 | 0x00001000 | 0x00000800 | 0x00000008 | 0x00000004;
    try { return GetOpenFileNameW(ref ofn) ? System.Runtime.InteropServices.Marshal.PtrToStringUni(ofn.file) : null; }
    finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(ofn.file); }
}
'@
    }
    return [Abk.OpenFileDialog]::Pick($Title, $Filter, $Folder)
}

$code = 0
$result = [ordered]@{ Action = ''; Ready = $false; Message = ''; Root = ''; Code = 1 }
try {
    $data = Get-AbkDataRootPath -AppRoot $appRoot -Root $Root
    $result.Root = $data.TrimEnd('\')
    $layout = Get-AbkOpenVpnLayout $data
    if (@($Configure, $Check, $Connect, $Disconnect | Where-Object { $_ }).Count -gt 1) { throw 'OpenVPN: select one action: -Configure, -Check, -Connect or -Disconnect.' }
    if ($Configure -and -not $ClientPath) {
        $ClientPath = Select-AbkOpenVpnFile -Title 'OpenVPN Portable / OpenVPN GUI' -Filter 'OpenVPN client|openvpn-portable.exe;openvpn-gui.exe' -Folder $layout.Root
        if (-not $ClientPath) { exit 0 }
        $client = Resolve-AbkOpenVpnClient -Layout $layout -ClientPath $ClientPath
        $files = @(Get-ChildItem -LiteralPath $client.ConfigDir -Filter '*.ovpn' -File -ErrorAction SilentlyContinue)
        if (-not $Profile -and $files.Count -gt 1) {
            $chosen = Select-AbkOpenVpnFile -Title 'OpenVPN profile in the selected DATA folder' -Filter 'OpenVPN profile (*.ovpn)|*.ovpn' -Folder $client.ConfigDir
            if (-not $chosen) { exit 0 }
            if ((Split-Path -Parent $chosen) -ne $client.ConfigDir) { throw 'OpenVPN: select a profile in the displayed data\config folder.' }
            $Profile = [IO.Path]::GetFileName($chosen)
        } elseif (-not $Profile -and $files.Count -eq 1) { $Profile = $files[0].Name }
    }
    $plan = Get-AbkOpenVpnPlan -DataRoot $data -ClientPath $ClientPath -Profile $Profile
    $result.Root = $plan.Layout.Root
    $result.Action = if ($Configure) { 'configure' } elseif ($Check) { 'check' } elseif ($Disconnect) { 'disconnect' } else { 'connect' }
    # An elevated OpenVPN GUI hides its command line from a normal process.
    # Re-run only this explicit action through UAC, never guess its DATA folder.
    if (-not $Configure -and -not $Check) {
        $unknown = @(Get-AbkOpenVpnProcesses | Where-Object { -not $_.CommandLine -or -not $_.ExecutablePath })
        if ($unknown.Count) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($AdminRetry -or $admin) { throw 'OpenVPN: cannot verify the running GUI; connections were not changed.' }
            $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                '-Root', $data, '-ClientPath', $plan.Client.Exe, '-Profile', $plan.Profile, '-AdminRetry', '-NoPause')
            $args += $(if ($Disconnect) { '-Disconnect' } else { '-Connect' })
            if ($ResultPath) { $args += @('-ResultPath', $ResultPath) }
            $quoted = @($args | ForEach-Object { ConvertTo-AbkOpenVpnArgument $_ }) -join ' '
            $relay = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $quoted -Verb RunAs -WindowStyle Hidden -PassThru
            try { $relay.WaitForExit(); $relayCode = $relay.ExitCode } finally { $relay.Dispose() }
            if (-not $NoPause) { [void](Read-Host ('OpenVPN exit=' + $relayCode + '. Press Enter to close')) }
            exit $relayCode
        }
    }
    Write-Host ('OpenVPN client: ' + $plan.Client.Exe)
    Write-Host ('OpenVPN profile: ' + $plan.ProfilePath)
    Write-Host ('OpenVPN logs: ' + $plan.Client.LogDir)
    if ($Configure) {
        Save-AbkOpenVpnSelection -Plan $plan
        Write-Host 'OpenVPN: selection saved in DATA; no connection started.'
    } elseif ($Check) {
        Assert-AbkOpenVpnInstance -Plan $plan -Processes @(Get-AbkOpenVpnProcesses)
        $null = Get-AbkOpenVpnWorkPlan -AppRoot $appRoot -DataRoot $data
        Write-Host 'OpenVPN: launch prerequisites passed; connection was not tested or started.'
    } elseif ($Disconnect) {
        $sent = Stop-AbkOpenVpn -Plan $plan
        $result.Message = if ($sent) { 'OpenVPN: disconnect requested for the selected profile only.' } else { 'OpenVPN: no running GUI; no connection changed.' }
        Write-Host $result.Message
    } else {
        $work = Get-AbkOpenVpnWorkPlan -AppRoot $appRoot -DataRoot $data
        $started = Start-AbkOpenVpn -Plan $plan -Elevate
        Write-Host ('OpenVPN: start requested, PID ' + $started + '. Waiting up to 90 seconds for WORK disks through rclone...')
        $read = Wait-AbkOpenVpnWork -Plan $work
        $result.Ready = $true
        $result.Message = 'WORK: rclone read the disk list. The file panel can open WORK.'
        Write-Host $result.Message
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    $result.Message = $_.Exception.Message
    $code = 1
}
$result.Code = $code
if ($ResultPath) {
    try { [IO.File]::WriteAllText($ResultPath, ($result | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) }
    catch { Write-Host ('OpenVPN: could not return result: ' + $_.Exception.Message); $code = 1 }
}
if (-not $NoPause) { [void](Read-Host 'Press Enter to close') }
exit $code
