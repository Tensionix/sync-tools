<#
.SYNOPSIS
    Обновляет локальные зеркала MAIN VPS в этой папке.

.DESCRIPTION
    Шесть папок рядом с этим файлом держат то, что живёт на MAIN VPS. Раньше
    каждая обновлялась своим способом и по памяти; здесь все способы собраны в
    одном месте.

    Источников два, и это не прихоть. Ночной резерв в R2 — один согласованный
    снимок: всё в нём снято в одну минуту, проверено контрольной суммой и
    годится для восстановления машины с нуля. Но код проектов туда не входит:
    он живёт в Forgejo и на самом MAIN VPS, и берётся оттуда.

    Сам снимок остаётся здесь, в `Snapshots`, — целиком и один. Разложенные
    папки удобны, чтобы читать и искать, но восстанавливают машину не они, а
    он: в нём и рецепты, и ключи, и дамп базы Forgejo.

    Старые снимки не копятся: каждый прогон оставляет последний и убирает
    прежние. История версий и так лежит в R2 bucket.

    В папки раскладывается то, что читают люди: юниты, скрипты, документы.
    Ключи из снимка туда не разбираются — не потому, что их надо прятать (они
    и так лежат в `Tunnel`), а потому что россыпью по шести папкам они
    протухают незаметно, а в архиве всегда те, что сняты в одну минуту.

.EXAMPLE
    sync-backup.cmd -WhatIf
    Показать, что будет обновлено, и ничего не трогать.

.EXAMPLE
    sync-backup.cmd
    Обновить всё: снимок из R2 плюс код с MAIN VPS и из Forgejo.

.EXAMPLE
    sync-backup.cmd -Only 'Forgejo Mirror','Audion Portal'
    Обновить только названные папки.
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string[]]$Only = @(),
    [switch]$WhatIf,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$Started = Get-Date

# Программа и данные разведены. Здесь — программа: Engine\Scripts внутри
# Audion Sync Tools. Там — зеркала, снимки и ключи: соседняя папка Audion
# Backup, если не сказано иное. Буква диска не зашита нигде.
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root) {
    . (Join-Path $AppRoot 'Engine\DataRoot.ps1')
    $Root = Get-AbkDataRootPath -AppRoot $AppRoot
}

# rclone и ключи к корзине — свои. Раньше и то и другое бралось у
# публикатора, и без него зеркало не поднималось вовсе; а подниматься оно
# должно на пустой машине первым.
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force -DisableNameChecking

$Server = 'audion-vps'
$Bucket = 'r2:audion-backup'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "===== $Text" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Text, [string]$Colour = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Colour
}

function Test-SnapshotUsable {
    <#
        Годится ли снимок: есть ли в нём каждая нужная часть и читается ли она.

        Проверка читающая: архив открывается, части перечисляются и
        просматриваются потоком, на диск не распаковывается ничего.

        Раньше здесь считались только записи внешнего архива, и любой непустой
        tar объявлялся годным - снимок с одной описью и без данных проходил, а
        следом стирались прежние. Совпавшая сумма от этого не спасает: она
        говорит, что скачанные байты равны исходным, а не что исходные годятся.
    #>
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        # Имена частей из config\mirror.json - те, что зеркало будет доставать.
        [string[]]$Parts = @()
    )

    $script = @'
import io, sys, tarfile

snapshot = sys.argv[1]
wanted = sys.argv[2:]

try:
    with tarfile.open(snapshot, "r:gz") as tar:
        names = tar.getnames()
except Exception as bad:
    print("unreadable: %s" % bad)
    raise SystemExit(2)

if not names:
    print("empty archive")
    raise SystemExit(3)

found = {}
for name in names:
    for part in wanted:
        if name.endswith("payload/" + part):
            found[part] = name

missing = [part for part in wanted if part not in found]
if missing:
    print("missing parts: %s" % ", ".join(missing))
    raise SystemExit(4)

# Каждая нужная часть открывается и просматривается потоком: обрезанный или
# подменённый кусок спотыкается здесь, а не при восстановлении машины.
counted = []
with tarfile.open(snapshot, "r:gz") as tar:
    for part in wanted:
        try:
            handle = tar.extractfile(found[part])
            with tarfile.open(fileobj=handle, mode="r|gz") as inner:
                entries = sum(1 for _ in inner)
        except Exception as bad:
            print("part unreadable: %s (%s)" % (part, bad))
            raise SystemExit(5)
        if not entries:
            print("part has nothing inside: %s" % part)
            raise SystemExit(6)
        counted.append("%s=%d" % (part, entries))

