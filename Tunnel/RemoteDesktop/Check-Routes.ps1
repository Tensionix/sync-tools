<#
.SYNOPSIS
    Проверка всех маршрутов к домашним машинам. Ничего не меняет, пишет отчёт.

.DESCRIPTION
    Прогоняет по очереди каждый путь к BASE и говорит про каждый, дошёл он или
    нет и за сколько. Нужна там, где не спросишь совета: в чужой сети, без
    VPN, в поездке — запустил, получил файл, показал позже.

    Что проверяется:

        сеть          дом, MAIN VPS, cloudflare, SECOND VPS
        ssh           доходит ли до приветствия sshd и до входа по ключу
        файлы         читается ли каталог на BASE каждым из четырёх маршрутов
        туннель       поднята ли служба WG BASE-ROUTER и есть ли рукопожатие
        роутер        порт WG-сервера и пиры с их рукопожатиями
        MAIN VPS и SECOND VPS  туннели до дома, маршруты, видят ли они BASE
        скорость      с ключом -Speed: сколько тянет живой маршрут

    Отчёт кладётся в logs\routes-<дата>-<время>.log рядом с программой и
    печатается на экран.

.PARAMETER Speed
    Дополнительно замерить скорость: скачать с BASE файл и показать МБ/с.
    Занимает минуту-другую на канал.

.PARAMETER Path
    Что читать на BASE для проверки. По умолчанию корень диска S:.

.EXAMPLE
    .\Check-Routes.ps1
    Быстрая проверка: кто отвечает и какие маршруты живы.

.EXAMPLE
    .\Check-Routes.ps1 -Speed
    То же плюс замер скорости на живых маршрутах.
#>
[CmdletBinding()]
param(
    [switch]$Speed,
    [string]$Path = '/S:',
    [string]$Router = 'router-base',
    # Папка данных этой машины: окно передаёт её каждому врапперу. Из неё
    # берутся адреса и доступы; журнал живёт в папке программы.
    [string]$Root,
    [switch]$NoPause
)

$ErrorActionPreference = 'Continue'

$AppRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# SECOND VPS: адрес и имена хостов из targets.json.
. (Join-Path $AppRoot 'Engine\Targets.ps1')
$DataRoot = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
$SecondVps = Get-AbkSecondVps -AppRoot $AppRoot -DataRoot $DataRoot
# Адреса стационара и роутера - из targets.json (поле lan).
$BaseLan = ''
$RouterLan = ''
try {
    $known = Get-Content -LiteralPath (Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $BaseLan = [string]$known.base.lan
    $RouterLan = [string]$known.'router-base'.lan
} catch { }
$logDir = Join-Path $AppRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$report = Join-Path $logDir ('routes-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$lines = New-Object System.Collections.Generic.List[string]

function Say {
    param([string]$Text, [string]$Colour = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Colour
    $lines.Add($Text)
}

function Measure-Step {
    <# Выполняет проверку и возвращает, сколько она заняла. #>
    param([scriptblock]$Body)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ok = & $Body
    $watch.Stop()
    return [pscustomobject]@{ Ok = [bool]$ok; Seconds = $watch.Elapsed.TotalSeconds }
}

function Test-Port {
    param([string]$Address, [int]$Port, [int]$Timeout = 6)
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($Address, $Port)
        $done = $task.Wait($Timeout * 1000)
        $ok = $done -and $client.Connected
        $client.Close()
        return $ok
    } catch { return $false }
}

Write-Host "`n=== Маршруты к дому: проверка ===`n" -ForegroundColor Cyan
Say ('время: {0}' -f (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))
Say ''

# --- 1. Сеть -----------------------------------------------------------------
Say 'Сеть:' Cyan
foreach ($target in @(
    @{ Name = 'дом, BASE';        Address = $BaseLan;             Port = 22 }
    @{ Name = 'дом, роутер';      Address = $RouterLan;           Port = 22 }
    @{ Name = 'MAIN VPS по имени';  Address = 'direct.audion.dev';  Port = 22 }
    @{ Name = 'cloudflare';       Address = 'ssh.audion.dev';     Port = 443 }
    @{ Name = 'SECOND VPS';       Address = $SecondVps.Host;      Port = $SecondVps.Port }
)) {
    if (-not $target.Address) { continue }
    $step = Measure-Step { Test-Port -Address $target.Address -Port $target.Port }
    Say ('  {0,-18} {1,-6} {2,5:N1} c' -f $target.Name, $(if ($step.Ok) { 'есть' } else { 'нет' }), $step.Seconds) `
        $(if ($step.Ok) { 'Green' } else { 'Yellow' })
}
Say ''

# --- 2. ssh ------------------------------------------------------------------
# Порт может быть открыт, а протокол — обрублен: сети с фильтрацией сбрасывают
# соединение до приветствия sshd. Отличаем одно от другого.
Say 'ssh (доходит ли до приветствия):' Cyan
foreach ($host_ in $SecondVps.SshHost, 'audion-vps-direct', 'audion-vps') {
    $step = Measure-Step {
        $answer = & ssh -o ConnectTimeout=15 -o BatchMode=yes $host_ 'echo ok' 2>&1
        return ($answer -join ' ') -match 'ok'
    }
    $note = $(if ($step.Ok) { 'вошёл' } else { 'нет' })
    Say ('  {0,-20} {1,-8} {2,5:N1} c' -f $host_, $note, $step.Seconds) `
        $(if ($step.Ok) { 'Green' } else { 'Yellow' })
}
Say ''

# --- 3. Файлы ----------------------------------------------------------------
Say ('Чтение каталога {0} на BASE:' -f $Path) Cyan
$rclone = Join-Path $AppRoot 'Tools\rclone\rclone.exe'
$config = Get-AbkWorkPath -AppRoot $AppRoot -DataRoot $DataRoot -Rel 'config\rclone\rclone.conf'
$env:AWS_SHARED_CREDENTIALS_FILE = Join-Path $DataRoot 'config\rclone\r2.credentials'

$alive = @()
foreach ($route in @(
    @{ Name = 'ДОМ';    Remote = 'base:' }
    @{ Name = 'MAIN VPS'; Remote = 'base-direct:' }
    @{ Name = 'MAIN VPS CF'; Remote = 'base-cf:' }
    @{ Name = 'SECOND VPS'; Remote = 'base-via:' }
)) {
    $target = $route.Remote + $Path
    $step = Measure-Step {
        $answer = & $rclone lsf $target --config $config --dirs-only --timeout 30s 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    if ($step.Ok) { $alive += $route }
    Say ('  {0,-10} {1,-10} {2,5:N1} c' -f $route.Name, $(if ($step.Ok) { 'работает' } else { 'нет' }), $step.Seconds) `
        $(if ($step.Ok) { 'Green' } else { 'Yellow' })
}
Say ''

# --- 4. Скорость -------------------------------------------------------------
if ($Speed -and $alive.Count) {
    Say 'Скорость (скачивание с BASE):' Cyan
    $sample = Join-Path $env:TEMP ('abk-speed-{0}' -f (Get-Random))
    foreach ($route in $alive) {
        try {
            $file = & $rclone lsjson ($route.Remote + '/S:/Releases/_archives_private_full') --config $config --no-modtime 2>$null |
                    ConvertFrom-Json | Where-Object { $_.Size -gt 50MB } | Select-Object -First 1
            if (-not $file) { Say ('  {0,-10} нечего мерить' -f $route.Name); continue }

            Remove-Item $sample -Recurse -Force -ErrorAction SilentlyContinue
            $watch = [Diagnostics.Stopwatch]::StartNew()
            & $rclone copy ($route.Remote + '/S:/Releases/_archives_private_full/' + $file.Name) $sample `
                --config $config --max-duration 25s 2>&1 | Out-Null
            $watch.Stop()

            $got = (Get-ChildItem $sample -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            $speed = $(if ($watch.Elapsed.TotalSeconds -gt 0) { $got / 1MB / $watch.Elapsed.TotalSeconds } else { 0 })
            Say ('  {0,-10} {1,6:N2} МБ/с ({2:N0} МБ за {3:N0} c)' -f $route.Name, $speed, ($got / 1MB), $watch.Elapsed.TotalSeconds) Green
        } catch {
            Say ('  {0,-10} сорвалось: {1}' -f $route.Name, $_.Exception.Message) Yellow
        }
    }
    Remove-Item $sample -Recurse -Force -ErrorAction SilentlyContinue
    Say ''
}

# --- 5. Туннель этой машины --------------------------------------------------
# Туннель у машины один - WG BASE-ROUTER, до роутера BASE. Служба может
# работать, а рукопожатия не быть: пакеты уходят, ответ не возвращается.
# Разделяем одно и другое, потому что лечится это по-разному.
#
# Имя службы менялось - home, base, теперь router-base-wg, - а поставить её
# мог и WireGuard, и AmneziaWG: ищем все имена у обоих, как и окно.
# Рукопожатие туннель отдаёт только своему клиенту, поэтому спрашиваем каждого,
# кто на машине есть, до первого ответа.
Say 'Туннель на этой машине:' Cyan
$tunnelText = 'WG BASE-ROUTER, до роутера BASE'
$service = $null
foreach ($oldName in @('router-base-wg', 'base', 'home')) {
    foreach ($prefix in @('WireGuardTunnel$', 'AmneziaWGTunnel$')) {
        if (-not $service) { $service = Get-Service -Name ($prefix + $oldName) -ErrorAction SilentlyContinue }
    }
}
if (-not $service) {
    Say ('  {0,-14} не заведён   {1}' -f 'router-base-wg', $tunnelText)
} else {
    $tunnelName = $service.Name -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    # Разрядность своя: чужая сборка Red Shield вместо ошибки показывает
    # модальное окно «Несоответствие типа компьютера».
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })
    $shake = 'нечем спросить'
    foreach ($cli in @(
        "${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvawg.exe",
        "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvawg.exe",
        "$env:ProgramFiles\AmneziaWG\awg.exe",
        "${env:ProgramFiles(x86)}\AmneziaWG\awg.exe",
        "$env:ProgramFiles\WireGuard\wg.exe",
        "${env:ProgramFiles(x86)}\WireGuard\wg.exe"
    )) {
        if (-not (Test-Path -LiteralPath $cli)) { continue }
        $shake = 'прав не хватает'
        $dump = & $cli show $tunnelName latest-handshakes 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        $stamp = ($dump -split '\s+')[1]
        if ($stamp -and $stamp -ne '0') {
            $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$stamp)
            $shake = "рукопожатие $age c назад"
        } else { $shake = 'рукопожатий не было' }
        break
    }

    $good = $service.Status -eq 'Running' -and $shake -match 'рукопожатие \d+ c'
    Say ('  {0,-14} {1,-9} {2,-24} {3}' -f $tunnelName, $service.Status, $shake, $tunnelText) `
        $(if ($good) { 'Green' } else { 'Yellow' })
}
Say ''

# --- 6. Роутер ---------------------------------------------------------------
Say 'Роутер:' Cyan
$ndm = Join-Path $PSScriptRoot 'RouterNdm.psm1'
if (-not $RouterLan) {
    Say '  адреса роутера BASE в targets.json нет' Yellow
} elseif (-not (Test-Path $ndm)) {
    Say '  модуль разговора с роутером не найден' Yellow
} else {
    Import-Module $ndm -Force -DisableNameChecking
    $secret = Get-RouterSecret -Router $Router -Root $Root
    if (-not $secret) {
        Say '  пароль роутера не сохранён: check-router.cmd -Remember' Yellow
    } else {
        try {
            $session = Connect-Router -Address $RouterLan -Password $secret
            $face = Invoke-Rci -Session $session -Path 'show/interface/Wireguard2'
            Say ('  WG-сервер: порт {0}, состояние {1}' -f $face.wireguard.'listen-port', $face.state) Green
            foreach ($peer in @($face.wireguard.peer)) {
                $age = [int64]$peer.'last-handshake'
                $when = $(if ($age -gt 0 -and $age -lt 2147483647) { "$age c назад" } else { 'не было' })
                Say ('    пир {0,-14} рукопожатие {1}' -f $peer.description, $when)
            }
            Disconnect-Router -Session $session
        } catch {
            Say ('  недоступен отсюда: {0}' -f $_.Exception.Message.Split([Environment]::NewLine)[0]) Yellow
        }
    }
}
Say ''

# --- 7. MAIN VPS и SECOND VPS ------------------------------------------------
# Спрашиваем сами MAIN VPS и SECOND VPS, видят ли они дом: если да, а мы не видим - дело в
# нашей сети, а не в доме.
Say 'MAIN VPS и SECOND VPS:' Cyan
foreach ($server in @(
    @{ Host = 'audion-vps'; Text = 'MAIN VPS' }
    @{ Host = $SecondVps.SshHostCf; Text = 'SECOND VPS, через MAIN VPS' }
)) {
    if (-not $BaseLan) { Say '  адреса BASE в targets.json нет - спрашивать MAIN VPS и SECOND VPS не о чем' Yellow; break }
    $answer = & ssh -o ConnectTimeout=20 -o BatchMode=yes $server.Host `
        ('ping -c1 -W3 {0} >/dev/null 2>&1 && echo "дом виден" || echo "дом молчит"' -f $BaseLan) 2>&1
    $text = ($answer | Where-Object { $_ -match 'дом' } | Select-Object -Last 1)
    if (-not $text) { $text = 'не отозвался' }
    Say ('  {0,-14} {1,-12} {2}' -f $server.Host, $text, $server.Text) `
        $(if ($text -match 'виден') { 'Green' } else { 'Yellow' })
}
Say ''

Set-Content -LiteralPath $report -Value $lines -Encoding UTF8
Write-Host "  Отчёт: $report`n" -ForegroundColor Cyan
