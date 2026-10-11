<#
.SYNOPSIS
    Раскладывает ключи из Export Keys по штатным местам этой машины.

.DESCRIPTION
    Папку данных копируют на новую машину целиком, и ключи едут внутри.
    Лежать в Export Keys они умеют, а работать оттуда — нет: три программы
    ищут их каждая в своём месте. ssh — в профиле пользователя, rclone — в
    `config\rclone` данных, git — по пути, записанному в `.git\config`
    при клонировании.

    Скрипт разносит ключи по этим трём местам и приводит записанные пути к
    нынешнему расположению папки. Буква диска нигде не зашита: всё считается
    от места, где лежит этот файл. На станции, где TOOLS живёт на `S:`, менять
    в нём ничего не нужно.

    Источников два, и оба устроены одинаково — подпапки `SSH` и `rclone`.
    Папка `Tunnel` с golden copy `Tunnel\SSH` собрана однажды и едет с папкой
    данных; `Tunnel\Export` собирает `export-keys.cmd` с живой машины, и он
    свежее, если ключ там добавили или переподписали. Без указания берётся
    `Export`, когда он есть, иначе `Tunnel`. В Auto отсутствующие серверные
    пары дополняются из `Tunnel\SSH\servers`, без приватных ключей соседних CLIENTS.

    Приватным ключам сразу выставляются права, которых требует ssh:
    наследование снято, доступ у нынешнего пользователя, администраторов и SYSTEM.
    Ключ на диске с общими правами ssh отвергает — это частая причина того, что
    на новой машине «ничего не работает».

    Содержимое ключей не выводится. Перед перезаписью файлы сравниваются
    по размеру и SHA256; совпадающая копия остаётся на месте.

    Маршруты в `~\.ssh\config` пишет `install-tunnel-client.cmd` в папке
    Tunnel: у него это единственное дело. Здесь конфиг из Export Keys кладётся
    только на машину, где своего нет вовсе, а в готовом чинятся пути, ведущие
    в никуда.

.PARAMETER Source
    Откуда брать: `Export` — папка `Tunnel\Export`, `Store` — папка `Tunnel` с
    golden copy, `Auto` (по умолчанию) — `Export`, если он не пуст, иначе `Tunnel`.
    В Auto недостающие серверные пары дополняются из golden copy.

.PARAMETER Check
    Ничего не менять, показать, что и куда легло бы.

.PARAMETER Force
    Перезаписать отличающиеся файлы, которые уже лежат на месте. Совпадающие
    копии сохраняются. Без ключа существующие файлы сохраняют содержимое.
    Права приватных файлов проверяются и без Force.

.EXAMPLE
    import-keys.cmd -Check
    Показать раскладку и ничего не трогать.

.EXAMPLE
    import-keys.cmd
    Разложить недостающее по местам.

.EXAMPLE
    import-keys.cmd -Source Store -Force
    Взять папку Tunnel и перезаписать ею то, что лежит на машине.
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [ValidateSet('Auto', 'Export', 'Store')]
    [string]$Source = 'Auto',
    [switch]$Check,
    [switch]$Force,
    # Explicitly replace profile routes with the selected DATA configuration.
    [switch]$RestoreConfig,
    # Ключ враппера из Runs: паузу держит он и читает ключ тоже он. Здесь ключ
    # только принимается, чтобы вызов с ним не падал на разборе аргументов.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Root) {
    . (Join-Path $AppRoot 'Engine\DataRoot.ps1')
    $Root = Get-AbkDataRootPath -AppRoot $AppRoot
}
$Tunnel = Join-Path $Root 'Tunnel'
$Export = Join-Path $Tunnel 'Export'
$SshDir = Join-Path $HOME '.ssh'
$SshConfig = Join-Path $SshDir 'config'

# Ключи к корзине кладутся в выбранную папку данных. Раньше они уезжали
# публикатору, и бэкап без него не работал; теперь у каждого свои.
$RcloneTarget = Join-Path $Root 'config\rclone'

# Ключ SECOND VPS у каждого зовётся по-своему: имя берётся из targets.json.
. (Join-Path $AppRoot 'Engine\Targets.ps1')
. (Join-Path $AppRoot 'Engine\Secrets.ps1')
. (Join-Path $AppRoot 'Engine\SshProfile.ps1')
$SecondVps = Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $Root

$Placed = 0
$Kept = 0
$Failed = 0

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "===== $Text" -ForegroundColor Cyan
}

