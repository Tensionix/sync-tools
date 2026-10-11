#requires -Version 5.1
<#
    Проверка кодировок. Два правила, и оба уже стоили поломок.

    Сценарии PowerShell живут с BOM: без него PowerShell 5.1 читает файл как
    ANSI, и русские строки превращаются в кашу. Сначала так молча сломался
    словарь языка.

    Командные файлы живут БЕЗ BOM: cmd читает его как часть первой строки и
    вместо `@echo off` видит «я╗┐@echo» - жалуется, что такой команды нет, и
    печатает эхом весь скрипт. На своей машине это выглядит безобидно, на
    чужой - как поломка.

    Концы строк везде CRLF: .cmd без них ломается сам по себе, а остальное
    просто держим единым.

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

function Get-Head {
    <# Первые байты: BOM видно только так, текстом его не поймать. #>
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    [pscustomobject]@{
        Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Crlf = ([System.Text.Encoding]::UTF8.GetString($bytes) -match "`r`n")
        Lines = ([System.Text.Encoding]::UTF8.GetString($bytes) -split "`n").Count
    }
}

# Инструменты не наши: там чужие файлы, и правила к ним не относятся.
# Рантайм - не исходник: там распакованные инструменты, рабочие копии и
# материалы разборов. Требовать от них BOM и CRLF нечего.
# App - собранное окно со встроенным PowerShell, bin и obj - кэш сборки: в них
# модули самого PowerShell, файлы Microsoft, и наши правила к ним не относятся.
$skip = @('\Tools\', '\logs\', '\.git\', '\._runtime\', '\App\', '\bin\', '\obj\')

function Get-Ours {
    <#
        Отбор без вложенных Where-Object: во втором `$_` - уже элемент маски, а
        не файл, и условие тихо отсеивало вообще всё. Явный цикл не спорит за
        имя.
    #>
    param([string]$Filter)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($file in Get-ChildItem -LiteralPath $AppRoot -Filter $Filter -Recurse -File -ErrorAction SilentlyContinue) {
        # Путь только относительный: сам проект лежит в E:\TOOLS, и маска
        # «\Tools\» совпадала с корнем - отсеивалось вообще всё.
        $rel = $file.FullName.Substring($AppRoot.Length)
        $ours = $true
        foreach ($mask in $skip) {
            if ($rel -like ('*' + $mask + '*')) { $ours = $false }
        }
        if ($ours) { $out.Add($file) }
    }
    return $out
}

Write-Host ''
Write-Host '===== КОДИРОВКИ ====='

# --- сценарии PowerShell: BOM обязателен -------------------------------------
$noBom = @()
$psFiles = @(Get-Ours '*.ps1') + @(Get-Ours '*.psm1') + @(Get-Ours '*.psd1')
foreach ($file in $psFiles) {
    if (-not (Get-Head $file.FullName).Bom) { $noBom += $file.FullName.Substring($AppRoot.Length + 1) }
}
Test-Step -Title 'сценарии PowerShell с BOM' -Ok ($noBom.Count -eq 0) `
    -Note $(if ($noBom.Count) { 'без BOM: ' + ($noBom -join ', ') } else { 'файлов: {0}' -f $psFiles.Count })

# --- командные файлы: BOM запрещён -------------------------------------------
$withBom = @()
$cmdFiles = @(Get-Ours '*.cmd')
foreach ($file in $cmdFiles) {
    if ((Get-Head $file.FullName).Bom) { $withBom += $file.FullName.Substring($AppRoot.Length + 1) }
}
Test-Step -Title 'командные файлы без BOM' -Ok ($withBom.Count -eq 0) `
    -Note $(if ($withBom.Count) { 'с BOM: ' + ($withBom -join ', ') } else { 'файлов: {0}' -f $cmdFiles.Count })

# --- концы строк -------------------------------------------------------------
$noCrlf = @()
foreach ($file in ($psFiles + $cmdFiles)) {
    $head = Get-Head $file.FullName
    if ($head.Lines -gt 3 -and -not $head.Crlf) { $noCrlf += $file.FullName.Substring($AppRoot.Length + 1) }
}
Test-Step -Title 'везде CRLF' -Ok ($noCrlf.Count -eq 0) `
    -Note $(if ($noCrlf.Count) { 'с LF: ' + ($noCrlf -join ', ') } else { '' })

# --- пустая строка после каждой строки: так уже ломались два сценария ---------
# Перенос через обратную кавычку не переживает пустую строку следом: команда
# рвётся, продолжение становится отдельной, и вызов падает на пустом месте.
$bloated = @()
foreach ($file in $psFiles) {
    $lines = [System.IO.File]::ReadAllText($file.FullName) -replace "`r`n", "`n" -split "`n"
    $broken = 0
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i].TrimEnd().EndsWith('`') -and -not $lines[$i + 1].Trim()) { $broken++ }
    }
    if ($broken) { $bloated += ('{0} ({1})' -f $file.FullName.Substring($AppRoot.Length + 1), $broken) }
}
Test-Step -Title 'переносы строк не разорваны пустой строкой' -Ok ($bloated.Count -eq 0) `
    -Note $(if ($bloated.Count) { $bloated -join ', ' } else { '' })

# --- путь, разорванный переводом строки --------------------------------------
# Патч, в котором обратная косая с буквой понята как управляющий символ,
# разбивает литерал на несколько строк. Синтаксис остаётся верным - PowerShell
# не против многострочной строки, - поэтому разбор молчит, а сравнение пути не
# совпадает никогда. Так путь к своему rclone был тремя строками, и уборка
# потерянных процессов не работала вовсе.
$torn = @()
foreach ($file in $psFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    if (-not $ast) { continue }
    $strings = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
    foreach ($one in $strings) {
        # Многострочными бывают и настоящие тексты - сценарии awk и bash
        # живут в @'...'@ и переводы строк в них законны. Смотрим только
        # обычные кавычки: там перевод строки почти всегда след патча.
        if ("$($one.StringConstantType)" -like '*HereString*') { continue }
        # Смотрим не на значение, а на место в файле: перевод строки внутри
        # значения бывает и законным - его пишут обратной кавычкой с n. След
        # патча выглядит иначе: литерал занимает в исходнике больше строки.
        if ($one.Extent.StartLineNumber -ne $one.Extent.EndLineNumber) {
            $torn += ('{0}:{1}' -f $file.FullName.Substring($AppRoot.Length + 1), $one.Extent.StartLineNumber)
        }
    }
}
Test-Step -Title 'пути в кавычках не разорваны переводом строки' -Ok ($torn.Count -eq 0) `
    -Note $(if ($torn.Count) { $torn -join ', ' } else { '' })

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
