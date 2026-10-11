<#
    Разговор с роутером на NDMS: вход и вызовы RCI.

    Роутер здоровается 401-м ответом и двумя заголовками — realm и challenge.
    Пароль в открытом виде по проводу не идёт: из него, имени и realm берётся
    MD5, к challenge приклеивается этот отпечаток, и уже от склейки берётся
    SHA-256. Роутер знает те же слагаемые и сверяет результат.

    Модуль ничего не меняет в роутере сам: он только открывает сессию и
    передаёт команды, которые дают ему сверху.
#>

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Net.Http

function ConvertTo-Hex {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-NdmDigest {
    <# Отпечаток пароля по схеме NDMS: SHA256(challenge + MD5(user:realm:pass)). #>
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Realm,
        [Parameter(Mandatory)][string]$Challenge
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $inner = ConvertTo-Hex ($md5.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes("$User`:$Realm`:$Password")))
        return ConvertTo-Hex ($sha.ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Challenge + $inner)))
    } finally {
        $md5.Dispose()
        $sha.Dispose()
    }
}

function Get-RouterSecretDir {
    <#
        Где лежат пароли роутеров: в папке данных, в Tunnel\RemoteDesktop\config.

        Пароль - секрет этой машины, а папка программы уезжает копией на соседние
        машины, поэтому рядом со сценариями ему не место. Папку данных называет
        окно или враппер ключом -Root; без него работает тот же поиск, что и у
        остальных сценариев. Прежде -Root сюда не доходил, и пароль ложился в
        папку из указателя, даже когда окно работало с другой.
    #>
    param([string]$Root = '')

    $appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $appRoot 'Engine\DataRoot.ps1')
    $dir = Join-Path (Get-AbkDataRootPath -AppRoot $appRoot -Root $Root) 'Tunnel\RemoteDesktop\config'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-RouterSecretPath {
    <#
        Файл пароля роутера в папке данных - по ИМЕНИ роутера: router-base.secret,
        router-home.secret, router-work.secret. Не по адресу: адреса роутеров
        совпадают (домашний и деревенский оба 192.168.1.1) и затирали бы друг
        друга. Разные роутеры - разные файлы, и пароли у них могут быть разными.
    #>
    param(
        [Parameter(Mandatory)][string]$Router,
        [string]$Root = ''
    )

    $safe = $Router -replace '[^A-Za-z0-9._-]', '_'
    return (Join-Path (Get-RouterSecretDir -Root $Root) ($safe + '.secret'))
}

function Save-RouterSecret {
    <#
        Кладёт пароль роутера переносимо - base64 в файл набора, как пароль
        облаков. Не DPAPI: тот привязан к учётной записи и машине, слетал при
        переустановке (а её тут раз в месяц) и не переезжал с набором. Файл сам
        по себе бесполезен: без доступа к самому роутеру им ничего не сделать.
        Замок - права папки и шифрование носителя.
    #>
    param(
        [Parameter(Mandatory)][string]$Router,
        [Parameter(Mandatory)][securestring]$Password,
        [string]$Root = ''
    )

    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($plain))
    $path = Get-RouterSecretPath -Router $Router -Root $Root
    Set-Content -LiteralPath $path -Value $b64 -Encoding ascii
    return $path
}

function Get-RouterSecret {
    <# Возвращает сохранённый пароль роутера или $null, если его не сохраняли. #>
    param(
        [Parameter(Mandatory)][string]$Router,
        [string]$Root = ''
    )

    $path = Get-RouterSecretPath -Router $Router -Root $Root
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $b64 = (Get-Content -LiteralPath $path -Raw).Trim()
        if (-not $b64) { return $null }
        $plain = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        return (ConvertTo-SecureString $plain -AsPlainText -Force)
    } catch {
        return $null
    }
}

