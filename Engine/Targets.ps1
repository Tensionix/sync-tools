<#
    SECOND VPS хозяйства.

    SECOND VPS - внутри страны: из дома до него маршрут прямой, без VPN, и через
    него ходят к машинам, когда маршруты через MAIN VPS молчат. Всё, что у каждого
    своё, - адрес, имена хостов в ~\.ssh\config, ключ и учётная запись - лежит в
    targets.json, в записи `second`. В коде и в образцах остаются только
    нейтральные имена по умолчанию: программа уезжает в публичный архив, а
    адреса и имена провайдеров - нет.

    Машина, настроенная до записи `second`, держит SECOND VPS только в своём
    ~\.ssh\config: так его прописывал клиент туннеля. Её запись переносится
    оттуда - по устройству файла, без единого угаданного имени.

    Файл дот-сорсится: его зовут и окно, и сценарии туннелей, которые модуль
    окна не грузят, а знать ответ должны одинаково.
#>

# Адреса живут в папке данных: резолвер оттуда.
. (Join-Path $PSScriptRoot 'DataRoot.ps1')

function Get-AbkSshConfigPath {
    <# Свой ~\.ssh\config. Без профиля пользователя его нет вовсе. #>
    if (-not $HOME) { return '' }
    return (Join-Path $HOME '.ssh\config')
}

function Read-AbkSshConfig {
    <#
        Хосты из ~\.ssh\config: имена, адрес, порт, учётная запись, ключ,
        прыжок и то, стоит ли запись в блоке клиента туннеля.

        `ssh -G` здесь не годится: он отвечает про одно имя, а нужен весь список
        разом - SECOND VPS узнаётся по тому, что стоит с ним рядом.

        Include раскрывается так же, как у OpenSSH: относительный путь считается
        от ~\.ssh, маски разворачиваются, глубина ограничена. Без этого имя,
        описанное во включённом файле, выглядело отсутствующим, и сборка
        транспорта принимала рабочий хост за несуществующий.
    #>
    param([string]$Path = '')

    if (-not $Path) { $Path = Get-AbkSshConfigPath }
    $hosts = New-Object System.Collections.Generic.List[hashtable]
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Add-AbkSshConfigHosts -Path $Path -Hosts $hosts -Depth 0
    }
    return $hosts.ToArray()
}

function Add-AbkSshConfigHosts {
    <# Один файл ssh config - в общий список хостов; Include - рекурсией. #>
    param(
        [Parameter(Mandatory)][string]$Path,
        # Список пуст, пока не разобран ни один хост: обязательный параметр без
        # AllowEmptyCollection отказывал уже первому вызову.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[hashtable]]$Hosts,
        [int]$Depth = 0
    )

    # OpenSSH останавливается на шестнадцатом уровне вложенности, и мы тоже:
    # файл, включающий сам себя, иначе разбирался бы вечно.
    if ($Depth -gt 16) { return }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return }

    $managed = $false
    $current = $null
    foreach ($raw in $lines) {
        $line = $raw.Trim()
        if ($line -eq '# >>> audion-tunnel >>>') { $managed = $true; $current = $null; continue }
        if ($line -eq '# <<< audion-tunnel <<<') { $managed = $false; $current = $null; continue }
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^(\w+)(?:\s*=\s*|\s+)(.+)$') { continue }
        $word = $Matches[1].ToLowerInvariant()
        $value = $Matches[2].Trim()

        if ($word -eq 'include') {
            foreach ($token in [regex]::Matches($value, '"([^"]+)"|(\S+)')) {
                $target = $(if ($token.Groups[1].Success) { $token.Groups[1].Value } else { $token.Groups[2].Value })
                if ($target.StartsWith('~')) {
                    if (-not $HOME) { continue }
                    $target = Join-Path $HOME $target.Substring(1).TrimStart('/', '\')
                } elseif (-not [System.IO.Path]::IsPathRooted($target)) {
                    if (-not $HOME) { continue }
                    $target = Join-Path (Join-Path $HOME '.ssh') $target
                }
                $files = @()
                if ($target -match '[*?]') {
                    $files = @(Get-ChildItem -Path $target -File -ErrorAction SilentlyContinue |
                        Sort-Object Name | ForEach-Object { $_.FullName })
                } elseif (Test-Path -LiteralPath $target -PathType Leaf) {
                    $files = @($target)
                }
                foreach ($file in $files) { Add-AbkSshConfigHosts -Path $file -Hosts $Hosts -Depth ($Depth + 1) }
            }
            continue
        }

        $value = $value.Trim('"')
        if ($word -eq 'host') {
            $current = @{
                Names        = @($value -split '\s+' | Where-Object { $_ })
                HostName     = ''
                Port         = 0
                User         = ''
                IdentityFile = ''
                ProxyJump    = ''
                Managed      = $managed
            }
            $Hosts.Add($current)
            continue
        }
        # Match устроен иначе, и SECOND VPS в нём не прописывали.
        if ($word -eq 'match') { $current = $null; continue }
        if (-not $current) { continue }

        # Побеждает первое значение - так читает и сам ssh.
        switch ($word) {
            'hostname'     { if (-not $current.HostName) { $current.HostName = $value } }
            'port'         {
                $number = 0
                if (-not $current.Port -and [int]::TryParse($value, [ref]$number)) { $current.Port = $number }
            }
            'user'         { if (-not $current.User) { $current.User = $value } }
            'identityfile' { if (-not $current.IdentityFile) { $current.IdentityFile = $value } }
            'proxyjump'    { if (-not $current.ProxyJump) { $current.ProxyJump = $value } }
        }
    }
}

