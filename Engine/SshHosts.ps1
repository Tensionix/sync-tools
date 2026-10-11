# Shared SSH-KEYSCAN worker. No GUI objects or user SSH configuration writes.
function Initialize-AbkHostScanLifetime {
    # The worker owns this job. Closing/killing it also closes every ssh/proxy child.
    if (-not ('Abk.HostScanJob' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Abk {
    public static class HostScanJob {
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
    if (-not [Abk.HostScanJob]::HoldChildren()) { throw 'SSH-KEYSCAN: cannot contain child processes' }
}

function ConvertTo-AbkScanArgument {
    param([string]$Value)
    # Windows command-line quoting; no shell, so $, &, and | stay literal.
    '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-AbkHostScanBatch {
    # -Detailed: every answer is an object - output, errors, exit code and
    # whether it timed out - so a failed probe can say why (RESTORE, 26.09.2026).
    # Without it the answer is stdout of a successful process, as before.
    param([object[]]$Requests, [ValidateRange(1,30)][int]$TimeoutSeconds = 5, [switch]$Detailed)
    $pending = New-Object System.Collections.Generic.List[object]
    $results = @{}
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($request in $Requests) {
            $process = [Diagnostics.Process]::new()
            $process.StartInfo.FileName = $request.File
            $process.StartInfo.Arguments = (@($request.Arguments | ForEach-Object { ConvertTo-AbkScanArgument ([string]$_) }) -join ' ')
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardInput = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            try {
                [void]$process.Start()
                $process.StandardInput.Close()
                $pending.Add([pscustomobject]@{ Key=$request.Key; Process=$process;
                    Out=$process.StandardOutput.ReadToEndAsync(); Err=$process.StandardError.ReadToEndAsync() })
            } catch {
                $failure = $_.Exception.Message
                $process.Dispose()
                $results[$request.Key] = if ($Detailed) { [pscustomobject]@{ Out=''; Err=$failure; ExitCode=-1; TimedOut=$false } } else { '' }
            }
        }
        while ($pending.Count) {
            foreach ($item in @($pending.ToArray())) {
                if ($item.Process.HasExited -and $item.Out.IsCompleted -and $item.Err.IsCompleted) {
                    $results[$item.Key] = if ($Detailed) {
                        [pscustomobject]@{ Out=$item.Out.GetAwaiter().GetResult(); Err=$item.Err.GetAwaiter().GetResult(); ExitCode=$item.Process.ExitCode; TimedOut=$false }
                    } elseif ($item.Process.ExitCode -eq 0) { $item.Out.GetAwaiter().GetResult() } else { '' }
                    $item.Process.Dispose()
                    [void]$pending.Remove($item)
                }
            }
            if (-not $pending.Count -or $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
            Start-Sleep -Milliseconds 40
        }
    } finally {
        foreach ($item in $pending) {
            # Kill only processes created above. Their proxies also belong to the
            # worker's job and cannot survive the worker, including GUI Stop.
            try { if (-not $item.Process.HasExited) { $item.Process.Kill() } } catch { }
            $results[$item.Key] = if ($Detailed) { [pscustomobject]@{ Out=''; Err=''; ExitCode=-1; TimedOut=$true } } else { '' }
            $item.Process.Dispose()
        }
    }
    return $results
}

function Get-AbkHostScanPlan {
    param($Targets)
    # router-base: FILES ROUTER opens WinSCP only when the router key is in this
    # list, and nothing else collects it - on a clean profile it never opened.
    foreach ($key in 'base','laptop','work','home','dad','server','second','router-base') {
        $target = $Targets.$key
        if (-not $target) { continue }
        $names = @()
        foreach ($field in 'lan','host','sshHost') {
            $name = [string]$target.$field
            if ($name -and $name -notmatch '^[\-]|\s' -and $names -notcontains $name) { $names += $name }
        }
        if (-not $names.Count) { continue }
        # Both MAIN VPS routes check the key under `HostKeyAlias audion-vps`
        # (Install-TunnelClient.ps1). Only the old profile known_hosts had that
        # name, so after RESTORE on a clean profile both routes failed.
        if ($key -eq 'server' -and $names -notcontains 'audion-vps') { $names += 'audion-vps' }
        $port = 22
        if ($target.sshPort) { $port = [int]$target.sshPort }
        if ($port -lt 1 -or $port -gt 65535) { throw ('Invalid SSH port: ' + $key) }
        $who = if ($port -ne 22) { (@($names | ForEach-Object { '[{0}]:{1}' -f $_,$port }) -join ',') } else { $names -join ',' }
        $caption = switch ($key) { 'server' { 'MAIN VPS' } 'second' { 'SECOND VPS' } 'router-base' { 'ROUTER' } default { $key.ToUpperInvariant() } }
        [pscustomobject]@{ Key=$key; Caption=$caption; Host=$names[0]; Ssh=[string]$target.sshHost; Port=$port; Who=$who; Unix=($key -in @('server','second')) }
    }
}

function ConvertFrom-AbkScannedKey {
    param([string]$Text, [string]$Who)
    foreach ($line in ($Text -split '\r?\n')) {
        # Accept either ssh-keyscan output or a public host-key file, never banners.
        if ($line.Trim() -match '^(?:\S+\s+)?((?:ssh-|ecdsa-|sk-)[\w@.-]+)\s+([A-Za-z0-9+/]+={0,3})(?:\s.*)?$') {
            # DSA: the fallback reads every ssh_host_*_key.pub, sshd no longer
            # offers it, and the next direct scan reported a false key change.
            if ($Matches[1] -eq 'ssh-dss') { continue }
            '{0} {1} {2}' -f $Who,$Matches[1],$Matches[2]
        }
    }
}

function Save-AbkScannedHosts {
    param([object[]]$Plan, [hashtable]$Answers, [string]$Path, [switch]$Force, [scriptblock]$Say)
    $kept = [ordered]@{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line.Trim() -match '^(?!#)(\S+)\s+\S+\s+\S+') {
                $who = $Matches[1]
                if (-not $kept.Contains($who)) { $kept[$who] = @() }
                $kept[$who] += $line
            }
        }
    }
    $fresh=0; $held=0; $changed=0
    foreach ($item in $Plan) {
        $rows = @(ConvertFrom-AbkScannedKey -Text $Answers[$item.Key] -Who $item.Who | Sort-Object -Unique)
        if (-not $rows.Count) {
            if ($kept.Contains($item.Who)) { $held++; & $Say ($item.Caption + ': did not answer, the previous keys are kept') }
            else { & $Say ($item.Caption + ': did not answer, no keys') }
            continue
        }
        if ($kept.Contains($item.Who) -and -not $Force -and
            (@($kept[$item.Who] | Sort-Object -Unique) -join "`n") -ne ($rows -join "`n")) {
            $changed++
            & $Say ($item.Caption + ': HOST KEY CHANGED, the previous keys are kept; verify the server before accepting with Ctrl + SSH-KEYSCAN')
            continue
        }
        $kept[$item.Who]=$rows; $fresh++
        & $Say ('{0}: {1} keys collected ({2})' -f $item.Caption,$rows.Count,$item.Who)
    }
    # No write after total failure or rejected changes; preserve even original formatting.
    if ($fresh -gt 0) {
        $lines = @($kept.Values | ForEach-Object { $_ })
        $parent = Split-Path -Parent $Path
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $temp = Join-Path $parent ('known-hosts-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($temp, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
            else { [IO.File]::Move($temp,$Path) }
        } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        & $Say ('written: ' + $Path)
    }
    [pscustomobject]@{ Fresh=$fresh; Held=$held; Changed=$changed }
}

function Update-AbkHostKeys {
    param($Targets, [string]$Path, [switch]$Force, [ValidateRange(1,30)][int]$TimeoutSeconds=5,
        [scriptblock]$Say = { param($Text) Write-Host $Text })
    $plan = @(Get-AbkHostScanPlan -Targets $Targets)
    $scanner = (Get-Command ssh-keyscan.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $ssh = (Get-Command ssh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    & $Say ('SSH-KEYSCAN: {0} hosts in parallel, up to {1}s per pass' -f $plan.Count,$TimeoutSeconds)
    # Windows ssh-keyscan holds one connection to a remote sshd until -T even
    # after all keys arrived. With -T equal to the batch wait it was killed
    # together with the keys, so LAPTOP and the router never got scanned.
    $scanWait = [Math]::Max(1, $TimeoutSeconds - 2)
    $requests = @($plan | ForEach-Object { [pscustomobject]@{ Key=$_.Key; File=$scanner;
        Arguments=@('-T',[string]$scanWait,'-p',[string]$_.Port,'--',$_.Host) } })
    $answers = Invoke-AbkHostScanBatch -Requests $requests -TimeoutSeconds $TimeoutSeconds
    $fallback = @()
    foreach ($item in $plan) {
        if (@(ConvertFrom-AbkScannedKey -Text $answers[$item.Key] -Who $item.Who).Count -or -not $item.Ssh -or $item.Ssh -match '^[\-]|\s') { continue }
        $command = if ($item.Unix) { 'cat /etc/ssh/ssh_host_*_key.pub' }
            else { 'powershell.exe -NoProfile -Command "Get-Content -Path $env:ProgramData\ssh\ssh_host_*_key.pub"' }
        # The route is trusted by the key already verified for the target's own
        # name, not by the route's HostKeyAlias: MAIN VPS routes check
        # `audion-vps`, which is exactly what this scan has to write. Windows
        # ssh-keyscan 9.5 cannot finish sntrup761 KEX, so this is its only way.
        $alias = if ($item.Port -eq 22) { @('-o',('HostKeyAlias='+$item.Host)) } else { @() }
        $fallback += [pscustomobject]@{ Key=$item.Key; File=$ssh; Arguments=(@('-o','BatchMode=yes',
            '-o','StrictHostKeyChecking=yes','-o','UpdateHostKeys=no','-o','ClearAllForwardings=yes',
            '-o',('ConnectTimeout='+$TimeoutSeconds),'-o','ConnectionAttempts=1') + $alias + @('--',$item.Ssh,$command)) }
    }
    if ($fallback.Count) {
        & $Say ('SSH: checking {0} established routes in parallel' -f $fallback.Count)
        $extra = Invoke-AbkHostScanBatch -Requests $fallback -TimeoutSeconds $TimeoutSeconds
        foreach ($key in $extra.Keys) { $answers[$key]=$extra[$key] }
    }
    Save-AbkScannedHosts -Plan $plan -Answers $answers -Path $Path -Force:$Force -Say $Say
}
