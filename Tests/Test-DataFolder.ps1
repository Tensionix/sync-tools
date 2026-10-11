#requires -Version 7.0
<#
    Папка данных готова к работе раньше, чем нажата первая кнопка.

    Окно при старте и при выборе другой папки данных зовёт
    Engine\Scripts\Initialize-DataFolder.ps1. Ни одна кнопка этого не делает:
    каркас адресов разворачивается из образца программы, запись SECOND VPS
    приходит из ~\.ssh\config машины, настроенной прежней версией, а рабочие
    файлы, оставшиеся в папке программы от модели до 1.15.0, переезжают в данные.
    При переносе окна на Avalonia этот шаг потерялся: мастер АДРЕСА на пустой
    папке данных отвечал «нет файла», и создать его из окна было нечем.

    Сценарий гоняется целиком на временной папке данных; ssh-конфиг ему назван
    свой, пустой, - настоящий профиль не читается.

    Проверяется:
      - пустая папка получает targets.json из образца, и ответ говорит об этом;
      - второй запуск ничего не меняет: файл, который есть, не заменяется;
      - заполненный человеком файл не трогается ни одним байтом;
      - ответ - одна строка JSON со всеми полями, которые читает окно;
      - окно зовёт сценарий при старте, при выборе папки и перед мастером АДРЕСА.

    За пределами временной папки ничего не меняет. Возвращает 0, когда всё сходится.
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
    if ($Note) { Write-Host ('{0}  {1,-50} {2}' -f $mark, $Title, $Note) }
    else { Write-Host ('{0}  {1}' -f $mark, $Title) }
    if (-not $Ok) { $script:failed++ }
}

$script = Join-Path $AppRoot 'Engine\Scripts\Initialize-DataFolder.ps1'

function Initialize-Stand {
    param([string]$Data, [string]$SshConfig, [string]$Previous = '')
    $global:LASTEXITCODE = 0
    $extra = @{}
    if ($Previous) { $extra['Previous'] = $Previous }
    $said = @(& $script -Root $Data -SshConfig $SshConfig @extra 6>&1 2>&1 | ForEach-Object { "$_" })
    $line = @($said | Where-Object { $_.StartsWith('{') })
    if (-not $line.Count) { return $null }
    return ($line[-1] | ConvertFrom-Json)
}

Write-Host ''
Write-Host '===== ПАПКА ДАННЫХ ГОТОВА К РАБОТЕ ====='

