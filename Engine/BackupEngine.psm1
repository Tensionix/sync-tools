<#
    Движок Audion Sync Tools: функции, на которых стоят сценарии Engine\Scripts.

    Адреса машин (targets.json), сборка транспорта rclone, имена и ключи машин,
    authorized_keys на машинах, туннель до роутера BASE, указатель папки данных
    и перенос рабочих файлов машины в неё.

    Окна здесь нет. Окно - Source\ (Avalonia): оно спрашивает и зовёт сценарии,
    сценарии подключают этот модуль. Из консоли те же сценарии делают то же.

    До 05.10.2026 эти функции лежали в начале модуля прежнего окна
    (Engine\BackupGui.psm1), вместе с самим окном на WPF; окно убрано, функции
    перенесены сюда буква в букву.
#>

# SECOND VPS хозяйства читается из targets.json: адрес и имена у каждого
# свои, а в коде только имена по умолчанию.
. (Join-Path $PSScriptRoot 'DataRoot.ps1')
. (Join-Path $PSScriptRoot 'Targets.ps1')

# Пары ключей без пароля - одним способом для всех сценариев.
. (Join-Path $PSScriptRoot 'KeyPair.ps1')

function Set-AbkTargetEntry {
    <#
        Правит одну цель прямо в тексте targets.json: разбирать и собирать файл
        заново - значит потерять и порядок ключей, и пояснения, ради которых он
        написан по-человечески. Меняем только те значения, что назвали.

        Функция уровня модуля намеренно: её зовёт окно, а проверяет тест - на
        копии файла, не трогая рабочий.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Address,
        [int]$Port = 22,
        [string]$User = '',
        # Какое поле адреса править. lan - домашний адрес машины; host - адрес
        # SECOND VPS, у которого домашнего нет: так он и записан.
        [ValidateSet('lan', 'host')][string]$Field = 'lan'
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = [System.IO.File]::ReadAllText($Path)

    $at = $text.IndexOf('"{0}":' -f $Key)
    if ($at -lt 0) { return $false }
    $stop = $text.IndexOf("`n  }", $at)
    if ($stop -lt 0) { return $false }

    $block = $text.Substring($at, $stop - $at)
    $fresh = [regex]::Replace($block, ('"{0}"\s*:\s*"[^"]*"' -f $Field), ('"{0}": "{1}"' -f $Field, $Address))
    $fresh = [regex]::Replace($fresh, '"sshPort"\s*:\s*\d+', ('"sshPort": {0}' -f $Port))
    if ($User) {
        $fresh = [regex]::Replace($fresh, '"user"\s*:\s*"[^"]*"', ('"user": "{0}"' -f $User))
    }
    # Пустой host заполняется тем же адресом: у точек за плечом HOME второго
    # адреса нет вовсе, а пустое поле ломает выбор маршрута.
    if ($Field -eq 'lan' -and $fresh -match '"host"\s*:\s*""') {
        $fresh = [regex]::Replace($fresh, '"host"\s*:\s*""', ('"host": "{0}"' -f $Address))
    }

    if ($fresh -eq $block) { return $false }
    $text = $text.Substring(0, $at) + $fresh + $text.Substring($stop)
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($true))
    return $true
}

function Build-AbkTransport {
    <#
        Собирает рабочий rclone.conf из заготовки config\rclone.sample.conf.
        Метки вида {{ИМЯ}} заменяются значениями из $Values; что не назвали -
        остаётся меткой, и это видно в готовом файле с первого взгляда.

        Возвращает список меток, которые остались незаполненными: пустой
        список значит, что транспорт собран целиком.

        С -KeepFrom строка, которой не хватило значения, берётся из прежнего
        рабочего файла - того же раздела и того же ключа, если в ней меток нет.
        Пересборка не вправе превращать работающий транспорт в заготовку: так
        однажды раздел SECOND VPS получил метку вместо рабочего имени.

        Функция уровня модуля намеренно: её зовёт окно, а проверяет тест.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Template,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Values,
        # Прежний рабочий файл: из него берутся строки вместо оставшихся меток.
        [string]$KeepFrom = '',
        # Сюда кладётся список меток, чьи строки взяты из прежнего файла (Kept).
        [hashtable]$Report = $null
    )

    if (-not (Test-Path -LiteralPath $Template)) { return @('нет заготовки') }
    $text = [System.IO.File]::ReadAllText($Template)
    # Existing callers omit ports; the GUI supplies the selected target's sshPort.
    foreach ($machine in 'BASE','LAPTOP','HOME','DAD','WORK','SERVER') {
        $portKey = $machine + '_PORT'
        if (-not $Values.ContainsKey($portKey)) { $text = $text.Replace('{{' + $portKey + '}}', '22') }
    }

    foreach ($pair in $Values.GetEnumerator()) {
        if (-not $pair.Value) { continue }
        $text = $text.Replace('{{' + $pair.Key + '}}', [string]$pair.Value)
    }

    # Шапка заготовки объясняет сами метки - в рабочем файле она лишняя и
    # только сбивает: там меток уже нет.
    $lines = $text -split "`r?`n"
    $start = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like '# --- *') { $start = $i; break }
    }
    $body = ($lines[$start..($lines.Count - 1)] -join "`n")

    $kept = @()
    if ($KeepFrom -and (Test-Path -LiteralPath $KeepFrom)) {
        $working = @{}
        $section = ''
        foreach ($oldLine in ([System.IO.File]::ReadAllText($KeepFrom) -split "`r?`n")) {
            if ($oldLine -match '^\s*\[([^\]]+)\]\s*$') { $section = $Matches[1]; continue }
            if ($oldLine -match '\{\{[A-Z_0-9]+\}\}') { continue }
            if ($oldLine -match '^\s*([^=#;\s][^=]*?)\s*=') { $working[$section + '|' + $Matches[1].Trim()] = $oldLine }
        }

        $freshLines = $body -split "`n"
        $section = ''
        for ($i = 0; $i -lt $freshLines.Count; $i++) {
            $freshLine = $freshLines[$i]
            if ($freshLine -match '^\s*\[([^\]]+)\]\s*$') { $section = $Matches[1]; continue }
            if ($freshLine -notmatch '\{\{[A-Z_0-9]+\}\}') { continue }
            if ($freshLine -notmatch '^\s*([^=#;\s][^=]*?)\s*=') { continue }
            $slot = $section + '|' + $Matches[1].Trim()
            if (-not $working.ContainsKey($slot)) { continue }
            foreach ($hit in [regex]::Matches($freshLine, '\{\{([A-Z_0-9]+)\}\}')) {
                if ($kept -notcontains $hit.Groups[1].Value) { $kept += $hit.Groups[1].Value }
            }
            $freshLines[$i] = $working[$slot]
        }
        $body = $freshLines -join "`n"
    }
    if ($null -ne $Report) { $Report['Kept'] = $kept }

    $left = @()
    foreach ($hit in [regex]::Matches($body, '\{\{([A-Z_]+)\}\}')) {
        $name = $hit.Groups[1].Value
        if ($left -notcontains $name) { $left += $name }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $body, [System.Text.UTF8Encoding]::new($true))
    return $left
}

