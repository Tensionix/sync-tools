#requires -Version 7.0
<#
    Окно (Source\, Avalonia) без его запуска.

    Имена элементов разметки сверяет компилятор: опечатка в x:Name не
    собирается. Не сверяет он данные - ряды кнопок живут в
    Source\config\bars.json, подписи - в Source\config\i18n.json, а действия -
    в коде, по имени кнопки. Эти три места расходятся молча: кнопка без
    действия пишет в журнал «действие не найдено», подпись без пары остаётся
    русской в английском окне.

    Проверяется:
      - bars.json разбирается, имена кнопок не повторяются;
      - у каждой кнопки есть действие в MainWindow*.cs;
      - у каждой русской подписи, подсказки и заголовка в bars.json и в
        разметке окна есть английская пара в i18n.json;
      - то же у русских текстов в коде окна: строка, которую окно пишет в
        журнал или в диалог, без пары осталась бы русской в английском окне;
      - ошибка, которую никто не поймал, окно не закрывает: сторож подключён;
      - то, что прежнее окно делало само и что аудит переезда 06.10.2026 нашёл
        потерянным, стоит на месте: маршруты читаются из открытого конфига,
        закрытие окна спрашивает и останавливает передачу, копия между двумя
        облаками одного вида идёт на стороне облака, папка данных меняется
        одним шагом вместе со своей облачной сессией и панелями, -Root в
        командной строке окна называет папку данных, номер версии один;
      - окно первого запуска отдаёт ответ, когда его уже нет среди окон
        программы: иначе выбранную в нём папку данных окно отклоняет;
      - действие, которое ждёт подсчёта или ответа, держит папку данных
        (Pending) и идёт по адресу, взятому до вопроса, а не туда, где панель
        оказалась после него; у каждого метода с await либо то, либо причина
        в списке этой проверки.

    Ничего не запускает и не меняет. Возвращает 0, когда всё сходится.
#>
[CmdletBinding()]
param(
    [string]$AppRoot = ''
)

$ErrorActionPreference = 'Stop'
if (-not $AppRoot) { $AppRoot = Split-Path -Parent $PSScriptRoot }
$source = Join-Path $AppRoot 'Source'

