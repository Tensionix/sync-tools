<#
.SYNOPSIS
    Облака: завести, убрать, проверить, показать где лежат ключи.

.DESCRIPTION
    Ключ доступа к облаку - это выданная облаком строка, по которой программа
    ходит вместо человека. В общем `rclone.conf` ей не место: тот файл лежит
    открытым и ездит между машинами. Поэтому облака живут в
    своём `config\rclone\clouds.conf`, зашифрованном самим rclone, а пароль от
    него - в `clouds.key`, запечатанный средствами Windows на этого
    пользователя и эту машину.

    Вход в облако делает сам человек и делает его у облака: где есть OAuth - в
    браузере, где нет - логином и паролем в этом окне. Сценарий в разговоре не
    участвует, ему достаётся только готовый ключ доступа.

.PARAMETER Add
    Завести облако. Вид и имя спрашиваются, если не заданы ключами.

.PARAMETER Remove
    Убрать облако из списка. Файлы в самом облаке остаются нетронутыми.

.PARAMETER Key
    Заменить ключ приложения у заведённого облака: client_id и client_secret.
    Всё остальное остаётся. После замены сразу предлагается войти заново - без
    этого облако продолжит ходить со старым пропуском или без него вовсе.

.PARAMETER Reconnect
    Войти в облако заново. Настройки остаются: имя, свой ключ приложения, всё
    прочее. Меняется только токен - тот пропуск, по которому rclone ходит
    вместо человека. Нужно, когда токен отозвали, он протух или вход не
    завершился с первого раза.

.PARAMETER Rename
    Переименовать облако. Своей команды у rclone нет: запись пересоздаётся под
    новым именем со всеми полями, старая убирается. Ключ доступа тот же.

.PARAMETER To
    Новое имя для -Rename.

.PARAMETER Check
    Постучаться в каждое заведённое облако и сказать, кто отвечает.

.PARAMETER Where
    Показать, где лежат ключи и чем закрыты. Значений не показываем.

.PARAMETER Kind
    Вид облака для -Add: drive, dropbox, onedrive, yandex, pcloud, box, mega,
    protondrive.

.PARAMETER Name
    Имя облака: подпись кнопки над панелью и имя remote для rclone.

.EXAMPLE
    .\Manage-Clouds.ps1
    Показать заведённые облака.

.EXAMPLE
    .\Manage-Clouds.ps1 -Add -Kind drive -Name drive-home
    Завести Google Drive под именем drive-home.
#>
[CmdletBinding()]
param(
    [switch]$Add,
    [switch]$Remove,
    [switch]$Check,
    [switch]$Where,
    [switch]$Rename,
    [switch]$Reconnect,
    [switch]$Key,
    [string]$To = '',
    [string]$Kind = '',
    [string]$Name = '',
    # Папка данных. Стоит последней: позиционные аргументы старше.
    [string]$Root,
    # Ключ враппера из Runs: паузу держит он и читает ключ тоже он. Здесь ключ
    # только принимается, чтобы вызов с ним не падал на разборе аргументов.
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$AppRoot = Split-Path -Parent (Split-Path -Parent $Here)

. (Join-Path $AppRoot 'Engine\Clouds.ps1')
$DataRoot = Get-AbkDataRootPath -AppRoot $AppRoot -Root $Root
Import-Module (Join-Path $AppRoot 'Engine\BackupRclone.psm1') -Force

$secrets = Join-Path $AppRoot 'Engine\Secrets.ps1'
if (Test-Path -LiteralPath $secrets) { . $secrets }

function Set-PassVariable {
    <#
        Empty removes the variable. Handed straight to .NET, $null becomes '' and
        PowerShell 7 keeps an EMPTY RCLONE_CONFIG_PASS - rclone then opens the
        config without values (26.09.2026).
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { [System.Environment]::SetEnvironmentVariable('RCLONE_CONFIG_PASS', [NullString]::Value) }
    else { [System.Environment]::SetEnvironmentVariable('RCLONE_CONFIG_PASS', $Value) }
}

function Format-Size {
    <# Размер словами, как в окне: гигабайты с одним знаком, дальше терабайты. #>
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N1} ТБ' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N0} МБ' -f ($Bytes / 1MB)) }
    return "$Bytes Б"
}