function Restore-AbkTargetsFile {
    <#
        Возвращает каркас адресов, если рабочего файла нет.

        targets.json - не просто данные: в нём заведены сами машины и написаны
        пояснения, ради которых он и хранится по-человечески. Запись адреса
        правит текст существующего файла и на отсутствующем молча отвечает «не
        удалось» - именно так чистая установка и встала: кнопка АДРЕСА нажалась,
        а записать было некуда.

        Поэтому в сборку едет образец с пустыми адресами, а рабочий файл
        разворачивается из него при первом запуске.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$DataRoot = ''
    )

    # Рабочий файл - в папке данных; образец едет с программой.
    $live = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $DataRoot
    if (Test-Path -LiteralPath $live) { return '' }
    # Папки данных нет - разворачивать некуда: окно попросит её выбрать.
    if (-not (Test-Path -LiteralPath (Resolve-AbkWorkRoot -AppRoot $AppRoot -DataRoot $DataRoot))) { return '' }

    $sample = Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json'
    if (-not (Test-Path -LiteralPath $sample)) { return '' }

    try {
        $dir = Split-Path -Parent $live
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $sample -Destination $live -Force
        return $live
    } catch { return '' }
}

function Get-AbkMachineFiles {
    <#
        Чем эта машина отличается от такой же программы у другого человека.

        Список рабочих файлов для переноса из прежних версий программы
        в папку данных. Текущие сценарии читают и пишут их сразу в данных:
        адреса, ключи, пароли, план зеркала с папками MAIN VPS.

        Версия сборки, темы и шаблон rclone сюда не входят: они приезжают с
        программой и у всех одинаковые.

        Настройки окна (`config\gui-settings.json`) не входят тоже: это часть
        самой программы, и живут они в её папке. До 1.8.0 они ездили в данные,
        и копия в комплекте несла путь к папке данных, который устаревал при
        первом же переносе.
    #>
    @(
        @{ Rel = 'config\rclone\rclone.conf';                    What = 'rclone.conf' }
        @{ Rel = 'config\rclone\r2.credentials';                 What = 'ключи R2 bucket' }
        @{ Rel = 'config\rclone\known_hosts';                    What = 'отпечатки хостов' }
        @{ Rel = 'config\rclone\clouds.conf';                    What = 'clouds.conf' }
        @{ Rel = 'config\rclone\clouds.key';                     What = 'clouds.key' }
        @{ Rel = 'config\mirror.json';                           What = 'план зеркала' }
        @{ Rel = 'Tunnel\RemoteDesktop\config\targets.json';      What = 'адреса машин' }
    )
}

function Get-AbkVpnService {
    <#
        Служба туннеля до роутера BASE - под тем именем, под которым она на
        этой машине есть.

        Имя менялось: сперва `home`, потом `base`, теперь `router-base-wg`.
        Мастер снимает прежние при установке, но пока его не запускали, туннель
        живёт под старым именем и работает. Программа же искала только новое и
        честно показывала «не заведён» при поднятом туннеле - и точка серая, и
        выключить нечем.

        Возвращает имя существующей службы или новое имя, если нет ни одной:
        тогда и заводить будут под ним. Приставка у нового имени - от того
        клиента, который и будет ставить: при найденном AmneziaWG мастер
        заводит службу под его именем, и смотреть надо туда же.
    #>
    param([string[]]$Names = @('router-base-wg', 'base', 'home'))
    foreach ($name in $Names) {
        foreach ($prefix in (Get-AbkTunnelPrefix)) {
            $service = $prefix + $name
            if (Get-Service -Name $service -ErrorAction SilentlyContinue) { return $service }
        }
    }
    $(if (Find-AbkAwgExe) { 'AmneziaWGTunnel$' } else { 'WireGuardTunnel$' }) + $Names[0]
}

function Find-AbkAwgExe {
    <#
        Клиент AmneziaWG, если он на машине есть.

        Основной движок у нас классический WireGuard - свой, ставится нами и ни
        от кого не зависит. AmneziaWG нужен не вместо него, а по необходимости:
        если на машине живёт чужой VPN на AmneziaWG, классический туннель с ним
        не уживётся. Драйвер ядра у них общий, версии разные, грузится он один
        на систему - занявший первым решает за остальных.

        Свой клиент Amnezia не ставим и чужой не трогаем: только смотрим, есть
        ли он, и пользуемся тем, что уже установлено.
    #>
    # Разрядность своя. Red Shield кладёт рядом сборки под amd64 и arm64, и
    # запуск чужой - не тихая ошибка: Windows показывает модальное окно
    # «Несоответствие типа компьютера», которое не поймать ни try, ни catch.
    # А состояние опрашивается по таймеру, так что окно всплывало снова и снова.
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
                  $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })

    foreach ($path in @(
        "${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvamneziawg.exe",
        "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvamneziawg.exe",
        "$env:ProgramFiles\AmneziaWG\amneziawg.exe",
        "${env:ProgramFiles(x86)}\AmneziaWG\amneziawg.exe"
    )) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    ''
}

function Test-AbkForeignTunnel {
    <#
        Наш это туннель или чужой.

        Своими считаем те, у которых лежит конфиг в данных. Но одного этого
        мало: конфиг могли удалить, а туннель остался - и он всё ещё наш.
        Зато чужие узнаются надёжно по имени: Red Shield называет свои туннели
        redlink и дальше случайные буквы, и меняет имя при каждом подключении.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Ours = @{}
    )
    if ($Name -like 'redlink*') { return $true }
    -not $Ours.ContainsKey($Name)
}