function Test-AbkSshHost {
    <#
        Знает ли ssh это имя - так, как его понимает сам ssh.

        Список хостов с раскрытым Include отвечает на прямой вопрос. `ssh -G`
        добавляет то, чего список не видит: Match и шаблоны. Имя считается
        известным, если оно названо в строке Host или если ssh разрешает его в
        другой адрес либо ведёт через прыжок.

        Буквальный поиск строки Host в одном файле ошибался в обе стороны
        сразу: не видел включённых файлов, и сборка транспорта затирала рабочий
        хост меткой.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [string]$Path = ''
    )

    if (-not $Name) { return $false }
    foreach ($entry in @(Read-AbkSshConfig -Path $Path)) {
        if ($entry.Names -contains $Name) { return $true }
    }

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) { return $false }
    $arguments = @('-G')
    if ($Path) { $arguments += @('-F', $Path) }
    $arguments += $Name

    $shown = @()
    $was = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $shown = @(& $ssh.Source @arguments 2>$null)
        $code = $LASTEXITCODE
    } catch {
        $code = 1
    } finally {
        $ErrorActionPreference = $was
    }
    if ($code -ne 0) { return $false }

    $options = @{}
    foreach ($row in $shown) {
        $parts = ([string]$row).Trim() -split '\s+', 2
        if ($parts.Count -eq 2 -and -not $options.ContainsKey($parts[0])) { $options[$parts[0]] = $parts[1] }
    }
    foreach ($jump in 'proxyjump', 'proxycommand') {
        if ($options[$jump] -and $options[$jump] -ne 'none') { return $true }
    }
    return [bool]($options['hostname'] -and $options['hostname'] -ne $Name)
}

function Find-AbkSecondVpsInSshConfig {
    <#
        SECOND VPS, каким его оставила версия до записи `second`.

        Тогда клиент туннеля писал в свой блок ~\.ssh\config три хоста: два имени
        MAIN VPS и SECOND VPS. Значит, SECOND VPS на такой машине -
        хост из этого блока, который не главный. Вариант поверх cloudflared
        клиент не писал никогда: его заводили рядом, тем же адресом и прыжком
        через MAIN VPS по туннелю.

        Не нашлось - возвращается пусто.
    #>
    param([string]$Path = '')

    $hosts = @(Read-AbkSshConfig -Path $Path)
    $main = @('audion-vps', 'audion-vps-direct')

    $found = $null
    foreach ($entry in $hosts) {
        if (-not $entry.Managed -or -not $entry.HostName) { continue }
        $isMain = $false
        foreach ($name in $entry.Names) { if ($main -contains $name) { $isMain = $true } }
        if ($isMain) { continue }
        $found = $entry
        break
    }
    if (-not $found) { return $null }

    $vps = @{
        Host      = [string]$found.HostName
        SshHost   = [string]$found.Names[0]
        SshHostCf = ''
        Key       = $(if ($found.IdentityFile) { ([string]$found.IdentityFile -split '[\\/]')[-1] } else { '' })
        User      = [string]$found.User
        Port      = [int]$found.Port
    }

    # Тот же адрес и прыжок через MAIN VPS поверх cloudflared. Таких бывает
    # несколько - тогда берётся тот, чьё имя кончается на -cf.
    $cf = New-Object System.Collections.Generic.List[hashtable]
    foreach ($entry in $hosts) {
        if ($entry.Names -contains $vps.SshHost) { continue }
        if ([string]$entry.HostName -ne $vps.Host) { continue }
        if ((([string]$entry.ProxyJump -split ',')[0]).Trim() -ne 'audion-vps') { continue }
        $cf.Add($entry)
    }
    foreach ($entry in $cf) {
        foreach ($name in $entry.Names) {
            if (-not $vps.SshHostCf -and $name -like '*-cf') { $vps.SshHostCf = $name }
        }
    }
    if (-not $vps.SshHostCf -and $cf.Count) { $vps.SshHostCf = [string]$cf[0].Names[0] }
    return $vps
}

