<#
.SYNOPSIS
    Разрешение имён: показать, кто им занимается, и дать выбрать другого.

.DESCRIPTION
    Так выглядит обрыв, которого нет: адреса пингуются, маршрут по умолчанию
    на месте, а ни один сайт не открывается. Разгадка обычно одна - DNS на
    адаптерах указывает на локальный резолвер, а тот не работает.

    Сценарий сперва смотрит и говорит, что нашёл: какие адреса стоят на
    адаптерах, что предлагает роутер по DHCP, кто держит 53-й порт, кто в
    итоге спрашивает имена наружу и разрешается ли имя вообще. Потом
    предлагает выбор: оставить как есть, вернуться к роутеру или назвать
    известного резолвера. Выбранного сперва проверяет запросом имени и
    прописывает, только если тот ответил, - иначе машина осталась бы без
    имён по своей же воле.

    Туннельные адаптеры не трогает: там DNS ставит сам туннель.

.PARAMETER Root
    Папка данных. Сценарию не нужна - принимается ради общего вида вызова.

.PARAMETER Check
    Только осмотр: ничего не менять и ничего не спрашивать.

.PARAMETER Set
    Выбрать резолвера без вопросов: auto, router, cloudflare, google, quad9,
    yandex, adguard.

.PARAMETER NoPause
    Не ждать нажатия клавиши в конце.

.EXAMPLE
    .\Repair-Dns.ps1 -Check
    Посмотреть, кто отвечает за имена, ничего не трогая.

.EXAMPLE
    .\Repair-Dns.ps1
    Посмотреть и выбрать.

.EXAMPLE
    .\Repair-Dns.ps1 -Set cloudflare
    Прописать Cloudflare без вопросов.
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Check,
    [ValidateSet('auto', 'router', 'cloudflare', 'google', 'quad9', 'yandex', 'adguard')]
    [string]$Set,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# Программы локального резолвера, какие встречаются на машинах. Список нужен
# только чтобы поднять службу по имени; если её здесь нет, сценарий увидит это
# по 53-му порту.
$ResolverNames = 'ctrld|yoga|adguard|dnscrypt|technitium|acrylic|unbound|stubby'

# Адаптеры туннелей: DNS на них ставит сам туннель, и это не наше дело.
$TunnelAdapters = 'WireGuard|Amnezia|Wintun|TAP|VPN|OpenVPN'

