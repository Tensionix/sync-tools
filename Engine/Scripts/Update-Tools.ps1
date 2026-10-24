<#
.SYNOPSIS
    Обновляет инструменты, которые программа возит с собой: cloudflared, rclone,
    терминал, архиватор PeaZip и редакторы Edit и micro.

.DESCRIPTION
    Инструменты лежат в `Tools` (клиент туннеля - в `Tunnel\Bin`) и ездят вместе
    с папкой — на машине их может не быть вовсе. Этот сценарий забирает свежие
    сборки и кладёт на место старых, ничего больше не трогая: настройки, ключи
    и конфиги остаются. Архиватор и редакторы ставит Install-Tools.ps1.

    Замена делается через временную папку и только после успешной распаковки:
    оборванная закачка не оставит программу без инструмента. Прежний файл
    убирается в сторону и возвращается, если новый не запустился.

.PARAMETER Cloudflared
    Обновить только клиент туннеля.

.PARAMETER Rclone
    Обновить только rclone.

.PARAMETER Terminal
    Обновить только терминал.

.PARAMETER PeaZip
    Обновить только архиватор (7-Zip и zstd из PeaZip portable).

.PARAMETER Edit
    Обновить только Microsoft Edit - редактор F4.

.PARAMETER Micro
    Обновить только micro - второй редактор F4.

.PARAMETER Check
    Ничего не качать, только сказать, что стоит сейчас и что доступно.

.PARAMETER Force
    Скачать заново, даже если стоит та же версия.

.EXAMPLE
    .\Update-Tools.ps1 -Check
    Показать нынешние версии.

.EXAMPLE
    .\Update-Tools.ps1 -Rclone
    Обновить rclone.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Cloudflared,
    [switch]$Rclone,
    [switch]$Terminal,
    [switch]$PeaZip,
    [switch]$Edit,
    [switch]$Micro,
    [switch]$Check,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ToolsDir = Join-Path $AppRoot 'Tools'
$Work = Join-Path $AppRoot '._runtime\tools-update'
# Сюда уезжает файл, который держит работающий процесс: заменить его нельзя,
# убрать в сторону - можно. Чистится при следующем запуске, когда освободится.
$Aside = Join-Path $AppRoot 'Recovery\tools-aside'