function Get-AbkSecondVps {
    <#
        SECOND VPS этой машины: адрес, порт, имена хостов, ключ и учётная
        запись.

        Сначала запись `second` в targets.json. Нет в ней адреса и имена
        образцовые - SECOND VPS ищется в ~\.ssh\config: так выглядит машина,
        настроенная до этой записи. Отдать ей образцовые имена значило бы
        собрать транспорт на хост, которого нет нигде: мастер RCLONE.CONF
        отчитался бы «собран», а панель SECOND VPS молчала бы.

        Source говорит, откуда ответ: targets, ssh-config или default.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        # Для проверок: свой ssh config вместо пользовательского.
        [string]$SshConfig = '',
        # Папка данных, если известна; иначе - по указателю программы.
        [string]$DataRoot = ''
    )

    $vps = @{
        Host      = ''
        SshHost   = 'second-vps'
        SshHostCf = 'second-vps-cf'
        Key       = 'second_vps_ed25519'
        User      = 'root'
        Port      = 22
        Source    = 'default'
    }

    $file = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $DataRoot
    $entry = $null
    if (Test-Path -LiteralPath $file) {
        try {
            $entry = (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).second
        } catch { $entry = $null }
    }

    if ($entry) {
        $vps.Source = 'targets'
        if ([string]$entry.host) { $vps.Host = [string]$entry.host }
        elseif ([string]$entry.lan) { $vps.Host = [string]$entry.lan }
        # Порт вписывается мастером АДРЕСА. Без него поле обещало бы настройку,
        # которой нет: клиент туннеля и пробы ходили бы на 22.
        $number = 0
        if ([int]::TryParse([string]$entry.sshPort, [ref]$number) -and $number -gt 0) { $vps.Port = $number }
        foreach ($pair in @(@('sshHost', 'SshHost'), @('sshHostCf', 'SshHostCf'), @('key', 'Key'), @('user', 'User'))) {
            $value = [string]$entry.($pair[0])
            if ($value) { $vps[$pair[1]] = $value }
        }
    }

    if (-not $vps.Host -and $vps.SshHost -eq 'second-vps') {
        $old = Find-AbkSecondVpsInSshConfig -Path $SshConfig
        if ($old) {
            foreach ($field in @('Host', 'SshHost', 'SshHostCf', 'Key', 'User', 'Port')) {
                if ($old[$field]) { $vps[$field] = $old[$field] }
            }
            $vps.Source = 'ssh-config'
        }
    }
    return $vps
}

