<#
.SYNOPSIS
    Audion Sync Tools - private archives of the Build stack into the backup bucket.

.DESCRIPTION
    Private projects never go to the shelf or to GitHub: the publisher refuses
    a `_archives_private_*` folder on purpose. They still need to survive a dead
    disk, and this is where they go - `audion-backup/Projects/<date>`, the same
    layout the earlier hand-made snapshots used.

    One snapshot is kept when it covers every old project and archive kind.
    The new one goes up first and is checked against local file paths and sizes;
    only when it matches do safely replaced older dates come down. Clearing
    the folder before the upload would leave no copy at all for the twenty
    minutes the transfer takes, and a transfer is exactly the thing that gets
    interrupted.

    Nothing here is a publication: no card, no release, no repository. The
    archives are copied as they are, and the bucket is not a distribution point
    - it is the place a rebuilt machine reads from.

    -Status changes nothing and only reads. Run it first.

.PARAMETER ArchiveRoot
    The release root holding `_archives_private_full` and `_archives_private_git`.

.PARAMETER Remote
    Bucket path without the date. Defaults to `r2:audion-backup/Projects`.

.PARAMETER Keep
    How many dated snapshots to leave, newest first. One by default - the
    rotation the owner asked for; two while a new build is still unproven.

.EXAMPLE
    backup.cmd -ArchiveRoot 'E:\Releases' -Status
    backup.cmd -ArchiveRoot 'E:\Releases' -Publish
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArchiveRoot,
    [string[]]$ProjectName = @(),
    [string]$Remote = 'r2:audion-backup/Projects',
    [ValidateRange(1, 2147483647)][int]$Keep = 1,
    [switch]$Status,
    [switch]$Publish,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking

if (-not $Status -and -not $Publish) { $Status = $true }

$root = [System.IO.Path]::GetFullPath($ArchiveRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    Write-Host ('[ERROR] Archive root not found: {0}' -f $root) -ForegroundColor Red
    exit 2
}

$folders = @('_archives_private_full', '_archives_private_git') |
    ForEach-Object { Join-Path $root $_ } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Container }

if (-not $folders.Count) {
    Write-Host ('[ERROR] No private archive folders under {0}' -f $root) -ForegroundColor Red
    exit 2
}

$rclone = Find-AbkRclone -AppRoot $AppRoot
if (-not $rclone) {
    Write-Host '[ERROR] rclone not found. Run the builder to install it.' -ForegroundColor Red
    exit 3
}

$configArgs = Get-AbkRcloneArgs -AppRoot $AppRoot -EnsureDirectories
# The token is scoped to objects, so rclone must not probe the bucket itself.
$safety = @('--s3-no-check-bucket')
$day = (Get-Date).ToString('yyyy-MM-dd')
$target = ('{0}/{1}' -f $Remote.TrimEnd('/'), $day)

function Invoke-Rclone {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    $command = @($rclone) + $configArgs + $Arguments + $safety
    return Invoke-AbkRcloneCommand -AppRoot $AppRoot -Command $command -PassThru:$Quiet
}

# ------------------------------------------------------------------ the plan
# Имя проекта в имени архива записано через подчёркивания: окно отдаёт
# «Audion Build Publisher», на диске лежит «Audion_Build_Publisher_v1.6.0…».
$wanted = @($ProjectName | ForEach-Object { $_ -split ',' } |
    ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } |
    ForEach-Object { ($_ -replace '\s+', '_') + '_v' } | Sort-Object -Unique)

$local = @()
foreach ($folder in $folders) {
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -File)) {
        if ($wanted.Count) {
            $mine = $false
            foreach ($prefix in $wanted) {
                if ($file.Name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $mine = $true; break }
            }
            if (-not $mine) { continue }
        }
        $local += [pscustomobject]@{
            Folder = Split-Path -Leaf $folder
            Name = $file.Name
            Bytes = $file.Length
            Path = $file.FullName
        }
    }
}

if (-not $local.Count) {
    Write-Host '[ERROR] No matching archive files; nothing uploaded or removed.' -ForegroundColor Red
    exit 2
}
$bytes = [int64]($local | Measure-Object Bytes -Sum).Sum