# Без ключей обновляем всё: человек сказал «обнови инструменты».
if (-not $Cloudflared -and -not $Rclone -and -not $Terminal -and -not $PeaZip -and -not $Edit -and -not $Micro) {
    $Cloudflared = $true; $Rclone = $true; $Terminal = $true; $PeaZip = $true; $Edit = $true; $Micro = $true
}
# Ниже ключ гаснет, когда версия уже свежая; накату настроек нужно знать, что
# о терминале вообще просили.
$terminalAsked = [bool]$Terminal

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Write-Step {
    <# Этап работы: их видно наперёд, и по ним понятно, где мы стоим. #>
    param([int]$Number, [int]$Total, [string]$Text)
    Write-Host ""
    Write-Host ("  [{0}/{1}] {2}" -f $Number, $Total, $Text) -ForegroundColor Cyan
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-GithubTag {
    <#
        Свежий выпуск по переадресации, а не через api.github.com: у API
        шестьдесят запросов в час на адрес, и он отвечал 403 «rate limit».
        Страница /releases/latest перекидывает на тег - оттуда и версия.
    #>
    param([string]$Repo)
    try {
        $head = & curl.exe -sIL -A 'Audion-Sync-Tools' ('https://github.com/{0}/releases/latest' -f $Repo) 2>$null
        $tag = @($head) |
            Where-Object { $_ -match 'location:.*\/releases\/tag\/(.+?)\s*$' } |
            ForEach-Object { $Matches[1] } | Select-Object -Last 1
        if ($tag) { return $tag.Trim() }
    } catch {}
    return ''
}

function Test-Fresh {
    <#
        Стоит ли уже то же самое. Качать одно и то же по полсотни мегабайт
        незачем: сравниваем версии и говорим об этом словами. Ключ -Force
        перекачивает всё равно - на случай побитого файла.
    #>
    param([string]$Name, [string]$Have, [string]$Fresh)
    Write-Line ('installed: {0}' -f $(if ($Have) { $Have } else { 'none' }))
    Write-Line ('latest: {0}' -f $(if ($Fresh) { $Fresh } else { 'could not be determined' }))
    if (-not $Fresh -or -not $Have) { return $false }
    if ($Have -ne $Fresh) { return $false }
    if ($Force) {
        Write-Line 'same version, but a re-download was asked for' Yellow
        return $false
    }
    Write-Line ('{0}: already current, nothing to download' -f $Name) Green
    return $true
}

$failed = New-Object System.Collections.Generic.List[string]

function Write-Fail {
    <#
        Инструмент не обновился - остальные идут своим чередом. Раньше первая
        же ошибка останавливала всё: занятый cloudflared.exe оставил без
        обновления и терминал (04.10.2026).
    #>
    param([string]$Name, $Problem)
    Write-Host ("`n  Failed ({0}): {1}" -f $Name, $Problem.Exception.Message) -ForegroundColor Red
    $failed.Add($Name)
}

function Expand-Package {
    <#
        Распаковка средствами .NET, а не Expand-Archive: у PowerShell, который
        едет внутри программы, модуля Archive нет, и команда находилась только
        через скрытый запуск Windows PowerShell 5.1.
    #>
    param([string]$Zip, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Zip, $Destination)
}

function Get-RemoteSize {
    <# Сколько весит файл на той стороне: спрашиваем заголовки, не качая. #>
    param([string]$Url)
    try {
        $head = & curl.exe -sIL -A 'Audion-Sync-Tools' $Url 2>$null
        $line = @($head) | Where-Object { $_ -match '^Content-Length:' } | Select-Object -Last 1
        if ($line) { return [long](($line -split ':')[1].Trim()) }
    } catch {}
    return 0
}

function Get-Version {
    <# Версия установленного инструмента, одной строкой. #>
    param([string]$Path, [string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $Path)) { return 'none' }
    try {
        $out = & $Path @Arguments 2>&1 | Select-Object -First 1
        return ([string]$out).Trim()
    } catch {
        return (Get-Item $Path).VersionInfo.FileVersion
    }
}

function Get-Package {
    <#
        Качает файл с повторами. curl есть в Windows с 2018 года и переживает
        обрывы лучше, чем Invoke-WebRequest; его и предпочитаем.

        Свой прогресс, а не curl'овский: тот рисует таблицу поверх одной
        строки возвратом каретки, и в окне программы она разворачивается в
        три десятка строк цифр. Здесь раз в полторы секунды печатается, чего
        и сколько уже пришло.
    #>
    param([string]$Url, [string]$Target)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Target) -Force | Out-Null
    Remove-Item $Target -Force -ErrorAction SilentlyContinue

    $total = Get-RemoteSize -Url $Url
    if ($total) { Write-Line ("size: " + (Format-Size $total)) }

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) {
        $previous = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Target -Headers @{ 'User-Agent' = 'Audion-Sync-Tools' }
        } finally {
            $ProgressPreference = $previous
        }
        return
    }

    # Кавычки ставим сами: Start-Process склеивает список аргументов пробелами
    # как есть, и путь программы («Audion Sync Tools») разваливался надвое -
    # curl не понимал -o и печатал архив прямо в окно.
    $arguments = @('-sS', '-L', '--fail', '--retry', '5', '--retry-delay', '5',
                   '--connect-timeout', '30', '-A', 'Audion-Sync-Tools',
                   '-o', ('"{0}"' -f $Target), ('"{0}"' -f $Url))
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $curl.Source -ArgumentList $arguments -NoNewWindow -PassThru

    $shown = [datetime]::MinValue
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 300
        if (((Get-Date) - $shown).TotalMilliseconds -lt 1500) { continue }
        $shown = Get-Date

        $done = 0
        try { $done = (Get-Item -LiteralPath $Target -ErrorAction Stop).Length } catch { continue }
        $speed = $done / [Math]::Max(0.001, $watch.Elapsed.TotalSeconds)
        if ($total) {
            $left = ($total - $done) / [Math]::Max(1, $speed)
            Write-Line ('{0} of {1} ({2:N0}%), {3}/s, {4:N0} s left' -f `
                (Format-Size $done), (Format-Size $total), (100 * $done / $total), (Format-Size $speed), $left)
        } else {
            Write-Line ('{0}, {1}/s' -f (Format-Size $done), (Format-Size $speed))
        }
    }
    $watch.Stop()

    if ($proc.ExitCode -ne 0) { throw "the download failed (curl $($proc.ExitCode)): $Url" }

    $size = (Get-Item -LiteralPath $Target).Length
    Write-Line ('downloaded {0} in {1:N1} s - {2}/s' -f `
        (Format-Size $size), $watch.Elapsed.TotalSeconds,
        (Format-Size ($size / [Math]::Max(0.001, $watch.Elapsed.TotalSeconds)))) Green
}