function Read-AbkChoice {
    <#
        Выбор стрелками. Внешних программ не зовём: fzf есть не у всех, а
        консоль умеет всё нужное сама - перерисовать список и поймать клавишу.

        Возвращает ключ выбранного или пустую строку, если человек передумал.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Items,
        [string]$Title = ''
    )

    # Без настоящей консоли стрелок не поймать - тогда просто спрашиваем словом.
    if ([Console]::IsInputRedirected) {
        foreach ($item in $Items) { Write-Line ('{0,-14} {1}' -f $item.Key, $item.Label) }
        return (Read-Host '  наберите ключ').Trim()
    }

    $at = 0
    $top = $null
    while ($true) {
        if ($null -eq $top) { $top = [Console]::CursorTop }
        [Console]::SetCursorPosition(0, $top)
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $line = '   {0,-14} {1,-16} {2}' -f $Items[$i].Key, $Items[$i].Label, $Items[$i].Note
            if ($i -eq $at) {
                Write-Host (' > ' + $line.Substring(3).PadRight([Console]::WindowWidth - 4)) -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host ($line.PadRight([Console]::WindowWidth - 1)) -ForegroundColor Gray
            }
        }

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $at = $(if ($at -gt 0) { $at - 1 } else { $Items.Count - 1 }) }
            'DownArrow' { $at = $(if ($at -lt $Items.Count - 1) { $at + 1 } else { 0 }) }
            'Home'      { $at = 0 }
            'End'       { $at = $Items.Count - 1 }
            'Enter'     { Write-Host ''; return [string]$Items[$at].Key }
            'Escape'    { Write-Host ''; return '' }
        }
    }
}

function Send-Reference {
    <#
        Кладёт конфиг облаков на MAIN VPS эталоном - сразу после удачной правки.

        Замок DPAPI живёт ровно до переустановки Windows, а токены к машине не
        привязаны. Поэтому свежий конфиг уезжает туда, где ничего не
        переустанавливают, и делает это сам: просить об этом человека - значит
        однажды не попросить.

        Молчащий MAIN VPS не беда и не повод для тревоги: на машине всё на месте,
        отправку повторит следующая удача или clouds-push.cmd руками.
    #>
    param([string]$Why = '')

    $sync = Join-Path $Here 'Sync-CloudKeys.ps1'
    if (-not (Test-Path -LiteralPath $sync)) { return }

    Write-Host ''
    Write-Line ('golden copy на MAIN VPS: {0}' -f $Why) Gray

    $ErrorActionPreference = 'Continue'
    # Тем же PowerShell, что исполняет этот сценарий, и с той же папкой данных. Без -Root
    # выгрузка брала папку по указателю программы: правили облака в одной папке, а на
    # MAIN VPS уезжал конфиг из другой (04.10.2026 - прогон на временной папке данных
    # заменил golden copy конфигом настоящей).
    $hostExe = (Get-Process -Id $PID).Path
    $out = & $hostExe -NoProfile -ExecutionPolicy Bypass -File $sync -Push -Root $DataRoot 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($code -eq 0) {
        Write-Line 'golden copy на MAIN VPS обновлена' Green
    } else {
        Write-Line 'MAIN VPS сейчас не принял - на машине всё на месте, повторить: clouds-push.cmd' Yellow
        foreach ($line in @($out | Select-Object -Last 3)) { Write-Line ('  ' + [string]$line) Gray }
    }
}

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Protect-Files {
    <# Права на оба файла: чужим тут делать нечего. #>
    if (-not (Get-Command Protect-AbkSecret -ErrorAction SilentlyContinue)) { return }
    foreach ($path in @((Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot), (Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot))) {
        if (Test-Path -LiteralPath $path) { $null = Protect-AbkSecret -Path $path }
    }
}

function Get-Rclone {
    $exe = Find-AbkRclone -AppRoot $AppRoot
    if (-not $exe) { throw 'rclone не найден: положите его в Tools\rclone или нажмите SETUP → TOOLS → ОБНОВИТЬ' }
    return $exe
}

