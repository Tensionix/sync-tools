# Shared process lifecycle for an already configured REVERSE SSH TUN.
# This file never registers keys or changes the SSH profile.
function Get-AbkLocalBeaconName {
    param([string]$DataRoot)
    $name = "$env:COMPUTERNAME".ToLowerInvariant()
    if ($DataRoot) {
        $receipt = Join-Path $DataRoot 'Tunnel\beacon-startup.json'
        $identity = Join-Path $DataRoot 'Tunnel\SSHD\identity.json'
        if (Test-Path -LiteralPath $receipt) { $name = [string](([IO.File]::ReadAllText($receipt) | ConvertFrom-Json).Name) }
        elseif (Test-Path -LiteralPath $identity) {
            $saved = [IO.File]::ReadAllText($identity) | ConvertFrom-Json
            if ($saved.SavedComputer) { $name = ([string]$saved.SavedComputer).ToLowerInvariant() }
        }
    }
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid local SSH TUN identity' }
    return $name
}

function Get-AbkBeaconLaunchSpec {
    param([string]$DataRoot, [string]$Name, [switch]$IncludeDisabled)
    if (-not $Name) { $Name = Get-AbkLocalBeaconName -DataRoot $DataRoot }
    if (-not $DataRoot -or $Name -notmatch '^[A-Za-z0-9_-]+$') { return $null }
    $receipt = Join-Path $DataRoot 'Tunnel\beacon-startup.json'
    if (-not $IncludeDisabled -and (Test-Path -LiteralPath $receipt)) {
        $localChannel = [IO.File]::ReadAllText($receipt) | ConvertFrom-Json
        if ($localChannel.Name -eq $Name -and $localChannel.Enabled -eq $false) { return $null }
    }
    $root = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $dir = Join-Path $root 'Tunnel\SSH\beacon'
    $file = Join-Path $dir ($Name + '.beacon.json')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $saved = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if (-not $IncludeDisabled -and $saved.PSObject.Properties['AutoStart'] -and -not $saved.AutoStart) { return $null }
    if ($saved.Name -and $saved.Name -ne $Name) { throw 'REVERSE SSH TUN: state belongs to another machine' }
    if ([int]$saved.Port -lt 1 -or [int]$saved.Port -gt 65535 -or -not $saved.User -or -not @($saved.Servers | Where-Object { $_ }).Count) {
        throw 'REVERSE SSH TUN: incomplete saved configuration'
    }
    foreach ($field in 'KeyFile','SshConfig') {
        $path = [string]$saved.$field
        if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { throw ('REVERSE SSH TUN: missing ' + $field) }
        $full = [IO.Path]::GetFullPath($path)
        if (-not $full.StartsWith(($dir + '\'), [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw ('REVERSE SSH TUN: invalid ' + $field + ': ' + $path) }
    }
    [pscustomobject]@{ Name=$Name; Root=$root; File=$file; State=$saved }
}

function Get-AbkBeaconRuntimeProcesses {
    param([string]$Name, [string]$DataRoot)
    $namePattern = '-Name\s+"?' + [regex]::Escape($Name) + '"?(\s|$)'
    $rootPattern = '-Root\s+"?' + [regex]::Escape($DataRoot.TrimEnd('\')) + '[\\]?"?(\s|$)'
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*Setup-SshBeacon.ps1*' -and
            $_.CommandLine -match '(?i)\s-Hold(\s|$)' -and $_.CommandLine -match $namePattern -and
            $_.CommandLine -match $rootPattern })
}

function Start-AbkBeaconRuntime {
    param([string]$AppRoot, [string]$DataRoot, [string]$Name)
    $spec = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot -Name $Name
    if (-not $spec) { return $null }
    $Name = $spec.Name
    if (@(Get-AbkBeaconRuntimeProcesses -Name $Name -DataRoot $spec.Root).Count) { return $null }
    # Use one known Windows host, independent of whichever pwsh is in PATH.
    # This choice does not fix or explain the reported Process.Start(ssh)
    # failure: the hidden worker failed under both PS 7.6 and PS 5.1, whereas
    # a contained ssh -V succeeded in an ordinary PS 5.1 console.
    $systemDirectory = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemDirectory = 'Sysnative' }
    $exePath = Join-Path $env:SystemRoot ($systemDirectory + '\WindowsPowerShell\v1.0\powershell.exe')
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw ('REVERSE SSH TUN: Windows PowerShell не найден: ' + $exePath) }
    $scriptPath = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
    $logs = Join-Path $AppRoot 'logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    $tag = 'ssh-beacon-{0}-worker-{1}-{2}' -f $Name,(Get-Date).ToString('yyyyMMdd-HHmmss'),[guid]::NewGuid().ToString('N').Substring(0,8)
    $outLog = Join-Path $logs ($tag + '.out.log')
    $errLog = Join-Path $logs ($tag + '.err.log')
    $traceLog = Join-Path $logs ($tag + '.trace.log')
    Write-AbkBeaconTrace -Path $traceLog -Stage 'launcher.start' -Detail ('PowerShell=' + $exePath + '; host=WindowsPowerShell')
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Hold -Name {1} -Root "{2}" -RuntimeLog "{3}"' -f $scriptPath,$Name,$spec.Root,$traceLog
    $persistent = [bool]($spec.State.PSObject.Properties['Persistent'] -and $spec.State.Persistent)
    if ($persistent) {
        # WMI creates the hidden worker outside the GUI/console process tree.
        # Its own job still contains SSH children. No service or scheduled task.
        $arguments += ' -RuntimeErrorLog "{0}"' -f $errLog
        $process = Start-AbkIndependentProcess -File $exePath -Arguments $arguments -Directory $AppRoot
    } else {
        $process = Start-Process -FilePath $exePath -ArgumentList $arguments -WindowStyle Hidden `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -ErrorAction Stop
    }
    # Windows PowerShell can otherwise lose ExitCode after a fast child exit.
    try { [void]$process.Handle } catch { Write-AbkBeaconTrace -Path $traceLog -Stage 'launcher.handle.unavailable' }
    [pscustomobject]@{ Process=$process; Root=$spec.Root; Name=$Name; OutLog=$outLog; ErrLog=$errLog; TraceLog=$traceLog; Persistent=$persistent }
}

function Start-AbkIndependentProcess {
    param([string]$File, [string]$Arguments, [string]$Directory)
    $startup = New-CimInstance -ClientOnly -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 }
    $started = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = ('"{0}" {1}' -f $File, $Arguments)
        CurrentDirectory = $Directory; ProcessStartupInformation = $startup
    } -ErrorAction Stop
    if ($started.ReturnValue -ne 0) { throw ('REVERSE SSH TUN: independent launch failed, WMI=' + $started.ReturnValue) }
    $process = Get-Process -Id ([int]$started.ProcessId) -ErrorAction Stop
    [void]$process.Handle
    return $process
}

function Set-AbkBeaconStartup {
    param([string]$AppRoot, [string]$DataRoot, [string]$Name, [bool]$Enabled,
        [string]$StartupFolder = [Environment]::GetFolderPath('Startup'))
    if ($Name -notmatch '^[A-Za-z0-9_-]+$' -or -not $DataRoot) { throw 'REVERSE SSH TUN: invalid startup identity' }
    $root = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $tag = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToLowerInvariant())))).Replace('-','').Substring(0,12) }
    finally { $hash.Dispose() }
    $path = Join-Path $StartupFolder ('Audion SSH Beacon ' + $Name + '-' + $tag + '.lnk')
    $script = Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-SshBeacon.ps1'
    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Hold -Name {1} -Root "{2}"' -f $script,$Name,$root
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($path)
        # Do not overwrite or remove an unrelated shortcut that occupies our name.
        if ((Test-Path -LiteralPath $path) -and ($link.TargetPath -ne $hostExe -or $link.Arguments -ne $args)) {
            throw ('REVERSE SSH TUN: startup shortcut differs; preserved: ' + $path)
        }
        if ($Enabled) {
            $link.TargetPath = $hostExe; $link.Arguments = $args
            $link.WorkingDirectory = $AppRoot; $link.WindowStyle = 7
            $link.Description = 'Audion REVERSE SSH TUN: ' + $Name
            $link.Save()
        } elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
    # Retain the explicitly selected channel name across Windows profile loss,
    # including names that differ from COMPUTERNAME. One local receipt per DATA.
    $receipt = Join-Path $root 'Tunnel\beacon-startup.json'
    $previous = if (Test-Path -LiteralPath $receipt) { [IO.File]::ReadAllText($receipt) | ConvertFrom-Json } else { $null }
    if ($Enabled -or -not $previous -or $previous.Name -eq $Name) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $receipt) -Force | Out-Null
        [IO.File]::WriteAllText($receipt, (@{ Name=$Name; Enabled=$Enabled } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    return $path
}

function Restore-AbkBeaconStartup {
    param([string]$AppRoot, [string]$DataRoot, [string]$Name,
        [string]$StartupFolder = [Environment]::GetFolderPath('Startup'))
    if (-not $Name) {
        $Name = "$env:COMPUTERNAME".ToLowerInvariant()
        $receipt = Join-Path $DataRoot 'Tunnel\beacon-startup.json'
        $identity = Join-Path $DataRoot 'Tunnel\SSHD\identity.json'
        if (Test-Path -LiteralPath $receipt) {
            $localChannel = [IO.File]::ReadAllText($receipt) | ConvertFrom-Json
            if ($localChannel.Enabled -ne $true) { return $null }
            $Name = [string]$localChannel.Name
        } elseif (Test-Path -LiteralPath $identity) {
            $savedIdentity = [IO.File]::ReadAllText($identity) | ConvertFrom-Json
            if ($savedIdentity.SavedComputer) { $Name = ([string]$savedIdentity.SavedComputer).ToLowerInvariant() }
        }
    }
    if ($Name -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid saved machine identity' }
    # Never enumerate/start every beacon: BASE/LAPTOP may hold other machines' backups.
    $dir = Join-Path $DataRoot 'Tunnel\SSH\beacon'
    $file = Join-Path $dir ($Name + '.beacon.json')
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $saved = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if ($saved.Name -ne $Name -or $saved.Persistent -ne $true -or $saved.AutoStart -ne $true) { return $null }
    $key = Join-Path $dir ($Name + '_beacon_ed25519')
    $config = Join-Path $dir ('beacon-' + $Name + '.sshconfig')
    foreach ($path in @($key, $config)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Saved SSH TUN is incomplete' } }
    . (Join-Path $AppRoot 'Engine\Secrets.ps1')
    . (Join-Path $AppRoot 'Engine\SshProfile.ps1')
    if (-not (Protect-AbkSshPrivateKey -Path $key)) { throw 'Cannot protect restored SSH TUN key' }
    $configText = [IO.File]::ReadAllText($config)
    $cf = Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'
    if (Test-Path -LiteralPath $cf) {
        $configText = [regex]::Replace($configText, '"[^"]*cloudflared\.exe"', [Text.RegularExpressions.MatchEvaluator]{
            param($m)
            if (Test-Path -LiteralPath $m.Value.Trim('"')) { return $m.Value }
            return '"' + $cf.Replace('\','/') + '"'
        })
        [IO.File]::WriteAllText($config, $configText, [Text.UTF8Encoding]::new($false))
    }
    $null = Update-AbkSshProfileTrust -DataRoot $DataRoot -SshConfig $config
    $saved.KeyFile = $key; $saved.SshConfig = $config
    [IO.File]::WriteAllText($file, ($saved | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $null = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot -Name $Name
    $null = Set-AbkBeaconStartup -AppRoot $AppRoot -DataRoot $DataRoot -Name $Name -Enabled $true -StartupFolder $StartupFolder
    return $Name
}

function Write-AbkBeaconTrace {
    # Synchronous checkpoints survive abrupt process exit. Never log SSH
    # arguments, config contents, keys or stdout here. Diagnostics are optional.
    param([string]$Path, [string]$Stage, [string]$Detail = '')
    if (-not $Path) { return }
    try {
        $line = '[{0}] pid={1} {2} {3}{4}' -f (Get-Date).ToString('o'),$PID,$Stage,($Detail -replace '[\r\n]+',' '),[Environment]::NewLine
        [IO.File]::AppendAllText($Path,$line,[Text.UTF8Encoding]::new($false))
    } catch { } # A diagnostic write must not stop a working tunnel.
}

function Get-AbkBeaconRuntimeExit {
    param($Handle)
    [void]$Handle.Process.WaitForExit(0)
    $code = $Handle.Process.ExitCode
    $hex = 'unknown'
    if ($null -ne $code) { $hex = '0x{0:X8}' -f [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$code),0) }
    else { $code = 'unknown' }
    $detail = ''
    if (Test-Path -LiteralPath $Handle.ErrLog) { $detail = ([IO.File]::ReadAllText($Handle.ErrLog)).Trim() }
    if (-not $detail) { $detail = 'процесс завершён без сообщения об ошибке' }
    if ($hex -eq '0x40000015') { $detail += '; аварийное завершение процесса: STATUS_FATAL_APP_EXIT; см. журнал Application Windows' }
    $trace = ''
    if ($Handle.PSObject.Properties['TraceLog'] -and $Handle.TraceLog) {
        $tail = (Read-AbkBeaconSshLog -Path $Handle.TraceLog).Trim()
        if ($tail) { $trace = '; последний шаг: ' + (($tail -split '\r?\n')[-1]) }
        $trace += '; трассировка: ' + $Handle.TraceLog
    }
    'PID {0}, exit={1} ({2}): {3}; журнал: {4}{5}' -f $Handle.Process.Id,$code,$hex,$detail,$Handle.ErrLog,$trace
}

function Update-AbkBeaconRuntime {
    # Called by the GUI timer, never from the interactive setup console.
    param([hashtable]$Control, [string]$AppRoot, [string]$DataRoot, [scriptblock]$Say)
    if ($Control.Suspended) { return }
    if ($Control.SetupProcess) {
        if (-not $Control.SetupProcess.HasExited) { return }
        $Control.SetupProcess.Dispose(); $Control.SetupProcess = $null
        if ($Control.Handle -and $Control.Handle.Process.HasExited) {
            $Control.Handle.Process.Dispose(); $Control.Handle = $null
        }
        $Control.After = [datetime]::MinValue
    }
    if ($Control.Handle) {
        if ($Control.Handle.Root -ne "$DataRoot".TrimEnd('\')) {
            if (-not $Control.Handle.Persistent -and -not $Control.Handle.Process.HasExited) { $Control.Handle.Process.Kill() }
            $Control.Handle.Process.Dispose(); $Control.Handle = $null
        } elseif (-not $Control.Handle.Process.HasExited) { return }
        else {
            & $Say ('REVERSE SSH TUN: ' + (Get-AbkBeaconRuntimeExit $Control.Handle))
            $Control.Handle.Process.Dispose(); $Control.Handle = $null
            $Control.After = (Get-Date).AddSeconds(30)
        }
    }
    if (-not $DataRoot) { return }
    # Old LAPTOP remnants remain disabled. Only an explicit new persistent
    # setup opts this machine into incoming reverse access.
    if ((Split-Path -Leaf $DataRoot.TrimEnd('\')) -match '(?i)(^|[ _-])laptop($|[ _-])') {
        try { $laptop = Get-AbkBeaconLaunchSpec -DataRoot $DataRoot } catch { return }
        if (-not $laptop -or -not $laptop.State.Persistent) { return }
    }
    if ($Control.After -and (Get-Date) -lt $Control.After) { return }
    try {
        $Control.Handle = Start-AbkBeaconRuntime -AppRoot $AppRoot -DataRoot $DataRoot
        if ($Control.Handle) {
            & $Say ('REVERSE SSH TUN: GUI запустил процесс PID {0}; журнал запуска: {1}' -f $Control.Handle.Process.Id,$Control.Handle.ErrLog)
        }
    } catch {
        $Control.After = (Get-Date).AddSeconds(30)
        & $Say ('REVERSE SSH TUN: запуск не удался: ' + $_.Exception.Message)
    }
}

function Initialize-AbkBeaconLifetime {
    # This handle is private to the worker. Its death also ends ssh and proxies,
    # even when the worker has already lost its original parent console.
    if (-not ('Abk.BeaconJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Abk {
    public static class BeaconJob {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string b);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, IntPtr p, uint n);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        static IntPtr handle;
        public static bool HoldChildren() {
            if (handle != IntPtr.Zero) return true;
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return false;
            int size = IntPtr.Size == 8 ? 144 : 112;
            IntPtr info = Marshal.AllocHGlobal(size);
            bool ready = false;
            try {
                for (int i=0; i<size; i++) Marshal.WriteByte(info, i, 0);
                Marshal.WriteInt32(info, 16, 0x2000);
                ready = SetInformationJobObject(job, 9, info, (uint)size);
            } finally { Marshal.FreeHGlobal(info); }
            if (!ready || !AssignProcessToJobObject(job, GetCurrentProcess())) { CloseHandle(job); return false; }
            handle = job;
            return true;
        }
    }
}
'@
    }
    if (-not [Abk.BeaconJob]::HoldChildren()) { throw 'REVERSE SSH TUN: cannot contain child processes' }
}

function Enter-AbkBeaconRuntime {
    param([string]$DataRoot, [string]$Name)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($DataRoot).TrimEnd('\') + '|' + $Name).ToLowerInvariant())
        $tag = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally { $sha.Dispose() }
    $guard = [Threading.Mutex]::new($false, ('Local\AudionBeacon-' + $tag))
    try {
        $entered = $false
        try { $entered = $guard.WaitOne(0) } catch [Threading.AbandonedMutexException] { $entered = $true }
        if ($entered) { return $guard }
    } catch { $guard.Dispose(); throw }
    $guard.Dispose()
    return $null
}

function Read-AbkBeaconSshLog {
    param([string]$Path, [switch]$Head)
    # Allow the worker's concurrent writes; GUI reads the initial handshake,
    # so later channel traffic cannot push its acknowledgment out of the tail.
    $stream=$null; $reader=$null
    try {
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if (-not $Head -and $stream.Length -gt 65536) { [void]$stream.Seek(-65536,[IO.SeekOrigin]::End) }
        $reader=[IO.StreamReader]::new($stream)
        if ($Head) {
            $buffer=New-Object char[] 65536
            $count=$reader.ReadBlock($buffer,0,$buffer.Length)
            return [string]::new($buffer,0,$count)
        }
        return $reader.ReadToEnd()
    } catch { return '' }
    finally { if($reader){$reader.Dispose()} elseif($stream){$stream.Dispose()} }
}

function Invoke-AbkBeaconSsh {
    param([string]$File, [string[]]$Arguments, [string]$Log, [string]$TraceLog = '')
    # Windows OpenSSH locks a file opened with -E. Drain stderr asynchronously
    # and close the log after each line so diagnostics stay readable while the
    # connection is alive. SSH remains a direct child of the contained worker.
    $process=[Diagnostics.Process]::new()
    $process.StartInfo.FileName=$File
    $process.StartInfo.Arguments=(@($Arguments | ForEach-Object {
        '"' + ([regex]::Replace([regex]::Replace([string]$_, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
    }) -join ' ')
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardInput=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    try {
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.start.begin' -Detail ('file=' + $File)
        [void]$process.Start()
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.started' -Detail ('childPID=' + $process.Id)
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stdin.close.begin'
        $process.StandardInput.Close()
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stdout.read.begin'
        $output=$process.StandardOutput.ReadToEndAsync()
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stderr.read.begin'
        $pending=$process.StandardError.ReadLineAsync()
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.poll.begin'
        $ended=$false
        $exitSeen=$null
        $firstLine=$true
        while (-not $process.HasExited -or -not $ended) {
            if ($process.HasExited) {
                if (-not $exitSeen) { $exitSeen=Get-Date }
                if (((Get-Date)-$exitSeen).TotalSeconds -ge 2) { break }
            }
            if (-not $ended -and $pending.IsCompleted) {
                if ($firstLine) { Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stderr.first-result.begin' }
                $line=$pending.GetAwaiter().GetResult()
                if ($null -eq $line) { $ended=$true }
                else {
                    if ($firstLine) { Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stderr.first-write.begin' }
                    [IO.File]::AppendAllText($Log,($line + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
                    if ($firstLine) { Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.stderr.first-write.done' }
                    $pending=$process.StandardError.ReadLineAsync()
                }
                $firstLine=$false
            } else { Start-Sleep -Milliseconds 50 }
        }
        [void]$process.WaitForExit(0)
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.exited' -Detail ('childPID={0} exit={1}' -f $process.Id,$process.ExitCode)
        return $process.ExitCode
    } catch {
        Write-AbkBeaconTrace -Path $TraceLog -Stage 'ssh.exception' -Detail $_.Exception.ToString()
        throw
    } finally {
        try { if(-not $process.HasExited){$process.Kill()} } catch {}
        $process.Dispose()
    }
}
