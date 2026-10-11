<#
.SYNOPSIS
    Клиент Cloudflare Tunnel для доступа к MAIN VPS и SECOND VPS.

.DESCRIPTION
    Ставит cloudflared и прописывает три маршрута в ~/.ssh/config:

      audion-vps          через туннель (работает из сетей с фильтрацией, адрес MAIN VPS не участвует)
      audion-vps-direct   напрямую по IP (только под VPN)
      second-vps          SECOND VPS: имя, адрес и ключ - из targets.json, запись second

    Ключи и корень инструментов вычисляются от расположения скрипта,
    буква диска нигде не зашита.

    По умолчанию работает портативно: скачивает одиночный cloudflared.exe в
    подпапку Bin рядом со скриптом, в системе ничего не оставляет. Если
    cloudflared уже найден в PATH, берётся он — второй копии не заводим.

.PARAMETER Winget
    Поставить в систему через winget вместо портативной копии.

.PARAMETER Update
    Скачать свежий cloudflared вместо копии в Bin. Обновляется только тот
    экземпляр, что лежит рядом с этим скриптом: каждая копия программы живёт
    сама по себе. Релизы выходят раз в две-три недели, но клиентская часть
    меняется мало — обновлять имеет смысл раз в несколько месяцев или когда
    что-то сломалось.

.PARAMETER Check
    Ничего не менять, только показать текущее состояние.

.PARAMETER SkipSshConfig
    Поставить клиент, но не трогать ~/.ssh/config.

.EXAMPLE
    .\Install-TunnelClient.ps1
    .\Install-TunnelClient.ps1 -Update
    .\Install-TunnelClient.ps1 -Check
#>

[CmdletBinding()]
param(
    [switch]$Winget,
    [switch]$Update,
    [switch]$Check,
    [switch]$SkipSshConfig,
    [string]$Root,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# --- Точки на местности -----------------------------------------------------

$TunnelDir  = $PSScriptRoot                                  # ...\Audion Sync Tools\Tunnel
$ProjectDir = Split-Path -Parent $TunnelDir                  # ...\Audion Sync Tools
$ToolsRoot  = Split-Path -Parent $ProjectDir                 # ...\TOOLS
$BinDir     = Join-Path $TunnelDir 'Bin'

# Ключи лежат в подпапке SSH рядом со скриптом. Прежнее место — корень TOOLS —
# остаётся запасным: на машине со старой раскладкой установка не должна упасть.
# Ключи остались данными: программа переехала в Audion Sync Tools, склад
# ключей — нет. Путь считается от корня инструментов, буква диска не зашита.
. (Join-Path $ProjectDir 'Engine\DataRoot.ps1')
. (Join-Path $ProjectDir 'Engine\Secrets.ps1')
$DataRoot = Get-AbkDataRootPath -AppRoot $ProjectDir -Root $Root
$SshKeyDir = Join-Path $DataRoot 'Tunnel\SSH'

# SECOND VPS: адрес, имя хоста, ключ и учётная запись у каждого
# свои и лежат в targets.json.
. (Join-Path $ProjectDir 'Engine\Targets.ps1')
$SecondVps = Get-AbkSecondVps -AppRoot $ProjectDir -DataRoot $DataRoot

function Resolve-Key {
    <#
        Где лежит ключ и как записать путь к нему в ssh-конфиг.

        Профиль пользователя идёт первым, и путь оттуда пишется через `~`.
        Так он переживает и переименование папки данных, и переезд на другой
        диск. Раньше сюда попадал абсолютный путь в данные - и стоило папке
        сменить имя, как ssh переставал находить ключ: конфиг цел, маршруты
        прописаны, а входа нет.

        Дальше - склад: пары к внешним дверям лежат в servers, половины наших
        машин в clients. Ищем и там, и плоско: старые склады ещё не разложены,
        и ломаться из-за этого они не должны.
    #>
    param([string]$Name)

    if (Test-Path (Join-Path (Join-Path $HOME '.ssh') $Name)) { return ('~/.ssh/' + $Name) }

    foreach ($where in @('servers', 'clients', '')) {
        $path = $(if ($where) { Join-Path (Join-Path $SshKeyDir $where) $Name } else { Join-Path $SshKeyDir $Name })
        if (Test-Path $path) { return $path }
    }
    $legacy = Join-Path $ToolsRoot $Name
    if (Test-Path $legacy) { return $legacy }
    return (Join-Path $SshKeyDir $Name)
}

function Format-KeyPath {
    <#
        Как вписать путь в конфиг. Тильду ssh раскрывает сам, но только если
        она не в кавычках; абсолютный путь с пробелами - наоборот, только в
        кавычках. Отсюда две формы вместо одной.
    #>
    param([string]$Path)
    if ($Path -like '~/*') { return $Path }
    '"' + $Path + '"'
}

$VpsKey      = Resolve-Key 'audion_vps_root_ed25519'
$SecondKey   = Resolve-Key $SecondVps.Key

$VpsHostname   = 'ssh.audion.dev'
$VpsAddress    = 'direct.audion.dev'

$SshDir     = Join-Path $HOME '.ssh'
$SshConfig  = Join-Path $SshDir 'config'
$MarkBegin  = '# >>> audion-tunnel >>>'
$MarkEnd    = '# <<< audion-tunnel <<<'

$DownloadUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'

function Write-Step { param([string]$Text) Write-Host "  $Text" }
function Write-Good { param([string]$Text) Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text) Write-Host "  $Text" -ForegroundColor Red }

