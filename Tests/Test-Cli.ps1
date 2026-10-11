#requires -Version 7.0
<#
    Соответствие окна и консоли.

    Правило проекта: в окне не должно происходить ничего, чего нельзя сделать
    из консоли. Кнопка зовёт враппер или сценарий - тогда правится одно место,
    а не два, и человек без окна не остаётся без действия.

    Окно - Source\ (Avalonia, C#). Тест читает его исходники текстом и сверяет
    с тем, что лежит на диске:
      - каждый сценарий и враппер, который зовёт окно, существует;
      - ключи, с которыми окно их зовёт, сценарий знает: неизвестный ключ
        роняет сценарий на привязке ещё до первой строки;
      - папка данных доходит до функций, которые её ищут;
      - обратная сторона: врапперы и сценарии, до которых из окна не
        дотянуться, перечислены поимённо с причиной - новый без кнопки и без
        причины валит тест;
      - показ и индикаторы: журнал ложится файлом, у каждой точки есть код,
        который её считает.

    До 05.10.2026 тест читал модуль прежнего окна (WPF, Engine\BackupGui.psm1)
    и держал карту его обработчиков. Ничего не запускает, кроме записи
    синтетического пароля роутера во временную папку. Возвращает 0, когда всё
    сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }

$failed = 0

function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-48} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Write-Host ''
Write-Host '===== ОКНО И КОНСОЛЬ ====='

