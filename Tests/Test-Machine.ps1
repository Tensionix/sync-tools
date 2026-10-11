#requires -Version 5.1
<#
    Папка данных машины: всё, чем она отличается от такой же программы у
    другого человека - адреса, ключи корзины, отпечатки хостов, пароль
    роутера, план зеркала. Настройки окна - часть самой программы и в данные
    не уходят.

    Папка зовётся по машине: `Audion Backup Laptop`, `Audion Backup Work`.
    Отдельного профиля внутри нет - папка сама себе профиль. Слой
    `Machines\<имя>` был нужен, пока папка данных была одна на всех; теперь у
    каждой машины своя, и разводить внутри нечего. Вместе они лежат только
    дома, пока собираются комплекты.

    Сама программа хранит один файл - указатель, где эта папка. Имя не
    выводится из имени компьютера: на работе его не переделать, а комплект
    носят между машинами - «угаданное» имя завело бы не туда.

    Проверка идёт на песочнице: дерево строится, папка программы сносится
    целиком и разворачивается заново пустой. Это и есть распаковка новой
    сборки поверх удалённой старой.

    Ничего в проекте не трогает. Возвращает 0, когда всё сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }

Import-Module (Join-Path $AppRoot 'Engine\BackupEngine.psm1') -Force -DisableNameChecking

$failed = 0

function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

function New-File {
    param([string]$Path, [string]$Text = 'x')
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Text -Encoding UTF8
}

Write-Host ''
Write-Host '===== ПАПКА ДАННЫХ МАШИНЫ ====='

$stand = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-profile-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$app = Join-Path $stand 'Audion Sync Tools'
$mine = Join-Path $stand 'Audion Backup Laptop'
$other = Join-Path $stand 'Audion Backup Work'