function Test-AbkTunnelOrphan {
    <#
        Цел ли клиент, которым поставлен туннель.

        Служба хранит путь к тому, кто её поднимает. Мы ставим туннели чужим
        клиентом - тем, что пришёл с Red Shield VPN, - и если его удалят или
        переложат при обновлении, служба останется, а поднять её будет нечем:
        файла нет. Снаружи это выглядит как «туннель просто не включается», и
        догадаться неоткуда.

        Возвращает путь, которого не хватает, или пустую строку, если всё цело.
    #>
    param([Parameter(Mandatory)][string]$Service)

    try {
        # Строку запуска берём из реестра: там та же строка, что отдаёт Win32_Service,
        # а первый вопрос к CIM стоит секунды.
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Service
        $found = Get-ItemProperty -LiteralPath $key -Name ImagePath -ErrorAction Stop
        if (-not $found) { return '' }

        # ImagePath вида: "C:\...\rsvamneziawg.exe" /tunnelservice "C:\...\base.conf"
        $line = [string]$found.ImagePath
        if ($line -match '^\s*"([^"]+)"') { $exe = $Matches[1] }
        elseif ($line -match '^\s*(\S+)') { $exe = $Matches[1] }
        else { return '' }

        if (Test-Path -LiteralPath $exe) { return '' }
        return $exe
    } catch { return '' }
}

function Get-AbkTunnelPrefix {
    <#
        Как зовутся службы туннелей: WireGuardTunnel$ у обычного клиента,
        AmneziaWGTunnel$ у AmneziaWG. Ищем обе - на машине может быть и то, и
        другое сразу.
    #>
    @('WireGuardTunnel$', 'AmneziaWGTunnel$')
}

function Find-AbkWgCli {
    <#
        Утилиты, которыми можно спросить состояние туннеля: wg(8) и его собратья.

        Их несколько, и это не про запас. Туннель отвечает только тому клиенту,
        который его поднял: у WireGuard и AmneziaWG свои каналы к службе, и в
        чужой они не заглядывают. Пока туннели стояли на AmneziaWG - а на этой
        машине они стоят на нём, чтобы не ссориться с чужим VPN, - `wg.exe`
        показывал пустоту: ни интерфейсов, ни рукопожатий. Программа честно
        спрашивала и честно получала «ничего», хотя туннель работал, здоровался
        каждую минуту и возил трафик.

        Поэтому спрашиваем всех, кто есть, и складываем ответы. Кому какой
        туннель отвечает - разбираться незачем: имена интерфейсов не совпадают.
    #>
    # Разрядность своя. Red Shield кладёт рядом сборки под amd64 и arm64, и
    # запуск чужой - не тихая ошибка: Windows показывает модальное окно
    # «Несоответствие типа компьютера», которое не поймать ни try, ни catch.
    # А состояние опрашивается по таймеру, так что окно всплывало снова и снова.
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
                  $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })

    $out = @()
    foreach ($try in @(
        # AmneziaWG: у Red Shield свой собранный wg(8), у официального клиента - свой.
        "${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvawg.exe",
        "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvawg.exe",
        "$env:ProgramFiles\AmneziaWG\awg.exe",
        "${env:ProgramFiles(x86)}\AmneziaWG\awg.exe",
        # Классический.
        "$env:ProgramFiles\WireGuard\wg.exe",
        "${env:ProgramFiles(x86)}\WireGuard\wg.exe"
    )) {
        if ($try -and (Test-Path -LiteralPath $try)) { $out += $try }
    }
    # Без запятой: обёртка вокруг массива превратила бы три пути в один
    # элемент, и вызов ушёл бы в никуда.
    $out
}

function Get-AbkHandshakes {
    <#
        Когда каждый туннель здоровался в последний раз.

        Спрашиваем у самих клиентов: `show all latest-handshakes` отдаёт строки
        «интерфейс, ключ пира, время». Спрашиваем каждого, кто на машине есть:
        туннель отвечает только своему клиенту, а стоять они могут на разных.
        Права администратора нужны - программа их и держит, потому что без них
        не работает ничего из сетевого: ни служба туннеля, ни состояние
        интерфейса, ни это.

        Возвращает таблицу «имя интерфейса - сколько секунд назад». Пустое
        значение значит, что рукопожатия не было вовсе.
    #>
    $out = @{}
    # Час рождения ошибки: Get-Date -UFormat %s отдаёт местное время под
    # видом всемирного, и возраст рукопожатия уезжал ровно на часовой пояс -
    # здесь на шесть часов. Свежее рукопожатие выглядело шестичасовым, и
    # программа показывала живой туннель мёртвым.
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    foreach ($wg in @(Find-AbkWgCli)) {
        try {
            foreach ($line in @(& $wg show all latest-handshakes 2>$null)) {
                $parts = "$line" -split "\t"
                if ($parts.Count -lt 3) { continue }
                $stamp = 0
                if (-not [int]::TryParse($parts[2].Trim(), [ref]$stamp)) { continue }
                # Ноль значит «не здоровались ни разу»: так отвечает сам wg.
                $out[$parts[0].Trim()] = $(if ($stamp -gt 0) { $now - $stamp } else { $null })
            }
        } catch { }
    }
    $out
}

function Get-AbkTunnelPeer {
    <#
        Адрес дальнего конца внутри туннеля.

        Спросить у WireGuard, когда было рукопожатие, нельзя: wg.exe ходит к
        интерфейсу через канал, открытый только администраторам, и отвечает
        «Permission denied». Поэтому смотрим иначе - стучимся внутрь туннеля.

        Адрес берём от своего же: если у туннеля 172.16.6.4, дальний конец -
        172.16.6.1. Так устроены подсети и роутера BASE, и SECOND VPS: первый
        адрес занимает тот, к кому подключаются.
    #>
    param([Parameter(Mandatory)][string]$Service)

    $name = $Service -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    $card = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $card) { return '' }

    $parts = $card.IPAddress -split '\.'
    if ($parts.Count -ne 4) { return '' }
    '{0}.{1}.{2}.1' -f $parts[0], $parts[1], $parts[2]
}

function Test-AbkTunnelAlive {
    <#
        Отвечает ли дальний конец внутри туннеля и за сколько.

        Это и есть замена рукопожатию: пакет идёт через сам туннель, и мимо
        него не пройдёт. Пинг до роутера по домашней сети так не годился - дома
        он отвечает и при опущенном туннеле.
    #>
    param([Parameter(Mandatory)][string]$Peer, [int]$Wait = 900)

    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $answer = $ping.Send($Peer, $Wait)
        if ($answer.Status -eq 'Success') {
            return @{ Alive = $true; Ms = [int]$answer.RoundtripTime }
        }
    } catch { }
    @{ Alive = $false; Ms = $null }
}