function Show-List {
    param([Parameter(Mandatory)][string]$RcloneExe)

    $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $RcloneExe | Where-Object { $_.Name })
    if (-not $clouds.Count) {
        Write-Line 'ни одного облака не заведено' Yellow
        return $clouds
    }
    foreach ($cloud in $clouds) {
        Write-Line ('{0,-18} {1}' -f $cloud.Name, $cloud.Type) Gray
    }
    return $clouds
}

Write-Host ''
$exe = Get-Rclone

# --- где лежат ключи -------------------------------------------------------
if ($Where) {
    Write-Host '=== КЛЮЧИ ОБЛАКОВ ===' -ForegroundColor Cyan
    Write-Host ''
    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $key = Get-AbkCloudsKeyPath -AppRoot $AppRoot -DataRoot $DataRoot
    Write-Line ('конфиг : {0}' -f $config)
    Write-Line ('пароль : {0}' -f $key)

    $sealed = Test-Path -LiteralPath $key
    $head = ''
    if (Test-Path -LiteralPath $config) {
        try { $head = Get-Content -LiteralPath $config -TotalCount 1 } catch { }
    }
    Write-Line ('конфиг зашифрован: {0}' -f $(
        if (-not (Test-Path -LiteralPath $config)) { 'файла нет' }
        elseif ($head -match 'Encrypted') { 'да' } else { 'нет' })) $(
        if ($head -match 'Encrypted') { 'Green' } else { 'Yellow' })
    Write-Line ('пароль запечатан: {0}' -f $(if ($sealed) { 'да' } else { 'файла нет' })) $(
        if ($sealed) { 'Green' } else { 'Yellow' })
    Write-Line 'запечатано на этого пользователя и эту машину: перенесённый файл не откроется'
    Write-Host ''
    exit 0
}

# --- проверка --------------------------------------------------------------
if ($Check) {
    Write-Host '=== ОБЛАКА: ПРОВЕРКА ===' -ForegroundColor Cyan
    Write-Host ''
    $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe | Where-Object { $_.Name })
    if (-not $clouds.Count) {
        Write-Line 'ни одного облака не заведено' Yellow
        Write-Host ''
        exit 0
    }

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot
    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }
        $freeAll = 0L
        $wholeAll = 0L
        foreach ($cloud in $clouds) {
            # Строгий режим тут вреден: молчащее облако - это ответ, а не сбой.
            $ErrorActionPreference = 'Continue'
            $null = & $exe --config $config lsd ('{0}:' -f $cloud.Name) --max-depth 1 --timeout 25s 2>&1
            $ok = ($LASTEXITCODE -eq 0)

            # Место спрашиваем у самого облака. Отвечают не все: где квоты нет
            # как понятия, rclone честно молчит - и мы молчим следом.
            $space = ''
            if ($ok) {
                $json = & $exe --config $config about ('{0}:' -f $cloud.Name) --json --timeout 25s 2>$null | Out-String
                if ($LASTEXITCODE -eq 0 -and $json.Trim()) {
                    try {
                        $about = $json | ConvertFrom-Json
                        if ($null -ne $about.free) {
                            $free = [long]$about.free
                            $whole = [long]$about.total
                            $freeAll += $free
                            $wholeAll += $whole
                            $space = 'свободно {0} из {1}' -f (Format-Size $free), (Format-Size $whole)
                        }
                    } catch { }
                }
            }
            $ErrorActionPreference = 'Stop'

            Write-Line ('{0,-18} {1,-12} {2,-10} {3}' -f $cloud.Name, $cloud.Type,
                $(if ($ok) { 'отвечает' } else { 'молчит' }), $space) $(if ($ok) { 'Green' } else { 'Yellow' })
        }

        if ($wholeAll) {
            Write-Host ''
            Write-Line ('итого по облакам: свободно {0} из {1}' -f (Format-Size $freeAll), (Format-Size $wholeAll)) Cyan
        }
    } finally {
        Set-PassVariable $keep
    }
    Write-Host ''
    exit 0
}