function Test-RouterSecretStored {
    <#
        Сохранён ли пароль хоть одного роутера - для индикатора окна. Смотрит
        переносимые router-*.secret в папке данных и там, где они могли лечь у
        прежних версий. Старые router_<адрес>.secret от DPAPI-хранения тут не в
        счёт: их не прочитать переносимо, пароль вносят заново кнопкой ROUTER PASS.
    #>
    param([string]$Root = '')

    $appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $appRoot 'Engine\DataRoot.ps1')
    $places = @((Join-Path (Get-AbkDataRootPath -AppRoot $appRoot -Root $Root) 'Tunnel\RemoteDesktop\config'),
                (Join-Path $PSScriptRoot 'config'))
    foreach ($place in $places) {
        if (-not (Test-Path -LiteralPath $place)) { continue }
        if (@(Get-ChildItem -LiteralPath $place -Filter 'router-*.secret' -File -ErrorAction SilentlyContinue).Count) { return $true }
    }
    return $false
}

function Get-RouterTargetsPath {
    param([string]$Root = '')
    $appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $appRoot 'Engine\DataRoot.ps1')
    Join-Path (Get-AbkDataRootPath -AppRoot $appRoot -Root $Root) 'Tunnel\RemoteDesktop\config\targets.json'
}

function Get-RouterPasswordShared {
    <#
        Один ли пароль у всех роутеров владельца: $true, $false или $null, пока
        владелец не ответил. У кого-то пароли разные, поэтому без явного ответа
        пароль одного роутера на другом даже не пробуется. Выбор лежит в
        targets.json данных (`_routers.sharedPassword`) и переживает
        переустановку вместе с ними.
    #>
    param([string]$Root = '')
    $file = Get-RouterTargetsPath -Root $Root
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $all = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if (-not $all.PSObject.Properties['_routers']) { return $null }
    if (-not $all._routers.PSObject.Properties['sharedPassword']) { return $null }
    return [bool]$all._routers.sharedPassword
}

function Set-RouterPasswordShared {
    <# Запоминает ответ владельца. Файл правится текстом, как и адреса: без пересборки. #>
    param([Parameter(Mandatory)][bool]$Shared, [string]$Root = '')
    $file = Get-RouterTargetsPath -Root $Root
    if (-not (Test-Path -LiteralPath $file)) { throw "нет targets.json: $file" }
    $bytes = [IO.File]::ReadAllBytes($file)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($file)
    $value = $(if ($Shared) { 'true' } else { 'false' })
    $pattern = [regex]'("_routers"\s*:\s*\{[^{}]*"sharedPassword"\s*:\s*)(true|false)'
    if ($pattern.IsMatch($text)) {
        $text = $pattern.Replace($text, ('${1}' + $value), 1)
    } elseif ($text -match '"_routers"\s*:') {
        throw 'targets.json: в _routers нет sharedPassword - поправьте файл руками'
    } else {
        $newline = $(if ($text.Contains("`r`n")) { "`r`n" } else { "`n" })
        $at = $text.IndexOf('{')
        if ($at -lt 0) { throw 'targets.json: не JSON-объект' }
        $text = $text.Insert($at + 1, $newline + '  "_routers": { "sharedPassword": ' + $value + ' },')
    }
    # Сломанный файл не записываем: на нём держатся все маршруты.
    $null = $text | ConvertFrom-Json
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($bom))
}

function Get-RouterAddress {
    <#
        Адрес роутера по его имени - из записи в targets.json: lan, иначе host.
        Прежде сценарии держали 192.168.1.1 по умолчанию, а дом переехал в
        192.168.10.x: консольные запуски и ROUTER WEB стучались в пустоту.
    #>
    param(
        [Parameter(Mandatory)][string]$Router,
        [string]$Root = ''
    )

    $file = Get-RouterTargetsPath -Root $Root
    if (-not (Test-Path -LiteralPath $file)) { throw "нет targets.json: $file" }
    $all = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    $address = ''
    if ($all.PSObject.Properties[$Router]) {
        $entry = $all.$Router
        foreach ($field in 'lan', 'host') {
            if ($entry.PSObject.Properties[$field] -and $entry.$field) { $address = [string]$entry.$field; break }
        }
    }
    if (-not $address) { throw "у роутера $Router в targets.json нет адреса - впишите его кнопкой АДРЕСА" }
    return $address
}