# Известные резолверы. Адреса открытые, у каждого свой нрав: Quad9 режет
# вредоносные имена, AdGuard - ещё и рекламные, Яндекс ближе прочих по
# расстоянию. Список не про «лучше», а про выбор: кому уходят все запросы
# имён с этой машины, решает хозяин.
$Providers = [ordered]@{
    auto       = @{ Title = 'От роутера (DHCP)'; Servers = @();                               Note = 'как задумано в сети, куда включена машина' }
    router     = @{ Title = 'Сам роутер';        Servers = @();                               Note = 'спрашиваем шлюз напрямую' }
    cloudflare = @{ Title = 'Cloudflare';        Servers = @('1.1.1.1', '1.0.0.1');           Note = 'быстрый, ничего не режет' }
    google     = @{ Title = 'Google';            Servers = @('8.8.8.8', '8.8.4.4');           Note = 'самый известный' }
    quad9      = @{ Title = 'Quad9';             Servers = @('9.9.9.9', '149.112.112.112');   Note = 'режет вредоносные имена' }
    yandex     = @{ Title = 'Яндекс';            Servers = @('77.88.8.8', '77.88.8.1');       Note = 'ближе прочих, есть свои фильтры' }
    adguard    = @{ Title = 'AdGuard';           Servers = @('94.140.14.14', '94.140.15.15'); Note = 'режет рекламу и счётчики' }
}

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Write-Step {
    param([int]$Number, [int]$Total, [string]$Text)
    Write-Host ""
    Write-Host ("  [{0}/{1}] {2}" -f $Number, $Total, $Text) -ForegroundColor Cyan
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TargetAdapters {
    <#
        Адаптеры, которым мы правим DNS: поднятые и не туннельные. «Физическими»
        они зовутся условно - виртуальный коммутатор Hyper-V или адаптер
        песочницы сюда тоже попадёт, и это осознанно: имена ему нужны так же.
    #>
    Get-NetAdapter | Where-Object {
        $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch $TunnelAdapters
    }
}

function Get-LocalListener {
    <# Кто держит 53-й порт на этой машине. Пусто - имена разрешать некому. #>
    $ends = @(Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1', '0.0.0.0', '::') })
    if (-not $ends) { return $null }
    $proc = Get-Process -Id $ends[0].OwningProcess -ErrorAction SilentlyContinue
    if ($proc) { return $proc.ProcessName }
    return 'неизвестный процесс'
}

function Get-DhcpDns {
    <#
        Что роутер выдаёт по DHCP. Windows держит это отдельно от заданного
        вручную: в реестре интерфейса лежат оба значения сразу - NameServer
        (вписанное руками) и DhcpNameServer (полученное от роутера). Второе
        никуда не девается, пока стоит первое, - оттуда и узнаём заранее, что
        получится после возврата к автоматическому режиму.
    #>
    param([Parameter(Mandatory)]$Adapter)
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $Adapter.InterfaceGuid
    $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    if ($p -and $p.DhcpNameServer) { return @($p.DhcpNameServer -split '[ ,]+' | Where-Object { $_ }) }
    return @()
}

function Get-Gateway {
    param([Parameter(Mandatory)]$Adapter)
    try {
        $g = (Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop).IPv4DefaultGateway
        if ($g) { return @($g.NextHop)[0] }
    } catch { }
    return $null
}

function Test-Resolver {
    <# Спрашиваем имя у названного адреса: отвечает - значит годится. #>
    param([Parameter(Mandatory)][string]$Server)
    try {
        $a = Resolve-DnsName 'ya.ru' -Type A -Server $Server -QuickTimeout -ErrorAction Stop
        return [bool]($a | Where-Object IPAddress)
    } catch { return $false }
}

function Test-Names {
    <# Проверка делом: имя должно превратиться в адрес. #>
    try {
        $a = Resolve-DnsName 'ya.ru' -Type A -QuickTimeout -ErrorAction Stop
        $ip = ($a | Where-Object IPAddress | Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch { }
    return $null
}

function Get-Upstream {
    <#
        Кто в итоге спрашивает имена наружу. Роутер в поле «DNS» - это ещё не
        ответ: он сам кого-то спрашивает, и так до того, кто дойдёт до
        авторитетного сервера. Google держит служебное имя, отвечающее адресом
        спросившего, - по нему и узнаём последнее звено, а обратное имя часто
        называет хозяина: dns.yandex.ru, one.one.one.one, узел провайдера.
    #>
    $seen = $null
    foreach ($probe in @(
        @{ Name = 'o-o.myaddr.l.google.com'; Type = 'TXT' },
        @{ Name = 'whoami.akamai.net';       Type = 'A' })) {
        try {
            $a = Resolve-DnsName $probe.Name -Type $probe.Type -QuickTimeout -ErrorAction Stop
            $seen = $(
                if ($probe.Type -eq 'TXT') { @($a | Where-Object Strings | ForEach-Object { $_.Strings })[0] }
                else { @($a | Where-Object IPAddress | ForEach-Object { $_.IPAddress })[0] }
            )
            if ($seen) { break }
        } catch { }
    }
    if (-not $seen) { return $null }

    # Обратное имя ищем по обоим протоколам: четвёртый складывается из
    # байтов задом наперёд в in-addr.arpa, шестой - из полубайтов в ip6.arpa.
    # Резолверы всё чаще отвечают именно с шестого, и без этого имя хозяина
    # оставалось неизвестным.
    $who = $null
    try {
        $addr = [System.Net.IPAddress]::Parse($seen)
        $bytes = $addr.GetAddressBytes()
        $back = $(
            if ($addr.AddressFamily -eq 'InterNetworkV6') {
                $hex = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').ToCharArray()
                [array]::Reverse($hex)
                ($hex -join '.') + '.ip6.arpa'
            } else {
                [array]::Reverse($bytes)
                (($bytes | ForEach-Object { $_.ToString() }) -join '.') + '.in-addr.arpa'
            }
        )
        $ptr = Resolve-DnsName $back -Type PTR -QuickTimeout -ErrorAction Stop
        $who = @($ptr | Where-Object NameHost | ForEach-Object { $_.NameHost })[0]
    } catch { }

    return @{ Address = $seen; Name = $who }
}

function Show-Upstream {
    param($Up)
    if (-not $Up) { Write-Line "кто спрашивает наружу - выяснить не вышло"; return }
    $tail = if ($Up.Name) { " ({0})" -f $Up.Name.TrimEnd('.') } else { '' }
    Write-Line ("наружу спрашивает: {0}{1}" -f $Up.Address, $tail)
}

function Get-NlaState {
    <#
        Значок сети рисует не сеть, а служба NlaSvc - «Сведения о расположении
        в сети». Она проверяет пару адресов Microsoft и решает, есть ли выход
        наружу. Пока она лежит, профиль висит на LocalNetwork, в трее глобус,
        Windows не различает частную сеть и общественную, а брандмауэр берёт
        профиль наугад. Сайты при этом открываются: интернет есть, сказать о
        нём некому.
    #>
    $svc = Get-CimInstance Win32_Service -Filter "Name='NlaSvc'" -ErrorAction SilentlyContinue
    $seen = @()
    try {
        $seen = @(Get-NetConnectionProfile -ErrorAction Stop | ForEach-Object { $_.IPv4Connectivity })
    } catch { }
    return @{
        Service = $svc
        Running = ($svc -and $svc.State -eq 'Running')
        Manual  = ($svc -and $svc.StartMode -ne 'Auto')
        Online  = [bool](@($seen | Where-Object { $_ -eq 'Internet' }).Count)
        Seen    = $seen
    }
}

function Set-Dns {
    <#
        Ставит адреса на адаптеры. Пусто - вернуть DHCP.

        `PerAdapter` - для случая, когда у каждого адаптера свой адрес: так
        работает режим «сам роутер». Раньше первый найденный шлюз назначался
        всем разом, и при одновременных Ethernet и Wi-Fi из разных сетей один
        получал чужой шлюз соседнего сегмента - а с отключением того
        подключения оставался и без имён.
    #>
    param([string[]]$Servers, [Parameter(Mandatory)]$Adapters, [hashtable]$PerAdapter)

    foreach ($a in $Adapters) {
        $mine = $(if ($PerAdapter) { @($PerAdapter[[int]$a.ifIndex]) } else { $Servers })
        if ($PerAdapter -and -not $mine) {
            Write-Line ("{0,-26} своего шлюза нет - оставлен как был" -f $a.Name) Yellow
            continue
        }

        $was = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)
        try {
            if ($mine) {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $mine -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
            }
            $now = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)
            $shown = if ($now) { $now -join ', ' } else { 'от роутера (DHCP)' }
            Write-Line ("{0,-26} было: {1,-18} стало: {2}" -f $a.Name, ($was -join ', '), $shown) Green
        } catch {
            Write-Line ("{0,-26} не вышло: {1}" -f $a.Name, $_.Exception.Message) Yellow
        }
    }
    & ipconfig.exe /flushdns | Out-Null
}

# --- Самоподнятие прав: служба и адреса адаптеров требуют администратора -----
if (-not $Check -and -not (Test-Admin)) {
    Write-Host "  Нужны права администратора - поднимаю (UAC)..." -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Root) { $argList += @('-Root', $Root) }
    if ($Set) { $argList += @('-Set', $Set) }
    if ($NoPause) { $argList += '-NoPause' }
    $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
    Start-Process $psExe -Verb RunAs -ArgumentList $argList
    exit 0
}

Write-Host "`n=== Разрешение имён на этой машине ===`n" -ForegroundColor Cyan

# --- 1. Смотрим -------------------------------------------------------------
Write-Step 1 3 "Что стоит сейчас"

$adapters = @(Get-TargetAdapters)
if (-not $adapters) { Write-Line "сетевых адаптеров не видно - машина не в сети" Yellow }

$onLocal = @()
$gateway = $null
$gateways = @{}
foreach ($a in $adapters) {
    $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)
    $shown = if ($dns) { $dns -join ', ' } else { 'от роутера (DHCP)' }
    Write-Line ("{0,-26} {1}" -f $a.Name, $shown)

    $offer = @(Get-DhcpDns -Adapter $a)
    $gate = Get-Gateway -Adapter $a
    if ($gate) { $gateways[[int]$a.ifIndex] = $gate }
    if (-not $gateway) { $gateway = $gate }
    if ($dns -and $offer) { Write-Line ("{0,-26} роутер предлагает: {1}" -f '', ($offer -join ', ')) }
    elseif ($dns -and $gate) { Write-Line ("{0,-26} роутер адреса не даёт, шлюз: {1}" -f '', $gate) }

    if ($dns -contains '127.0.0.1') { $onLocal += $a }
}