# --- заменить ключ приложения ------------------------------------------------
if ($Key) {
    Write-Host '=== ОБЛАКА: КЛЮЧ ПРИЛОЖЕНИЯ ===' -ForegroundColor Cyan
    Write-Host ''

    $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe | Where-Object { $_.Name })
    if (-not $clouds.Count) { Write-Line 'ни одного облака не заведено' Yellow; Write-Host ''; exit 0 }

    if (-not $Name) {
        Write-Line 'выбирайте стрелками, Enter - взять, Esc - передумать' Gray
        Write-Host ''
        $Name = Read-AbkChoice -Items @($clouds | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = $_.Name.ToUpper(); Note = $_.Type } })
    }
    if (-not $Name) { Write-Line 'ничего не выбрано' Yellow; Write-Host ''; exit 0 }

    Write-Host ''
    Write-Line 'вставьте client_id целиком - он кончается на .apps.googleusercontent.com'
    $newId = (Read-Host '  client_id').Trim()

    # Форму ключа проверяем сразу. Обрезанный при вставке хвост стоит часа
    # разбирательств: Google на такой ключ отвечает «клиент не найден», и
    # выглядит это как что угодно, только не потеря двух букв.
    if ($newId -and $newId -notmatch '\.apps\.googleusercontent\.com$') {
        Write-Line 'этот client_id не кончается на .apps.googleusercontent.com - похоже, при вставке потерялся хвост' Yellow
        Write-Line ('вставлено знаков: {0}, обычная длина - 72' -f $newId.Length) Yellow
        Write-Host ''
        $again = (Read-Host '  всё равно записать? (да/нет)').Trim().ToLower()
        if ($again -ne 'да' -and $again -ne 'yes' -and $again -ne 'y') {
            Write-Line 'ничего не записано' Yellow
            Write-Host ''
            exit 1
        }
    }

    Write-Line 'теперь client_secret - он начинается на GOCSPX-'
    $secure = Read-Host '  client_secret' -AsSecureString
    $newSecret = [System.Net.NetworkCredential]::new('', $secure).Password

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot
    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }
        $ErrorActionPreference = 'Continue'
        $pairs = @()
        if ($newId) { $pairs += @('client_id', $newId) }
        if ($newSecret) { $pairs += @('client_secret', $newSecret) }
        & $exe --config $config config update $Name @pairs --non-interactive | Out-Null
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    } finally {
        Set-PassVariable $keep
    }

    Protect-Files
    Write-Host ''
    if ($code -ne 0) { Write-Line 'ключ не записался' Yellow; Write-Host ''; exit 1 }
    Write-Line ('ключ приложения заменён у {0}' -f $Name) Green
    Send-Reference -Why ('заменён ключ ' + $Name)
    Write-Host ''
    Write-Line 'осталось войти заново - тем же окном: clouds-reconnect.cmd'
    Write-Host ''
    exit 0
}

# --- войти заново -----------------------------------------------------------
if ($Reconnect) {
    Write-Host '=== ОБЛАКА: ВОЙТИ ЗАНОВО ===' -ForegroundColor Cyan
    Write-Host ''

    $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe | Where-Object { $_.Name })
    if (-not $clouds.Count) { Write-Line 'ни одного облака не заведено' Yellow; Write-Host ''; exit 0 }

    if (-not $Name) {
        Write-Line 'выбирайте стрелками, Enter - взять, Esc - передумать' Gray
        Write-Host ''
        $Name = Read-AbkChoice -Items @($clouds | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = $_.Name.ToUpper(); Note = $_.Type } })
    }
    if (-not $Name) { Write-Line 'ничего не выбрано' Yellow; Write-Host ''; exit 0 }

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot

    Write-Host ''
    Write-Line 'настройки остаются, меняется только пропуск: rclone откроет браузер'
    Write-Line 'если ключ приложения заведён только что - Google признаёт его не сразу,'
    Write-Line 'от пяти минут до часа. Ошибка «invalid_client» до тех пор - это она и есть.'
    Write-Host ''
    # Дальше говорит сам rclone, и говорит по-английски: перевести его вывод
    # мы не можем, а вот сказать заранее, о чём он спросит, - вполне.
    Write-Line 'дальше спрашивает сам rclone, по-английски - на оба вопроса отвечаем y:' Gray
    Write-Line '  Token already configured - replace it?  - заменить прежний пропуск' Gray
    Write-Line '  Use web browser to automatically authenticate?  - открыть браузер для входа' Gray
    Write-Host ''

    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }
        # Строгий режим здесь вреден: rclone говорит в поток ошибок по любому
        # поводу, а вход - это разговор, а не сбой.
        $ErrorActionPreference = 'Continue'
        & $exe --config $config config reconnect ('{0}:' -f $Name)
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    } finally {
        Set-PassVariable $keep
    }

    Protect-Files
    Write-Host ''
    if ($code -eq 0) {
        Write-Line ('{0}: вход обновлён' -f $Name) Green
        Send-Reference -Why ('обновлён вход ' + $Name)
    } else {
        Write-Line ('{0}: войти не вышло' -f $Name) Yellow
    }
    Write-Host ''
    exit $code
}