function Assert-Publisher {
    <#
        Скачанное здесь запускается с правами администратора, поэтому до первого
        запуска сверяется, чьё оно: подпись должна быть действительной, а издатель -
        тем, кого ждём. До проверки 08.10.2026 «проверкой» был сам запуск: файл
        спрашивали о версии и по ответу судили, годен ли он.

        Подписаны клиент туннеля (Cloudflare) и терминал (Microsoft). rclone его
        издатель не подписывает: у него сверяется сумма, см. Assert-PublisherSum.
    #>
    param([string[]]$Path, [string]$Publisher, [string]$What)

    foreach ($file in $Path) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        $signer = [string]$(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' })
        if ($signature.Status -ne 'Valid' -or $signer -notmatch $Publisher) {
            throw ('{0}: {1} is not signed by its publisher (signature: {2}) - not installed' -f $What, (Split-Path -Leaf $file), $signature.Status)
        }
    }
}

function Assert-PublisherSum {
    <#
        Архив сверяется с суммой SHA-256, которую издатель кладёт рядом с выпуском
        (у rclone - файл SHA256SUMS в папке версии). Сумма с того же сервера
        говорит, что архив дошёл целым и что это тот файл, который выложен под
        этим номером; подписи она не заменяет.

        Не сошлась - архив не ставится. Нет файла сумм или строки в нём - об этом
        сказано, и установка идёт дальше: иначе сбой второго запроса не давал бы
        поставить инструмент вовсе, а первый запуск программы начинается с них.
    #>
    param([string]$File, [string]$Sums, [string]$Name, [string]$What)

    $line = @($Sums -split "`r?`n" | Where-Object { $_ -match ('^\s*[0-9a-fA-F]{64}\s+\*?' + [regex]::Escape($Name) + '\s*$') }) | Select-Object -First 1
    if (-not $line) {
        Write-Line ('{0}: the checksum of the publisher was not found - the archive is not compared' -f $What) Yellow
        return $false
    }
    $want = ([regex]::Match($line, '[0-9a-fA-F]{64}')).Value
    $have = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    if ($have -ne $want) { throw ('{0}: the archive does not match the checksum of its publisher - not installed' -f $What) }
    Write-Line ('{0}: the archive matches the checksum of its publisher' -f $What)
    return $true
}

function Install-Fresh {
    <#
        Кладёт распакованное на место старого. Прежняя папка не удаляется
        сразу: она уезжает в сторону и возвращается, если новое не заработало.
    #>
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Probe,
        [string[]]$ProbeArgs,
        [string[]]$Keep = @(),
        # Не запускать проверяемую программу, а прочесть версию файла.
        [switch]$NoRun
    )

    $backup = $Destination + '.prev'
    Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
    # Папки Tools может не быть вовсе: чистка убирает из неё всё, а пустая папка
    # в архив выпуска не попадает. Без неё первый же инструмент падал с
    # «Could not find a part of the path» (04.10.2026).
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null

    if (Test-Path -LiteralPath $Destination) {
        try { Move-Item $Destination $backup -Force }
        catch { throw ("the folder {0} is in use - close what runs from it and update again" -f $Destination) }
    }
    try {
        Move-Item $Source $Destination -Force

        # Нажитое переносим из прежней папки: настройки терминала и маркер
        # переносимости живут рядом с программой, и обновление их не касается.
        foreach ($name in $Keep) {
            $old = Join-Path $backup $name
            $new = Join-Path $Destination $name
            if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $new)) {
                Move-Item $old $new -Force
            }
        }

        $check = Join-Path $Destination $Probe
        if (-not (Test-Path -LiteralPath $check)) { throw "the unpacked files hold no $Probe" }
        # Терминал не запускаем: wt.exe без аргументов - это открыть окно, и на
        # экране владельца при каждой сборке всплывал пустой PowerShell
        # (26.09.2026). Для него хватает файла и его версии.
        $version = if ($NoRun) { (Get-Item -LiteralPath $check).VersionInfo.FileVersion } else { Get-Version -Path $check -Arguments $ProbeArgs }
        Remove-Item $backup -Recurse -Force -ErrorAction SilentlyContinue
        return $version
    } catch {
        Remove-Item $Destination -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $backup) { Move-Item $backup $Destination -Force }
        throw
    }
}