# Retention requires the same project AND archive kind, not merely a matching
# total file count. An unrecognised old file must never be removed implicitly.
function Get-ArchiveSlot {
    param([string]$Path)
    if ($Path -match '^(_archives_private_(?:full|git))/([^/]+)_v[0-9][^/]*\.zip(\.sha256)?$') {
        return ($Matches[1] + '/' + $Matches[2] + '/' + $Matches[3])
    }
    return ''
}
$coverage = @{}
$expectedFiles = @{}
foreach ($file in $local) {
    $relative = $file.Folder + '/' + $file.Name
    $expectedFiles[$relative] = [int64]$file.Bytes
    $slot = Get-ArchiveSlot $relative
    if ($slot) { $coverage[$slot] = $true }
}
function Read-ArchiveFiles {
    param([string]$Path)
    $result = Invoke-Rclone -Arguments @('lsjson', '--recursive', '--files-only', $Path) -Quiet
    if ($result.ExitCode -ne 0) { throw "Cannot read snapshot $Path (exit $($result.ExitCode))" }
    $payload = (@($result.Output) -join "`n").Trim()
    if (-not $payload.StartsWith('[')) { throw "Invalid snapshot listing: $Path" }
    $parsed = ConvertFrom-Json -InputObject $payload
    $items = @()
    if ($payload -notmatch '^\[\s*\]$') { $items = @($parsed) }
    foreach ($item in $items) {
        if (-not $item.Path -or $item.IsDir -or $null -eq $item.Size -or $item.Size -lt 0) {
            throw "Invalid file entry in snapshot: $Path"
        }
    }
    return ,$items
}
function Get-ArchiveBlockers {
    param([AllowEmptyCollection()][object[]]$Items)
    foreach ($item in $Items) {
        $slot = Get-ArchiveSlot ([string]$item.Path)
        if (-not $slot -or -not $coverage.ContainsKey($slot)) { [string]$item.Path }
    }
}
Write-Host '======================================================================'
Write-Host 'AUDION SYNC TOOLS - PRIVATE BACKUP'
Write-Host '======================================================================'
Write-Host ('Archive root : {0}' -f $root)
Write-Host ('Bucket path  : {0}' -f $target)
Write-Host ('Files        : {0} ({1:N1} MB)' -f $local.Count, ($bytes / 1MB))
Write-Host ('Keep         : {0} snapshot(s)' -f $Keep)
Write-Host ''

foreach ($group in ($local | Group-Object Folder)) {
    Write-Host ('  {0,-26} {1} file(s)' -f $group.Name, $group.Count)
}
Write-Host ''

# Existing snapshots: the plan says what would go, and rotation later reads the
# same list rather than deciding twice.
$listing = Invoke-Rclone -Arguments @('lsf', '--dirs-only', $Remote) -Quiet
if ($listing.ExitCode -ne 0) {
    Write-Host ('[ERROR] Cannot list snapshots (exit {0}); nothing uploaded or removed.' -f $listing.ExitCode) -ForegroundColor Red
    exit 6
}
$snapshots = @()
if ($listing.ExitCode -eq 0) {
    $snapshots = @($listing.Output |
        ForEach-Object { ([string]$_).Trim('/', ' ') } |
        Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' } |
        Sort-Object -Descending)
}
Write-Host ('Snapshots    : {0}{1}' -f ($snapshots -join ', '), $(if (-not $snapshots.Count) { 'none yet' } else { '' }))

$doomed = @($snapshots | Where-Object { $_ -ne $day } | Select-Object -Skip ([Math]::Max(0, $Keep - 1)))
if ($doomed.Count) {
    Write-Host ('May remove   : {0} (after verification and project coverage checks)' -f ($doomed -join ', '))
}
Write-Host ''

if (-not $Publish) {
    Write-Host 'Nothing sent. Add -Publish to upload.'
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 0
}

# ---------------------------------------------------------------- the upload
# sync also deletes within today's folder. Protect a more complete same-day
# snapshot before the first upload; explicit project filters preserve others.
if (-not $wanted.Count -and $snapshots -contains $day) {
    try {
        $blockers = @(Get-ArchiveBlockers -Items (Read-ArchiveFiles $target))
        if ($blockers.Count) {
            throw ('Today already contains archives absent from this root: ' + ($blockers -join ', ') + '. Use -ProjectName for a selective update.')
        }
    } catch {
        Write-Host ('[ERROR] ' + $_.Exception.Message + ' Nothing uploaded or removed.') -ForegroundColor Red
        exit 6
    }
}
$failed = 0
foreach ($folder in $folders) {
    $leaf = Split-Path -Leaf $folder
    Write-Host ('--- {0}' -f $leaf)
    # `sync`, а не `copy`: снимок должен повторять папку, а не копить её
    # историю. Пересобранный за день проект иначе ложится рядом с прежней
    # версией, и снимок перестаёт сходиться с тем, что лежит на диске.
    # Удаление здесь ограничено папкой сегодняшнего снимка.
    # Выбран проект - передаём только его файлы. Прежде фильтр жил лишь в
    # списке на экране, а `sync` получал папку целиком: при нескольких проектах
    # рядом уезжали и чужие архивы, а сверка потом сравнивала полный удалённый
    # каталог с выбранной частью локального и объявляла ошибку - когда лишнее
    # уже отправлено.
    #
    # `--include` вместо `--filter`: маска простая, а `sync` с включениями сам
    # ограничивает и удаление на той стороне тем же набором.
    $picked = @()
    foreach ($prefix in $wanted) { $picked += @('--include', ($prefix + '*')) }

    $result = Invoke-Rclone -Arguments (@('sync', $folder, ('{0}/{1}' -f $target, $leaf)) +
        $picked + @('--delete-after', '--transfers', '4', '--stats-one-line', '--stats', '30s'))
    if ($result.ExitCode -ne 0) {
        Write-Host ('    upload     : failed, exit {0}' -f $result.ExitCode) -ForegroundColor Red
        $failed++
    } else {
        Write-Host '    upload     : done'
    }
}