function Get-CloudflaredPath {
    # Порядок поиска: копия на уровень выше папки Tunnel, затем в Bin рядом со
    # скриптом, затем PATH, затем обычные места установки winget.
    #
    # Верхний уровень идёт первым ради Tabby: если комплект лежит внутри него,
    # exe кладётся в корень программы — рядом с Tabby.exe. Тогда в профиле можно
    # писать «cloudflared ...» без пути: Windows ищет программу сначала в каталоге
    # запускающего приложения, и профиль переживает переезд Tabby куда угодно.
    $besideHost = Join-Path $ProjectDir 'cloudflared.exe'
    if (Test-Path $besideHost) { return $besideHost }

    $portableExe = Join-Path $BinDir 'cloudflared.exe'
    if (Test-Path $portableExe) { return $portableExe }

    $inPath = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles      'cloudflared\cloudflared.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'cloudflared\cloudflared.exe'),
        (Join-Path $env:LOCALAPPDATA      'Microsoft\WinGet\Links\cloudflared.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Assert-Cloudflared {
    <#
        Скачанный клиент туннеля запускается с правами администратора, поэтому до
        первого запуска сверяется подпись: действительная и от Cloudflare. Файл,
        который её не прошёл, удаляется - он только что скачан сюда этим сценарием.
    #>
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $signer = [string]$(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' })
    if ($signature.Status -ne 'Valid' -or $signer -notmatch '^CN="?Cloudflare, Inc\."?,') {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        throw ('Скачанный cloudflared не подписан Cloudflare (подпись: {0}): файл удалён, ничего не установлено.' -f $signature.Status)
    }
}

function Install-Portable {
    # Если комплект лежит внутри программы-хозяина (Tabby), кладём exe в её
    # корень: тогда в профиле путь не нужен вовсе. Иначе — в свой Bin.
    if (Test-Path (Join-Path $ProjectDir 'Tabby.exe')) {
        $target = Join-Path $ProjectDir 'cloudflared.exe'
    }
    else {
        if (-not (Test-Path $BinDir)) {
            New-Item -ItemType Directory -Path $BinDir | Out-Null
        }
        $target = Join-Path $BinDir 'cloudflared.exe'
    }

    Write-Step "Качаю cloudflared в $target"
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $target -UseBasicParsing
    Assert-Cloudflared -Path $target
    return $target
}

function Install-Winget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget не найден. Запустите скрипт без ключей — портативная копия скачается в Bin.'
    }
    Write-Step 'Ставлю Cloudflare.cloudflared через winget'
    & winget install --id Cloudflare.cloudflared --exact --source winget `
        --accept-package-agreements --accept-source-agreements --disable-interactivity

    # winget не обновляет PATH текущего процесса — подтягиваем сами,
    # иначе следующая же проверка не найдёт свежепоставленный exe.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:PATH    = "$machinePath;$userPath"

    return Get-CloudflaredPath
}

function Update-Cloudflared {
    # Обновляем ровно тот экземпляр, которым пользуется эта копия комплекта.
    $target = Get-CloudflaredPath
    if (-not $target) {
        Write-Warn 'Обновлять нечего: копии нет. Запустите скрипт без ключей.'
        return
    }

    Write-Step "было: $(& $target --version 2>&1 | Select-Object -First 1)"

    $tmp = Join-Path $env:TEMP "cloudflared-new-$PID.exe"
    Write-Step 'Качаю свежий cloudflared'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $tmp -UseBasicParsing
    Assert-Cloudflared -Path $tmp
    Write-Good "скачано: $(& $tmp --version 2>&1 | Select-Object -First 1)"

    Copy-Item $tmp $target -Force
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Good "обновлено: $target"
}

function Show-TabbyHint {
    param([string]$CloudflaredPath)

    $dir = Split-Path -Parent $CloudflaredPath
    $besideHostApp = Test-Path (Join-Path $dir 'Tabby.exe')

    Write-Host ''
    Write-Host 'Профиль Tabby: хост ssh.audion.dev, порт 22, пользователь root.' -ForegroundColor Cyan
    Write-Host 'В поле «Proxy command»:' -ForegroundColor Cyan

    if ($besideHostApp) {
        # exe лежит рядом с Tabby.exe — путь не нужен, Windows найдёт его сам.
        Write-Host '  cloudflared access ssh --hostname ssh.audion.dev'
        Write-Step 'без пути: exe лежит рядом с Tabby.exe, профиль переживёт переезд'
    }
    else {
        Write-Host "  `"$CloudflaredPath`" access ssh --hostname ssh.audion.dev"
        Write-Step 'путь абсолютный: чтобы обойтись без него, положите cloudflared.exe рядом с Tabby.exe'
    }
}

