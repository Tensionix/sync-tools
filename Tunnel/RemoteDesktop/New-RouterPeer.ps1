<#
.SYNOPSIS
    Выписывает конфиг WireGuard на этой машине: сам заводит пира в роутере.

.DESCRIPTION
    То же, что делается руками в веб-интерфейсе роутера — добавить клиента,
    скачать его файл, — но целиком отсюда и без браузера.

    По шагам: ключевая пара рождается на этой машине (приватный ключ роутеру
    не показывается вовсе), в роутере заводится пир с публичным ключом и
    свободным адресом из его же подсети, обратно забираются публичный ключ
    WG-сервера и порт, из всего этого собирается .conf.

    Ключи генерирует wg.exe из установленного WireGuard: своей арифметики
    здесь нет и быть не должно.

    Сначала стоит запустить с -WhatIf: он покажет команды, которые ушли бы в
    роутер, и ничего не сделает.

.PARAMETER Name
    Имя пира: так он будет подписан в роутере и в конфиге. По умолчанию — имя
    этой машины.

.PARAMETER Address
    Адрес роутера. По умолчанию - из записи -Router в targets.json (lan или host).

.PARAMETER User
    Учётная запись роутера. По умолчанию admin.

.PARAMETER Interface
    Интерфейс WG-сервера в роутере. По умолчанию ищется сам: у WG-сервера роутер
    держит признак server-owned, а в конфигурации - строку listen-port. Порт
    слушают оба туннеля (у клиента он свой, случайный), поэтому по одному лишь
    порту их не различить.

.PARAMETER Endpoint
    Чем клиент будет находить роутер: имя или адрес. По умолчанию берётся
    доменное имя роутера, а если его нет - Endpoint из уже выписанного
    конфига рядом.

.PARAMETER Out
    Куда положить собранный конфиг. По умолчанию — рядом, в config\<имя>.conf.

.PARAMETER Remove
    Снять пира с таким именем вместо того, чтобы заводить нового. Ключ берётся
    из конфигурации роутера, конфиг на диске не трогается.

.PARAMETER WhatIf
    Показать команды и остановиться, ничего не меняя в роутере.

.EXAMPLE
    .\New-RouterPeer.ps1 -WhatIf
    Посмотреть, что будет сделано.

.EXAMPLE
    .\New-RouterPeer.ps1 -Name LAPTOP
    Выписать конфиг для другой машины.
#>
[CmdletBinding()]
param(
    [string]$Name = $env:COMPUTERNAME,
    [string]$Address = '',
    [string]$Router = 'router-base',
    [string]$User = 'admin',
    [string]$Interface,
    [string]$Endpoint,
    [string]$Out,
    [switch]$Remove,
    [switch]$WhatIf,
    [switch]$Remember,
    # Папка данных этой машины: окно передаёт её каждому врапперу.
    [string]$Root,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'RouterNdm.psm1') -Force -DisableNameChecking

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Find-Wg {
    <#
        Утилита wg(8): ею рождается ключевая пара. Своя есть и у AmneziaWG, и
        берём её первой - на машине с чужим VPN обычного WireGuard может не
        быть вовсе, а ставить его ради одного genkey не за чем.

        Разрядность своя: запуск сборки не под свою машину показывает модальное
        окно Windows, которое ничем не поймать.
    #>
    $arch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or
                  $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } else { 'amd64' })
    foreach ($p in @("${env:ProgramFiles(x86)}\Red Shield VPN\awg\$arch\rsvawg.exe",
                     "$env:ProgramFiles\Red Shield VPN\awg\$arch\rsvawg.exe",
                     "$env:ProgramFiles\AmneziaWG\awg.exe",
                     "${env:ProgramFiles(x86)}\AmneziaWG\awg.exe",
                     'wg.exe', "$env:ProgramFiles\WireGuard\wg.exe", "${env:ProgramFiles(x86)}\WireGuard\wg.exe")) {
        $c = Get-Command $p -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        if (Test-Path $p) { return $p }
    }
    return $null
}

if (-not $Address) { $Address = Get-RouterAddress -Router $Router -Root $Root }

Write-Host "`n=== Выписка конфига для '$Name' на роутере $Address ===`n" -ForegroundColor Cyan

$wg = Find-Wg
if (-not $wg) { throw "Нет wg.exe — сначала поставь WireGuard: install-wireguard.cmd" }