$stand = Join-Path ([System.IO.Path]::GetTempPath()) ('abk-datafolder-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    $data = Join-Path $stand 'Audion Backup Stand'
    New-Item -ItemType Directory -Path $data -Force | Out-Null
    # Пустой ssh-конфиг стенда: SECOND VPS в нём нет, настоящий ~\.ssh\config не читается.
    $sshConfig = Join-Path $stand 'ssh_config'
    [System.IO.File]::WriteAllText($sshConfig, '')
    $live = Join-Path $data 'Tunnel\RemoteDesktop\config\targets.json'
    $sample = Join-Path $AppRoot 'Tunnel\RemoteDesktop\config\targets.sample.json'

    # --- 1. пустая папка данных ----------------------------------------------------------
    $first = Initialize-Stand -Data $data -SshConfig $sshConfig
    Test-Step -Title 'сценарий отвечает одной строкой JSON' -Ok ($null -ne $first)
    Test-Step -Title 'пустая папка получает каркас адресов' -Ok ((Test-Path -LiteralPath $live) -and $first -and $first.targets -eq $true)
    $asSample = $false
    try { $asSample = ((Get-Content -LiteralPath $live -Raw | ConvertFrom-Json).PSObject.Properties.Name -contains 'base') } catch { }
    Test-Step -Title 'каркас разобран: машины из образца на месте' -Ok $asSample
    $fields = @('moved', 'quarantined', 'quarantine', 'targets', 'second')
    $missing = @($fields | Where-Object { -not ($first -and $first.PSObject.Properties[$_]) })
    Test-Step -Title 'в ответе все поля, которые читает окно' -Ok ($missing.Count -eq 0) `
        -Note $(if ($missing.Count) { 'нет: ' + ($missing -join ', ') } else { $fields -join ', ' })
    Test-Step -Title 'списки приходят списками и на пустом месте пусты' `
        -Ok ($first -and $first.moved -is [array] -and $first.quarantined -is [array] -and -not $first.moved.Count -and -not $first.quarantined.Count)

    # --- 2. второй запуск -----------------------------------------------------------------
    $before = [System.IO.File]::ReadAllBytes($live)
    $second = Initialize-Stand -Data $data -SshConfig $sshConfig
    $after = [System.IO.File]::ReadAllBytes($live)
    Test-Step -Title 'второй запуск каркас не разворачивает заново' -Ok ($second -and $second.targets -eq $false)
    Test-Step -Title 'и файл остаётся байт в байт' -Ok ([System.Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]]$after))

    # --- 3. файл, заполненный человеком ---------------------------------------------------
    # Адреса вписаны, запись second заполнена: сценарию здесь делать нечего.
    $filled = [System.IO.File]::ReadAllText($sample)
    $filled = $filled -replace '("base"\s*:\s*\{[^}]*?"lan"\s*:\s*)""', '$1"192.0.2.10"'
    $filled = $filled -replace '("second"\s*:\s*\{[^}]*?"host"\s*:\s*)""', '$1"192.0.2.20"'
    [System.IO.File]::WriteAllText($live, $filled)
    $before = [System.IO.File]::ReadAllBytes($live)
    $third = Initialize-Stand -Data $data -SshConfig $sshConfig
    $after = [System.IO.File]::ReadAllBytes($live)
    Test-Step -Title 'заполненный файл не тронут ни одним байтом' `
        -Ok ($third -and $third.targets -eq $false -and -not [string]$third.second -and [System.Linq.Enumerable]::SequenceEqual([byte[]]$before, [byte[]]$after))

    # --- 4. другая папка данных -----------------------------------------------------------
    # Смена папки: новая получает свой каркас, а прежняя остаётся как была.
    $other = Join-Path $stand 'Audion Backup Other'
    New-Item -ItemType Directory -Path $other -Force | Out-Null
    $moved = Initialize-Stand -Data $other -SshConfig $sshConfig -Previous $data
    Test-Step -Title 'новая папка при смене получает свой каркас' `
        -Ok ($moved -and $moved.targets -eq $true -and (Test-Path -LiteralPath (Join-Path $other 'Tunnel\RemoteDesktop\config\targets.json')))
    Test-Step -Title 'прежняя папка при смене не меняется' `
        -Ok ([System.Linq.Enumerable]::SequenceEqual([byte[]]$after, [byte[]][System.IO.File]::ReadAllBytes($live)))
} finally {
    Remove-Item -LiteralPath $stand -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 5. окно зовёт сценарий ------------------------------------------------------------
$source = Join-Path $AppRoot 'Source'
$actions = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.Actions.cs'))
$window = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.axaml.cs'))
$setup = [System.IO.File]::ReadAllText((Join-Path $source 'MainWindow.Setup.cs'))
Test-Step -Title 'окно готовит папку данных сценарием движка' -Ok ($actions.Contains('SetupScript("Initialize-DataFolder.ps1")'))
Test-Step -Title 'при старте' -Ok ($window.Contains('PrepareAtStart();') -and $window.Contains('await PrepareData()'))
$choose = $actions.IndexOf('async Task ChooseDataFolder(')
$prepare = $actions.IndexOf('await PrepareData(previous)', [Math]::Max(0, $choose))
$reread = $actions.IndexOf('LeftPanel.ReloadNow(); RightPanel.ReloadNow();', [Math]::Max(0, $prepare))
Test-Step -Title 'при выборе папки, и прочитанное до неё читается заново' -Ok ($choose -gt 0 -and $prepare -gt $choose -and $reread -gt $prepare)
Test-Step -Title 'и перед мастером АДРЕСА, когда файла нет' -Ok ($setup -match 'if \(!File\.Exists\(file\) && await PrepareData\(\)\)')

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