$listener = Get-LocalListener
Write-Line ("53-й порт: " + $(if ($listener) { "держит $listener" } else { "не слушает никто" })) `
    $(if ($listener) { 'Gray' } else { 'Yellow' })

$ip = Test-Names
Write-Line ("имена: " + $(if ($ip) { "разрешаются, ya.ru -> $ip" } else { "НЕ разрешаются" })) `
    $(if ($ip) { 'Green' } else { 'Yellow' })

if ($ip) { Show-Upstream -Up (Get-Upstream) }

$nla = Get-NlaState
if (-not $nla.Service) {
    Write-Line "службы NlaSvc в системе нет" Yellow
} elseif (-not $nla.Running) {
    Write-Line ("значок сети: служба NlaSvc не работает (запуск: {0})" -f $nla.Service.StartMode) Yellow
} elseif ($ip -and -not $nla.Online) {
    Write-Line ("значок сети: Windows считает, что выхода нет ({0})" -f (($nla.Seen | Select-Object -Unique) -join ', ')) Yellow
} else {
    Write-Line ("значок сети: Windows видит выход наружу") Green
}

# --- 2. Ставим диагноз ------------------------------------------------------
Write-Step 2 3 "Что из этого следует"

$service = $null
if (-not $ip -and $onLocal.Count -and -not $listener) {
    Write-Line "адаптеры отправляют имена на 127.0.0.1, а отвечать там некому" Yellow
    $service = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $ResolverNames -or $_.DisplayName -match $ResolverNames } |
        Select-Object -First 1
    if ($service) { Write-Line ("резолвер на машине есть: служба {0} ({1})" -f $service.Name, $service.Status) }
    else { Write-Line "службы резолвера в системе нет - адреса остались от снятой программы" Yellow }
} elseif (-not $ip) {
    Write-Line "сервер имён не отвечает" Yellow
} elseif ($onLocal.Count -and $listener) {
    Write-Line ("имена идут через локальный резолвер ({0}), и он работает" -f $listener) Green
} else {
    Write-Line "имена разрешаются обычным путём" Green
}