try {
    # --- указатель: единственное, что программа держит у себя ---------------------
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    $empty = Get-AbkProfilePointer -AppRoot $app
    Test-Step -Title 'без указателя программа не гадает' -Ok (-not $empty.DataRoot) `
        -Note 'пустой указатель на чистой установке'

    [void](Set-AbkProfilePointer -AppRoot $app -DataRoot $mine -Profile 'Audion Backup Laptop')
    $kept = Get-AbkProfilePointer -AppRoot $app
    Test-Step -Title 'указатель читается обратно' -Ok ($kept.DataRoot -eq $mine) `
        -Note 'config\profile.json'

    # --- папка данных рядом ---------------------------------------------------------
    New-Item -ItemType Directory -Path $mine -Force | Out-Null
    Test-Step -Title 'одна папка рядом - берётся без вопросов' `
        -Ok ((Find-AbkDataRoot -AppRoot $app) -eq $mine) `
        -Note 'на машине она одна, выбирать не из чего'

    Test-Step -Title 'профиль машины - сама её папка' `
        -Ok ((Get-AbkMachineRoot -DataRoot $mine) -eq $mine) `
        -Note 'слоя внутри больше нет'

    # --- в выборе папки легко зайти на шаг глубже ------------------------------------
    # Окно выбора показывает дерево, и подпапка выглядит не хуже родителя.
    $deepOk = $true
    foreach ($deep in @(
        (Join-Path $mine 'Tunnel'),
        (Join-Path $mine 'Tunnel\SSH'),
        (Join-Path $mine 'Tunnel\SSH\clients')
    )) {
        if ((Resolve-AbkDataRoot -Path $deep) -ne $mine) { $deepOk = $false }
    }
    Test-Step -Title 'указали подпапку - взяли папку данных' -Ok $deepOk `
        -Note 'поднимаемся до имени Audion Backup*'

    # --- машина поработала ----------------------------------------------------------
    New-File (Join-Path $app 'config\gui-settings.json') '{"Theme":"dark","ClientName":"laptop"}'
    New-File (Join-Path $app 'config\rclone\rclone.conf') "[base]`ntype = sftp"
    New-File (Join-Path $app 'config\rclone\known_hosts') 'srv ssh-ed25519 AAAA'
    New-File (Join-Path $app 'config\rclone\r2.credentials') 'aws_access_key_id = test'
    New-File (Join-Path $app 'config\mirror.json') '{"sources":[]}'
    New-File (Join-Path $app 'Tunnel\RemoteDesktop\config\targets.json') '{"base":{"lan":"192.168.1.10"}}'
    New-File (Join-Path $app 'Tunnel\RemoteDesktop\config\router_192.168.1.1.secret') 'protected'
    New-File (Join-Path $app 'config\version.json') '{"version":"1.4.0"}'

    $saved = @(Save-AbkMachineState -AppRoot $app -DataRoot $mine)
    Test-Step -Title 'различия сложены в свою папку' -Ok ($saved.Count -eq 5) `
        -Note ('файлов: {0}' -f $saved.Count)

    Test-Step -Title 'пароль роутера в различия не входит' `
        -Ok (-not (Test-Path -LiteralPath (Join-Path $mine 'Tunnel\RemoteDesktop\config\router_192.168.1.1.secret'))) `
        -Note 'рабочий файл сам живёт в папке данных'

    Test-Step -Title 'версия сборки в папку данных не попала' `
        -Ok (-not (Test-Path -LiteralPath (Join-Path $mine 'config\version.json'))) `
        -Note 'приезжает с программой, у всех одна'

    Test-Step -Title 'настройки окна в папку данных не попали' `
        -Ok (-not (Test-Path -LiteralPath (Join-Path $mine 'config\gui-settings.json'))) `
        -Note 'часть программы, живут вместе с ней'

    Test-Step -Title 'легло в корень, без слоя внутри' `
        -Ok ((Test-Path -LiteralPath (Join-Path $mine 'Tunnel\RemoteDesktop\config\targets.json')) -and
             (-not (Test-Path -LiteralPath (Join-Path $mine 'Machines')))) `
        -Note 'папка данных сама себе профиль'

    # --- соседний комплект рядом не мешает -------------------------------------------
    New-File (Join-Path $other 'config\rclone\known_hosts') 'work ssh-ed25519 AAAA'
    New-File (Join-Path $other 'Tunnel\RemoteDesktop\config\targets.json') '{"base":{"lan":"192.0.2.33"}}'

    $near = @(Get-AbkProfileNames -DataRoot $mine)
    Test-Step -Title 'папки данных рядом перечисляются' -Ok ($near.Count -eq 2) `
        -Note 'дома их несколько, пока собираются папки для других машин'

    # --- распаковка новой сборки поверх удалённой старой ----------------------------
    Remove-Item -LiteralPath $app -Recurse -Force
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    New-File (Join-Path $app 'config\version.json') '{"version":"1.5.0"}'

    # Копия настроек от прежних версий, оставшаяся в данных: в программу она
    # больше не возвращается.
    New-File (Join-Path $mine 'config\gui-settings.json') '{"DataRoot":"E:\\TOOLS\\Audion Backup"}'

    # С 1.15.0 рабочие файлы живут только в папке данных: в свежую программу
    # ничего не возвращается, читают прямо из данных.
    $back = @(Restore-AbkMachineState -AppRoot $app -DataRoot $mine)
    Test-Step -Title 'в свежую программу ничего не едет' -Ok ($back.Count -eq 0) `
        -Note ('файлов: {0}; рабочие читаются из данных' -f $back.Count)

    Test-Step -Title 'рабочие файлы остались в данных' `
        -Ok ((Test-Path -LiteralPath (Join-Path $mine 'Tunnel\RemoteDesktop\config\targets.json')) -and
             -not (Test-Path -LiteralPath (Join-Path $app 'Tunnel\RemoteDesktop\config\targets.json'))) `
        -Note 'программа их не копирует'

    Test-Step -Title 'копия настроек из данных не вернулась' `
        -Ok (-not (Test-Path -LiteralPath (Join-Path $app 'config\gui-settings.json'))) `
        -Note 'настройки приезжают с программой, а не из данных'

    Test-Step -Title 'новая сборка своей версией не пожертвовала' `
        -Ok ((Get-Content -LiteralPath (Join-Path $app 'config\version.json') -Raw) -match '1\.5\.0') `
        -Note 'папка данных чужого не трогает'

    # --- остаток прежней модели переезжает в данные ------------------------------------
    New-File (Join-Path $app 'config\rclone\known_hosts') 'из программы'
    [void](Set-AbkProfilePointer -AppRoot $app -DataRoot $mine -Profile 'Audion Backup Laptop')
    Remove-Item -LiteralPath (Join-Path $mine 'config\rclone\known_hosts') -Force
    $moved = @(Restore-AbkMachineState -AppRoot $app -DataRoot $mine)
    Test-Step -Title 'остаток в программе переехал в данные' `
        -Ok (($moved.Count -eq 1) -and ($moved[0].Mode -eq 'moved') -and
             (Test-Path -LiteralPath (Join-Path $mine 'config\rclone\known_hosts')) -and
             -not (Test-Path -LiteralPath (Join-Path $app 'config\rclone\known_hosts'))) `
        -Note 'нет в данных - переносится'

    # --- в данных своё, в программе иное - карантин, не перезапись -------------------
    New-File (Join-Path $app 'config\rclone\known_hosts') 'чужое'
    $kept = @(Restore-AbkMachineState -AppRoot $app -DataRoot $mine)
    $stillMine = Get-Content -LiteralPath (Join-Path $mine 'config\rclone\known_hosts') -Raw
    $quarantined = @(Get-ChildItem -LiteralPath (Join-Path $mine '._runtime') -Directory -Filter 'migrated-*' -ErrorAction SilentlyContinue)
    Test-Step -Title 'отличное от данных уходит в карантин' `
        -Ok (($kept.Count -eq 1) -and ($kept[0].Mode -eq 'quarantined') -and ($stillMine -match 'из программы') -and
             ($quarantined.Count -ge 1) -and -not (Test-Path -LiteralPath (Join-Path $app 'config\rclone\known_hosts'))) `
        -Note '._runtime\migrated-<время>, в данных своё'

    # --- совпадающая копия просто снимается ------------------------------------------
    Copy-Item -LiteralPath (Join-Path $mine 'config\rclone\known_hosts') -Destination (Join-Path $app 'config\rclone\known_hosts') -Force
    $same = @(Restore-AbkMachineState -AppRoot $app -DataRoot $mine)
    Test-Step -Title 'совпадающая копия из программы снята' `
        -Ok (($same.Count -eq 0) -and -not (Test-Path -LiteralPath (Join-Path $app 'config\rclone\known_hosts'))) `
        -Note 'два места для одного не держим'

    # --- комплект соседа: в программу не едет, у соседа своё ---------------------------
    Remove-Item -LiteralPath $app -Recurse -Force
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    $alien = @(Restore-AbkMachineState -AppRoot $app -DataRoot $other)
    $theirs = Get-Content -LiteralPath (Join-Path $other 'Tunnel\RemoteDesktop\config\targets.json') -Raw
    Test-Step -Title 'другая машина читает свою папку, не трогая её' -Ok (($alien.Count -eq 0) -and ($theirs -match '192\.0\.2\.33')) `
        -Note 'адрес из Work остался в Work'

    # --- профиль прежних схем поднимается в корень ------------------------------------
    # Схем было две: общий слой `Machine` и именной `Machines\<имя>`. Обе держали
    # профиль внутри, и содержимое надо поднять - иначе адреса и пароль роутера
    # останутся там, куда никто больше не смотрит.
    foreach ($case in @(
        @{ Name = 'общий слой'; Rel = 'Machine\Tunnel\RemoteDesktop\config\targets.json'; Wrap = 'Machine' }
        @{ Name = 'именной слой'; Rel = 'Machines\Base\Tunnel\RemoteDesktop\config\targets.json'; Wrap = 'Machines' }
    )) {
        $legacy = Join-Path $stand ('Audion Backup Прежняя ' + $case.Wrap)
        New-File (Join-Path $legacy $case.Rel) '{"base":{"lan":"старый слой"}}'
        $moved = Move-AbkMachineLayer -MachineRoot $legacy
        $here = Join-Path $legacy 'Tunnel\RemoteDesktop\config\targets.json'
        Test-Step -Title ('{0} прежней схемы поднят в корень' -f $case.Name) `
            -Ok ($moved -and (Test-Path -LiteralPath $here)) `
            -Note ($case.Wrap + ' → корень')
        Test-Step -Title ('обёртка {0} убрана' -f $case.Wrap) `
            -Ok (-not (Test-Path -LiteralPath (Join-Path $legacy $case.Wrap))) `
            -Note 'два места для одного не держим'
    }

    # --- без папки данных программа просто идёт дальше ----------------------------------
    $bare = Join-Path $stand 'Пустая'
    New-Item -ItemType Directory -Path $bare -Force | Out-Null
    $none = @(Restore-AbkMachineState -AppRoot $bare -MachineRoot (Join-Path $stand 'нет такой папки'))
    Test-Step -Title 'без папки данных программа идёт дальше' -Ok ($none.Count -eq 0) `
        -Note 'первый запуск на новой машине'
} finally {
    Remove-Item -LiteralPath $stand -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module BackupEngine -ErrorAction SilentlyContinue
}

# --- задания планировщика переживают переезд программы ------------------------
# Задача помнит путь, по которому её завели, и переименование папки его не
# меняет. После переезда обе задачи - ночное зеркало и REVERSE SSH TUN - остались
# смотреть на прежнее имя проекта: файлов там нет, зеркало молчало сутки, и
# заметил это только аудит. Проверка читающая: ничего не заводит и не снимает.
$ghosts = @()
$looked = 0
try {
    foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        foreach ($action in @($task.Actions)) {
            $line = ('{0} {1}' -f $action.Execute, $action.Arguments)
            if ($line -notlike '*Audion*') { continue }
            foreach ($found in [regex]::Matches($line, '"([^"]+\.(?:cmd|ps1|exe))"')) {
                $looked++
                $file = $found.Groups[1].Value
                if (-not (Test-Path -LiteralPath $file)) {
                    $ghosts += ('{0} -> {1}' -f $task.TaskName, $file)
                }
            }
        }
    }
} catch {
    # Планировщик может быть недоступен - это не повод ронять проверку машины.
    $looked = -1
}
if ($looked -ge 0) {
    Test-Step -Title 'задания планировщика смотрят на существующие файлы' -Ok ($ghosts.Count -eq 0) `
        -Note $(if ($ghosts.Count) { $ghosts -join '; ' } else { ('проверено путей: {0}' -f $looked) })
} else {
    Test-Step -Title 'задания планировщика смотрят на существующие файлы' -Ok $true `
        -Note 'планировщик недоступен - пропущено'
}

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'провалено проверок: 0'
exit 0