# --- исходники окна ------------------------------------------------------------
$source = Join-Path $AppRoot 'Source'
$windowFiles = @(Get-ChildItem -LiteralPath $source -Filter '*.cs' -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' -and $_.Name -ne 'MainWindow.Dev.cs' })
$code = ($windowFiles | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
Test-Step -Title 'исходники окна на месте' -Ok ($windowFiles.Count -gt 20 -and $code.Contains('partial class MainWindow')) `
    -Note ('файлов: {0}' -f $windowFiles.Count)

# Где лежит то, что зовёт окно.
$scriptPlaces = @('Engine\Scripts', 'Engine', 'Tunnel', 'Tunnel\RemoteDesktop')
$wrapperPlaces = @('Runs', 'Tunnel', 'Tunnel\RemoteDesktop')
function Find-Door {
    param([string]$Name)
    foreach ($place in $(if ($Name -like '*.cmd') { $wrapperPlaces } else { $scriptPlaces })) {
        $path = Join-Path (Join-Path $AppRoot $place) $Name
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return ''
}

# --- всё, что зовёт окно, лежит на диске ----------------------------------------
# Инструкция C# - от точки с запятой до точки с запятой: имя сценария или
# враппера и ключи стоят в одной.
$calls = @()
foreach ($statement in ($code -split ';')) {
    $names = @([regex]::Matches($statement, '"([A-Za-z][\w-]*\.(?:ps1|cmd))"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if (-not $names.Count) { continue }
    $keys = @([regex]::Matches($statement, '"(-[A-Za-z]\w*)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # RunScript зовёт сценарий ровно с теми ключами, что даны: папку данных окно ему не дописывает.
    $plain = $statement.Contains('RunScript(')
    foreach ($name in $names) { $calls += [pscustomobject]@{ Name = $name; Keys = $keys; Alone = ($names.Count -eq 1); Plain = $plain } }
}
$called = @($calls | ForEach-Object { $_.Name } | Sort-Object -Unique)
$missing = @($called | Where-Object { -not (Find-Door -Name $_) })
Test-Step -Title 'всё, что зовёт окно, лежит на диске' -Ok ($missing.Count -eq 0 -and $called.Count -gt 30) `
    -Note $(if ($missing.Count) { 'нет на диске: ' + ($missing -join ', ') } else { 'сценариев и врапперов: {0}' -f $called.Count })

# --- окно и консоль говорят одними ключами --------------------------------------
# Ключа, которого сценарий не знает, хватает, чтобы он упал на привязке: так
# SSHD, NDMS API и ROUTER WG PEER отвечали «A parameter cannot be found that
# matches parameter name 'Root'». Сверяются ключи каждого вызова в окне, ключи,
# зашитые в самом враппере, и -Root, который окно добавляет сценариям само.
# Заодно: -Root не должен затираться в теле сценария - так SSHD получил папку
# сценария вместо папки данных и не нашёл ни одного ключа.
function Get-ScriptOf {
    <# Сценарий, который запускает враппер, и ключи, зашитые во враппере. #>
    param([string]$Wrapper)
    $body = [System.IO.File]::ReadAllText($Wrapper)
    $script = ''
    if ($body -match 'set "SCRIPT=(%~dp0[^"]*\.ps1)"') {
        $script = [System.IO.Path]::GetFullPath(($Matches[1] -replace '%~dp0', ((Split-Path -Parent $Wrapper) + '\')))
    }
    $fixed = [regex]::Match($body, '-File "%SCRIPT%"([^\r\n]*)').Groups[1].Value
    $keys = @([regex]::Matches($fixed, '(?<=\s|^)-[A-Za-z]\w*') | ForEach-Object { $_.Value })
    return [pscustomobject]@{ Script = $script; Keys = $keys }
}

function Get-KnownKeys {
    param([string]$Script)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errors)
    $known = @()
    if ($ast.ParamBlock) {
        $known = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        if ($ast.ParamBlock.Extent.Text -match 'SupportsShouldProcess' -or
            @($ast.ParamBlock.Attributes | Where-Object { $_.Extent.Text -match 'SupportsShouldProcess' }).Count) { $known += 'WhatIf', 'Confirm' }
    }
    return [pscustomobject]@{ Ast = $ast; Known = $known }
}

$mismatch = @()
$checkedCalls = 0
foreach ($call in $calls) {
    # Две двери в одной инструкции (выбор «тот враппер или этот»): чьи ключи, не разобрать.
    if (-not $call.Alone) { continue }
    $door = Find-Door -Name $call.Name
    if (-not $door) { continue }
    $script = $door
    $passed = @($call.Keys)
    if ($door -like '*.cmd') {
        $inside = Get-ScriptOf -Wrapper $door
        if (-not $inside.Script -or -not (Test-Path -LiteralPath $inside.Script)) { continue }
        $script = $inside.Script
        $passed += $inside.Keys
    }
    $checkedCalls++
    $scriptInfo = Get-KnownKeys -Script $script
    foreach ($key in @($passed | Sort-Object -Unique)) {
        if ($scriptInfo.Known -notcontains $key.TrimStart('-')) {
            $mismatch += ('{0} -> {1} не знает {2}' -f $call.Name, (Split-Path -Leaf $script), $key)
        }
    }
    if ($scriptInfo.Known -contains 'Root' -and $scriptInfo.Ast.EndBlock) {
        $overwrites = @($scriptInfo.Ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -eq 'Root' })
        if ($overwrites.Count) {
            $mismatch += ('{0}: параметр -Root затирается в теле, строка {1}' -f (Split-Path -Leaf $script), $overwrites[0].Extent.StartLineNumber)
        }
    }
}
Test-Step -Title 'окно зовёт сценарии ключами, которые те знают' -Ok ($mismatch.Count -eq 0 -and $checkedCalls -gt 30) `
    -Note $(if ($mismatch.Count) { @($mismatch | Sort-Object -Unique) -join '; ' } else { 'вызовов: {0}' -f $checkedCalls })

# Сценариям Engine\Scripts окно само дописывает -Root с папкой данных (Core\Scripts.cs):
# сценарий, который зовут кнопкой, обязан этот ключ знать.
$rootless = @()
foreach ($name in $called | Where-Object { $_ -like '*.ps1' }) {
    $path = Join-Path $AppRoot ('Engine\Scripts\' + $name)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (-not @($calls | Where-Object { $_.Name -eq $name -and -not $_.Plain }).Count) { continue }
    if ((Get-KnownKeys -Script $path).Known -notcontains 'Root') { $rootless += $name }
}
Test-Step -Title 'сценарии кнопок принимают папку данных' -Ok ($rootless.Count -eq 0) `
    -Note $(if ($rootless.Count) { 'без -Root: ' + ($rootless -join ', ') } else { '' })

# --- папка данных доходит до функций, которые её ищут ------------------------------
# Того, что параметр -Root есть, мало: Check-Router.ps1 и New-RouterPeer.ps1
# приняли -Root, а пароль роутера всё равно ложился в папку из указателя -
# функции модуля его не получали. Каждый вызов функции, которая ищет папку
# данных, обязан передать -Root в сценариях, объявивших этот параметр. Вызов
# внутри `if (-not $Root)` законен - ключа тогда нет.
$rootAware = @('Get-AbkDataRootPath', 'Get-RouterSecretDir', 'Get-RouterSecretPath', 'Save-RouterSecret', 'Get-RouterSecret', 'Test-RouterSecretStored')
$lostRoot = @()
$rootChecked = 0
$rootFiles = @(Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Tunnel') -Filter '*.ps1' -File -Recurse) +
             @(Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Engine\Scripts') -Filter '*.ps1' -File)
foreach ($file in $rootFiles) {
    $fileTokens = $null
    $fileErrors = $null
    $fileAst = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$fileTokens, [ref]$fileErrors)
    if (-not $fileAst.ParamBlock) { continue }
    if (-not @($fileAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Root' }).Count) { continue }
    $found = @($fileAst.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $rootAware -contains $n.GetCommandName() }, $true))
    foreach ($one in $found) {
        $rootChecked++
        if (@($one.CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Root' }).Count) { continue }
        $guard = $one.Parent
        $guarded = $false
        while ($guard) {
            if ($guard -is [System.Management.Automation.Language.IfStatementAst] -and
                $guard.Clauses[0].Item1.Extent.Text -match '-not\s+\$Root') { $guarded = $true; break }
            $guard = $guard.Parent
        }
        if (-not $guarded) { $lostRoot += ('{0}:{1} {2}' -f $file.Name, $one.Extent.StartLineNumber, $one.GetCommandName()) }
    }
}
Test-Step -Title 'папка данных доходит до функций, которые её ищут' -Ok ($lostRoot.Count -eq 0 -and $rootChecked -gt 5) `
    -Note $(if ($lostRoot.Count) { $lostRoot -join '; ' } else { 'вызовов: {0}' -f $rootChecked })

# Делом: синтетический пароль ложится в папку, названную -Root, а не в папку из
# указателя, и индикатор его видит.
$routerLab = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-router-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$chosenRoot = Join-Path $routerLab 'Data B selected'
New-Item -ItemType Directory -Path $chosenRoot -Force | Out-Null
try {
    Import-Module (Join-Path $AppRoot 'Tunnel\RemoteDesktop\RouterNdm.psm1') -Force -DisableNameChecking
    $synthetic = ConvertTo-SecureString 'synthetic-not-a-password' -AsPlainText -Force
    $kept = Save-RouterSecret -Router 'router-base' -Password $synthetic -Root $chosenRoot
    $resolvedRoot = (Resolve-Path -LiteralPath $chosenRoot).Path
    $inChosen = ([string]$kept).StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $seen = [bool](Test-RouterSecretStored -Root $chosenRoot)
    $back = [bool](Get-RouterSecret -Router 'router-base' -Root $chosenRoot)
    Test-Step -Title 'пароль роутера ложится в папку из -Root' -Ok ($inChosen -and $seen -and $back) `
        -Note $(if ($inChosen) { 'индикатор: {0}, читается: {1}' -f $seen, $back } else { 'лёг в: ' + $kept })
} finally {
    Remove-Module RouterNdm -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $routerLab -Recurse -Force -ErrorAction SilentlyContinue
}

# Нажитое в окне - наборы масок и пары BISYNC - лежит в папке данных, а не в настройках окна:
# настройки уходят с чисткой программы, а указать папку данных должно быть всей настройкой.
# Состояние пары rclone держит там же, по папке на пару: список без состояния - это отказ
# «must run --resync», после которого окно не умело спросить заново.
$storeCode = [System.IO.File]::ReadAllText((Join-Path $source 'Core\DataStore.cs'))
$settingsCode = [System.IO.File]::ReadAllText((Join-Path $source 'Core\Settings.cs'))
$opsCode = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.Ops.cs'))
$masksCode = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.Masks.cs'))
$keptOnlyToRead = @([regex]::Matches($settingsCode, 'WhenWritingNull\)\]\s+public List<(?:string|MaskSet)>\? (BisyncPairs|MaskSets)')).Count
Test-Step -Title 'наборы масок и пары BISYNC лежат в папке данных' `
    -Ok ($storeCode.Contains('"mask-sets.json"') -and $storeCode.Contains('"bisync"') -and $storeCode.Contains('DataRoot.Path_') -and
         $opsCode.Contains('"--workdir", DataStore.PairState(') -and $opsCode.Contains('DataStore.PairKnown(') -and
         $masksCode.Contains('DataStore.SaveMaskSets(') -and -not $masksCode.Contains('_settings.MaskSets') -and
         $keptOnlyToRead -eq 2) `
    -Note 'config\mask-sets.json, config\bisync; в настройках окна оба ключа только читаются'

# --- обратная сторона: до чего из окна не дотянуться ---------------------------
# Консольные двери, которым кнопка не нужна: терминал и файлы открываются
# кнопками машин, а рабочий стол ноутбука - только руками: снаружи к ноутбуку не ходят.
$byHand = @('connect-base.cmd', 'connect-base-lan.cmd', 'connect-laptop.cmd', 'connect-laptop-lan.cmd',
    'files-base.cmd', 'files-home.cmd', 'files-laptop.cmd', 'files-router.cmd', 'desktop-laptop.cmd')
$orphans = @()
$checked = 0
foreach ($file in Get-ChildItem -LiteralPath $AppRoot -Filter '*.cmd' -Recurse -File) {
    # Путь только относительный. Полный путь сравнивался с маской «*\Tools\*»,
    # а проект лежит в E:\TOOLS - и без учёта регистра отсеивались все
    # врапперы разом: строка горела зелёным, не проверив ни одного.
    $rel = $file.FullName.Substring($AppRoot.TrimEnd('\').Length + 1)
    if ($rel -like 'Tools\*' -or $rel -like '._runtime\*' -or $rel -like '.git\*' -or $rel -like 'App\*' -or $rel -like 'Source\*') { continue }
    if ($byHand -contains $file.Name) { continue }
    # Сборочный цикл зовёт не окно, а Audion Build Orchestrator и человек руками.
    if ($rel -in @('builder_main.cmd', 'cleanup_project.cmd')) { continue }
    $checked++
    if ($code.Contains('"' + $file.Name + '"')) { continue }

    # Окно зовёт сценарии и напрямую, и тогда враппер остаётся консольной парой
    # той же кнопки. Сверка идёт по имени сценария; ключи действий она не различает.
    $inside = Get-ScriptOf -Wrapper $file.FullName
    if ($inside.Script -and $code.Contains('"' + (Split-Path -Leaf $inside.Script) + '"')) { continue }
    $orphans += $file.Name
}
Test-Step -Title 'у каждого враппера есть кнопка' -Ok ($orphans.Count -eq 0 -and $checked -gt 30) `
    -Note $(if ($orphans.Count) { 'без кнопки: ' + ($orphans -join ', ') } else { 'врапперов: {0}' -f $checked })

# Сценарии, которых кнопка не зовёт напрямую, но дверь у них есть.
$scriptDoors = $code
# Сценарии без кнопки по замыслу: сейчас таких нет. Появится - сюда, с причиной в комментарии.
$byBuild = @()
# RESTORE - намеренная цепочка: враппер -> сценарий восстановления -> проверка маршрутов.
$restoreWrapper = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Tunnel\RemoteDesktop\restore-machine.cmd'))
$restoreCode = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Restore-Machine.ps1'))
$restoreLinked = $code.Contains('"restore-machine.cmd"') -and $restoreWrapper.Contains('Restore-Machine.ps1')
Test-Step -Title 'RESTORE связывает окно, консоль и проверку SSH/SFTP' -Ok ($restoreLinked -and $restoreCode.Contains('Test-RestoredRoutes.ps1'))
if ($restoreLinked) { $scriptDoors += $restoreWrapper + $restoreCode }
# ОБНОВИТЬ зовёт Update-Tools.ps1, а тот - Install-Tools.ps1 за архиватором и
# редакторами: своей кнопки у установщика нет, его дверь - сценарий обновления.
if ($code.Contains('"Update-Tools.ps1"')) { $scriptDoors += [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Update-Tools.ps1')) }
# Сценарии, которые зовёт враппер, чья кнопка в окне есть.
foreach ($name in $called | Where-Object { $_ -like '*.cmd' }) {
    $door = Find-Door -Name $name
    if ($door) { $scriptDoors += [System.IO.File]::ReadAllText($door) }
}
$lonely = @()
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $AppRoot 'Engine\Scripts') -Filter '*.ps1' -File) {
    if ($byBuild -contains $file.Name) { continue }
    if (-not $scriptDoors.Contains($file.Name)) { $lonely += $file.Name }
}
Test-Step -Title 'у каждого сценария есть кнопка' -Ok ($lonely.Count -eq 0) `
    -Note $(if ($lonely.Count) { 'без кнопки: ' + ($lonely -join ', ') } else { '' })

# --- показ: журнал, проба, состояние ------------------------------------------
# Всё, что окно показывает, человек должен получать и без окна. На рабочей
# машине однажды вскрылось: папка logs пуста, прислать нечего, разбирать нечем.
$journal = [System.IO.File]::ReadAllText((Join-Path $source 'Core\Journal.cs'))
Test-Step -Title 'журнал окна ложится файлом' `
    -Ok ($journal.Contains('File.AppendAllText(LogFile') -and $journal -match 'gui-\{DateTime\.Now:yyyyMMdd\}\.log') `
    -Note 'logs\gui-ГГГГММДД.log, строка со временем'
Test-Step -Title 'проба повторима из консоли' `
    -Ok (Test-Path -LiteralPath (Join-Path $AppRoot 'Tunnel\RemoteDesktop\check-routes.cmd')) `
    -Note 'check-routes.cmd - те же маршруты, отчётом в logs\routes-*.log'
Test-Step -Title 'состояние зеркала повторимо из консоли' `
    -Ok (Test-Path -LiteralPath (Join-Path $AppRoot 'Runs\sync-backup.cmd')) `
    -Note 'sync-backup.cmd -WhatIf'
Test-Step -Title 'состояние ключей повторимо из консоли' `
    -Ok ((Test-Path -LiteralPath (Join-Path $AppRoot 'Runs\export-keys.cmd')) -and
         (Test-Path -LiteralPath (Join-Path $AppRoot 'Runs\import-keys.cmd'))) `
    -Note 'export-keys.cmd -Check, import-keys.cmd -Check'
Test-Step -Title 'состояние точек повторимо из консоли' `
    -Ok ((Test-Path -LiteralPath (Join-Path $AppRoot 'Engine\Scripts\Get-SetupState.ps1')) -and
         (Test-Path -LiteralPath (Join-Path $AppRoot 'Engine\Scripts\Get-BeaconState.ps1'))) `
    -Note 'Get-SetupState.ps1, Get-BeaconState.ps1 - одной строкой JSON'
Test-Step -Title 'сводка состояния повторима из консоли' `
    -Ok (Test-Path -LiteralPath (Join-Path $AppRoot 'Engine\Scripts\Get-StateSummary.ps1')) `
    -Note 'Get-StateSummary.ps1 - одной строкой JSON; окно пишет её в журнал'

# --- индикаторы ---------------------------------------------------------------
# Точка - главный способ соврать человеку. Она обязана быть посчитана в коде, а
# не лежать у кнопки серой навсегда; и она обязана показывать ответ, а не факт
# нажатия.
$bars = Get-Content -LiteralPath (Join-Path $source 'config\bars.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$dots = @()
foreach ($bar in $bars.Values) { foreach ($group in $bar) { foreach ($item in $group.items) { if ($item.dot) { $dots += [string]$item.dot } } } }
$dots = @($dots | Sort-Object -Unique)
$stateCode = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.State.cs'))
$dead = @($dots | Where-Object { -not $stateCode.Contains('"' + $_ + '"') })
Test-Step -Title 'каждый индикатор считается в коде' -Ok ($dead.Count -eq 0 -and $dots.Count -gt 10) `
    -Note $(if ($dead.Count) { 'ничем не заполнены: ' + ($dead -join ', ') } else { 'индикаторов: {0}' -f $dots.Count })

# Три состояния: серое - этого нет, оранжевое - есть, зелёное - доказано делом.
Test-Step -Title 'у точек настройки три состояния' `
    -Ok ($stateCode.Contains('_proven.ContainsKey(proof)') -and $stateCode.Contains('"warn"') -and $stateCode.Contains('"idle"')) `
    -Note 'зелёное только по подтверждению делом'

# Точка и кнопка отвечают на разные вопросы, и смешивать их нельзя: точка -
# отработал ли мастер, кнопка - поднят ли туннель сейчас. Пока точка мерила
# пинг до роутера, она горела зелёным при опущенном туннеле: дома роутер
# отвечает и без туннеля.
$setupState = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Get-SetupState.ps1'))
Test-Step -Title 'индикатор показывает установку, а не связь' `
    -Ok ($setupState.Contains('installed = $installed') -and $stateCode.Contains('Flag(vpn, "installed")')) `
    -Note 'зелёная - служба заведена, оранжевая - есть только конфиг'

$engine = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\BackupEngine.psm1'))
Test-Step -Title 'кнопка показывает питание, а не установку' `
    -Ok ($engine -match 'function Get-AbkTunnelPower' -and $engine -match 'Get-NetAdapter -Name \$name' -and $stateCode.Contains('PaintPower(')) `
    -Note 'считается по интерфейсу: служба может идти при выключенном адаптере'

# Точка канала не должна знать имя машины наизусть: канал заводят разные
# машины, и каждая видит свой - под тем же именем, что берёт Setup-SshBeacon.ps1.
$beaconState = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Get-BeaconState.ps1'))
Test-Step -Title 'индикатор REVERSE SSH TUN не зашит на одно имя' `
    -Ok ($beaconState.Contains('Get-AbkLocalBeaconName -DataRoot $data')) `
    -Note 'имя берётся из выбранной DATA, затем у Windows'

# Сплит-туннелинг: что идёт в туннель, задаётся списком сетей. Окно и скрипт
# обязаны говорить об одном файле - иначе правка кнопкой никуда не доедет.
$vpn = Get-Content (Join-Path $AppRoot 'Tunnel\RemoteDesktop\Setup-BaseVpn.ps1') -Raw -Encoding UTF8
Test-Step -Title 'сети туннеля правятся кнопкой, а не файлом' `
    -Ok ($code.Contains('"routes.txt"') -and $vpn -match 'routes\.txt') `
    -Note 'окно пишет routes.txt, скрипт его читает'

Test-Step -Title 'скрипт не держит сети в себе' `
    -Ok ($vpn -match '\$DefaultNets' -and $vpn -notmatch '\$HomeNets = @\(''192') `
    -Note 'жёсткий список остался только умолчанием'

# Питание и установка - разные кнопки. Мастер ставит и сносит туннель насовсем,
# кнопка питания только поднимает и опускает службу. Смешивать их нельзя: снять
# туннель ради того, чтобы он не мешал сети, значит потом заводить его заново.
$power = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Switch-Tunnel.ps1'))
Test-Step -Title 'питание туннеля отделено от установки' `
    -Ok ($power.Contains('Switch-AbkTunnel -Service') -and $power -notmatch 'uninstalltunnelservice|-Remove') `
    -Note 'мастер ставит и сносит, кнопка включает и выключает'

# Права поднимаются один раз, при старте: программа административная. Без них
# не работает ничего сетевого - ни служба туннеля, ни состояние интерфейса, ни
# рукопожатия. Выпрашивать их по кусочкам, в момент нажатия, было хуже всего.
$boot = [System.IO.File]::ReadAllText((Join-Path $source 'Program.cs'))
Test-Step -Title 'права поднимаются при старте' `
    -Ok ($boot.Contains('WindowsBuiltInRole.Administrator') -and $boot.Contains('Verb = "runas"')) `
    -Note 'программа административная, как и остальные инструменты'

Test-Step -Title 'отказ в правах не роняет программу' `
    -Ok ($boot.Contains('"--no-admin"') -and $boot.Contains('catch (Win32Exception)')) `
    -Note 'без прав не работают туннели, остальное работает'

Test-Step -Title 'окно не выпрашивает права по кусочкам' `
    -Ok (@([regex]::Matches($code, 'Verb = "runas"')).Count -eq 1) `
    -Note 'один запрос - в Program.cs, при старте'

Test-Step -Title 'рукопожатия берутся у самого WireGuard' `
    -Ok ($engine -match 'function Get-AbkHandshakes' -and $engine -match 'latest-handshakes') `
    -Note 'wg show all latest-handshakes — доступно только администратору'

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