# Пароль спрашиваем только когда его негде взять: сохранённый лежит рядом,
# зашифрованный под эту учётную запись и эту машину.
$password = Get-RouterSecret -Router $Router -Root $Root
if ($password) {
    Write-Line 'пароль взят из сохранённого' DarkGray
} else {
    $password = Read-Host "  Пароль учётной записи $User на роутере" -AsSecureString
    Write-Host ""
}
if ($Remember) {
    $kept = Save-RouterSecret -Router $Router -Password $password -Root $Root
    Write-Line "пароль сохранён: $kept" DarkGray
}

$session = $null
try {
    $session = Connect-Router -Address $Address -User $User -Password $password
    Write-Line $session.Note Green

    # --- 1. Какой интерфейс WG-сервер ---------------------------------------
    $interfaces = Invoke-Rci -Session $session -Path 'show/interface'
    $wgFaces = @($interfaces.PSObject.Properties |
        Where-Object { $_.Value.type -eq 'Wireguard' } | ForEach-Object { $_.Value })

    $server = $null
    if ($Interface) {
        $server = $wgFaces | Where-Object { $_.id -eq $Interface -or $_.'interface-name' -eq $Interface } | Select-Object -First 1
        if (-not $server) { throw "Интерфейса $Interface на роутере нет" }
    } else {
        # Признак WG-сервера - поле server-owned: роутер ставит его тому туннелю,
        # который создан приложением «WG-сервер». У клиентского
        # туннеля такого поля нет вовсе, хотя порт слушают оба.
        $server = $wgFaces | Where-Object {
            $_.PSObject.Properties['wireguard'] -and $_.wireguard.PSObject.Properties['server-owned']
        } | Select-Object -First 1

        if (-not $server) {
            Write-Host ""
            Write-Line 'Не нашёл интерфейс, похожий на WG-сервер. Что есть в роутере:' Yellow
            foreach ($face in $wgFaces) {
                Write-Line ("  {0} ({1}) — {2}" -f $face.description, $face.id, $face.state) DarkGray
            }
            throw "Укажи интерфейс явно: -Interface Wireguard2"
        }
    }

    $faceId = $server.id
    $listen = $server.wireguard.'listen-port'
    $serverKey = if ($server.wireguard.PSObject.Properties['public-key']) { $server.wireguard.'public-key' } else { $null }
    Write-Line ("WG-сервер: {0} ({1}), порт {2}" -f $server.description, $faceId, $listen) Green

    # --- 2. Свободный адрес в его подсети -----------------------------------
    # Кому какой адрес выдан, роутер держит в конфигурации, а не в состоянии:
    # в show/interface у пира есть трафик и рукопожатие, но не allow-ips.
    $netAddress = $server.address
    if ($netAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "Интерфейс $($server.id) без адреса — выдавать пиру нечего"
    }
    $prefix = ($netAddress -replace '\.\d+$', '')

    $config = Invoke-Rci -Session $session -Path 'show/running-config'
    $configText = if ($config -is [string]) { $config } elseif ($config.PSObject.Properties['message']) { $config.message } else { $config | Out-String }

    $taken = @($netAddress)
    $inside = $false
    foreach ($line in ($configText -split "`r?`n")) {
        if ($line -match ('^\s*interface\s+' + [regex]::Escape($server.id) + '\s*$')) { $inside = $true; continue }
        if ($inside -and $line -match '^\S') { break }
        if ($inside -and $line -match '^\s*allow-ips\s+(\d{1,3}(?:\.\d{1,3}){3})') {
            $taken += $matches[1]
        }
    }

    $free = $null
    foreach ($n in 2..254) {
        $candidate = "$prefix.$n"
        if ($taken -notcontains $candidate) { $free = $candidate; break }
    }
    if (-not $free) { throw "В подсети $prefix.0/24 свободных адресов не осталось" }
    Write-Line ("адрес пира: {0} (занято: {1})" -f $free, ($taken.Count)) Green

    # --- 2а. Снятие пира ----------------------------------------------------
    if ($Remove) {
        # Ключ пира лежит только в конфигурации: в строке «wireguard peer <ключ>
        # !Имя». По имени и находим, что снимать.
        $victim = $null
        $inside = $false
        foreach ($line in ($configText -split "`r?`n")) {
            if ($line -match ('^\s*interface\s+' + [regex]::Escape($server.id) + '\s*$')) { $inside = $true; continue }
            if ($inside -and $line -match '^\S') { break }
            if ($inside -and $line -match '^\s*wireguard peer\s+(\S+)\s+!(.+?)\s*$') {
                if ($matches[2] -eq $Name) { $victim = $matches[1]; break }
            }
        }
        if (-not $victim) { throw "Пира с именем $Name в роутере нет" }

        $drop = @(
            "no interface $faceId wireguard peer $victim",
            "system configuration save"
        )
        Write-Host ""
        Write-Line 'команды роутеру:' Cyan
        foreach ($line in $drop) {
            Write-Host ("    " + ($line -replace '[A-Za-z0-9+/]{40,}={0,2}', '<ключ>')) -ForegroundColor DarkGray
        }
        Write-Host ""
        if ($WhatIf) {
            Write-Host "  Это был показ: в роутер ничего не ушло.`n" -ForegroundColor Cyan
            exit 0
        }
        foreach ($line in $drop) { [void](Invoke-Rci -Session $session -Path '' -Body @(@{ parse = $line })) }
        Write-Line "пир $Name снят" Green
        Write-Host ""
        exit 0
    }

    # --- 3. Ключи рождаются здесь -------------------------------------------
    # Приватная половина роутеру не уходит: он получает только открытую.
    $private = (& $wg genkey).Trim()

    # Через файл, а не пайпом. PowerShell, отдавая строку нативной программе,
    # дописывает перевод строки по-виндовому, и wg(8) отвечает «Trailing
    # characters found after key»: классический клиент это прощал, сборка
    # AmneziaWG - нет. Ключ живёт во временном файле ровно один вызов.
    $keyTmp = Join-Path $env:TEMP ('wgkey-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($keyTmp, $private + "`n")
        $public = (& cmd /c "`"$wg`" pubkey < `"$keyTmp`"" 2>$null | Out-String).Trim()
    } finally {
        Remove-Item -LiteralPath $keyTmp -Force -ErrorAction SilentlyContinue
    }
    if (-not $public) { throw "не вышло посчитать публичный ключ - проверь клиент WireGuard" }
    $preshared = (& $wg genpsk).Trim()

    # --- 4. Команды роутеру --------------------------------------------------
    # Слова взяты из его же running-config: комментарий пишется через «!»,
    # маска у пира полная, connect включает пира.
    $commands = @(
        "interface $faceId wireguard peer $public !$Name",
        "interface $faceId wireguard peer $public preshared-key $preshared",
        "interface $faceId wireguard peer $public allow-ips $free 255.255.255.255",
        "interface $faceId wireguard peer $public connect",
        "system configuration save"
    )

    Write-Host ""
    Write-Line 'команды роутеру:' Cyan
    foreach ($line in $commands) {
        Write-Host ("    " + ($line -replace '[A-Za-z0-9+/]{40,}={0,2}', '<ключ>')) -ForegroundColor DarkGray
    }
    Write-Host ""

    if ($WhatIf) {
        Write-Host "  Это был показ: в роутер ничего не ушло.`n" -ForegroundColor Cyan
        exit 0
    }

    # Тёзка означает, что прошлый запуск дошёл до роутера: второй пир с тем же
    # именем и другим ключом только запутает, а первый останется мусором.
    if ($configText -match ('!\s*' + [regex]::Escape($Name) + '\s*$')) {
        throw "Пир с именем $Name в роутере уже есть — выбери другое имя или сними прежний"
    }

    foreach ($line in $commands) {
        # RCI принимает команды пачкой, поэтому шлём массивом из одной - так же,
        # как это делает веб-интерфейс роутера.
        $answer = Invoke-Rci -Session $session -Path '' -Body @(@{ parse = $line })

        # Ответ приходит по-разному: объектом, массивом объектов, со статусами
        # внутри. Ищем признаки отказа везде, где они могут лежать.
        $trouble = @()
        foreach ($item in @($answer)) {
            if ($null -eq $item) { continue }
            $statuses = @()
            if ($item.PSObject.Properties['status']) { $statuses = @($item.status) }
            elseif ($item.PSObject.Properties['parse'] -and $item.parse.PSObject.Properties['status']) { $statuses = @($item.parse.status) }
            foreach ($st in $statuses) {
                if ($st.PSObject.Properties['status'] -and $st.status -match 'error') { $trouble += $st.message }
            }
        }

        if ($trouble) {
            Write-Host ""
            Write-Line ("команда: " + ($line -replace '[A-Za-z0-9+/]{40,}={0,2}', '<ключ>')) Yellow
            foreach ($message in $trouble) { Write-Line ("  ответ: " + $message) Yellow }
            throw "Роутер не принял команду"
        }
    }
    Write-Line 'пир заведён и сохранён' Green

    # --- 5. Открытый ключ WG-сервера ----------------------------------------
    if (-not $serverKey) { throw "Роутер не показал свой открытый ключ — конфиг собрать не из чего" }

    # --- 6. Конфиг -----------------------------------------------------------
    # Точка входа — доменное имя роутера: домашний адрес у провайдера меняется,
    # а имя следует за ним.
    $endpointHost = $Endpoint
    if (-not $endpointHost) {
        try {
            # Роутер держит имя разобранным: name отдельно, domain отдельно.
            # Склеиваем сами, иначе в конфиг уедет «baseultra» без домена.
            $dns = Invoke-Rci -Session $session -Path 'show/ndns'
            if ($dns -and $dns.PSObject.Properties['name'] -and $dns.name) {
                $endpointHost = $dns.name
                if ($dns.PSObject.Properties['domain'] -and $dns.domain -and $endpointHost -notmatch '\.') {
                    $endpointHost = "{0}.{1}" -f $dns.name, $dns.domain
                }
            }

            # access = direct означает, что имя ведёт прямо на роутер. В облачном
            # режиме через это имя ходит только веб, а WireGuard - нет.
            if ($dns -and $dns.PSObject.Properties['access'] -and $dns.access -ne 'direct') {
                Write-Line ("имя роутера работает через облако ({0}) — WireGuard по нему не пройдёт" -f $dns.access) Yellow
            }
        } catch { }
    }
    if (-not $endpointHost) {
        # Запасной источник - конфиг, выписанный роутером раньше: там уже стоит
        # то самое имя, по которому его находят снаружи.
        $earlier = Get-ChildItem (Join-Path $PSScriptRoot 'config') -Filter '*.conf' -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($earlier) {
            $found = Select-String -Path $earlier.FullName -Pattern '^\s*Endpoint\s*=\s*([^:]+)' |
                     Select-Object -First 1
            if ($found) { $endpointHost = $found.Matches.Groups[1].Value.Trim() }
        }
    }
    if (-not $endpointHost) {
        throw "Не знаю, по какому имени клиент найдёт роутер — задай -Endpoint"
    }

    $conf = @(
        '[Interface]',
        "# Name = $Name",
        "Address = $free/32",
        "PrivateKey = $private",
        '',
        '[Peer]',
        "# Name = $endpointHost",
        "PublicKey = $serverKey",
        "PresharedKey = $preshared",
        "Endpoint = ${endpointHost}:$listen",
        "AllowedIPs = 0.0.0.0/0",   # setup-base-vpn.cmd сузит до сетей BASE
        'PersistentKeepalive = 15'
    )

    if (-not $Out) {
        # Внутри конфига закрытый ключ, поэтому место ему в данных - рядом с
        # конфигом туннеля в сеть BASE, а не в папке программы: та уезжает копией
        # на соседние машины.
        $tunnelRoot = Split-Path $PSScriptRoot -Parent
        . (Join-Path (Split-Path -Parent $tunnelRoot) 'Engine\DataRoot.ps1')
        . (Join-Path (Split-Path -Parent $tunnelRoot) 'Engine\Secrets.ps1')
        $dataRoot = Get-AbkDataRootPath -AppRoot (Split-Path -Parent $tunnelRoot) -Root $Root
        $dir = Join-Path $dataRoot 'Tunnel\WG'
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $Out = Join-Path $dir ("wg-srv_{0}.conf" -f $Name)
    }
    Set-Content -LiteralPath $Out -Value ($conf -join "`r`n") -Encoding ascii

    # Выписанный конфиг несёт приватную половину пары: она рождается здесь и
    # роутеру не уходит. Значит и лежать должна закрытой.
    if (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue) {
        [void](Protect-AbkSecret -Path $Out)
    }
    Write-Line "конфиг: $Out" Green

    Write-Host "`n  Готово. Туннель до router-base поднимается так:" -ForegroundColor Cyan
    Write-Host "      setup-base-vpn.cmd -From `"$Out`"`n" -ForegroundColor Cyan
    exit 0
} catch {
    Write-Host "`n  Сорвалось: $($_.Exception.Message)`n" -ForegroundColor Red
    exit 1
} finally {
    if ($session) { Disconnect-Router -Session $session }
}