function Update-AbkSecondVpsEntry {
    <#
        Переносит SECOND VPS в targets.json, если записи `second` там нет или
        она пуста, а машина настроена прежней версией.

        Без переноса мастер АДРЕСА не показывает строку SECOND VPS, а
        сборка транспорта берёт образцовые имена. Машине без прежнего SECOND VPS
        запись заводится пустой, из образца: мастеру адресов тогда есть
        куда писать.

        Файл правится текстом, как и в мастере адресов: соседние записи, их
        порядок и пояснения остаются на месте. Получившийся текст сперва
        разбирается, и на диск ложится только разобравшийся.

        Возвращает, откуда взяты значения: ssh-config, sample или пустую строку,
        когда файл не менялся.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$SshConfig = '',
        [string]$DataRoot = ''
    )

    $live = Get-AbkWorkPath -AppRoot $AppRoot -Rel 'Tunnel\RemoteDesktop\config\targets.json' -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $live)) { return '' }
    $text = [System.IO.File]::ReadAllText($live)
    try { $entry = ($text | ConvertFrom-Json).second } catch { return '' }

    # Заполненную запись не трогаем: её вписал человек или прежний перенос.
    if ($entry -and ([string]$entry.host -or [string]$entry.lan -or
            ([string]$entry.sshHost -and [string]$entry.sshHost -ne 'second-vps'))) { return '' }

    $vps = Get-AbkSecondVps -AppRoot $AppRoot -SshConfig $SshConfig -DataRoot $DataRoot
    if ($entry -and $vps.Source -ne 'ssh-config') { return '' }

    $nl = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" })

    if (-not $entry) {
        # Запись - из образца, с описанием и пояснением. Нет образца - та же
        # запись без пояснений.
        $block = ''
        $sample = Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json'
        if (Test-Path -LiteralPath $sample) {
            $model = [System.IO.File]::ReadAllText($sample)
            $at = $model.IndexOf('"second":')
            $stop = $(if ($at -ge 0) { $model.IndexOf("`n  }", $at) } else { -1 })
            if ($stop -ge 0) {
                $start = $model.LastIndexOf("`n", $at) + 1
                $block = $model.Substring($start, $stop + 4 - $start)
            }
        }
        if (-not $block) {
            $block = @(
                '  "second": {',
                '    "desc": "SECOND VPS",',
                '    "lan": "",',
                '    "host": "",',
                '    "sshHost": "second-vps",',
                '    "sshHostCf": "second-vps-cf",',
                '    "key": "second_vps_ed25519",',
                '    "sshPort": 22,',
                '    "user": ""',
                '  }'
            ) -join "`n"
        }
        $block = ($block -replace "`r`n", "`n") -replace "`n", $nl

        # Запись встаёт следом за MAIN VPS, как в образце. Нет его -
        # последней.
        $at = $text.IndexOf('"server":')
        $stop = $(if ($at -ge 0) { $text.IndexOf("`n  }", $at) } else { -1 })
        if ($stop -lt 0) { $stop = $text.LastIndexOf("`n  }") }
        if ($stop -lt 0) { return '' }
        $after = $stop + 4
        if ($after -lt $text.Length -and $text[$after] -eq ',') {
            $text = $text.Substring(0, $after + 1) + $nl + $nl + $block + ',' + $text.Substring($after + 1)
        } else {
            $text = $text.Substring(0, $after) + ',' + $nl + $nl + $block + $text.Substring($after)
        }
    }

    $source = 'sample'
    if ($vps.Source -eq 'ssh-config') {
        $at = $text.IndexOf('"second":')
        $stop = $(if ($at -ge 0) { $text.IndexOf("`n  }", $at) } else { -1 })
        if ($stop -lt 0) { return '' }
        $part = $text.Substring($at, $stop - $at)
        $part = Set-AbkJsonFields -Text $part -Values ([ordered]@{
            host = $vps.Host; sshHost = $vps.SshHost; sshHostCf = $vps.SshHostCf; key = $vps.Key; user = $vps.User })
        if ([int]$vps.Port -gt 0 -and [int]$vps.Port -ne 22) {
            $part = [regex]::Replace($part, '"sshPort"\s*:\s*\d+', ('"sshPort": {0}' -f [int]$vps.Port))
        }
        $text = $text.Substring(0, $at) + $part + $text.Substring($stop)
        $source = 'ssh-config'
    }

    try { $check = ($text | ConvertFrom-Json).second } catch { return '' }
    if (-not $check) { return '' }
    if ($source -eq 'ssh-config' -and [string]$check.sshHost -ne $vps.SshHost) { return '' }

    [System.IO.File]::WriteAllText($live, $text, [System.Text.UTF8Encoding]::new($true))
    return $source
}

function Set-AbkJsonFields {
    <#
        Строковые поля в куске JSON-текста: значение меняется на месте, без
        пересборки. Поля, которого нет, не добавляем; пустое значение не пишем.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)]$Values
    )

    foreach ($field in @($Values.Keys)) {
        $value = [string]$Values[$field]
        if (-not $value) { continue }
        $safe = $value.Replace('\', '\\').Replace('"', '\"')
        $pattern = [regex]('"' + $field + '"\s*:\s*"[^"]*"')
        $Text = $pattern.Replace($Text, ('"{0}": "{1}"' -f $field, $safe).Replace('$', '$$'), 1)
    }
    return $Text
}

function Set-AbkSecondVpsNames {
    <#
        Имена SECOND VPS в записи `second`: хост в ssh config, он же поверх
        cloudflared и имя ключа. Правится текст записи, как и адрес; пустое
        значение не пишется. Возвращает, изменилось ли что-нибудь.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$SshHost = '',
        [string]$SshHostCf = '',
        [string]$Key = ''
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $text = [System.IO.File]::ReadAllText($Path)
    $at = $text.IndexOf('"second":')
    $stop = $(if ($at -ge 0) { $text.IndexOf("`n  }", $at) } else { -1 })
    if ($stop -lt 0) { return $false }

    $part = $text.Substring($at, $stop - $at)
    $fresh = Set-AbkJsonFields -Text $part -Values ([ordered]@{ sshHost = $SshHost; sshHostCf = $SshHostCf; key = $Key })
    if ($fresh -eq $part) { return $false }

    $text = $text.Substring(0, $at) + $fresh + $text.Substring($stop)
    try { $null = $text | ConvertFrom-Json } catch { return $false }
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($true))
    return $true
}
