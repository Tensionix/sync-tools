<#
.SYNOPSIS
    WG BASE-ROUTER: туннель от этой машины до WG-сервера на роутере
    BASE. WG-сервер там один на всё хозяйство - роутеры HOME и WORK так не умеют,
    у них WireGuard только клиентом.

.DESCRIPTION
    Поднимает на машине туннель WireGuard прямо к домашнему роутеру. Пока он
    поднят, домашняя сеть видна так же, как если бы машина стояла дома: к
    стационару идут по его домашнему адресу, файлы забирают тем же путём, крюк
    через SECOND VPS не нужен.

    Ходит через туннель только сеть BASE. Заворачиваются лишь тамошние
    подсети, а обычный интернет идёт как шёл — напрямую. Так быстрее, и так
    обходится известная беда: при заворачивании всего трафика через дом
    HTTPS-сайты переставали открываться, хотя пинг и обычный HTTP работали.

    Конфиг выдаёт сам роутер. В его настройках WG-сервер заводится
    клиент (кнопка «Добавить пользователя»), роутер показывает QR-код и файл —
    файл и скармливается этому скрипту. Свои ключи скрипт не выдумывает: пара
    уже сгенерирована роутером и записана в тот файл.

.PARAMETER From
    Путь к файлу конфига, выданному роутером. Если не указан, скрипт ищет
    свежий .conf в «Загрузках» и в папке config рядом с собой.

.PARAMETER Name
    Имя туннеля и его службы. По умолчанию `home`.

.PARAMETER FullTunnel
    Завернуть в туннель весь трафик машины, а не только домашние сети. Даёт
    машине домашний адрес в интернете, но по опыту 27.08 в такой схеме
    переставали открываться HTTPS-сайты — включать только осознанно.

.PARAMETER Endpoint
    Чем заменить адрес роутера из конфига: «адрес:порт». Роутер выписывает
    конфиг на своё доменное имя, а оно работает, только когда опубликовано
    наружу. Пока имени нет, сюда ставится прямой адрес - с оговоркой, что у
    домашнего провайдера он может смениться.

.PARAMETER Install
    Только поставить WireGuard и выйти: ни туннеля, ни службы, ни конфига. Нужен,
    когда машина новая, а конфиг от роутера ещё не выписан - программу можно
    поставить заранее, одним нажатием.

.PARAMETER Check
    Ничего не менять, только показать: стоит ли WireGuard, есть ли служба, живо
    ли рукопожатие с роутером, видна ли домашняя сеть.

.PARAMETER Remove
    Снять туннель: остановить и удалить службу. Конфиг остаётся на месте —
    повторный запуск поднимет всё заново.

.EXAMPLE
    .\Setup-BaseVpn.ps1 -From "$env:USERPROFILE\Downloads\wg-laptop.conf"
    Поднять туннель до router-base из файла, скачанного с роутера.

.EXAMPLE
    .\Setup-BaseVpn.ps1 -Install
    Поставить сам WireGuard, ничего не поднимая.

.EXAMPLE
    .\Setup-BaseVpn.ps1 -Check
    Посмотреть, жив ли туннель и видна ли домашняя сеть.
#>
[CmdletBinding()]
param(
    [string]$From,
    [string]$Name = 'router-base-wg',
    [switch]$FullTunnel,
    [string]$Endpoint,
    [switch]$Install,
    [switch]$Check,
    [switch]$Remove,
    [switch]$AtBoot,
    # Служебный признак самоподнятия прав. Руками не передавать.
    [switch]$Elevated,
    # Папка данных этой машины. Стоит последней: позиционные аргументы
    # старше - `Connect-Files.ps1 router` должен означать цель, а не путь.
    [string]$Root,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# --- Что считается домом -----------------------------------------------------
# Две подсети за домашний роутер плюс сеть самого WG-сервера роутера. Всё остальное
# туннель не трогает.
# Что заворачивать в туннель, решает файл routes.txt рядом с конфигами: одна
# сеть на строку, решётка - комментарий. В коде остаётся лишь умолчание, с
# которым программа выросла: у другого человека сети другие, а на чужой машине
# они могут пересечься с местной - и тогда в туннель уедет её собственная сеть
# вместе с принтерами и общими папками.
$DefaultNets = @('192.168.10.0/24')

# По чему проверяется, что путь действительно открылся: стационар BASE и сам
# роутер. Адреса - из targets.json (поле lan), ниже, когда известна папка config.

# --- Пути от расположения скрипта, без жёсткого диска ------------------------
$Here        = $PSScriptRoot
$CfgDir      = Join-Path $Here 'config'
# Адреса живут в папке данных: резолвер грузим здесь, раньше остального.
$TunnelRoot  = Split-Path $Here -Parent                      # ...\Tunnel
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\DataRoot.ps1')
$DataRoot    = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root
$HomeProbe = @()
try {
    $targetsFile = Join-Path $DataRoot 'Tunnel\RemoteDesktop\config\targets.json'
    if (Test-Path -LiteralPath $targetsFile) {
        $known = Get-Content -LiteralPath $targetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($pair in @(@('base', 'BASE'), @('router-base', 'роутер BASE'))) {
            $address = [string]$known.($pair[0]).lan
            if ($address) { $HomeProbe += @{ Name = $pair[1]; Address = $address } }
        }
    }
} catch { }
# Внутри конфига закрытый ключ этой машины, поэтому лежит он не в папке
# программы, а в данных - рядом со складом ssh. Папка данных у каждой машины
# своя и копией программы не уезжает.
$TunnelRoot  = Split-Path $Here -Parent                      # ...\Tunnel
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\DataRoot.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\Secrets.ps1')
. (Join-Path (Split-Path -Parent $TunnelRoot) 'Engine\Routes.ps1')
$DataRoot = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $TunnelRoot) -Root $Root
$KeyDir      = Join-Path $DataRoot 'Tunnel\WG'
$RoutesFile  = Join-Path $KeyDir 'routes.txt'

