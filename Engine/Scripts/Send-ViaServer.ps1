<#
.SYNOPSIS
    Перегон между облаками руками MAIN VPS, а не этой машины.

.DESCRIPTION
    Между разными облаками протокола «возьми у соседа» не существует: rclone
    гонит данные через машину, на которой запущен. Вопрос только в том, какая
    это будет машина.

    Запущен rclone дома - и терабайт дважды проходит через домашний канал. MAIN VPS стоит в дата-центре с широким каналом, и ему такая
    работа даётся вчетверо легче: он забирает у одного облака и отдаёт другому,
    а мы лишь смотрим за ходом.

    Ключи при этом на MAIN VPS не переезжают. rclone читает описание remote из
    переменных окружения, а сами переменные уходят туда внутри сценария,
    который выполняется через `ssh ... bash -s`: на диск MAIN VPS не ложится
    ничего, в списке процессов видно только `bash`. Проверено делом: после
    прогона `~/.config/rclone` на MAIN VPS остаётся пустым.

.PARAMETER From
    Откуда: `облако:путь`, например `drive:Архив`.

.PARAMETER To
    Куда: `облако:путь`.

.PARAMETER Server
    Через какой хост MAIN VPS идти. По умолчанию перебираются те же, что у
    SSH MAIN VPS: сперва прямой адрес, затем поверх cloudflared.

.PARAMETER Move
    Перенести, а не скопировать: после успешной передачи источник пустеет.

.PARAMETER Check
    Только показать, что будет сделано, и ничего не передавать.

.PARAMETER Watch
    Показать журнал последнего перегона: идёт ли он ещё и сколько прошло.
    Сама передача от этого не зависит - она живёт на MAIN VPS своей жизнью.

.EXAMPLE
    .\Send-ViaServer.ps1 -From drive:Архив -To dropbox:Архив -Check
    Посмотреть план.

.EXAMPLE
    .\Send-ViaServer.ps1 -From drive:Архив -To dropbox:Архив
    Перегнать силами MAIN VPS.
#>
# Два набора: перегон требует откуда и куда, наблюдение - ничего. Пока
# набор был один, обязательные From и To требовались и от `-Watch`:
# команда, которую сценарий сам же и советует, до дела не доходила.
[CmdletBinding(DefaultParameterSetName = 'Send')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Send')][string]$From,
    [Parameter(Mandatory, ParameterSetName = 'Send')][string]$To,
    [string[]]$Server = @('audion-vps-direct', 'audion-vps'),
    [Parameter(ParameterSetName = 'Send')][switch]$Move,
    [Parameter(ParameterSetName = 'Send')][switch]$Check,
    # Смотреть, как идёт начатое: журнал последнего перегона на MAIN VPS.
    [Parameter(Mandatory, ParameterSetName = 'Watch')][switch]$Watch,
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

# Список плеч приходит от враппера одной строкой: powershell -File не делит
# аргумент по запятым.
$Server = @($Server | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ })

function Write-Line { param($Text, $Color = 'Gray') Write-Host "  $Text" -ForegroundColor $Color }

function Get-RemoteName {
    <# Имя облака из «облако:путь». Без двоеточия это местный путь. #>
    param([string]$Spec)
    if ($Spec -notmatch '^([^:\\/]+):') { return '' }
    return $Matches[1]
}

Write-Host ''
Write-Host '=== ПЕРЕГОН СИЛАМИ MAIN VPS ===' -ForegroundColor Cyan
Write-Host ''

$LogFile = '~/.audion/logs/transfer.log'
$PidFile = '~/.audion/logs/transfer.pid'

# Идёт ли перегон: процесс с записанным номером жив, и это rclone. Одного
# `kill -0` мало: после перезагрузки MAIN VPS тот же номер достаётся кому
# угодно, и «ИДЁТ» говорилось бы о чужом процессе.
$Running = ('[ "$(ps -p "$(cat {0} 2>/dev/null)" -o comm= 2>/dev/null)" = rclone ]' -f $PidFile)
# Код, которым сценарий на MAIN VPS отвечает «занято»: не сбой хоста, второй хост пробовать незачем.
$BusyCode = 75

function Invoke-Leg {
    <# Команда на первом отвечающем плече. #>
    param([Parameter(Mandatory)][string]$Command)

    foreach ($leg in $Server) {
        $ErrorActionPreference = 'Continue'
        $out = & ssh -o BatchMode=yes -o ConnectTimeout=20 $leg $Command 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) { return @{ Ok = $true; Text = ($out | Out-String); Leg = $leg } }
    }
    return @{ Ok = $false; Text = ''; Leg = '' }
}

if ($Watch) {
    Write-Line 'журнал последнего перегона на MAIN VPS:'
    Write-Host ''
    $ask = 'if [ -f {0} ]; then if {1}; then echo "ИДЁТ"; else echo "ЗАКОНЧЕН"; fi; tail -n 20 {0}; else echo "перегонов ещё не было"; fi'
    $answer = Invoke-Leg -Command ($ask -f $LogFile, $Running)
    if (-not $answer.Ok) { Write-Line 'MAIN VPS молчит' Yellow; Write-Host ''; exit 1 }
    Write-Host $answer.Text
    Write-Host ''
    exit 0
}

$fromName = Get-RemoteName -Spec $From
$toName = Get-RemoteName -Spec $To
if (-not $fromName -or -not $toName) {
    Write-Line 'обе стороны должны быть облаками: «облако:путь»' Yellow
    Write-Line 'местные файлы MAIN VPS забрать не может - он их не видит' Yellow
    Write-Host ''
    exit 1
}

$exe = Find-AbkRclone -AppRoot $AppRoot
if (-not $exe) { Write-Line 'rclone не найден' Red; Write-Host ''; exit 1 }