function Get-AbkTunnelServices {
    <#
        Все туннели WireGuard этой машины - как их зовут службы.

        Имена задаёт тот, кто ставил: `base`, `router-base-wg`, чей-то
        ещё. Поэтому не перечисляем известные, а спрашиваем систему.
    #>
    $found = @()
    foreach ($prefix in (Get-AbkTunnelPrefix)) {
        $found += @(Get-Service -Name ($prefix + '*') -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Name })
    }
    @($found | Sort-Object -Unique)
}

function Get-AbkTunnelPower {
    <#
        Состояние туннеля одним словом: on, off или none.

        Считается по сетевому интерфейсу, а не по службе. Служба может идти,
        пока сам интерфейс выключен - так и было на этой машине: служба
        WireGuardTunnel$base в Running, а адаптер base в Disabled, и туннель
        не работал. Программа смотрела на службу, показывала «включён» и на
        нажатие отвечала «уже включено» - менять было нечего.

        Человек видит именно интерфейс: пропал адрес, пропала сеть. По нему и
        отвечаем.
    #>
    param([Parameter(Mandatory)][string]$Service)

    $live = Get-Service -Name $Service -ErrorAction SilentlyContinue
    if (-not $live) { return 'none' }

    $name = $Service -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    $card = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
    if ($card) { return $(if ($card.Status -eq 'Up') { 'on' } else { 'off' }) }

    # Интерфейса нет вовсе - значит туннель не поднят, чем бы ни была занята
    # служба.
    if ($live.Status -eq 'Running') { return 'off' }
    return 'off'
}

function Switch-AbkTunnel {
    <#
        Переключает туннель. Возвращает, что вышло: on, off или почему нет.

        Права проверяются делом, а не заранее: сказать «нет прав» до попытки
        нельзя - служба могла быть настроена под эту учётную запись при
        установке. Если не пустили, так и сообщаем - с подсказкой, что чинится
        это переустановкой туннеля мастером.
    #>
    param(
        [Parameter(Mandatory)][string]$Service,
        [ValidateSet('on', 'off', 'toggle')][string]$To = 'toggle'
    )

    $now = Get-AbkTunnelPower -Service $Service
    if ($now -eq 'none') { return @{ Ok = $false; State = 'none'; Why = 'служба не заведена' } }

    $want = $To
    if ($To -eq 'toggle') { $want = $(if ($now -eq 'on') { 'off' } else { 'on' }) }
    if ($want -eq $now) { return @{ Ok = $true; State = $now; Why = '' } }

    # Служба и интерфейс расходятся: служба может идти при выключенном
    # адаптере. Тогда одного Start-Service мало - перезапускаем службу, чтобы
    # она подняла интерфейс заново.
    $name = $Service -replace '^(WireGuardTunnel|AmneziaWGTunnel)\$', ''
    $live = Get-Service -Name $Service -ErrorAction SilentlyContinue
    $running = ($live -and $live.Status -eq 'Running')

    try {
        if ($want -eq 'on') {
            if ($running) {
                # Служба идёт, а интерфейса нет: поднимаем его сами, а если не
                # выйдет - перекладываем это на службу перезапуском.
                $card = Get-NetAdapter -Name $name -ErrorAction SilentlyContinue
                if ($card -and $card.Status -ne 'Up') {
                    try { Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop }
                    catch { Restart-Service -Name $Service -Force -ErrorAction Stop }
                } else {
                    Restart-Service -Name $Service -Force -ErrorAction Stop
                }
            } else {
                Start-Service -Name $Service -ErrorAction Stop
            }
        }
        else { Stop-Service -Name $Service -Force -ErrorAction Stop }
    } catch {
        return @{ Ok = $false; State = (Get-AbkTunnelPower -Service $Service)
                  Why = $_.Exception.Message.Split([Environment]::NewLine)[0] }
    }

    # Служба меняет состояние не мгновенно: ждём, пока переключится.
    $stop = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $stop) {
        $state = Get-AbkTunnelPower -Service $Service
        if ($state -eq $want) { return @{ Ok = $true; State = $state; Why = '' } }
        Start-Sleep -Milliseconds 300
    }
    @{ Ok = $false; State = (Get-AbkTunnelPower -Service $Service); Why = 'служба не переключилась за 12 секунд' }
}

function Resolve-AbkDataRoot {
    <#
        Приводит указанную папку к папке данных.

        В выборе папки легко зайти на шаг глубже: окно показывает дерево, и
        `Tunnel` внутри выглядит не хуже родителя. Поднимаемся обратно, пока не
        встретим папку, чьё имя начинается с «Audion Backup» - так зовут папку
        данных, и это единственный признак, по которому её можно узнать.

        Прежняя схема держала внутри слой `Machines\<имя>`, и путь складывался
        дважды: `Audion Backup\Machines\Machines\Work`. Слоя больше нет -
        папка данных сама себе профиль, - но подъём остался: ткнуть глубже
        по-прежнему легко.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $here = $Path.TrimEnd('\', '/')
    for ($step = 0; $step -lt 4; $step++) {
        $leaf = Split-Path -Leaf $here
        if ($leaf -like 'Audion Backup*') { break }
        $up = Split-Path -Parent $here
        if (-not $up) { break }
        $here = $up
    }
    $here
}

function Get-AbkProfilePointer {
    <#
        Единственное, что программа хранит у себя: где папка данных и как
        зовётся профиль этой машины. Два поля, ни одного секрета.

        Всё остальное - ключи, адреса, конфиги, пароли - живёт в профиле
        снаружи. Программу можно снести, пересобрать, распаковать заново: она
        прочитает указатель и найдёт своё.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)

    $file = Join-Path $AppRoot 'config\profile.json'
    $out = @{ DataRoot = ''; Profile = '' }
    if (-not (Test-Path -LiteralPath $file)) { return $out }
    try {
        $kept = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        if ($kept.dataRoot) { $out.DataRoot = [string]$kept.dataRoot }
        if ($kept.profile) { $out.Profile = [string]$kept.profile }
    } catch { }
    $out
}

function Set-AbkProfilePointer {
    <# Записывает указатель. Пишется редко: при выборе папки и профиля. #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$Profile
    )
    $file = Join-Path $AppRoot 'config\profile.json'
    try {
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [pscustomobject]@{ dataRoot = $DataRoot; profile = $Profile } |
            ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
        return $true
    } catch { return $false }
}