print("entries=%d parts ok: %s" % (len(names), ", ".join(counted) if counted else "none asked"))
raise SystemExit(0)
'@

    $scriptPath = Join-Path $env:TEMP ('audion-snapshot-check-' + [guid]::NewGuid().ToString('N') + '.py')
    try {
        [System.IO.File]::WriteAllText($scriptPath, $script)
        $said = & py '-3.12' $scriptPath $SnapshotPath @Parts 2>&1
        $ok = ($LASTEXITCODE -eq 0)
        Write-Note ('snapshot check: ' + (@($said) -join ' ')) $(if ($ok) { 'Gray' } else { 'Yellow' })
        return $ok
    } catch {
        Write-Note ('snapshot check failed: ' + $_.Exception.Message) 'Yellow'
        return $false
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Rclone {
    param([Parameter(Mandatory)][string[]]$Arguments)
    Invoke-AbkRclone -AppRoot $AppRoot -DataRoot $Root -Arguments $Arguments -EnsureDirectories
}

function Get-LatestSnapshotDate {
    $dates = @(Invoke-Rclone -Arguments @('lsf', "$Bucket/daily/", '--dirs-only') |
        ForEach-Object { $_.TrimEnd('/') } |
        Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}$' } |
        Sort-Object -Descending)
    if (-not $dates.Count) { throw 'the bucket holds no snapshot' }
    return $dates[0]
}

# --------------------------------------------------------------- источники

# Что откуда берётся - в config\mirror.json папки данных. В коде этого
# списка больше нет: у того, кто поставил программу себе, папки на MAIN VPS
# другие, и правкой сценария такое не решается.
$PlanFile = Join-Path $Root 'config\mirror.json'
if (-not (Test-Path -LiteralPath $PlanFile)) {
    # Своего списка ещё нет - берём образец. В сборку едет он: рабочий список у
    # каждого свой, с папками, MAIN VPS и SECOND VPS его хозяйства.
    $PlanSample = Join-Path $AppRoot 'config\mirror.sample.json'
    if (Test-Path -LiteralPath $PlanSample) { Copy-Item -LiteralPath $PlanSample -Destination $PlanFile }
}
if (-not (Test-Path -LiteralPath $PlanFile)) {
    throw "no source list: $PlanFile"
}

try {
    $Plan = @((Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json).sources)
} catch {
    throw "the source list is not readable: $($_.Exception.Message)"
}

if (-not $Plan.Count) { throw "the source list is empty: $PlanFile" }

# Части снимка запоминаем до отбора: проверять годность нужно целиком,
# даже когда обновляют одну папку. Иначе `-Only` сузит и проверку тоже.
$SnapshotParts = @($Plan | Where-Object { $_.from -eq 'snapshot' -and $_.part } |
    ForEach-Object { [string]$_.part } | Sort-Object -Unique)

foreach ($entry in $Plan) {
    if (-not $entry.folder) { throw 'a source has no folder name' }
    if ($entry.from -eq 'snapshot' -and -not $entry.part) {
        throw "a snapshot source has no part: $($entry.folder)"
    }
    if ($entry.from -eq 'server' -and -not $entry.path) {
        throw "a MAIN VPS or SECOND VPS source has no path: $($entry.folder)"
    }
}

if ($Only.Count) {
    # Обёртка зовёт скрипт через -File, а тот отдаёт список одной строкой:
    # «A,B» приезжает как единственный элемент. Разбираем сами, иначе отбор
    # молча не находит ни одной папки.
    $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Plan = @($Plan | Where-Object { $Only -contains $_.folder })
    if (-not $Plan.Count) { throw "no folder matched -Only: $($Only -join ', ')" }
}

Write-Host '======================================================================'
Write-Host 'AUDION SYNC TOOLS - updating the local mirrors'
Write-Host '======================================================================'
Write-Note "folder : $Root"
Write-Note "MAIN VPS : $Server"
Write-Note "bucket : $Bucket"
if ($WhatIf) { Write-Note 'mode   : dry run, nothing is written' 'Yellow' }

# ------------------------------------------------------------------ снимок