Write-Host "`n=== The tools the program carries ===`n" -ForegroundColor Cyan

$rcloneExe = Join-Path $ToolsDir 'rclone\rclone.exe'
$terminalExe = Join-Path $ToolsDir 'terminal\wt.exe'
$terminalMark = Join-Path $ToolsDir 'terminal\.version'

# Клиент туннеля живёт не в Tools, а в своей папке: он часть комплекта Tunnel
# и ищется там же, где его берут остальные сценарии.
$cloudflaredExe = Join-Path $AppRoot 'Tunnel\Bin\cloudflared.exe'
$cloudflaredUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

function Get-TerminalVersion {
    <#
        Своя пометка, а не версия файла: Microsoft оставляет в wt.exe номер
        базовой ветки, и после обновления на v1.24.11911.0 файл по-прежнему
        говорит 1.24.2607.10001. Настоящий выпуск пишется рядом при установке.
    #>
    if (Test-Path -LiteralPath $terminalMark) {
        return (Get-Content -LiteralPath $terminalMark -Raw).Trim()
    }
    if (Test-Path -LiteralPath $terminalExe) {
        return (Get-Item $terminalExe).VersionInfo.FileVersion + ' (by file)'
    }
    return 'none'
}

Write-Line ("tunnel client:  " + (Get-Version -Path $cloudflaredExe -Arguments @('--version')))
Write-Line ("rclone:         " + (Get-Version -Path $rcloneExe -Arguments @('version')))
Write-Line ("terminal:       " + (Get-TerminalVersion))
foreach ($carried in @(@('archiver:       ', 'PeaZip'), @('edit:           ', 'edit'), @('micro:          ', 'micro'))) {
    $stamp = Join-Path $ToolsDir (Join-Path $carried[1] 'version.txt')
    Write-Line ($carried[0] + $(if (Test-Path -LiteralPath $stamp) { (Get-Content -LiteralPath $stamp -Raw).Trim() } else { 'none' }))
}

