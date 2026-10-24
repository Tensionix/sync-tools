#requires -Version 5.1
<#
    Проверка корневых документов.

    AGENTS.md - копия CLAUDE.md: разные помощники ищут правила под разными
    именами. Копия живёт ровно до первой правки одного из файлов, поэтому за
    совпадением следит тест, а не память.

    Сверяются тела: у AGENTS.md своя шапка, объясняющая, почему файлов два.
    Всё, что ниже шапки, обязано совпадать слово в слово.

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

function Get-Body {
    <# Текст без шапки: до первого правила, отмеченного жирным заголовком. #>
    param([string]$Path)
    $text = (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"
    $at = $text.IndexOf('Четыре файла, и у каждого своё дело:')
    if ($at -lt 0) { return $text }
    return $text.Substring($at)
}

Write-Host ''
Write-Host '===== ДОКУМЕНТЫ ====='

foreach ($name in 'CLAUDE.md', 'AGENTS.md', 'MEMORY.md', 'SKILL.md', 'README.md',
    'PROMPT_RU.md', 'PROMPT_EN.md') {
    Test-Step -Title ('есть: {0}' -f $name) -Ok (Test-Path -LiteralPath (Join-Path $AppRoot $name))
}

$claude = Get-Body -Path (Join-Path $AppRoot 'CLAUDE.md')
$agents = Get-Body -Path (Join-Path $AppRoot 'AGENTS.md')

Test-Step -Title 'AGENTS.md повторяет CLAUDE.md' -Ok ($claude -eq $agents) `
    -Note $(if ($claude -eq $agents) { 'знаков: {0}' -f $claude.Length }
            else { 'расходятся: {0} против {1}' -f $claude.Length, $agents.Length })

if ($claude -ne $agents) {
    # Показываем первую разошедшуюся строку - иначе искать глазами долго.
    $left = $claude -split "`n"
    $right = $agents -split "`n"
    for ($i = 0; $i -lt [Math]::Max($left.Count, $right.Count); $i++) {
        $a = $(if ($i -lt $left.Count) { $left[$i] } else { '(нет строки)' })
        $b = $(if ($i -lt $right.Count) { $right[$i] } else { '(нет строки)' })
        if ($a -ne $b) {
            Write-Host ('      строка {0}' -f ($i + 1))
            Write-Host ('      CLAUDE: {0}' -f $a)
            Write-Host ('      AGENTS: {0}' -f $b)
            break
        }
    }
}

# Шапка AGENTS.md обязана объяснять, почему файлов два - иначе следующий
# правящий решит, что это забытый черновик.
$head = (Get-Content -LiteralPath (Join-Path $AppRoot 'AGENTS.md') -Raw)
Test-Step -Title 'AGENTS.md объясняет, что он копия' -Ok ($head -like '*копия*CLAUDE.md*')

# Описание программы и порядок восстановления лежат парами в Docs, как у остальных программ,
# а README.md в корне - указатель на обе половины каждой: человек открывает любую и находит
# вторую. Перевод тест не сверяет - только что половины есть, знают друг о друге и разделов
# в них поровну (по заголовкам второго уровня).
$pointer = Get-Content -LiteralPath (Join-Path $AppRoot 'README.md') -Raw
foreach ($pair in 'README', 'RESTORE', 'SYNC_ALL') {
    $ruName = '{0}_RU.md' -f $pair
    $enName = '{0}_EN.md' -f $pair
    $ruPath = Join-Path $AppRoot (Join-Path 'Docs' $ruName)
    $enPath = Join-Path $AppRoot (Join-Path 'Docs' $enName)
    $both = (Test-Path -LiteralPath $ruPath) -and (Test-Path -LiteralPath $enPath)
    Test-Step -Title ('есть пара: Docs\{0} и Docs\{1}' -f $ruName, $enName) -Ok $both
    if (-not $both) { continue }
    $ruText = Get-Content -LiteralPath $ruPath -Raw
    $enText = Get-Content -LiteralPath $enPath -Raw
    Test-Step -Title ('{0}: половины ссылаются друг на друга' -f $pair) `
        -Ok (($ruText -like ('*' + $enName + '*')) -and ($enText -like ('*' + $ruName + '*')))
    Test-Step -Title ('{0}: README.md в корне ведёт к обеим' -f $pair) `
        -Ok (($pointer -like ('*Docs/' + $ruName + '*')) -and ($pointer -like ('*Docs/' + $enName + '*')))
    $sectionsRu = @($ruText -split "`n" | Where-Object { $_ -like '## *' }).Count
    $sectionsEn = @($enText -split "`n" | Where-Object { $_ -like '## *' }).Count
    Test-Step -Title ('{0}: разделов поровну' -f $pair) -Ok ($sectionsRu -eq $sectionsEn) `
        -Note ('{0} и {1}' -f $sectionsRu, $sectionsEn)
}
# Прежнего имени без языка быть не должно: ссылка на него вела бы в никуда.
Test-Step -Title 'нет Docs\RESTORE.md без языка' `
    -Ok (-not (Test-Path -LiteralPath (Join-Path $AppRoot 'Docs\RESTORE.md')))

# Промпты ссылаются друг на друга: человек открывает любой и находит второй.
$ru = Get-Content -LiteralPath (Join-Path $AppRoot 'PROMPT_RU.md') -Raw
$en = Get-Content -LiteralPath (Join-Path $AppRoot 'PROMPT_EN.md') -Raw
Test-Step -Title 'промпты ссылаются друг на друга' `
    -Ok (($ru -like '*PROMPT_EN.md*') -and ($en -like '*PROMPT_RU.md*'))

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
