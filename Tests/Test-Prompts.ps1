#requires -Version 5.1
<#
    Проверка промптов против настоящего окна.

    Промпт для помощника перечисляет шаги по именам кнопок. Кнопку
    переименовали или перенесли - помощник на новой машине ищет несуществующее
    и начинает выдумывать. Разметка такие расхождения не ловит: для неё это
    просто чужой текст.

    Тест берёт подписи нового окна (Source\, Avalonia) - ряды кнопок из
    config\bars.json, разделы, блоки и кнопки SETTINGS, кнопки разметки, - обе:
    русскую и её перевод из config\i18n.json. Вылавливает из промптов все
    имена, набранные заглавными в обратных кавычках, и требует, чтобы каждое
    нашлось в окне. Заодно следит за нумерацией шагов: она должна идти подряд
    и совпадать в двух языках.

    Ничего не запускает и не меняет. Возвращает 0, когда всё сходится.
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
    if ($Note) { Write-Host ('{0}  {1,-46} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

Write-Host ''
Write-Host '===== ПРОМПТЫ ПРОТИВ ОКНА ====='

# --- подписи всех кнопок окна: русская и английская --------------------------
$source = Join-Path $AppRoot 'Source'
$dict = Get-Content -LiteralPath (Join-Path $source 'config\i18n.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$captions = New-Object System.Collections.Generic.HashSet[string]
$rows = @{}
function Add-Caption {
    param([string]$Text, [string]$Place)
    $ru = $Text.Trim()
    if (-not $ru) { return }
    foreach ($cap in @($ru, $(if ($dict.ContainsKey($ru)) { [string]$dict[$ru].en } else { '' }))) {
        if (-not $cap) { continue }
        [void]$captions.Add($cap.Trim())
        $rows[$cap.Trim().TrimEnd([char]0x2026, ' ')] = $Place
    }
}

# Ряды кнопок разделов.
$bars = Get-Content -LiteralPath (Join-Path $source 'config\bars.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
foreach ($bar in $bars.Keys) {
    foreach ($group in $bars[$bar]) { foreach ($item in $group.items) { Add-Caption -Text ([string]$item.text) -Place $bar } }
}
# Разделы, блоки и кнопки SETTINGS, кнопки и переключатели, собранные кодом: первая строка в кавычках у вызова.
$windowCode = (Get-ChildItem -LiteralPath $source -Filter '*.cs' -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
foreach ($m in [regex]::Matches($windowCode, 'new\("\w+", "([^"]+)", "[^"]+", (?:Machines|new\[\])')) { Add-Caption -Text $m.Groups[1].Value -Place 'section' }
foreach ($m in [regex]::Matches($windowCode, '(?:Open\(\w+, |Action\(|Content = (?:Lang\.T\()?)"([^"]+)"')) { Add-Caption -Text $m.Groups[1].Value -Place 'window' }
foreach ($m in [regex]::Matches($windowCode, '\((?:-?\d+|true|false|"[^"]*"|AgeLimit\.\w+), "([^"]+)", "[^"]*"\)')) { Add-Caption -Text $m.Groups[1].Value -Place 'switch' }
# Кнопки разметки.
foreach ($file in Get-ChildItem -LiteralPath $source -Filter '*.axaml' -File -Recurse | Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }) {
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), '(?:Content|Text)="([^"{]+)"')) { Add-Caption -Text $m.Groups[1].Value -Place 'markup' }
}

Test-Step -Title 'подписи кнопок собраны' -Ok ($captions.Count -gt 20) `
    -Note ('имён: {0}' -f $captions.Count)

# --- шаги промптов ------------------------------------------------------------
$texts = @{}
foreach ($name in 'PROMPT_RU.md', 'PROMPT_EN.md') {
    $texts[$name] = (Get-Content -LiteralPath (Join-Path $AppRoot $name) -Raw) -replace "`r`n", "`n"
}

