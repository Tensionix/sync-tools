# OpenVPN remains an external, user-managed client. No profile contents are read.
function Get-AbkOpenVpnLayout {
    param([Parameter(Mandatory)][string]$DataRoot)
    if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) { throw 'OpenVPN: select an existing DATA folder first.' }
    $root = (Get-Item -LiteralPath $DataRoot).FullName.TrimEnd('\')
    $portable = Join-Path $root 'OpenVPN Portable'
    [pscustomobject]@{
        Root = $root; Portable = $portable
        ConfigDir = Join-Path $portable 'data\config'
        LogDir = Join-Path $portable 'data\log'
        Settings = Join-Path $portable 'data\audion-client.json'
    }
}

function Get-AbkOpenVpnSettings {
    param($Layout)
    if (Test-Path -LiteralPath $Layout.Settings) {
        try { return (Get-Content -LiteralPath $Layout.Settings -Raw | ConvertFrom-Json) }
        catch { throw 'OpenVPN: invalid data\audion-client.json; settings were preserved.' }
    }
    return [pscustomobject]@{ ClientPath = ''; Profile = '' }
}

function Get-AbkSystemOpenVpn {
    # Do not search PATH or neighbouring tools/data folders.
    $folders = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    foreach ($folder in $folders) {
        $candidate = Join-Path $folder 'OpenVPN\bin\openvpn-gui.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    # A real installer may use another directory; the portable launcher also
    # writes this value, so only accept a GUI next to the matching core.
    foreach ($key in @('HKLM:\SOFTWARE\OpenVPN', 'HKLM:\SOFTWARE\WOW6432Node\OpenVPN')) {
        if (Test-Path -LiteralPath $key) {
            $folder = (Get-Item -LiteralPath $key).GetValue('')
            if ($folder) {
                $candidate = Join-Path $folder 'bin\openvpn-gui.exe'
                # Portapps is selected through its launcher, not this registry residue.
                if ($folder -match '[\\/]app[\\/]win(?:7|10)[\\/]?$') { continue }
                if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and
                    (Test-Path -LiteralPath (Join-Path $folder 'bin\openvpn.exe') -PathType Leaf)) { return $candidate }
            }
        }
    }
    return ''
}