function New-SshConfigBlock {
    param([string]$CloudflaredPath)

    # ProxyCommand уходит в OpenSSH как строка для CreateProcess,
    # поэтому путь кавычим — на случай пробелов в Program Files.
    $proxy = "`"$CloudflaredPath`" access ssh --hostname %h"

    $SecondBlock = New-SecondVpsBlock
    return @"
$MarkBegin
# Создано Install-TunnelClient.ps1. Правки внутри блока перезаписываются.

# Основной маршрут: канал строит сам MAIN VPS, наш адрес в схеме не участвует.
Host audion-vps
    HostName $VpsHostname
    User root
    IdentityFile $(Format-KeyPath $VpsKey)
    IdentitiesOnly yes
    HostKeyAlias audion-vps
    ProxyCommand $proxy
    ServerAliveInterval 30
    ServerAliveCountMax 3
    StrictHostKeyChecking accept-new

# Запасной: прямо по адресу. Из России не работает, под VPN — быстрее туннеля.
# HostKeyAlias тот же, поэтому отпечаток сверяется с одной записью known_hosts
# независимо от маршрута: подмена на пути будет замечена.
Host audion-vps-direct
    HostName $VpsAddress
    User root
    IdentityFile $(Format-KeyPath $VpsKey)
    IdentitiesOnly yes
    HostKeyAlias audion-vps
    ServerAliveInterval 30

$SecondBlock
$MarkEnd
"@
}

function New-SecondVpsBlock {
    <#
        Запись SECOND VPS для ~/.ssh/config.

        Адрес, имя, ключ и учётная запись - из targets.json. Если записи second
        там ещё нет, переписать блок без неё значило бы молча стереть маршрут,
        прописанный прежней версией. Поэтому прежняя запись переносится как
        есть, и об этом говорится вслух.
    #>
    if ($SecondVps.Host) {
        # Порт пишется, когда он не 22: его вписывают кнопкой АДРЕСА, и без этой
        # строки подключение шло бы на стандартный порт.
        $portLine = $(if ([int]$SecondVps.Port -gt 0 -and [int]$SecondVps.Port -ne 22) { "`r`n    Port $([int]$SecondVps.Port)" } else { '' })
        return @"
# SECOND VPS - внутри страны. Отсюда видно, как всё выглядит из местных сетей.
Host $($SecondVps.SshHost)
    HostName $($SecondVps.Host)$portLine
    User $($SecondVps.User)
    IdentityFile $(Format-KeyPath $SecondKey)
    IdentitiesOnly yes
    ServerAliveInterval 30
"@
    }

    if (Test-Path $SshConfig) {
        $existing = Get-Content $SshConfig -Raw
        $pattern = '(?s)' + [regex]::Escape($MarkBegin) + '(.*?)' + [regex]::Escape($MarkEnd)
        $block = [regex]::Match($existing, $pattern)
        if ($block.Success) {
            $kept = [regex]::Match($block.Groups[1].Value, '(?ms)^(?:#[^\r\n]*\r?\n)?Host\s+(?!audion-vps(?:-direct)?\s)\S+.*')
            if ($kept.Success) {
                Write-Warn 'SECOND VPS не вписан в targets.json - прежняя запись оставлена как была'
                return $kept.Value.TrimEnd()
            }
        }
    }
    return '# SECOND VPS: адрес не вписан в targets.json (запись second)'
}

function Update-SshConfig {
    param([string]$CloudflaredPath)

    if (-not (Test-Path $SshDir)) {
        New-Item -ItemType Directory -Path $SshDir | Out-Null
        Write-Step "Создал $SshDir"
    }

    $block = New-SshConfigBlock -CloudflaredPath $CloudflaredPath

    if (Test-Path $SshConfig) {
        $existing = Get-Content $SshConfig -Raw

        if ($existing -match [regex]::Escape($MarkBegin)) {
            # Блок уже есть — меняем только его, чужие записи не трогаем.
            $backup = "$SshConfig.bak"
            Copy-Item $SshConfig $backup -Force
            $pattern = '(?s)' + [regex]::Escape($MarkBegin) + '.*?' + [regex]::Escape($MarkEnd)
            $updated = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
            Set-Content -Path $SshConfig -Value $updated -Encoding UTF8 -NoNewline
            Write-Good "Обновил блок в $SshConfig (копия прежнего: $backup)"
        }
        else {
            Add-Content -Path $SshConfig -Value "`r`n$block`r`n" -Encoding UTF8
            Write-Good "Дописал блок в $SshConfig"
        }
    }
    else {
        Set-Content -Path $SshConfig -Value $block -Encoding UTF8
        Write-Good "Создал $SshConfig"
    }
}

function Test-Setup {
    param([string]$CloudflaredPath)

    Write-Host ''
    Write-Host 'Проверка' -ForegroundColor Cyan

    if ($CloudflaredPath) {
        $version = (& $CloudflaredPath --version 2>&1 | Select-Object -First 1)
        Write-Good "cloudflared: $CloudflaredPath"
        Write-Step  "версия: $version"
    }
    else {
        Write-Bad 'cloudflared не найден'
    }

    foreach ($k in @($VpsKey, $SecondKey)) {
        if (Test-Path $k) { Write-Good "ключ на месте: $k" }
        else               { Write-Bad  "ключа нет: $k" }
    }

    # Имя должно резолвиться. Тип не проверяем: при включённом прокси Cloudflare
    # отдаёт A-записи своих серверов, а не CNAME на туннель, — CNAME виден только
    # в панели. Пока запись не создана, здесь пусто; это самая частая причина отказа.
    try {
        $answers = @(Resolve-DnsName -Name $VpsHostname -ErrorAction Stop |
                     Where-Object { $_.IPAddress -or $_.NameHost })
        if (-not $answers) { throw 'пустой ответ' }
        $shown = ($answers | ForEach-Object { if ($_.IPAddress) { $_.IPAddress } else { $_.NameHost } }) -join ', '
        Write-Good "$VpsHostname → $shown"
    }
    catch {
        Write-Warn "$VpsHostname не резолвится — создайте в Cloudflare DNS запись:"
        Write-Step 'тип CNAME, имя ssh, значение <ID туннеля>.cfargotunnel.com, прокси включён'
    }

    if (Test-Path $SshConfig) {
        $hasBlock = (Get-Content $SshConfig -Raw) -match [regex]::Escape($MarkBegin)
        if ($hasBlock) { Write-Good "маршруты прописаны в $SshConfig" }
        else           { Write-Warn "в $SshConfig нет нашего блока" }
    }
    else {
        Write-Warn "$SshConfig отсутствует"
    }

    Write-Host ''
    Write-Host 'Дальше: ssh audion-vps' -ForegroundColor Cyan
}

# --- Работа -----------------------------------------------------------------

Write-Host ''
Write-Host 'Клиент туннеля Audion' -ForegroundColor Cyan
Write-Host ''

$cloudflared = Get-CloudflaredPath

if ($Check) {
    Test-Setup -CloudflaredPath $cloudflared
    if ($cloudflared) { Show-TabbyHint -CloudflaredPath $cloudflared }
    return
}

if ($Update) {
    Update-Cloudflared
    return
}

if ($cloudflared) {
    Write-Good "cloudflared уже стоит: $cloudflared"
}
else {
    $cloudflared = if ($Winget) { Install-Winget } else { Install-Portable }
    if (-not $cloudflared) {
        throw 'Установка прошла, но exe не найден. Проверьте PATH или запустите без ключей — тогда копия ляжет в Bin.'
    }
    Write-Good "cloudflared: $cloudflared"
}

if (-not $SkipSshConfig) {
    foreach ($keyPath in @($VpsKey, $SecondKey) | Select-Object -Unique) {
        if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
            if (-not (Protect-AbkSshPrivateKey -Path $keyPath)) { throw ('Не удалось исправить ACL приватного SSH-ключа: ' + $keyPath) }
        }
    }
    Update-SshConfig -CloudflaredPath $cloudflared
}

Test-Setup -CloudflaredPath $cloudflared
Show-TabbyHint -CloudflaredPath $cloudflared