$vars = Get-AbkCloudRemoteEnv -AppRoot $AppRoot -DataRoot $DataRoot -RcloneExe $exe
if (-not $vars.Count) {
    Write-Line 'ни одного облака не заведено: clouds-add.cmd' Yellow
    Write-Host ''
    exit 1
}

# На MAIN VPS уезжают только те два облака, что участвуют в перегоне. Остальные
# ему знать незачем - меньше знает, меньше теряет.
$needed = @{}
foreach ($pair in $vars.GetEnumerator()) {
    foreach ($name in @($fromName, $toName)) {
        $prefix = 'RCLONE_CONFIG_{0}_' -f ($name.ToUpper() -replace '[^A-Z0-9]', '_')
        if ($pair.Key.StartsWith($prefix)) { $needed[$pair.Key] = $pair.Value }
    }
}
if (-not $needed.Count) {
    Write-Line ('не нашлось описаний для {0} и {1}' -f $fromName, $toName) Yellow
    Write-Host ''
    exit 1
}

$verb = $(if ($Move) { 'move' } else { 'copy' })
Write-Line ('откуда : {0}' -f $From)
Write-Line ('куда   : {0}' -f $To)
Write-Line ('способ : {0}' -f $(if ($Move) { 'перенести' } else { 'скопировать' }))
Write-Line ('облаков в описании: {0}' -f @($fromName, $toName).Count)

if ($Check) {
    Write-Host ''
    Write-Line 'проверка: ничего не передано' Yellow
    Write-Line ('на MAIN VPS пойдёт: rclone {0} {1} {2}' -f $verb, $From, $To)
    Write-Line 'ключи уйдут переменными внутри сценария, на диск MAIN VPS не лягут'
    Write-Line 'работа отвяжется от этой консоли: её можно будет закрыть'
    Write-Line 'перегон на MAIN VPS идёт один: пока он не кончился, второй не начнётся'
    Write-Host ''
    exit 0
}

# Сценарий для MAIN VPS. Переменные объявляются внутри него и живут ровно
# столько, сколько идёт передача.
$lines = @('set -e')
# Журнал и файл с номером процесса на MAIN VPS одни на все перегоны. Второй,
# начатый до конца первого, затирал оба: первый шёл дальше, а смотреть за ним
# и узнать, что он ещё идёт, было уже нечем (проверка 08.10.2026). Теперь
# сценарий сперва спрашивает, идёт ли перегон, и при живом отказывается - до
# того, как объявлен хоть один ключ.
$lines += ('if {0}; then echo "--- на MAIN VPS уже идёт перегон, вот конец его журнала ---"; tail -n 3 {1} 2>/dev/null || true; exit {2}; fi' -f $Running, $LogFile, $BusyCode)
foreach ($pair in $needed.GetEnumerator()) {
    # Значение в одинарных кавычках: токен - это JSON со скобками и запятыми.
    $safe = $pair.Value -replace "'", "'\''"
    $lines += ("export {0}='{1}'" -f $pair.Key, $safe)
}
# Работа отвязывается от нашей консоли: `setsid` уводит rclone из группы
# процессов ssh, и обрыв связи, закрытый ноутбук или потухший Wi-Fi её больше не
# трогают. Сотня гигабайт едет часами - держать ради этого открытое окно было бы
# издевательством. За ходом смотрит `-Watch`, он читает тот же журнал.
$lines += 'mkdir -p ~/.audion/logs'
# Пути прячем так же, как токены выше. В двойных кавычках bash выполняет
# `$(...)` и обратные кавычки, а имя папки приходит из чужого облака:
# открыл такую папку, нажал перегон - и её имя выполнилось на MAIN VPS.
$fromSafe = $From -replace "'", "'\''"
$toSafe = $To -replace "'", "'\''"
$lines += ("setsid nohup rclone {0} '{1}' '{2}' --stats 30s --stats-one-line --transfers 8 --checkers 8 > {3} 2>&1 < /dev/null &" -f $verb, $fromSafe, $toSafe, '~/.audion/logs/transfer.log')
$lines += 'echo $! > ~/.audion/logs/transfer.pid'
$lines += 'sleep 2'
$lines += 'echo "--- запущено на MAIN VPS, вот начало журнала ---"'
$lines += 'tail -n 5 ~/.audion/logs/transfer.log 2>/dev/null || true'
$script = ($lines -join "`n") + "`n"

$done = $false
$busy = $false
foreach ($leg in $Server) {
    Write-Host ''
    Write-Line ('хост: {0}' -f $leg) Cyan

    # Сценарий уходит конвейером: перенаправление «<» в PowerShell
    # зарезервировано, а временный файл с ключами не нужен и здесь.
    $ErrorActionPreference = 'Continue'
    $script | & ssh -o BatchMode=yes -o ConnectTimeout=20 $leg 'bash -s'
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'

    if ($code -eq 0) { $done = $true; break }
    if ($code -eq $BusyCode) { $busy = $true; break }
    Write-Line ('хост {0} не отработал, пробуем следующий' -f $leg) Yellow
}

Write-Host ''
if ($done) {
    Write-Line 'запущено на MAIN VPS. Эту консоль можно закрыть: передача идёт сама.' Green
    Write-Line 'посмотреть, как идёт: clouds-send.cmd -Watch' Gray
    Write-Host ''
    exit 0
}

if ($busy) {
    Write-Line 'на MAIN VPS ещё идёт прежний перегон: новый не начат' Yellow
    Write-Line 'посмотреть, как идёт: clouds-send.cmd -Watch' Gray
    Write-Host ''
    exit 1
}

Write-Line 'не вышло ни через один хост' Yellow
Write-Host ''
exit 1