function Get-AbkProfileNames {
    <#
        Какие папки данных лежат рядом: их и предлагаем на выбор.

        На машине она одна, и выбирать не из чего. Несколько бывает только
        дома, пока собираются комплекты для остальных машин, - там и нужен
        список, чтобы не промахнуться папкой.

        Возвращает полные пути.
    #>
    param([Parameter(Mandatory)][string]$DataRoot)
    $near = Split-Path -Parent (Resolve-AbkDataRoot -Path $DataRoot)
    if (-not $near -or -not (Test-Path -LiteralPath $near)) { return @() }
    @(Get-ChildItem -LiteralPath $near -Directory -Filter 'Audion Backup*' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName } | Sort-Object)
}

function Get-AbkMachineRoot {
    <#
        Профиль этой машины - сама её папка данных.

        Раньше внутри был слой `Machines\<имя>`: папка данных была одна на
        всех, и профили machin приходилось разводить именами. Теперь у каждой
        машины своя папка - `Audion Backup Laptop`, `Audion Backup Work`, - и
        разводить нечего. Имя машины видно снаружи, по имени папки, а вместе
        эти папки лежат только дома, пока собираются комплекты.

        Параметр `Client` остался ради совместимости вызовов и не используется.
    #>
    param(
        [string]$AppRoot = '',
        [string]$DataRoot = '',
        [string]$Client = ''
    )
    if (-not $DataRoot) {
        if (-not $AppRoot) { throw 'нужен либо DataRoot, либо AppRoot' }
        $DataRoot = Find-AbkDataRoot -AppRoot $AppRoot
    }
    Resolve-AbkDataRoot -Path $DataRoot
}

function Find-AbkDataRoot {
    <#
        Папка данных рядом с программой: соседняя, чьё имя начинается с
        «Audion Backup».

        Искать «свою среди многих» не нужно: на машине она одна. Вместе они
        лежат только дома, пока собираются комплекты, и там папку указывают
        руками - указатель на то и есть.

        Ничего не нашлось - возвращаем прежнее имя: пусть окно скажет, что
        папки нет, вместо того чтобы молча работать в пустоте.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)

    $near = Split-Path -Parent $AppRoot
    $found = @(Get-ChildItem -LiteralPath $near -Directory -Filter 'Audion Backup*' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne (Split-Path -Leaf $AppRoot) } | Sort-Object Name)

    if ($found.Count -eq 1) { return $found[0].FullName }
    if ($found.Count -gt 1) {
        # Несколько - значит это домашняя машина со сложенными комплектами.
        # Берём безымянную, если она есть: так звалась папка прежней схемы.
        # An unnamed data folder is also ambiguous when neighbours exist.
        # Несколько именных папок и ни указателя - выбирать за человека нельзя:
        # первая по алфавиту (Base) молча становилась личностью машины, и правки
        # уходили в чужой комплект. CLI в той же ситуации останавливается; окно
        # пусть покажет «папки нет» и попросит выбрать кнопкой ПАПКА ДАННЫХ.
        return (Join-Path $near '__AUDION_DATA_FOLDER_NOT_SELECTED__')
    }
    Join-Path $near 'Audion Backup'
}

function Get-AbkMachinePairs {
    <#
        Разворачивает список в пары «файл там - файл здесь». Маски (пароль
        роутера назван по его адресу) раскрываются по обеим сторонам: файл
        может быть уже в программе, а может только в слое.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [Parameter(Mandatory)][string]$MachineRoot
    )
    $pairs = @()
    foreach ($item in (Get-AbkMachineFiles)) {
        # Не $names: так называется список загрузки окна, и проверка окна
        # ищет его по имени - совпадение уводило её на эту функцию.
        $relatives = @()
        if ($item.Rel) {
            $relatives = @($item.Rel)
        } else {
            $dir = Split-Path -Parent $item.Mask
            $leaf = Split-Path -Leaf $item.Mask
            foreach ($side in @($AppRoot, $MachineRoot)) {
                $where = Join-Path $side $dir
                if (-not (Test-Path -LiteralPath $where)) { continue }
                foreach ($found in Get-ChildItem -LiteralPath $where -Filter $leaf -File -ErrorAction SilentlyContinue) {
                    $rel = Join-Path $dir $found.Name
                    if ($relatives -notcontains $rel) { $relatives += $rel }
                }
            }
        }
        foreach ($rel in $relatives) {
            $pairs += [pscustomobject]@{
                Rel  = $rel
                What = [string]$item.What
                App  = (Join-Path $AppRoot $rel)
                Kept = (Join-Path $MachineRoot $rel)
            }
        }
    }
    # Без запятой: обёртка `,$x` уходит в конвейер одним объектом, и
    # внешний @() считает её единственным элементом - счёт врёт, хотя
    # копирование идёт верно.
    $pairs
}

function Test-AbkSameFile {
    # Сверяем содержимым: время правки меняется и от простого копирования.
    param([string]$Left, [string]$Right)
    if (-not (Test-Path -LiteralPath $Left) -or -not (Test-Path -LiteralPath $Right)) { return $false }
    try {
        return (Get-FileHash -LiteralPath $Left -Algorithm SHA256).Hash -eq
               (Get-FileHash -LiteralPath $Right -Algorithm SHA256).Hash
    } catch { return $false }
}