# --- переименовать ----------------------------------------------------------
if ($Rename) {
    Write-Host '=== ОБЛАКА: ПЕРЕИМЕНОВАТЬ ===' -ForegroundColor Cyan
    Write-Host ''

    $clouds = @(Get-AbkCloudList -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe | Where-Object { $_.Name })
    if (-not $clouds.Count) { Write-Line 'ни одного облака не заведено' Yellow; Write-Host ''; exit 0 }

    if (-not $Name) {
        Write-Line 'выбирайте стрелками, Enter - взять, Esc - передумать' Gray
        Write-Host ''
        $Name = Read-AbkChoice -Items @($clouds | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = $_.Name.ToUpper(); Note = $_.Type } })
    }
    if (-not $Name) { Write-Line 'ничего не выбрано' Yellow; Write-Host ''; exit 0 }

    if (-not $To) {
        Write-Host ''
        $To = (Read-Host ('  новое имя для {0}' -f $Name)).Trim()
    }
    if ($To -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        Write-Line ('имя не годится: {0}' -f $To) Yellow
        Write-Host ''
        exit 1
    }

    # Новое имя проверяем в том же пространстве, что и при заведении: рядом
    # с облаками живут машины и корзины, а rclone не различает имена, которые
    # отличаются только дефисом или подчёркиванием. Своё прежнее имя занятым
    # не считаем - переименование в него же просто ничего не меняет.
    $free = Test-AbkCloudNameFree -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe -Name $To -Except $Name
    if (-not $free.Free) {
        Write-Line ('имя {0} занято: это {1}' -f $To, $free.Reason) Yellow
        Write-Line 'rclone не различил бы их, и операция ушла бы не туда,' Gray
        Write-Line 'куда показывает панель.' Gray
        Write-Host ''
        exit 1
    }

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot
    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }

        $dump = & $exe --config $config config dump 2>$null | Out-String | ConvertFrom-Json
        $entry = $dump.$Name
        if (-not $entry) { Write-Line ('такого облака нет: {0}' -f $Name) Yellow; Write-Host ''; exit 1 }
        if ($dump.$To) { Write-Line ('имя уже занято: {0}' -f $To) Yellow; Write-Host ''; exit 1 }

        # Поля переносим все, какие есть: токен, ключ приложения, настройки.
        # Тип идёт отдельным аргументом, остальное - парами.
        $pairs = @()
        foreach ($field in $entry.PSObject.Properties) {
            if ($field.Name -eq 'type') { continue }
            $pairs += $field.Name
            $pairs += [string]$field.Value
        }

        $ErrorActionPreference = 'Continue'
        & $exe --config $config config create $To ([string]$entry.type) @pairs --non-interactive | Out-Null
        $made = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
        if (-not $made) { Write-Line 'новая запись не создалась - старая на месте' Yellow; Write-Host ''; exit 1 }

        # Старую убираем только теперь, когда новая проверена по списку.
        $after = & $exe --config $config config dump 2>$null | Out-String | ConvertFrom-Json
        if (-not $after.$To) { Write-Line 'новой записи нет в конфиге - старую не трогаем' Yellow; Write-Host ''; exit 1 }

        $ErrorActionPreference = 'Continue'
        & $exe --config $config config delete $Name | Out-Null
        $stayed = ($LASTEXITCODE -ne 0)
        $ErrorActionPreference = 'Stop'
    } finally {
        Set-PassVariable $keep
    }

    Protect-Files
    if ($stayed) { Write-Line ('прежняя запись {0} не убралась - в списке остались обе' -f $Name) Yellow }
    Write-Line ('{0} теперь зовётся {1}. Ключ доступа тот же, входить заново не нужно.' -f $Name, $To) Green
    Send-Reference -Why ('переименовано в ' + $To)
    Write-Host ''
    exit 0
}