$HomeNets = @()
if (Test-Path -LiteralPath $RoutesFile) {
    foreach ($line in (Get-Content -LiteralPath $RoutesFile)) {
        # Разделителем может оказаться что угодно: файл правят и рукой, и
        # окном. Строка «192.168.1.0/24 192.168.2.0/24» уехала бы в конфиг
        # целиком, и WireGuard её не понял бы.
        foreach ($net in (($line -split '#')[0] -split '[\s,;]+')) {
            $clean = $net.Trim()
            if ($clean) { $HomeNets += $clean }
        }
    }
}
if (-not $HomeNets.Count) { $HomeNets = $DefaultNets }
$TunConf     = Join-Path $KeyDir "$Name.conf"
$ServiceName = "WireGuardTunnel`$$Name"

# Раньше маршрут в сеть BASE звался домом, и служба - тоже. Снимаем прежнюю: две
# службы на один канал не нужны, а имя `home` теперь принадлежит машине HOME.
$LegacyNames = @('base', 'home')   # как туннель звался раньше

foreach ($dir in @($CfgDir, $KeyDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# Переезд со старого места. Осмотр ничего не двигает - читает там, где лежит.
$LegacyConf = Join-Path $CfgDir "$Name.conf"
if ((Test-Path $LegacyConf) -and -not (Test-Path $TunConf)) {
    if ($Check) {
        $TunConf = $LegacyConf
    } else {
        try {
            Move-Item -LiteralPath $LegacyConf -Destination $TunConf -Force
            Write-Host "  перенесено в данные: $Name.conf" -ForegroundColor Yellow
        } catch {
            $TunConf = $LegacyConf
            Write-Host "  не удалось перенести $Name.conf - остался в папке программы" -ForegroundColor Yellow
        }
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Find-WireGuard {
    $c = Get-Command 'wireguard.exe' -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\WireGuard\wireguard.exe",
                     "${env:ProgramFiles(x86)}\WireGuard\wireguard.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Find-Awg {
    <#
        Клиент AmneziaWG, если он на машине есть. Свой мы не ставим никогда.

        Ищем два места: Red Shield VPN - он на AmneziaWG и держит клиент у себя
        в awg\<платформа>\rsvamneziawg.exe, - и официальный клиент AmneziaWG,
        если его поставили отдельно. Рядом эти двое не живут: имена служб у них
        совпадают, и установщик официального спотыкается о службу Red Shield.
    #>
    # Разрядность своя. Red Shield кладёт рядом сборки под amd64 и arm64, и
    # запуск чужой - не тихая ошибка: Windows показывает модальное окно
    # «Несоответствие типа компьютера», которое не поймать ни try, ни catch.
    # А состояние опрашивается по таймеру, так что окно всплывало снова и снова.
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
                  $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })

    foreach ($try in @(
        "${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvamneziawg.exe",
        "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvamneziawg.exe",
        "$env:ProgramFiles\AmneziaWG\amneziawg.exe"
    )) {
        if ($try -and (Test-Path -LiteralPath $try)) { return $try }
    }
    ''
}

function Find-Wg {
    <#
        Утилита wg(8): ею считаются ключи. Своя есть и у AmneziaWG, и берём её
        первой - на машине с чужим VPN клиент AmneziaWG уже стоит, а обычный
        WireGuard может не стоять вовсе, и ставить его только ради genkey не за
        чем.

        Разрядность своя: запуск сборки не под свою машину показывает модальное
        окно Windows, которое ничем не поймать.
    #>
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
                  $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })
    foreach ($p in @("${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvawg.exe",
                     "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvawg.exe",
                     "$env:ProgramFiles\AmneziaWG\awg.exe",
                     "${env:ProgramFiles(x86)}\AmneziaWG\awg.exe",
                     'wg.exe',
                     "$env:ProgramFiles\WireGuard\wg.exe",
                     "${env:ProgramFiles(x86)}\WireGuard\wg.exe")) {
        $c = Get-Command $p -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Test-Endpoint {
    <#
        Проверяет, что адрес роутера из конфига виден ИЗВНЕ.

        Спрашивать системный резолвер бесполезно: дома имя роутера отдаёт сам
        роутер, и проверка всегда говорит «есть», а из чужой сети имени не
        существует и служба Windows падает с «Этот хост неизвестен». Поэтому
        спрашиваем публичные резолверы, и только если до них не достучаться -
        отвечаем по системному, честно пометив, что проверка местная.
    #>
    param([Parameter(Mandatory)][string]$Value)

    $host_ = ($Value -split ':')[0]
    if ($host_ -match '^\d{1,3}(\.\d{1,3}){3}$') {
        return @{ Ok = $true; Where = 'прямой адрес' }
    }

    foreach ($server in '1.1.1.1', '8.8.8.8') {
        try {
            $answer = Resolve-DnsName -Name $host_ -Server $server -Type A -ErrorAction Stop -QuickTimeout
            if ($answer | Where-Object { $_.IPAddress }) {
                return @{ Ok = $true; Where = "виден снаружи ($server)" }
            }
            return @{ Ok = $false; Where = "снаружи не виден ($server)" }
        } catch [System.ComponentModel.Win32Exception] {
            # Имени нет - это ответ, а не сбой связи.
            return @{ Ok = $false; Where = "снаружи не виден ($server)" }
        } catch {
            continue
        }
    }

    try {
        [void][System.Net.Dns]::GetHostAddresses($host_)
        return @{ Ok = $true; Where = 'проверено только местным резолвером' }
    } catch {
        return @{ Ok = $false; Where = 'не разрешается и местным резолвером' }
    }
}

function Install-WireGuard {
    <#
        Ставит сам WireGuard. Портативным он не бывает: туннель поднимается
        службой, а служба ставится установщиком - поэтому winget и права.
    #>
    Write-Line "ставлю WireGuard через winget, это займёт минуту..." Yellow

    # winget пишет в UTF-8, а консоль на русской Windows читает вывод дочернего
    # процесса кодовой страницей OEM - без подмены сообщения приезжают
    # кракозябрами. Возвращаем прежнюю кодировку в любом случае.
    $previous = [Console]::OutputEncoding
    $log = @()
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $log = & winget install --id WireGuard.WireGuard --silent `
            --accept-source-agreements --accept-package-agreements 2>&1
    } finally {
        [Console]::OutputEncoding = $previous
    }

    $found = Find-WireGuard
    if (-not $found) {
        # Простыню установщика показываем только когда она нужна: разбираться,
        # почему не встало.
        $log | Select-Object -Last 12 | ForEach-Object { Write-Line $_ DarkGray }
        throw "WireGuard не установился - поставь вручную и запусти снова"
    }
    return $found
}

function Find-RouterConfig {
    # Свежий конфиг от роутера: сначала явно указанный, потом уже принятый,
    # потом самый свежий .conf в «Загрузках» — туда роутер его и кладёт.
    if ($From) {
        if (-not (Test-Path $From)) { throw "Файла нет: $From" }
        return (Resolve-Path $From).Path
    }
    if (Test-Path $TunConf) { return $TunConf }

    # Конфиг этой машины под прежним именем. Искать его надо раньше, чем
    # выписанные мастером: те лежат в той же папке и зовутся по имени пира, а
    # пиров у роутера несколько - рабочая машина среди них. Однажды сюда и
    # попал чужой: wg-srv_audion-work.conf оказался свежее, скрипт взял его
    # вместе с чужим ключом и чужим адресом, и роутер молча отбрасывал пакеты -
    # ключ приходил свой, а адрес чужой, такому пиру он не разрешён. Со стороны
    # это выглядело как «поднял и тишина», причём на любом клиенте.
    foreach ($old in $LegacyNames) {
        $was = Join-Path (Split-Path -Parent $TunConf) "$old.conf"
        if (Test-Path -LiteralPath $was) { return $was }
    }

    # Конфиг, только что выписанный мастером пира, лежит рядом и называется по
    # имени пира: wg-srv_audion-work.conf. Кнопке неоткуда знать это имя, и
    # человеку не за чем набирать путь руками - берём свежий из тех, что там
    # есть.
    $issued = Get-ChildItem -LiteralPath (Split-Path -Parent $TunConf) -Filter 'wg-srv_*.conf' `
        -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($issued) {
        # Имя пира стоит в имени файла - показываем его. Это единственное
        # место, где до установки видно, что конфиг выписан не этой машине.
        Write-Host ("  беру выписанный конфиг пира: " + ($issued.BaseName -replace '^wg-srv_', '')) -ForegroundColor Yellow
        Write-Host "  не эта машина - выпиши свой кнопкой ROUTER WG PEER и запусти снова`n" -ForegroundColor Yellow
        return $issued.FullName
    }
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path $dl) {
        $c = Get-ChildItem $dl -Filter '*.conf' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($c) { return $c.FullName }
    }
    return $null
}

# --- Самоподнятие прав -------------------------------------------------------
if (-not $Check -and -not (Test-Admin)) {
    Write-Host "Нужны права администратора — поднимаю (UAC)..." -ForegroundColor Yellow
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
                 '-Name',$Name,'-Elevated')
    # Выбранную папку передаём дальше: повышенный процесс ищет её заново,
    # и рядом их может оказаться несколько - тогда он либо остановится с
    # вопросом, либо (до этой правки) взял бы чужую.
    if ($Root) { $argList += @('-Root', ('"' + ($Root -replace '(\\+)$', '$1$1') + '"')) }
    if ($From)       { $argList += @('-From', "`"$From`"") }
    if ($FullTunnel) { $argList += '-FullTunnel' }
    if ($Remove)     { $argList += '-Remove' }
    if ($Install)    { $argList += '-Install' }
    if ($AtBoot)     { $argList += '-AtBoot' }
    if ($Endpoint)   { $argList += @('-Endpoint', $Endpoint) }
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    if ($NoPause) { $argList += '-NoPause' }
    Start-Process $psExe -Verb RunAs -ArgumentList $argList
    exit 0
}

function Complete-Run {
    # Повышенное окно закрывается само; придержим его, чтобы итог успели прочесть.
    param([int]$Code = 0)
    if ($Elevated -and -not $NoPause) {
        Write-Host "  Нажми Enter, чтобы закрыть окно." -ForegroundColor DarkGray
        [void](Read-Host)
    }
    exit $Code
}

trap {
    Write-Host "`n  Сорвалось: $($_.Exception.Message)`n" -ForegroundColor Red
    Complete-Run 1
}

Write-Host "`n=== WG BASE-ROUTER: туннель '$Name' до роутера BASE ===`n" -ForegroundColor Cyan

# Переезд с прежнего имени - до всего остального.
foreach ($legacy in $LegacyNames) {
    if ($Check) { break }
    if ($legacy -eq $Name) { continue }
    if (-not (Get-Service -Name ("WireGuardTunnel`$" + $legacy) -ErrorAction SilentlyContinue) -and
        -not (Get-Service -Name ("AmneziaWGTunnel`$" + $legacy) -ErrorAction SilentlyContinue)) { continue }
    $old = Find-WireGuard
    if ($old) {
        & $old /uninstalltunnelservice $legacy
        Start-Sleep 2
        Write-Line "прежняя служба под именем $legacy снята" Yellow
    }
}

$wireguard = Find-WireGuard
$wg = Find-Wg

# На чём поднимать туннель. Основной движок - классический WireGuard: он свой,
# ставится нами и ни от кого не зависит.
#
# Уступаем ему место только по необходимости. Если на машине стоит клиент
# AmneziaWG - обычно он приходит вместе с чужим VPN, - то классический туннель
# с этим VPN не уживётся: AmneziaWG форк WireGuard, драйвер ядра у них общий,
# но версии разные, а грузится он один на систему. Занявший первым решает за
# остальных: версия Amnezia умеет и обфускацию, и обычный WireGuard, обычная -
# только обычный. Отсюда и наблюдалось: VPN не соединялся, пока наши туннели
# стояли на классическом клиенте.
#
# Поэтому при найденном AmneziaWG ставим туннель на нём - не потому, что он
# лучше, а чтобы не отбирать у человека его VPN. Своего клиента не ставим и
# чужой не трогаем.
$awg = Find-Awg
if ($awg) {
    $engine = $awg
    $ServiceName = "AmneziaWGTunnel`$$Name"
} else {
    $engine = $wireguard
}

# Раньше выше печаталась строка «WG: ...» с путём к обычному клиенту, и её
# читали как ответ на вопрос «чем ставим». Отвечаем прямо: тем, что выбрано.
Write-Line ("ставим на: " + $(if ($awg) { "AmneziaWG - $engine" } else { "WireGuard - $engine" })) `
    $(if ($awg) { 'Yellow' } else { 'Green' })
Write-Line ("служба будет зваться: " + $ServiceName) Gray

function Remove-AnyTunnel {
    <#
        Снимает службу туннеля, чем бы она ни была поставлена.

        Клиентов два - обычный WireGuard и AmneziaWG, - и служба зовётся по
        тому, кто её ставил: `WireGuardTunnel$имя` или `AmneziaWGTunnel$имя`.
        Снимать надо тем же клиентом: чужую службу другой не видит и молча
        ничего не делает. А переставлять приходится как раз при переходе с
        одного на другой - иначе останутся две службы с одним именем внутри.
    #>
    param([Parameter(Mandatory)][string[]]$TunnelName)

    # Имя менялось: home, base, теперь router-base-wg. Снимаем всё, что найдём
    # под любым из них - иначе «СНЯТЬ» промахивается мимо работающего туннеля,
    # заведённого прежней версией.
    $pairs = @()
    foreach ($one in $TunnelName) {
        $pairs += @{ Service = "WireGuardTunnel`$$one"; Exe = $wireguard; Name = $one }
        $pairs += @{ Service = "AmneziaWGTunnel`$$one"; Exe = $awg;       Name = $one }
    }

    $gone = $false
    foreach ($pair in $pairs) {
        if (-not (Get-Service -Name $pair.Service -ErrorAction SilentlyContinue)) { continue }

        if ($pair.Exe) {
            & $pair.Exe /uninstalltunnelservice $pair.Name
            Start-Sleep 2
        }

        # Клиента могло и не остаться: Red Shield удалили, официальный не
        # поставили - а служба висит. Тогда убираем её напрямую: программа
        # идёт с правами администратора, и это ровно то же самое, что делает
        # сам клиент.
        if (Get-Service -Name $pair.Service -ErrorAction SilentlyContinue) {
            & sc.exe stop $pair.Service 2>&1 | Out-Null
            Start-Sleep 2
            & sc.exe delete $pair.Service 2>&1 | Out-Null
            Start-Sleep 1
        }

        if (Get-Service -Name $pair.Service -ErrorAction SilentlyContinue) {
            Write-Line "служба $($pair.Service) не снялась" Red
        } else {
            Write-Line "снята служба $($pair.Service)" Gray
            $gone = $true
        }
    }
    $gone
}