$counts = @{}
foreach ($name in $texts.Keys) {
    $numbers = @()
    foreach ($m in [regex]::Matches($texts[$name], '(?m)^>\s*(\d+)\.\s')) {
        $numbers += [int]$m.Groups[1].Value
    }
    $counts[$name] = $numbers.Count
    $straight = $true
    for ($i = 0; $i -lt $numbers.Count; $i++) { if ($numbers[$i] -ne ($i + 1)) { $straight = $false } }
    Test-Step -Title ('{0}: шаги нумерованы подряд' -f $name) -Ok ($numbers.Count -gt 0 -and $straight) `
        -Note ('шагов: {0}' -f $numbers.Count)
}

Test-Step -Title 'в обоих промптах шагов поровну' `
    -Ok ($counts['PROMPT_RU.md'] -eq $counts['PROMPT_EN.md']) `
    -Note ('RU {0}, EN {1}' -f $counts['PROMPT_RU.md'], $counts['PROMPT_EN.md'])

# --- каждое имя кнопки из промпта существует в окне ---------------------------
# Ловим только то, что набрано заглавными латинскими в обратных кавычках:
# пути, файлы и ключи командной строки под это не подходят.
$unknown = New-Object System.Collections.Generic.List[string]
$seen = New-Object System.Collections.Generic.HashSet[string]
foreach ($name in $texts.Keys) {
    foreach ($m in [regex]::Matches($texts[$name], '`([A-Z][A-Z0-9._-]*(?: [A-Z0-9._-]+)*[' + [char]0x2026 + ']?)`')) {
        $token = $m.Groups[1].Value.TrimEnd([char]0x2026, ' ')
        if (-not $seen.Add($token)) { continue }
        $hit = $false
        foreach ($c in $captions) { if ($c.TrimEnd([char]0x2026, ' ') -ceq $token) { $hit = $true } }
        if (-not $hit) { $unknown.Add(('{0} ({1})' -f $token, $name)) }
    }
}

Test-Step -Title 'все имена кнопок из промптов есть в окне' -Ok ($unknown.Count -eq 0) `
    -Note $(if ($unknown.Count) { 'нет таких: ' + ($unknown -join ', ') } else { 'проверено: {0}' -f $seen.Count })

# --- обязательные шаги первичной настройки ------------------------------------
# Порядок первых шагов важен: ключи раскладываются до того, как ими пользуются.
foreach ($must in 'DATA FOLDER', 'IMPORT KEYS', 'SSH-KEYGEN', 'ADDRESSES', 'SSH-KEYSCAN',
    'RCLONE.CONF', 'SSH-COPY-ID', 'SSHD') {
    $inBoth = $true
    foreach ($name in $texts.Keys) { if ($texts[$name] -notmatch [regex]::Escape($must)) { $inBoth = $false } }
    Test-Step -Title ('шаг назван в обоих промптах: {0}' -f $must) -Ok $inBoth `
        -Note $(if ($rows.ContainsKey($must)) { 'ряд ' + $rows[$must] } else { '' })
}

# --- врапперы, на которые ссылаются промпты, существуют ------------------------
$missing = New-Object System.Collections.Generic.List[string]
# Start.exe собирается из исходников и в git не лежит: на чистой копии его нет,
# и промпт не ошибается, пока на месте сборщик.
$built = @{ 'Start.exe' = 'Engine\Launcher\Build-StartExe.ps1' }
foreach ($name in $texts.Keys) {
    # Имя файла может содержать пробелы, а после него - ключи командной строки.
    # Поэтому режем не по пробелу, а по самому расширению.
    foreach ($m in [regex]::Matches($texts[$name], '`([^`]+?\.(?:cmd|exe|ps1))')) {
        $rel = $m.Groups[1].Value.Trim()
        if (Test-Path -LiteralPath (Join-Path $AppRoot $rel)) { continue }
        $leafName = Split-Path $rel -Leaf
        if ($built.ContainsKey($leafName) -and (Test-Path -LiteralPath (Join-Path $AppRoot $built[$leafName]))) { continue }
        # Файл могли назвать без папки - поищем по имени.
        $leaf = Split-Path $rel -Leaf
        $found = Get-ChildItem -LiteralPath $AppRoot -Filter $leaf -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $found) { $missing.Add(('{0} ({1})' -f $rel, $name)) }
    }
}

Test-Step -Title 'файлы и врапперы из промптов существуют' -Ok ($missing.Count -eq 0) `
    -Note $(if ($missing.Count) { 'нет: ' + ($missing -join ', ') } else { '' })

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