function Move-AbkMachineLayer {
    <#
        Поднимает профиль прежних схем в корень папки данных.

        Схем было две, и обе держали профиль внутри: сперва общий слой
        `Machine` без имени, потом именной `Machines\<имя>`. Теперь папка
        данных сама себе профиль, и содержимое надо поднять - иначе настройки,
        адреса и пароль роутера останутся лежать там, куда никто больше не
        смотрит.

        Переносится только то, чего в корне ещё нет: свежее важнее принесённого.
    #>
    param(
        [Parameter(Mandatory)][string]$MachineRoot
    )

    $moved = $false
    foreach ($old in @(
        @(Get-ChildItem -LiteralPath (Join-Path $MachineRoot 'Machines') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
        (Join-Path $MachineRoot 'Machine')
    )) {
        if (-not $old) { continue }
        # Признак - есть ли внутри хоть что-то. По наличию config судить нельзя:
        # первый проход уносит его первым, и остаток слоя остаётся навсегда.
        if (-not @(Get-ChildItem -LiteralPath $old -Recurse -File -Force -ErrorAction SilentlyContinue).Count) { continue }
        try {
            # По файлам, а не по верхним папкам: `Tunnel` в корне уже есть - там
            # связка ключей и конфиги туннелей, - и перенос целой папкой пропустил
            # бы всё её содержимое разом. Так и вышло: адреса машин и пароль
            # роутера остались лежать внутри слоя.
            foreach ($file in @(Get-ChildItem -LiteralPath $old -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $rel = $file.FullName.Substring($old.Length).TrimStart('\')
                $to = Join-Path $MachineRoot $rel
                if (Test-Path -LiteralPath $to) { continue }
                $dir = Split-Path -Parent $to
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item -LiteralPath $file.FullName -Destination $to -Force
                $moved = $true
            }
            if (-not @(Get-ChildItem -LiteralPath $old -Recurse -File -Force -ErrorAction SilentlyContinue).Count) {
                Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    # Опустевшая обёртка `Machines` тоже уходит: держать её незачем.
    $wrap = Join-Path $MachineRoot 'Machines'
    if ((Test-Path -LiteralPath $wrap) -and
        -not @(Get-ChildItem -LiteralPath $wrap -Recurse -File -Force -ErrorAction SilentlyContinue).Count) {
        Remove-Item -LiteralPath $wrap -Recurse -Force -ErrorAction SilentlyContinue
    }
    $moved
}

function Restore-AbkMachineState {
    <#
        Разовая миграция: рабочие файлы, оставшиеся в папке программы,
        переезжают в папку данных - с 1.15.0 они живут только там, а
        программа их больше не читает и не пишет.

        Нет в данных и прежний указатель подтверждает папку - переносится.
        Есть и совпадает - копия из программы
        просто снимается. Есть и отличается - в данных своё, а копия из
        программы уходит в карантин ._runtime\migrated-<время>-<id> в данных: ничего не
        теряется, но и чужое в личность машины не попадает. Возвращает
        перенесённые и отправленные в карантин пары (Mode: moved|quarantined).
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$MachineRoot = '',
        [string]$DataRoot = '',
        [string]$Client = ''
    )
    if (-not $MachineRoot) {
        $MachineRoot = Get-AbkMachineRoot -AppRoot $AppRoot -DataRoot $DataRoot -Client $Client
    }
    # Перенос зовём всегда: профиль прежних схем мог остаться внутри и после
    # того, как папку данных однажды уже открывали.
    [void](Move-AbkMachineLayer -MachineRoot $MachineRoot)
    $back = @()
    if (-not (Test-Path -LiteralPath $MachineRoot)) { return $back }

    $quarantine = ''
    $previous = (Get-AbkProfilePointer -AppRoot $AppRoot).DataRoot
    $owned = $previous -and ([IO.Path]::GetFullPath($previous).TrimEnd('\') -eq [IO.Path]::GetFullPath($MachineRoot).TrimEnd('\'))
    foreach ($pair in (Get-AbkMachinePairs -AppRoot $AppRoot -MachineRoot $MachineRoot)) {
        if (-not (Test-Path -LiteralPath $pair.App)) { continue }
        try {
            if ($owned -and -not (Test-Path -LiteralPath $pair.Kept)) {
                $dir = Split-Path -Parent $pair.Kept
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item -LiteralPath $pair.App -Destination $pair.Kept -Force
                $back += [pscustomobject]@{ App = $pair.App; Kept = $pair.Kept; Rel = $pair.Rel; What = $pair.What; Mode = 'moved' }
            } elseif ((Test-Path -LiteralPath $pair.Kept) -and (Test-AbkSameFile -Left $pair.App -Right $pair.Kept)) {
                Remove-Item -LiteralPath $pair.App -Force
            } else {
                if (-not $quarantine) {
                    $quarantine = Join-Path $MachineRoot ('._runtime\migrated-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
                }
                $to = Join-Path $quarantine $pair.Rel
                $dir = Split-Path -Parent $to
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Move-Item -LiteralPath $pair.App -Destination $to -Force
                $back += [pscustomobject]@{ App = $pair.App; Kept = $pair.Kept; Rel = $pair.Rel; What = $pair.What; Mode = 'quarantined' }
            }
        } catch { }
    }
    $back
}

function Save-AbkMachineState {
    <#
        Складывает различия этой машины в данные. Зовётся после каждой записи:
        файлы мелкие, а расхождение между копиями дороже лишнего сравнения.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$MachineRoot = '',
        [string]$DataRoot = '',
        [string]$Client = ''
    )
    # Compatibility entry point: never copy active program files over machine data.
    Restore-AbkMachineState -AppRoot $AppRoot -MachineRoot $MachineRoot -DataRoot $DataRoot -Client $Client
}

function ConvertTo-AbkClientName {
    <#
        Приводит введённое имя к тому виду, который годится в имя файла и в
        подпись ключа: кириллица переписывается латиницей, регистр опускается,
        пробелы и точки становятся тире, всё прочее отбрасывается.

        Отказывать человеку из-за раскладки - плохая работа: он написал «Мой
        ПК», и понятно, что имелось в виду. Мастер покажет, что получилось, и
        спросит, так ли сохранять.
    #>
    [CmdletBinding()]
    param([string]$Name)

    if (-not $Name) { return '' }

    $map = @{
        'а' = 'a'; 'б' = 'b'; 'в' = 'v'; 'г' = 'g'; 'д' = 'd'; 'е' = 'e'; 'ё' = 'e'
        'ж' = 'zh'; 'з' = 'z'; 'и' = 'i'; 'й' = 'y'; 'к' = 'k'; 'л' = 'l'; 'м' = 'm'
        'н' = 'n'; 'о' = 'o'; 'п' = 'p'; 'р' = 'r'; 'с' = 's'; 'т' = 't'; 'у' = 'u'
        'ф' = 'f'; 'х' = 'h'; 'ц' = 'ts'; 'ч' = 'ch'; 'ш' = 'sh'; 'щ' = 'sch'
        'ъ' = ''; 'ы' = 'y'; 'ь' = ''; 'э' = 'e'; 'ю' = 'yu'; 'я' = 'ya'
    }

    $out = ''
    foreach ($ch in $Name.ToLower().ToCharArray()) {
        $one = [string]$ch
        if ($map.ContainsKey($one)) { $out += $map[$one] }
        elseif ($one -cmatch '[a-z0-9]') { $out += $one }
        elseif ($one -match '[\s._]') { $out += '-' }
        elseif ($one -eq '-') { $out += '-' }
    }

    # Тире по краям и подряд идущие - мусор, а не часть имени.
    $out = ($out -replace '-{2,}', '-').Trim('-')
    if ($out.Length -gt 31) { $out = $out.Substring(0, 31).Trim('-') }
    return $out
}

function Get-AbkSuggestedName {
    <#
        Что предложить в поле имени: учётная запись и имя компьютера, склеенные
        через тире и приведённые к годному виду. Повторяющиеся куски убираются -
        учётка admin на машине ADMIN-PC дала бы «admin-admin-pc».

        Человек всё равно правит написанное: предложение экономит ввод, а не
        решает за него.
    #>
    [CmdletBinding()]
    param([string]$User = '', [string]$Computer = '')

    if (-not $User) { $User = $env:USERNAME }
    if (-not $Computer) { $Computer = $env:COMPUTERNAME }

    $parts = @()
    foreach ($piece in @($User, $Computer)) {
        $clean = ConvertTo-AbkClientName -Name $piece
        if (-not $clean) { continue }
        foreach ($word in ($clean -split '-')) {
            if ($word -and ($parts -notcontains $word)) { $parts += $word }
        }
    }

    if (-not $parts.Count) { return '' }
    return ConvertTo-AbkClientName -Name ($parts -join '-')
}

function Test-AbkClientName {
    <#
        Имя машины даёт человек - оно станет именем файла ключа и подписью в
        authorized_keys на всех целях. Поэтому допускаем только то, что
        одинаково читается везде: латиница в нижнем регистре, цифры, тире и
        подчёркивание. Кириллица, пробелы и точки ломают то ssh, то путь.
    #>
    [CmdletBinding()]
    param([string]$Name)

    if (-not $Name) { return $false }
    return ($Name -cmatch '^[a-z0-9][a-z0-9_-]{1,30}$')
}

function Add-AbkAuthorizedKey {
    <#
        Кладёт открытую половину в authorized_keys на той стороне - через уже
        живой доступ. Из ничего доступ не появляется: если войти нельзя,
        функция так и скажет.

        Дважды одну строку не пишет: сверяет по самому ключу, а не по подписи,
        поэтому переименование метки ничего не ломает.

        Возвращает слово: added, already, unreachable, failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [Parameter(Mandatory)][string]$PublicKey,
        [ValidateSet('windows', 'unix')][string]$Kind = 'unix'
    )

    $parts = $PublicKey.Trim() -split ' '
    if ($parts.Count -lt 2) { return 'failed' }
    $body = $parts[1]

    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Kind -eq 'windows') {
            # У администраторов Windows файл общий, и права на нём особые:
            # трогаем только содержимое, ACL не переписываем.
            $probe = 'powershell -NoProfile -Command "if (Test-Path $env:ProgramData\ssh\administrators_authorized_keys) { Select-String -Path $env:ProgramData\ssh\administrators_authorized_keys -SimpleMatch -Pattern ''KEYBODY'' -Quiet } else { $false }"'
            $probe = $probe.Replace('KEYBODY', $body)
            $seen = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost $probe 2>$null
            if ($LASTEXITCODE -ne 0) { return 'unreachable' }
            if ("$seen".Trim() -eq 'True') { return 'already' }

            $line = $PublicKey.Trim()
            $write = 'powershell -NoProfile -Command "Add-Content -Path $env:ProgramData\ssh\administrators_authorized_keys -Value ''LINE''"'
            $write = $write.Replace('LINE', $line)
            $null = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost $write 2>$null
            if ($LASTEXITCODE -ne 0) { return 'failed' }
            return 'added'
        }

        $seen = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost ("grep -qF '{0}' ~/.ssh/authorized_keys && echo yes || echo no" -f $body) 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unreachable' }
        if ("$seen".Trim() -eq 'yes') { return 'already' }

        $null = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost ("mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s\n' '{0}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" -f $PublicKey.Trim()) 2>$null
        if ($LASTEXITCODE -ne 0) { return 'failed' }
        return 'added'
    } finally {
        $ErrorActionPreference = $was
    }
}

function Remove-AbkAuthorizedKey {
    <#
        Убирает половину из authorized_keys на той стороне. Строка ищется по
        самому ключу: подпись - метка, и по ней отзывать опасно.

        Возвращает слово: removed, missing, unreachable, failed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [Parameter(Mandatory)][string]$KeyBody,
        [ValidateSet('windows', 'unix')][string]$Kind = 'unix'
    )

    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Kind -eq 'windows') {
            $script = 'powershell -NoProfile -Command "$f=$env:ProgramData+''\ssh\administrators_authorized_keys''; if (-not (Test-Path $f)) { ''missing''; exit }; $rows=@(Get-Content $f); $keep=@($rows | Where-Object { $_ -notlike ''*KEYBODY*'' }); if ($keep.Count -eq $rows.Count) { ''missing'' } else { Set-Content -Path $f -Value $keep; ''removed'' }"'
            $script = $script.Replace('KEYBODY', $KeyBody)
            $answer = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost $script 2>$null
            if ($LASTEXITCODE -ne 0) { return 'unreachable' }
            return "$answer".Trim()
        }

        $answer = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost ("f=~/.ssh/authorized_keys; if [ ! -f `$f ]; then echo missing; elif grep -qF '{0}' `$f; then grep -vF '{0}' `$f > `$f.new && mv `$f.new `$f && chmod 600 `$f && echo removed; else echo missing; fi" -f $KeyBody) 2>$null
        if ($LASTEXITCODE -ne 0) { return 'unreachable' }
        return "$answer".Trim()
    } finally {
        $ErrorActionPreference = $was
    }
}

function Get-AbkAuthorizedKeys {
    <#
        Кто прописан на той стороне: список из тела ключа и подписи. Нужен не
        ради любопытства - перед отзывом надо знать, останется ли машина
        доступной хоть кому-нибудь.

        Возвращает пустой список и когда файла нет, и когда машина молчит;
        различить помогает $Reachable по ссылке.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [ValidateSet('windows', 'unix')][string]$Kind = 'unix',
        [ref]$Reachable = $null
    )

    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Kind -eq 'windows') {
            $script = 'powershell -NoProfile -Command "$f=$env:ProgramData+''\ssh\administrators_authorized_keys''; if (Test-Path $f) { Get-Content $f }"'
            $rows = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost $script 2>$null
        } else {
            $rows = & ssh -o BatchMode=yes -o ConnectTimeout=10 $SshHost 'cat ~/.ssh/authorized_keys 2>/dev/null' 2>$null
        }
        $ok = ($LASTEXITCODE -eq 0)
        if ($Reachable) { $Reachable.Value = $ok }
        if (-not $ok) { return @() }

        $out = @()
        foreach ($row in @($rows)) {
            $parts = ([string]$row).Trim() -split ' '
            if ($parts.Count -lt 2) { continue }
            $out += [pscustomobject]@{
                Body = $parts[1]
                Label = $(if ($parts.Count -ge 3) { $parts[2] } else { '' })
            }
        }
        return $out
    } finally {
        $ErrorActionPreference = $was
    }
}