if ($nla.Service -and -not $nla.Running) {
    Write-Line "отсюда и «интернет как бы есть, но»: имена идут, а ярлык вешать некому" Yellow
    if ($nla.Manual) { Write-Line "штатно эта служба стоит на автозапуске, здесь - «вручную»" Yellow }
}

if ($Check) {
    Write-Host "`n  Это был осмотр: ничего не менялось.`n" -ForegroundColor Cyan
    if (-not $NoPause) { Write-Host "  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

# Лежачую службу резолвера поднимаем сразу: это возврат к тому, как было
# задумано, а не решение за хозяина.
if ($service -and $service.Status -ne 'Running') {
    try {
        Start-Service -Name $service.Name -ErrorAction Stop
        Start-Sleep 2
        Write-Line ("служба {0} поднята" -f $service.Name) Green
        & ipconfig.exe /flushdns | Out-Null
        $ip = Test-Names
        if ($ip) { Write-Line ("имена вернулись: ya.ru -> {0}" -f $ip) Green }
    } catch {
        Write-Line ("службу {0} поднять не вышло: {1}" -f $service.Name, $_.Exception.Message) Yellow
    }
}

# Значок и профиль сети возвращаем туда же, где их держит сама Windows:
# автозапуск, работающая служба и включённая проба. Это не наша выдумка, а её
# умолчание; гасят это обычно «ускорители служб».
if ($nla.Service) {
    try {
        # Активная проба - те самые два запроса к Microsoft, по которым
        # Windows решает, есть ли выход. Выключенной пробой значок гасится
        # намертво, сколько службу ни поднимай.
        $probeKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet'
        $probe = (Get-ItemProperty -Path $probeKey -ErrorAction SilentlyContinue).EnableActiveProbing
        if ($null -ne $probe -and $probe -eq 0) {
            Set-ItemProperty -Path $probeKey -Name 'EnableActiveProbing' -Value 1 -Type DWord -ErrorAction Stop
            Write-Line "проба выхода в интернет была отключена - включена" Green
        }
    } catch {
        Write-Line ("пробу включить не вышло: {0}" -f $_.Exception.Message) Yellow
    }

    try {
        if ($nla.Manual) {
            Set-Service -Name 'NlaSvc' -StartupType Automatic -ErrorAction Stop
            Write-Line "NlaSvc переведена на автозапуск" Green
        }

        if (-not $nla.Running) {
            Start-Service -Name 'NlaSvc' -ErrorAction Stop
            Start-Sleep 3
            $nla = Get-NlaState
            if ($nla.Running) { Write-Line "NlaSvc поднята" Green }
        }

        # Служба может работать, а оценку держать старую: она считает её при
        # изменении сети, а не по кругу. Тогда сайты открываются, а в трее
        # по-прежнему глобус. Перезапуск заставляет пересчитать заново.
        if ($nla.Running -and -not $nla.Online) {
            Write-Line "оценка сети устарела - перезапускаю NlaSvc"
            Restart-Service -Name 'NlaSvc' -Force -ErrorAction Stop
            Start-Sleep 5
            $nla = Get-NlaState
        }

        if ($nla.Running) {
            $seen = ($nla.Seen | Select-Object -Unique) -join ', '
            if ($nla.Online) { Write-Line ("Windows видит выход наружу: {0}" -f $seen) Green }
            else { Write-Line ("Windows пока считает: {0} - значок обновится сам в течение минуты" -f $seen) Yellow }
        }
    } catch {
        Write-Line ("с NlaSvc не вышло: {0}" -f $_.Exception.Message) Yellow
    }
}

# --- 3. Выбираем ------------------------------------------------------------
Write-Step 3 3 "Кому доверить имена"

$keys = @($Providers.Keys)
$choice = $Set

if (-not $choice) {
    # Первым пунктом - то, что стоит сейчас, с адресом. Иначе «оставить как
    # есть» значит «не знаю, что оставляю».
    $current = @()
    foreach ($a in $adapters) {
        $dns = @((Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4).ServerAddresses)
        $current += $(if ($dns) { $dns -join ', ' } else { 'от роутера' })
    }
    $current = @($current | Select-Object -Unique)
    $now = $(if ($current) { $current -join ' / ' } else { 'неизвестно' })
    if ($listener -and $now -match '127\.0\.0\.1') { $now += " ($listener)" }

    Write-Host ("  0. {0,-18} {1,-30} {2}" -f 'Оставить как есть', $now, 'то, что стоит сейчас') -ForegroundColor White
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $p = $Providers[$keys[$i]]
        $addr = $(
            if ($keys[$i] -eq 'router') { $(if ($gateways.Count) { (@($gateways.Values | Select-Object -Unique) -join ', ') } else { 'шлюза не видно' }) }
            elseif ($p.Servers) { $p.Servers -join ', ' }
            else { 'адрес даст роутер' }
        )
        Write-Host ("  {0}. {1,-18} {2,-30} {3}" -f ($i + 1), $p.Title, $addr, $p.Note) -ForegroundColor White
    }
    Write-Host ""
    $said = Read-Host "  Номер (Enter - оставить как есть)"
    if ($said -match '^\s*[1-9]\d*\s*$' -and [int]$said -le $keys.Count) {
        $choice = $keys[[int]$said - 1]
    }
}

if (-not $choice) {
    Write-Host "`n  Оставлено как было.`n" -ForegroundColor Cyan
    if (-not $NoPause) { Write-Host "  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
    exit 0
}

$picked = $Providers[$choice]
$servers = @($picked.Servers)
$perAdapter = $null
if ($choice -eq 'router') {
    if (-not $gateways.Count) {
        Write-Line "шлюза не видно - роутер спросить не у кого" Yellow
        if (-not $NoPause) { Write-Host "`n  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
        exit 1
    }
    # У каждого адаптера свой роутер: у проводного один, у беспроводного может
    # быть совсем другой. Поэтому здесь не общий список, а таблица «адаптер -
    # его шлюз», и проверяется каждый отдельно.
    $perAdapter = @{}
    foreach ($pair in $gateways.GetEnumerator()) {
        if (Test-Resolver -Server $pair.Value) { $perAdapter[$pair.Key] = @($pair.Value) }
        else { Write-Line ("шлюз {0} имя не разрешает - этот адаптер не трогаю" -f $pair.Value) Yellow }
    }
    if (-not $perAdapter.Count) {
        Write-Line "ни один роутер не ответил именем - оставляю как было" Yellow
        if (-not $NoPause) { Write-Host "`n  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
        exit 1
    }
    $servers = @()
}

Write-Host ""
# Проверяем прежде, чем ставить: прописанный молчащий резолвер оставит машину
# без имён, и чинить придётся вслепую. У «от роутера» проверять нечего -
# адрес выдаст сам роутер; шлюзы уже проверены выше, каждый свой.
if ($servers) {
    Write-Line ("проверяю {0}: {1}" -f $picked.Title, ($servers -join ', '))
    $alive = @($servers | Where-Object { Test-Resolver -Server $_ })
    if (-not $alive) {
        Write-Line "не отвечает - оставляю как было" Yellow
        Write-Line "так бывает там, где чужой DNS заворачивают на свой" Gray
        if (-not $NoPause) { Write-Host "`n  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
        exit 1
    }
    if ($alive.Count -lt $servers.Count) {
        Write-Line ("отвечает не весь: беру {0}" -f ($alive -join ', ')) Yellow
    }
    $servers = $alive
}

if ($perAdapter) { Set-Dns -Adapters $adapters -PerAdapter $perAdapter }
else { Set-Dns -Servers $servers -Adapters $adapters }

$ip = Test-Names
if ($ip) {
    Write-Host ("`n  Имена разрешаются: ya.ru -> {0}" -f $ip) -ForegroundColor Green
    Show-Upstream -Up (Get-Upstream)
    Write-Host ""
} else {
    Write-Host "`n  Имена всё ещё не разрешаются." -ForegroundColor Yellow
    Write-Line "если поднят VPN - выключите его своей кнопкой, а не обрывом" Gray
    Write-Line "если и роутер молчит - дело в канале, а не в машине" Gray
    Write-Host ""
}

if (-not $NoPause) { Write-Host "  Нажмите Enter, чтобы закрыть окно." -ForegroundColor DarkGray; [void](Read-Host) }