# --- убрать ----------------------------------------------------------------
if ($Remove) {
    Write-Host '=== ОБЛАКА: УБРАТЬ ===' -ForegroundColor Cyan
    Write-Host ''
    $clouds = @(Show-List -RcloneExe $exe)
    if (-not $clouds.Count) { Write-Host ''; exit 0 }

    if (-not $Name) {
        Write-Host ''
        Write-Line 'выбирайте стрелками, Enter - взять, Esc - передумать' Gray
        Write-Host ''
        $Name = Read-AbkChoice -Items @($clouds | ForEach-Object {
            [pscustomobject]@{ Key = $_.Name; Label = $_.Name.ToUpper(); Note = $_.Type } })
    }
    if (-not $Name) { Write-Line 'имя не названо - ничего не трогаем' Yellow; Write-Host ''; exit 1 }
    if (-not @($clouds | Where-Object { $_.Name -eq $Name }).Count) {
        Write-Line ('такого облака нет: {0}' -f $Name) Yellow
        Write-Host ''
        exit 1
    }

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot
    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }
        & $exe --config $config config delete $Name
        $gone = ($LASTEXITCODE -eq 0)
    } finally {
        Set-PassVariable $keep
    }
    Protect-Files
    if (-not $gone) { Write-Line ('rclone не убрал запись {0} - она на месте' -f $Name) Yellow; Write-Host ''; exit 1 }
    Write-Line ('убрано: {0}. Файлы в самом облаке остались нетронутыми.' -f $Name) Green
    Send-Reference -Why ('убрано ' + $Name)
    Write-Host ''
    exit 0
}