# --- Режим осмотра -----------------------------------------------------------
if ($Check) {
    # Ищем службу под всеми именами и обоими клиентами: туннель мог быть
    # заведён прежней версией и зваться base или home.
    $liveName = ''
    $liveService = ''
    foreach ($one in (@($Name) + $LegacyNames)) {
        foreach ($prefix in @('WireGuardTunnel$', 'AmneziaWGTunnel$')) {
            if (Get-Service -Name ($prefix + $one) -ErrorAction SilentlyContinue) {
                $liveName = $one
                $liveService = $prefix + $one
                break
            }
        }
        if ($liveService) { break }
    }
    if ($liveService) {
        $ServiceName = $liveService
        # Конфиг зовётся так же, как служба: раз туннель живёт под прежним
        # именем, то и файл рядом с ним - base.conf, а не router-base-wg.conf.
        $liveConf = Join-Path $KeyDir "$liveName.conf"
        if (Test-Path -LiteralPath $liveConf) { $TunConf = $liveConf }
    }

    # Когда туннели идут на AmneziaWG, обычный клиент не нужен вовсе - и его
    # отсутствие не повод для жёлтого цвета. Тревожить стоит, когда нет ни
    # одного: тогда и поднимать нечем.
    Write-Line ("WireGuard: " + $(if ($wireguard) { $wireguard }
                                  elseif ($awg) { 'не нужен - туннели на AmneziaWG' }
                                  else { 'НЕ установлен' })) `
        $(if ($wireguard) { 'Green' } elseif ($awg) { 'Gray' } else { 'Yellow' })

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($liveName -and $liveName -ne $Name) {
        Write-Line "туннель живёт под прежним именем: $liveName" Yellow
        Write-Line "  переустановка мастером заведёт его как $Name" Gray
    }
    Write-Line ("Служба туннеля: " + $(if ($svc) { $svc.Status } else { 'нет' })) `
        $(if ($svc -and $svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })

    Write-Line ("Конфиг: " + $(if (Test-Path $TunConf) { 'на месте' } else { 'нет' }))

    if (Test-Path $TunConf) {
        $point = (Select-String -Path $TunConf -Pattern '^\s*Endpoint\s*=\s*(.+)$' |
                  Select-Object -First 1).Matches.Groups[1].Value
        if ($point) {
            $reach = Test-Endpoint -Value $point.Trim()
            Write-Line ("Endpoint: {0} — {1}" -f $point.Trim(), $reach.Where) `
                $(if ($reach.Ok) { 'Green' } else { 'Yellow' })
        }
    }

    if ($wg -and $svc -and $svc.Status -eq 'Running') {
        # Рукопожатие показывает, отвечает ли роутер: служба может быть запущена,
        # а другая сторона молчать.
        $hs = & $wg show $Name latest-handshakes 2>$null
        if ($hs) {
            $stamp = ($hs -split "\s+")[1]
            if ($stamp -and $stamp -ne '0') {
                $age = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$stamp)
                Write-Line "Рукопожатие с роутером: $age сек назад" `
                    $(if ($age -lt 180) { 'Green' } else { 'Yellow' })
            } else { Write-Line "Рукопожатие с роутером: не было" 'Yellow' }
        }
    }

    foreach ($t in $HomeProbe) {
        $ok = Test-Connection -ComputerName $t.Address -Count 1 -Quiet -ErrorAction SilentlyContinue
        Write-Line ("$($t.Name) ($($t.Address)): " + $(if ($ok) { 'виден' } else { 'не виден' })) `
            $(if ($ok) { 'Green' } else { 'Yellow' })
    }
    Write-Host ""
    exit 0
}

# --- Только установка --------------------------------------------------------
if ($Install) {
    if ($wireguard) {
        Write-Line "WG уже стоит: $wireguard" Green
        Write-Host "`n  Ставить нечего. Туннель поднимается кнопкой TUNNEL → LOCAL → WG BASE-ROUTER.`n" -ForegroundColor Cyan
        Complete-Run 0
    }
    $wireguard = Install-WireGuard
    Write-Line "WG: $wireguard" Green
    Write-Host "`n  Готово. Теперь нужен конфиг от роутера, дальше - кнопка HOME VPN.`n" -ForegroundColor Cyan
    Complete-Run 0
}

# --- Снятие ------------------------------------------------------------------
if ($Remove) {
    if (-not (Remove-AnyTunnel -TunnelName (@($Name) + $LegacyNames))) { Write-Line "службы не было" }
    Write-Host "`n  Туннель до router-base снят. Конфиг остался — поднять снова одним запуском.`n" -ForegroundColor Cyan
    Complete-Run 0
}

# --- 1. Клиент ---------------------------------------------------------------
# Сами не ставим. Ставить есть кому - кнопка WIREGUARD в окне, и она сперва
# смотрит, что на машине уже есть. Здесь мы однажды поставили обычный клиент на
# машину, где давно стоял AmneziaWG: он не был нужен ни для чего, кроме
# подсчёта ключей, а тот же счёт умеет и клиент, который уже был.
if (-not $engine) {
    Write-Host ""
    Write-Host "  Клиента нет: ни WireGuard, ни AmneziaWG." -ForegroundColor Yellow
    Write-Host "  Поставьте его кнопкой WIREGUARD в окне и запустите снова.`n" -ForegroundColor Yellow
    Complete-Run 1
}
Write-Line ("клиент: " + $engine) Green

