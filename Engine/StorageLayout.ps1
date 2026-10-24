<# Durable DATA recovery is never stored in disposable ._runtime. Windows PS 5.1+. #>
function Assert-AbkStoragePath {
    param([string]$Root, [string]$Path)
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($base -eq [IO.Path]::GetPathRoot($base).TrimEnd('\') -or
        -not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Storage path is outside its explicit non-root workspace'
    }
    $current = $full
    while ($current.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Storage migration refuses reparse points'
            }
        }
        if ($current -eq $base) { break }
        $current = Split-Path -Parent $current
    }
    return $full
}

function Get-AbkStorageFingerprint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $rows = @()
    $items = if ($item.PSIsContainer) { @(Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) } else { @($item) }
    foreach ($entry in $items) {
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Nested storage link refused' }
        $name = if ($entry.FullName -eq $item.FullName) { '.' } else { $entry.FullName.Substring($item.FullName.Length + 1) }
        if ($entry.PSIsContainer) { $rows += 'D|' + $name }
        else { $rows += 'F|' + $name + '|' + $entry.Length + '|' + (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash }
    }
    return (($rows | Sort-Object -CaseSensitive) -join "`n")
}

function Protect-AbkStorageRecovery {
    param([string]$Path)
    [void][IO.Directory]::CreateDirectory($Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r ('*' + $sid + ':(OI)(CI)(F)') '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /Q 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect durable recovery storage' }
}

function Move-AbkStorageVerified {
    param([string]$SourceRoot, [string]$Source, [string]$TargetRoot, [string]$Target, [switch]$Exact)
    $from = Assert-AbkStoragePath $SourceRoot $Source
    $to = Assert-AbkStoragePath $TargetRoot $Target
    if (-not (Test-Path -LiteralPath $from)) { return $null }
    $before = Get-AbkStorageFingerprint $from
    if (Test-Path -LiteralPath $to) {
        if ($Exact) { throw 'Existing durable transaction conflicts with legacy storage' }
        $to += '.legacy-' + [guid]::NewGuid().ToString('N')
        [void](Assert-AbkStoragePath $TargetRoot $to)
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $to))
    $sameVolume = [IO.Path]::GetPathRoot($from) -eq [IO.Path]::GetPathRoot($to)
    if ($sameVolume) { Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop }
    else { Copy-Item -LiteralPath $from -Destination $to -Recurse -Force -ErrorAction Stop }
    if ((Get-AbkStorageFingerprint $to) -cne $before) {
        if ($sameVolume -and -not (Test-Path -LiteralPath $from)) { Move-Item -LiteralPath $to -Destination $from -ErrorAction Stop }
        throw 'Storage migration verification failed; source has not been discarded'
    }
    if (-not $sameVolume) {
        # The exact absolute source was bounded and inspected above; delete only after byte verification.
        if ((Get-AbkStorageFingerprint $from) -cne $before) { throw 'Source changed during migration; both copies retained' }
        Remove-Item -LiteralPath $from -Recurse -Force -ErrorAction Stop
    }
    [pscustomobject]@{ from = $from; to = $to; verified = $true }
}

function Move-AbkRuntimeStorage {
    param([Parameter(Mandatory)][string]$AppRoot, [Parameter(Mandatory)][string]$DataRoot, [switch]$IncludeProgram)
    $data = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $data -PathType Container)) { throw 'DATA must already exist' }
    $recovery = Assert-AbkStoragePath $data (Join-Path $data 'Recovery')
    $runtime = Assert-AbkStoragePath $data (Join-Path $data '._runtime')
    $moves = @()
    $locks = @()
    try {
        # Serialize against new SYNC ALL and refuse an old writer before moving its journal.
        [void][IO.Directory]::CreateDirectory((Join-Path $data 'config'))
        foreach ($path in @((Join-Path $data 'config\sync-all.lock'), (Join-Path $runtime 'sync-all.lock'))) {
            if ($path -like '*\._runtime\*' -and -not (Test-Path -LiteralPath $path)) { continue }
            [void](Assert-AbkStoragePath $data $path)
            try { $locks += [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch { throw 'Storage migration refused: SYNC ALL is active' }
        }
        if (Test-Path -LiteralPath $runtime) {
            $oldListings = Join-Path $runtime 'rclone-cache\bisync'
            if (Test-Path -LiteralPath $oldListings) {
                Protect-AbkStorageRecovery $recovery
                $moves += Move-AbkStorageVerified $data $oldListings $data (Join-Path $recovery 'legacy-runtime\rclone-bisync')
            }
            foreach ($item in @(Get-ChildItem -LiteralPath $runtime -Force)) {
                if ($item.Name -in @('rclone-cache', 'sync-all.lock', 'openvpn') -or $item.Name -like '*.log') { continue }
                if ($item.Name -eq 'session.conf') { $target = Join-Path $data 'config\rclone\session.conf' }
                elseif ($item.Name -eq 'bisync') { $target = Join-Path $data 'config\bisync' }
                elseif ($item.Name -match '^sync-all-\d{8}T\d{6}Z-[0-9a-f]{8}$') { $target = Join-Path $recovery ('sync-all\' + $item.Name) }
                else { $target = Join-Path $recovery ('legacy-runtime\' + $item.Name) }
                Protect-AbkStorageRecovery $recovery
                $exact = $item.Name -match '^sync-all-\d{8}T\d{6}Z-[0-9a-f]{8}$'
                $moves += Move-AbkStorageVerified -SourceRoot $data -Source $item.FullName -TargetRoot $data -Target $target -Exact:$exact
            }
        }
        if ($IncludeProgram) {
            $app = [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
            $scratch = Assert-AbkStoragePath $app (Join-Path $app '._runtime')
            if (Test-Path -LiteralPath $scratch) {
                $legacyBisync = Join-Path $scratch 'rclone-cache\bisync'
                if (Test-Path -LiteralPath $legacyBisync) {
                    Protect-AbkStorageRecovery $recovery
                    $moves += Move-AbkStorageVerified $app $legacyBisync $data (Join-Path $recovery 'legacy-program-runtime\rclone-bisync')
                }
                foreach ($item in @(Get-ChildItem -LiteralPath $scratch -Force)) {
                    if ($item.Name -in @('rclone-cache','tests','tools_stage','tools-update','app_stage','terminal','updates.json','this-machine.id') -or
                        $item.Name -like '*.log' -or $item.Name -like 'setup-answers-*') { continue }
                    if ($item.Name -eq 'bisync') { $target = Join-Path $data 'config\bisync' }
                    elseif ($item.Name -eq 'app_old') { $target = Join-Path $app 'Recovery\app-old' }
                    elseif ($item.Name -eq 'tools-aside') { $target = Join-Path $app 'Recovery\tools-aside' }
                    else { $target = Join-Path $recovery ('legacy-program-runtime\' + $item.Name) }
                    $targetRoot = if ($target.StartsWith($app + '\', [StringComparison]::OrdinalIgnoreCase)) { $app } else { $data }
                    if ($targetRoot -eq $data) { Protect-AbkStorageRecovery $recovery }
                    $moves += Move-AbkStorageVerified $app $item.FullName $targetRoot $target
                }
            }
        }
    } finally { foreach ($lock in $locks) { $lock.Dispose() } }
    if ($moves.Count) {
        $report = Join-Path $recovery ('storage-migration-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($report, (ConvertTo-Json -InputObject @($moves) -Depth 4), [Text.UTF8Encoding]::new($false))
    }
    return $moves
}
