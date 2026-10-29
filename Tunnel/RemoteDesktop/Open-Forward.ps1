<#
.SYNOPSIS
    Проброс порта по ssh: рабочий стол, веб-морда устройства или прокси - без
    туннеля в системе.

.DESCRIPTION
    Всё, что умеет ssh, кроме файлов и команд: донести чужой порт до себя.

    Адрес после первого двоеточия разрешается НА ТОЙ СТОРОНЕ, а не здесь.
    Поэтому через одну машину видно всё, что видит она: рабочий стол её самой,
    веб-морду домашнего роутера, принтер, камеру, соседний компьютер. При этом
    в системе не меняется ничего - ни адаптера, ни маршрутов, ни DNS, ни спора
    с чужим VPN за драйвер. Кончилась работа - закрылось соединение, и следов
    не осталось.

    Туннель нужен только тогда, когда домашнюю сеть надо видеть целиком и
    сразу. Для одной машины или одного устройства проброс дешевле во всех
    смыслах.

    Держится он ровно столько, сколько открыто окно: закрыли рабочий стол -
    проброс снят.

.PARAMETER Target
    Куда идём: имя хоста из ~\.ssh\config - base, laptop, base-direct, base-cf.

.PARAMETER Kind
    Что пробрасываем:
      desktop - рабочий стол (3389) и сразу mstsc;
      web     - веб-морда (80) и сразу браузер;
      socks   - прокси на всю сеть той стороны, для браузера;
      port    - произвольный порт, задаётся ключами -RemoteHost и -RemotePort.

.PARAMETER RemoteHost
    Чей порт несём. По умолчанию - сама машина (127.0.0.1 с её стороны).

.PARAMETER Router
    Имя роутера в targets.json (router-base): его адрес становится -RemoteHost,
    если тот не задан. Так зовёт ROUTER WEB - адрес не зашит в враппер.

.PARAMETER RemotePort
    Порт на той стороне. Для `port` обязателен.

.PARAMETER LocalPort
    Порт у себя. Пустой - берётся свободный из 24000-24099.

.PARAMETER Root
    Папка данных этой машины.

.EXAMPLE
    .\Open-Forward.ps1 base desktop
    Рабочий стол BASE.

.EXAMPLE
    .\Open-Forward.ps1 base web -Router router-base
    Веб-морда домашнего роутера.

.EXAMPLE
    .\Open-Forward.ps1 base socks
    Прокси: браузер ходит по домашней сети целиком.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Target = 'base',
    [Parameter(Position = 1)][ValidateSet('desktop', 'web', 'socks', 'port')][string]$Kind = 'desktop',
    [string]$RemoteHost = '',
    [string]$Router = '',
    [int]$RemotePort = 0,
    [int]$LocalPort = 0,
    [string]$Root
)

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$TunnelRoot = Split-Path $Here -Parent

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Get-FreeLocalPort {
    <#
        Свободный порт у себя: занимаем его на миг сами, на том же адресе, что
        займёт ssh -L. Таблице соединений Windows не верим: в 26H2 (сборка 26300)
        она отдаёт состояния вразнобой, и занятый порт мог сойти за свободный.
    #>
    for ($p = 24000; $p -lt 24100; $p++) {
        $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
        try { $probe.Start(); return $p } catch { } finally { $probe.Stop() }
    }
    return 0
}

function Test-LocalPortAnswers {
    <# Отвечает ли порт у нас: стук в него, а не таблица соединений (см. выше). #>
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try { return ($client.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $client.Connected) }
    catch { return $false }
    finally { $client.Close() }
}

# --- Что именно несём --------------------------------------------------------
switch ($Kind) {
    'desktop' { if (-not $RemotePort) { $RemotePort = 3389 } }
    'web'     { if (-not $RemotePort) { $RemotePort = 80 } }
    'socks'   { }
    'port'    { if (-not $RemotePort) { throw 'для -Kind port нужен ключ -RemotePort' } }
}

if ($Router -and -not $RemoteHost) {
    Import-Module (Join-Path $Here 'RouterNdm.psm1') -Force -DisableNameChecking
    $RemoteHost = Get-RouterAddress -Router $Router -Root $Root
}