function Resolve-AbkOpenVpnClient {
    param($Layout, [string]$ClientPath = '')
    if (-not $ClientPath) {
        $ClientPath = Get-AbkSystemOpenVpn
        if (-not $ClientPath) { $ClientPath = Join-Path $Layout.Portable 'openvpn-portable.exe' }
    } elseif (-not [IO.Path]::IsPathRooted($ClientPath)) { $ClientPath = Join-Path $Layout.Root $ClientPath }
    if (Test-Path -LiteralPath $ClientPath -PathType Container) {
        $ClientPath = Join-Path $ClientPath 'openvpn-portable.exe'
    }
    if (-not (Test-Path -LiteralPath $ClientPath -PathType Leaf)) { throw 'OpenVPN: client not found. Install OpenVPN GUI or select OpenVPN Portable in the DATA folder.' }
    $exe = (Get-Item -LiteralPath $ClientPath).FullName
    $kind = switch ([IO.Path]::GetFileName($exe)) {
        'openvpn-portable.exe' { 'Portable' }
        'openvpn-gui.exe' { 'GUI' }
        default { throw 'OpenVPN: choose openvpn-portable.exe or openvpn-gui.exe (OpenVPN Connect is a different client).' }
    }
    $configDir = $Layout.ConfigDir
    $logDir = $Layout.LogDir
    if ($kind -eq 'Portable') {
        $base = Split-Path -Parent $exe
        # Portapps appends its own config_dir LAST: it cannot be overridden.
        # Keep all connection data in the explicitly selected DATA folder.
        if (-not $base.StartsWith($Layout.Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'OpenVPN Portable: place the client inside the selected DATA folder; its launcher always uses its own data\config.'
        }
        $configDir = Join-Path $base 'data\config'
        $logDir = Join-Path $base 'data\log'
        $platform = if ([Environment]::OSVersion.Version.Major -ge 10) { 'win10' } else { 'win7' }
        $gui = Join-Path $base ('app\' + $platform + '\bin\openvpn-gui.exe')
    } else { $gui = $exe }
    $core = Join-Path (Split-Path -Parent $gui) 'openvpn.exe'
    if (-not (Test-Path -LiteralPath $gui -PathType Leaf) -or -not (Test-Path -LiteralPath $core -PathType Leaf)) {
        throw 'OpenVPN: incomplete client, openvpn-gui.exe and openvpn.exe must both be present.'
    }
    [pscustomobject]@{ Exe = $exe; Gui = $gui; Core = $core; Kind = $kind; ConfigDir = $configDir; LogDir = $logDir }
}

function Get-AbkOpenVpnPlan {
    param([Parameter(Mandatory)][string]$DataRoot, [string]$ClientPath = '', [string]$Profile = '')
    $layout = Get-AbkOpenVpnLayout $DataRoot
    $saved = Get-AbkOpenVpnSettings $layout
    if (-not $ClientPath) { $ClientPath = [string]$saved.ClientPath }
    if (-not $Profile) { $Profile = [string]$saved.Profile }
    $client = Resolve-AbkOpenVpnClient -Layout $layout -ClientPath $ClientPath
    if (-not $Profile) {
        $files = @(Get-ChildItem -LiteralPath $client.ConfigDir -Filter '*.ovpn' -File -ErrorAction SilentlyContinue)
        if ($files.Count -ne 1) { throw 'OpenVPN: expected one .ovpn profile in data\config. Use OVPN PATH or -Profile to select one explicitly.' }
        $Profile = $files[0].Name
    }
    if ($Profile -ne [IO.Path]::GetFileName($Profile) -or $Profile -notmatch '(?i)\.ovpn$' -or $Profile -match '[\r\n"/\\:]' -or $Profile.StartsWith('-')) {
        throw 'OpenVPN: Profile must be a .ovpn filename, without a path or options.'
    }
    $profilePath = Join-Path $client.ConfigDir $Profile
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw ('OpenVPN: profile not found: ' + $profilePath) }
    $arguments = @('--connect', $Profile)
    if ($client.Kind -eq 'GUI') {
        $arguments = @('--exe_path', $client.Core, '--config_dir', $client.ConfigDir,
                       '--log_dir', $client.LogDir, '--connect', $Profile)
    }
    [pscustomobject]@{
        Layout = $layout; Client = $client; Profile = $Profile; ProfilePath = $profilePath
        Arguments = $arguments
    }
}

function Save-AbkOpenVpnSelection {
    param($Plan)
    $path = $Plan.Client.Exe
    if ($path.StartsWith($Plan.Layout.Root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $path = $path.Substring($Plan.Layout.Root.Length + 1)
    }
    $json = [pscustomobject]@{ ClientPath = $path; Profile = $Plan.Profile } | ConvertTo-Json
    $parent = Split-Path -Parent $Plan.Layout.Settings
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $tmp = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $Plan.Layout.Settings -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function ConvertTo-AbkOpenVpnArgument {
    param([string]$Value)
    # Windows CommandLineToArgvW quoting, including trailing backslashes.
    '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Get-AbkOpenVpnProcesses {
    $session = (Get-Process -Id $PID).SessionId
    @(Get-CimInstance Win32_Process -Filter "Name = 'openvpn-gui.exe'" -ErrorAction Stop |
        Where-Object { $_.SessionId -eq $session })
}

function Save-AbkOpenVpnInstance {
    param($Plan, $Process)
    # Only called for the PID returned by our own direct GUI launch. Portapps
    # returns a wrapper PID, which must never be mistaken for the GUI.
    if (-not $Process.ProcessId -or -not $Process.CreationDate -or
        $Process.SessionId -ne (Get-Process -Id $PID).SessionId) {
        throw 'OpenVPN: could not record the launched GUI identity; check the tray.'
    }
    $record = [ordered]@{
        Version = 1; ProcessId = $Process.ProcessId; SessionId = $Process.SessionId
        CreatedUtc = ([datetime]$Process.CreationDate).ToUniversalTime().ToString('o')
        ExecutablePath = $Plan.Client.Gui; ConfigDir = $Plan.Client.ConfigDir
        Root = $Plan.Layout.Root
    }
    $parent = Split-Path -Parent $Plan.Layout.Settings
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $tmp = Join-Path $parent ([guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination (Join-Path $parent 'audion-instance.json') -Force
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Test-AbkOpenVpnInstanceRecord {
    param($Plan, $Process)
    # Modern GUI versions can leave CIM with only the executable name.
    # A saved selection alone cannot prove ownership.
    try {
        $path = Join-Path (Split-Path -Parent $Plan.Layout.Settings) 'audion-instance.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if (-not $Process.ProcessId -or -not $Process.CreationDate) { return $false }
        # PS 7 decodes ISO JSON dates as DateTime; PS 5.1 keeps the string.
        # Compare the exact UTC instant in both hosts, without losing subsecond precision.
        $created = if ($record.CreatedUtc -is [datetime]) { $record.CreatedUtc } else {
            [datetime]::ParseExact([string]$record.CreatedUtc, 'o',
                [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        $sameCreation = $created.ToUniversalTime().Ticks -eq ([datetime]$Process.CreationDate).ToUniversalTime().Ticks
        return ($record.Version -eq 1 -and $record.ProcessId -eq $Process.ProcessId -and
            $record.SessionId -eq $Process.SessionId -and
            $sameCreation -and
            [string]::Equals($record.ExecutablePath, $Plan.Client.Gui, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($record.ConfigDir, $Plan.Client.ConfigDir, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals($record.Root, $Plan.Layout.Root, [StringComparison]::OrdinalIgnoreCase))
    } catch { return $false }
}

function Assert-AbkOpenVpnInstance {
    param($Plan, [object[]]$Processes)
    foreach ($p in $Processes) {
        # A second GUI forwards only the profile NAME to the first instance.
        # Refuse a GUI from another data set, even if it has the same filename.
        $dir = ''
        foreach ($m in [regex]::Matches([string]$p.CommandLine, '(?i)--config_dir\s+(?:"([^"]+)"|(\S+))')) {
            $dir = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        }
        # An explicit conflicting directory always wins over a receipt. When
        # arguments were erased, require PID + creation time + session + DATA.
        $sameDirectory = if ($dir) {
            [string]::Equals([IO.Path]::GetFullPath($dir).TrimEnd('\'), $Plan.Client.ConfigDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
        } else { Test-AbkOpenVpnInstanceRecord -Plan $Plan -Process $p }
        if (-not $sameDirectory -or -not $p.ExecutablePath -or
            -not [string]::Equals([string]$p.ExecutablePath, $Plan.Client.Gui, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'OpenVPN GUI is already open with another or unknown config folder. Close it yourself before selecting this DATA folder; its connections were not changed.'
        }
    }
}

function Start-AbkOpenVpn {
    param($Plan, [switch]$Elevate)
    $running = @(Get-AbkOpenVpnProcesses)
    Assert-AbkOpenVpnInstance -Plan $Plan -Processes $running
    New-Item -ItemType Directory -Path $Plan.Client.LogDir -Force | Out-Null
    $arguments = @($Plan.Arguments | ForEach-Object { ConvertTo-AbkOpenVpnArgument $_ }) -join ' '
    # OpenVPN owns its tray, UAC and connection lifecycle; GUI closure / STOP
    # in Audion must not disconnect the user's corporate VPN.
    $extra = @{}
    # The shell elevation broker launches the external client independently of
    # Audion's child-process job. The client may need UAC for its TAP adapter.
    if ($Elevate) { $extra.Verb = 'RunAs' }
    $process = Start-Process -FilePath $Plan.Client.Exe -ArgumentList $arguments `
        -WorkingDirectory (Split-Path -Parent $Plan.Client.Exe) -WindowStyle Normal -PassThru @extra
    try {
        if (-not $running.Count -and $Plan.Client.Kind -eq 'GUI') {
            $owned = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $process.Id) -ErrorAction Stop
            if ($process.HasExited -or -not $owned -or $owned.Name -ne 'openvpn-gui.exe' -or
                ($owned.ExecutablePath -and $owned.ExecutablePath -ne $Plan.Client.Gui)) {
                throw 'OpenVPN: the launched GUI exited or could not be identified; check the tray.'
            }
            Save-AbkOpenVpnInstance -Plan $Plan -Process $owned
        }
        # A second GUI only forwards IPC and exits: retain the first receipt.
        return $process.Id
    } finally { $process.Dispose() }
}

function Stop-AbkOpenVpn {
    param($Plan)
    $running = @(Get-AbkOpenVpnProcesses)
    Assert-AbkOpenVpnInstance -Plan $Plan -Processes $running
    if (-not $running.Count) { return $false }
    # Use the GUI's named IPC command. Never kill a process or disconnect_all.
    $args = @('--command', 'disconnect', [IO.Path]::GetFileNameWithoutExtension($Plan.Profile))
    $quoted = @($args | ForEach-Object { ConvertTo-AbkOpenVpnArgument $_ }) -join ' '
    $process = Start-Process -FilePath $Plan.Client.Gui -ArgumentList $quoted `
        -WorkingDirectory (Split-Path -Parent $Plan.Client.Gui) -WindowStyle Hidden -PassThru
    try {
        if (-not $process.WaitForExit(10000)) { throw 'OpenVPN: disconnect command did not return; check the tray.' }
        if ($process.ExitCode -ne 0) { throw ('OpenVPN: disconnect command failed, exit=' + $process.ExitCode) }
    } finally { $process.Dispose() }
    return $true
}

function Get-AbkOpenVpnWorkPlan {
    param([string]$AppRoot, [string]$DataRoot)
    $config = Join-Path $DataRoot 'config\rclone\rclone.conf'
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw 'WORK: configure RCLONE.CONF in SETUP first (selected DATA has no rclone.conf).' }
    $section = ''; $work = @{}
    foreach ($line in [IO.File]::ReadAllLines($config)) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') { $section = $Matches[1]; continue }
        if ($section -eq 'work' -and $line -match '^\s*([^#;=\s]+)\s*=\s*(.*?)\s*$') { $work[$Matches[1]] = $Matches[2] }
    }
    if ($work.type -ne 'sftp' -or -not $work.host -or $work.host -match '\{\{') {
        throw 'WORK: complete the [work] SFTP remote in RCLONE.CONF first.'
    }
    # The panel's own trust file must already exist. Do not collect or accept
    # new server keys merely because the VPN could reach an address.
    $known = [string]$work.known_hosts_file
    if ($known.StartsWith('~/') -or $known.StartsWith('~\')) { $known = Join-Path $HOME $known.Substring(2) }
    if (-not $known -or -not [IO.Path]::IsPathRooted($known) -or -not (Test-Path -LiteralPath $known -PathType Leaf)) {
        throw 'WORK: the SFTP remote needs an existing trusted known_hosts_file.'
    }
    $exe = Join-Path $AppRoot 'Tools\rclone\rclone.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'WORK: bundled rclone was not found.' }
    [pscustomobject]@{ Exe = $exe; Config = $config; DataRoot = $DataRoot }
}

function Read-AbkOpenVpnWork {
    param($Plan, [ValidateRange(100,20000)][int]$TimeoutMs = 10000)
    # The same DATA remote and lsjson listing as the file panels; no SSH tunnel,
    # no writes and no replacement host, user, key or host-key checking options.
    $args = @('--config', $Plan.Config, '--ask-password=false', '--contimeout', '5s',
        '--timeout', '8s', '--retries', '1', '--low-level-retries', '1', 'lsjson', 'work:/', '--dirs-only')
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Plan.Exe
    $psi.Arguments = @($args | ForEach-Object { ConvertTo-AbkOpenVpnArgument $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start(); $p.StandardInput.Close()
        $output = $p.StandardOutput.ReadToEndAsync(); $errors = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutMs)) {
            $p.Kill(); [void]$p.WaitForExit(1000)
            return [pscustomobject]@{ Ready = $false; Count = 0; Error = 'WORK: rclone listing timed out.' }
        }
        if (-not $output.Wait(1000) -or -not $errors.Wait(1000)) { throw 'WORK: rclone output did not close.' }
        if ($p.ExitCode -ne 0) { return [pscustomobject]@{ Ready = $false; Count = 0; Error = $errors.Result.Trim() } }
        $text = $output.Result.Trim()
        if (-not $text.StartsWith('[')) { throw 'WORK: rclone returned an invalid directory listing.' }
        $rows = @($text | ConvertFrom-Json)
        return [pscustomobject]@{ Ready = $true; Count = $rows.Count; Error = '' }
    } finally { $p.Dispose() }
}

function Wait-AbkOpenVpnWork {
    param($Plan, [ValidateRange(1,180)][int]$TimeoutSeconds = 90)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $last = 'WORK: waiting for the VPN and SFTP access.'
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $left = [int](($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000)
        if ($left -lt 100) { break }
        $read = Read-AbkOpenVpnWork -Plan $Plan -TimeoutMs ([Math]::Min(10000, $left))
        if ($read.Ready) { return $read }
        if ($read.Error) { $last = $read.Error }
        if ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Milliseconds 500 }
    }
    throw ('WORK: disks are not available through rclone yet. VPN was left running. ' + $last)
}