if ($failed) {
    Write-Host ''
    Write-Host '[ERROR] Upload failed; older snapshots are left alone.' -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 4
}

# ------------------------------------------------------------- the check
# Counted, not trusted. A copy that silently sent nothing looks exactly like a
# copy that sent everything until someone compares the two sides.
# `lsjson` вместо разбора колонок: у текстового вывода первая колонка
# выравнивается пробелами, и одна несовпавшая строка тихо превращается в
# «в корзине пусто» - ровно та ошибка, из-за которой проверка однажды
# отказалась принимать полностью залитый снимок.
# Имена и размеры сверяются по каждому файлу: одинаковые итоговые числа
# сами по себе не доказывают, что приехал именно ожидаемый набор.
$remoteBytes = 0L
$remoteFiles = 0
$matched = @{}
$verified = $true
try {
    foreach ($item in (Read-ArchiveFiles $target)) {
        # Считаем ту же область, что и передавали. Иначе выбранный проект
        # сравнивается с полной корзиной, и сверка объявляет ошибку из-за
        # чужих файлов, которых мы не касались.
        if ($wanted.Count) {
            $leafName = Split-Path -Leaf ([string]$item.Path)
            $mine = $false
            foreach ($prefix in $wanted) {
                if ($leafName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { $mine = $true; break }
            }
            if (-not $mine) { continue }
        }
        $remoteBytes += [int64]$item.Size
        $remoteFiles++
        $relative = [string]$item.Path
        if ($matched.ContainsKey($relative) -or -not $expectedFiles.ContainsKey($relative) -or
            [int64]$item.Size -ne $expectedFiles[$relative]) { $verified = $false }
        $matched[$relative] = $true
    }
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    $verified = $false
}

Write-Host ''
Write-Host ('Verified     : {0} file(s), {1:N1} MB remote against {2} file(s), {3:N1} MB local' -f `
    $remoteFiles, ($remoteBytes / 1MB), $local.Count, ($bytes / 1MB))

if (-not $verified -or $remoteFiles -ne $local.Count -or $remoteBytes -ne $bytes) {
    Write-Host '[ERROR] The snapshot does not match; older snapshots are left alone.' -ForegroundColor Red
    if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    exit 5
}

# ------------------------------------------------------------- the rotation
if ($wanted.Count -and $doomed.Count) {
    Write-Host 'Rotation     : skipped - this run covered only the selected projects'
    $doomed = @()
}

foreach ($old in $doomed) {
    $path = ('{0}/{1}' -f $Remote.TrimEnd('/'), $old)
    try {
        $blockers = @(Get-ArchiveBlockers -Items (Read-ArchiveFiles $path))
        if ($blockers.Count) {
            Write-Host ('Kept         : {0}; not replaced: {1}' -f $old, ($blockers -join ', ')) -ForegroundColor Yellow
            continue
        }
    } catch {
        Write-Host ('[WARN] Keeping {0}: {1}' -f $old, $_.Exception.Message) -ForegroundColor Yellow
        continue
    }
    # Object deletion avoids purge's bucket-versioning probe with object-only tokens.
    $result = Invoke-Rclone -Arguments @('delete', $path, '--rmdirs')
    if ($result.ExitCode -eq 0) {
        Write-Host ('Removed      : {0}' -f $old)
    } else {
        # A snapshot that would not go is not a failed backup: the new one is
        # already up and counted. Say it and finish.
        Write-Host ('[WARN] Could not remove {0} (exit {1})' -f $old, $result.ExitCode) -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host ('Backup complete: {0}' -f $target)
if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
exit 0