# Пустой адрес означает саму машину: с её стороны это её же localhost.
$far = $(if ($RemoteHost) { $RemoteHost } else { '127.0.0.1' })

if (-not $LocalPort) { $LocalPort = Get-FreeLocalPort }
if (-not $LocalPort) { throw 'свободного порта не нашлось' }

$what = switch ($Kind) {
    'desktop' { 'рабочий стол' }
    'web'     { 'веб-морда' }
    'socks'   { 'прокси на сеть' }
    'port'    { 'порт' }
}

Write-Host ("`n=== {0}: {1} через {2} ===`n" -f $what, $(if ($Kind -eq 'socks') { $Target } else { "${far}:${RemotePort}" }), $Target) -ForegroundColor Cyan

$ssh = Get-Command ssh -ErrorAction SilentlyContinue
if (-not $ssh) { Write-Line 'ssh на машине не найден' Yellow; Write-Host ''; exit 1 }

# --- Поднимаем проброс -------------------------------------------------------
# Без -N нельзя: с ним ssh не просит оболочку, а только держит канал. И
# ExitOnForwardFailure - чтобы занятый порт был виден сразу, а не притворялся
# рабочим пробросом.
$sshArgs = @(
    '-N',
    # Окно скрыто, спрашивать в нём некого: без BatchMode ssh молча ждал бы
    # пароль, процесс выглядел бы живым, а проброса не было бы вовсе - ровно
    # это и случилось при первой проверке.
    '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ServerAliveCountMax=3'
)
if ($Kind -eq 'socks') {
    $sshArgs += @('-D', ('127.0.0.1:{0}' -f $LocalPort))
} else {
    $sshArgs += @('-L', ('127.0.0.1:{0}:{1}:{2}' -f $LocalPort, $far, $RemotePort))
}
$sshArgs += $Target

$proc = Start-Process $ssh.Source -ArgumentList $sshArgs -PassThru -WindowStyle Hidden

# Живой процесс - ещё не поднятый проброс. Ждём, пока порт начнёт отвечать у
# нас: сессия встаёт за секунду-другую, через прыжок дольше.
$up = $false
for ($try = 0; $try -lt 12; $try++) {
    Start-Sleep 1
    if ($proc.HasExited) { break }
    if (Test-LocalPortAnswers $LocalPort) { $up = $true; break }
}

if (-not $up) {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Write-Line 'проброс не поднялся' Yellow
    Write-Line ("проверьте маршрут: ssh {0} hostname" -f $Target) Gray
    Write-Line 'если она просит пароль - нужен ключ: вход по паролю здесь не спросят' Gray
    Write-Host ''
    exit 1
}

Write-Line ("проброс поднят: 127.0.0.1:{0}" -f $LocalPort) Green

# --- Что с ним делать --------------------------------------------------------
$client = $null
try {
    switch ($Kind) {
        'desktop' {
            Write-Line 'открываю рабочий стол' Green
            $client = Start-Process 'mstsc.exe' -ArgumentList ('/v:127.0.0.1:{0}' -f $LocalPort) -PassThru
        }
        'web' {
            Write-Line 'открываю браузер' Green
            $client = Start-Process ('http://127.0.0.1:{0}/' -f $LocalPort) -PassThru
        }
        'socks' {
            Write-Line 'пропишите в браузере прокси SOCKS5:' Gray
            Write-Line ("    127.0.0.1 порт {0}" -f $LocalPort) 'White'
            Write-Line 'через него видна вся сеть той стороны - роутер, принтер, соседние машины' Gray
        }
        'port' {
            Write-Line ("порт {0}:{1} доступен как 127.0.0.1:{2}" -f $far, $RemotePort, $LocalPort) Green
        }
    }

    Write-Host ''
    if ($client) {
        Write-Line 'проброс держится, пока открыто окно клиента' Gray
        $client.WaitForExit()
    } else {
        Write-Line 'проброс держится, пока открыто это окно. Ctrl+C - закрыть' Gray
        while (-not $proc.HasExited) { Start-Sleep 1 }
    }
} finally {
    # Закрываем за собой всегда: брошенный проброс - открытая дверь, о которой
    # никто не помнит.
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        Write-Line 'проброс снят' Gray
    }
    Write-Host ''
}