# --- 2. Конфиг от роутера ----------------------------------------------------
$src = Find-RouterConfig
if (-not $src) {
    Write-Host ""
    Write-Host "  Нет конфига от роутера." -ForegroundColor Yellow
    Write-Host "  Заведи клиента в роутере (WG-сервер -> добавить пользователя)," -ForegroundColor Yellow
    Write-Host "  скачай его файл и запусти снова — скрипт подхватит свежий .conf из Загрузок." -ForegroundColor Yellow
    Write-Host "  Либо укажи прямо: setup-base-vpn.cmd -From `"путь\к\файлу.conf`"`n" -ForegroundColor Yellow
    Complete-Run 1
}
Write-Line "конфиг от роутера: $src" Green

$lines = Get-Content $src
if (-not ($lines -match '^\s*PrivateKey')) {
    throw "В файле нет приватного ключа — это не конфиг клиента, а что-то другое"
}

# --- 3. Правка: через туннель ходит только сеть BASE ------------------------
# Роутер выдаёт AllowedIPs = 0.0.0.0/0 — с ним в туннель уходит весь трафик
# машины. Нам нужен только дом; заодно снимаем DNS роутера, иначе домашний
# резолвер начинает обслуживать и обычные сайты.
$allowed = if ($FullTunnel) { '0.0.0.0/0' } else { $HomeNets -join ', ' }