$needSnapshot = @($Plan | Where-Object { $_.From -eq 'snapshot' }).Count -gt 0
$snapshotFile = ''
$work = Join-Path $env:TEMP ('audion-backup-sync-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

if ($needSnapshot) {
    Write-Step 'The snapshot from the bucket'
    $date = Get-LatestSnapshotDate
    Write-Note "latest: $date"

    if ($WhatIf) {
        Write-Note 'dry run: the snapshot is not downloaded'
    } else {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $name = 'audion-main-server-recovery.tar.gz'
        Invoke-Rclone -Arguments @('copy', "$Bucket/daily/$date/$name", $work, '--stats-one-line') | Out-Null
        $snapshotFile = Join-Path $work $name
        if (-not (Test-Path -LiteralPath $snapshotFile)) { throw "the snapshot did not download: $name" }
        $size = (Get-Item $snapshotFile).Length
        Write-Note ('downloaded: {0:N0} bytes' -f $size)

        # Сумма лежит рядом отдельным файлом - её и сверяем: снимок, доехавший
        # наполовину, выглядит как обычный архив, пока его не распакуют.
        Invoke-Rclone -Arguments @('copy', "$Bucket/daily/$date/$name.sha256", $work, '--stats-one-line') | Out-Null
        $sumFile = Join-Path $work "$name.sha256"
        if (Test-Path -LiteralPath $sumFile) {
            $expected = ((Get-Content -LiteralPath $sumFile -Raw) -split '\s+')[0].Trim().ToLower()
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $stream = [System.IO.File]::OpenRead($snapshotFile)
            try {
                $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLower()
            } finally {
                $stream.Dispose()
                $sha.Dispose()
            }
            if ($expected -notmatch '^[0-9a-f]{64}$' -or $expected -ne $actual) {
                throw "the snapshot checksum did not match: expected $expected, got $actual"
            }
            Write-Note 'checksum matched'
        } else {
            throw 'the snapshot checksum file is missing'
        }

        # Снимок остаётся здесь целиком: папки хороши для чтения, а машину
        # поднимают из него. Держим последний - прежние уходят, история версий
        # и так лежит в корзине.
        # Validate the downloaded file before it can replace a usable snapshot
        # from the same date or feed a destructive mirror operation.
        if (-not (Test-SnapshotUsable -SnapshotPath $snapshotFile -Parts $SnapshotParts)) {
            throw 'the new snapshot is unusable; stored snapshots and mirrors are unchanged'
        }
        $shelf = Join-Path $Root 'Snapshots'
        New-Item -ItemType Directory -Path $shelf -Force | Out-Null
        $kept = Join-Path $shelf "audion-main-server-recovery-$date.tar.gz"
        Copy-Item -LiteralPath $snapshotFile -Destination $kept -Force
        if (Test-Path -LiteralPath $sumFile) {
            Copy-Item -LiteralPath $sumFile -Destination "$kept.sha256" -Force
        }

        # Прежние снимки уходят только после того, как новый показал, что из
        # него можно восстановиться. Совпавшая контрольная сумма этого не
        # доказывает: она говорит, что скачанные байты равны исходным, а не что
        # исходные годятся. MAIN VPS мог выгрузить обрезанный архив вместе с его
        # правильной суммой - и прежний, рабочий, к этому времени уже стёрт.
        $old = @(Get-ChildItem -LiteralPath $shelf -File -Force |
            Where-Object {
                $_.Name -match '^audion-main-server-recovery-(\d{4}-\d{2}-\d{2})\.tar\.gz(?:\.sha256)?$' -and
                $Matches[1] -lt $date -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
            })
        foreach ($file in $old) { Remove-Item -LiteralPath $file.FullName -Force }
        if ($old.Count) { Write-Note "previous snapshots removed: $($old.Count)" }
        Write-Note "snapshot kept: Snapshots\$(Split-Path -Leaf $kept)" 'Green'
    }
}

# ----------------------------------------------------------------- разбор

function Expand-SnapshotPart {
    <#
        Достаёт одну часть снимка во временную папку. Части лежат вложенными
        архивами: внешний - опись и рецепты, внутренние - сами данные.
    #>
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$Part,
        [Parameter(Mandatory)][string]$Destination
    )

    $python = 'py'
    $script = @'
import io, os, sys, tarfile
snapshot, part, destination = sys.argv[1], sys.argv[2], sys.argv[3]
with tarfile.open(snapshot, "r:gz") as outer:
    member = None
    for name in outer.getnames():
        if name.endswith("payload/" + part):
            member = name
            break
    if member is None:
        print("part not found: " + part, file=sys.stderr)
        raise SystemExit(2)
    data = outer.extractfile(member).read()
with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as inner:
    os.makedirs(destination, exist_ok=True)
    # Правило отбора названо явно: иначе Python 3.14 сменит поведение молча.
    # Ссылки пропускаются: в конфигурации MAIN VPS есть ссылка на абсолютный
    # путь, строгое правило на ней падает, а зеркалу ссылки не нужны — в нём
    # читают файлы, а не ходят по ним.
    members = [m for m in inner.getmembers() if not (m.issym() or m.islnk())]
    try:
        inner.extractall(destination, members=members, filter="data")
    except TypeError:
        inner.extractall(destination, members=members)
    print(len(members))
'@
    $scriptPath = Join-Path $Destination '..\extract-part.py'
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding UTF8
    $count = & $python '-3.12' $scriptPath $SnapshotPath $Part $Destination
    if ($LASTEXITCODE -ne 0) { throw "a snapshot part did not unpack: $Part" }
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    return [int]$count
}