function Get-AbkKeyInventory {
    <#
        Все ключи хозяйства одним списком.

        Ключ узнаётся по телу, а не по имени файла: одна и та же половина
        лежит под разными именами - в связке `<машина>.pub`, в профиле
        `<машина>_ed25519.pub`, - и по именам они выглядели бы двумя
        разными ключами. Тело же совпадает буква в букву.

        Назначение выводится из места, а не из названия. Название врёт: имя
        `audion_codex_ed25519` однажды приняли за ключ машины, хотя это дверь
        на MAIN VPS. Место не врёт: в `clients` кладёт мастер, в `servers` -
        раскладка связки.

        Чистая функция: только читает и ничего не спрашивает у сети.
    #>
    [CmdletBinding()]
    param(
        [string]$SshDir = '',
        [string]$Store = '',
        [string]$Kit = ''
    )

    $places = @()
    if ($SshDir) { $places += @{ Path = $SshDir; Where = 'профиль'; Purpose = '' } }
    if ($Store) {
        $places += @{ Path = (Join-Path $Store 'clients'); Where = 'CLIENTS'; Purpose = 'машина' }
        $places += @{ Path = (Join-Path $Store 'servers'); Where = 'Tunnel\SSH\servers'; Purpose = 'MAIN VPS и SECOND VPS' }
        $places += @{ Path = $Store; Where = 'Tunnel\SSH'; Purpose = 'старая схема' }
    }
    if ($Kit) { $places += @{ Path = $Kit; Where = 'Export Keys'; Purpose = '' } }

    $found = @{}
    foreach ($place in $places) {
        if (-not (Test-Path -LiteralPath $place.Path)) { continue }
        foreach ($pub in @(Get-ChildItem -LiteralPath $place.Path -Filter '*.pub' -File -ErrorAction SilentlyContinue)) {
            # Строка ключа - это тип, тело и подпись. Хвостовой перевод
            # строки даёт второй элемент даже у мусора, поэтому мало посчитать
            # части: тип обязан быть типом, а тело - непустым.
            $text = (Get-Content -LiteralPath $pub.FullName -Raw -ErrorAction SilentlyContinue)
            if (-not $text) { continue }
            $parts = $text.Trim() -split '\s+'
            if ($parts.Count -lt 2) { continue }
            if ($parts[0] -notmatch '^(ssh|ecdsa|sk)-') { continue }
            $body = $parts[1]
            if (-not $body) { continue }

            if (-not $found.ContainsKey($body)) {
                $found[$body] = [pscustomobject]@{
                    Body = $body
                    Names = New-Object System.Collections.Generic.List[string]
                    Places = New-Object System.Collections.Generic.List[string]
                    Purpose = ''
                    Private = New-Object System.Collections.Generic.List[string]
                }
            }
            $item = $found[$body]

            $name = $pub.BaseName
            if (-not $item.Names.Contains($name)) { $item.Names.Add($name) }
            if (-not $item.Places.Contains($place.Where)) { $item.Places.Add($place.Where) }
            if ($place.Purpose -and -not $item.Purpose) { $item.Purpose = $place.Purpose }

            # Закрытая половина - файл с тем же именем, но без .pub.
            $private = Join-Path $place.Path $pub.BaseName
            if (Test-Path -LiteralPath $private) {
                if (-not $item.Private.Contains($place.Where)) { $item.Private.Add($place.Where) }
            }
        }
    }

    foreach ($item in $found.Values) {
        if (-not $item.Purpose) { $item.Purpose = 'без места' }
    }

    return @($found.Values | Sort-Object @{ Expression = { $_.Purpose } }, @{ Expression = { $_.Names[0] } })
}