# Если адрес самой машины попадает в то, что мы заворачиваем, - её сеть уедет
# в туннель. Так и бывает в большой сети вроде 192.168.0.0/16: туннель забирает
# из неё подсети, и пропадают принтеры и общие папки.
if (-not $FullTunnel) {
    $ipToNum = {
        param([string]$Ip)
        $parts = $Ip -split '\.'
        if ($parts.Count -ne 4) { return $null }
        ([uint32]$parts[0] -shl 24) -bor ([uint32]$parts[1] -shl 16) -bor
        ([uint32]$parts[2] -shl 8) -bor [uint32]$parts[3]
    }
    foreach ($own in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })) {
        foreach ($net in $HomeNets) {
            $pair = $net -split '/'
            if ($pair.Count -ne 2) { continue }
            $bits = 0
            if (-not [int]::TryParse($pair[1], [ref]$bits)) { continue }
            if ($bits -lt 8 -or $bits -gt 32) { continue }
            $mask = [uint32]4294967295 -shl (32 - $bits)
            $a = & $ipToNum $own.IPAddress
            $n = & $ipToNum $pair[0]
            if ($null -eq $a -or $null -eq $n) { continue }
            if (($a -band $mask) -eq ($n -band $mask)) {
                Write-Line "ОСТОРОЖНО: адрес этой машины $($own.IPAddress) лежит в сети $net" Yellow
                Write-Line "  туннель заберёт её себе: принтеры и общие папки станут недоступны" Yellow
                Write-Line "  список сетей правится в $RoutesFile" Gray
            }
        }
    }
}
$out = New-Object System.Collections.Generic.List[string]
$changedAllowed = $false
$droppedDns = $false
$usedEndpoint = $null