if ($Check) {
    Write-Host "`n  That was a look around: nothing was downloaded.`n" -ForegroundColor Cyan
    if (-not $NoPause) { Write-Host "  Press Enter to close the window." -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $Aside -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Work -Force | Out-Null

try {
    try {
        # --- клиент туннеля ------------------------------------------------------
        # Тот же адрес, что и в Tunnel\Install-TunnelClient.ps1: там установка с
        # настройкой ssh, здесь - только замена файла, зато с весом и скоростью.
        if ($Cloudflared) {
            Write-Host ""
            Write-Host "  --- tunnel client ---" -ForegroundColor White

            Write-Step 1 2 'comparing versions'
            $have = ''
            if ((Get-Version -Path $cloudflaredExe -Arguments @('--version')) -match 'version (\S+)') { $have = $Matches[1] }
            $tag = Get-GithubTag 'cloudflare/cloudflared'
            if (Test-Fresh -Name 'tunnel client' -Have $have -Fresh $tag) { $Cloudflared = $false }
        }

        if ($Cloudflared) {
            Write-Step 2 2 'downloading and installing'
            $fresh = Join-Path $Work 'cloudflared.exe'
            Get-Package -Url $cloudflaredUrl -Target $fresh

            # Подпись Cloudflare - до первого запуска скачанного.
            Assert-Publisher -Path $fresh -Publisher '^CN="?Cloudflare, Inc\."?,' -What 'tunnel client'
            $version = (& $fresh --version 2>&1 | Select-Object -First 1)
            New-Item -ItemType Directory -Path (Split-Path -Parent $cloudflaredExe) -Force | Out-Null
            # Работающий клиент держит свой файл: заменить его нельзя, а убрать в
            # сторону можно - процесс доживает на прежнем файле, новые запуски
            # берут свежий.
            $held = ''
            if (Test-Path -LiteralPath $cloudflaredExe) {
                New-Item -ItemType Directory -Path $Aside -Force | Out-Null
                $held = Join-Path $Aside ('cloudflared-{0}.exe' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Move-Item -LiteralPath $cloudflaredExe -Destination $held -Force
            }
            try {
                Copy-Item -LiteralPath $fresh -Destination $cloudflaredExe -Force
            } catch {
                if ($held) { Move-Item -LiteralPath $held -Destination $cloudflaredExe -Force }
                throw
            }
            if ($held) { Remove-Item -LiteralPath $held -Force -ErrorAction SilentlyContinue }
            Write-Line ("tunnel client updated: " + $version) Green
            if ($held -and (Test-Path -LiteralPath $held)) { Write-Line 'the running tunnel client stays on the previous file until it exits' }
        }
    } catch {
        Write-Fail 'tunnel client' $_
    }

    try {
        # --- rclone --------------------------------------------------------------
        if ($Rclone) {
            Write-Host ""
            Write-Host "  --- rclone ---" -ForegroundColor White

            Write-Step 1 3 'comparing versions'
            $have = (Get-Version -Path $rcloneExe -Arguments @('version')).Trim()
            # У rclone есть отдельный файлик с номером - три десятка байт вместо
            # тридцати мегабайт.
            $fresh = ''
            try { $fresh = (& curl.exe -sS -A 'Audion-Sync-Tools' 'https://downloads.rclone.org/version.txt' 2>$null | Select-Object -First 1).Trim() } catch {}
            if (Test-Fresh -Name 'rclone' -Have $have -Fresh $fresh) { $Rclone = $false }
        }

        if ($Rclone) {
            Write-Step 2 3 'downloading the latest build'
            $zip = Join-Path $Work 'rclone.zip'
            Get-Package -Url 'https://downloads.rclone.org/rclone-current-windows-amd64.zip' -Target $zip

            # rclone не подписан: архив сверяется с суммой издателя из папки этой версии.
            $number = @($fresh -split '\s+' | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
            $sums = ''
            if ($number) {
                try { $sums = (& curl.exe -sS -L --fail -A 'Audion-Sync-Tools' ('https://downloads.rclone.org/{0}/SHA256SUMS' -f $number) 2>$null) -join "`n" } catch {}
            }
            [void](Assert-PublisherSum -File $zip -Sums $sums -Name ('rclone-{0}-windows-amd64.zip' -f $number) -What 'rclone')

            Write-Step 3 3 'unpacking and installing'
            $unpacked = Join-Path $Work 'rclone-unpacked'
            Expand-Package -Zip $zip -Destination $unpacked

            # В архиве папка вида rclone-v1.75.0-windows-amd64; берём её содержимое.
            $inner = Get-ChildItem $unpacked -Directory | Select-Object -First 1
            if (-not $inner) { throw 'the rclone archive is empty' }
            Write-Line ('files: {0}' -f (Get-ChildItem $inner.FullName -File).Count)

            $version = Install-Fresh -Source $inner.FullName -Destination (Join-Path $ToolsDir 'rclone') `
                -Probe 'rclone.exe' -ProbeArgs @('version')
            Write-Line ("rclone updated: " + $version) Green
        }
    } catch {
        Write-Fail 'rclone' $_
    }

    try {
        # --- терминал ------------------------------------------------------------
        if ($Terminal) {
            Write-Host ""
            Write-Host "  --- terminal ---" -ForegroundColor White

            Write-Step 1 4 'comparing versions'
            $tag = Get-GithubTag 'microsoft/terminal'
            if (-not $tag) { throw 'could not determine the latest terminal release' }
            if (Test-Fresh -Name 'terminal' -Have (Get-TerminalVersion) -Fresh $tag) { $Terminal = $false }
        }

        if ($Terminal) {
            # Нужна распакованная сборка (не MSIX): Microsoft.WindowsTerminal_<версия>_x64.zip.
            # Имя взято из карты приложений Audion TC, где терминал обновляется годами.
            $url = 'https://github.com/microsoft/terminal/releases/download/{0}/Microsoft.WindowsTerminal_{1}_x64.zip' -f $tag, $tag.TrimStart('v')

            Write-Step 2 4 'downloading the build'
            $zip = Join-Path $Work 'terminal.zip'
            Get-Package -Url $url -Target $zip

            Write-Step 3 4 'unpacking'
            $unpacked = Join-Path $Work 'terminal-unpacked'
            Expand-Package -Zip $zip -Destination $unpacked

            # Иногда файлы лежат в корне архива, иногда в одной папке внутри.
            $source = $unpacked
            if (-not (Test-Path (Join-Path $unpacked 'wt.exe'))) {
                $inner = Get-ChildItem $unpacked -Directory | Select-Object -First 1
                if ($inner) { $source = $inner.FullName }
            }

            # Каждая программа и библиотека пакета подписана Microsoft. Сверяется до
            # замены прежней копии; сам терминал не запускается - это открыло бы окно.
            Assert-Publisher -Path @(Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object { $_.FullName }) `
                -Publisher '^CN=Microsoft Corporation,' -What 'terminal'

            Write-Step 4 4 'replacing the old one and checking'
            # Маркер .portable уводит настройки в settings рядом с программой, а не
            # в профиль пользователя; оба переживают обновление.
            [void](Install-Fresh -Source $source -Destination (Join-Path $ToolsDir 'terminal') `
                -Probe 'wt.exe' -NoRun -Keep @('.portable', 'settings'))

            # Номер выпуска кладём рядом: в самом wt.exe он не меняется.
            Set-Content -LiteralPath $terminalMark -Value $tag -Encoding UTF8
            Write-Line ("terminal updated: " + $tag) Green
        }

        # Настройки программы для терминала лежат в config\terminal и накатываются на
        # установленный терминал: после чистки Tools ставится заново, и без этого он
        # открылся бы с заводскими настройками и писал бы их в профиль пользователя
        # (маркер .portable - тоже отсюда). Кладётся только недостающее: нажитые
        # настройки обжитой машины обновление переносит само и затирать их нельзя.
        # Шаг идёт и тогда, когда версия уже свежая, - терминал мог быть поставлен
        # до появления этой папки.
        $terminalDefaults = Join-Path $AppRoot 'config\terminal'
        if ($terminalAsked -and -not $Check -and (Test-Path -LiteralPath $terminalExe) -and
            (Test-Path -LiteralPath $terminalDefaults -PathType Container)) {
            $terminalRoot = Join-Path $ToolsDir 'terminal'
            $placed = 0
            foreach ($file in @(Get-ChildItem -LiteralPath $terminalDefaults -Recurse -File -Force)) {
                $relative = $file.FullName.Substring($terminalDefaults.Length).TrimStart('\')
                $target = Join-Path $terminalRoot $relative
                if (Test-Path -LiteralPath $target) { continue }
                New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $target
                $placed++
            }
            if ($placed) { Write-Line ("terminal settings from config\terminal: {0} file(s) placed" -f $placed) Green }
            else { Write-Line 'terminal settings: already in place' }
        }
    } catch {
        Write-Fail 'terminal' $_
    }

    # --- архиватор и редакторы ----------------------------------------------
    # Их ставит Install-Tools.ps1, взятый из Audion Disk Tools: сам сравнивает
    # версию с выпуском, качает, оставляет только нужное и пишет version.txt.
    # С ключом -Force перекачивает и одинаковую версию.
    foreach ($carried in @(@($PeaZip, 'peazip', 'archiver'), @($Edit, 'edit', 'edit'), @($Micro, 'micro', 'micro'))) {
        if (-not $carried[0]) { continue }
        try {
            Write-Host ""
            Write-Host ("  --- {0} ---" -f $carried[2]) -ForegroundColor White
            $installer = Join-Path $PSScriptRoot 'Install-Tools.ps1'
            # Успех вызова, а не $LASTEXITCODE: в той переменной лежит и код последней
            # программы, которую запускал кто угодно до установщика, а сам он при удаче
            # кончается без exit. Ложно оно только после его собственного exit не с нулём.
            if ($Force) { & $installer -Tool $carried[1] -Root $AppRoot; $ran = $? } else { & $installer -Tool $carried[1] -Root $AppRoot -IfNewer; $ran = $? }
            if (-not $ran) { throw ("Install-Tools.ps1 ended with code {0}" -f $LASTEXITCODE) }
        } catch {
            Write-Fail $carried[2] $_
        }
    }

    if ($failed.Count) {
        Write-Host ("`n  Update failed for: {0}.`n" -f ($failed -join ', ')) -ForegroundColor Red
        $code = 1
    } else {
        Write-Host "`n  Done.`n" -ForegroundColor Cyan
        $code = 0
    }
} catch {
    Write-Host "`n  Failed: $($_.Exception.Message)`n" -ForegroundColor Red
    $code = 1
} finally {
    Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
    # Пустую папку не оставляем; занятый файл в ней дождётся следующего запуска.
    if ((Test-Path -LiteralPath $Aside) -and -not (Get-ChildItem -LiteralPath $Aside -Force)) { Remove-Item -LiteralPath $Aside -Force }
}

if (-not $NoPause) {
    Write-Host "  Press Enter to close the window." -ForegroundColor DarkGray
    [void](Read-Host)
}
exit $code