function Get-AbkMachineKey {
    <#
        Закрытая половина ЭТОЙ машины - та, которой она ходит на свои.

        Имя машины окно помнит в настройках, но помнит не всегда: ключ мог
        появиться до того, как настройки завели, или настройки могли уехать.
        Поэтому имя - только подсказка, а решает связка: половина лежит в
        `clients`, и если рядом, в профиле, есть парный закрытый файл - это и
        есть ключ здешней машины.

        Возвращает имя файла (`<машина>_ed25519`) или пустую строку.
        Общий ключ старой схемы сюда не попадает: он не в `clients`.
    #>
    [CmdletBinding()]
    param(
        [string]$Store = '',
        [string]$SshDir = '',
        [string]$Preferred = ''
    )

    if (-not $SshDir) { return '' }

    if ($Preferred) {
        $named = '{0}_ed25519' -f $Preferred
        if (Test-Path -LiteralPath (Join-Path $SshDir $named)) { return $named }
    }

    if (-not $Store -or -not (Test-Path -LiteralPath $Store)) { return '' }

    foreach ($half in @(Get-ChildItem -LiteralPath $Store -Filter '*.pub' -ErrorAction SilentlyContinue |
            Sort-Object Name)) {
        # Публичная половина в CLIENTS зовётся <имя>_ed25519.pub: суффикс уже в
        # BaseName, второй раз его не клеим - иначе искали …_ed25519_ed25519.
        $stem = $half.BaseName -replace '_ed25519$', ''
        $candidate = '{0}_ed25519' -f $stem
        if (Test-Path -LiteralPath (Join-Path $SshDir $candidate)) { return $candidate }
    }

    return ''
}

Export-ModuleMember -Function Find-AbkDataRoot, Find-AbkWgCli, Find-AbkAwgExe, Test-AbkTunnelOrphan, Test-AbkForeignTunnel, Get-AbkTunnelPrefix, Get-AbkHandshakes, Get-AbkTunnelPeer, Test-AbkTunnelAlive, Get-AbkTunnelServices, Get-AbkVpnService, Get-AbkTunnelPower, Switch-AbkTunnel, Resolve-AbkDataRoot, Restore-AbkTargetsFile, Move-AbkMachineLayer, Get-AbkProfilePointer, Set-AbkProfilePointer, Get-AbkProfileNames, Get-AbkMachineFiles, Get-AbkMachineRoot, Get-AbkMachinePairs, Restore-AbkMachineState, Save-AbkMachineState, Test-AbkSameFile, Set-AbkTargetEntry, Build-AbkTransport, Test-AbkClientName, ConvertTo-AbkClientName, Get-AbkSuggestedName, Add-AbkAuthorizedKey, Remove-AbkAuthorizedKey, Get-AbkAuthorizedKeys, Get-AbkMachineKey, Get-AbkKeyInventory