foreach ($line in $lines) {
    if ($line -match '^\s*AllowedIPs\s*=') {
        $out.Add("AllowedIPs = $allowed")
        $changedAllowed = $true
        continue
    }
    if (-not $FullTunnel -and $line -match '^\s*DNS\s*=') {
        $droppedDns = $true
        continue
    }
    if ($line -match '^\s*Endpoint\s*=\s*(.+)$') {
        # Роутер выписывает конфиг на своё доменное имя. Пока имя не
        # опубликовано наружу, оно не разрешается ни у одного провайдера, и
        # служба Windows молча падает с «Этот хост неизвестен».
        $usedEndpoint = if ($Endpoint) { $Endpoint } else { $matches[1].Trim() }
        $out.Add("Endpoint = $usedEndpoint")
        continue
    }
    $out.Add($line)
}
if (-not $changedAllowed) { throw "В конфиге нет строки AllowedIPs — файл непохож на конфиг WireGuard" }
if (-not $usedEndpoint) { throw "В конфиге нет строки Endpoint — некуда стучаться" }

$reach = Test-Endpoint -Value $usedEndpoint
if ($reach.Ok) {
    Write-Line ("endpoint: {0} — {1}" -f $usedEndpoint, $reach.Where) Green
} else {
    Write-Host ""
    Write-Host "  Endpoint не разрешается в адрес: $usedEndpoint" -ForegroundColor Yellow
    Write-Host "  Роутер выписал конфиг на своё доменное имя, а оно ещё не опубликовано" -ForegroundColor Yellow
    Write-Host "  наружу — снаружи такого имени не существует, и служба туннеля упадёт" -ForegroundColor Yellow
    Write-Host "  с «Этот хост неизвестен»." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Два выхода: опубликовать имя в настройках роутера (Доменное имя)" -ForegroundColor Yellow
    Write-Host "  либо подставить прямой адрес:" -ForegroundColor Yellow
    Write-Host "      setup-base-vpn.cmd -Endpoint 1.2.3.4:500" -ForegroundColor Yellow
    Write-Host "  Адрес домашнего провайдера может смениться, поэтому это на время.`n" -ForegroundColor Yellow
    Complete-Run 1
}