function Connect-Router {
    <#
        Открывает сессию с роутером и возвращает её. Пароль принимается только
        закрытым (SecureString) и разворачивается на время расчёта отпечатка:
        в переменных модуля он не остаётся.
    #>
    param(
        [Parameter(Mandatory)][string]$Address,
        [string]$User = 'admin',
        [Parameter(Mandatory)][securestring]$Password
    )

    $base = if ($Address -match '^https?://') { $Address.TrimEnd('/') } else { "http://$Address" }

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.CookieContainer = [System.Net.CookieContainer]::new()
    $handler.UseCookies = $true
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(15)

    # Первый заход всегда отказ — он же и приносит realm с challenge.
    $probe = $client.GetAsync("$base/auth").GetAwaiter().GetResult()
    if ([int]$probe.StatusCode -eq 200) {
        return [pscustomobject]@{ Base = $base; Client = $client; Note = 'сессия уже была открыта' }
    }
    if ([int]$probe.StatusCode -ne 401) {
        $client.Dispose()
        throw "Роутер ответил $([int]$probe.StatusCode) — это не вход NDMS"
    }

    $realm = $null; $challenge = $null
    [void]$probe.Headers.TryGetValues('X-NDM-Realm', [ref]$realm)
    [void]$probe.Headers.TryGetValues('X-NDM-Challenge', [ref]$challenge)
    if (-not $realm -or -not $challenge) {
        $client.Dispose()
        throw 'Роутер не прислал realm и challenge — незнакомая прошивка'
    }

    $plain = [System.Net.NetworkCredential]::new('', $Password).Password
    try {
        $digest = Get-NdmDigest -User $User -Password $plain -Realm @($realm)[0] -Challenge @($challenge)[0]
    } finally {
        $plain = $null
    }

    $body = [System.Net.Http.StringContent]::new(
        (@{ login = $User; password = $digest } | ConvertTo-Json -Compress),
        [System.Text.Encoding]::UTF8, 'application/json')
    $answer = $client.PostAsync("$base/auth", $body).GetAwaiter().GetResult()

    if ([int]$answer.StatusCode -ne 200) {
        $client.Dispose()
        throw "Вход отклонён: $([int]$answer.StatusCode). Проверь имя и пароль учётной записи роутера"
    }

    return [pscustomobject]@{ Base = $base; Client = $client; Note = 'вход выполнен' }
}

function Invoke-Rci {
    <#
        Вызов RCI. Без -Body это чтение (GET), с -Body — команда (POST).
        Путь пишется как в справке роутера: 'show/version', 'interface'.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        # Пустой путь - это корень RCI: туда уходят команды, собранные из слов
        # CLI, а именованные ветки вроде show/version читаются по имени.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        $Body
    )

    $url = '{0}/rci/{1}' -f $Session.Base, $Path.TrimStart('/')

    if ($null -eq $Body) {
        $answer = $Session.Client.GetAsync($url).GetAwaiter().GetResult()
    } else {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 12 -Compress }
        $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
        $answer = $Session.Client.PostAsync($url, $content).GetAwaiter().GetResult()
    }

    $text = $answer.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ([int]$answer.StatusCode -ge 400) {
        throw "RCI $Path ответил $([int]$answer.StatusCode): $text"
    }
    if (-not $text) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $text }
}

function Disconnect-Router {
    param([Parameter(Mandatory)]$Session)
    if ($Session -and $Session.Client) { $Session.Client.Dispose() }
}

Export-ModuleMember -Function Connect-Router, Invoke-Rci, Disconnect-Router, Get-NdmDigest, `
    Save-RouterSecret, Get-RouterSecret, Get-RouterSecretPath, Test-RouterSecretStored, Get-RouterAddress, `
    Get-RouterPasswordShared, Set-RouterPasswordShared