$failed = 0
function Test-Step {
    param([string]$Title, [bool]$Ok, [string]$Note = '')
    $mark = $(if ($Ok) { 'ок  ' } else { 'СБОЙ' })
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Write-Host ''
Write-Host '===== ОКНО ====='

# --- ряды кнопок ---------------------------------------------------------------
$bars = $null
try { $bars = Get-Content -LiteralPath (Join-Path $source 'config\bars.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { }
Test-Step -Title 'bars.json разбирается' -Ok ($null -ne $bars)
if ($null -eq $bars) { Write-Host 'провалено проверок: 1'; exit 1 }

$buttons = New-Object System.Collections.Generic.List[string]
$texts = New-Object System.Collections.Generic.List[string]
foreach ($bar in $bars.Keys) {
    foreach ($group in $bars[$bar]) {
        if ($group.title) { $texts.Add([string]$group.title) }
        foreach ($item in $group.items) {
            # Без имени - не кнопка, а место под ряд машин (TerminalHosts, RouterHosts): его строит код.
            if (-not $item.name) { continue }
            $buttons.Add([string]$item.name)
            foreach ($field in 'text', 'hint', 'tip') { if ($item[$field]) { $texts.Add([string]$item[$field]) } }
        }
    }
}
$twice = @($buttons | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Test-Step -Title 'имена кнопок не повторяются' -Ok ($twice.Count -eq 0 -and $buttons.Count -gt 0) `
    -Note $(if ($twice.Count) { 'дважды: ' + ($twice -join ', ') } else { 'кнопок: {0}' -f $buttons.Count })

# --- действия ------------------------------------------------------------------
$code = ''
foreach ($file in Get-ChildItem -LiteralPath $source -Filter 'MainWindow*.cs' -File) { $code += [System.IO.File]::ReadAllText($file.FullName) }
# Действие - ветка `case "Имя":` (одна ветка бывает на две кнопки: `case "A" or "B":`). Простое
# упоминание имени действием не считается: кнопку могут звать из другого места, а ветки у неё нет.
$without = @($buttons | Where-Object { $code -notmatch ('case [^:\r\n]*"' + [regex]::Escape($_) + '"[^:\r\n]*:') })
Test-Step -Title 'у каждой кнопки есть действие' -Ok ($without.Count -eq 0) `
    -Note $(if ($without.Count) { 'без действия: ' + ($without -join ', ') } else { 'кнопок с действием: {0}' -f $buttons.Count })

# --- переводы ------------------------------------------------------------------
$table = Get-Content -LiteralPath (Join-Path $source 'config\i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
function Test-Pair([string]$Text) { $table.ContainsKey($Text) -and $table[$Text].en }

$lonely = @($texts | Where-Object { $_ -match '[А-Яа-яЁё]' -and -not (Test-Pair $_) } | Select-Object -Unique)
Test-Step -Title 'подписи рядов кнопок переведены' -Ok ($lonely.Count -eq 0) `
    -Note $(if ($lonely.Count) { 'без пары: ' + (($lonely | ForEach-Object { $_.Substring(0, [Math]::Min(40, $_.Length)) }) -join ' | ') } else { 'строк: {0}' -f $texts.Count })

# Разметка: всё, что стоит в атрибутах русским текстом, окно показывает человеку.
$markup = @(Get-ChildItem -LiteralPath $source -Filter '*.axaml' -File) + @(Get-ChildItem -LiteralPath (Join-Path $source 'Views') -Filter '*.axaml' -File)
$shown = 0
$bare = New-Object System.Collections.Generic.List[string]
foreach ($file in $markup) {
    if ($file.Name -eq 'App.axaml') { continue }
    $xml = [xml][System.IO.File]::ReadAllText($file.FullName)
    foreach ($node in $xml.SelectNodes('//*')) {
        foreach ($attribute in $node.Attributes) {
            if ($attribute.Value -notmatch '[А-Яа-яЁё]') { continue }
            $shown++
            if (-not (Test-Pair $attribute.Value)) { $bare.Add(('{0}: {1}' -f $file.Name, $attribute.Value.Substring(0, [Math]::Min(40, $attribute.Value.Length)))) }
        }
    }
}
Test-Step -Title 'подписи и подсказки разметки переведены' -Ok ($bare.Count -eq 0 -and $shown -gt 0) `
    -Note $(if ($bare.Count) { 'без пары: ' + ($bare -join ' | ') } else { 'строк: {0}' -f $shown })

# Код окна. Русская строка в кавычках - ключ пары: её переводит Lang.T, Lang.F или сам журнал.
# Строка без пары молчит до первой ошибки в английском окне: так шесть сообщений корзины Windows
# и архиватора остались русскими, пока их не нашли перебором. Собранные из кусков ($"...") ключом
# быть не могут и сюда не попадают - их части проверяются как отдельные строки.
$notShown = @(
    # Образец самой широкой строки, по которому меряется колонка размера: на экран не выводится.
    '0 000,0 МБ',
    # Имя-заполнитель в шаблоне пути SFX: его набирает человек, а не показывает окно.
    '<имя>',
    # Метка, по которой журнал узнаёт строки самого окна и красит их приглушённо.
    '[окно]'
)
$scanned = 0
$dumb = New-Object System.Collections.Generic.List[string]
$files = @(Get-ChildItem -LiteralPath $source -Filter '*.cs' -File) +
         @(Get-ChildItem -LiteralPath (Join-Path $source 'Core') -Filter '*.cs' -File) +
         @(Get-ChildItem -LiteralPath (Join-Path $source 'Views') -Filter '*.cs' -File)
# Строка или комментарий - что начнётся раньше: «//» внутри адреса в кавычках комментарием не считается.
$token = [regex]'(?s)(?<text>"(?:[^"\\\r\n]|\\.)*")|(?<note>//[^\r\n]*|/\*.*?\*/)'
foreach ($file in $files) {
    # Шаги проверки без мыши живут только в отладочной сборке, а единицы размера Format.cs выбирает по языку сам.
    if ($file.Name -in 'MainWindow.Dev.cs', 'Format.cs') { continue }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($m in $token.Matches($text)) {
        if (-not $m.Groups['text'].Success) { continue }
        $raw = $m.Value.Substring(1, $m.Value.Length - 2)
        if ($raw -notmatch '[А-Яа-яЁё]') { continue }
        # $"..." и @"..." - не ключи: первая собирается на ходу, вторая пишется в файл как есть.
        if ($m.Index -gt 0 -and $text[$m.Index - 1] -in '$', '@') { continue }
        # Выражение для разбора строк журнала - не текст для человека.
        $lineStart = $text.LastIndexOf("`n", $m.Index) + 1
        $lineEnd = $text.IndexOf("`n", $m.Index); if ($lineEnd -lt 0) { $lineEnd = $text.Length }
        if ($text.Substring($lineStart, $lineEnd - $lineStart) -match 'Regex') { continue }
        $key = $raw.Replace('\\', [string][char]1).Replace('\n', "`n").Replace('\t', "`t").Replace('\"', '"').Replace([string][char]1, '\')
        # Строка файла настроек, которую окно пишет на диск (заголовок routes.txt), а не показывает.
        if ($key.StartsWith('# ')) { continue }
        if ($notShown -contains $key) { continue }
        $scanned++
        if (-not (Test-Pair $key)) { $dumb.Add(('{0}: {1}' -f $file.Name, $key.Substring(0, [Math]::Min(50, $key.Length)).Replace("`n", ' / '))) }
    }
}
Test-Step -Title 'русские тексты кода окна переведены' -Ok ($dumb.Count -eq 0 -and $scanned -gt 500) `
    -Note $(if ($dumb.Count) { 'без пары: ' + (($dumb | Select-Object -Unique) -join ' | ') } else { 'строк: {0}' -f $scanned })

# --- сторож --------------------------------------------------------------------
# Ошибка в обработчике кнопки, которую никто не поймал, закрывает программу без единого слова.
# Сторож пишет её целиком в logs\gui-crash-<время>.log, оставляет строку в журнале и окно не роняет.
$guard = [System.IO.File]::ReadAllText((Join-Path $source 'Core\CrashGuard.cs'))
$app = [System.IO.File]::ReadAllText((Join-Path $source 'App.axaml.cs'))
Test-Step -Title 'сторож ошибок подключён до окна' `
    -Ok ($app.IndexOf('CrashGuard.Install()') -gt 0 -and $app.IndexOf('CrashGuard.Install()') -lt $app.IndexOf('new MainWindow(')) `
    -Note 'App.axaml.cs: CrashGuard.Install() раньше new MainWindow'
Test-Step -Title 'сторож пишет файл и держит окно' `
    -Ok ($guard.Contains('UIThread.UnhandledException') -and $guard.Contains('e.Handled = true') -and $guard.Contains('gui-crash-') -and
         $guard.Contains('UnobservedTaskException') -and $guard.Contains('CurrentDomain.UnhandledException')) `
    -Note 'logs\gui-crash-<время>.log, строка в журнале'

# --- переезд с прежнего окна ---------------------------------------------------
# Прежнее окно делало это само, без единой кнопки, - и при переносе на Avalonia оно потерялось
# молча: ни компилятор, ни проверка дверей такого не видят. Нашёл аудит переезда 06.10.2026
# (AST-M01 ... AST-M06); поведение проверено на стенде, а здесь закреплено место в коде.
function Read-Source { param([string]$Rel) [System.IO.File]::ReadAllText((Join-Path $source $Rel)) }
function Get-Body {
    # Текст от заголовка до заголовка следующего члена класса: «в этом методе есть».
    param([string]$Text, [string]$Head)
    $from = $Text.IndexOf($Head)
    if ($from -lt 0) { return '' }
    $next = [regex]::Match($Text.Substring($from + $Head.Length), '(?m)^    (?:/// <summary>|#if |#else|#endif)')
    return $(if ($next.Success) { $Text.Substring($from, $Head.Length + $next.Index) } else { $Text.Substring($from) })
}
$rclone = Read-Source 'Core\Rclone.cs'
$jobs = Read-Source 'Core\Jobs.cs'
$dataRoot = Read-Source 'Core\DataRoot.cs'
$program = Read-Source 'Program.cs'
$window = Read-Source 'MainWindow.axaml.cs'
$actions = Read-Source 'MainWindow.Actions.cs'
$cloudsCode = Read-Source 'MainWindow.Clouds.cs'
$ops = Read-Source 'MainWindow.Ops.cs'

# Сессия облаков зашифрована: прочитанная как текст, она не показывает ни одного маршрута.
$transports = Get-Body $rclone 'public static Dictionary<string, Dictionary<string, string>> Transports()'
Test-Step -Title 'маршруты читаются из открытого конфига' `
    -Ok ($transports.Contains('var path = TransportPath;') -and -not $transports.Contains('ConfigPath') -and
         $rclone -match 'TransportPath => DataRoot\.File_\(' -and $rclone.Contains('ConfigPath => SessionConfig ?? TransportPath;')) `
    -Note 'Rclone.Transports() - TransportPath, не файл сессии'

# Передача не переживает окно: брошенный rclone льёт файлы дальше, и видеть это уже нечем.
$closing = Get-Body $window 'void OnClosing(object? sender, WindowClosingEventArgs e)'
$stopForClose = Get-Body $jobs 'public void StopForClose()'
$stop = Get-Body $jobs 'public void Stop()'
Test-Step -Title 'закрытие окна спрашивает о передаче' `
    -Ok ($closing.Contains('_jobs.Running') -and $closing.Contains('e.Cancel = true;') -and $closing.Contains('AskToClose();')) `
    -Note 'MainWindow.OnClosing'
Test-Step -Title 'и останавливает её вместе с очередью' `
    -Ok ($closing.Contains('_jobs.StopForClose();') -and $stopForClose.Contains('Stop();') -and $stopForClose.Contains('WaitForExit(') -and
         $stop.Contains('_queue.Clear();') -and $stop.Contains('Kill(entireProcessTree: true)') -and $stop.Contains('_cancel?.Cancel()')) `
    -Note 'JobRunner.StopForClose: процесс с детьми, встроенная работа, очередь'

# Два облака одного вида копируют между собой сами; флаг общий у COPY, MIRROR, BISYNC и у подсчёта COPY.
$sync = Get-Body $ops 'async void Sync(string mode)'
Test-Step -Title 'копия между облаками одного вида - на их стороне' `
    -Ok ($sync -match 'CloudType == toSource\.CloudType[^;]*\)\s*carry\.Add\("--server-side-across-configs"\);' -and
         $sync.Contains('MeasureCopy(src, dst, filters, carry)') -and $sync.Contains('operation.AddRange(carry);') -and
         ([regex]::Matches($sync, '\.Concat\(carry\)').Count -ge 2) -and $cloudsCode.Contains('CloudType = cloud.Type')) `
    -Note '--server-side-across-configs: COPY, MIRROR, BISYNC'

# Папка данных меняется одним шагом, в котором ничего не ждут: сессия прежней папки уходит из окна
# раньше, чем меняется папка, а панели открываются заново. Ответ об облаках берёт только тот вопрос,
# что задан последним и об этой папке.
$choose = Get-Body $actions 'async Task ChooseDataFolder(string picked)'
$close = $choose.IndexOf('CloseClouds();')
$pointer = $choose.IndexOf('DataRoot.Choose(root)')
$said = $choose.IndexOf('Journal.Add(Lang.T("===== ПАПКА ДАННЫХ ====="));')
$opened = $choose.IndexOf('SetSection(_section, openPanels: true);')
$oneStep = $(if ($said -gt 0 -and $opened -gt $said) { $choose.Substring($said, $opened - $said) } else { 'await' })
Test-Step -Title 'папка данных меняется вместе со своей сессией' `
    -Ok ($close -gt 0 -and $pointer -gt $close -and $choose.Contains('_jobs.Running') -and
         (Get-Body $cloudsCode 'Task CloseClouds()').Contains('Rclone.SessionConfig = null;') -and
         (Get-Body $cloudsCode 'async void OpenClouds()') -match 'epoch != _cloudsEpoch \|\| !string\.Equals\(root, DataRoot\.Path_') `
    -Note 'CloseClouds раньше DataRoot.Choose; ответ - по номеру вопроса и папке'
Test-Step -Title 'одним шагом, и панели открываются заново' `
    -Ok ($opened -gt $pointer -and -not $oneStep.Contains('await') -and $oneStep.Contains('Sources.Rebuild();') -and $oneStep.Contains('_opened = false;')) `
    -Note 'между сменой папки и открытием панелей нет ни одного await'

# Start.exe -Root "<папка>" называет папку данных этого запуска, как -Root у каждого враппера.
Test-Step -Title '-Root в командной строке окна называет папку' `
    -Ok ($program.Contains('"-Root"') -and $program.Contains('Core.DataRoot.Name(named)') -and
         $program.IndexOf('Core.DataRoot.Name(named)') -lt $program.IndexOf('StartWithClassicDesktopLifetime') -and
         (Get-Body $dataRoot 'static string Find()').IndexOf('Named is { Length: > 0 }') -gt 0 -and
         (Get-Body $dataRoot 'static string Find()').IndexOf('Named is { Length: > 0 }') -lt (Get-Body $dataRoot 'static string Find()').IndexOf('Paths.ProfileFile')) `
    -Note 'Program.Main -> DataRoot.Name; указатель программы не меняется'
# Папка из -Root - папка одного запуска: то, что прежние настройки несут в папку данных своей
# машины (наборы масок), туда не переезжает - иначе с машины оно пропало бы.
Test-Step -Title 'и одноразовый перенос из настроек в неё не идёт' `
    -Ok ($window.Contains('if (DataRoot.Named.Length == 0 && DataStore.Adopt(_settings)) _settings.Save();')) `
    -Note 'MainWindow.Start: DataStore.Adopt только без -Root'
# Поля статического класса заполняются в порядке записи: Path_ спрашивает Named, пока заполняется сам.
# Объявленное ниже, Named было ещё null - и окно не запускалось вовсе.
Test-Step -Title 'Named объявлено выше Path_' `
    -Ok ($dataRoot.IndexOf('public static string Named') -gt 0 -and $dataRoot.IndexOf('public static string Named') -lt $dataRoot.IndexOf('public static string Path_')) `
    -Note 'порядок статических полей DataRoot'
Test-Step -Title 'сторож стоит раньше всего в Main' `
    -Ok ($program.IndexOf('Core.CrashGuard.Early();') -gt 0 -and $program.IndexOf('Core.CrashGuard.Early();') -lt $program.IndexOf('Core.DataRoot.Name(named)')) `
    -Note 'конец программы на самом старте тоже оставляет logs\gui-crash-*.log'

# Номер версии один - config\version.json. Свой номер в проекте сборки однажды разошёлся с ним.
$project = [System.IO.File]::ReadAllText((Join-Path $source 'AudionSyncTools.csproj'))
$number = [string](Get-Content -LiteralPath (Join-Path $AppRoot 'config\version.json') -Raw -Encoding UTF8 | ConvertFrom-Json).version
$builtDll = Join-Path $AppRoot 'App\AudionSyncTools.dll'
$builtAs = $(if (Test-Path -LiteralPath $builtDll) { ([System.Diagnostics.FileVersionInfo]::GetVersionInfo($builtDll).ProductVersion -split '\+')[0] } else { '' })
Test-Step -Title 'номер версии у окна один' `
    -Ok ($project.Contains('config\version.json') -and $project -notmatch '<Version>\s*\d' -and (-not $builtAs -or $builtAs -eq $number)) `
    -Note $(if ($builtAs) { 'version.json {0}, собранное окно {1}' -f $number, $builtAs } else { 'version.json {0}; App\ не собрана' -f $number })

# --- действие и то, с чем оно начато ---------------------------------------------
# Действие, которое ждёт - подсчёта, сценария, ответа на свой вопрос, - взяло пути у панелей и
# папку данных такими, какими они были в начале. К концу ожидания и то и другое могло стать
# другим: COPY, сосчитанный в папке A и подтверждённый после смены на B, уходил с путями A и
# конфигом B (AST-M07), а F8 спрашивал про одну папку и удалял то же имя в другой, куда панель
# успела перейти из окна поиска. Отсюда два правила, и оба держатся здесь.
function Get-Method {
    # Тело метода окна: от заголовка до закрывающей скобки на отступе класса.
    param([string]$Text, [string]$Name)
    $hit = [regex]::Match($Text, '(?ms)^    (?! )[^\r\n/]*?\basync\s+[^\r\n]*?\b' + [regex]::Escape($Name) + '\([^\r\n]*\r?\n    \{.*?^    \}')
    return $(if ($hit.Success) { $hit.Value } else { '' })
}
$waiting = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath $source -Filter 'MainWindow*.cs' | Sort-Object Name) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    foreach ($hit in [regex]::Matches($text, '(?m)^    (?! )[^\r\n/]*?\basync\s+[^\r\n]*?\b(\w+)\(')) {
        $waiting[$hit.Groups[1].Value] = Get-Method $text $hit.Groups[1].Value
    }
}
# Кому правило «using var pending = Pending();» не нужно - поимённо и с причиной. Новый метод
# с await, которого здесь нет и который папку данных не держит, проверку роняет.
$free = [ordered]@{
    'FirstStart'        = 'окно первого запуска: само ведёт к выбору папки данных'
    'AskFirstStart'     = 'окно первого запуска: само ведёт к выбору папки данных'
    'PickDataFolder'    = 'выбор папки данных'
    'CheckUpdatesQuietly' = 'версии инструментов при старте: от папки данных не зависят, рисуют только точку на SETTINGS'
    'ChooseDataFolder'  = 'сама смена папки данных'
    'PrepareData'       = 'подготовка папки данных: ответ сверяется с папкой'
    'PrepareAtStart'    = 'подготовка папки данных при старте'
    'OpenClouds'        = 'чтение облаков: ответ берётся по номеру вопроса и папке'
    'RefreshState'      = 'чтение состояния: ответ сверяется с папкой'
    'ShowState'         = 'сводка в журнал: ответ сверяется с папкой'
    'StartProbe'        = 'проба сети: ответ сверяется с номером смены папки'
    'FindLegacyTask'    = 'планировщик Windows: от папки данных не зависит'
    'CheckVersions'     = 'версии инструментов: от папки данных не зависят'
    'WaitThenRefresh'   = 'ждёт консоль мастера, потом читает то, что есть сейчас'
    'WrapperThenClouds' = 'ждёт консоль мастера rclone, потом читает облака заново'
    'OpenVpn'           = 'ждёт консоль OpenVPN; после неё сверяет папку, раздел и место панели'
    'AskToClose'        = 'вопрос о закрытии окна'
    'PickArchiveRoot'   = 'настройка окна: папка RELEASE'
    'PickTerminal'      = 'настройка окна: терминал'
    'SelectTabby'       = 'настройка окна: терминал'
    'CopyNames'         = 'буфер обмена: адреса собраны до ожидания'
    'ShowPublicKey'     = 'буфер обмена'
    'RemoveSchedule'    = 'планировщик Windows'
    'Describe'          = 'помощник мастеров: папку держит тот, кто его зовёт'
    'MeasureCopy'       = 'помощник COPY: папку держит Sync'
    'Overlap'           = 'помощник F5, F6 и SYNC: папку держит тот, кто его зовёт'
    'PickRouter'        = 'помощник мастеров роутера'
    'PickFolder'        = 'системный выбор папки'
    'AskClouds'         = 'помощник чтения облаков'
    'DevCrashLater'     = 'отладочная копия'
    'RunDevScript'      = 'отладочная копия'
}
$loose = @($waiting.Keys | Where-Object { -not $free.Contains($_) -and -not $waiting[$_].Contains('using var pending = Pending();') })
Test-Step -Title 'действие, которое ждёт, держит папку данных' -Ok ($loose.Count -eq 0 -and $waiting.Count -gt 40) `
    -Note $(if ($loose.Count) { 'без Pending(): ' + ($loose -join ', ') } else { 'методов с await: {0}, из них держат папку: {1}' -f $waiting.Count, ($waiting.Count - $free.Count) })
$gone = @($free.Keys | Where-Object { -not $waiting.Contains($_) })
$twice = @($free.Keys | Where-Object { $waiting.Contains($_) -and $waiting[$_].Contains('using var pending = Pending();') })
Test-Step -Title 'список исключений из этого правила не устарел' -Ok ($gone.Count -eq 0 -and $twice.Count -eq 0) `
    -Note $(if ($gone.Count -or $twice.Count) { 'нет такого метода: {0}; держит и назван исключением: {1}' -f ($gone -join ', '), ($twice -join ', ') } else { 'исключений: {0}' -f $free.Count })
Test-Step -Title 'папка данных под действием не меняется' `
    -Ok ($choose.Contains('if (_jobs.Running || _pending > 0 || OwnedWindows.Count > 0)') -and
         $actions.Contains('IDisposable Pending() => new PendingAction(this);') -and $actions.Contains('window._pending++;') -and $actions.Contains('window._pending--;')) `
    -Note 'ChooseDataFolder отказывает: задание, действие в ожидании, вопрос на экране'

# Адрес операции - у места, взятого до вопроса; панель после ответа уже может стоять не там.
$panelAfter = '\b(?:panel|from|to|_active|Other|LeftPanel|RightPanel)\.(?:Path|SourceKey|Rows|Selection\(\)|CursorRow)\b|\b(?:IsMachine|AtDisks|Where|Label|LocalDir)\((?:panel|from|to|_active|Other)\)'
$strays = [System.Collections.Generic.List[string]]::new()
foreach ($name in 'Copy', 'Rename', 'Mkdir', 'Delete', 'Sync', 'ShareLinks', 'Pack', 'Unpack') {
    $body = [string]$waiting[$name]
    $at = $body.IndexOf('await ')
    if ($at -lt 0) { $strays.Add($name + ': нет await'); continue }
    foreach ($hit in [regex]::Matches($body.Substring($at), $panelAfter)) { $strays.Add($name + ': ' + $hit.Value) }
}
$placed = @('Copy', 'Rename', 'Mkdir', 'Delete', 'ShareLinks' | Where-Object {
    $body = [string]$waiting[$_]
    $body.IndexOf('Place.Of(') -lt 0 -or $body.IndexOf('Place.Of(') -gt $body.IndexOf('await ')
})
Test-Step -Title 'операция идёт туда, что назвал её вопрос' `
    -Ok ($strays.Count -eq 0 -and $placed.Count -eq 0 -and -not $ops.Contains('static string Target(FilePanel')) `
    -Note $(if ($strays.Count -or $placed.Count) { 'панель читается после ожидания: {0}; место не взято до него: {1}' -f ($strays -join ' | '), ($placed -join ', ') } else { 'F5 F6 F2 F7 F8 F3 F11 F12: место панели берётся до вопроса' })

# Аудит 08.10.2026, то, что видно чтением. Вложенность двух папок спрашивается у диска не на потоке
# окна: сетевой диск, переставший отвечать, подвешивал окно. Машина дальним маршрутом по адресу не
# узнаётся: её спрашивают, и только когда пути на обоих концах мешали бы друг другу. F2 читает папку
# с тем же терпением, что и панель: на 30 секундах он отказывал там, где панель папку показывала.
# Предупреждение rclone об ssh поверх адреса молчит в одном задании, а не во всём журнале.
$overlap = Get-Method $ops 'Overlap'
$rename = [string]$waiting['Rename']
$journalCode = [System.IO.File]::ReadAllText((Join-Path $source 'Core\Journal.cs'))
Test-Step -Title 'вложенность папок спрашивается у диска не на потоке окна' `
    -Ok ($overlap.Length -gt 0 -and ([regex]::Matches($overlap, 'PathGuard\.Problem\(')).Count -eq 2 -and ([regex]::Matches($overlap, 'Task\.Run\(\(\) => PathGuard\.Problem\(')).Count -eq 2) `
    -Note 'Overlap: PathGuard.Problem только внутри Task.Run'
Test-Step -Title 'машину дальним маршрутом спрашивают, эта ли она' `
    -Ok ($overlap.Contains('Sources.AsLocal(far.Path)') -and $overlap.Contains('await Sources.SameMachine(far.Key') -and
         $overlap.IndexOf('PathGuard.Problem(source, target') -lt $overlap.IndexOf('Sources.SameMachine(') -and $overlap.Contains('Sources.Same.Silent')) `
    -Note 'Overlap: сначала пути, потом вопрос машине; молчание - отказ'
Test-Step -Title 'F2 читает папку с тем же сроком, что и панель' `
    -Ok ($rename.Contains('await Rclone.List(into, CancellationToken.None);') -and $rename -notmatch 'Rclone\.List\([^;]*,\s*\d+\)') `
    -Note 'Rename: Rclone.List без своего срока'
Test-Step -Title 'F2 перепроверяет имя перед запуском и папку после' `
    -Ok ($rename.Contains('first.Before = StillFree;') -and $rename.Contains('job.Before = StillFree;') -and
         $rename.Contains('if (item.IsDir) job.After = ') -and $rename.Contains('if (item.IsDir) second.After = ') -and $rename.Contains('second.Undone = ')) `
    -Note 'Rename: Job.Before, Job.After, Job.Undone'
Test-Step -Title 'предупреждение rclone об ssh поверх адреса скрыто только в своём задании' `
    -Ok (-not (Get-Body $journalCode 'public static bool IsNoise(string line)').Contains('sftp-ssh') -and $sync.Contains('job.Hush = new[] { Journal.SshOverHost };') -and
         (Get-Body $jobs 'void Take(string line, string title)').Contains('foreach (var expected in _hush)')) `
    -Note 'Journal.IsNoise его не знает; BISYNC издалека ставит Job.Hush'

# Чтение, спрошенное у прежней папки, в новую не ложится: проба, состояние, сводка.
Test-Step -Title 'ответ о прежней папке в новую не ложится' `
    -Ok (([string]$waiting['StartProbe']).Contains('if (step != _dataStep)') -and ([string]$waiting['StartProbe']).Contains('if (_probeAsked) StartProbe(quiet: true);') -and
         ([string]$waiting['RefreshState']) -match 'string\.Equals\(root, DataRoot\.Path_[^)]*\)\) continue;' -and
         ([string]$waiting['ShowState']) -match 'string\.Equals\(root, DataRoot\.Path_[^)]*\)\)\s*\{\s*if \(_summaryAsked\) ShowState\(\);\s*return;' -and
         $choose.Contains('_proven.Clear();') -and $choose.Contains('Sources.LanUp.Clear();') -and $choose.Contains('_setup = _beacon = null;')) `
    -Note 'проба, состояние и сводка сверяют папку; смена папки забывает узнанное о прежней'

# Окно первого запуска отдаёт ответ, когда его уже нет среди окон программы. На Windows код после
# await ShowDialog идёт, пока владелец ещё числит диалог своим (Avalonia убирает его после Closed),
# и ChooseDataFolder отклонял выбранную папку как «идёт операция» (18.10.2026). Стенд без экрана
# этого не видит: там диалог уходит раньше.
$firstStart = Get-Content -LiteralPath (Join-Path $source 'Views\FirstStartDialog.cs') -Raw -Encoding UTF8
Test-Step -Title 'ответ окна первого запуска - после ухода диалога' `
    -Ok ($firstStart -match 'await dialog\.ShowDialog\(owner\);\s*(//[^\n]*\n\s*)*await Task\.Yield\(\);\s*return result;') `
    -Note 'FirstStartDialog.Ask: await Task.Yield() после ShowDialog'

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