function Write-Note {
    param([string]$Text, [string]$Colour = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Colour
}

function Protect-KeyFile {
    param([string]$Path)
    if (-not (Protect-AbkSshPrivateKey -Path $Path)) { throw ('Cannot protect private key ACL: ' + $Path) }
}

function Copy-Secret {
    param(
        [string]$From,
        [string]$To,
        [string]$Title,
        [switch]$Protect
    )

    if (-not (Test-Path -LiteralPath $From)) {
        Write-Note "not in Export Keys: $Title" 'Yellow'
        return
    }

    $exists = Test-Path -LiteralPath $To
    $same = $false
    if ($exists -and $Force) {
        $sourceFile = Get-Item -LiteralPath $From -ErrorAction Stop
        $targetFile = Get-Item -LiteralPath $To -ErrorAction Stop
        if (-not $sourceFile.PSIsContainer -and -not $targetFile.PSIsContainer -and
            $sourceFile.Length -eq $targetFile.Length) {
            $same = (Get-FileHash -LiteralPath $From -Algorithm SHA256 -ErrorAction Stop).Hash -eq
                    (Get-FileHash -LiteralPath $To -Algorithm SHA256 -ErrorAction Stop).Hash
        }
    }
    if ($exists -and (-not $Force -or $same)) {
        if ($Protect -and -not $Check) { Protect-KeyFile -Path $To }
        Write-Note "already in place: $Title"
        $script:Kept++
        return
    }

    if ($Check) {
        $verb = if ($exists) { 'would overwrite' } else { 'would place' }
        Write-Note "$verb : $Title -> $To" 'Yellow'
        return
    }

    $parent = Split-Path -Parent $To
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $From -Destination $To -Force
    if ($Protect) { Protect-KeyFile -Path $To }
    Write-Note "placed: $Title" 'Green'
    $script:Placed++
}

# ------------------------------------------------------------------- источник

function Test-HasKeys {
    param([string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder)) { return $false }
    return @(Get-ChildItem -LiteralPath $Folder -File -Filter '*.pub' -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-ImportPrivatePath {
    param([System.IO.FileInfo]$PublicFile)
    $path = Join-Path $PublicFile.DirectoryName $PublicFile.BaseName
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    # CLIENTS also stores <name>.pub beside <name>_ed25519.
    $path = Join-Path $PublicFile.DirectoryName ($PublicFile.BaseName + '_ed25519')
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return ''
}

function Get-ImportPublicKeys {
    param([string[]]$Folders)
    $seen = @{}
    foreach ($folder in $Folders) {
        foreach ($sub in @('', 'clients', 'servers')) {
            $dir = if ($sub) { Join-Path $folder $sub } else { $folder }
            foreach ($pub in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.pub' -ErrorAction SilentlyContinue)) {
                $private = Get-ImportPrivatePath -PublicFile $pub
                $name = if ($private) { Split-Path -Leaf $private } else { $pub.BaseName }
                if ($seen.ContainsKey($name)) { continue }
                # Только полноценная пара перекрывает запасную копию.
                if ($private) { $seen[$name] = $true }
                $pub
            }
        }
    }
}

switch ($Source) {
    'Export' {
        $From = $Export
        if (-not (Test-Path -LiteralPath $From)) { throw "no Export Keys at $From - collect them on the old machine with export-keys.cmd" }
    }
    'Store' { $From = $Tunnel }
    default {
        # Комплект свежее склада по смыслу: его собирают с живой машины. Но
        # пустая папка Export не повод отказываться от склада, который едет с
        # бэкапом всегда.
        $From = if (Test-HasKeys (Join-Path $Export 'SSH')) { $Export } else { $Tunnel }
    }
}

$KeySource = Join-Path $From 'SSH'
$RcloneSource = Join-Path $From 'rclone'
$SourceName = if ($From -eq $Export) { 'Export Keys' } else { 'the Tunnel folder (golden copy)' }

Write-Host '======================================================================'
Write-Host 'AUDION SYNC TOOLS - IMPORT KEYS: laying the keys into place'
Write-Host '======================================================================'
Write-Note "source  : $SourceName"
Write-Note "            $From"
Write-Note "profile : $SshDir"
Write-Note "program : $AppRoot"
if ($Check) { Write-Note 'mode    : dry run, nothing is written' 'Yellow' }
if ($Force) { Write-Note 'mode    : overwrite what exists' 'Yellow' }

# ------------------------------------------------------------------- корзина

Write-Step 'The R2 bucket keys - into config\rclone'

foreach ($name in @('r2.credentials', 'rclone.conf')) {
    try {
        Copy-Secret -From (Join-Path $RcloneSource $name) `
                    -To (Join-Path $RcloneTarget $name) `
                    -Title "rclone\$name"
    } catch {
        $Failed++
        Write-Note ("failed: rclone\{0}: {1}" -f $name, $_.Exception.Message) 'Red'
    }
}

# ---------------------------------------------------------------------- ssh

Write-Step 'The machine keys - into the profile'

if (-not (Test-Path -LiteralPath $KeySource)) {
    Write-Note "no folder $KeySource" 'Yellow'
} else {
    # Ключом считается файл с парным .pub: так приезжают любые имена, а
    # ssh_config.copy и прочие соседи по папке остаются на месте.
    # Golden copy держит пары в подпапках: clients - пары машин, servers - ключи
    # VPS (хосты в ~\.ssh\config ходят ими из профиля). Плоская раскладка и
    # Export Keys - прямо в SSH. Обходим всё: раньше подпапки не читались, и
    # IMPORT KEYS на чистом профиле не клал ничего.
    $folders = @($KeySource)
    if ($Source -eq 'Auto' -and $From -eq $Export) {
        # Export contains this machine's key. Supplement server access only;
        # do not import neighbouring machines' private keys from CLIENTS.
        $folders += Join-Path (Join-Path $Tunnel 'SSH') 'servers'
        Write-Note 'missing server SSH pairs in Export Keys are restored from the golden copy'
    }
    $pubs = @(Get-ImportPublicKeys -Folders $folders)
    if (-not $pubs.Count) {
        Write-Note 'not a single key pair in the source' 'Yellow'
    }

    foreach ($pub in $pubs) {
        $private = Get-ImportPrivatePath -PublicFile $pub
        if (-not $private) {
            Write-Note "public key only: $($pub.Name)" 'Yellow'
            continue
        }

        $privateName = Split-Path -Leaf $private
        try {
            Copy-Secret -From $private -To (Join-Path $SshDir $privateName) -Title $privateName -Protect
            # A failed private-key copy must not replace its public half.
            Copy-Secret -From $pub.FullName -To (Join-Path $SshDir ($privateName + '.pub')) -Title $pub.Name
        } catch {
            $Failed++
            Write-Note ("failed: {0}: {1}" -f $privateName, $_.Exception.Message) 'Red'
        }
    }

    # Права выставляются и самим ключам в источнике. Профилем дело не
    # ограничивается: install-tunnel-client.cmd прописывает в маршруты путь в
    # склад, и на свежей машине эти файлы наследуют права папки — ssh откажется
    # их читать, а ssh-keygen откажется их менять.
    if (-not $Check) {
        $loose = @()
        foreach ($pub in $pubs) {
            $private = Get-ImportPrivatePath -PublicFile $pub
            if (-not $private) { continue }

            try {
                Protect-KeyFile -Path $private
                $loose += $pub.BaseName
            } catch {
                $Failed++
                Write-Note ("failed source ACL: {0}: {1}" -f $pub.BaseName, $_.Exception.Message) 'Red'
            }
        }

        if ($loose.Count) {
            Write-Note "private key rights checked in the source: $($loose.Count) key(s)" 'Green'
        }
    }
}

# ------------------------------------------------------------------- маршруты

Write-Step 'The routes in ~\.ssh\config'

if ($RestoreConfig -or -not (Test-Path -LiteralPath $SshConfig)) {
    # Своего конфига нет: кладём из комплекта, если он там есть. Пути внутри
    # почти наверняка от прежней машины - их чинит блок ниже.
    $spare = @(
        (Join-Path $KeySource 'config'),
        (Join-Path $KeySource 'ssh_config.copy')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($spare) {
        if ($RestoreConfig) {
            if (-not $Check) {
                New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
                if (Test-Path -LiteralPath $SshConfig) { Copy-Item -LiteralPath $SshConfig -Destination ($SshConfig + '.before-restore') -Force }
                Copy-Item -LiteralPath $spare -Destination $SshConfig -Force
            }
            Write-Note 'restore profile config from DATA (previous config: config.before-restore)' 'Yellow'
        } else { Copy-Secret -From $spare -To $SshConfig -Title 'config' }
    } else {
        Write-Note 'no config in the profile and none in Export Keys' 'Yellow'
        Write-Note 'run Tunnel\install-tunnel-client.cmd - it writes the routes' 'Yellow'
        if ($RestoreConfig) { $Failed++; Write-Note 'RestoreConfig needs a saved DATA SSH config; profile left intact' 'Red' }
    }
}

if (Test-Path -LiteralPath $SshConfig) {
    $text = Get-Content -LiteralPath $SshConfig -Raw
    $fixed = @()
    $relocated = Repair-AbkImportedIdentityPaths -Text $text -SshDirectory $SshDir
    if ($relocated -cne $text) { $text = $relocated; $fixed += 'client IdentityFile paths' }

    # Путь чинится только тогда, когда записанный файл не существует: на
    # обжитой машине конфиг настроен, и трогать его незачем.
    $targets = @(
        @{ Pattern = '"[^"]*audion_vps_root_ed25519"'; Path = (Join-Path $SshDir 'audion_vps_root_ed25519'); Name = 'the audion-vps key' }
        @{ Pattern = ('"[^"]*{0}"' -f [regex]::Escape($SecondVps.Key)); Path = (Join-Path $SshDir $SecondVps.Key); Name = 'the SECOND VPS key' }
        @{ Pattern = '"[^"]*cloudflared\.exe"'; Path = (Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'); Name = 'cloudflared' }
    )

    foreach ($target in $targets) {
        $found = [regex]::Matches($text, $target.Pattern)
        if (-not $found.Count) { continue }

        $current = $found[0].Value.Trim('"')
        if (Test-Path -LiteralPath $current) {
            Write-Note "path is correct: $($target.Name)"
            continue
        }

        if (-not (Test-Path -LiteralPath $target.Path)) {
            Write-Note "nothing to fix it with: $($target.Name) - no $($target.Path)" 'Yellow'
            continue
        }

        if ($Check) {
            Write-Note "would fix: $($target.Name) -> $($target.Path)" 'Yellow'
            continue
        }

        $text = [regex]::Replace($text, $target.Pattern, ('"' + $target.Path + '"'))
        $fixed += $target.Name
    }

    if ($fixed.Count -and -not $Check) {
        # Без BOM: ssh читает конфиг построчно и на первой же строке с меткой
        # спотыкается, не находя ключевого слова.
        [System.IO.File]::WriteAllText($SshConfig, $text, (New-Object System.Text.UTF8Encoding $false))
        Write-Note "fixed: $($fixed -join ', ')" 'Green'
        $Placed += $fixed.Count
    } elseif (-not $fixed.Count) {
        Write-Note 'nothing to fix'
    }
}

# The same retained trust is visible to ordinary SSH and its ProxyJump children.
try {
    $trust = Update-AbkSshProfileTrust -DataRoot $Root -SshConfig $SshConfig -Check:$Check
    Write-Note ("SSH trust: " + $trust)
} catch { $Failed++; Write-Note ("failed SSH trust: " + $_.Exception.Message) 'Red' }

# ----------------------------------------------------------------------- git

Write-Step 'The Forgejo key - in the mirror repositories'

$forgejoKey = Join-Path $SshDir 'forgejo_vps_audion_ed25519'
if (-not (Test-Path -LiteralPath $forgejoKey)) {
    $forgejoKey = Join-Path $KeySource 'forgejo_vps_audion_ed25519'
}

if (-not (Test-Path -LiteralPath $forgejoKey)) {
    Write-Note 'no Forgejo key in the profile and none in the source' 'Yellow'
} else {
    # git понимает и прямую косую, и обратную, но в своём конфиге держит
    # прямую: обратная там экранируется и путь читается неверно.
    $keyForGit = $forgejoKey -replace '\\', '/'
    $wanted = "ssh -i `"$keyForGit`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -J audion-vps"

    $repos = @(Get-ChildItem -LiteralPath $Root -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git\config') })

    if (-not $repos.Count) {
        Write-Note 'no working copies beside it - nothing to fix'
    }

    foreach ($repo in $repos) {
        $current = (& git -C $repo.FullName config --get core.sshCommand 2>$null)
        if (-not $current) { continue }

        # Верным считается любой путь, по которому ключ действительно лежит:
        # на обжитой машине он может указывать в склад, и переписывать рабочую
        # строку на профильную незачем. Чинится только то, что не открывается.
        $written = ''
        $match = [regex]::Match($current, '-i\s+"([^"]+)"')
        if ($match.Success) { $written = $match.Groups[1].Value }

        if ($written -and (Test-Path -LiteralPath $written)) {
            Write-Note "path is correct: $($repo.Name)"
            $Kept++
            continue
        }

        if ($Check) {
            Write-Note "would fix: $($repo.Name)" 'Yellow'
            continue
        }

        & git -C $repo.FullName config core.sshCommand $wanted
        if ($LASTEXITCODE -ne 0) {
            Write-Note "git failed to take the fix (code $LASTEXITCODE): $($repo.Name)" 'Red'
            $Failed++
            continue
        }
        Write-Note "fixed: $($repo.Name)" 'Green'
        $Placed++
    }
}

# ---------------------------------------------------------------------- итог

Write-Step 'Summary'
if ($Check) {
    Write-Note 'dry run: nothing on disk was changed' 'Yellow'
} else {
    Write-Note "placed: $Placed"
}
if ($Kept) { Write-Note "left as it was: $Kept" }
if ($Failed) { Write-Note "failed: $Failed - import is incomplete" 'Red' }

Write-Host ''
Write-Note 'next: Tunnel\install-tunnel-client.cmd - cloudflared and the routes'
Write-Note 'check: sync-backup.cmd -WhatIf - reads the keys and MAIN VPS, writes nothing'
if ($Failed) { exit 1 }