Set-Content -Path $TunConf -Value ($out -join "`r`n") -Encoding ascii

# В конфиге лежит приватный ключ этой машины - закрываем его от соседей по
# системе, как и ключевой файл.
if (-not (Protect-AbkSecret -Path $TunConf)) {
    Write-Line "права на конфиг закрыть не вышло - к ключу есть посторонний доступ" Yellow
}
Write-Line ("в сеть BASE заворачивается: " + $(if ($FullTunnel) { 'ВЕСЬ трафик машины' } else { $allowed })) `
    $(if ($FullTunnel) { 'Yellow' } else { 'Green' })
if ($droppedDns) { Write-Line "домашний DNS снят — имена резолвятся как обычно" Green }

# --- 4. Служба (ставится, но сама при загрузке не поднимается) --------------
# Заголовок раньше обещал автозапуск. Проверено делом: клиент заводит службу
# с ручным запуском, и после перезагрузки туннель не встаёт сам - его поднимает
# кнопка питания. Для машины, которая ходит по чужим сетям, это к лучшему:
# включил компьютер на работе - и туннель не мешает тамошнему VPN, пока сам
# не понадобится. Дома же придётся поднять его заново после каждой загрузки.
[void](Remove-AnyTunnel -TunnelName (@($Name) + $LegacyNames))
& $engine /installtunnelservice $TunConf

# Ждём, пока служба доберётся до Running. Трёх секунд не хватало: в отчёте
# оставалось StartPending - состояние на полпути, - и выглядело это как
# поломка, хотя туннель через мгновение вставал.
$svc = $null
for ($try = 0; $try -lt 15; $try++) {
    Start-Sleep 1
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') { break }
}
Write-Line ("служба туннеля: " + $(if ($svc) { $svc.Status } else { 'не создалась' })) `
    $(if ($svc -and $svc.Status -eq 'Running') { 'Green' } elseif ($svc) { 'Yellow' } else { 'Red' })

