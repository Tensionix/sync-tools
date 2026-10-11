#requires -Version 7.0
<#
    Код, которым кончается сценарий, один - как бы его ни запустили.

    Враппер и проверка запускают сценарий ключом -File: кодом становится число
    его собственного exit, а без exit - ноль. Окно запускает его через -Command с
    обёрткой (Source\Core\Scripts.cs: Inner), шаг RESTORE - через -EncodedCommand
    (Engine\Scripts\Restore-Machine.ps1: Invoke-RestoreStep). Обе обёртки
    кончались `exit $LASTEXITCODE`, а в этой переменной лежит и код последней
    программы, которую сценарий запускал сам. Сценарий, который разобрался с
    отказом ssh или robocopy и кончился без своего exit, в окне был «код 3» при
    нуле у враппера, а шаг RESTORE с таким сценарием проваливал всё
    восстановление (проверка 08.10.2026).

    Различает одно от другого успех вызова: после сценария он ложен только
    тогда, когда сценарий сам вышел через exit не с нулём.

    Обёртка окна берётся из Scripts.cs так, как она там написана, команда шага
    RESTORE - из Restore-Machine.ps1; обе исполняются на пробных сценариях во
    временной папке под той же оболочкой, что и эта проверка. Мерило - тот же
    сценарий, запущенный через -File.

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

Write-Host ''
Write-Host '===== КОД ВЫХОДА СЦЕНАРИЯ ====='

# --- обёртки, как они написаны в программе -------------------------------------
$window = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Source\Core\Scripts.cs'))
$head = [regex]::Match($window, 'var inner = "(?<text>[^"]*)" \+ Quote\(path\);')
$tail = [regex]::Match($window, 'return inner \+ "(?<text>[^"]*)";')
Test-Step -Title 'обёртка окна читается из Scripts.cs' -Ok ($head.Success -and $tail.Success) -Note 'Scripts.Inner: начало и хвост команды'

$restore = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Restore-Machine.ps1'))
$from = $restore.IndexOf('function Invoke-RestoreStep')
$to = $(if ($from -ge 0) { $restore.IndexOf('function ', $from + 10) } else { -1 })
$step = @([regex]::Matches($(if ($from -ge 0 -and $to -gt $from) { $restore.Substring($from, $to - $from) } else { '' }), "(?m)^\s*\`$command \+?= '(?<text>[^']*)'") | ForEach-Object { $_.Groups['text'].Value })
Test-Step -Title 'команда шага RESTORE читается из Restore-Machine.ps1' -Ok ($step.Count -eq 3 -and $step[0].EndsWith('& ')) -Note ('частей команды: {0}' -f $step.Count)

if ($failed) { Write-Host ''; Write-Host ('провалено проверок: {0}' -f $failed); exit 1 }

# --- пробные сценарии ----------------------------------------------------------
# Внешней программой служит cmd.exe: «cmd /c exit N» кончается кодом N и больше ничего не делает.
$probes = [ordered]@{
    'без exit; программа ответила 3, сценарий разобрался'  = "& cmd.exe /c exit 3`nif (`$LASTEXITCODE -ne 0) { 'handled' | Out-Null }`n'done' | Out-Null"
    'exit 5'                                                = 'exit 5'
    'exit 0 после программы, ответившей 6'                  = "& cmd.exe /c exit 6`nexit 0"
    'throw'                                                 = "`$ErrorActionPreference = 'Stop'`nthrow 'it broke'"
    'без exit и без программ'                               = "'done' | Out-Null"
    'return после программы, ответившей 2'                  = "& cmd.exe /c exit 2`nreturn"
    'exit 7 внутри функции'                                 = "function Leave { exit 7 }`nLeave"
    'последняя строка - программа, ответившая 4'            = '& cmd.exe /c exit 4'
    'if (failed) { exit 1 } в конце, сбоя нет, программа 9' = "& cmd.exe /c exit 9`n`$failed = 0`nif (`$failed) { exit 1 }"
}

$shell = (Get-Process -Id $PID).Path
$box = Join-Path ([System.IO.Path]::GetTempPath()) ('abk script exit ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][System.IO.Directory]::CreateDirectory($box)
function Get-Code {
    param([string[]]$Arguments)
    & $shell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass @Arguments 2>&1 | Out-Null
    return $LASTEXITCODE
}
try {
    $number = 0
    $rows = foreach ($title in $probes.Keys) {
        $number++
        # Пробел и апостроф в имени: папка данных зовётся «Audion Backup Laptop», и кавычки ставит обёртка.
        $file = Join-Path $box ("probe {0} o'k.ps1" -f $number)
        [System.IO.File]::WriteAllText($file, $probes[$title], [System.Text.UTF8Encoding]::new($true))
        $quoted = "'" + $file.Replace("'", "''") + "'"
        [pscustomobject]@{
            Title  = $title
            File   = Get-Code @('-File', $file)
            Window = Get-Code @('-Command', ($head.Groups['text'].Value + $quoted + $tail.Groups['text'].Value))
            Step   = Get-Code @('-EncodedCommand', [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($step[0] + $quoted + $step[1] + $step[2])))
        }
    }
    $other = @($rows | Where-Object { $_.Window -ne $_.File })
    Test-Step -Title 'под окном сценарий кончается тем же кодом, что и через -File' -Ok ($other.Count -eq 0 -and $rows.Count -eq $probes.Count) `
        -Note $(if ($other.Count) { ($other | ForEach-Object { '{0}: -File {1}, окно {2}' -f $_.Title, $_.File, $_.Window }) -join ' | ' } else { 'сценариев: {0}' -f $rows.Count })
    # Шаг RESTORE различает только «удался» и «нет»: любой отказ у него - единица.
    $wrong = @($rows | Where-Object { ($_.File -eq 0) -ne ($_.Step -eq 0) })
    Test-Step -Title 'шаг RESTORE удаётся там же, где удаётся -File' -Ok ($wrong.Count -eq 0) `
        -Note $(if ($wrong.Count) { ($wrong | ForEach-Object { '{0}: -File {1}, шаг {2}' -f $_.Title, $_.File, $_.Step }) -join ' | ' } else { 'сценариев: {0}' -f $rows.Count })
    $own = @($rows | Where-Object { $_.Title -in 'exit 5', 'exit 7 внутри функции' })
    Test-Step -Title 'собственный exit сценария доходит числом' -Ok ($own.Count -eq 2 -and $own[0].Window -eq 5 -and $own[1].Window -eq 7) -Note 'exit 5 и exit 7 из функции'
} finally {
    try { [System.IO.Directory]::Delete($box, $true) } catch { }
}

# Установщик архиватора и редакторов зовётся из Update-Tools.ps1 в том же процессе и при удаче кончается без exit.
$update = [System.IO.File]::ReadAllText((Join-Path $AppRoot 'Engine\Scripts\Update-Tools.ps1'))
Test-Step -Title 'Update-Tools.ps1 судит об установщике по успеху вызова' `
    -Ok ($update.Contains('if (-not $ran) { throw ("Install-Tools.ps1 ended with code') -and -not $update.Contains('if ($LASTEXITCODE) { throw ("Install-Tools.ps1')) `
    -Note '$ran = $? сразу после вызова'

Write-Host ''
if ($failed) {
    Write-Host ('провалено проверок: {0}' -f $failed)
    exit 1
}
Write-Host 'всё сходится'
exit 0