function Sync-Tree {
    <#
        Кладёт принесённое поверх папки. По умолчанию ничего не удаляет:
        зеркало собиралось из разных мест MAIN VPS, и то, чего нет в одном
        источнике, вовсе не мусор.

        Удаление включается отдельно и только там, где источник полон -
        у голых репозиториев, которые обязаны совпадать до объекта.

        Каталог .git не трогается ни в каком режиме: история локальной копии -
        её дело.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target,
        [switch]$Mirror
    )

    $before = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count

    $mode = if ($Mirror) { '/MIR' } else { '/E' }
    robocopy $Source $Target $mode /XD '.git' /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
    # robocopy отдаёт 0-7 при успехе; 8 и выше - настоящая беда.
    if ($LASTEXITCODE -ge 8) { throw "the copy failed, robocopy code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0

    $after = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' }).Count
    return [pscustomobject]@{ Before = $before; After = $after }
}

$results = @()

foreach ($entry in $Plan) {
    $target = Join-Path $Root $entry.folder
    Write-Step $entry.folder
    Write-Note $entry.note

    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Note 'no such folder - creating it' 'Yellow'
        if (-not $WhatIf) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    }

    if ($WhatIf) {
        $named = $(if ($entry.host) { [string]$entry.host } else { $Server })
        $source = if ($entry.from -eq 'snapshot') { "snapshot -> $($entry.part)" } else { "$named`:$($entry.path)" }
        Write-Note "source: $source"
        $results += [pscustomobject]@{ Folder = $entry.folder; Status = 'dry run'; Files = '' }
        continue
    }

    try {
        if ($entry.from -eq 'snapshot') {
            $staging = Join-Path $work ($entry.folder -replace '\s', '-')
            $count = Expand-SnapshotPart -SnapshotPath $snapshotFile -Part $entry.part -Destination $staging
            Write-Note "entries in the snapshot part: $count"

            # Части лежат по-разному: у портала дерево от корня проекта, у
            # Чем брать из распакованного, решает описание источника, а не
            # имя папки: subdir - взять одну ветку, pick - собрать плоско
            # только названные, иначе берём всё целиком.
            $from = $staging
            if ($entry.subdir) {
                $from = Join-Path $staging ($entry.subdir -replace '/', '\\')
            }

            if ($entry.pick) {
                # Плоско и только то, что читают люди. Всё, что не названо -
                # ключи, сертификаты, чужие каталоги - остаётся в снимке.
                $flat = Join-Path $work (($entry.folder -replace '\s', '-') + '-flat')
                New-Item -ItemType Directory -Path $flat -Force | Out-Null

                $skip = @($entry.skip)
                $mask = $(if ($skip.Count) { '(?i)\.(' + ($skip -join '|') + ')$' } else { '' })

                foreach ($branch in @($entry.pick)) {
                    $dir = Join-Path $staging ($branch -replace '/', '\\')
                    if (-not (Test-Path -LiteralPath $dir)) { continue }
                    foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                        if ($mask -and $item.Name -match $mask) { continue }
                        if ($item.PSIsContainer) {
                            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $flat $item.Name) -Recurse -Force
                        } else {
                            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $flat $item.Name) -Force
                        }
                    }
                }
                $from = $flat
            }

            if (-not $from -or -not (Test-Path -LiteralPath $from)) {
                throw "the snapshot part holds no expected tree"
            }
            # Полное совпадение требуется только репозиториям: остальные
            # папки богаче своего источника, и стирать в них нечего.
            $counts = Sync-Tree -Source $from -Target $target -Mirror:([bool]$entry.mirror)
        } else {
            # Дерево с MAIN VPS читается потоком и нигде там не оседает:
            # зеркало только берёт, на MAIN VPS не пишет ничего, даже во
            # временную папку.
            #
            # Перенаправление делает cmd, а не PowerShell: тот не двоичный и
            # режет поток на строки, отчего архив приезжает битым - «формат не
            # распознан». Через cmd байты доходят как есть.
            $staging = Join-Path $work ($entry.folder -replace '\\s', '-')
            New-Item -ItemType Directory -Path $staging -Force | Out-Null
            $localFile = Join-Path $work ("$($entry.folder -replace '\\s', '-').tar.gz")
            $pack = "cd '$($entry.path)' && tar -cz --exclude=.git --exclude=var --exclude=node_modules --exclude=__pycache__ --exclude='*.pyc' ."
            # У источника может быть свой хост: SECOND VPS - отдельная
            # машина, и её конфигурация лежит только на ней. Переменную
            # нельзя звать $host - так зовётся сама консоль PowerShell.
            $sshHost = $(if ($entry.host) { [string]$entry.host } else { $Server })
            $line = 'ssh ' + $sshHost + ' "' + $pack + '" > "' + $localFile + '"'
            cmd.exe /c $line
            $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $localFile)
            if ($ok) { $ok = (Get-Item $localFile).Length -gt 1024 }
            if (-not $ok) { throw 'the archive from MAIN VPS did not arrive' }
            & tar -xzf $localFile -C $staging
            if ($LASTEXITCODE -ne 0) { throw 'the archive from MAIN VPS did not unpack' }
            Remove-Item -LiteralPath $localFile -Force -ErrorAction SilentlyContinue
            if (-not (Get-ChildItem -LiteralPath $staging -Force -ErrorAction SilentlyContinue)) {
                throw 'nothing arrived from MAIN VPS'
            }
            $counts = Sync-Tree -Source $staging -Target $target
        }

        $delta = $counts.After - $counts.Before
        $sign = if ($delta -gt 0) { "+$delta" } elseif ($delta -lt 0) { "$delta" } else { 'unchanged' }
        Write-Note "files: $($counts.After) ($sign)" 'Green'
        $results += [pscustomobject]@{ Folder = $entry.folder; Status = 'done'; Files = $counts.After }
    } catch {
        Write-Note "did not work: $($_.Exception.Message)" 'Red'
        $results += [pscustomobject]@{ Folder = $entry.folder; Status = 'failed'; Files = '' }
    }
}