# Поднимать при загрузке или ждать кнопки. Клиент заводит службу с ручным
# запуском, и это верно для машины, которая ходит по чужим сетям: включил
# компьютер на работе - туннель не мешает тамошнему VPN, пока сам не
# понадобится. Но там, куда не дотянуться рукой, - на машине без человека
# рядом, - кнопку нажать некому: перезагрузился компьютер, и связи нет до
# следующего визита.
if ($AtBoot) {
    # Автозапуск отложенный, а не обычный. Обычный поднимает службу слишком
    # рано: сеть ещё не готова, имя точки входа не разрешается, и служба
    # падает с «No such host is known» - в журнале событий остаётся 7023, а
    # туннеля нет. Отложенный ждёт, пока система закончит загрузку.
    & sc.exe config "$ServiceName" start= delayed-auto | Out-Null
    $set = ($LASTEXITCODE -eq 0)

    # Пять минут вместо двух. Отложенный старт Windows ждёт по умолчанию две
    # минуты - этого хватает не всегда: у роутера своя загрузка, у провайдера
    # свои минуты, а туннелю нужно разрешить имя точки входа. Задержка живёт
    # в самой службе, отдельным значением.
    try {
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $ServiceName
        New-ItemProperty -Path $key -Name 'AutoStartDelay' -Value 300000 -PropertyType DWord -Force | Out-Null
    } catch { }

    # И перезапуск при сбое: канал может подняться позже машины - у роутера
    # своя загрузка, у провайдера свои минуты. Три попытки по минуте, счётчик
    # сбрасывается через пять - этого хватает, чтобы дождаться сети, и мало,
    # чтобы крутиться впустую.
    & sc.exe failure "$ServiceName" reset= 300 actions= restart/60000/restart/60000/restart/60000 | Out-Null

    if ($set) {
        Write-Line "поднимается при загрузке машины, через пять минут после неё" Green
        Write-Line "  не встанет с первого раза - повторит трижды, по разу в минуту" Gray
    } else {
        Write-Line "автозапуск включить не вышло - туннель поднимается кнопкой" Yellow
    }
} else {
    # Ставим ручной запуск явно, а не оставляем прежний. Иначе однажды
    # включённый автозапуск оставался навсегда: кнопка ПОДНЯТЬ выглядела бы
    # так же, а туннель продолжал бы вставать сам - и на рабочей машине
    # мешать тамошнему VPN, о чём человек уже и не помнит.
    & sc.exe config "$ServiceName" start= demand | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Line "поднимается по кнопке, при загрузке сам не встаёт" Gray
    } else {
        Write-Line "тип запуска сменить не вышло - смотрите службу вручную" Yellow
    }
}

# Право включать и выключать эту службу - текущей учётной записи. Сценарий уже
# идёт с правами администратора, и выдать их лучше здесь: иначе кнопка питания
# в окне тянула бы UAC при каждом нажатии, а выключать туннель приходится
# часто - поднятый, он забирает себе перечисленные сети и мешает обычной
# сетевой работе.
#
# Даём ровно на одну службу и ровно на питание: RP - пуск, WP - остановка,
# LO - опрос состояния, CR - пользовательские команды. Ни установки, ни
# удаления, ни смены настроек.
try {
    $who = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $shown = & sc.exe sdshow $ServiceName 2>&1
    $sddl = ($shown | Where-Object { "$_" -match '^D:' } | Select-Object -First 1)
    if ($sddl) {
        $sddl = "$sddl".Trim()
        if ($sddl -like "*$who*") {
            Write-Line "право на включение уже есть" Gray
        } else {
            $ace = "(A;;RPWPLOCR;;;$who)"
            # Раздел аудита, если он есть, должен остаться хвостом. Граница -
            # это "S:(", а не первая же буква S: она встречается и внутри самих
            # прав (CCLCSW, SY, SD, SU), и по ней строка рвалась посреди права.
            # В sc.exe уходила каша, а он отвечал «неверный тип данных» - одно
            # сообщение на все случаи, поди догадайся.
            if ($sddl -match '^(?<dacl>D:.*?)(?<rest>S:\(.*)$') {
                $fresh = $Matches['dacl'] + $ace + $Matches['rest']
            } else {
                $fresh = $sddl + $ace
            }
            # Ответ sc.exe раньше уходил в Out-Null, и о причине оставалось
            # гадать: сообщение было одно на все случаи.
            $said = & sc.exe sdset $ServiceName $fresh 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Line "включать и выключать можно без прав администратора" Green
            } else {
                Write-Line "право на включение выдать не вышло - кнопка спросит права" Yellow
                foreach ($row in @($said)) {
                    $text = "$row".Trim()
                    if ($text) { Write-Line ("  " + $text) Gray }
                }
            }
        }
    }
} catch {
    Write-Line "право на включение выдать не вышло - кнопка спросит права" Yellow
}


# --- 5. Проверка: виден ли дом ----------------------------------------------
Start-Sleep 3
$seen = @()
foreach ($t in $HomeProbe) {
    if (Test-Connection -ComputerName $t.Address -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        $seen += $t.Name
    }
}
Write-Host ""
if (-not $HomeProbe.Count) {
    Write-Host "  Адресов BASE и роутера в targets.json нет - проверить видимость нечем." -ForegroundColor Yellow
    Write-Host ""
} elseif ($seen.Count -gt 0) {
    Write-Host "  ГОТОВО: сеть BASE видна — $($seen -join ', ')." -ForegroundColor Green
    Write-Host "  Рабочий стол: connect-base.cmd    Файлы: files-base.cmd" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host "  Туннель поднят, но домашние машины пока не отвечают." -ForegroundColor Yellow
    Write-Host "  Подожди полминуты и проверь: setup-base-vpn.cmd -Check" -ForegroundColor Yellow
    Write-Host "  Если тихо и дальше — на роутере у этого клиента должна стоять" -ForegroundColor Yellow
    Write-Host "  галочка доступа к домашней сети (NAT для клиентов).`n" -ForegroundColor Yellow
}
Complete-Run 0