# --- завести ---------------------------------------------------------------
if ($Add) {
    Write-Host '=== ОБЛАКА: ЗАВЕСТИ ===' -ForegroundColor Cyan
    Write-Host ''

    $kinds = @(Get-AbkCloudKinds)
    if (-not $Kind) {
        Write-Line 'выбирайте стрелками, Enter - взять, Esc - передумать' Gray
        Write-Host ''
        $Kind = Read-AbkChoice -Items @($kinds | ForEach-Object {
            [pscustomobject]@{ Key = $_.Key; Label = $_.Label
                               Note = $(if ($_.Login -eq 'oauth') { 'вход в браузере' } else { 'логин и пароль' }) } })
        if (-not $Kind) { Write-Line 'ничего не выбрано' Yellow; Write-Host ''; exit 0 }
    }

    $chosen = @($kinds | Where-Object { $_.Key -eq $Kind })[0]
    if (-not $chosen) {
        # Не из списка - не отказ: rclone умеет вчетверо больше, и запретить
        # человеку завести своё было бы самоуправством.
        Write-Line ('вида {0} нет в коротком списке - передаём rclone как есть' -f $Kind) Yellow
    }

    if (-not $Name) {
        Write-Host ''
        $Name = (Read-Host ('  имя облака (латиницей, оно встанет подписью кнопки) [{0}]' -f $Kind)).Trim()
        if (-not $Name) { $Name = $Kind }
    }
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        Write-Line ('имя не годится: {0}. Латиница, цифры, дефис и подчёркивание.' -f $Name) Yellow
        Write-Host ''
        exit 1
    }

    # Имя облака и имя транспорта - одно пространство: rclone читает remote и из
    # конфига, и из окружения. Совпадение здесь означает, что копирование или
    # удаление уйдёт не туда, куда показывает панель, и никто об этом не скажет.
    $free = Test-AbkCloudNameFree -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe -Name $Name
    if (-not $free.Free) {
        Write-Line ('имя {0} занято: это {1}' -f $Name, $free.Reason) Yellow
        Write-Line 'rclone не различил бы их: одинаковые имена сливаются в одно,' Gray
        Write-Line 'и операция ушла бы не туда, куда показывает панель.' Gray
        Write-Host ''
        exit 1
    }

    # Свой ключ приложения. У Google Drive и Dropbox rclone по умолчанию ходит
    # общим ключом - тем же, что и все остальные его пользователи, - и упирается
    # в общую квоту: скорость проседает, а в час пик прилетает «rate limit».
    # Свой ключ заводится в консоли самого облака за несколько минут и снимает
    # это целиком. Дело добровольное: пропустил - работает и так.
    $appKey = ''
    $appSecret = ''
    if ($chosen -and $chosen.Login -eq 'oauth') {
        Write-Host ''
        Write-Line 'без своего ключа приложения rclone ходит общим - тем же, что у всех:'
        Write-Line 'квота одна на всех, скорость ниже, в час пик - отказы. Свой ключ это снимает.'
        Write-Line 'свой ключ принимают Google Drive, Dropbox, OneDrive, Яндекс.Диск, pCloud и Box;'
        Write-Line 'заводится в консоли самого облака: rclone.org/drive/#making-your-own-client-id'
        Write-Host ''
        $appKey = (Read-Host '  свой client_id (пусто - ходить общим)').Trim()
        if ($appKey) {
            # Секрет вводит человек и вводит его здесь: ни окно, ни сценарий
            # его не запоминают - он уходит прямо в конфиг rclone.
            $secure = Read-Host '  свой client_secret' -AsSecureString
            $appSecret = [System.Net.NetworkCredential]::new('', $secure).Password
        }
    }

    if (-not (Initialize-AbkClouds -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe)) {
        Write-Line 'хранилище ключей не завелось' Red
        Write-Host ''
        exit 1
    }
    Protect-Files

    $config = Get-AbkCloudsPath -AppRoot $AppRoot -DataRoot $DataRoot
    $environment = Get-AbkCloudsEnvironment -AppRoot $AppRoot -DataRoot $DataRoot

    Write-Host ''
    Write-Line 'дальше говорит rclone: он спросит нужное и, если у облака есть OAuth, откроет браузер'
    Write-Line 'логин и пароль от аккаунта видит только облако - ни сценарий, ни окно их не запоминают'
    Write-Host ''

    $keep = [System.Environment]::GetEnvironmentVariable('RCLONE_CONFIG_PASS')
    try {
        if ($environment.Count) {
            Set-PassVariable $environment.RCLONE_CONFIG_PASS
        }
        # Строгий режим здесь вреден: rclone здоровается в поток ошибок по
        # любому поводу, и окно закрывалось бы на первом же приветствии.
        $ErrorActionPreference = 'Continue'
        $extra = @()
        if ($appKey) { $extra += @('client_id', $appKey) }
        if ($appSecret) { $extra += @('client_secret', $appSecret) }
        & $exe --config $config config create $Name $Kind @extra
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
    } finally {
        Set-PassVariable $keep
    }

    Protect-Files
    Write-Host ''
    if ($code -eq 0) {
        Write-Line ('заведено: {0}. Облако появится источником над панелями.' -f $Name) Green
        Send-Reference -Why ('заведено ' + $Name)
    } else {
        Write-Line ('не заведено: {0}' -f $Name) Yellow
    }
    Write-Host ''
    exit $code
}

# --- список по умолчанию ---------------------------------------------------
Write-Host '=== ОБЛАКА ===' -ForegroundColor Cyan
Write-Host ''
$null = Show-List -RcloneExe $exe
Write-Host ''
Write-Line 'завести: clouds-add.cmd · убрать: clouds-remove.cmd · проверить: clouds-check.cmd'
Write-Host ''
exit 0