# ------------------------------------------------------------------- итог

Write-Step 'Summary'
foreach ($result in $results) {
    $colour = switch ($result.Status) { 'done' { 'Green' } 'failed' { 'Red' } default { 'Gray' } }
    Write-Host ('  {0,-24} {1,-10} {2}' -f $result.Folder, $result.Status, $result.Files) -ForegroundColor $colour
}

if (-not $WhatIf -and $work -and (Test-Path -LiteralPath $work)) {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Note 'temporary files cleaned up'
}

$failed = @($results | Where-Object { $_.Status -eq 'failed' }).Count
Write-Note ('took: {0:mm\:ss}' -f ((Get-Date) - $Started))

# Git здесь не трогается намеренно: в папках с историей коммит делает владелец,
# посмотрев на изменения. Скрипт приносит файлы, решение остаётся человеку.
$withGit = @($Plan | ForEach-Object { Join-Path $Root $_.Folder } | Where-Object { Test-Path (Join-Path $_ '.git') })
if ($withGit.Count -and -not $WhatIf) {
    Write-Host ''
    Write-Note 'folders with history hold uncommitted changes - look and decide:' 'Yellow'
    foreach ($path in $withGit) { Write-Note "  git -C `"$path`" status --short" }
}

if (-not $NoPause -and -not $env:CI) {
    Write-Host ''
    Read-Host 'Enter - close' | Out-Null
}
exit ([int]($failed -gt 0))
